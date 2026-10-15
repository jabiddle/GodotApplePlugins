import Foundation

/// The answers a restriction call gives beside `""` for success. The host reads them as a closed
/// list, so a new failure maps onto one of these or onto `error:` followed by the platform's text.
public enum RestrictionCode {
    public static let unsupported = "unsupported"
    public static let notAuthorized = "not_authorized"
    public static let passcodeRequired = "passcode_required"
    public static let promptUnavailable = "prompt_unavailable"
    public static let unknownSelection = "unknown_selection"
    public static let invalidSpec = "invalid_spec"
    public static let unknownSlot = "unknown_slot"
    public static let tooManyWindows = "too_many_windows"
    public static let selectionTooLarge = "selection_too_large"
    public static let busy = "busy"
    public static let cancelled = "cancelled"
    public static let schemaMismatch = "schema_mismatch"
    /// A rebuild's report that it replaced a value or file no revision could have written.
    public static let storeReset = platform("store reset")

    public static func platform(_ text: String) -> String {
        "error: " + text
    }
}

public enum RestrictionEventKind {
    public static let started = "restriction_started"
    public static let ended = "restriction_ended"
    public static let degraded = "restriction_degraded"
    public static let lost = "restriction_lost"
    public static let shieldButton = "shield_button"
}

public enum RestrictionReason {
    public static let cap = "cap"
    public static let refused = "refused"
    public static let permission = "permission"
    public static let applyFailed = "apply_failed"
}

/// One entry of the event queue. `atUnix` is 0 when the device cannot date it.
public struct RestrictionEvent: Codable, Equatable, Sendable {
    public var kind: String
    public var slotId: String
    public var generation: Int
    public var atUnix: Int
    public var button: String
    public var reason: String

    enum CodingKeys: String, CodingKey {
        case kind
        case slotId = "slot_id"
        case generation
        case atUnix = "at_unix"
        case button
        case reason
    }

    public init(kind: String, slotId: String, generation: Int, atUnix: Int, button: String = "", reason: String = "") {
        self.kind = kind
        self.slotId = slotId
        self.generation = generation
        self.atUnix = atUnix
        self.button = button
        self.reason = reason
    }

    public var jsonObject: [String: Any] {
        ["kind": kind, "slot_id": slotId, "generation": generation, "at_unix": atUnix, "button": button, "reason": reason]
    }
}

public enum RestrictionMode: String, Sendable {
    case blockAll = "block_all"
    case blockSelection = "block_selection"
}

/// What one block shields: every app but its exceptions, or one list but its exceptions.
public struct RestrictionBlock: Equatable, Sendable {
    public var mode: RestrictionMode
    public var selectionId: String
    public var exceptSelectionId: String
    public var blocksAllWeb: Bool

    public init(mode: RestrictionMode, selectionId: String = "", exceptSelectionId: String = "", blocksAllWeb: Bool = false) {
        self.mode = mode
        self.selectionId = selectionId
        self.exceptSelectionId = exceptSelectionId
        self.blocksAllWeb = blocksAllWeb
    }

    /// Every selection id the block names.
    public var selectionIds: [String] {
        [selectionId, exceptSelectionId].filter { !$0.isEmpty }
    }
}

/// When a block holds. A `once` window is an instant pair; a `daily` window repeats on ISO weekdays
/// (Monday 1) at minutes after local midnight, and an end not after its start runs into the next day.
public enum RestrictionWindow: Equatable, Sendable {
    case once(startUnix: Int, endUnix: Int)
    case daily(weekdays: [Int], startMinute: Int, endMinute: Int)
}

/// A second block beside the slot's own until `untilUnix`; past it the block is ignored. The caller
/// alone writes and changes it.
public struct RetainedBlock: Equatable, Sendable {
    public var block: RestrictionBlock
    public var untilUnix: Int

    public init(block: RestrictionBlock, untilUnix: Int) {
        self.block = block
        self.untilUnix = untilUnix
    }
}

public struct RestrictionSpec: Equatable, Sendable {
    public var block: RestrictionBlock
    public var window: RestrictionWindow
    public var generation: Int
    public var appearanceId: String
    public var exempt: [String]
    public var retained: RetainedBlock?

    public init(block: RestrictionBlock, window: RestrictionWindow, generation: Int, appearanceId: String = "",
                exempt: [String] = [], retained: RetainedBlock? = nil) {
        self.block = block
        self.window = window
        self.generation = generation
        self.appearanceId = appearanceId
        self.exempt = exempt
        self.retained = retained
    }

    public var selectionIds: [String] {
        block.selectionIds + (retained?.block.selectionIds ?? [])
    }

    /// Nil for any shape the wire refuses as `invalid_spec`. `exempt` is kept for the read-back and
    /// ignored by every evaluation here: this platform spares no app by role.
    public static func parse(_ object: Any?) -> RestrictionSpec? {
        guard let spec = object as? [String: Any],
              let block = parseBlock(spec),
              let window = parseWindow(spec["window"]),
              let generation = WireJSON.whole(spec["generation"]) else {
            return nil
        }
        let appearanceId = spec["appearance_id"] ?? ""
        let exempt = spec["exempt"] ?? [Any]()
        guard let appearanceText = appearanceId as? String, let exemptList = exempt as? [Any] else {
            return nil
        }
        var retained: RetainedBlock?
        if spec.keys.contains("retain") {
            guard let part = spec["retain"] as? [String: Any], let partBlock = parseBlock(part),
                  let until = WireJSON.whole(part["until_unix"]) else {
                return nil
            }
            retained = RetainedBlock(block: partBlock, untilUnix: until)
        }
        return RestrictionSpec(block: block, window: window, generation: generation, appearanceId: appearanceText,
                               exempt: exemptList.compactMap { $0 as? String }, retained: retained)
    }

