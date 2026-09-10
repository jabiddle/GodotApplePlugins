import Foundation
import FirebaseCore
import FirebaseMessaging
@preconcurrency import SwiftGodotRuntime

protocol MessagingTokenListener: AnyObject, Sendable {
    func deliverRegistrationToken(_ token: String)
}

/// ⚠️ Owns the messaging service's delegate slot, and deliberately is not the Godot object: the
/// service holds that delegate weakly, so a `RefCounted` whose lifetime belongs to the script side
/// would empty the slot the moment the script dropped it. Handing the device token over is this
/// type's work at all only because the app-delegate proxy is disabled on the build; with the proxy
/// on, the service swizzles for that token itself and none of this exists.
final class FirebaseMessagingTokenService: NSObject, MessagingDelegate, @unchecked Sendable {

    static let shared = FirebaseMessagingTokenService()

    private let lock = NSLock()
    private var registrationToken = ""
    private var deviceToken: Data?
    private var handedOver = false
    private weak var listener: (any MessagingTokenListener)?

    var currentToken: String {
        flush()
        lock.lock()
        defer { lock.unlock() }
        return registrationToken
    }

    func setListener(_ newListener: any MessagingTokenListener) {
        lock.lock()
        listener = newListener
        let token = registrationToken
        lock.unlock()

        guard !token.isEmpty else { return }
        // Deferred for `RemoteNotificationRelay.attach`'s reason.
        DispatchQueue.main.async { [weak newListener] in
            newListener?.deliverRegistrationToken(token)
        }
    }

    func clearListener(_ oldListener: any MessagingTokenListener) {
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
    /// `FirebaseApp.configure()`, and a replayed device token lands at exactly that moment —
    /// touching `Messaging.messaging()` there would read an unconfigured app.
    private func flush() {
        guard FirebaseApp.app() != nil else { return }

        lock.lock()
        let pending = handedOver ? nil : deviceToken
        if pending != nil {
            handedOver = true
        }
        lock.unlock()

        guard let pending else { return }
        let messaging = Messaging.messaging()
        messaging.delegate = self
        messaging.apnsToken = pending
        // The delegate fires on rotation, so asking outright is the only route to a value already
        // held — otherwise a launch where nothing rotates delivers nothing at all.
        messaging.token { [weak self] token, error in
            if let error {
                NSLog(
                    "FirebaseMessagingTokenService: no registration token: %@",
                    error.localizedDescription
                )
                return
            }
            guard let token, !token.isEmpty else { return }
            self?.publish(token)
        }
    }

    /// Bookkeeping the service does for itself when the proxy is on. Taken on arrival only: an open
    /// is counted by the caller's own funnel, and twice for one message reports it as two.
    func recordArrival(_ userInfo: [AnyHashable: Any]) {
        guard FirebaseApp.app() != nil else { return }
        _ = Messaging.messaging().appDidReceiveMessage(userInfo)
    }

    @objc func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, !fcmToken.isEmpty else { return }
        publish(fcmToken)
    }

    private func publish(_ token: String) {
        lock.lock()
        let changed = token != registrationToken
        registrationToken = token
        let target = listener
        lock.unlock()

        guard changed, let target else { return }
        NotificationEventQueue.onMain { target.deliverRegistrationToken(token) }
    }
}

/// Publishes state and decides nothing. Capture lives elsewhere for the reason
/// `NotificationManager`'s does: the tap that launched the app is delivered during scene
/// connection, before this `RefCounted` exists.
@Godot
class FirebaseMessagingManager: RefCounted, @unchecked Sendable {

    /// ⚠️ The registration token, never the OS device token — a host that treats the two as
    /// interchangeable addresses one of them at a service that refuses it. The device token is
    /// `NotificationManager.apns_token_updated`.
    @Signal("token") var push_token_updated: SignalWithArguments<String>
    @Signal("json") var push_received: SignalWithArguments<String>
    @Signal("json") var push_opened: SignalWithArguments<String>

    /// Reserved by the transport on its own messages; the rest of `userInfo` is the sender's data
    /// block, the only half a caller has any use for.
    private static let reservedKeys: Set<String> = ["aps"]
    private static let reservedPrefixes = ["gcm.", "google."]

    required init(_ context: InitContext) {
        super.init(context)
        RemoteNotificationRelay.shared.attach(self)
        FirebaseMessagingTokenService.shared.setListener(self)
    }

    deinit {
        RemoteNotificationRelay.shared.detach(self)
        FirebaseMessagingTokenService.shared.clearListener(self)
    }

    @Callable
    func get_push_token() -> String {
        return FirebaseMessagingTokenService.shared.currentToken
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
        FirebaseMessagingTokenService.shared.ingest(deviceToken: token)
    }

    func deliverRemoteNotification(_ event: RemoteNotificationEvent) {
        let payload = Self.senderData(from: event.userInfo)
        switch event.arrival {
        case .foreground:
            FirebaseMessagingTokenService.shared.recordArrival(event.userInfo)
            push_received.emit(NotificationJSON.encode(payload) ?? "{}")
        case .opened:
            let opened: [String: Any] = ["payload": payload, "cold_launch": event.coldLaunch]
            push_opened.emit(NotificationJSON.encode(opened) ?? "{}")
        }
    }
}

extension FirebaseMessagingManager: MessagingTokenListener {

    func deliverRegistrationToken(_ token: String) {
        push_token_updated.emit(token)
    }
}
