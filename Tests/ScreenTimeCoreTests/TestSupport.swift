import Foundation
@testable import ScreenTimeCore

typealias Selection = TokenSelection<String, String, String>
typealias Contents = ShieldContents<String, String, String>

/// One hour east of UTC, so a local day and a UTC day never coincide.
let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
    return calendar
}()

/// An instant on the test calendar's wall clock. 2026-10-12 is a Monday.
func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Int {
    let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    return Int(testCalendar.date(from: parts)!.timeIntervalSince1970)
}

func onceSpec(_ start: Int, _ end: Int, mode: RestrictionMode = .blockAll, list: String = "", except: String = "",
              allWeb: Bool = false, generation: Int = 1, appearance: String = "", retained: RetainedBlock? = nil) -> RestrictionSpec {
    RestrictionSpec(block: RestrictionBlock(mode: mode, selectionId: list, exceptSelectionId: except, blocksAllWeb: allWeb),
                    window: .once(startUnix: start, endUnix: end), generation: generation, appearanceId: appearance,
                    retained: retained)
}

func dailySpec(_ weekdays: [Int], _ start: Int, _ end: Int, mode: RestrictionMode = .blockAll, list: String = "",
               except: String = "", generation: Int = 1, appearance: String = "", retained: RetainedBlock? = nil) -> RestrictionSpec {
    RestrictionSpec(block: RestrictionBlock(mode: mode, selectionId: list, exceptSelectionId: except),
                    window: .daily(weekdays: weekdays, startMinute: start, endMinute: end), generation: generation,
                    appearanceId: appearance, retained: retained)
}

func specJSON(_ spec: RestrictionSpec) -> String {
    WireJSON.text(spec.jsonObject)
}

func tokens(_ prefix: String, _ count: Int) -> Set<String> {
    Set((0..<count).map { "\(prefix)\($0)" })
}

final class MemoryValues: SharedValues {
    var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        values[key]
    }

    func setData(_ data: Data?, forKey key: String) {
        values[key] = data
    }
}

/// One field of a store's shield.
enum ShieldField {
    case apps
    case categories
    case webDomains
    case allWebDomains
}

/// Named stores in memory. A store in `refusing` takes a write and reads back empty, as the system
/// does past its cap; a field in `refusingFields` reads back nil while the store's others hold.
final class FakeShields: ShieldBackend {
    typealias App = String
    typealias Category = String
    typealias Web = String

    var stores: [String: Contents] = [:]
    var writes: [(name: String, contents: Contents)] = []
    var refusing: Set<String> = []
    var refusingFields: [String: Set<ShieldField>] = [:]
    var marker = false
    var renewal: ((Selection) -> TokenRenewal<String, String, String>)?

    func read(store name: String) -> Contents {
        stores[name] ?? Contents()
    }

    func write(store name: String, contents: Contents) {
        writes.append((name, contents))
        var taken = contents
        for field in refusingFields[name] ?? [] {
            switch field {
            case .apps:
                taken.apps = []
            case .categories:
                taken.categories = .none
            case .webDomains:
                taken.webDomains = []
            case .allWebDomains:
                taken.allWebDomains = false
            }
        }
        stores[name] = refusing.contains(name) || taken.isEmpty ? nil : taken
    }

    func markerHolds() -> Bool {
        marker
    }

    func writeMarker() {
        marker = true
    }

    func deleteListedStores() {}

    func renew(_ selection: Selection) -> TokenRenewal<String, String, String> {
        renewal?(selection) ?? .unavailable
    }
}

final class FakeWindows: WindowBackend {
    var running: [String: PlannedWindow] = [:]
    var log: [String] = []
    var budget = WakePlanner.windowBudget
    /// Sees the names a stop is about to end, while the store's record is as the stop finds it.
    var onStop: (([String]) -> Void)?

    func start(name: String, window: PlannedWindow) -> WindowStart {
        guard running.count < budget else {
            return .tooMany
        }
        running[name] = window
        log.append("start " + name)
        return .started
    }

    func stop(names: [String]) {
        onStop?(names)
        for name in names {
            running[name] = nil
        }
        log.append("stop " + names.joined(separator: ","))
    }

    func stopAll() {
        onStop?(Array(running.keys))
        running = [:]
        log.append("stopAll")
    }
}

/// Unchecked: a test hands it to a second thread only to hold the store's lock there.
final class Harness: @unchecked Sendable {
    let shields = FakeShields()
    let windows = FakeWindows()
    let store: RestrictionStore
    let enforcer: RestrictionEnforcer<FakeShields>
    let values = MemoryValues()
    var now: Int

    init(now: Int) {
        self.now = now
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screen-time-" + UUID().uuidString)
        store = RestrictionStore(values: values, directory: directory)
        var clockSource: (() -> Int)!
        enforcer = RestrictionEnforcer(store: store, shields: shields, windows: windows, calendar: testCalendar,
                                       clock: { clockSource() })
        clockSource = { [unowned self] in self.now }
    }

    func approve() {
        enforcer.noteApproval()
    }

    func put(_ id: String, apps: Set<String> = [], categories: Set<String> = [], web: Set<String> = []) {
        requireSuccess(enforcer.putSelection(Selection(apps: apps, categories: categories, web: web), id: id))
    }

    func set(_ slotId: String, _ spec: RestrictionSpec) -> String {
        enforcer.setRestriction(slotId: slotId, json: specJSON(spec), apple: .approved)
    }

    func drain() -> [RestrictionEvent] {
        store.drainEvents() ?? []
    }

    func restrictions() -> [String: Any] {
        WireJSON.object(enforcer.restrictions()) ?? [:]
    }

    func slot(_ slotId: String) -> [String: Any] {
        (restrictions()["slots"] as? [String: Any])?[slotId] as? [String: Any] ?? [:]
    }
}

func requireSuccess(_ code: String) {
    precondition(code.isEmpty, "a fixture's write answered \(code)")
}
