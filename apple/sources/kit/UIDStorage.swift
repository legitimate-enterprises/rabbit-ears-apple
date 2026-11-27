import Foundation
import GRDB
import RabbitEarsAPI

// swift-format-ignore: AvoidRetroactiveConformances
/// An id is a 16-byte BLOB in the replica and the queue. Any other cell
/// reads as no id, so a non-optional read of a TEXT id traps instead of
/// matching nothing.
extension UID: @retroactive DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { uuid.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> UID? {
        guard case .blob(let bytes) = dbValue.storage, bytes.count == 16 else { return nil }
        return UUID.fromDatabaseValue(dbValue).map(UID.init(uuid:))
    }
}
