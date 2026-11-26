import AppKit

/// A way back or forward through `NavigationHistory` that is not a key.
public enum HistoryStep: Equatable, Sendable {
    case back, forward

    /// Mouse buttons 4 and 5 (numbered from 0) on press, and a swipe event,
    /// which mouse utilities post in their place. Two-finger trackpad swipes
    /// arrive as scrolls and are tracked apart.
    public init?(_ event: NSEvent) {
        switch event.type {
        case .otherMouseDown where event.buttonNumber == 3: self = .back
        case .otherMouseDown where event.buttonNumber == 4: self = .forward
        case .swipe where event.deltaX > 0: self = .back
        case .swipe where event.deltaX < 0: self = .forward
        default: return nil
        }
    }
}

extension NavigationHistory {
    public mutating func take(_ step: HistoryStep) {
        switch step {
        case .back: back()
        case .forward: forward()
        }
    }
}
