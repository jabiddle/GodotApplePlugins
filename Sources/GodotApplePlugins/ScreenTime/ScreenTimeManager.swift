import Foundation
@preconcurrency import SwiftGodotRuntime
import ScreenTimeCore
#if os(iOS)
import Combine
import ImageIO
import UIKit
@preconcurrency import FamilyControls
@preconcurrency import ManagedSettings
#endif

/// GDScript-facing surface for restricting apps through the system's Screen Time frameworks.
///
/// Every method that can fail answers `""` or one code of `RestrictionCode`; payloads are JSON
/// text; an asynchronous answer reaches the `Callable` passed last, on the main thread. The rules
/// live in `ScreenTimeCore`, which the app's extensions compile too: this class only adapts the
/// wire, presents the system's picker and asks for access. Where the frameworks are absent every
/// call answers `unsupported`.
@Godot
class ScreenTimeManager: RefCounted, @unchecked Sendable {

    @Signal("state_json") var authorization_changed: SignalWithArguments<String>
    @Signal var events_available: SimpleSignal

    /// How long the system's list of monitored windows may take; past it a reconcile compares
    /// against the store's own record alone, because the list has deadlocked. The reconcile holds
    /// the store's lock meanwhile, so this stays under `RestrictionEnforcer.wakeLockSeconds`.
    private static let listTimeout: TimeInterval = 2.0
    /// The shield extensions' memory limit is unknown, and an image decodes to four bytes a pixel.
    private static let maxImageSide = 256

    private static let unsupportedState = WireJSON.text(["status": AccessVerdict.unsupported, "was_approved": false,
                                                         "requirements": [Any]()])
    private static let unsupportedAnswer = WireJSON.text(["applied": 0, "lifted": 0, "rearmed": 0,
                                                          "errors": [RestrictionCode.unsupported], "expired_selections": [Any]()])

#if os(iOS)
    private let enforcer: ManagedRestrictionEnforcer?
    private var ready = false
    private var presenting = false
    private var statusSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
#endif

    required init(_ context: InitContext) {
#if os(iOS)
        enforcer = WidgetStateStore.appGroupIdentifier(bundleIdentifier: Bundle.main.bundleIdentifier)
            .flatMap { ManagedRestrictionEnforcer.inAppGroup($0) }
#endif
        super.init(context)
    }

    deinit {
#if os(iOS)
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let name = enforcer?.store.eventsNotification, ready {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                               CFNotificationName(name as CFString), nil)
        }
#endif
    }

    // MARK: Capabilities and access

    @Callable
    func get_capabilities() -> String {
#if os(iOS)
        var opensApp = false
        if #available(iOS 26.5, *) {
            opensApp = true
        }
        return WireJSON.text(["selection_editor": "system_sheet", "max_selection_items": 50,
                              "min_window_seconds": WakePlanner.minimumWindowSeconds, "max_windows": WakePlanner.windowBudget,
                              "web_domains": true, "shield_opens_app": opensApp, "manufacturer": "apple"])
#else
        return "{}"
