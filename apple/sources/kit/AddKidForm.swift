import Foundation
import RabbitEarsAPI

/// The Add a kid form, also used to edit a kid: values, validation and the
/// request it becomes.
public struct AddKidForm: Equatable, Sendable {
    public typealias MovieRating = Components.Schemas.MovieRating
    public typealias TvRating = Components.Schemas.TvRating

    public enum Field: Hashable, Sendable { case name, birthday, pin }

    /// The ceilings the form offers; NC-17 is never a kid's ceiling.
    public static let movieRatings: [MovieRating] = [.g, .pg, .pg13, .r]
    public static let tvRatings = TvRating.allCases

    public var name = ""
    public var birthday: Date
    public var filterMode = Components.Schemas.FilterMode.ratings
    public var movieCeiling = MovieRating.pg
    public var tvCeiling = TvRating.tvY7
    public var ceilingsEdited = false
    public var requirePin = false
    public var pin = ""
    public var pinConfirmation = ""
    /// One of `ProfilePalette.colors`; nil lets the server pick a new kid's.
    public var color: String?
    public private(set) var suggestion: Components.Schemas.CeilingSuggestion?
    /// The kid being edited; their PIN stays when the PIN fields are left blank.
    public var editing: Account?
    let today: Date

    public init(today: Date = Date()) {
        self.today = today
        birthday = Calendar.current.date(byAdding: .year, value: -8, to: today) ?? today
    }

    public init(editing kid: Account, today: Date = Date()) {
        self.init(today: today)
        editing = kid
        name = kid.name
        if let day = kid.birthday.flatMap(Self.day) { birthday = day }
        filterMode = kid.filterMode
        movieCeiling = kid.movieCeiling ?? movieCeiling
        tvCeiling = kid.tvCeiling ?? tvCeiling
        ceilingsEdited = true
        requirePin = kid.hasPin
        color = kid.color
    }

    /// Whether saving sets a new PIN, clears the old one, or leaves it.
    public var pinChange: PinChange {
        if requirePin { return pin.isEmpty && editing?.hasPin == true ? .keep : .set(pin) }
        return editing?.hasPin == true ? .clear : .keep
    }

    public enum PinChange: Equatable, Sendable {
        case keep, clear
        case set(String)
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var submitTitle: String {
        if editing != nil { return "Save" }
        return trimmedName.isEmpty ? "Add kid" : "Add \(trimmedName)"
    }

    /// An API date: an ISO 8601 day, Gregorian whatever calendar the device
    /// keeps, in the device's time zone.
    private static var apiDay: Date.ISO8601FormatStyle { .init(timeZone: .current).year().month().day() }

    public var birthdayString: String { birthday.formatted(Self.apiDay) }

    public var errors: [Field: String] {
        var errors: [Field: String] = [:]
        if trimmedName.isEmpty {
            errors[.name] = "Enter a name."
        } else if trimmedName.count > 40 {
            errors[.name] = "Use 40 characters or fewer."
        }
        if Calendar.current.startOfDay(for: birthday) > Calendar.current.startOfDay(for: today) {
            errors[.birthday] = "Birthday can't be in the future."
        }
        if pinChange != .keep, requirePin {
            if pin.count != 4 || !pin.allSatisfy({ $0.isASCII && $0.isNumber }) {
                errors[.pin] = "Use four digits."
            } else if pin != pinConfirmation {
                errors[.pin] = "PINs don't match."
            }
        }
        return errors
    }

    public var input: Components.Schemas.ProfileInput {
        let ratings = filterMode == .ratings
        return .init(
            name: trimmedName, birthday: birthdayString, filterMode: filterMode,
            movieCeiling: ratings ? movieCeiling : nil, tvCeiling: ratings ? tvCeiling : nil, color: color)
    }

    /// Takes the server's suggestion for the birthday unless the ceilings were picked by hand.
    public mutating func apply(_ suggestion: Components.Schemas.CeilingSuggestion) {
        self.suggestion = suggestion
        guard !ceilingsEdited else { return }
        movieCeiling = suggestion.movieCeiling
        tvCeiling = suggestion.tvCeiling
    }

    /// The calendar day an API date names, at local midnight.
    static func day(_ text: String) -> Date? { try? Date(text, strategy: apiDay) }

    public var hint: String? {
        guard let suggestion else { return nil }
        let who = trimmedName.isEmpty ? "They are" : "\(trimmedName) is"
        return "\(who) \(suggestion.age). Suggested: movies up to \(suggestion.movieCeiling.rawValue), "
            + "TV up to \(suggestion.tvCeiling.rawValue)."
    }
}
