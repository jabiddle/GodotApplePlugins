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
    /// A window already running stays wanted until its end, so its end still wakes: every window of
    /// `registered` that does not repeat and holds `now` is wanted as registered, and a new window
    /// meets neither of its bounds. Only a window not yet registered must start ahead of now
    /// (`registrable`).
    public static func plan(slots: [String: SlotRecord], now: Int, calendar: Calendar,
                            registered: [PlannedWindow] = []) -> [PlannedWindow] {
        let running = registered.filter { !$0.repeats && $0.startUnix <= now && now < $0.endUnix }
        let runningEnds = Set(running.map(\.endUnix))
        let daily = dailyWindows(slots: slots, now: now, calendar: calendar, running: running)
        let dailyTimes = Set(daily.wakes.flatMap { [$0.startMinute, $0.endMinute] })
        // A daily wake or a running window's end already lands on the instant, and two windows
        // meeting there misfire.
        let landsOnAWake = { (unix: Int) -> Bool in
            runningEnds.contains(unix)
                || (unix % 60 == 0 && dailyTimes.contains(RestrictionTime.minuteOfDay(unix, calendar: calendar)))
        }
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
        var starts = Set(running.map(\.startUnix))
        var kept: [PlannedWindow] = []
        for var window in once.sorted(by: { ($0.startUnix, $0.kind) < ($1.startUnix, $1.kind) }) where window.endUnix > now {
            if window.kind == PlannedWindow.release {
                // A lift waits on a start, which arrives, never on an end the system may not deliver:
                // a minute late, never early.
                while landsOnAWake(window.startUnix) {
                    window.startUnix += 60
                    window.endUnix += 60
                }
            }
            if running.contains(where: { $0.sameInterval(window) }) {
                continue
            }
            if window.kind != PlannedWindow.release && landsOnAWake(window.startUnix) {
                continue
            }
            // Another window's start wakes here already.
            if !starts.insert(window.startUnix).inserted {
                continue
            }
            kept.append(window)
        }
        for index in kept.indices {
            while starts.contains(kept[index].endUnix) || landsOnAWake(kept[index].endUnix) {
                kept[index].endUnix += 60
            }
        }
        return daily.wakes + running + kept
    }

    /// Whether a window not yet registered may be: one whose start comes within the lead of now,
    /// the next occurrence of a daily window's start included, would start as it is registered,
    /// which the system does not do reliably.
    public static func registrable(_ window: PlannedWindow, now: Int, calendar: Calendar) -> Bool {
        guard window.repeats else {
            return window.startUnix > now + leadSeconds
        }
        var next = RestrictionTime.instant(dayStart: RestrictionTime.dayStart(now, days: 0, calendar: calendar),
                                           minute: window.startMinute, calendar: calendar)
        if next < now {
            next = RestrictionTime.instant(dayStart: RestrictionTime.dayStart(now, days: 1, calendar: calendar),
                                           minute: window.startMinute, calendar: calendar)
        }
        return next > now + leadSeconds
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
    /// of the roll. A running roll window keeps its place among the roll's four and the instant its
    /// end wakes at, so the roll is not planned afresh at every one of its own starts.
    static func dailyWindows(slots: [String: SlotRecord], now: Int, calendar: Calendar, running: [PlannedWindow] = [])
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
        let covered = Set(running.map(\.endUnix))
        let room = max(0, rollingWindows - running.filter { $0.kind == PlannedWindow.roll }.count)
        let next = upcoming.filter { $0 > now + leadSeconds && !covered.contains($0) }.sorted().prefix(room * 2)
        return (pairDaily(kept), pairOnce(Array(next), limit: room))
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
    static func pairOnce(_ instants: [Int], limit: Int = rollingWindows) -> [PlannedWindow] {
        var remaining = instants.sorted()
        var windows: [PlannedWindow] = []
        while !remaining.isEmpty && windows.count < limit {
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
