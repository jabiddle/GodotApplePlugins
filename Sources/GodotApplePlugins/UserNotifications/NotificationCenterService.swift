import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Raw values cross into GDScript verbatim through `NotificationManager.drain_pending_opens()`.
enum NotificationOpenKind: String, Sendable {
    case open
    case action
}

/// One tap, on its way from `UNUserNotificationCenter` into Godot.
///
/// `payloadJSON` is carried as text rather than a dictionary: `userInfo` accepts only
/// property-list types, and a JSON `null` anywhere in the payload is not one.
struct NotificationOpenEvent: Sendable {
    let kind: NotificationOpenKind
    let actionId: String
    let payloadJSON: String
}

protocol NotificationEventSink: AnyObject, Sendable {
    func deliverNotificationOpen(_ event: NotificationOpenEvent)
    func deliverPushToken(_ token: String)
}

/// The keys a scheduled request carries in `userInfo` and the delegate reads back out.
enum NotificationUserInfoKey {
    static let payload = "payload"
    static let presentInForeground = "present_in_foreground"
    static let sound = "sound"
}

/// A lock-guarded slot, so a value can be filled in by a completion handler and read back by the
/// caller waiting on it. Swift 6 refuses a plain captured `var` in a concurrently-executing closure.
final class NotificationBox<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var stored: Value

    init(_ initial: Value) {
        stored = initial
    }

    var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: Value) {
        lock.lock()
        stored = newValue
        lock.unlock()
    }
}

enum NotificationJSON {

    static func object(from string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parsed
    }

    static func array(from string: String) -> [Any]? {
        guard let data = string.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        return parsed
    }

    static func encode(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// A locally scheduled request stores its payload as the JSON text it was handed; a remote
    /// push arrives with the same key already decoded. Both shapes reach the delegate.
    static func payloadString(from userInfo: [AnyHashable: Any]) -> String {
        if let raw = userInfo[NotificationUserInfoKey.payload] as? String { return raw }
        if let decoded = userInfo[NotificationUserInfoKey.payload] as? [String: Any] {
            return encode(decoded) ?? "{}"
        }
        return "{}"
    }
}

/// Buffers taps and the device token on their way from the OS into Godot. Deliberately not a Godot
/// object: the tap that launched the app is delivered during scene connection, long before GDScript
/// has instantiated `NotificationManager`, and must survive that object being re-created.
final class NotificationEventQueue: @unchecked Sendable {

    static let shared = NotificationEventQueue()

    /// Cap on the backlog, so a build where GDScript never attaches cannot grow without bound.
    private static let maxBuffered = 16

    private let lock = NSLock()
    private var buffered: [NotificationOpenEvent] = []
    private var pendingToken: String?
    private weak var sink: (any NotificationEventSink)?
    private var sinkIsReady = false

    func enqueue(_ event: NotificationOpenEvent) {
        lock.lock()
        let target: (any NotificationEventSink)? = sinkIsReady ? sink : nil
        if target == nil {
            buffered.append(event)
            if buffered.count > Self.maxBuffered {
                buffered.removeFirst(buffered.count - Self.maxBuffered)
            }
        }
        lock.unlock()

        if let target {
            Self.onMain { target.deliverNotificationOpen(event) }
        }
    }

    func enqueueToken(_ token: String) {
        lock.lock()
        let target: (any NotificationEventSink)? = sinkIsReady ? sink : nil
        if target == nil {
            pendingToken = token
        }
        lock.unlock()

        if let target {
            Self.onMain { target.deliverPushToken(token) }
        }
    }

    func attach(_ newSink: any NotificationEventSink) {
        lock.lock()
        sink = newSink
        sinkIsReady = false
        lock.unlock()
    }

    func detach(_ oldSink: any NotificationEventSink) {
        lock.lock()
        // `sink` is weak and already zeroed by the time a sink's `deinit` runs, hence the nil check.
        if sink == nil || sink === oldSink {
            sink = nil
            sinkIsReady = false
        }
        lock.unlock()
    }

    /// Marks the attached sink as wired up and flushes what arrived in the meantime, closing the
    /// window between `drainPending()` and GDScript finishing its connections.
    func markReady() {
        lock.lock()
        sinkIsReady = true
        let target = sink
        let pending = buffered
        let token = pendingToken
        buffered.removeAll()
        pendingToken = nil
        lock.unlock()

        guard let target else { return }
        Self.onMain {
            for event in pending {
                target.deliverNotificationOpen(event)
            }
            if let token {
                target.deliverPushToken(token)
            }
        }
    }

    func drainPending() -> [NotificationOpenEvent] {
        lock.lock()
        defer { lock.unlock() }

        let pending = buffered
        buffered.removeAll()
        return pending
    }

    /// Signals must be emitted from Godot's main loop; inline delivery preserves arrival order.
    static func onMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

/// One relayed message on its way to whichever object owns the messaging service. `userInfo`
/// travels as-is: which of its keys are the sender's is the transport's contract, not this file's.
struct RemoteNotificationEvent: @unchecked Sendable {

    enum Arrival: Sendable {
        case foreground
        case opened
    }

