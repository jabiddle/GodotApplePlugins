import Foundation

/// Local-time arithmetic. A `daily` window is read in the calendar's own time zone, so travel keeps
/// its wall-clock hours; a `once` window is a pair of instants and never moves.
public enum RestrictionTime {
    public static let minutesPerDay = 1440
    public static let secondsPerDay = 86_400

    public static func floorMinute(_ unix: Int) -> Int {
        unix - ((unix % 60) + 60) % 60
    }

    public static func ceilMinute(_ unix: Int) -> Int {
        let floor = floorMinute(unix)
        return floor == unix ? unix : floor + 60
    }

    public static func isoWeekday(of unix: Int, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date(unix))
        return (weekday + 5) % 7 + 1
    }

    public static func minuteOfDay(_ unix: Int, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date(unix))
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The local midnight `days` days after the one that starts the day holding `unix`.
    public static func dayStart(_ unix: Int, days: Int, calendar: Calendar) -> Int {
        let today = calendar.startOfDay(for: date(unix))
        let day = calendar.date(byAdding: .day, value: days, to: today) ?? today
        return Int(day.timeIntervalSince1970)
    }

    /// `minute` after the local midnight `dayStart`; a minute that a clock change skips lands on the
    /// next one that exists.
    public static func instant(dayStart: Int, minute: Int, calendar: Calendar) -> Int {
        let day = date(dayStart)
        let moment = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
            ?? day.addingTimeInterval(TimeInterval(minute * 60))
        return Int(moment.timeIntervalSince1970)
    }

    /// The end of the period `window` holds at `unix`, or nil when it holds none. `once` instants are
    /// rounded outward to whole minutes, so a block never lifts before the minute it was asked to.
    public static func periodEnd(_ window: RestrictionWindow, at unix: Int, calendar: Calendar) -> Int? {
        switch window {
        case let .once(start, end):
            let lower = floorMinute(start)
            let upper = ceilMinute(end)
            return lower <= unix && unix < upper ? upper : nil
        case let .daily(weekdays, startMinute, endMinute):
            for offset in [-1, 0] {
                let day = dayStart(unix, days: offset, calendar: calendar)
                guard weekdays.contains(isoWeekday(of: day + 43_200, calendar: calendar)) else {
                    continue
                }
                let periodStart = instant(dayStart: day, minute: startMinute, calendar: calendar)
                let endDay = endMinute <= startMinute ? dayStart(day + 43_200, days: 1, calendar: calendar) : day
                let periodEnd = instant(dayStart: endDay, minute: endMinute, calendar: calendar)
                if periodStart <= unix && unix < periodEnd {
                    return periodEnd
                }
            }
            return nil
        }
    }

    static func date(_ unix: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(unix))
    }
}

/// A block one slot asks for at an instant, with the key of the list store it rides.
public struct DueBlock: Equatable, Sendable {
    public var slotId: String
    public var block: RestrictionBlock
    public var retained: Bool
    /// A retained list rides the store of its slot's own list, so folding a list into it never moves
    /// apps out of a store that holds them.
    public var listKey: String
}

public enum RestrictionEvaluator {
    /// Nothing while suspended; the slot's own block while its window holds; its retained part until
    /// that part's instant, rounded up to a whole minute.
    public static func dueBlocks(slotId: String, record: SlotRecord, at unix: Int, calendar: Calendar) -> [DueBlock] {
        if unix < record.suspendedUntil {
            return []
        }
        let spec = record.spec
        let ownKey = spec.block.mode == .blockSelection ? spec.block.selectionId : ""
        var blocks: [DueBlock] = []
        if RestrictionTime.periodEnd(spec.window, at: unix, calendar: calendar) != nil {
            blocks.append(DueBlock(slotId: slotId, block: spec.block, retained: false, listKey: ownKey))
        }
        if let retained = spec.retained, unix < RestrictionTime.ceilMinute(retained.untilUnix) {
            let key = ownKey.isEmpty ? retained.block.selectionId : ownKey
            blocks.append(DueBlock(slotId: slotId, block: retained.block, retained: true, listKey: key))
        }
        return blocks
    }

