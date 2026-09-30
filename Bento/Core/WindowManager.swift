import Cocoa
import ApplicationServices
import os.log

private let log = OSLog(subsystem: "run.nudge.app", category: "WindowManager")
private let kAXEnhancedUserInterface = "AXEnhancedUserInterface" as CFString

struct WindowFrameHistory {
    private let capacity: Int
    private var frames: [String: CGRect] = [:]
    private var insertionOrder: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func frame(for windowID: String) -> CGRect? {
        frames[windowID]
    }

    mutating func remember(_ frame: CGRect, for windowID: String) {
        guard frames[windowID] == nil else { return }
        frames[windowID] = frame
        insertionOrder.append(windowID)

        while insertionOrder.count > capacity {
            let expiredID = insertionOrder.removeFirst()
            frames.removeValue(forKey: expiredID)
        }
    }

    mutating func forget(windowID: String) {
        frames.removeValue(forKey: windowID)
        insertionOrder.removeAll { $0 == windowID }
    }
}

final class WindowManager {
    static let shared = WindowManager()

    private var frameHistory = WindowFrameHistory(capacity: 128)
    private var lastSnapAction: (windowID: String, action: SnapAction, screen: NSScreen)?

    // MARK: - Get Focused Window

    func getFocusedWindow() -> AXUIElement? {
        // Step 1: Get the frontmost app's PID (two strategies)
        let pid: pid_t
        let appElement: AXUIElement

        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)

        if appResult == .success, let axApp = axElement(from: focusedApp) {
            var p: pid_t = 0
            guard AXUIElementGetPid(axApp, &p) == .success else { return nil }
            pid = p
            appElement = axApp
        } else if let frontApp = NSWorkspace.shared.frontmostApplication {
            pid = frontApp.processIdentifier
            appElement = AXUIElementCreateApplication(pid)
        } else {
            FileLog.write("getFocusedWindow: no app found")
            return nil
        }

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid:\(pid)"

        // Step 2: Try AX attributes to get the focused/main window
        if let window = axWindow(from: appElement, appName: appName) {
            return window
        }

        // Step 3: If appElement came from systemWide, also try PID-based element
        if appResult == .success {
            let pidApp = AXUIElementCreateApplication(pid)
            if let window = axWindow(from: pidApp, appName: appName) {
                FileLog.write("getFocusedWindow: OK via PID-rebased [\(appName)]")
                return window
            }
        }

        // Step 4: Use CGWindowList to find the topmost on-screen window for this PID,
        //         then match it to an AX window by position
        if let window = windowViaCGWindowList(pid: pid, appName: appName) {
            return window
        }

