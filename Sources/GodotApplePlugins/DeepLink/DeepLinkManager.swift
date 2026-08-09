#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Foundation
@preconcurrency import SwiftGodotRuntime

/// GDScript-facing surface for quick actions, universal links and custom URL schemes.
///
/// This object owns no capture logic of its own. `DeepLinkService` registers with the host app
/// delegate at extension init and pushes everything into `DeepLinkQueue`, which buffers until
/// GDScript is listening. That split matters: payloads land during app launch, well before this
/// `RefCounted` exists, and they must outlive it being released and re-created.
@Godot
class DeepLinkManager: RefCounted, @unchecked Sendable {

    @Signal var quickActionReceived: SignalWithArguments<String>
    @Signal var universalLinkReceived: SignalWithArguments<String>
    @Signal var customUrlReceived: SignalWithArguments<String>

    required init(_ context: InitContext) {
        super.init(context)
        DeepLinkLog.write("DeepLinkManager instantiated by GDScript")
        DeepLinkQueue.shared.attach(self)
    }

    deinit {
        DeepLinkQueue.shared.detach(self)
    }

    // MARK: - GDScript API

    /// Everything that arrived before GDScript was listening, oldest first, as a JSON array of
    /// `{"kind": ..., "payload": ...}`.
    ///
    /// Preferred over the `check_pending_*` getters below, which cannot express ordering across
    /// kinds and can only surface one payload per kind.
    @Callable
    func drain_pending() -> String {
        let events = DeepLinkQueue.shared.drainPending()
        let encoded = events.map { ["kind": $0.kind.rawValue, "payload": $0.payload] }

        guard let data = try? JSONSerialization.data(withJSONObject: encoded),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }

        return json
    }

    /// Called by GDScript once its handlers are connected.
    ///
    /// Until this lands, every payload is buffered — the native object existing does not mean the
    /// scene tree is listening — and anything that arrived in between is flushed here.
    @Callable
    func set_ready() {
        DeepLinkQueue.shared.markReady()
    }

    /// Lets GDScript write into the native trace.
    ///
    /// GDScript's own `print()` goes to stdout, which never reaches the unified log, so on a
    /// device the GDScript half of the pipeline is invisible in Console. Routing it through here
    /// puts both halves in one ordered trace.
    @Callable
    func log_note(message: String) {
        DeepLinkLog.write("gd: \(message)")
    }

    /// Everything the native side knows about itself, for diagnosing a release build on a device.
    ///
    /// Deep links only happen during launch on real hardware, so the useful evidence is long gone
    /// by the time any UI exists to ask for it. Returns JSON:
    ///   `registration` — did the app delegate service actually register, and which selectors are
    ///                    visible to the ObjC runtime
    ///   `queue`        — whether a sink is attached and ready, and how deep the backlog is
    ///   `trace`        — the ordered log of every pipeline event since launch
    @Callable
    func get_debug_state() -> String {
        var registration = "unavailable on this platform"
#if os(iOS) || os(macOS)
        registration = DeepLinkService.registrationReport
#endif
        let state: [String: Any] = [
            "registration": registration,
            "queue": DeepLinkQueue.shared.stateDescription(),
            "trace": DeepLinkLog.trace(),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }

        return json
    }

    /// Legacy one-shot getters, kept so the Android bridge's `has_method`/`has_signal` probes in
    /// `native_bridge.gd` keep working unchanged. Prefer `drain_pending()`.
    @Callable
    func check_pending_quick_action() -> String {
        return DeepLinkQueue.shared.drainFirst(.quickAction) ?? ""
    }

    @Callable
    func check_pending_universal_link() -> String {
        return DeepLinkQueue.shared.drainFirst(.universalLink) ?? ""
    }

    @Callable
    func check_pending_custom_url() -> String {
        return DeepLinkQueue.shared.drainFirst(.customURL) ?? ""
    }

    @Callable
    func set_quick_actions(jsonArray: String) {
#if os(iOS)
        guard let data = jsonArray.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }

        let shortcutItems: [UIApplicationShortcutItem] = items.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty,
                  let title = dict["title"] as? String, !title.isEmpty
            else { return nil }

            let subtitle = dict["subtitle"] as? String
            let iconKey = dict["icon"] as? String ?? ""
            let sfIcon = dict["sf_icon"] as? String ?? ""
            let icon = Self.resolveShortcutIcon(iconKey: iconKey, sfIcon: sfIcon)

            return UIApplicationShortcutItem(
                type: id,
                localizedTitle: title,
                localizedSubtitle: subtitle?.isEmpty == false ? subtitle : nil,
                icon: icon,
                userInfo: nil
            )
        }

        // UIApplication must be accessed on the main thread.
        DispatchQueue.main.async {
            UIApplication.shared.shortcutItems = shortcutItems
        }
#endif
    }

#if os(iOS)
    /// Maps a platform-agnostic icon key string from GDScript to a native
    /// `UIApplicationShortcutIcon`. Prioritizes a custom bundled asset if available,
    /// and falls back to an Apple SF Symbol (`sfIcon`) if the custom asset is missing.
    private static func resolveShortcutIcon(iconKey: String, sfIcon: String) -> UIApplicationShortcutIcon? {
        // Check if the custom asset actually exists in the iOS app bundle
        if !iconKey.isEmpty, UIImage(named: iconKey) != nil {
            return UIApplicationShortcutIcon(templateImageName: iconKey)
        }

        // Fall back to Apple SF Symbol
        if !sfIcon.isEmpty {
            if #available(iOS 13.0, *) {
                return UIApplicationShortcutIcon(systemImageName: sfIcon)
            }
        }

        return nil
    }
#endif
}

extension DeepLinkManager: DeepLinkSink {

    func deliverDeepLink(_ event: DeepLinkEvent) {
        DeepLinkLog.write("emitting \(event.kind.rawValue) '\(event.payload)' to GDScript")
        switch event.kind {
        case .quickAction:
            quickActionReceived.emit(event.payload)
        case .universalLink:
            universalLinkReceived.emit(event.payload)
        case .customURL:
            customUrlReceived.emit(event.payload)
        }
    }
}
