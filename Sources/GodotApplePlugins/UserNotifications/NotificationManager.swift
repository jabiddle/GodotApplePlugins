import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#endif
@preconcurrency import SwiftGodotRuntime

/// GDScript-facing surface for local notifications, categories and APNs registration.
///
/// This object owns no capture logic. `NotificationCenterService` is the notification centre's
/// delegate and the app delegate's service from extension init onward, and it pushes every tap
/// into `NotificationEventQueue`, which buffers until GDScript is listening. That split matters:
/// the tap that launched the app is delivered before this `RefCounted` exists.
///
/// Nothing here knows what any notification is for. Every identifier, category, title and body is
/// a string the caller supplies.
@Godot
class NotificationManager: RefCounted, @unchecked Sendable {

    @Signal("state") var authorization_changed: SignalWithArguments<String>
    @Signal("json") var notification_opened: SignalWithArguments<String>
    @Signal("json") var notification_action: SignalWithArguments<String>
    @Signal("token") var push_token_updated: SignalWithArguments<String>

    /// Emitted by the Android plugin only — this platform has no exact-alarm permission and no
    /// `can_schedule_exact()`. Declared so the surface carries the same member names on both.
    @Signal("granted") var exact_alarm_state_changed: SignalWithArguments<Bool>

    /// Emitted once a messaging manager delivers data pushes; nothing raises it yet.
    @Signal("json") var push_received: SignalWithArguments<String>

    /// The floor `UNTimeIntervalNotificationTrigger` accepts: it rejects a non-positive interval,
    /// and a request whose instant has already passed is a normal outcome of a slow rebuild.
    private static let minimumInterval: TimeInterval = 1.0

    /// `UNUserNotificationCenter` answers only asynchronously, but two members of this surface are
    /// synchronous by contract. The completion handlers run on the framework's own queue, never on
    /// the caller's, so waiting here cannot deadlock; the bound is what keeps a changed assumption
    /// from becoming a frozen app.
    private static let readTimeout: TimeInterval = 2.0

    private static let lastKnownAuthorizationState = NotificationBox<String>("not_determined")

    required init(_ context: InitContext) {
        super.init(context)
        NotificationEventQueue.shared.attach(self)
    }

    deinit {
        NotificationEventQueue.shared.detach(self)
    }

    // MARK: - Authorization

    @Callable
    func get_authorization_state() -> String {
#if os(iOS)
        let result = NotificationBox<String>(Self.lastKnownAuthorizationState.current)
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            result.set(Self.stateString(for: settings.authorizationStatus))
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + Self.readTimeout) == .success else {
            NSLog("NotificationManager: getNotificationSettings timed out; reporting the last known state.")
            return result.current
        }

