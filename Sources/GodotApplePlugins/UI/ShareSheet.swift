@preconcurrency import SwiftGodotRuntime
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The system share sheet for one piece of text. What the text is, and what sharing it means, is
/// the caller's.
@Godot
class ShareSheet: RefCounted, @unchecked Sendable {

    /// True once the sheet is asked for; false for empty text and on a platform without one.
    /// Whether anything was then shared is not reported, and a cancel is not a failure.
    @Callable
    func share_text(text: String) -> Bool {
#if os(iOS)
        guard !text.isEmpty else { return false }
        Task { @MainActor in
            ShareSheet.present(text)
        }
        return true
#else
        return false
#endif
    }

#if os(iOS)
    @MainActor
    private static func present(_ text: String) {
        guard let top = topMostViewController() else { return }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        // An iPad presents the sheet as a popover, and UIKit raises on a popover with no anchor.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
#endif
}
