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
/// rewrite each other's shields.
public final class RestrictionStore {
    public static let schemaVersion = 1
    public static let eventQueueCap = 200

    static let schemaKey = "screen_time.schema"
    static let prefix = "screen_time.v1."
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

    public var schemaMatches: Bool {
        guard let stored = number(Self.schemaKey) else {
            return true
        }
        return stored == Self.schemaVersion
    }

    /// Stamps the version before the first write, so a reader of another version sees it.
    func claimSchema() {
        if number(Self.schemaKey) == nil {
            setNumber(Self.schemaVersion, Self.schemaKey)
        }
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

    public func setHeld(_ held: [String: HeldSlot]) {
        setObject(held.mapValues { ["stores": $0.stores.sorted(), "generation": $0.generation] }, "held")
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

    /// Serialises the app and its extensions over the store. Held only for a synchronous call: a
    /// process the system suspends while it holds a lock in a shared container is killed for it.
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        processLock.lock()
        defer { processLock.unlock() }
        if lockDepth == 0 {
            acquireFileLock()
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

    func acquireFileLock() {
#if canImport(Darwin)
        let descriptor = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            return
        }
        // Bounded: a store the lock keeps out for this long is better written unlocked than not at all.
        for _ in 0..<200 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                lockDescriptor = descriptor
                return
            }
            usleep(10_000)
        }
        close(descriptor)
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
        guard let data = values.data(forKey: key), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Int(text)
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
