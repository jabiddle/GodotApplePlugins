import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The small values the store keeps beside its files: the App Group's `UserDefaults` on a device.
public protocol SharedValues: AnyObject {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
}

public final class DefaultsValues: SharedValues {
    let defaults: UserDefaults

    public init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func setData(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// What the host app and its extensions share: slots, appearances and bookkeeping as small values
/// under versioned keys, and each selection, each image, the access record and the event queue as a
/// file of its own, so an extension loads only what it needs and never a whole queue.
///
/// Every value and file carries the schema version. A reader that finds another one writes nothing:
/// the app and its extensions can be built from different revisions, and two evaluators would
/// rewrite each other's shields. A value no revision could have written is refused alike, since
/// read as empty the next write would replace everything it held, until a rebuild replaces it.
public final class RestrictionStore {
    public static let schemaVersion = 1
    public static let eventQueueCap = 200

    static let schemaKey = "screen_time.schema"
    static let prefix = "screen_time.v1."
    static let objectNames = ["slots", "appearances", "list_names", "held", "degraded", "windows"]
    static let numberNames = ["generation", "window_serial", "loss_reported", "held_at"]
    /// A queue file past this size is rotated, so appending never has to read the queue.
    static let eventFileLimit = 64 * 1024

    let values: SharedValues
    public let directory: URL
    /// The Darwin notification posted after every append, so a process that is listening learns of
    /// events another process appended.
    public let eventsNotification: String?
    let processLock = NSRecursiveLock()
    var lockDepth = 0
    var lockDescriptor: Int32 = -1

    public init(values: SharedValues, directory: URL, eventsNotification: String? = nil) {
        self.values = values
        self.directory = directory
        self.eventsNotification = eventsNotification
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

#if canImport(Darwin)
    /// The store in an App Group, or nil when this process lacks the entitlement: `UserDefaults`
    /// still answers then, into a private store nothing else opens, so the container is the test.
    public static func inAppGroup(_ identifier: String) -> RestrictionStore? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier),
              let defaults = UserDefaults(suiteName: identifier) else {
            return nil
        }
        return RestrictionStore(values: DefaultsValues(defaults),
                                directory: container.appendingPathComponent("ScreenTime", isDirectory: true),
                                eventsNotification: identifier + ".screen-time.events")
    }
#endif

    // MARK: Schema

    public enum SchemaReading: Sendable {
        case current
        case otherVersion
        case unparseable
    }

    public var schemaMatches: Bool {
        schemaReading == .current
    }

    public var schemaReading: SchemaReading {
        if let data = values.data(forKey: Self.schemaKey) {
            guard let stored = Self.whole(data) else {
                return .unparseable
            }
            if stored != Self.schemaVersion {
                return .otherVersion
            }
        }
        return unparseableKeys().isEmpty ? .current : .unparseable
    }

    /// Stamps the version before the first write, so a reader of another version sees it.
    func claimSchema() {
        if values.data(forKey: Self.schemaKey) == nil {
            setNumber(Self.schemaVersion, Self.schemaKey)
        }
    }

    /// The values present that no revision wrote: an object that is no JSON object, a number that
    /// is no whole one.
    func unparseableKeys() -> [String] {
        let objects = Self.objectNames.map { Self.prefix + $0 }.filter { key in
            values.data(forKey: key).map { !((try? JSONSerialization.jsonObject(with: $0)) is [String: Any]) } ?? false
        }
        let numbers = Self.numberNames.map { Self.prefix + $0 }.filter { key in
            values.data(forKey: key).map { Self.whole($0) == nil } ?? false
        }
        return objects + numbers
    }

    /// A rebuild's way out of a torn store: each value that cannot be parsed is removed, which reads
    /// as empty at this version, and each list file that cannot be parsed is deleted. Answers whether
    /// anything was. Only while no value is at another version.
    public func resetUnparseable() -> Bool {
        var torn = unparseableKeys()
        if let data = values.data(forKey: Self.schemaKey), Self.whole(data) == nil {
            torn.append(Self.schemaKey)
        }
        for key in torn {
            values.setData(nil, forKey: key)
        }
        let tornLists = selectionIds().filter { !selectionParses($0) }
        tornLists.forEach(deleteSelection)
        guard !torn.isEmpty || !tornLists.isEmpty else {
            return false
        }
        claimSchema()
        return true
    }

    // MARK: Slots and bookkeeping

    public func slots() -> [String: SlotRecord] {
        var slots: [String: SlotRecord] = [:]
        for (slotId, entry) in object("slots") {
            guard let entry = entry as? [String: Any], let spec = RestrictionSpec.parse(entry["spec"]) else {
                continue
            }
            slots[slotId] = SlotRecord(spec: spec, suspendedUntil: WireJSON.whole(entry["suspended_until"]) ?? 0)
        }
        return slots
    }

    public func setSlots(_ slots: [String: SlotRecord]) {
        claimSchema()
        setObject(slots.mapValues { ["spec": $0.spec.jsonObject, "suspended_until": $0.suspendedUntil] }, "slots")
    }

    public func appearances() -> [String: [String: Any]] {
        object("appearances").compactMapValues { $0 as? [String: Any] }
    }

    public func setAppearance(_ appearance: [String: Any]?, id: String) {
        claimSchema()
        var all = object("appearances")
        all[id] = appearance
        setObject(all, "appearances")
    }

    public func imageURL(appearanceId: String) -> URL {
        directory.appendingPathComponent("img-" + Self.fileKey(appearanceId) + ".png")
    }

    /// Each due list's key to its store name.
    public func listNames() -> [String: String] {
        object("list_names").compactMapValues { $0 as? String }
    }

    public func setListNames(_ names: [String: String]) {
        setObject(names, "list_names")
    }

    /// Each slot the stores held at the last write, to the stores that held it.
    public func held() -> [String: HeldSlot] {
        var held: [String: HeldSlot] = [:]
        for (slotId, entry) in object("held") {
            guard let entry = entry as? [String: Any], let stores = entry["stores"] as? [String] else {
                continue
            }
            held[slotId] = HeldSlot(stores: Set(stores), generation: WireJSON.whole(entry["generation"]) ?? 0)
        }
        return held
    }

    /// `evaluation` is the instant the write was planned for: a shield left up past its block's end
    /// until a wake lifts it is read as of then.
    public func setHeld(_ held: [String: HeldSlot], at evaluation: Int) {
        setObject(held.mapValues { ["stores": $0.stores.sorted(), "generation": $0.generation] }, "held")
        setNumber(evaluation, Self.prefix + "held_at")
    }

    /// The instant the last write of `held` was planned for; 0 before any write recorded one.
    public var heldAt: Int {
        number(Self.prefix + "held_at") ?? 0
    }

    /// Each slot that shields less than it asks, to the reason last reported for it.
    public func degraded() -> [String: String] {
        object("degraded").compactMapValues { $0 as? String }
    }

    public func setDegraded(_ degraded: [String: String]) {
        setObject(degraded, "degraded")
    }

    /// The store's generation, which a rebuild raises.
    public var generation: Int {
        get { number(Self.prefix + "generation") ?? 0 }
        set { setNumber(newValue, Self.prefix + "generation") }
    }

    /// The windows registered now, by name. A callback naming any other window is from a generation
    /// already replaced, and does nothing.
    public func windows() -> [String: PlannedWindow] {
        guard let data = values.data(forKey: Self.prefix + "windows"),
              let windows = try? JSONDecoder().decode([String: PlannedWindow].self, from: data) else {
            return [:]
        }
        return windows
    }

    public func setWindows(_ windows: [String: PlannedWindow]) {
        values.setData(try? JSONEncoder().encode(windows), forKey: Self.prefix + "windows")
    }

    /// A new window name each time: a running window registered again under its own name does not
    /// start again, and starting a name inside its own end callback deadlocks.
    public func nextWindowName(kind: String) -> String {
        let serial = (number(Self.prefix + "window_serial") ?? 0) + 1
        setNumber(serial, Self.prefix + "window_serial")
        return kind + "." + String(serial)
    }

    /// Set once the access loss has been reported, so the losses are appended once per loss.
    public var lossReported: Bool {
        get { number(Self.prefix + "loss_reported") == 1 }
        set { setNumber(newValue ? 1 : 0, Self.prefix + "loss_reported") }
    }

    // MARK: Selections

    public func hasSelection(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: selectionURL(id).path)
    }

