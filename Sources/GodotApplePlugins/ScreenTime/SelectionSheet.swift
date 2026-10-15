#if os(iOS)
import SwiftUI
import UIKit
import ScreenTimeCore
@preconcurrency import FamilyControls
@preconcurrency import ManagedSettings

extension FamilyActivitySelection {
    init(tokens: TokenSelection<ApplicationToken, ActivityCategoryToken, WebDomainToken>) {
        self.init()
        applicationTokens = tokens.apps
        categoryTokens = tokens.categories
        webDomainTokens = tokens.web
    }

    var tokens: TokenSelection<ApplicationToken, ActivityCategoryToken, WebDomainToken> {
        TokenSelection(apps: applicationTokens, categories: categoryTokens, web: webDomainTokens)
    }
}

/// The system's own picker sheet, with its own buttons and words, presented over a transparent
/// host so nothing of the app's appears around it. Closing it with the list unchanged answers nil,
/// which the wire reports as cancelled.
@MainActor
enum SelectionSheet {
    /// False when there is no window to present from, and `finish` is then never called.
    static func present(initial: FamilyActivitySelection, finish: @escaping (FamilyActivitySelection?) -> Void) -> Bool {
        guard let presenter = topMostViewController() else {
            return false
        }
        var host: UIViewController?
        let outcome = SheetOutcome()
        let sheet = SelectionSheetView(initial: initial) { picked in
            guard !outcome.finished else {
                return
            }
            outcome.finished = true
            let shown = host
            host = nil
            if let shown {
                shown.dismiss(animated: false) {
                    finish(picked)
                }
            } else {
                finish(picked)
            }
        }
        let controller = UIHostingController(rootView: sheet)
        controller.modalPresentationStyle = .overFullScreen
        controller.view.backgroundColor = .clear
        host = controller
        presenter.present(controller, animated: false)
        return true
    }
}

@MainActor
private final class SheetOutcome {
    var finished = false
}

private struct SelectionSheetView: View {
    let initial: FamilyActivitySelection
    let finish: (FamilyActivitySelection?) -> Void
    @State private var selection: FamilyActivitySelection
    @State private var shown = false

    init(initial: FamilyActivitySelection, finish: @escaping (FamilyActivitySelection?) -> Void) {
        self.initial = initial
        self.finish = finish
        _selection = State(initialValue: initial)
    }

    var body: some View {
        Color.clear
            .familyActivityPicker(isPresented: $shown, selection: $selection)
            .onAppear {
                shown = true
            }
            .onChange(of: shown) { _, isShown in
                if !isShown {
                    finish(selection.tokens == initial.tokens ? nil : selection)
                }
            }
            // The host leaving by any other way, as a crashed picker can, must still answer.
            .onDisappear {
                finish(nil)
            }
    }
}
#endif
