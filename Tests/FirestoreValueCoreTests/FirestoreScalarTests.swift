import Foundation
import XCTest
@testable import FirestoreValueCore

/// A Firestore boolean reaches Godot as a bool and an integer as an int, 0 and 1 included. The
/// inputs are the NSNumbers Firestore builds: `numberWithBool:` and `numberWithLongLong:`.
final class FirestoreScalarTests: XCTestCase {
    func test_a_boolean_number_is_a_bool() {
        XCTAssertEqual(FirestoreScalar(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(FirestoreScalar(NSNumber(value: false)), .bool(false))
    }

    func test_a_swift_bool_is_a_bool() {
        XCTAssertEqual(FirestoreScalar(true), .bool(true))
    }

    func test_the_integers_zero_and_one_stay_ints() {
        XCTAssertEqual(FirestoreScalar(NSNumber(value: Int64(1))), .int(1))
        XCTAssertEqual(FirestoreScalar(NSNumber(value: Int64(0))), .int(0))
        XCTAssertEqual(FirestoreScalar(1), .int(1))
    }

    func test_a_fraction_is_a_double() {
        XCTAssertEqual(FirestoreScalar(NSNumber(value: 1.5)), .double(1.5))
    }

    func test_a_value_that_is_not_a_number_has_no_scalar() {
        XCTAssertNil(FirestoreScalar("true"))
        XCTAssertNil(FirestoreScalar(NSNull()))
        XCTAssertNil(FirestoreScalar(["enabled": true]))
    }
}