    public func selection<App: Codable & Hashable, Category: Codable & Hashable, Web: Codable & Hashable>(
        _ id: String
    ) -> TokenSelection<App, Category, Web>? {
        guard let data = try? Data(contentsOf: selectionURL(id)),
              let file = try? JSONDecoder().decode(SelectionFile<App, Category, Web>.self, from: data),
              file.schema == Self.schemaVersion else {
            return nil
        }
        return file.selection
    }

    public func setSelection<App: Codable & Hashable, Category: Codable & Hashable, Web: Codable & Hashable>(
        _ selection: TokenSelection<App, Category, Web>, id: String
    ) {
        claimSchema()
        let file = SelectionFile(schema: Self.schemaVersion, selection: selection)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: selectionURL(id), options: .atomic)
        }
    }

    public func deleteSelection(_ id: String) {
        try? FileManager.default.removeItem(at: selectionURL(id))
    }

    public func selectionIds() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> String? in
            guard name.hasPrefix("sel-"), name.hasSuffix(".json") else {
                return nil
            }
            return Self.idFromFileKey(String(name.dropFirst(4).dropLast(5)))
        }.sorted()
    }

    func selectionURL(_ id: String) -> URL {
        directory.appendingPathComponent("sel-" + Self.fileKey(id) + ".json")
    }

    /// Whether any revision could have written the list's file: a JSON object with a whole-number
    /// version. One this process cannot read is kept, as a file at another version is.
    func selectionParses(_ id: String) -> Bool {
        guard let data = try? Data(contentsOf: selectionURL(id)) else {
            return true
        }
        let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return WireJSON.whole(file?["schema"]) != nil
    }

    // MARK: The access record

    /// Whether this device approved access here. The file is excluded from backups, so a phone
    /// restored from one reads as never having asked.
    public var approvalRecorded: Bool {
        guard let data = try? Data(contentsOf: recordURL),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        return WireJSON.whole(record["schema"]) == Self.schemaVersion
    }

    public func recordApproval(at unix: Int) {
        claimSchema()
        guard let data = try? JSONSerialization.data(withJSONObject: ["schema": Self.schemaVersion, "approved_at": unix]) else {
            return
        }
        var url = recordURL
        try? data.write(to: url, options: .atomic)
#if canImport(Darwin)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try? url.setResourceValues(excluded)
#endif
    }

    var recordURL: URL {
        directory.appendingPathComponent("approved.json")
    }

    // MARK: Events

    /// Appends without reading the queue: a line per event, and a full file rotated aside.
    public func appendEvents(_ events: [RestrictionEvent]) {
        guard !events.isEmpty else {
            return
        }
        claimSchema()
        var text = ""
        for event in events {
            var line = event.jsonObject
            line["schema"] = Self.schemaVersion
            text += WireJSON.text(line) + "\n"
        }
        let active = eventURL(0)
        let size = (try? FileManager.default.attributesOfItem(atPath: active.path)[.size] as? Int) ?? 0
        if size > Self.eventFileLimit {
            try? FileManager.default.removeItem(at: eventURL(1))
            try? FileManager.default.moveItem(at: active, to: eventURL(1))
        }
        if let handle = try? FileHandle(forWritingTo: active) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: active)
        }
        postEventsNotification()
    }

    /// The newest events, oldest first, removed from the queue; nil when a file is at another version.
    public func drainEvents() -> [RestrictionEvent]? {
        var events: [RestrictionEvent] = []
        for index in [1, 0] {
            guard let text = try? String(contentsOf: eventURL(index), encoding: .utf8) else {
                continue
            }
            for line in text.split(separator: "\n") {
                guard let object = WireJSON.object(String(line)) else {
                    continue
                }
                guard WireJSON.whole(object["schema"]) == Self.schemaVersion else {
                    return nil
                }
                events.append(RestrictionEvent(kind: object["kind"] as? String ?? "", slotId: object["slot_id"] as? String ?? "",
                                               generation: WireJSON.whole(object["generation"]) ?? 0,
                                               atUnix: WireJSON.whole(object["at_unix"]) ?? 0,
                                               button: object["button"] as? String ?? "", reason: object["reason"] as? String ?? ""))
            }
        }
        try? FileManager.default.removeItem(at: eventURL(1))
        try? FileManager.default.removeItem(at: eventURL(0))
        return Array(events.suffix(Self.eventQueueCap))
    }

    public var hasQueuedEvents: Bool {
        [0, 1].contains { ((try? FileManager.default.attributesOfItem(atPath: eventURL($0).path)[.size] as? Int) ?? 0) > 0 }
    }

    func eventURL(_ index: Int) -> URL {
        directory.appendingPathComponent("events-\(index).jsonl")
    }

    func postEventsNotification() {
#if canImport(Darwin)
        guard let name = eventsNotification else {
            return
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString),
                                             nil, nil, true)