#endif
    }

    /// The verdict, not the platform's raw status, which never reports a revocation to a running
    /// app and reads "never asked" after a relaunch.
    @Callable
    func get_authorization_state() -> String {
#if os(iOS)
        guard let enforcer else {
            return Self.unsupportedState
        }
        return enforcer.authorizationState(apple: Self.appleStatus())
#else
        return Self.unsupportedState
#endif
    }

    /// Resolves `(ok, state_json, code)`, `ok` only when access is approved.
    @Callable
    func request_authorization(resolver: Callable) {
#if os(iOS)
        guard enforcer != nil else {
            _ = resolver.call(Variant(false), Variant(Self.unsupportedState), Variant(RestrictionCode.unsupported))
            return
        }
        Task { @MainActor in
            var code = ""
            do {
                try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
                self.enforcer?.noteApproval()
            } catch {
                code = Self.code(for: error)
            }
            // The status publishes after the prompt returns, so a prompt that returned approved is
            // the answer until it does.
            let apple: AppleAuthorization = code.isEmpty ? .approved : Self.appleStatus()
            let approved = self.enforcer?.status(apple: apple) == AccessVerdict.approved
            if !approved && code.isEmpty {
                code = RestrictionCode.notAuthorized
            }
            let state = self.enforcer?.authorizationState(apple: apple) ?? Self.unsupportedState
            _ = resolver.call(Variant(approved), Variant(state), Variant(approved ? "" : code))
        }
#else
        _ = resolver.call(Variant(false), Variant(Self.unsupportedState), Variant(RestrictionCode.unsupported))
#endif
    }

    @Callable
    func open_settings(kind: String) -> String {
#if os(iOS)
        guard kind == "app" else {
            return RestrictionCode.unsupported
        }
        MainActor.assumeIsolated {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
        return ""
#else
        return RestrictionCode.unsupported
#endif
    }

    // MARK: Selections

    /// The system's picker over the list held under `selection_id`, or an empty one. Resolves
    /// `(ok, summary_json, code)` once: `cancelled` when closed with nothing changed, `busy` while
    /// another is up, `error: …` when it could not be shown.
    @Callable
    func present_selection_editor(selection_id: String, resolver: Callable) {
#if os(iOS)
        guard let enforcer else {
            _ = resolver.call(Variant(false), Variant(""), Variant(RestrictionCode.unsupported))
            return
        }
        let refusal: String
        if !enforcer.store.schemaMatches {
            refusal = RestrictionCode.schemaMismatch
        } else if !enforcer.mayWrite(apple: Self.appleStatus()) {
            refusal = RestrictionCode.notAuthorized
        } else if selection_id.isEmpty {
            refusal = RestrictionCode.unknownSelection
        } else if presenting {
            refusal = RestrictionCode.busy
        } else {
            refusal = ""
        }
        guard refusal.isEmpty else {
            _ = resolver.call(Variant(false), Variant(""), Variant(refusal))
            return
        }
        presenting = true
        let initial = FamilyActivitySelection(tokens: enforcer.selection(selection_id) ?? ManagedRestrictionEnforcer.Selection())
        MainActor.assumeIsolated {
            SelectionSheet.present(initial: initial) { answer in
                self.presenting = false
                switch answer {
                case .cancelled:
                    _ = resolver.call(Variant(false), Variant(""), Variant(RestrictionCode.cancelled))
                case let .failed(reason):
                    _ = resolver.call(Variant(false), Variant(""), Variant(RestrictionCode.platform(reason)))
                case let .picked(picked):
                    let code = enforcer.putSelection(picked.tokens, id: selection_id)
                    _ = resolver.call(Variant(code.isEmpty), Variant(code.isEmpty ? enforcer.summary(selection_id) : ""),
                                      Variant(code))
                }
            }
        }
#else
        _ = resolver.call(Variant(false), Variant(""), Variant(RestrictionCode.unsupported))
#endif
    }

    /// This platform's lists are the system's opaque tokens; it lists no apps and draws no icons.
    @Callable
    func list_launchable_apps() -> String {
        "[]"
    }

    @Callable
    func get_app_icon(package_name: String, size_px: Int) -> PackedByteArray {
        PackedByteArray()
    }

    /// Lists here are picked in the system's sheet, never written from a list of names.
    @Callable
    func set_selection(selection_id: String, json: String) -> String {
        RestrictionCode.unsupported
    }

    @Callable
    func get_selection_summary(selection_id: String) -> String {
#if os(iOS)
        return enforcer?.summary(selection_id) ?? WireJSON.text(["error": RestrictionCode.unsupported])
#else
        return WireJSON.text(["error": RestrictionCode.unsupported])
#endif
    }

    @Callable
    func delete_selection(selection_id: String) -> String {
#if os(iOS)
        return enforcer?.deleteSelection(selection_id) ?? RestrictionCode.unsupported
#else
        return RestrictionCode.unsupported
#endif
    }

    @Callable
    func copy_selection(from_id: String, to_id: String) -> String {
#if os(iOS)
        return enforcer?.copySelection(from: from_id, to: to_id) ?? RestrictionCode.unsupported
#else
        return RestrictionCode.unsupported
#endif
    }

    @Callable
    func union_selection(from_id: String, into_id: String) -> String {
#if os(iOS)
        return enforcer?.unionSelection(from: from_id, into: into_id) ?? RestrictionCode.unsupported
#else
        return RestrictionCode.unsupported
#endif
    }

    @Callable
    func intersect_selection(from_id: String, into_id: String) -> String {
#if os(iOS)
        return enforcer?.intersectSelection(from: from_id, into: into_id) ?? RestrictionCode.unsupported
#else
        return RestrictionCode.unsupported
#endif
    }

    @Callable
    func diff_selections(base_id: String, other_id: String) -> String {
#if os(iOS)
        return enforcer?.diffSelections(base: base_id, other: other_id) ?? WireJSON.text(["error": RestrictionCode.unsupported])
#else
        return WireJSON.text(["error": RestrictionCode.unsupported])
#endif
    }

    // MARK: Restrictions

    @Callable
    func set_restriction(slot_id: String, spec_json: String) -> String {
#if os(iOS)
        return enforcer?.setRestriction(slotId: slot_id, json: spec_json, apple: Self.appleStatus()) ?? RestrictionCode.unsupported
#else
        return RestrictionCode.unsupported
#endif
    }

    @Callable
    func suspend_restriction(slot_id: String, until_unix: Int) -> String {
#if os(iOS)
        return enforcer?.suspendRestriction(slotId: slot_id, until: until_unix) ?? RestrictionCode.unsupported
#else
        return RestrictionCode.unsupported
#endif
    }

    @Callable
    func resume_restriction(slot_id: String) -> String {
#if os(iOS)
        return enforcer?.resumeRestriction(slotId: slot_id) ?? RestrictionCode.unsupported
#else
        return RestrictionCode.unsupported
#endif
    }

    @Callable
    func clear_restriction(slot_id: String) -> String {
#if os(iOS)
        return enforcer?.clearRestriction(slotId: slot_id) ?? RestrictionCode.unsupported
#else
        return RestrictionCode.unsupported
#endif
    }

    @Callable
    func get_restrictions() -> String {
#if os(iOS)
        return enforcer?.restrictions() ?? WireJSON.text(["error": RestrictionCode.unsupported])
#else
        return WireJSON.text(["error": RestrictionCode.unsupported])
#endif
    }

    @Callable
    func reconcile_restrictions() -> String {
#if os(iOS)
        guard let enforcer else {
            return Self.unsupportedAnswer
        }
        return enforcer.reconcile(listed: Self.listedWindows())
#else
        return Self.unsupportedAnswer
#endif
    }

    @Callable
    func rebuild_restrictions() -> String {
#if os(iOS)
        return enforcer?.rebuild() ?? Self.unsupportedAnswer
#else
        return Self.unsupportedAnswer
#endif
    }

    // MARK: Appearances and the notice

    /// Kept in the App Group for the shield extensions, the image no larger than the extensions can
    /// afford to decode.
    @Callable
    func set_shield_appearance(appearance_id: String, json: String, image_png: PackedByteArray) -> String {
#if os(iOS)
        guard let enforcer else {
            return RestrictionCode.unsupported
        }
        return enforcer.setAppearance(id: appearance_id, json: json,
                                      image: image_png.asData().map { Self.boundedImage($0, maxSide: Self.maxImageSide) })
#else
        return RestrictionCode.unsupported
#endif
    }

    @Callable
    func clear_shield_appearance(appearance_id: String) -> String {
#if os(iOS)
        return enforcer?.clearAppearance(id: appearance_id) ?? RestrictionCode.unsupported
#else
        return RestrictionCode.unsupported
#endif
    }

    @Callable
    func set_service_notice(json: String) -> String {
#if os(iOS)
        return enforcer?.acceptServiceNotice(json: json) ?? RestrictionCode.unsupported
#else
        return RestrictionCode.unsupported
#endif
    }

    // MARK: Events

    @Callable
    func drain_events() -> String {
#if os(iOS)
        return enforcer?.drainEvents() ?? "[]"
#else
        return "[]"
#endif
    }

    /// Starts live delivery: `events_available` after any process appends an event, and
    /// `authorization_changed` after the platform's status publishes. Until then events wait in the
    /// queue for `drain_events`.
    @Callable
    func set_ready() {
#if os(iOS)
        guard let enforcer, !ready else {
            return
        }
        ready = true
        if let name = enforcer.store.eventsNotification {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                            { _, observer, _, _, _ in
                                                guard let observer else {
                                                    return
                                                }
                                                let manager = Unmanaged<ScreenTimeManager>.fromOpaque(observer).takeUnretainedValue()
                                                DispatchQueue.main.async {
                                                    manager.announceEvents()
                                                }
                                            }, name as CFString, nil, .deliverImmediately)
        }
        MainActor.assumeIsolated {
            // The current value too: the status may have moved since the owner last read it.
            statusSubscription = AuthorizationCenter.shared.$authorizationStatus
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.announceAuthorization()
                }
            // A window that does not repeat is the local time of an instant, so a moved clock or
            // zone moves it until it is registered again.
            for name in [UIApplication.significantTimeChangeNotification, Notification.Name.NSSystemTimeZoneDidChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.enforcer?.reregisterWindows()
                })
            }
        }
        if enforcer.store.hasQueuedEvents {
            announceEvents()
        }