    let arrival: Arrival
    let userInfo: [AnyHashable: Any]
    /// Recorded at arrival because a replay cannot recover it afterwards.
    let coldLaunch: Bool
}

protocol RemoteNotificationSink: AnyObject, Sendable {
    func deliverDeviceToken(_ token: Data)
    func deliverRemoteNotification(_ event: RemoteNotificationEvent)
}

/// The seam holding the notification centre and a messaging service apart: this half must keep
/// working when push does not, so it learns nothing of the transport beyond the one key below.
final class RemoteNotificationRelay: @unchecked Sendable {

    static let shared = RemoteNotificationRelay()

    private static let maxBuffered = 16

    /// Stamped by the transport and unwritable here, so it tells relayed from locally scheduled.
    private static let transportMessageIdKey = "gcm.message_id"

    private let lock = NSLock()
    private var buffered: [RemoteNotificationEvent] = []
    private var deviceToken: Data?
    private weak var sink: (any RemoteNotificationSink)?

    static func isRemote(_ userInfo: [AnyHashable: Any]) -> Bool {
        return userInfo[transportMessageIdKey] != nil
    }

    /// The token is a level and not an edge, so it is retained and replayed rather than consumed.
    func post(deviceToken token: Data) {
        lock.lock()
        deviceToken = token
        let target = sink
        lock.unlock()

        if let target {
            NotificationEventQueue.onMain { target.deliverDeviceToken(token) }
        }
    }

    func post(_ arrival: RemoteNotificationEvent.Arrival, userInfo: [AnyHashable: Any]) {
        lock.lock()
        let target = sink
        let event = RemoteNotificationEvent(
            arrival: arrival,
            userInfo: userInfo,
            coldLaunch: target == nil
        )
        if target == nil {
            buffered.append(event)
            if buffered.count > Self.maxBuffered {
                buffered.removeFirst(buffered.count - Self.maxBuffered)
            }
        }
        lock.unlock()

        if let target {
            NotificationEventQueue.onMain { target.deliverRemoteNotification(event) }
        }
    }

    /// ⚠️ The replay is deferred a full turn of the main loop, never inline: this runs from the
    /// subscriber's own initialiser, whose caller has connected nothing to it yet, so an inline
    /// emit reaches nobody and the event is gone. `set_ready()` is the local surface's answer to
    /// that window; this seam has none, so the hop stands in for it.
    func attach(_ newSink: any RemoteNotificationSink) {
        lock.lock()
        sink = newSink
        let pending = buffered
        let token = deviceToken
        buffered.removeAll()
        lock.unlock()

        guard !pending.isEmpty || token != nil else { return }
        DispatchQueue.main.async { [weak newSink] in
            guard let newSink else { return }
            if let token {
                newSink.deliverDeviceToken(token)
            }
            for event in pending {
                newSink.deliverRemoteNotification(event)
            }
        }
    }

    func detach(_ oldSink: any RemoteNotificationSink) {
        lock.lock()
        if sink == nil || sink === oldSink {
            sink = nil
        }
        lock.unlock()
    }
}

#if os(iOS)

/// Owns `UNUserNotificationCenter.current().delegate` and the APNs registration callbacks. Both
/// have to be in place before the scene connects: a delegate assigned later never receives the
/// notification that launched the app, and a token callback reaches an object nobody registered.
/// Neither failure produces an error anywhere.
///
/// The registration mechanism is `DeepLinkService.register()`'s, reproduced rather than shared so
/// neither feature can break the other; that file carries the why.
final class NotificationCenterService: NSObject, UNUserNotificationCenterDelegate, UIApplicationDelegate, @unchecked Sendable {

    static let shared = NotificationCenterService()

    /// Godot renamed the delegate class after 4.7, so resolve it by name at runtime rather than
    /// linking against it — it lives in the host binary, not in this framework.
    private static let delegateClassNames = [
        "GDTApplicationDelegate", // Godot 4.7
        "GDTAppDelegateIOS",      // Godot master
        "GDTAppDelegate",
    ]

    /// Called from `pluginSetupHook` at `.core` init level, which runs inside
    /// `application:didFinishLaunchingWithOptions:` — before the scene connects.
    static func register() {
        // The center holds its delegate weakly, so the singleton is what keeps this object alive.
        // A locally created delegate would be released at once and every tap would land nowhere.
        UNUserNotificationCenter.current().delegate = shared

        guard let delegateClass = resolveDelegateClass() else {
            fail("no app delegate class found (tried \(delegateClassNames.joined(separator: ", ")))")
            return
        }

        let addService = NSSelectorFromString("addService:")
        guard let method = class_getClassMethod(delegateClass, addService) else {
            fail("\(NSStringFromClass(delegateClass)) has no +addService:")
            return
        }

        typealias AddServiceFunction = @convention(c) (AnyClass, Selector, AnyObject) -> Void
        let addServiceFunction = unsafeBitCast(
            method_getImplementation(method),
            to: AddServiceFunction.self
        )
        addServiceFunction(delegateClass, addService, shared)

        installRemoteNotificationShims(on: delegateClass)
    }

