import XCTest
@testable import ScreenTimeCore

/// The window arithmetic every evaluation stands on: local days, ISO weekdays, overnight periods
/// and instants rounded outward.
final class RestrictionTimeTests: XCTestCase {
    func test_iso_weekdays_start_on_monday() {
        XCTAssertEqual(RestrictionTime.isoWeekday(of: at(2026, 10, 12, 12, 0), calendar: testCalendar), 1)
        XCTAssertEqual(RestrictionTime.isoWeekday(of: at(2026, 10, 18, 12, 0), calendar: testCalendar), 7)
    }

    func test_an_overnight_period_holds_across_midnight_from_its_start_day() {
        let window = RestrictionWindow.daily(weekdays: [1], startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertEqual(RestrictionTime.periodEnd(window, at: at(2026, 10, 12, 23, 0), calendar: testCalendar),
                       at(2026, 10, 13, 7, 0))
        XCTAssertEqual(RestrictionTime.periodEnd(window, at: at(2026, 10, 13, 6, 59), calendar: testCalendar),
                       at(2026, 10, 13, 7, 0))
        XCTAssertNil(RestrictionTime.periodEnd(window, at: at(2026, 10, 13, 7, 0), calendar: testCalendar))
        XCTAssertNil(RestrictionTime.periodEnd(window, at: at(2026, 10, 12, 21, 59), calendar: testCalendar))
    }

    func test_a_weekday_the_window_leaves_out_starts_no_period() {
        let overnight = RestrictionWindow.daily(weekdays: [1], startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertNil(RestrictionTime.periodEnd(overnight, at: at(2026, 10, 13, 23, 0), calendar: testCalendar))
        XCTAssertNil(RestrictionTime.periodEnd(overnight, at: at(2026, 10, 12, 3, 0), calendar: testCalendar))
        let workdays = RestrictionWindow.daily(weekdays: [1, 2, 3, 4, 5], startMinute: 9 * 60, endMinute: 17 * 60)
        XCTAssertNil(RestrictionTime.periodEnd(workdays, at: at(2026, 10, 17, 10, 0), calendar: testCalendar))
        XCTAssertEqual(RestrictionTime.periodEnd(workdays, at: at(2026, 10, 16, 10, 0), calendar: testCalendar),
                       at(2026, 10, 16, 17, 0))
    }

    func test_once_instants_round_outward_to_whole_minutes() {
        let window = RestrictionWindow.once(startUnix: at(2026, 10, 12, 10, 0, 30), endUnix: at(2026, 10, 12, 10, 20, 10))
        XCTAssertEqual(RestrictionTime.periodEnd(window, at: at(2026, 10, 12, 10, 0, 5), calendar: testCalendar),
                       at(2026, 10, 12, 10, 21))
        XCTAssertNotNil(RestrictionTime.periodEnd(window, at: at(2026, 10, 12, 10, 20, 30), calendar: testCalendar))
        XCTAssertNil(RestrictionTime.periodEnd(window, at: at(2026, 10, 12, 10, 21), calendar: testCalendar))
    }

    func test_a_suspended_slot_is_due_nowhere_until_its_suspension_ends() {
        var record = SlotRecord(spec: onceSpec(at(2026, 10, 12, 10, 0), at(2026, 10, 12, 12, 0)))
        record.suspendedUntil = at(2026, 10, 12, 11, 0)
        XCTAssertFalse(RestrictionEvaluator.isDue(record, at: at(2026, 10, 12, 10, 30), calendar: testCalendar))
        XCTAssertTrue(RestrictionEvaluator.isDue(record, at: at(2026, 10, 12, 11, 0), calendar: testCalendar))
    }

    func test_a_retained_part_holds_beside_its_slot_until_its_instant_and_not_after() {
        let until = at(2026, 10, 12, 12, 0)
        let retained = RetainedBlock(block: RestrictionBlock(mode: .blockSelection, selectionId: "kept"), untilUnix: until)
        let record = SlotRecord(spec: onceSpec(at(2026, 10, 12, 10, 0), at(2026, 10, 12, 11, 0), mode: .blockSelection,
                                               list: "now", retained: retained))
        let during = RestrictionEvaluator.dueBlocks(slotId: "a", record: record, at: at(2026, 10, 12, 10, 30), calendar: testCalendar)
        XCTAssertEqual(during.map(\.block.selectionId), ["now", "kept"])
        let after = RestrictionEvaluator.dueBlocks(slotId: "a", record: record, at: at(2026, 10, 12, 11, 30), calendar: testCalendar)
        XCTAssertEqual(after.map(\.block.selectionId), ["kept"])
        XCTAssertEqual(RestrictionEvaluator.holdsUntil(record, at: at(2026, 10, 12, 10, 30), calendar: testCalendar), until)
        XCTAssertTrue(RestrictionEvaluator.dueBlocks(slotId: "a", record: record, at: until, calendar: testCalendar).isEmpty)
    }

    func test_a_window_shorter_than_the_platform_minimum_is_padded() {
        XCTAssertTrue(RestrictionEvaluator.isPadded(onceSpec(0, 600), minimumSeconds: 900))
        XCTAssertFalse(RestrictionEvaluator.isPadded(onceSpec(0, 900), minimumSeconds: 900))
        XCTAssertTrue(RestrictionEvaluator.isPadded(dailySpec([1], 1435, 5), minimumSeconds: 900))
        XCTAssertFalse(RestrictionEvaluator.isPadded(dailySpec([1], 1430, 5), minimumSeconds: 900))
    }

    func test_the_spec_parser_refuses_every_malformed_shape() {
        let valid = onceSpec(100, 1000).jsonObject
        XCTAssertNotNil(RestrictionSpec.parse(valid))
        var retainNull = valid
        retainNull["retain"] = NSNull()
        XCTAssertNil(RestrictionSpec.parse(retainNull))
        var sameEnds = valid
        sameEnds["window"] = ["daily": ["weekdays": [1], "start_minute": 60, "end_minute": 60]]
        XCTAssertNil(RestrictionSpec.parse(sameEnds))
        var noList = valid
        noList["mode"] = "block_selection"
        XCTAssertNil(RestrictionSpec.parse(noList))
        var badDay = valid
        badDay["window"] = ["daily": ["weekdays": [8], "start_minute": 60, "end_minute": 120]]
        XCTAssertNil(RestrictionSpec.parse(badDay))
        var twoWindows = valid
        twoWindows["window"] = ["once": ["start_unix": 1, "end_unix": 2], "daily": [:]]
        XCTAssertNil(RestrictionSpec.parse(twoWindows))
        var backwards = valid
        backwards["window"] = ["once": ["start_unix": 5, "end_unix": 5]]
        XCTAssertNil(RestrictionSpec.parse(backwards))
    }

    func test_a_window_key_an_older_side_does_not_know_is_ignored() {
        var spec = onceSpec(100, 1000).jsonObject
        spec["window"] = ["once": ["start_unix": 100, "end_unix": 1000], "zone": "added later"]
        XCTAssertEqual(RestrictionSpec.parse(spec)?.window, .once(startUnix: 100, endUnix: 1000))
        spec["window"] = ["zone": "added later"]
        XCTAssertNil(RestrictionSpec.parse(spec), "a window still needs one of its two shapes")
    }

    func test_a_spec_reads_back_with_whole_numbers_and_empty_ids() {
        let parsed = RestrictionSpec.parse(WireJSON.object(
            #"{"mode":"block_all","window":{"once":{"start_unix":10.0,"end_unix":20}},"generation":3.0,"exempt":["call"]}"#))
        XCTAssertEqual(parsed?.generation, 3)
        XCTAssertEqual(parsed?.window, .once(startUnix: 10, endUnix: 20))
        let echoed = parsed!.jsonObject
        XCTAssertEqual(echoed["selection_id"] as? String, "")
        XCTAssertEqual(echoed["appearance_id"] as? String, "")
        XCTAssertEqual(echoed["exempt"] as? [String], ["call"])
    }
}