    /// What a slot the stores held at the last write, planned for `heldAt`, held then. That write read
    /// a `daily` window in its own calendar, so where the calendar read now places none of the
    /// slot's blocks at that instant, as after a time-zone change, its own block is what they held.
    public static func heldBlocks(slotId: String, record: SlotRecord, at heldAt: Int, calendar: Calendar) -> [DueBlock] {
        let blocks = dueBlocks(slotId: slotId, record: record, at: heldAt, calendar: calendar)
        guard blocks.isEmpty, case .daily = record.spec.window, heldAt >= record.suspendedUntil else {
            return blocks
        }
        let block = record.spec.block
        return [DueBlock(slotId: slotId, block: block, retained: false,
                         listKey: block.mode == .blockSelection ? block.selectionId : "")]
    }

    public static func isDue(_ record: SlotRecord, at unix: Int, calendar: Calendar) -> Bool {
        !dueBlocks(slotId: "", record: record, at: unix, calendar: calendar).isEmpty
    }

    /// When the slot's block stops holding as it reads at `unix`: its period's end, or its retained
    /// part's instant when that is later.
    public static func holdsUntil(_ record: SlotRecord, at unix: Int, calendar: Calendar) -> Int {
        var end = RestrictionTime.periodEnd(record.spec.window, at: unix, calendar: calendar) ?? 0
        if let retained = record.spec.retained, unix < RestrictionTime.ceilMinute(retained.untilUnix) {
            end = max(end, RestrictionTime.ceilMinute(retained.untilUnix))
        }
        return end
    }

    /// The window is shorter than the shortest one the platform monitors.
    public static func isPadded(_ spec: RestrictionSpec, minimumSeconds: Int) -> Bool {
        switch spec.window {
        case let .once(start, end):
            return end - start < minimumSeconds
        case let .daily(_, start, end):
            let minutes = ((end - start) % RestrictionTime.minutesPerDay + RestrictionTime.minutesPerDay) % RestrictionTime.minutesPerDay
            return minutes * 60 < minimumSeconds
        }
    }
}

/// How a store shields categories: none, every app but some, or some categories but some apps.
public enum CategoryShield<App: Hashable, Category: Hashable>: Equatable {
    case none
    case all(except: Set<App>)
    case specific(Set<Category>, except: Set<App>)
}

/// One named store's shield fields, as written and as read back.
public struct ShieldContents<App: Hashable, Category: Hashable, Web: Hashable>: Equatable {
    public var apps: Set<App>
    public var categories: CategoryShield<App, Category>
    public var webDomains: Set<Web>
    public var allWebDomains: Bool

    public init(apps: Set<App> = [], categories: CategoryShield<App, Category> = .none, webDomains: Set<Web> = [],
                allWebDomains: Bool = false) {
        self.apps = apps
        self.categories = categories
        self.webDomains = webDomains
        self.allWebDomains = allWebDomains
    }

    public var isEmpty: Bool {
        apps.isEmpty && categories == .none && webDomains.isEmpty && !allWebDomains
    }

    /// Whether these contents, read back after `written`, lack a field the write set. The system
    /// answers a field it took none of with nil, as past a cap, while the other fields still read
    /// back, so a store that is not empty can still have refused part of a write.
    public func lacksAField(of written: Self) -> Bool {
        (!written.apps.isEmpty && apps.isEmpty) || (written.categories != .none && categories == .none)
            || (!written.webDomains.isEmpty && webDomains.isEmpty) || (written.allWebDomains && !allWebDomains)
    }

    /// A shield on everything a store can shield, for the block-then-unblock of a rebuild.
    public static var everything: Self {
        Self(categories: .all(except: []), allWebDomains: true)
    }
}

/// The fixed, short set of store names. Nothing lists an app's stores before iOS 26.5, so a rebuild
/// can only reach a store whose name it already knows.
public enum ShieldStoreName {
    public static let all = "all"
    public static let web = "web"
    public static let lists: [String] = (1...8).map { "list\($0)" }
    public static let fixedSet: [String] = [all, web] + lists
    /// Holds one setting that restricts nothing; outside the fixed set, so no rebuild clears it.
    public static let marker = "marker"
}