    /// Only reachable if the host engine changed shape; the symptom is a token that never arrives.
    private static func fail(_ reason: String) {
        NSLog("NotificationCenterService FAILED: %@ — the APNs device token will never reach GDScript.", reason)
    }

    private static func resolveDelegateClass() -> AnyClass? {
        for name in delegateClassNames {
            if let cls = NSClassFromString(name) {
                return cls
            }
        }
        return nil
    }

    /// Godot's delegate fans a callback out to its services only for the selectors it implements
    /// itself, and it implements neither APNs callback, so registering is not on its own enough.
    /// Adding them is purely additive — never a swizzle, so nothing to chain to and no recursion.
    /// The guard also keeps the paths exclusive: where the host declares a selector this is inert
    /// and the fan-out reaches the methods below, so a token is delivered exactly once either way.
    @discardableResult
    private static func installRemoteNotificationShims(on delegateClass: AnyClass) -> Bool {
        var installed = false

        let tokenSelector = NSSelectorFromString("application:didRegisterForRemoteNotificationsWithDeviceToken:")
        if class_getInstanceMethod(delegateClass, tokenSelector) == nil {
            typealias TokenBlock = @convention(block) (AnyObject, UIApplication, NSData) -> Void
            let block: TokenBlock = { _, _, token in
                NotificationCenterService.ingest(deviceToken: token as Data)
            }
            // v = void return, @ = self, : = _cmd, @ = application, @ = token
            installed = class_addMethod(delegateClass, tokenSelector, imp_implementationWithBlock(block), "v@:@@")
        }

        let failureSelector = NSSelectorFromString("application:didFailToRegisterForRemoteNotificationsWithError:")
        if class_getInstanceMethod(delegateClass, failureSelector) == nil {
            typealias FailureBlock = @convention(block) (AnyObject, UIApplication, NSError) -> Void
            let block: FailureBlock = { _, _, error in
                NotificationCenterService.report(registrationError: error)
            }
            let added = class_addMethod(delegateClass, failureSelector, imp_implementationWithBlock(block), "v@:@@")
            installed = installed || added
        }

        return installed
    }

    /// ⚠️ Two consumers, two representations, neither substitutable: GDScript gets hex text, a
    /// messaging service the raw bytes. The wrong form is accepted in silence and addresses nobody.
    private static func ingest(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationEventQueue.shared.enqueueToken(hex)
        RemoteNotificationRelay.shared.post(deviceToken: deviceToken)
    }

    private static func report(registrationError: Error) {
        NSLog("NotificationCenterService: APNs registration failed: %@", registrationError.localizedDescription)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Self.ingest(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Self.report(registrationError: error)
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Both callbacks are `nonisolated` because this class also conforms to UIApplicationDelegate,
    // which is @MainActor: conforming to a globally isolated protocol infers that isolation for
    // the whole type, and a main-actor method cannot satisfy these nonisolated requirements. The
    // package builds in the Swift 6 language mode, so that mismatch is an error, not a warning.
    // Neither body touches main-actor state -- the payload types and the event queue are Sendable
    // -- so dropping the isolation costs nothing here and re-adding it breaks the build.

    /// The pipeline decides whether a notification may show while the app is in front; this only
    /// enforces the answer already recorded on the request.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if RemoteNotificationRelay.isRemote(userInfo) {
            RemoteNotificationRelay.shared.post(.foreground, userInfo: userInfo)
        }

        // A relayed message carries no `present_in_foreground`, so it shows nothing here by design.
        guard userInfo[NotificationUserInfoKey.presentInForeground] as? Bool == true else {
            completionHandler([])
            return
        }

        var options: UNNotificationPresentationOptions = [.banner]
        if userInfo[NotificationUserInfoKey.sound] as? Bool == true {
            options.insert(.sound)
        }
        completionHandler(options)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let identifier = response.actionIdentifier
        // A swipe-away is not an open, and routing it would foreground the app the user dismissed.
        guard identifier != UNNotificationDismissActionIdentifier else { return }

        let userInfo = response.notification.request.content.userInfo
        // Routed to the relay instead: flat transport keys rather than the single `payload` this
        // file writes, and an open owing a cold-launch bit the local queue cannot hold.
        if RemoteNotificationRelay.isRemote(userInfo) {
            RemoteNotificationRelay.shared.post(.opened, userInfo: userInfo)
            return
        }

        let payload = NotificationJSON.payloadString(from: userInfo)
        let event = identifier == UNNotificationDefaultActionIdentifier
            ? NotificationOpenEvent(kind: .open, actionId: "", payloadJSON: payload)
            : NotificationOpenEvent(kind: .action, actionId: identifier, payloadJSON: payload)
        NotificationEventQueue.shared.enqueue(event)
    }
}

#else

/// macOS has no `+addService:` registry, and the desktop build of this plugin exists only so the
/// project opens in a desktop editor. Nothing is registered there, and every `NotificationManager`
/// call answers inert rather than touching a notification centre the editor process shares.
enum NotificationCenterService {

    static func register() {}
}

#endif
