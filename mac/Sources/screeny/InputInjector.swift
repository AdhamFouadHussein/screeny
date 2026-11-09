import CoreGraphics
import Foundation

enum InputAction: UInt8 {
    case down = 0, drag, up
    case scroll
    case rightClick
    case hover
}

/// Turns touch messages from the tablet into mouse events on the virtual display.
/// Coordinates and scroll deltas are normalized to the display size.
final class InputInjector {
    static let messageSize = 9

    private static let doubleClickSeconds = 0.4
    private static let doubleClickPoints = 8.0

    private let displayID: CGDirectDisplayID
    private var buttonDown = false
    private var lastPoint = CGPoint.zero
    private var lastUpTime = 0.0
    private var lastUpPoint = CGPoint.zero
    private var clickCount = 1

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func handle(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count == Self.messageSize, let action = InputAction(rawValue: bytes[0]) else { return }
        func float(_ offset: Int) -> Double {
            let bits = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : 0
        }
        let a = float(1)
        let b = float(5)

        switch action {
        case .down:
            let point = point(a, b)
            let now = Date().timeIntervalSinceReferenceDate
            let isRepeat = now - lastUpTime < Self.doubleClickSeconds
                && hypot(point.x - lastUpPoint.x, point.y - lastUpPoint.y) < Self.doubleClickPoints
            clickCount = isRepeat ? clickCount + 1 : 1
            post(.mouseMoved, at: point, button: .left)
            post(.leftMouseDown, at: point, button: .left, clicks: clickCount)
            buttonDown = true
        case .drag:
            post(buttonDown ? .leftMouseDragged : .mouseMoved, at: point(a, b), button: .left, clicks: clickCount)
        case .up:
            let point = point(a, b)
            post(.leftMouseUp, at: point, button: .left, clicks: clickCount)
            buttonDown = false
            lastUpTime = Date().timeIntervalSinceReferenceDate
            lastUpPoint = point
        case .scroll:
            let bounds = CGDisplayBounds(displayID)
            scroll(dx: a * bounds.width, dy: b * bounds.height)
        case .rightClick:
            let point = point(a, b)
            post(.mouseMoved, at: point, button: .left)
            post(.rightMouseDown, at: point, button: .right)
            post(.rightMouseUp, at: point, button: .right)
        case .hover:
            post(.mouseMoved, at: point(a, b), button: .left)
        }
    }

    func releaseButtons() {
        guard buttonDown else { return }
        post(.leftMouseUp, at: lastPoint, button: .left, clicks: clickCount)
        buttonDown = false
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(
            x: bounds.minX + min(max(x, 0), 1) * (bounds.width - 1),
            y: bounds.minY + min(max(y, 0), 1) * (bounds.height - 1)
        )
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clicks: Int = 1) {
        lastPoint = point
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        event.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Double, dy: Double) {
        guard abs(dx) < 100_000, abs(dy) < 100_000 else { return }
        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy.rounded()),
            wheel2: Int32(dx.rounded()),
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }
}
