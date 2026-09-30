import Cocoa

final class DragSnapManager {
    static let shared = DragSnapManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var gestureState = DragGestureState()
    private var currentSnapAction: SnapAction?
    private var draggedWindow: AXUIElement?
    private var pendingDragPosition: CGPoint?
    private var dragUpdateScheduled = false

    private let edgeThreshold: CGFloat = 100
    private let cornerRadius: CGFloat = 200

    func start() {
        guard UserPreferences.shared.dragSnapEnabled else { return }
        guard eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDragged.rawValue) |
                                 (1 << CGEventType.leftMouseUp.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                DragSnapManager.shared.enqueueEvent(type: type, cursorPosition: event.location)
                return Unmanaged.passUnretained(event)
            }, userInfo: nil
        )
        guard let eventTap = eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        if let eventTap = eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        resetDragState()
        pendingDragPosition = nil
        dragUpdateScheduled = false
        eventTap = nil
        runLoopSource = nil
    }

    func reload() { stop(); start() }

    private func enqueueEvent(type: CGEventType, cursorPosition: CGPoint) {
        if Self.isEventTapDisabled(type) {
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            resetDragState()
            pendingDragPosition = nil
            dragUpdateScheduled = false
            DispatchQueue.main.async { SnapOverlayWindow.shared.hideOverlay() }
            return
        }

        switch type {
        case .leftMouseDragged:
            pendingDragPosition = cursorPosition
            guard !dragUpdateScheduled else { return }
            dragUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dragUpdateScheduled = false
                guard let latestPosition = self.pendingDragPosition else { return }
                self.pendingDragPosition = nil
                self.handleDrag(cursorPosition: latestPosition)
            }
        case .leftMouseUp:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let latestPosition = self.pendingDragPosition {
                    self.pendingDragPosition = nil
                    self.handleDrag(cursorPosition: latestPosition)
                }
                self.handleMouseUp(cursorPosition: cursorPosition)
            }
        default: break
        }
    }

    static func isEventTapDisabled(_ type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }

    private func handleDrag(cursorPosition: CGPoint) {
        if !gestureState.isActive {
            guard let window = WindowManager.shared.getFocusedWindow(),
                  let windowPos = WindowManager.shared.getPosition(of: window),
                  let windowSize = WindowManager.shared.getSize(of: window) else { return }

            var windowPID: pid_t = 0
            guard AXUIElementGetPid(window, &windowPID) == .success else { return }

            let isCandidate = DragGestureState.isWindowDragCandidate(
                point: cursorPosition,
                windowPosition: windowPos,
                windowSize: windowSize,
                windowPID: windowPID,
                topmostWindowPID: topmostWindowOwnerPID(at: cursorPosition)
            )

            gestureState.begin(
                isCandidate: isCandidate,
                cursorPosition: cursorPosition,
                windowPosition: windowPos
            )
            draggedWindow = window
            currentSnapAction = nil
            return
        }

        // Ignore the entire gesture when it did not begin in the window title bar.
        // Keeping the drag state until mouse-up prevents a screenshot or file drag
        // from being reconsidered as a window drag as it crosses the screen.
        guard gestureState.isCandidate,
              let window = draggedWindow,
              let currentWindowPosition = WindowManager.shared.getPosition(of: window) else { return }

        let decision = gestureState.update(
            cursorPosition: cursorPosition,
            currentWindowPosition: currentWindowPosition
        ) {
            if WindowManager.shared.hasPreviousFrame(for: window) {
                return .previousFrame
            }
            if WindowManager.shared.isWindowMaximized(window) {
                return .maximized
            }
            return nil
        }

        switch decision {
        case .ignore, .wait:
            return
        case .restore(.previousFrame):
            DispatchQueue.main.async {
                WindowManager.shared.restoreWindowAtCursor(window, cursorCG: cursorPosition)
            }
            return
        case .restore(.maximized):
            DispatchQueue.main.async {
                WindowManager.shared.restoreFromMaximized(window, cursorCG: cursorPosition)
            }
            return
        case .detectSnapZone:
            break
        }

        let detectedAction = detectSnapZone(cursor: cursorPosition)

        if detectedAction != currentSnapAction {
            currentSnapAction = detectedAction
            DispatchQueue.main.async {
                if let action = detectedAction, let screen = self.screenForCursor(cursorPosition) {
                    if let frame = SnapZone.frame(for: action, on: screen) {
                        SnapOverlayWindow.shared.show(at: frame)
                    }
                } else {
                    SnapOverlayWindow.shared.hideOverlay()
                }
            }
        }
    }

    private func handleMouseUp(cursorPosition: CGPoint) {
        let action = currentSnapAction
        let window = draggedWindow
        let wasDragging = gestureState.isActive

        resetDragState()

        guard wasDragging, let action = action, let window = window else {
            DispatchQueue.main.async { SnapOverlayWindow.shared.hideOverlay() }
            return
        }
        guard let screen = screenForCursor(cursorPosition) else {
            DispatchQueue.main.async { SnapOverlayWindow.shared.hideOverlay() }
            return
        }

        if let targetFrame = SnapZone.frame(for: action, on: screen) {
            let cgFrame = DisplayHelper.shared.cgFrame(fromAppKitFrame: targetFrame)
            DispatchQueue.main.async {
                WindowManager.shared.move(window: window, to: cgFrame)
                SnapOverlayWindow.shared.hideOverlay()
            }
        } else {
            DispatchQueue.main.async { SnapOverlayWindow.shared.hideOverlay() }
        }
    }

    // MARK: - Zone Detection

    private func topmostWindowOwnerPID(at point: CGPoint) -> pid_t? {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for info in windows {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"],
                  let height = bounds["Height"],
                  width > 0,
                  height > 0 else { continue }

            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: width,
                height: height
            )
            if frame.contains(point) {
                return ownerPID
            }
        }

        return nil
    }

    func detectSnapZone(cursor: CGPoint) -> SnapAction? {
        let nsCursor = DisplayHelper.shared.appKitPoint(fromCGPoint: cursor)

        guard let screen = screenForNSPoint(nsCursor) else { return nil }
        let frame = screen.frame

        let distLeft = nsCursor.x - frame.minX
        let distRight = frame.maxX - nsCursor.x
        let distTop = frame.maxY - nsCursor.y
        let distBottom = nsCursor.y - frame.minY

        let nearLeft = distLeft < edgeThreshold
        let nearRight = distRight < edgeThreshold
        let nearTop = distTop < edgeThreshold

        let inCornerLeft = distLeft < cornerRadius
        let inCornerRight = distRight < cornerRadius
        let inCornerTop = distTop < cornerRadius
        let inCornerBottom = distBottom < cornerRadius

        // Corners first
        if nearTop && inCornerLeft { return .topLeft }
        if nearTop && inCornerRight { return .topRight }
        if nearLeft && inCornerTop { return .topLeft }
        if nearRight && inCornerTop { return .topRight }
        if nearLeft && inCornerBottom { return .bottomLeft }
        if nearRight && inCornerBottom { return .bottomRight }

        // Edges
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        if nearTop { return .maximize }

        return nil
    }

    private func screenForCursor(_ cgPoint: CGPoint) -> NSScreen? {
        DisplayHelper.shared.screen(at: cgPoint)
    }

    private func screenForNSPoint(_ nsPoint: CGPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.frame.contains(nsPoint) {
                return screen
            }
        }
        return NSScreen.main
    }

    private func resetDragState() {
        gestureState.reset()
        currentSnapAction = nil
        draggedWindow = nil
    }
}