        let state = result.current
        Self.lastKnownAuthorizationState.set(state)
        return state
#else
        return "unsupported"
#endif
    }

    @Callable
    func request_authorization(options_json: String) {
#if os(iOS)
        let requested = NotificationJSON.object(from: options_json) ?? [:]
        var options: UNAuthorizationOptions = []
        if requested["alert"] as? Bool ?? true { options.insert(.alert) }
        if requested["sound"] as? Bool ?? true { options.insert(.sound) }
        if requested["badge"] as? Bool ?? true { options.insert(.badge) }

        UNUserNotificationCenter.current().requestAuthorization(options: options) { [weak self] _, error in
            if let error {
                NSLog("NotificationManager: requestAuthorization failed: %@", error.localizedDescription)
            }
            // The grant flag alone cannot distinguish a fresh denial from a cached one, and the
            // caller is told the state either way.
            self?.emitAuthorizationState()
        }
#endif
    }

    // MARK: - Categories

    /// The `channels` and `delete_channels` blocks of the payload are Android's; both platforms
    /// take one string so the caller has one call site.
    @Callable
    func create_categories(json: String) {
#if os(iOS)
        guard let root = NotificationJSON.object(from: json),
              let declared = root["categories"] as? [[String: Any]]
        else { return }

        var categories: Set<UNNotificationCategory> = []
        for entry in declared {
            guard let identifier = entry["id"] as? String, !identifier.isEmpty else { continue }
            let actions = (entry["actions"] as? [[String: Any]] ?? []).compactMap(Self.action(from:))
            categories.insert(
                UNNotificationCategory(
                    identifier: identifier,
                    actions: actions,
                    intentIdentifiers: [],
                    options: []
                )
            )
        }

        UNUserNotificationCenter.current().setNotificationCategories(categories)
#endif
    }

    // MARK: - Scheduling

    @Callable
    func schedule(request_json: String) -> String {
#if os(iOS)
        guard let request = NotificationJSON.object(from: request_json) else {
            return "request is not a JSON object"
        }
        guard let identifier = request["id"] as? String, !identifier.isEmpty else {
            return "request carries no id"
        }

        let trigger: UNNotificationTrigger
        if let rule = request["repeat"] as? [String: Any] {
            trigger = Self.calendarTrigger(from: rule)
        } else {
            guard let fireAtEpochMs = NotificationJSON.double(request["fire_at_epoch_ms"]) else {
                return "request carries no fire_at_epoch_ms"
            }
            let seconds = max(
                Self.minimumInterval,
                fireAtEpochMs / 1000.0 - Date().timeIntervalSince1970
            )
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        }

        Self.submit(request, identifier: identifier, trigger: trigger)
        return ""
#else
        return "notifications are unsupported on this platform"
#endif
    }

    @Callable
    func post_now(request_json: String) -> String {
#if os(iOS)
        guard let request = NotificationJSON.object(from: request_json) else {
            return "request is not a JSON object"
        }
        guard let identifier = request["id"] as? String, !identifier.isEmpty else {
            return "request carries no id"
        }

        Self.submit(request, identifier: identifier, trigger: nil)
        return ""
#else
        return "notifications are unsupported on this platform"
#endif
    }

    @Callable
    func cancel(ids_json: String) {
#if os(iOS)
        let identifiers = (NotificationJSON.array(from: ids_json) ?? []).compactMap { $0 as? String }
        guard !identifiers.isEmpty else { return }
        // A posted notification (`post_now`) is already delivered, and its cancellation on foreground
        // is the success case the caller relies on, so both stores are cleared, never only pending.
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
#endif
    }

    @Callable
    func list_pending() -> String {
#if os(iOS)
        let result = NotificationBox<[String]>([])
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            result.set(requests.map { $0.identifier })
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + Self.readTimeout) == .success else {
            NSLog("NotificationManager: getPendingNotificationRequests timed out; reporting none pending.")
            return "[]"
        }

        return NotificationJSON.encode(result.current) ?? "[]"
#else
        return "[]"
#endif
    }

    // MARK: - Push registration

    @Callable
    func register_for_push() {
#if os(iOS)
        // UIApplication must be touched on the main thread. The token arrives at
        // `NotificationCenterService`, not here.
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
#endif
    }

    // MARK: - Presentation and settings

    @Callable
    func set_badge(count: Int) {
#if os(iOS)
        UNUserNotificationCenter.current().setBadgeCount(count) { error in
            if let error {
                NSLog("NotificationManager: setBadgeCount failed: %@", error.localizedDescription)
            }
        }
#endif
    }

    /// `channel_id` is Android's; this platform has one per-app notification screen.
    @Callable
    func open_notification_settings(channel_id: String) {
#if os(iOS)
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
#endif
    }

    /// Channels are an Android concept, so there is never anything to report here.
    @Callable
    func get_channels_enabled() -> String {
        return "{}"
    }

    @Callable
    func get_time_zone_identifier() -> String {
        return TimeZone.current.identifier
    }

    // MARK: - Launch handshake

    /// Everything that arrived before GDScript was listening, oldest first, as a JSON array of
    /// `{"kind": ..., "action_id": ..., "payload": ...}`.
    @Callable
    func drain_pending_opens() -> String {
        let events = NotificationEventQueue.shared.drainPending()
        let encoded: [[String: Any]] = events.map { event in
            [
                "kind": event.kind.rawValue,
                "action_id": event.actionId,
                "payload": NotificationJSON.object(from: event.payloadJSON) ?? [:],
            ]
        }

        return NotificationJSON.encode(encoded) ?? "[]"
    }

    /// Called by GDScript once its handlers are connected.
    ///
    /// Until this lands every tap is buffered — the native object existing does not mean the scene
    /// tree is listening — and anything that arrived in between is flushed here.
    @Callable
    func set_ready() {
        NotificationEventQueue.shared.markReady()
    }

    // MARK: - Internals

