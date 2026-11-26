import Foundation
import RabbitEarsAPI
import XCTest

@testable import RabbitEarsKit

final class PinEntryTests: XCTestCase {
    func testTakesFourDigitsAndIgnoresTheRest() {
        var entry = PinEntry()
        XCTAssertFalse(entry.type("1"))
        XCTAssertFalse(entry.type("x"))
        XCTAssertFalse(entry.type("2"))
        XCTAssertEqual(entry.accessibilityLabel, "PIN, 2 of 4 digits entered")
        XCTAssertFalse(entry.type("3"))
        XCTAssertTrue(entry.type("4"))
        XCTAssertFalse(entry.type("5"))
        XCTAssertEqual(entry.digits, "1234")
        entry.deleteBackward()
        XCTAssertEqual(entry.digits, "123")
    }
}

final class AddKidFormTests: XCTestCase {
    let today = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!

    func testSubmitTitleNamesTheKid() {
        var form = AddKidForm(today: today)
        XCTAssertEqual(form.submitTitle, "Add kid")
        form.name = "  Robin "
        XCTAssertEqual(form.submitTitle, "Add Robin")
    }

    func testValidatesNameBirthdayAndPin() {
        var form = AddKidForm(today: today)
        form.birthday = today.addingTimeInterval(86400 * 2)
        form.requirePin = true
        form.pin = "12a4"
        let errors = form.errors
        XCTAssertEqual(errors[.name], "Enter a name.")
        XCTAssertEqual(errors[.birthday], "Birthday can't be in the future.")
        XCTAssertEqual(errors[.pin], "Use four digits.")
        form.name = "Robin"
        form.birthday = today
        form.pin = "1234"
        form.pinConfirmation = "1235"
        XCTAssertEqual(form.errors, [.pin: "PINs don't match."])
        form.pinConfirmation = "1234"
        XCTAssertTrue(form.errors.isEmpty)
    }

    func testBuildsTheProfileInputAsADateWithoutTimeZone() {
        var form = AddKidForm(today: today)
        form.name = "Robin"
        var parts = DateComponents(year: 2017, month: 8, day: 19, hour: 0)
        parts.calendar = Calendar(identifier: .gregorian)
        form.birthday = parts.date!
        form.movieCeiling = .pg
        form.tvCeiling = .tvPg
        let input = form.input
        XCTAssertEqual(input.birthday, "2017-08-19")
        XCTAssertEqual(AddKidForm.day("2017-08-19"), parts.date)
        XCTAssertNil(AddKidForm.day("soon"))
        XCTAssertEqual(input.filterMode, .ratings)
        XCTAssertEqual(input.movieCeiling, .pg)
        form.filterMode = .allowList
        XCTAssertNil(form.input.movieCeiling)
    }

    func testSuggestionFillsCeilingsUntilEditedByHand() {
        var form = AddKidForm(today: today)
        form.name = "Robin"
        let suggestion = Components.Schemas.CeilingSuggestion(age: 9, movieCeiling: .pg, tvCeiling: .tvPg)
        form.apply(suggestion)
        XCTAssertEqual(form.movieCeiling, .pg)
        XCTAssertEqual(form.hint, "Robin is 9. Suggested: movies up to PG, TV up to TV-PG.")
        form.movieCeiling = .g
        form.ceilingsEdited = true
        form.apply(Components.Schemas.CeilingSuggestion(age: 12, movieCeiling: .pg13, tvCeiling: .tvPg))
        XCTAssertEqual(form.movieCeiling, .g)
    }
}

final class NewPasswordTests: XCTestCase {
    func testShortAndMismatchedPasswordsSayWhyOnceTyped() {
        XCTAssertNil(NewPassword("", confirmation: "").passwordError)
        XCTAssertFalse(NewPassword("", confirmation: "").isValid)
        let short = NewPassword("short", confirmation: "shorter")
        XCTAssertEqual(short.passwordError, "Use at least 12 characters.")
        XCTAssertEqual(short.confirmationError, "Passwords don't match.")
        XCTAssertFalse(short.isValid)
        XCTAssertFalse(NewPassword("twelve chars", confirmation: "").isValid)
        let good = NewPassword("twelve chars", confirmation: "twelve chars")
        XCTAssertNil(good.passwordError)
        XCTAssertNil(good.confirmationError)
        XCTAssertTrue(good.isValid)
    }
}
