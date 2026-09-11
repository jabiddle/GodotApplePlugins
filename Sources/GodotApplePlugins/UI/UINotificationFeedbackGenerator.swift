//
//  UINotificationFeedbackGenerator.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 9/11/26.
//

#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import SwiftGodotRuntime

/// Wraps `UINotificationFeedbackGenerator`.
@Godot
class UINotificationFeedbackGenerator: RefCounted, @unchecked Sendable {
#if canImport(UIKit)
    var generator: UIKit.UINotificationFeedbackGenerator?
#endif

    required init(_ context: InitContext) {
        super.init(context)
    }

    @Callable
    func prepare() {
#if canImport(UIKit)
        MainActor.assumeIsolated { resolved().prepare() }
#endif
    }

    /// `type` names a `FeedbackType` case: success, warning or error. An unrecognised name plays
    /// nothing and answers false — substituting one hides the typo behind a haptic.
    @Callable
    func notification_occurred(type: String) -> Bool {
#if canImport(UIKit)
        return MainActor.assumeIsolated { () -> Bool in
            guard let feedbackType = Self.feedbackType(named: type) else {
                GD.print("UINotificationFeedbackGenerator: no FeedbackType named '\(type)'")
                return false
            }
            resolved().notificationOccurred(feedbackType)
            return true
        }
#else
        return false
#endif
    }

#if canImport(UIKit)
    /// UIKit's initialiser is main-actor isolated, so the generator cannot be built in `init(_:)`,
    /// which carries no isolation. It is kept rather than made per call because `prepare` warms only
    /// the instance it is sent to, and a generator discarded after each play is never warm.
    @MainActor
    private func resolved() -> UIKit.UINotificationFeedbackGenerator {
        if let generator { return generator }
        let created = UIKit.UINotificationFeedbackGenerator()
        generator = created
        return created
    }

    private static func feedbackType(named name: String) -> UIKit.UINotificationFeedbackGenerator.FeedbackType? {
        switch name {
        case "success": return .success
        case "warning": return .warning
        case "error": return .error
        default: return nil
        }
    }
#endif
}