public struct ShieldPlan<App: Hashable, Category: Hashable, Web: Hashable> {
    /// Non-empty stores only; every other name in the fixed set is to be empty.
    public var stores: [String: ShieldContents<App, Category, Web>] = [:]
    /// Each due slot whose blocks the plan shields, to the stores that hold them.
    public var storesBySlot: [String: Set<String>] = [:]
    public var dueSlots: Set<String> = []
    /// Slots that shield less than they ask, because a list was dropped to stay under a cap.
    public var cappedSlots: Set<String> = []
    /// Each due list's key to its store name; a key keeps its name while it stays due.
    public var listNames: [String: String] = [:]
}

/// What every due block asks for at an instant, written as a few named stores: one of all apps
/// while any block of all apps is due, else one per due list, and the lists' websites in a store of
/// their own while all apps are shielded, because a shield of all apps covers no website.
public struct ShieldPlanner<App: Hashable, Category: Hashable, Web: Hashable> {
    public typealias Selection = TokenSelection<App, Category, Web>
    public typealias Contents = ShieldContents<App, Category, Web>

    /// Apple's per-app cap in each class: apps, categories, websites and excepted apps, summed over
    /// every store, past which a store shields nothing at all.
    public var cap: Int

    public init(cap: Int) {
        self.cap = cap
    }

    public func plan(slots: [String: SlotRecord], at unix: Int, calendar: Calendar, previousNames: [String: String],
                     selection: (String) -> Selection?) -> ShieldPlan<App, Category, Web> {
        var plan = ShieldPlan<App, Category, Web>()
        var due: [DueBlock] = []
        for slotId in slots.keys.sorted() {
            let blocks = RestrictionEvaluator.dueBlocks(slotId: slotId, record: slots[slotId]!, at: unix, calendar: calendar)
            if !blocks.isEmpty {
                plan.dueSlots.insert(slotId)
            }
            due += blocks
        }
        var held: [String: Selection] = [:]
        for id in Set(due.flatMap(\.block.selectionIds)) {
            held[id] = selection(id)
        }
        let lookup = { (id: String) -> Selection in held[id] ?? Selection() }
        let listBlocks = due.filter { $0.block.mode == .blockSelection }
        let allBlocks = due.filter { $0.block.mode == .blockAll }
        plan.listNames = Self.assignNames(keys: Set(listBlocks.map(\.listKey)), previous: previousNames)
        let keys = plan.listNames.keys.sorted { Self.order(plan.listNames, $0, $1) }
        var used = SelectionCounts(apps: 0, categories: 0, web: 0)
        var exceptionsUsed = 0

        if !allBlocks.isEmpty {
            // An app a due list blocks stays blocked though an all-apps block excepts it, because
            // the list's own store is dropped while all apps are shielded.
            var excepted = lookup(allBlocks[0].block.exceptSelectionId).apps
            for block in allBlocks.dropFirst() {
                excepted.formIntersection(lookup(block.block.exceptSelectionId).apps)
            }
            for block in listBlocks {
                excepted.subtract(lookup(block.block.selectionId).apps.subtracting(lookup(block.block.exceptSelectionId).apps))
            }
            plan.stores[ShieldStoreName.all] = Contents(categories: .all(except: excepted),
                                                        allWebDomains: allBlocks.contains { $0.block.blocksAllWeb })
            for block in allBlocks {
                plan.storesBySlot[block.slotId, default: []].insert(ShieldStoreName.all)
            }
            var web = Set<Web>()
            for key in keys {
                let blocks = listBlocks.filter { $0.listKey == key }
                for block in blocks {
                    plan.storesBySlot[block.slotId, default: []].insert(ShieldStoreName.all)
                }
                let keyWeb = blocks.reduce(into: Set<Web>()) { $0.formUnion(lookup($1.block.selectionId).web) }
                if used.web + keyWeb.count > cap {
                    plan.cappedSlots.formUnion(blocks.map(\.slotId))
                    continue
                }
                used.web += keyWeb.count
                web.formUnion(keyWeb)
                for block in blocks where !keyWeb.isEmpty {
                    plan.storesBySlot[block.slotId, default: []].insert(ShieldStoreName.web)
                }
            }
            if !web.isEmpty {
                plan.stores[ShieldStoreName.web] = Contents(webDomains: web)
            }
            return plan
        }

        for key in keys {
            let blocks = listBlocks.filter { $0.listKey == key }
            var contents = Contents()
            var categories = Set<Category>()
            var categoryExceptions: Set<App>?
            for block in blocks {
                let listed = lookup(block.block.selectionId)
                let excepted = lookup(block.block.exceptSelectionId).apps
                contents.apps.formUnion(listed.apps.subtracting(excepted))
                contents.webDomains.formUnion(listed.web)
                if !listed.categories.isEmpty {
                    categories.formUnion(listed.categories)
                    categoryExceptions = categoryExceptions.map { $0.intersection(excepted) } ?? excepted
                }
            }
            let exceptions = categories.isEmpty ? 0 : (categoryExceptions?.count ?? 0)
            if used.apps + contents.apps.count > cap || used.categories + categories.count > cap
                || used.web + contents.webDomains.count > cap || exceptionsUsed + exceptions > cap {
                plan.cappedSlots.formUnion(blocks.map(\.slotId))
                continue
            }
            used.apps += contents.apps.count
            used.categories += categories.count
            used.web += contents.webDomains.count
            exceptionsUsed += exceptions
            if !categories.isEmpty {
                contents.categories = .specific(categories, except: categoryExceptions ?? [])
            }
            guard !contents.isEmpty, let name = plan.listNames[key] else {
                continue
            }
            plan.stores[name] = Self.merge(plan.stores[name], contents)
            for block in blocks {
                plan.storesBySlot[block.slotId, default: []].insert(name)
            }
        }
        // A due block with nothing to shield, such as an empty list, holds by holding nothing.
        for slotId in plan.dueSlots where plan.storesBySlot[slotId] == nil && !plan.cappedSlots.contains(slotId) {
            plan.storesBySlot[slotId] = []
        }
        return plan
    }

