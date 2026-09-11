//
//  UIImpactFeedbackGenerator.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 9/11/26.
//

#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import SwiftGodotRuntime

/// Wraps `UIImpactFeedbackGenerator`. UIKit binds a style at construction and cannot restyle a live
/// generator, so a caller wanting several styles holds several instances.
///
/// Where UIKit is absent every generator in this family is inert, and `create` answering false is
/// the only report any of the three makes of it.
@Godot
class UIImpactFeedbackGenerator: RefCounted, @unchecked Sendable {
#if canImport(UIKit)
    var generator: UIKit.UIImpactFeedbackGenerator?
#endif

    required init(_ context: InitContext) {
        super.init(context)
    }

    /// `style` names a `FeedbackStyle` case: light, medium, heavy, rigid or soft. An unrecognised
    /// name builds nothing and answers false — substituting one hides the typo behind a haptic.
    @Callable
    func create(style: String) -> Bool {
#if canImport(UIKit)
        return MainActor.assumeIsolated { () -> Bool in
            guard let feedbackStyle = Self.feedbackStyle(named: style) else {
                GD.print("UIImpactFeedbackGenerator: no FeedbackStyle named '\(style)'")
                return false
            }
            generator = UIKit.UIImpactFeedbackGenerator(style: feedbackStyle)
            return true
        }
#else
        return false
#endif
    }

    @Callable
    func prepare() {
#if canImport(UIKit)
        MainActor.assumeIsolated { generator?.prepare() }
#endif
    }

    @Callable
    func impact_occurred() {
#if canImport(UIKit)
        MainActor.assumeIsolated { generator?.impactOccurred() }
#endif
    }

    /// `intensity` reaches UIKit unaltered: clamping to its documented 0–1 range here would rewrite
    /// a caller's value silently.
    @Callable
    func impact_occurred_with_intensity(intensity: Double) {
#if canImport(UIKit)
        MainActor.assumeIsolated { generator?.impactOccurred(intensity: CGFloat(intensity)) }
#endif
    }

#if canImport(UIKit)
    private static func feedbackStyle(named name: String) -> UIKit.UIImpactFeedbackGenerator.FeedbackStyle? {
        switch name {
        case "light": return .light
        case "medium": return .medium
        case "heavy": return .heavy
        case "rigid": return .rigid
        case "soft": return .soft
        default: return nil
        }
    }
#endif
}