        FileLog.write("getFocusedWindow: ALL methods failed [\(appName)]")
        return nil
    }

    /// Try focusedWindow → mainWindow → windows[] on an AX app element
    private func axWindow(from appElement: AXUIElement, appName: String) -> AXUIElement? {
        // focusedWindow
        var fw: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &fw) == .success,
           let w = axElement(from: fw), getPosition(of: w) != nil {
            return w
        }
        // mainWindow
        var mw: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mw) == .success,
           let w = axElement(from: mw), getPosition(of: w) != nil {
            return w
        }
        // walk windows array
        var wl: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &wl) == .success,
           let windows = wl as? [AXUIElement] {
            for w in windows {
                if getPosition(of: w) != nil, getSize(of: w) != nil {
                    return w
                }
            }
        }
        return nil
    }

    /// Use CGWindowListCopyWindowInfo to find the topmost window for a PID,
    /// then match its bounds against AX windows to return the correct AXUIElement
    private func windowViaCGWindowList(pid: pid_t, appName: String) -> AXUIElement? {
        let allWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        // Find the topmost (first in z-order) normal window for this PID
        var targetBounds: CGRect?
        for info in allWindows {
            guard let wPid = info[kCGWindowOwnerPID as String] as? pid_t, wPid == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = bounds["X"] ?? 0, y = bounds["Y"] ?? 0
            let w = bounds["Width"] ?? 0, h = bounds["Height"] ?? 0
            if w > 50 && h > 50 { // skip tiny windows (tooltips, etc.)
                targetBounds = CGRect(x: x, y: y, width: w, height: h)
                break // first match = topmost in z-order
            }
        }

        guard let target = targetBounds else { return nil }

        // Now match against AX windows by position
        let pidApp = AXUIElementCreateApplication(pid)
        var wl: AnyObject?
        guard AXUIElementCopyAttributeValue(pidApp, kAXWindowsAttribute as CFString, &wl) == .success,
              let windows = wl as? [AXUIElement] else { return nil }

        for w in windows {
            guard let pos = getPosition(of: w), let size = getSize(of: w) else { continue }
            if abs(pos.x - target.origin.x) < 10 &&
               abs(pos.y - target.origin.y) < 10 &&
               abs(size.width - target.width) < 10 &&
               abs(size.height - target.height) < 10 {
                FileLog.write("getFocusedWindow: OK via CGWindowList match [\(appName)]")
                return w
            }
        }

        // If no exact match, return the first window that has both pos and size
        for w in windows {
            if getPosition(of: w) != nil, getSize(of: w) != nil {
                FileLog.write("getFocusedWindow: OK via CGWindowList first-visible [\(appName)]")
                return w
            }
        }

        return nil
    }

    // MARK: - Get/Set Window Position & Size

    func getFrame(of window: AXUIElement) -> CGRect? {
        guard let position = getPosition(of: window),
              let size = getSize(of: window) else { return nil }
        return CGRect(origin: position, size: size)
    }

    func getPosition(of window: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = axValue(from: value),
              AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    func getSize(of window: AXUIElement) -> CGSize? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = axValue(from: value),
              AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    @discardableResult
    func setPosition(of window: AXUIElement, to point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    func setSize(of window: AXUIElement, to size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    // MARK: - Move Window to Frame

    @discardableResult
    func move(window: AXUIElement, to frame: CGRect) -> Bool {
        let currentFrame = getFrame(of: window)
        let windowID = getWindowID(of: window)
        disableEnhancedUI(for: window)
        let resized = setSize(of: window, to: frame.size)
        let positioned = setPosition(of: window, to: frame.origin)
        if (resized || positioned), let currentFrame, let windowID {
            rememberPreviousFrame(currentFrame, for: windowID)
        }
        if !resized || !positioned {
            FileLog.write("move: position=\(positioned) size=\(resized)")
        }
        return resized && positioned
    }

    /// Disable AXEnhancedUserInterface on the app — Chrome/Chromium enables this
    /// which causes animated window moves via AX. Rectangle uses the same workaround.
    private func disableEnhancedUI(for window: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXEnhancedUserInterface, &value) == .success,
              let enabled = value as? NSNumber, enabled.boolValue else { return }
        AXUIElementSetAttributeValue(app, kAXEnhancedUserInterface, kCFBooleanFalse)
    }

    // MARK: - Restore

    func hasPreviousFrame(for window: AXUIElement) -> Bool {
        guard let windowID = getWindowID(of: window) else { return false }
        return frameHistory.frame(for: windowID) != nil
    }

    func restoreWindow(_ window: AXUIElement) {
        guard let windowID = getWindowID(of: window),
              let previousFrame = frameHistory.frame(for: windowID) else { return }
        let resized = setSize(of: window, to: previousFrame.size)
        let positioned = setPosition(of: window, to: previousFrame.origin)
        if resized && positioned {
            forgetPreviousFrame(for: windowID)
        } else {
            FileLog.write("restore: position=\(positioned) size=\(resized)")
        }
    }

    func isWindowMaximized(_ window: AXUIElement) -> Bool {
        guard let frame = getFrame(of: window) else { return false }
        let screen = DisplayHelper.shared.currentScreen(for: frame)
        let visibleCG = convertToCG(nsFrame: screen.visibleFrame)
        return abs(frame.width - visibleCG.width) < 20 &&
               abs(frame.height - visibleCG.height) < 20
    }

    func restoreFromMaximized(_ window: AXUIElement, cursorCG: CGPoint? = nil) {
        guard let frame = getFrame(of: window) else { return }
        let screen = DisplayHelper.shared.currentScreen(for: frame)
        let visible = screen.visibleFrame
        let newWidth = visible.width * 0.7
        let newHeight = visible.height * 0.7
        let cgX: CGFloat
        let cgY: CGFloat
        if let cursor = cursorCG {
            cgX = cursor.x - newWidth / 2
            cgY = cursor.y
        } else {
            cgX = visible.minX + (visible.width - newWidth) / 2
            let centeredFrame = CGRect(
                x: cgX,
                y: visible.minY + (visible.height - newHeight) / 2,
                width: newWidth,
                height: newHeight
            )
            cgY = convertToCG(nsFrame: centeredFrame).minY
        }
        let resized = setSize(of: window, to: CGSize(width: newWidth, height: newHeight))
        let positioned = setPosition(of: window, to: CGPoint(x: cgX, y: cgY))
        if !resized || !positioned {
            FileLog.write("restoreFromMaximized: position=\(positioned) size=\(resized)")
        }
    }

    func restoreWindowAtCursor(_ window: AXUIElement, cursorCG: CGPoint) {
        guard let windowID = getWindowID(of: window),
              let previousFrame = frameHistory.frame(for: windowID) else { return }
        let prevSize = previousFrame.size
        let cgX = cursorCG.x - prevSize.width / 2
        let cgY = cursorCG.y
        let resized = setSize(of: window, to: prevSize)
        let positioned = setPosition(of: window, to: CGPoint(x: cgX, y: cgY))
        if resized && positioned {
            forgetPreviousFrame(for: windowID)
        } else {
            FileLog.write("restoreAtCursor: position=\(positioned) size=\(resized)")
        }
    }

    // MARK: - Snap Actions

    func performAction(_ action: SnapAction) {
        // Try AX-based window detection first
        if let window = getFocusedWindow() {
            performActionOnAXWindow(window, action: action)
            return
        }

        FileLog.write("performAction(\(action.rawValue)): no focused window")
        os_log("performAction: no focused window", log: log, type: .error)
    }

    private func performActionOnAXWindow(_ window: AXUIElement, action: SnapAction) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else {
            FileLog.write("performAction: cannot resolve window PID")
            return
        }
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        os_log("performAction: %{public}@ on %{public}@", log: log, type: .info, action.rawValue, appName)
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleID = app.bundleIdentifier,
           UserPreferences.shared.isAppIgnored(bundleID) {
            return
        }

        guard let currentFrame = getFrame(of: window) else {
            os_log("performAction: cannot get window frame", log: log, type: .error)
            return
        }

        let currentScreen = DisplayHelper.shared.currentScreen(for: currentFrame)

        switch action {
        case .restore:
            restoreWindow(window)
            lastSnapAction = nil
            return
        case .center:
            center(window: window, on: currentScreen)
            lastSnapAction = nil
            return
        case .nextDisplay:
            moveToDisplay(window: window, from: currentScreen, next: true)
            lastSnapAction = nil
            return
        case .previousDisplay:
            moveToDisplay(window: window, from: currentScreen, next: false)
            lastSnapAction = nil
            return
        default:
            break
        }

        // Check if window is ALREADY at the target snap position on this screen
        let windowID = getWindowID(of: window)
        if let targetFrame = SnapZone.frame(for: action, on: currentScreen) {
            let cgTarget = convertToCG(nsFrame: targetFrame)
            let exactMatch = Self.framesMatch(currentFrame, cgTarget)
            let repeatMatch = windowID != nil &&
                lastSnapAction?.windowID == windowID &&
                lastSnapAction?.action == action &&
                lastSnapAction?.screen == currentScreen
            if exactMatch || repeatMatch {
                if !action.hasCycleDirection {
                    lastSnapAction = nil
                    return
                }
                lastSnapAction = nil
                cycleToNextMonitor(window: window, action: action, from: currentScreen)
                return
            }
        }

        // Normal snap on current screen
        if let targetFrame = SnapZone.frame(for: action, on: currentScreen) {
            let cgFrame = convertToCG(nsFrame: targetFrame)
            move(window: window, to: cgFrame)
            if let wid = windowID {
                lastSnapAction = (windowID: wid, action: action, screen: currentScreen)
            }
        }
    }

    // MARK: - Multi-Monitor Cycling

    /// When window is already at the target position, move to next monitor with mirrored position
    private func cycleToNextMonitor(window: AXUIElement, action: SnapAction, from screen: NSScreen) {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }

        let direction = Self.cycleDirection(for: action)
        let targetScreen: NSScreen?
        if direction > 0 {
            targetScreen = DisplayHelper.shared.nextScreen(from: screen)
        } else {
            targetScreen = DisplayHelper.shared.previousScreen(from: screen)
        }
        guard let nextScreen = targetScreen else { return }

        // Mirror the action horizontally when crossing monitors
        let mirroredAction = Self.mirroredAction(action)

        if let targetFrame = SnapZone.frame(for: mirroredAction, on: nextScreen) {
            let cgFrame = convertToCG(nsFrame: targetFrame)
            move(window: window, to: cgFrame)
        }
    }

    /// Mirror an action horizontally (right↔left, keeping top/bottom)
    /// For top/bottom half: keep the same shape on the next monitor
    static func mirroredAction(_ action: SnapAction) -> SnapAction {
        switch action {
        case .leftHalf: return .rightHalf
        case .rightHalf: return .leftHalf
        case .topLeft: return .topRight
        case .topRight: return .topLeft
        case .bottomLeft: return .bottomRight
        case .bottomRight: return .bottomLeft
        case .leftThird: return .rightThird
        case .rightThird: return .leftThird
        case .leftTwoThirds: return .rightTwoThirds
        case .rightTwoThirds: return .leftTwoThirds
        // Top/bottom half: mirror vertically when crossing monitors
        case .topHalf: return .bottomHalf
        case .bottomHalf: return .topHalf
        default: return action
        }
    }

    /// Right-side actions cycle right, left-side actions cycle left
    /// Bottom half cycles right (like rightHalf), top half cycles left (like leftHalf)
    static func cycleDirection(for action: SnapAction) -> Int {
        switch action {
        case .rightHalf, .topRight, .bottomRight, .rightThird, .rightTwoThirds, .bottomHalf:
            return 1
        case .leftHalf, .topLeft, .bottomLeft, .leftThird, .leftTwoThirds, .topHalf:
            return -1
        default:
            return 1
        }
    }

    /// Check if two frames match (within tolerance)
    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 15) -> Bool {
        return abs(a.origin.x - b.origin.x) < tolerance &&
               abs(a.origin.y - b.origin.y) < tolerance &&
               abs(a.width - b.width) < tolerance &&
               abs(a.height - b.height) < tolerance
    }

    // MARK: - Special Actions

    private func center(window: AXUIElement, on screen: NSScreen) {
        guard let size = getSize(of: window) else { return }
        guard let currentFrame = getFrame(of: window) else { return }

        let screenCG = convertToCG(nsFrame: screen.visibleFrame)
        let cgX = screenCG.minX + (screenCG.width - size.width) / 2
        let cgY = screenCG.minY + (screenCG.height - size.height) / 2
        let windowID = getWindowID(of: window)

        let positioned = setPosition(of: window, to: CGPoint(x: cgX, y: cgY))
        if positioned {
            if let windowID {
                rememberPreviousFrame(currentFrame, for: windowID)
            }
        } else {
            FileLog.write("center: failed to move window")
        }
    }

    private func moveToDisplay(window: AXUIElement, from currentScreen: NSScreen, next: Bool) {
        let targetScreen: NSScreen?
        if next {
            targetScreen = DisplayHelper.shared.nextScreen(from: currentScreen)
        } else {
            targetScreen = DisplayHelper.shared.previousScreen(from: currentScreen)
        }
        guard let screen = targetScreen else { return }
        let targetFrame = screen.visibleFrame
        let cgFrame = convertToCG(nsFrame: targetFrame)
        move(window: window, to: cgFrame)
    }

    // MARK: - Window ID

    private func getWindowID(of window: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let position = getPosition(of: window) else { return fallbackWindowID(pid: pid, window: window) }
        for info in windowList {
            guard let wPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  wPid == pid,
                  let wNumber = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let wX = bounds["X"] ?? 0
            let wY = bounds["Y"] ?? 0
            if abs(wX - position.x) < 5 && abs(wY - position.y) < 5 {
                return "\(pid)-\(wNumber)"
            }
        }
        return fallbackWindowID(pid: pid, window: window)
    }

    // MARK: - Coordinate Conversion

    func convertToCG(nsFrame: CGRect) -> CGRect {
        DisplayHelper.shared.cgFrame(fromAppKitFrame: nsFrame)
    }

    private func rememberPreviousFrame(_ frame: CGRect, for windowID: String) {
        frameHistory.remember(frame, for: windowID)
    }

    private func forgetPreviousFrame(for windowID: String) {
        frameHistory.forget(windowID: windowID)
    }

    private func fallbackWindowID(pid: pid_t, window: AXUIElement) -> String {
        "\(pid)-ax-\(CFHash(window))"
    }

    private func axElement(from value: AnyObject?) -> AXUIElement? {
        guard let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func axValue(from value: AnyObject?) -> AXValue? {
        guard let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}
