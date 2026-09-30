import CoreGraphics
import Darwin

struct DragGestureState {
    enum RestoreKind: Equatable {
        case previousFrame
        case maximized
    }

    enum Decision: Equatable {
        case ignore
        case wait
        case restore(RestoreKind)
        case detectSnapZone
    }

    private(set) var isActive = false
    private(set) var isCandidate = false

    private var startCursorPosition: CGPoint?
    private var startWindowPosition: CGPoint?
    private var hasConfirmedWindowMovement = false
    private var hasCheckedRestore = false

    mutating func begin(
        isCandidate: Bool,
        cursorPosition: CGPoint,
        windowPosition: CGPoint
    ) {
        reset()
        isActive = true
        self.isCandidate = isCandidate
        startCursorPosition = cursorPosition
        startWindowPosition = windowPosition
    }

    mutating func update(
        cursorPosition: CGPoint,
        currentWindowPosition: CGPoint,
        restoreKind: () -> RestoreKind?
    ) -> Decision {
        guard isActive,
              isCandidate,
              let startCursorPosition,
              let startWindowPosition else { return .ignore }

        let cursorDistance = distance(from: startCursorPosition, to: cursorPosition)
        guard cursorDistance >= 5 else { return .wait }

        if !hasCheckedRestore && cursorDistance > 50 {
            hasCheckedRestore = true
            if let restoreKind = restoreKind() {
                return .restore(restoreKind)
            }
        }

        if !hasConfirmedWindowMovement {
            guard distance(from: startWindowPosition, to: currentWindowPosition) >= 5 else {
                return .wait
            }
            hasConfirmedWindowMovement = true
        }

        return .detectSnapZone
    }

    mutating func reset() {
        self = DragGestureState()
    }

    static func isPointInTitleBar(
        _ point: CGPoint,
        windowPosition: CGPoint,
        windowSize: CGSize,
        titleBarHeight: CGFloat = 40
    ) -> Bool {
        let relativeY = point.y - windowPosition.y
        return relativeY >= 0 && relativeY <= titleBarHeight
            && point.x >= windowPosition.x && point.x <= windowPosition.x + windowSize.width
    }

    static func isWindowDragCandidate(
        point: CGPoint,
        windowPosition: CGPoint,
        windowSize: CGSize,
        windowPID: pid_t,
        topmostWindowPID: pid_t?
    ) -> Bool {
        isPointInTitleBar(
            point,
            windowPosition: windowPosition,
            windowSize: windowSize
        ) && topmostWindowPID == windowPID
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}
