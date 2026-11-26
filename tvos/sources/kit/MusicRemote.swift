import Foundation
import RabbitEarsAPI

extension RepeatMode {
    public var label: String { self == .one ? "Repeat one" : "Repeat" }
}
