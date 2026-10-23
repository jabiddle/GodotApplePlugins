#if os(iOS)
import Foundation
@preconcurrency import ManagedSettings
@preconcurrency import DeviceActivity

/// The named `ManagedSettingsStore`s. Only the shield fields are written, and an empty value is
/// written as no value: a set the system reads back as nil is how it says it took none of a write.
public final class ManagedShieldBackend: ShieldBackend {
    public typealias App = ApplicationToken
    public typealias Category = ActivityCategoryToken
    public typealias Web = WebDomainToken
    public typealias Contents = ShieldContents<ApplicationToken, ActivityCategoryToken, WebDomainToken>

    public init() {}

    func store(_ name: String) -> ManagedSettingsStore {
        ManagedSettingsStore(named: ManagedSettingsStore.Name(name))
    }

    public func read(store name: String) -> Contents {
        let shield = store(name).shield
        var contents = Contents(apps: shield.applications ?? [], webDomains: shield.webDomains ?? [])
        if let policy = shield.applicationCategories {
            switch policy {
            case let .all(except):
                contents.categories = .all(except: except)
            case let .specific(categories, except):
                contents.categories = .specific(categories, except: except)
            case .none:
                contents.categories = .none
            @unknown default:
                contents.categories = .none
            }
        }
        if let policy = shield.webDomainCategories, case .all = policy {
            contents.allWebDomains = true
        }
        return contents
    }

    public func write(store name: String, contents: Contents) {
        let target = store(name)
        guard !contents.isEmpty else {
            target.clearAllSettings()
            return
        }
        target.shield.applications = contents.apps.isEmpty ? nil : contents.apps
        switch contents.categories {
        case .none:
            target.shield.applicationCategories = nil
        case let .all(except):
            target.shield.applicationCategories = .all(except: except)
        case let .specific(categories, except):
            target.shield.applicationCategories = .specific(categories, except: except)
        }
        target.shield.webDomains = contents.webDomains.isEmpty ? nil : contents.webDomains
        target.shield.webDomainCategories = contents.allWebDomains ? .all() : nil
    }

    /// A setting that restricts nothing, in a store no rebuild clears. The system removes it with
    /// every other setting at a revocation, which the running app is never told of.
    public func markerHolds() -> Bool {
        store(ShieldStoreName.marker).media.denyExplicitContent != nil
    }

    public func writeMarker() {
        store(ShieldStoreName.marker).media.denyExplicitContent = false
    }

    // Only an iOS 26.5 SDK declares the calls below, and an availability check cannot hide a name
    // the SDK lacks, so the Makefile defines IPHONEOS_SDK_26_5_OR_LATER from the SDK it builds with.
    // Without it, as in an app extension's build, nothing is deleted and no list is ever expired.

    /// From iOS 26.5, reaches a name an older build used.
    public func deleteListedStores(keeping names: Set<String>) {
#if IPHONEOS_SDK_26_5_OR_LATER
        if #available(iOS 26.5, *) {
            let stray = ManagedSettingsStore.stores.subtracting(names.map { ManagedSettingsStore.Name($0) })
            if !stray.isEmpty {
                ManagedSettingsStore.deleteStores(stray)
            }
        }
#endif
    }

    /// Whether `renew` asks the system for new tokens rather than answering `unavailable`. True
    /// where a list the system cannot renew is reported expired, and nowhere else.
    public static var renewsTokens: Bool {
#if IPHONEOS_SDK_26_5_OR_LATER
        if #available(iOS 26.5, *) {
            return true
        }
#endif
        return false
    }

    public func renew(_ selection: TokenSelection<ApplicationToken, ActivityCategoryToken, WebDomainToken>)
        -> TokenRenewal<ApplicationToken, ActivityCategoryToken, WebDomainToken> {
#if IPHONEOS_SDK_26_5_OR_LATER
        if #available(iOS 26.5, *) {
            return .renewing(selection, apps: { try ManagedSettingsStore.refresh(&$0) },
                             categories: { try ManagedSettingsStore.refresh(&$0) },
                             web: { try ManagedSettingsStore.refresh(&$0) })
        }
#endif
        return .unavailable
    }
}

/// `DeviceActivityCenter`. A window's two bounds carry the same components, the year to the second
/// from the current calendar for a window that does not repeat and the time of day for one that
/// does, and never a calendar, a time zone or an era: mixed sets have failed to fire.
public final class DeviceActivityWindowBackend: WindowBackend {
    let center = DeviceActivityCenter()
    let calendar: Calendar

    public init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    public func start(name: String, window: PlannedWindow) -> WindowStart {
        let interval: DeviceActivitySchedule
        if window.repeats {
            interval = DeviceActivitySchedule(intervalStart: timeOfDay(window.startMinute), intervalEnd: timeOfDay(window.endMinute),
                                              repeats: true)
        } else {
            interval = DeviceActivitySchedule(intervalStart: instant(window.startUnix), intervalEnd: instant(window.endUnix),
                                              repeats: false)
        }
        do {
            try center.startMonitoring(DeviceActivityName(name), during: interval)
            return .started
        } catch DeviceActivityCenter.MonitoringError.excessiveActivities {
            return .tooMany
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func stop(names: [String]) {
        guard !names.isEmpty else {
            return
        }
        center.stopMonitoring(names.map { DeviceActivityName($0) })
    }

    public func stopAll() {
        center.stopMonitoring()
    }

    /// The windows the system monitors, each as the dates it resolves to now. Reads the system's own
    /// list, which has deadlocked: the app calls it off the main thread with a time limit, and the
    /// monitor never calls it.
    public func listed() -> [String: PlannedWindow] {
        var windows: [String: PlannedWindow] = [:]
        for name in center.activities {
            guard let interval = center.schedule(for: name) else {
                continue
            }
            if interval.repeats {
                windows[name.rawValue] = .daily(start: minute(interval.intervalStart), end: minute(interval.intervalEnd))
            } else if let start = calendar.date(from: interval.intervalStart), let end = calendar.date(from: interval.intervalEnd) {
                windows[name.rawValue] = .once("", start: Int(start.timeIntervalSince1970), end: Int(end.timeIntervalSince1970))
            }
        }
        return windows
    }

    func instant(_ unix: Int) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    func timeOfDay(_ minute: Int) -> DateComponents {
        DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
    }

    func minute(_ components: DateComponents) -> Int {
        (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

public typealias ManagedRestrictionEnforcer = RestrictionEnforcer<ManagedShieldBackend>

public extension RestrictionEnforcer where Shields == ManagedShieldBackend {
    /// The enforcer over an App Group's store, the one the app and every extension run. Nil when
    /// this process is not entitled to the group.
    static func inAppGroup(_ identifier: String) -> ManagedRestrictionEnforcer? {
        guard let store = RestrictionStore.inAppGroup(identifier) else {
            return nil
        }
        return ManagedRestrictionEnforcer(store: store, shields: ManagedShieldBackend(), windows: DeviceActivityWindowBackend())
    }
}
#endif
