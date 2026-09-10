import Foundation
import FirebaseCore
import FirebaseMessaging
@preconcurrency import SwiftGodotRuntime

protocol MessagingRegistrationListener: AnyObject, Sendable {
    func deliverRegistration(_ installationId: String)
}

/// ⚠️ Owns the messaging service's delegate slot, and deliberately is not the Godot object: that
/// slot is weak, so a `RefCounted` owned by the script side would empty it the moment the
/// script dropped it. Registering by hand is this type's work only because the proxy is off.
final class FirebaseMessagingRegistrationService: NSObject, MessagingDelegate, @unchecked Sendable {

    static let shared = FirebaseMessagingRegistrationService()

    private let lock = NSLock()
    private var installationId = ""
    private var deviceToken: Data?
    private var handedOver = false
    private var registering = false
    private weak var listener: (any MessagingRegistrationListener)?

    var currentRegistration: String {
        flush()
        lock.lock()
        defer { lock.unlock() }
        return installationId
    }

    func setListener(_ newListener: any MessagingRegistrationListener) {
        lock.lock()
        listener = newListener
        let known = installationId
        lock.unlock()

        guard !known.isEmpty else { return }
        // Deferred for `RemoteNotificationRelay.attach`'s reason.
        DispatchQueue.main.async { [weak newListener] in
            newListener?.deliverRegistration(known)
        }
    }

    func clearListener(_ oldListener: any MessagingRegistrationListener) {
        lock.lock()
        if listener == nil || listener === oldListener {
            listener = nil
        }
        lock.unlock()
    }

    func ingest(deviceToken token: Data) {
        lock.lock()
        deviceToken = token
        handedOver = false
        lock.unlock()
        flush()
    }

    /// ⚠️ Retried on every read rather than done once. The Godot object is built by the script-side
    /// Firebase autoload's member initialiser, which runs before that autoload's setup reaches
    /// `FirebaseApp.configure()` — `Messaging.messaging()` there would read an unconfigured app.
    private func flush() {
        guard FirebaseApp.app() != nil else { return }

        lock.lock()
        let pending = handedOver ? nil : deviceToken
        if pending != nil {
            handedOver = true
        }
        // Auto-init announces an id only once the APNs token is in hand, so it is asked outright.
        // The flag guards an in-flight call, not the process: a refusal lets the next read retry.
        let shouldRegister = installationId.isEmpty && !registering
        if shouldRegister {
            registering = true
        }
        lock.unlock()

        guard pending != nil || shouldRegister else { return }

        let messaging = Messaging.messaging()
        messaging.delegate = self
        // ⚠️ Installation-id registration did not retire this: the service still maps the APNs
        // token onto the id itself, and an unmapped id addresses no device with nothing erroring.
        if let pending {
            messaging.apnsToken = pending
        }

        guard shouldRegister else { return }
        // 🔴 Answers an error and never an id unless the app's Info.plist carries
        // `FirebaseMessagingInstallationIdEnabled` = `<true/>`, which gates the delegate below too.
        // That key is the host export preset's, and nothing in this package can reach or assert it.
        messaging.register { [weak self] error in
            guard let error else { return }
            self?.registrationFailed(error)
        }
    }

    private func registrationFailed(_ error: Error) {
        lock.lock()
        registering = false
        lock.unlock()
        NSLog(
            "FirebaseMessagingRegistrationService: registration refused: %@",
            error.localizedDescription
        )
    }

    /// Bookkeeping the service does for itself when the proxy is on, on arrival only — an open is
    /// counted by the caller's own funnel.
    func recordArrival(_ userInfo: [AnyHashable: Any]) {
        guard FirebaseApp.app() != nil else { return }
        _ = Messaging.messaging().appDidReceiveMessage(userInfo)
    }

    /// ⚠️ The selector is spelled out because the requirement is optional and reached through
    /// `respondsToSelector:`: a signature off by a character compiles clean and is never called.
    @objc(messaging:didReceiveRegistration:)
    func messaging(_ messaging: Messaging, didReceiveRegistration id: String?) {
        guard let id, !id.isEmpty else { return }
        publish(id)
    }

    private func publish(_ id: String) {
        lock.lock()
        let changed = id != installationId
        installationId = id
        registering = false
        let target = listener
        lock.unlock()

        guard changed, let target else { return }
        NotificationEventQueue.onMain { target.deliverRegistration(id) }
    }
}

/// Publishes state and decides nothing. Capture lives elsewhere for `NotificationManager`'s own
/// reason: the launching tap arrives during scene connection, before this `RefCounted` exists.
@Godot
class FirebaseMessagingManager: RefCounted, @unchecked Sendable {

    /// ⚠️ The installation id the service registered, never the OS device token — a host that
    /// crosses them addresses a service that refuses it. `NotificationManager` owns the latter.
    @Signal("installation_id") var push_registration_updated: SignalWithArguments<String>
    @Signal("json") var push_received: SignalWithArguments<String>
    @Signal("json") var push_opened: SignalWithArguments<String>

    /// Reserved by the transport; the rest of `userInfo` is the sender's data block.
    private static let reservedKeys: Set<String> = ["aps"]
    private static let reservedPrefixes = ["gcm.", "google."]

    required init(_ context: InitContext) {
        super.init(context)
        RemoteNotificationRelay.shared.attach(self)
        FirebaseMessagingRegistrationService.shared.setListener(self)
    }

    deinit {
        RemoteNotificationRelay.shared.detach(self)
        FirebaseMessagingRegistrationService.shared.clearListener(self)
    }

    @Callable
    func get_push_registration() -> String {
        return FirebaseMessagingRegistrationService.shared.currentRegistration
    }

    private static func senderData(from userInfo: [AnyHashable: Any]) -> [String: Any] {
        var data: [String: Any] = [:]
        for (rawKey, value) in userInfo {
            guard let key = rawKey as? String,
                  !reservedKeys.contains(key),
                  !reservedPrefixes.contains(where: { key.hasPrefix($0) })
            else { continue }
            // One unrepresentable value would fail the encode of the whole object, taking every
            // other key with it, so it is dropped on its own instead.
            guard JSONSerialization.isValidJSONObject([key: value]) else { continue }
            data[key] = value
        }
        return data
    }
}

extension FirebaseMessagingManager: RemoteNotificationSink {

    func deliverDeviceToken(_ token: Data) {
        FirebaseMessagingRegistrationService.shared.ingest(deviceToken: token)
    }

    func deliverRemoteNotification(_ event: RemoteNotificationEvent) {
        let payload = Self.senderData(from: event.userInfo)
        switch event.arrival {
        case .foreground:
            FirebaseMessagingRegistrationService.shared.recordArrival(event.userInfo)
            push_received.emit(NotificationJSON.encode(payload) ?? "{}")
        case .opened:
            let opened: [String: Any] = ["payload": payload, "cold_launch": event.coldLaunch]
            push_opened.emit(NotificationJSON.encode(opened) ?? "{}")
        }
    }
}

extension FirebaseMessagingManager: MessagingRegistrationListener {

    func deliverRegistration(_ installationId: String) {
        push_registration_updated.emit(installationId)
    }
}
