import XCTest
@testable import ScreenTimeCore

/// The windows that wake the enforcer: release windows from real ends, nothing starting at now,
/// daily times paired two to a window, the roll past 32 times, and the boundary a callback stands for.
final class WakePlannerTests: XCTestCase {
    let now = at(2026, 10, 12, 10, 0)

    func plan(_ slots: [String: RestrictionSpec], now: Int? = nil) -> [PlannedWindow] {
        WakePlanner.plan(slots: slots.mapValues { SlotRecord(spec: $0) }, now: now ?? self.now, calendar: testCalendar)
    }

    func dailySlots(_ pairs: [(Int, Int)], weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]) -> [String: RestrictionSpec] {
        var slots: [String: RestrictionSpec] = [:]
        for (index, pair) in pairs.enumerated() {
            slots["d\(index)"] = dailySpec(weekdays, pair.0, pair.1)
        }
        return slots
    }

    func boundaries(_ windows: [PlannedWindow]) -> [Int] {
        windows.flatMap { [$0.startMinute, $0.endMinute] }
    }

    func forwardMinutes(_ window: PlannedWindow) -> Int {
        ((window.endMinute - window.startMinute) % 1440 + 1440) % 1440
    }

    func test_a_once_slots_end_is_a_release_window_starting_at_the_real_end_and_its_start_gets_one_too() {
        let start = now + 600
        let end = now + 3000 + 20
        let windows = plan(["one": onceSpec(start, end)])
        let release = windows.first { $0.kind == PlannedWindow.release }!
        XCTAssertEqual(release.startUnix, RestrictionTime.ceilMinute(end))
        XCTAssertEqual(release.endUnix - release.startUnix, WakePlanner.minimumWindowSeconds)
        let opening = windows.first { $0.kind == PlannedWindow.start }!
        XCTAssertEqual(opening.startUnix, start)
        XCTAssertTrue(windows.allSatisfy { WakePlanner.registrable($0, now: now) })
    }

    func test_no_window_starts_at_now() {
        XCTAssertFalse(plan(["one": onceSpec(now - 600, now)]).contains { WakePlanner.registrable($0, now: now) },
                       "a block ending now is lifted by the write itself, not by a window")
        let late = now + 57
        XCTAssertFalse(plan(["one": onceSpec(now - 600, late + 2)], now: late).contains { WakePlanner.registrable($0, now: late) },
                       "a release window starting within the lead is not registered")
    }

    func test_a_running_window_stays_wanted_until_its_end_so_its_end_still_wakes() {
        let end = now - 60
        let windows = plan(["one": onceSpec(now - 3600, end)])
        XCTAssertEqual(windows.map(\.kind), [PlannedWindow.release])
        XCTAssertFalse(WakePlanner.registrable(windows[0], now: now))
        XCTAssertTrue(plan(["one": onceSpec(now - 3600, end)], now: end + 900).isEmpty, "an ended window is no longer wanted")
    }

    func test_a_short_blocks_windows_never_meet_at_one_instant() {
        let windows = plan(["one": onceSpec(now + 60, now + 660)])
        XCTAssertEqual(windows.count, 2)
        let starts = Set(windows.map(\.startUnix))
        XCTAssertTrue(windows.allSatisfy { !starts.contains($0.endUnix) })
    }

    func test_a_retained_ends_once_slot_gets_a_release_window_at_each_lift() {
        let retained = RetainedBlock(block: RestrictionBlock(mode: .blockSelection, selectionId: "kept"), untilUnix: now + 7200)
        let windows = plan(["one": onceSpec(now - 60, now + 3600, retained: retained)])
        XCTAssertEqual(Set(windows.filter { $0.kind == PlannedWindow.release }.map(\.startUnix)), [now + 3600, now + 7200])
    }

    func test_daily_times_pair_into_windows_of_at_least_fifteen_minutes_each_time_once() {
        let times = [(22 * 60, 7 * 60), (22 * 60 + 5, 7 * 60 + 10), (12 * 60, 12 * 60 + 1)]
        let windows = plan(dailySlots(times))
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(boundaries(windows).sorted(), times.flatMap { [$0.0, $0.1] }.sorted())
        XCTAssertTrue(windows.allSatisfy { $0.repeats && forwardMinutes($0) >= 15 })
    }

    func test_an_overnight_periods_two_times_share_one_window_with_no_split_at_midnight() {
        let windows = plan(dailySlots([(22 * 60, 7 * 60)]))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(Set(boundaries(windows)), [22 * 60, 7 * 60])
    }

    func test_an_odd_time_out_takes_a_free_minute_fifteen_minutes_on() {
        let slots = ["a": dailySpec([1], 600, 700), "b": dailySpec([1], 600, 800)]
        let windows = plan(slots)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(Set(boundaries(windows)).count, 4)
        XCTAssertTrue(boundaries(windows).contains(715))
    }

    func test_sixteen_windows_serve_thirty_two_times_whatever_the_days() {
        var pairs: [(Int, Int)] = []
        for index in 0..<16 {
            pairs.append((index * 40, index * 40 + 20))
        }
        let windows = plan(dailySlots(pairs, weekdays: [3]))
        XCTAssertEqual(windows.count, 16)
        XCTAssertTrue(windows.allSatisfy(\.repeats))
        XCTAssertEqual(Set(boundaries(windows)).count, 32)
    }

    func test_past_thirty_two_times_twelve_daily_windows_keep_the_most_used_and_four_roll_the_next() {
        var slots: [String: RestrictionSpec] = [:]
        for index in 0..<12 {
            slots["busy\(index)"] = dailySpec([1, 2, 3, 4, 5, 6, 7], index * 60, index * 60 + 30)
        }
        for index in 0..<6 {
            slots["rare\(index)"] = dailySpec([2], 13 * 60 + index * 90, 13 * 60 + index * 90 + 45)
        }
        let windows = plan(slots)
        let daily = windows.filter(\.repeats)
        let rolled = windows.filter { !$0.repeats }
        XCTAssertEqual(daily.count, 12)
        XCTAssertEqual(rolled.count, 4)
        var busyTimes = Set<Int>()
        for index in 0..<12 {
            busyTimes.formUnion([index * 60, index * 60 + 30])
        }
        XCTAssertEqual(Set(boundaries(daily)), busyTimes)
        XCTAssertTrue(rolled.allSatisfy { $0.kind == PlannedWindow.roll && $0.startUnix > now })
        let tuesday = RestrictionTime.dayStart(now, days: 1, calendar: testCalendar)
        XCTAssertEqual(rolled.map(\.startUnix).min(), RestrictionTime.instant(dayStart: tuesday, minute: 13 * 60, calendar: testCalendar))
        let wakes = Set(rolled.flatMap { [$0.startUnix, $0.endUnix] })
        var rareTimes: [Int] = []
        for index in 0..<4 {
            let start: Int = 13 * 60 + index * 90
            rareTimes += [start, start + 45]
        }
        for minute in rareTimes {
            XCTAssertTrue(wakes.contains(RestrictionTime.instant(dayStart: tuesday, minute: minute, calendar: testCalendar)),
                          "the next eight missed times each get a wake")
        }
    }

    func test_clustered_rolling_times_still_each_get_a_wake_where_they_can() {
        let windows = WakePlanner.pairOnce([0, 60, 120, 180, 1000, 1060, 1120, 1180].map { now + 3600 + $0 })
        XCTAssertEqual(windows.count, 4)
        XCTAssertEqual(Set(windows.flatMap { [$0.startUnix, $0.endUnix] }).count, 8)
        XCTAssertTrue(windows.allSatisfy { $0.endUnix - $0.startUnix >= WakePlanner.minimumWindowSeconds })
    }

    func test_a_retained_parts_end_stays_among_the_wakes_until_it_passes() {
        let until = at(2026, 10, 12, 23, 30)
        let retained = RetainedBlock(block: RestrictionBlock(mode: .blockAll), untilUnix: until)
        let slots = ["night": dailySpec([1], 22 * 60, 23 * 60, retained: retained)]
        XCTAssertTrue(boundaries(plan(slots)).contains(23 * 60 + 30))
        XCTAssertFalse(boundaries(plan(slots, now: until + 60)).contains(23 * 60 + 30))
    }

    func test_a_once_window_landing_on_a_daily_wake_gives_way_to_it() {
        let end = at(2026, 10, 12, 22, 0)
        let slots = ["night": dailySpec([1], 22 * 60, 7 * 60), "once": onceSpec(now - 60, end)]
        XCTAssertFalse(plan(slots).contains { !$0.repeats && $0.startUnix == end })
    }

    func test_a_callback_stands_for_its_boundary_only_within_sixty_seconds() {
        let window = PlannedWindow.once(PlannedWindow.release, start: now + 3600, end: now + 4500)
        XCTAssertEqual(WakePlanner.evaluationInstant(window: window, isEnd: true, now: now + 4499, calendar: testCalendar), now + 4500,
                       "an end a second early is the last wake before its boundary")
        XCTAssertEqual(WakePlanner.evaluationInstant(window: window, isEnd: true, now: now + 3600, calendar: testCalendar), now + 3600,
                       "a stop's echo far from the end evaluates at the clock")
        XCTAssertEqual(WakePlanner.evaluationInstant(window: window, isEnd: false, now: now + 3602, calendar: testCalendar), now + 3602)
        XCTAssertEqual(WakePlanner.evaluationInstant(window: window, isEnd: false, now: now + 3540, calendar: testCalendar), now + 3600)
    }

    func test_a_daily_callback_stands_for_the_nearest_occurrence_of_its_minute() {
        let window = PlannedWindow.daily(start: 23 * 60 + 59, end: 0)
        let justBefore = at(2026, 10, 12, 23, 59, 59)
        XCTAssertEqual(WakePlanner.evaluationInstant(window: window, isEnd: true, now: justBefore, calendar: testCalendar),
                       at(2026, 10, 13, 0, 0))
    }
}
