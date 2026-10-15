import Foundation

/// One monitored window. A window only wakes the enforcer at its start and its end: every wake
/// derives every block again from the store and the clock, so no window owns a block.
public struct PlannedWindow: Codable, Equatable, Sendable {
    public static let release = "release"
    public static let start = "start"
    public static let wake = "wake"
    public static let roll = "roll"

    public var kind: String
    public var repeats: Bool
    /// Instants of a window that does not repeat.
    public var startUnix: Int
    public var endUnix: Int
    /// Minutes after local midnight of a window that repeats daily; an end below the start runs
    /// into the next day.
    public var startMinute: Int
    public var endMinute: Int

    public static func once(_ kind: String, start: Int, end: Int) -> PlannedWindow {
        PlannedWindow(kind: kind, repeats: false, startUnix: start, endUnix: end, startMinute: 0, endMinute: 0)
    }

    public static func daily(start: Int, end: Int) -> PlannedWindow {
        PlannedWindow(kind: wake, repeats: true, startUnix: 0, endUnix: 0, startMinute: start, endMinute: end)
    }

    /// Whether two windows ask the system for the same thing, whatever they are for.
    public func sameInterval(_ other: PlannedWindow) -> Bool {
        repeats == other.repeats && (repeats
            ? startMinute == other.startMinute && endMinute == other.endMinute
            : startUnix == other.startUnix && endUnix == other.endUnix)
    }
}

/// Turns the slots into the windows that wake the enforcer at every instant a block must change on
/// time. Every such instant is a window's START: starts arrive seconds late and never early, while
/// ends and warnings are unmeasured, and a window starting as it is registered is unreliable.
public enum WakePlanner {
    public static let minimumWindowSeconds = 900
    /// The monitored windows the system allows an app and its extensions together.
    public static let windowBudget = 20
    /// Daily windows pair two wake times each, so sixteen serve 32 times.
    public static let dailyWindowCeiling = 16
    public static let rolledDailyWindows = 12
    public static let rollingWindows = 4
    /// No new window starts closer to now than this.
    public static let leadSeconds = 5
    /// A callback stands for its window's boundary only this close to it; further off it is the echo
    /// of a stop, a late delivery or a moved clock, and the clock rules.
    public static let boundaryToleranceSeconds = 60

    /// Every window wanted at `now`: a release window from each end of a `once` slot, a window from
    /// a `once` slot's start while it lies ahead, and daily wake windows for every `daily` time.
    /// A window already running stays wanted until its end, so its end still wakes; only a window
    /// not yet registered must start ahead of now (`registrable`).
    public static func plan(slots: [String: SlotRecord], now: Int, calendar: Calendar) -> [PlannedWindow] {
        let daily = dailyWindows(slots: slots, now: now, calendar: calendar)
        let dailyTimes = Set(daily.wakes.flatMap { [$0.startMinute, $0.endMinute] })
        var once: [PlannedWindow] = []
        for slotId in slots.keys.sorted() {
            let spec = slots[slotId]!.spec
            guard case let .once(start, end) = spec.window else {
                continue
            }
            var lifts = [RestrictionTime.ceilMinute(end)]
            if let retained = spec.retained {
                lifts.append(RestrictionTime.ceilMinute(retained.untilUnix))
            }
            for lift in Set(lifts) {
                once.append(.once(PlannedWindow.release, start: lift, end: lift + minimumWindowSeconds))
            }
            let opening = RestrictionTime.floorMinute(start)
            once.append(.once(PlannedWindow.start, start: opening, end: opening + minimumWindowSeconds))
        }
        once += daily.rolled
        var starts = Set<Int>()
        var kept: [PlannedWindow] = []
        for window in once.sorted(by: { ($0.startUnix, $0.kind) < ($1.startUnix, $1.kind) }) where window.endUnix > now {
            // A daily wake already lands on this instant, and two windows meeting there misfire.
            let onDailyTime = window.startUnix % 60 == 0
                && dailyTimes.contains(RestrictionTime.minuteOfDay(window.startUnix, calendar: calendar))
            if onDailyTime || !starts.insert(window.startUnix).inserted {
                continue
            }
            kept.append(window)
        }
        for index in kept.indices {
            while starts.contains(kept[index].endUnix)
                || (kept[index].endUnix % 60 == 0
                    && dailyTimes.contains(RestrictionTime.minuteOfDay(kept[index].endUnix, calendar: calendar))) {
                kept[index].endUnix += 60
            }
        }
        return daily.wakes + kept
    }

    /// Whether a window not yet registered may be: one starting at or before now would fire its start
    /// at once, which the system does not do reliably.
    public static func registrable(_ window: PlannedWindow, now: Int) -> Bool {
        window.repeats || window.startUnix > now + leadSeconds
    }

