import Cocoa

final class DisplayHelper {
    static let shared = DisplayHelper()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        NotificationCenter.default.post(name: .displaysChanged, object: nil)
    }

    /// Returns the AppKit screen containing a point expressed in the global
    /// Core Graphics / Accessibility coordinate space.
    func screen(at point: CGPoint) -> NSScreen? {
        let appKitPoint = self.appKitPoint(fromCGPoint: point)
        for screen in NSScreen.screens {
            if screen.frame.contains(appKitPoint) {
                return screen
            }
        }
        return NSScreen.main
    }

    /// AX window frames use the Core Graphics coordinate space, while
    /// NSScreen frames use AppKit coordinates. Convert every display before
    /// comparing intersections so vertically arranged displays work too.
    func currentScreen(for windowFrame: CGRect) -> NSScreen {
        let screens = NSScreen.screens
        if let index = Self.bestScreenIndex(
            forCGWindowFrame: windowFrame,
            appKitScreenFrames: screens.map(\.frame),
            primaryMaxY: primaryMaxY
        ) {
            return screens[index]
        }
        return NSScreen.main ?? screens[0]
    }

    private var sortedScreens: [NSScreen] {
        NSScreen.screens.sorted {
            if $0.frame.minX == $1.frame.minX {
                return $0.frame.maxY > $1.frame.maxY
            }
            return $0.frame.minX < $1.frame.minX
        }
    }

    /// Next screen to the right (by physical position). No wrap.
    func nextScreen(from current: NSScreen) -> NSScreen? {
        let screens = sortedScreens
        guard screens.count > 1 else { return nil }
        guard let idx = screens.firstIndex(of: current) else { return nil }
        let nextIdx = idx + 1
        guard nextIdx < screens.count else { return nil }
        return screens[nextIdx]
    }

    /// Previous screen to the left (by physical position). No wrap.
    func previousScreen(from current: NSScreen) -> NSScreen? {
        let screens = sortedScreens
        guard screens.count > 1 else { return nil }
        guard let idx = screens.firstIndex(of: current) else { return nil }
        let prevIdx = idx - 1
        guard prevIdx >= 0 else { return nil }
        return screens[prevIdx]
    }

    func appKitPoint(fromCGPoint point: CGPoint) -> CGPoint {
        Self.appKitPoint(fromCGPoint: point, primaryMaxY: primaryMaxY)
    }

    func cgFrame(fromAppKitFrame frame: CGRect) -> CGRect {
        Self.cgFrame(fromAppKitFrame: frame, primaryMaxY: primaryMaxY)
    }

    static func appKitPoint(fromCGPoint point: CGPoint, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }

    static func cgFrame(fromAppKitFrame frame: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func bestScreenIndex(
        forCGWindowFrame windowFrame: CGRect,
        appKitScreenFrames: [CGRect],
        primaryMaxY: CGFloat
    ) -> Int? {
        var bestIndex: Int?
        var maximumArea: CGFloat = 0

        for (index, appKitFrame) in appKitScreenFrames.enumerated() {
            let screenFrame = cgFrame(fromAppKitFrame: appKitFrame, primaryMaxY: primaryMaxY)
            let intersection = screenFrame.intersection(windowFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > maximumArea {
                maximumArea = area
                bestIndex = index
            }
        }

        return bestIndex
    }

    private var primaryMaxY: CGFloat {
        (NSScreen.screens.first ?? NSScreen.main)?.frame.maxY ?? 0
    }
}

extension Notification.Name {
    static let displaysChanged = Notification.Name("BentoDisplaysChanged")
}