#endif
    }

    // MARK: The lock

    /// Serialises the app and its extensions over the store, waiting for as long as another process
    /// holds it: a body run unlocked loses another process's update. Every holder holds it for one
    /// synchronous call, and a process the system suspends while it holds a lock in a shared
    /// container is killed for it, which releases the lock.
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        // Never nil: without a deadline the lock is always taken.
        try locked(until: nil, body)!
    }

    /// The same, giving up once `seconds` pass without the lock: nil then, and the body has not run.
    public func withLock<T>(within seconds: TimeInterval, _ body: () throws -> T) rethrows -> T? {
        try locked(until: Date().addingTimeInterval(seconds), body)
    }

    func locked<T>(until deadline: Date?, _ body: () throws -> T) rethrows -> T? {
        if let deadline {
            guard processLock.lock(before: deadline) else {
                return nil
            }
        } else {
            processLock.lock()
        }
        defer { processLock.unlock() }
        if lockDepth == 0 && !acquireFileLock(until: deadline) {
            return nil
        }
        lockDepth += 1
        defer {
            lockDepth -= 1
            if lockDepth == 0 {
                releaseFileLock()
            }
        }
        return try body()
    }

    /// Without Darwin there is one process, the tests', and the process lock serialises it.
    func acquireFileLock(until deadline: Date?) -> Bool {
#if canImport(Darwin)
        var descriptor: Int32 = -1
        while true {
            if descriptor < 0 {
                descriptor = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o644)
            }
            if descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                lockDescriptor = descriptor
                return true
            }
            if let deadline, Date() >= deadline {
                if descriptor >= 0 {
                    close(descriptor)
                }
                return false
            }
            usleep(10_000)
        }