#endif
    }

#if os(iOS)
    private func announceEvents() {
        if ready {
            _ = events_available.emit()
        }
    }

    private func announceAuthorization() {
        guard let enforcer else {
            return
        }
        _ = authorization_changed.emit(enforcer.authorizationState(apple: Self.appleStatus()))
    }

    private static func appleStatus() -> AppleAuthorization {
        MainActor.assumeIsolated { () -> AppleAuthorization in
            switch AuthorizationCenter.shared.authorizationStatus {
            case .approved:
                return .approved
            case .denied:
                return .denied
            default:
                return .notDetermined
            }
        }
    }

    private static func code(for error: Error) -> String {
        guard let failure = error as? FamilyControlsError else {
            return RestrictionCode.platform(error.localizedDescription)
        }
        switch failure {
        case .authorizationCanceled:
            return RestrictionCode.notAuthorized
        case .authenticationMethodUnavailable:
            return RestrictionCode.passcodeRequired
        case .restricted:
            return RestrictionCode.promptUnavailable
        default:
            return RestrictionCode.platform(failure.localizedDescription)
        }
    }

    /// The system's list read off the main thread with a time limit, because it has deadlocked;
    /// nil when it did not answer in time.
    private static func listedWindows() -> [String: PlannedWindow]? {
        WindowListing.shared.list(timeout: listTimeout)
    }

    /// The image unchanged when it fits, else a thumbnail no larger than `maxSide` a side; empty
    /// when it cannot be decoded.
    private static func boundedImage(_ data: Data, maxSide: Int) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return Data()
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? Int.max
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? Int.max
        if max(width, height) <= maxSide {
            return data
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSide,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        let output = NSMutableData()
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : Data()
    }
#endif
}

#if os(iOS)
/// One listing of the system's windows at a time. A listing that hangs keeps its thread, so a
/// listing asked for while one is still out answers nil at once rather than stranding another
/// thread at every return to the front.
private final class WindowListing: @unchecked Sendable {
    static let shared = WindowListing()

    private let lock = NSLock()
    private var outstanding = false

    /// Nil when the list did not answer within `timeout`, or an earlier listing has not answered yet.
    func list(timeout: TimeInterval) -> [String: PlannedWindow]? {
        guard claim() else {
            return nil
        }
        let answer = ListedWindows()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            answer.set(DeviceActivityWindowBackend().listed())
            self.release()
            finished.signal()
        }
        return finished.wait(timeout: .now() + timeout) == .success ? answer.value : nil
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if outstanding {
            return false
        }
        outstanding = true
        return true
    }

    private func release() {
        lock.lock()
        outstanding = false
        lock.unlock()
    }
}

private final class ListedWindows: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: PlannedWindow]?

    var value: [String: PlannedWindow]? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ windows: [String: PlannedWindow]) {
        lock.lock()
        stored = windows
        lock.unlock()
    }
}
#endif
