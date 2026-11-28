import Foundation
import Observation
import RabbitEarsAPI

public typealias SmartField = Components.Schemas.SmartField
public typealias SmartOperator = Components.Schemas.SmartOperator
public typealias SmartMatch = Components.Schemas.SmartMatch
public typealias SmartRules = Components.Schemas.SmartRules

/// What rules choose from: a playlist's kind of title, or a collection's movies.
public enum SmartScope: Hashable, Sendable {
    case playlist(PlaylistKind)
    case collection
}

/// What a field's conditions compare it with.
public enum SmartValueType: Sendable {
    case text, number, boolean
}

extension SmartField {
    /// The fields the server's catalog has for the scope, in picker order.
    public static func fields(_ scope: SmartScope) -> [SmartField] {
        switch scope {
        case .collection: fields(.playlist(.movies)).filter { !$0.isPersonal }
        case .playlist(let kind):
            switch kind {
            case .movies:
                [
                    .title, .year, .runtime, .contentRating, .genre, .cast, .director, .hdr, .uhd, .watched, .playCount,
                    .favorite,
                ]
            case .tv:
                [
                    .title, .show, .season, .episode, .year, .runtime, .contentRating, .genre, .cast, .hdr, .uhd,
                    .watched,
                    .playCount, .favorite,
                ]
            case .music:
                [.title, .artist, .album, .year, .genre, .duration, .explicit, .lossless, .playCount, .favorite]
            }
        }
    }

    public var type: SmartValueType {
        switch self {
        case .title, .contentRating, .genre, .cast, .director, .show, .artist, .album: .text
        case .year, .runtime, .playCount, .season, .episode, .duration: .number
        case .hdr, .uhd, .watched, .favorite, .explicit, .lossless: .boolean
        }
    }

    /// Read from the list owner's own plays and favorites, so a collection has none.
    public var isPersonal: Bool { [.watched, .playCount, .favorite].contains(self) }

    public var label: String {
        switch self {
        case .title: "Title"
        case .year: "Year"
        case .runtime: "Runtime"
        case .contentRating: "Content rating"
        case .genre: "Genre"
        case .cast: "Cast"
        case .director: "Director"
        case .hdr: "HDR"
        case .uhd: "4K"
        case .watched: "Watched"
        case .playCount: "Plays"
        case .favorite: "Favorite"
        case .show: "Show"
        case .season: "Season"
        case .episode: "Episode"
        case .artist: "Artist"
        case .album: "Album"
        case .duration: "Duration"
        case .explicit: "Explicit"
        case .lossless: "Lossless"
        }
    }

    /// Shown after a number's field.
    public var unit: String? {
        switch self {
        case .runtime: "min"
        case .duration: "s"
        default: nil
        }
    }

    /// Values a text field offers to fill in: the rating scale of the scope's titles.
    public func suggestions(_ scope: SmartScope) -> [String] {
        guard self == .contentRating else { return [] }
        return scope == .playlist(.tv)
            ? Components.Schemas.TvRating.allCases.map(\.rawValue)
            : Components.Schemas.MovieRating.allCases.map(\.rawValue)
    }
}

extension SmartOperator {
    public static func choices(_ type: SmartValueType) -> [SmartOperator] {
        switch type {
        case .text: [._is, .isNot, .contains, .notContains, .startsWith, .endsWith]
        case .number: [._is, .isNot, .lt, .le, .gt, .ge]
        case .boolean: [.isTrue, .isFalse]
        }
    }

    public func label(for field: SmartField) -> String {
        if field.type == .number, let symbol = [Self._is: "=", .isNot: "≠"][self] { return symbol }
        return Self.labels[self] ?? rawValue
    }

    private static let labels: [SmartOperator: String] = [
        ._is: "is", .isNot: "is not", .contains: "contains", .notContains: "does not contain",
        .startsWith: "starts with", .endsWith: "ends with", .lt: "less than", .le: "at most", .gt: "more than",
        .ge: "at least", .isTrue: "Yes", .isFalse: "No",
    ]
}

/// One row of the editor: [field] [operator] [value].
public struct SmartConditionDraft: Identifiable, Hashable, Sendable {
    public let id = UUID()
    /// Setting it puts the operator back to its type's first and clears a value of another type.
    public var field: SmartField {
        didSet {
            op = SmartOperator.choices(field.type)[0]
            if field.type != oldValue.type { value = "" }
        }
    }
    public var op: SmartOperator
    /// The text, or a number's digits; a boolean has none.
    public var value = ""

    public init(field: SmartField) {
        self.field = field
        op = SmartOperator.choices(field.type)[0]
    }
}

public struct SmartGroupDraft: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var match = SmartMatch.all
    public var conditions: [SmartConditionDraft]
}