#else
        return true
#endif
    }

    func releaseFileLock() {
#if canImport(Darwin)
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockDescriptor = -1
        }
#endif
    }

    // MARK: Encoding

    /// A filename-safe form of a caller's id: its UTF-8 in hex.
    static func fileKey(_ id: String) -> String {
        id.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func idFromFileKey(_ key: String) -> String? {
        guard key.count % 2 == 0 else {
            return nil
        }
        var bytes: [UInt8] = []
        var index = key.startIndex
        while index < key.endIndex {
            let next = key.index(index, offsetBy: 2)
            guard let byte = UInt8(key[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    func object(_ name: String) -> [String: Any] {
        guard let data = values.data(forKey: Self.prefix + name),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return object
    }

    func setObject(_ object: [String: Any], _ name: String) {
        values.setData(try? JSONSerialization.data(withJSONObject: object), forKey: Self.prefix + name)
    }

    func number(_ key: String) -> Int? {
        values.data(forKey: key).flatMap(Self.whole)
    }

    static func whole(_ data: Data) -> Int? {
        String(data: data, encoding: .utf8).flatMap { Int($0) }
    }

    func setNumber(_ value: Int, _ key: String) {
        values.setData(Data(String(value).utf8), forKey: key)
    }
}

/// A slot the stores held at the last write, and the stores that held it.
public struct HeldSlot: Equatable, Sendable {
    public var stores: Set<String>
    public var generation: Int

    public init(stores: Set<String>, generation: Int) {
        self.stores = stores
        self.generation = generation
    }
}

struct SelectionFile<App: Codable & Hashable, Category: Codable & Hashable, Web: Codable & Hashable>: Codable {
    var schema: Int
    var selection: TokenSelection<App, Category, Web>
}
