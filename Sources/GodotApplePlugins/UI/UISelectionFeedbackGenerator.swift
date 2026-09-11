//
//  UISelectionFeedbackGenerator.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 9/11/26.
//

#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import SwiftGodotRuntime

/// Wraps `UISelectionFeedbackGenerator`.
@Godot
class UISelectionFeedbackGenerator: RefCounted, @unchecked Sendable {
#if canImport(UIKit)
    var generator: UIKit.UISelectionFeedbackGenerator?
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

    @Callable
    func selection_changed() {
#if canImport(UIKit)
        MainActor.assumeIsolated { resolved().selectionChanged() }
#endif
    }

#if canImport(UIKit)
    /// Built on first use and kept, for the reason `UINotificationFeedbackGenerator.swift`'s
    /// `resolved` gives.
    @MainActor
    private func resolved() -> UIKit.UISelectionFeedbackGenerator {
        if let generator { return generator }
        let created = UIKit.UISelectionFeedbackGenerator()
        generator = created
        return created
    }
#endif
}