#if os(iOS)
    private func emitAuthorizationState() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let state = Self.stateString(for: settings.authorizationStatus)
            Self.lastKnownAuthorizationState.set(state)
            guard let self else { return }
            NotificationEventQueue.onMain { self.authorization_changed.emit(state) }
        }
    }

    /// `restricted` has no `UNAuthorizationStatus` case, and `ephemeral` is reachable only from an
    /// App Clip; anything else the framework grows lands on `unsupported` rather than being
    /// guessed at.
    private static func stateString(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .provisional: return "provisional"
        case .authorized: return "authorized"
        case .denied: return "denied"
        default: return "unsupported"
        }
    }

    private static func action(from declared: [String: Any]) -> UNNotificationAction? {
        guard let identifier = declared["id"] as? String, !identifier.isEmpty,
              let title = declared["title"] as? String
        else { return nil }

        let options: UNNotificationActionOptions = declared["foreground"] as? Bool == true
            ? [.foreground]
            : []
        return UNNotificationAction(identifier: identifier, title: title, options: options)
    }

    /// The request counts Monday as 1; `DateComponents.weekday` counts Sunday as 1. A rule without
    /// a usable weekday repeats daily.
    private static func calendarTrigger(from rule: [String: Any]) -> UNCalendarNotificationTrigger {
        var components = DateComponents()
        components.hour = NotificationJSON.int(rule["hour"]) ?? 0
        components.minute = NotificationJSON.int(rule["minute"]) ?? 0
        if let weekday = NotificationJSON.int(rule["weekday"]), (1...7).contains(weekday) {
            components.weekday = (weekday % 7) + 1
        }

        return UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
    }

    private static func submit(
        _ request: [String: Any],
        identifier: String,
        trigger: UNNotificationTrigger?
    ) {
        let notification = UNNotificationRequest(
            identifier: identifier,
            content: content(from: request),
            trigger: trigger
        )

        // The only failure the framework reports arrives here, after the caller has its answer.
        UNUserNotificationCenter.current().add(notification) { error in
            if let error {
                NSLog(
                    "NotificationManager: the OS refused request %@: %@",
                    identifier,
                    error.localizedDescription
                )
            }
        }
    }

    private static func content(from request: [String: Any]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request["title"] as? String ?? ""
        content.body = request["body"] as? String ?? ""

        if let group = request["group"] as? String, !group.isEmpty {
            content.threadIdentifier = group
        }
        if let category = request["category_id"] as? String, !category.isEmpty {
            content.categoryIdentifier = category
        }

        let sound = request["sound"] as? Bool ?? false
        if sound {
            content.sound = .default
        }
        // Without the matching entitlement on the build this level is silently downgraded.
        if request["time_sensitive"] as? Bool == true {
            content.interruptionLevel = .timeSensitive
        }

        content.userInfo = [
            NotificationUserInfoKey.payload: NotificationJSON.encode(request["payload"] ?? [:]) ?? "{}",
            NotificationUserInfoKey.presentInForeground: request["present_in_foreground"] as? Bool ?? false,
            NotificationUserInfoKey.sound: sound,
        ]

        return content
    }
#endif
}

extension NotificationManager: NotificationEventSink {

    func deliverNotificationOpen(_ event: NotificationOpenEvent) {
        let json = NotificationJSON.encode([
            "action_id": event.actionId,
            "payload": NotificationJSON.object(from: event.payloadJSON) ?? [:],
        ]) ?? "{}"

        switch event.kind {
        case .open:
            notification_opened.emit(json)
        case .action:
            notification_action.emit(json)
        }
    }

    func deliverPushToken(_ token: String) {
        push_token_updated.emit(token)
    }
}