    /// Keeps each due list's name, gives a new one the lowest free name in sorted id order, and folds
    /// every list past the last name into it: a name that moved would clear and set again a shield
    /// that holds, which a blocked app on screen redraws with the system's generic words.
    public static func assignNames(keys: Set<String>, previous: [String: String]) -> [String: String] {
        var names: [String: String] = [:]
        for key in keys {
            if let name = previous[key], ShieldStoreName.lists.contains(name) {
                names[key] = name
            }
        }
        var free = ShieldStoreName.lists.filter { !names.values.contains($0) }
        for key in keys.sorted() where names[key] == nil {
            names[key] = free.isEmpty ? ShieldStoreName.lists.last! : free.removeFirst()
        }
        return names
    }

    /// The fixed order lists are shielded in when a cap is reached: by store name, then by key.
    static func order(_ names: [String: String], _ a: String, _ b: String) -> Bool {
        let left = ShieldStoreName.lists.firstIndex(of: names[a] ?? "") ?? Int.max
        let right = ShieldStoreName.lists.firstIndex(of: names[b] ?? "") ?? Int.max
        return left == right ? a < b : left < right
    }

    static func merge(_ existing: Contents?, _ next: Contents) -> Contents {
        guard var merged = existing else {
            return next
        }
        merged.apps.formUnion(next.apps)
        merged.webDomains.formUnion(next.webDomains)
        switch (merged.categories, next.categories) {
        case let (.specific(left, leftExcept), .specific(right, rightExcept)):
            merged.categories = .specific(left.union(right), except: leftExcept.intersection(rightExcept))
        case (.none, _):
            merged.categories = next.categories
        default:
            break
        }
        return merged
    }
}

/// The words of one block screen, and the block a button on it names.
public struct ComposedShield: Equatable, Sendable {
    /// Empty when the screen's block has no appearance and none is the fallback: the system's own
    /// screen shows, and a button on it still names the block.
    public var appearanceId: String
    /// Empty only for the fallback screen over an app no block covers.
    public var slotId: String
    public var title: String
    public var subtitle: String
}