    private static func parseBlock(_ object: [String: Any]) -> RestrictionBlock? {
        guard let modeText = object["mode"] as? String, let mode = RestrictionMode(rawValue: modeText),
              let selectionId = (object["selection_id"] ?? "") as? String,
              let exceptId = (object["except_selection_id"] ?? "") as? String,
              let allWeb = WireJSON.flag(object["block_all_web"] ?? false) else {
            return nil
        }
        if mode == .blockSelection && selectionId.isEmpty {
            return nil
        }
        return RestrictionBlock(mode: mode, selectionId: selectionId, exceptSelectionId: exceptId, blocksAllWeb: allWeb)
    }

    /// Exactly one of `once` and `daily`; any other key is one a newer side added, and is ignored.
    private static func parseWindow(_ object: Any?) -> RestrictionWindow? {
        guard let window = object as? [String: Any], (window["once"] == nil) != (window["daily"] == nil) else {
            return nil
        }
        if let once = window["once"] as? [String: Any] {
            guard let start = WireJSON.whole(once["start_unix"]), let end = WireJSON.whole(once["end_unix"]),
                  end > start else {
                return nil
            }
            return .once(startUnix: start, endUnix: end)
        }
        guard let daily = window["daily"] as? [String: Any], let days = daily["weekdays"] as? [Any], !days.isEmpty,
              let start = WireJSON.whole(daily["start_minute"]), let end = WireJSON.whole(daily["end_minute"]),
              (0..<RestrictionTime.minutesPerDay).contains(start), (0..<RestrictionTime.minutesPerDay).contains(end),
              start != end else {
            return nil
        }
        var weekdays: [Int] = []
        for day in days {
            guard let weekday = WireJSON.whole(day), (1...7).contains(weekday) else {
                return nil
            }
            weekdays.append(weekday)
        }
        return .daily(weekdays: weekdays, startMinute: start, endMinute: end)
    }

    /// The spec as the read-back answers it: every number whole and every absent id empty.
    public var jsonObject: [String: Any] {
        var object = Self.blockObject(block)
        switch window {
        case let .once(start, end):
            object["window"] = ["once": ["start_unix": start, "end_unix": end]]
        case let .daily(weekdays, start, end):
            object["window"] = ["daily": ["weekdays": weekdays, "start_minute": start, "end_minute": end]]
        }
        object["generation"] = generation
        object["appearance_id"] = appearanceId
        object["exempt"] = exempt
        if let retained {
            var part = Self.blockObject(retained.block)
            part["until_unix"] = retained.untilUnix
            object["retain"] = part
        }
        return object
    }

    private static func blockObject(_ block: RestrictionBlock) -> [String: Any] {
        ["mode": block.mode.rawValue, "selection_id": block.selectionId,
         "except_selection_id": block.exceptSelectionId, "block_all_web": block.blocksAllWeb]
    }
}

/// A slot as the store keeps it. A slot set again under its id keeps its suspension.
public struct SlotRecord: Equatable, Sendable {
    public var spec: RestrictionSpec
    public var suspendedUntil: Int

    public init(spec: RestrictionSpec, suspendedUntil: Int = 0) {
        self.spec = spec
        self.suspendedUntil = suspendedUntil
    }
}

/// Three token sets that unite, intersect and compare without learning a name.
public struct TokenSelection<App: Hashable, Category: Hashable, Web: Hashable>: Equatable {
    public var apps: Set<App>
    public var categories: Set<Category>
    public var web: Set<Web>
    /// The platform could not renew this list's tokens, so its shields may no longer match.
    public var expired: Bool

    public init(apps: Set<App> = [], categories: Set<Category> = [], web: Set<Web> = [], expired: Bool = false) {
        self.apps = apps
        self.categories = categories
        self.web = web
        self.expired = expired
    }

    public var counts: SelectionCounts {
        SelectionCounts(apps: apps.count, categories: categories.count, web: web.count)
    }

    public func union(_ other: Self) -> Self {
        Self(apps: apps.union(other.apps), categories: categories.union(other.categories), web: web.union(other.web),
             expired: expired || other.expired)
    }

    public func intersection(_ other: Self) -> Self {
        Self(apps: apps.intersection(other.apps), categories: categories.intersection(other.categories),
             web: web.intersection(other.web), expired: expired)
    }

    /// What this selection holds beyond `base`, counted per kind.
    public func counts(beyond base: Self) -> SelectionCounts {
        SelectionCounts(apps: apps.subtracting(base.apps).count, categories: categories.subtracting(base.categories).count,
                        web: web.subtracting(base.web).count)
    }

    public func exceeds(cap: Int) -> Bool {
        apps.count > cap || categories.count > cap || web.count > cap
    }
}

extension TokenSelection: Codable where App: Codable, Category: Codable, Web: Codable {}

public struct SelectionCounts: Equatable, Sendable {
    public var apps: Int
    public var categories: Int
    public var web: Int

    public init(apps: Int, categories: Int, web: Int) {
        self.apps = apps
        self.categories = categories
        self.web = web
    }

    public var jsonObject: [String: Any] {
        ["apps": apps, "categories": categories, "web": web]
    }
}

/// JSON as the wire carries it: text in, text out, every number read whole.
public enum WireJSON {
    public static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func text(_ value: Any, fallback: String = "{}") -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return text
    }

    public static func whole(_ value: Any?) -> Int? {
        if let number = value as? Int {
            return number
        }
        if let number = value as? Double, number.rounded() == number, abs(number) < 9.0e15 {
            return Int(number)
        }
        return nil
    }

    public static func flag(_ value: Any?) -> Bool? {
        value as? Bool
    }
}
