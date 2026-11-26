import Foundation
import RabbitEarsAPI

public typealias PreviewFrames = Components.Schemas.PreviewFrames

extension PreviewFrames {
    /// Frame n is the keyframe nearest n times the interval.
    public func index(at seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        let nearest = (seconds * 1000 / Double(intervalMs)).rounded()
        return Int(min(Double(count - 1), max(0, nearest)))
    }

    public func url(at seconds: Double, endpoint: ServerEndpoint) -> URL {
        endpoint.resolve(frameUrl.replacingOccurrences(of: "{n}", with: String(index(at: seconds))))
    }
}

/// Pointer geometry of the scrub bar.
public enum Scrub {
    public static func seconds(atX pointer: Double, width: Double, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return min(1, max(0, pointer / width)) * duration
    }

    /// The preview card follows the pointer but never leaves the bar.
    public static func cardCenter(atX pointer: Double, width: Double, card: Double) -> Double {
        guard width > card else { return width / 2 }
        return min(width - card / 2, max(card / 2, pointer))
    }
}