/// Composes the block screen over one app from the appearances the host wrote. One covering block
/// shows its own words; two or more show the joined title, their names in ascending `name_order`,
/// and the joined line with the `until` of the block that holds longest. The host writes every
/// word; this only joins them. A covering block whose appearance was never written is named only
/// when no covering block has one: its screen shows the fallback words, and a button on it still
/// routes to that block.
///
/// A button names no slot only when nothing the bridge holds explains the shield, which is how an
/// identity the system changed reads (screen-time proposal §4.2): the blocks due now come first;
/// then the slots the stores held at the last write, as that write saw them, since a shield stays
/// up past its block's end until a wake lifts it, and a `daily` one by its own block where the
/// calendar has moved since; then a due block whose list cannot be read.
public enum ShieldWords {
    public static func compose(slots: [String: SlotRecord], appearances: [String: [String: Any]], at unix: Int,
                               calendar: Calendar, held: Set<String> = [], heldAt: Int = 0,
                               unreadable: (RestrictionBlock) -> Bool = { _ in false },
                               covers: (RestrictionBlock) -> Bool) -> ComposedShield? {
        if let shield = screen(slots, appearances, at: unix, calendar: calendar, covers) {
            return shield
        }
        if heldAt > 0,
           let shield = screen(slots.filter { held.contains($0.key) }, appearances, at: heldAt, calendar: calendar,
                               held: true, covers) {
            return shield
        }
        return screen(slots, appearances, at: unix, calendar: calendar, unreadable) ?? fallback(appearances)
    }

    /// The screen of the slots whose blocks due at `unix`, or with `held` held then, match, or nil
    /// when none does.
    static func screen(_ slots: [String: SlotRecord], _ appearances: [String: [String: Any]], at unix: Int,
                       calendar: Calendar, held: Bool = false, _ matches: (RestrictionBlock) -> Bool) -> ComposedShield? {
        var unnamed: [String] = []
        var covering: [(slotId: String, appearanceId: String, appearance: [String: Any], order: Int, ends: Int)] = []
        for slotId in slots.keys.sorted() {
            let record = slots[slotId]!
            let blocks = held
                ? RestrictionEvaluator.heldBlocks(slotId: slotId, record: record, at: unix, calendar: calendar)
                : RestrictionEvaluator.dueBlocks(slotId: slotId, record: record, at: unix, calendar: calendar)
            guard blocks.contains(where: { matches($0.block) }) else {
                continue
            }
            guard let appearance = appearances[record.spec.appearanceId] else {
                unnamed.append(slotId)
                continue
            }
            covering.append((slotId, record.spec.appearanceId, appearance, WireJSON.whole(appearance["name_order"]) ?? 0,
                             RestrictionEvaluator.holdsUntil(record, at: unix, calendar: calendar)))
        }
        guard !covering.isEmpty else {
            return unnamed.first.map {
                fallback(appearances, slotId: $0) ?? ComposedShield(appearanceId: "", slotId: $0, title: "", subtitle: "")
            }
        }
        covering.sort { $0.order == $1.order ? $0.slotId < $1.slotId : $0.order < $1.order }
        let first = covering[0]
        if covering.count == 1 {
            return ComposedShield(appearanceId: first.appearanceId, slotId: first.slotId,
                                  title: text(first.appearance["title"]), subtitle: text(first.appearance["subtitle"]))
        }
        var latest = first
        for entry in covering where entry.ends > latest.ends {
            latest = entry
        }
        let names = covering.map { text($0.appearance["name"]) }
        let joined = names.dropLast().joined(separator: text(first.appearance["name_separator"]))
            + text(first.appearance["name_last_separator"]) + names.last!
        return ComposedShield(appearanceId: first.appearanceId, slotId: first.slotId,
                              title: text(first.appearance["joined_title"]).replacingOccurrences(of: "{names}", with: joined),
                              subtitle: text(first.appearance["joined_subtitle"])
                                .replacingOccurrences(of: "{until}", with: text(latest.appearance["until"])))
    }

    /// The screen for an app a shield covers but no block's list matches, as after a system update
    /// changes the app's token, with `slotId` empty; or for a block with no appearance, naming it.
    public static func fallback(_ appearances: [String: [String: Any]], slotId: String = "") -> ComposedShield? {
        for id in appearances.keys.sorted() where WireJSON.flag(appearances[id]?["fallback"]) == true {
            let appearance = appearances[id]!
            return ComposedShield(appearanceId: id, slotId: slotId, title: text(appearance["title"]),
                                  subtitle: text(appearance["subtitle"]))
        }
        return nil
    }

    static func text(_ value: Any?) -> String {
        value as? String ?? ""
    }
}
