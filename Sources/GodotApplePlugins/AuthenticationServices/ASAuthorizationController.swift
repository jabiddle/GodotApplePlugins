//
//  ASAuthorizationController.swift
//  GodotApplePlugins
//
//  Created by Miguel de Icaza on 12/07/25.
//

import Foundation
import AuthenticationServices
import SwiftGodotRuntime
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@Godot
class ASAuthorizationController: RefCounted, @unchecked Sendable {
    /// Can be either ASAuthorizationAppleIDCredential, ASPasswordCredential or nil for others
    @Signal("credential")
    var authorization_completed: SignalWithArguments<RefCounted?>

    @Signal("message")
    var authorization_failed: SignalWithArguments<String>

    /// Emitted when the user dismisses the system sheet instead of authorizing.
    /// This is a normal outcome, not an error, so it gets its own signal.
    @Signal
    var authorization_canceled: SimpleSignal

    var controller: AuthenticationServices.ASAuthorizationController?
    var proxy: Proxy?

    /// Bumped on every request so that callbacks belonging to a superseded or
    /// cancelled request are dropped instead of resolving the current flow.
    var generation: Int = 0

    class Proxy: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        weak var base: ASAuthorizationController?
        let generation: Int
        /// Resolved up front, because by the time AuthenticationServices asks for the
        /// anchor the app may already have resigned active for the biometric prompt.
        let anchor: ASPresentationAnchor

        init(_ base: ASAuthorizationController, generation: Int, anchor: ASPresentationAnchor) {
            self.base = base
            self.generation = generation
            self.anchor = anchor
        }

        /// Returns the owner only when it is still alive and this request is the current one.
        /// Releasing `base.controller` / `base.proxy` is deferred: `self` is reachable only
        /// through `base.proxy`, so clearing it inline would free the proxy mid-callback.
        @MainActor
        private func liveBase() -> ASAuthorizationController? {
            guard let base, base.generation == generation else { return nil }
            let gen = generation
            DispatchQueue.main.async { [weak base] in
                guard let base, base.generation == gen else { return }
                base.controller = nil
                base.proxy = nil
            }
            return base
        }

        func presentationAnchor(for controller: AuthenticationServices.ASAuthorizationController) -> ASPresentationAnchor {
            anchor
        }

        @MainActor
        func authorizationController(controller: AuthenticationServices.ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            guard let base = liveBase() else { return }

            if let appleIDCredential = authorization.credential as? AuthenticationServices.ASAuthorizationAppleIDCredential {
                let wrapped = ASAuthorizationAppleIDCredential(credential: appleIDCredential)
                base.authorization_completed.emit(wrapped)
            } else if let passwordCredential = authorization.credential as? AuthenticationServices.ASPasswordCredential {
                let wrapped = ASPasswordCredential(credential: passwordCredential)
                base.authorization_completed.emit(wrapped)
            } else {
                // Unknown credential type, might be the enterprise credential, but I dont think any games need that.
                base.authorization_completed.emit(nil)
            }
        }

        @MainActor
        func authorizationController(controller: AuthenticationServices.ASAuthorizationController, didCompleteWithError error: Error) {
            guard let base = liveBase() else { return }

            if let authError = error as? ASAuthorizationError {
                if authError.code == .canceled {
                    base.authorization_canceled.emit()
                    return
                }
                // Surface the raw code: callers need it to tell a recoverable
                // failure apart from a misconfigured entitlement (.unknown/1000).
                base.authorization_failed.emit("[\(authError.code.rawValue)] \(error.localizedDescription)")
                return
            }

            base.authorization_failed.emit(error.localizedDescription)
        }
    }

    // The more specific version of it
    @Callable
    func signin_with_scopes(scopeStrings: VariantArray) {
        _signin(scopeStrings: scopeStrings, nonce: nil)
    }

    // Overload to support Firebase nonce requirements
    @Callable
    func signin_with_scopes_and_nonce(scopeStrings: VariantArray, nonce: String) {
        _signin(scopeStrings: scopeStrings, nonce: nonce)
    }

    /// Abandons an in-flight request. Callbacks that arrive afterwards are ignored.
    @Callable
    func cancel() {
        MainActor.assumeIsolated {
            generation &+= 1
            controller?.cancel()
            controller = nil
            proxy = nil
        }
    }

    private func _signin(scopeStrings: VariantArray, nonce: String?) {
        var requestedScopes: [ASAuthorization.Scope] = []
        for vscope in scopeStrings {
            guard let scope = String(vscope) else { continue }
            if scope == "email" {
                requestedScopes.append(.email)
            } else if scope == "full_name" {
                requestedScopes.append(.fullName)
            }
        }

        MainActor.assumeIsolated {
            // Supersede anything still in flight so its callbacks can't resolve this one.
            generation &+= 1
            self.controller?.cancel()
            self.controller = nil
            self.proxy = nil

            // Without an anchor the system starts the request (the biometric prompt
            // fires) but can never present the authorization sheet, and neither
            // delegate callback is ever invoked. Fail loudly instead of hanging.
            guard let anchor = resolveAuthorizationAnchor() else {
                authorization_failed.emit("No window available to present the Sign in with Apple sheet.")
                return
            }

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()

            request.requestedScopes = requestedScopes

            if let nonce = nonce, !nonce.isEmpty {
                request.nonce = nonce
            }

            let controller = AuthenticationServices.ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller

            let proxy = Proxy(self, generation: generation, anchor: anchor)
            self.proxy = proxy

            // `delegate` is weak; `proxy` above is what keeps it alive.
            controller.delegate = proxy
            controller.presentationContextProvider = proxy

            controller.performRequests()
        }
    }

    // Just a general purpose easy-to-use version
    @Callable
    func signin() {
        let scopes = VariantArray()
        scopes.append(Variant("full_name"))
        scopes.append(Variant("email"))
        _signin(scopeStrings: scopes, nonce: nil)
    }
}

/// Godot's iOS host is scene-based, so `UIApplication.keyWindow` is nil and
/// AuthenticationServices has no window to fall back on. Walk the connected
/// scenes instead.
@MainActor
func resolveAuthorizationAnchor() -> ASPresentationAnchor? {
#if canImport(UIKit)
    if let scene = UIApplication.shared.activeWindowScene {
        if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            return window
        }
    }
    return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
#else
    return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
#endif
}