    /// The instant a callback evaluates at: the later of the clock and the boundary it stands for,
    /// but only while the clock is within the tolerance of that boundary, so a stale callback never
    /// stands for a boundary still ahead and lifts a block early.
    public static func evaluationInstant(window: PlannedWindow, isEnd: Bool, now: Int, calendar: Calendar) -> Int {
        let boundary: Int
        if window.repeats {
            let minute = isEnd ? window.endMinute : window.startMinute
            boundary = (-1...1).map {
                RestrictionTime.instant(dayStart: RestrictionTime.dayStart(now, days: $0, calendar: calendar), minute: minute,
                                        calendar: calendar)
            }.min { abs($0 - now) < abs($1 - now) }!
        } else {
            boundary = isEnd ? window.endUnix : window.startUnix
        }
        return abs(now - boundary) <= boundaryToleranceSeconds ? max(now, boundary) : now
    }

    /// The daily wake windows, and when there are more than 32 distinct times, the one-off windows
    /// of the roll.
    static func dailyWindows(slots: [String: SlotRecord], now: Int, calendar: Calendar)
        -> (wakes: [PlannedWindow], rolled: [PlannedWindow]) {
        var weight: [Int: Int] = [:]
        var days: [Int: Set<Int>] = [:]
        var instants: [Int: [Int]] = [:]
        for record in slots.values {
            guard case let .daily(weekdays, start, end) = record.spec.window else {
                continue
            }
            let startDays = Set(weekdays)
            let endDays = end <= start ? Set(startDays.map { $0 % 7 + 1 }) : startDays
            weight[start, default: 0] += startDays.count
            days[start, default: []].formUnion(startDays)
            weight[end, default: 0] += endDays.count
            days[end, default: []].formUnion(endDays)
            // A retained part ends at its period's own end, which an edit may have moved since, so
            // that end stays among the wakes until it passes.
            if let retained = record.spec.retained {
                let until = RestrictionTime.ceilMinute(retained.untilUnix)
                if until > now {
                    let minute = RestrictionTime.minuteOfDay(until, calendar: calendar)
                    weight[minute, default: 0] += 1
                    instants[minute, default: []].append(until)
                }
            }
        }
        let times = weight.keys.sorted()
        if times.count <= dailyWindowCeiling * 2 {
            return (pairDaily(times), [])
        }
        let ranked = times.sorted { weight[$0]! == weight[$1]! ? $0 < $1 : weight[$0]! > weight[$1]! }
        let kept = Array(ranked.prefix(rolledDailyWindows * 2)).sorted()
        var upcoming = Set<Int>()
        for minute in ranked.dropFirst(rolledDailyWindows * 2) {
            for offset in 0...7 {
                let day = RestrictionTime.dayStart(now, days: offset, calendar: calendar)
                guard days[minute, default: []].contains(RestrictionTime.isoWeekday(of: day + 43_200, calendar: calendar)) else {
                    continue
                }
                upcoming.insert(RestrictionTime.instant(dayStart: day, minute: minute, calendar: calendar))
            }
            upcoming.formUnion(instants[minute, default: []])
        }
        let next = upcoming.filter { $0 > now + leadSeconds }.sorted().prefix(rollingWindows * 2)
        return (pairDaily(kept), pairOnce(Array(next)))
    }

    /// Pairs each time with the one half the list later, the earlier of the two as the start when
    /// they are 15 minutes apart that way round and the later one otherwise, so a cluster of times
    /// still gives every time a wake. An odd time out takes a free minute 15 minutes on as its end.
    static func pairDaily(_ times: [Int]) -> [PlannedWindow] {
        let half = (times.count + 1) / 2
        let minimumMinutes = minimumWindowSeconds / 60
        var taken = Set(times)
        var windows: [PlannedWindow] = []
        for index in 0..<half {
            let first = times[index]
            var second: Int
            if index + half < times.count {
                second = times[index + half]
            } else {
                second = (first + minimumMinutes) % RestrictionTime.minutesPerDay
                while taken.contains(second) {
                    second = (second + 1) % RestrictionTime.minutesPerDay
                }
                taken.insert(second)
            }
            let forward = ((second - first) % RestrictionTime.minutesPerDay + RestrictionTime.minutesPerDay) % RestrictionTime.minutesPerDay
            windows.append(forward >= minimumMinutes ? .daily(start: first, end: second) : .daily(start: second, end: first))
        }
        return windows
    }

    /// One-off windows over the roll's upcoming instants: each takes the earliest instant left and,
    /// as its end, the first one 15 minutes after it, or a padded end when none is.
    static func pairOnce(_ instants: [Int]) -> [PlannedWindow] {
        var remaining = instants.sorted()
        var windows: [PlannedWindow] = []
        while !remaining.isEmpty && windows.count < rollingWindows {
            let start = remaining.removeFirst()
            if let index = remaining.firstIndex(where: { $0 >= start + minimumWindowSeconds && $0 - start <= 7 * RestrictionTime.secondsPerDay }) {
                windows.append(.once(PlannedWindow.roll, start: start, end: remaining.remove(at: index)))
            } else {
                windows.append(.once(PlannedWindow.roll, start: start, end: start + minimumWindowSeconds))
            }
        }
        return windows
    }
}
