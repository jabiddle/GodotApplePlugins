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

/// How the picker sheet went away.
enum SheetAnswer {
    case picked(FamilyActivitySelection)
    /// Closed with the list unchanged, or gone without an answer.
    case cancelled
    /// Never shown, with the reason.
    case failed(String)
}

/// The system's own picker sheet, with its own buttons and words, presented over a transparent
/// host so nothing of the app's appears around it. `finish` is called exactly once, whichever way
/// the sheet goes or fails to come.
@MainActor
enum SelectionSheet {
    /// How often, and how far apart, a presentation waits for the top controller to finish a
    /// transition: UIKit drops a presentation from a controller being presented or dismissed
    /// without a word, and the sheet would then never answer.
    static let settleAttempts = 40
    static let settleNanoseconds: UInt64 = 50_000_000

    static func present(initial: FamilyActivitySelection, finish: @escaping @MainActor (SheetAnswer) -> Void) {
        let outcome = SheetOutcome(finish)
        let sheet = SelectionSheetView(initial: initial) { picked in
            outcome.close(picked.map { SheetAnswer.picked($0) } ?? .cancelled)
        }
        let controller = UIHostingController(rootView: sheet)
        controller.modalPresentationStyle = .overFullScreen
        controller.view.backgroundColor = .clear
        outcome.host = controller
        show(controller, outcome, attemptsLeft: settleAttempts)
    }

    private static func show(_ controller: UIViewController, _ outcome: SheetOutcome, attemptsLeft: Int) {
        guard let presenter = topMostViewController() else {
            outcome.answer(.failed("no window to present the picker from"))
            return
        }
        if presenter.isBeingDismissed || presenter.isBeingPresented {
            guard attemptsLeft > 0 else {
                outcome.answer(.failed("the window stayed in a transition"))
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: settleNanoseconds)
                show(controller, outcome, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        presenter.present(controller, animated: false)
        // A refused presentation calls no completion, so it is read back at once.
        if controller.presentingViewController == nil {
            outcome.answer(.failed("the picker was not presented"))
        }
    }
}

/// The one answer a presentation gives.
@MainActor
private final class SheetOutcome {
    weak var host: UIViewController?
    private var finish: (@MainActor (SheetAnswer) -> Void)?
    private var closing = false

    init(_ finish: @escaping @MainActor (SheetAnswer) -> Void) {
        self.finish = finish
    }

    /// Takes the host down first, so the app's next presentation finds the top free; a host no
    /// longer presented, or already on its way out, answers at once, since a dismissal of it would
    /// call no completion. A host UIKit presented after all, once a failure was answered, is still
    /// taken down, and its answer dropped.
    func close(_ answer: SheetAnswer) {
        guard !closing else {
            return
        }
        closing = true
        guard let host, host.presentingViewController != nil, !host.isBeingDismissed else {
            self.answer(answer)
            return
        }
        host.dismiss(animated: false) {
            self.answer(answer)
        }
    }

    func answer(_ answer: SheetAnswer) {
        let finish = finish
        self.finish = nil
        finish?(answer)
    }
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
