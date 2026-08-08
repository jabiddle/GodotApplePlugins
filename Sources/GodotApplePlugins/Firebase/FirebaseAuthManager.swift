//
//  FirebaseAuthManager.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 3/18/26.
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import FirebaseAuth

@Godot
class FirebaseAuthManager: RefCounted, @unchecked Sendable {
    
    private var authStateHandle: AuthStateDidChangeListenerHandle?
    
    // MARK: - Continuous Listener
    
    /// Starts a persistent auth state listener. The callback fires on every
    /// auth state change for the lifetime of the session.
    /// Callback signature: (is_logged_in: Bool, uid: String, event_type: String)
    @Callable
    func start_auth_listener(callback: Callable) {
        if authStateHandle == nil {
            authStateHandle = Auth.auth().addStateDidChangeListener { auth, user in
                if let user = user {
                    let uid = user.uid
                    let _ = callback.callDeferred(Variant(true), Variant(uid), Variant("state_change"))
                } else {
                    let _ = callback.callDeferred(Variant(false), Variant(""), Variant("state_change"))
                }
            }
        }
    }
    
    @Callable
    func stop_auth_listener() {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
            authStateHandle = nil
        }
    }
    
    // MARK: - One-Off Operations
    // All one-off operations accept a trailing callback Callable.
    // Callback signature: (success: Bool, resource_id: String, payload: String, error_msg: String)
    //   - resource_id: uid on success, provider or operation name on failure
    //   - payload: "link_conflict", "user_not_found", or "" on success/generic error
    //   - error_msg: human-readable error string, or "" on success
    
    @Callable
    func sign_in_anonymously(callback: Callable) {
        Auth.auth().signInAnonymously { authResult, error in
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant("sign_in_anonymously"), Variant(""), Variant(errorDesc))
            } else if let user = authResult?.user {
                let uid = user.uid
                let _ = callback.callDeferred(Variant(true), Variant(uid), Variant(""), Variant(""))
            }
        }
    }
    
    @Callable
    func sign_in_with_google(idToken: String, accessToken: String, forceSignIn: Bool, autoCreate: Bool, callback: Callable) {
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        handle_credential(credential: credential, forceSignIn: forceSignIn, autoCreate: autoCreate, callback: callback)
    }

    @Callable
    func sign_in_with_apple(idToken: String, rawNonce: String, forceSignIn: Bool, autoCreate: Bool, callback: Callable) {
        let credential = OAuthProvider.credential(providerID: .apple, idToken: idToken, rawNonce: rawNonce)
        handle_credential(credential: credential, forceSignIn: forceSignIn, autoCreate: autoCreate, callback: callback)
    }

    private func report(_ callback: Callable, _ success: Bool, _ resourceID: String, _ payload: String, _ errorMsg: String) {
        let _ = callback.callDeferred(Variant(success), Variant(resourceID), Variant(payload), Variant(errorMsg))
    }

    /// `forceSignIn` selects the intent: `false` attaches the credential to the account
    /// that is already signed in, `true` signs in as whoever owns the credential.
    /// `autoCreate` mirrors the REST `autoCreate` flag — when `false`, a credential that
    /// belongs to no account must report `user_not_found` rather than quietly provisioning one.
    private func handle_credential(credential: AuthCredential, forceSignIn: Bool, autoCreate: Bool, callback: Callable) {
        let currentUser = Auth.auth().currentUser

        if !forceSignIn, let currentUser {
            // Link onto the signed-in account whatever it is. Gating this on
            // `isAnonymous` is what turned "link Apple to my Google account" into
            // "sign in as a brand new Apple account".
            currentUser.link(with: credential) { authResult, error in
                if let error {
                    self.report_link_error(error, credential, callback)
                } else if let user = authResult?.user {
                    self.report(callback, true, user.uid, "", "")
                }
            }
            return
        }

        if autoCreate {
            perform_standard_sign_in(credential: credential, callback: callback)
            return
        }

        guard let currentUser else {
            // No session to protect, so sign in and roll back if that provisioned an account.
            Auth.auth().signIn(with: credential) { authResult, error in
                if let error {
                    self.report(callback, false, credential.provider, "", error.localizedDescription)
                    return
                }
                guard let authResult else { return }
                if authResult.additionalUserInfo?.isNewUser == true {
                    authResult.user.delete { _ in
                        self.report(callback, false, credential.provider, "user_not_found", "No account exists for this provider.")
                    }
                    return
                }
                self.report(callback, true, authResult.user.uid, "", "")
            }
            return
        }

        // A session exists and has to survive the lookup, so probe by linking instead of
        // by signing in: the SDK has no read-only "does this credential resolve to an
        // account" call, and signing in would strand the current account's data.
        currentUser.link(with: credential) { _, error in
            guard let error else {
                // The link succeeded, so no account owned this credential. Undo the probe
                // and let the caller ask the user before committing to a link.
                Auth.auth().currentUser?.unlink(fromProvider: credential.provider) { _, _ in
                    self.report(callback, false, credential.provider, "user_not_found", "No account exists for this provider.")
                }
                return
            }

            let nsError = error as NSError
            if nsError.domain == AuthErrorDomain, nsError.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                // An account owns it. Apple identity tokens are single use, so sign in with
                // the refreshed credential Firebase returns, not the one the probe consumed.
                let updated = nsError.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential
                self.perform_standard_sign_in(credential: updated ?? credential, callback: callback)
                return
            }

            if nsError.domain == AuthErrorDomain, nsError.code == AuthErrorCode.providerAlreadyLinked.rawValue {
                // The signed-in account already carries this provider, so an account
                // certainly exists. This is the account-deletion re-verification path.
                // The SDK rejects on local provider data without calling the server, so
                // the credential is still unspent and a real sign-in can confirm that the
                // identity actually matches (a different Apple ID yields a different uid).
                self.perform_standard_sign_in(credential: credential, callback: callback)
                return
            }

            self.report_link_error(error, credential, callback)
        }
    }

    // MARK: - Re-authentication
    //
    // Proving ownership of the signed-in account is not the same operation as signing in.
    // `signIn(with:)` happily succeeds on a credential belonging to somebody else and swaps
    // the session over to them; `reauthenticate(with:)` validates the credential against the
    // current user, fails with `.userMismatch` otherwise, and never disturbs the session.
    // Note it also does not change the current user, so no auth state listener will fire —
    // callers must treat the callback itself as the terminal signal.

    @Callable
    func reauthenticate_with_apple(idToken: String, rawNonce: String, callback: Callable) {
        let credential = OAuthProvider.credential(providerID: .apple, idToken: idToken, rawNonce: rawNonce)
        reauthenticate(credential: credential, callback: callback)
    }

    @Callable
    func reauthenticate_with_google(idToken: String, accessToken: String, callback: Callable) {
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        reauthenticate(credential: credential, callback: callback)
    }

    private func reauthenticate(credential: AuthCredential, callback: Callable) {
        guard let user = Auth.auth().currentUser else {
            report(callback, false, credential.provider, "", "No user is signed in.")
            return
        }

        user.reauthenticate(with: credential) { authResult, error in
            if let error {
                let nsError = error as NSError
                if nsError.domain == AuthErrorDomain, nsError.code == AuthErrorCode.userMismatch.rawValue {
                    self.report(callback, false, credential.provider, "user_mismatch", error.localizedDescription)
                    return
                }
                self.report(callback, false, credential.provider, "", error.localizedDescription)
                return
            }
            self.report(callback, true, authResult?.user.uid ?? user.uid, "", "")
        }
    }

    private func report_link_error(_ error: Error, _ credential: AuthCredential, _ callback: Callable) {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain &&
           (nsError.code == AuthErrorCode.credentialAlreadyInUse.rawValue ||
            nsError.code == AuthErrorCode.emailAlreadyInUse.rawValue) {
            report(callback, false, credential.provider, "link_conflict", error.localizedDescription)
            return
        }
        // Deliberately no sign-in fallback here: a transient link failure must not
        // silently move the player onto a different account.
        report(callback, false, credential.provider, "", error.localizedDescription)
    }

    private func perform_standard_sign_in(credential: AuthCredential, callback: Callable) {
        Auth.auth().signIn(with: credential) { authResult, error in
            if let error = error {
                let nsError = error as NSError
                if nsError.domain == AuthErrorDomain && nsError.code == AuthErrorCode.userNotFound.rawValue {
                    self.report(callback, false, credential.provider, "user_not_found", error.localizedDescription)
                } else {
                    self.report(callback, false, credential.provider, "", error.localizedDescription)
                }
            } else if let user = authResult?.user {
                self.report(callback, true, user.uid, "", "")
            }
        }
    }
    
    @Callable
    func create_user_with_email_and_password(email: String, password: String, callback: Callable) {
        Auth.auth().createUser(withEmail: email, password: password) { authResult, error in
            if let error = error {
                let _ = callback.callDeferred(Variant(false), Variant("email_auth"), Variant(""), Variant(error.localizedDescription))
            } else if let user = authResult?.user {
                let uid = user.uid
                let _ = callback.callDeferred(Variant(true), Variant(uid), Variant(""), Variant(""))
            }
        }
    }
    
    @Callable
    func sign_in_with_email_and_password(email: String, password: String, callback: Callable) {
        Auth.auth().signIn(withEmail: email, password: password) { authResult, error in
            if let error = error {
                let _ = callback.callDeferred(Variant(false), Variant("email_auth"), Variant(""), Variant(error.localizedDescription))
            } else if let user = authResult?.user {
                let uid = user.uid
                let _ = callback.callDeferred(Variant(true), Variant(uid), Variant(""), Variant(""))
            }
        }
    }
    
    @Callable
    func unlink_provider(provider: String, callback: Callable) {
        guard let user = Auth.auth().currentUser else {
            let _ = callback.callDeferred(Variant(false), Variant(provider), Variant(""), Variant("No current user"))
            return
        }
        var providerId = provider
        if !providerId.hasSuffix(".com") {
            providerId += ".com"
        }
        user.unlink(fromProvider: providerId) { unlinkedUser, error in
            if let error = error {
                let _ = callback.callDeferred(Variant(false), Variant(provider), Variant(""), Variant(error.localizedDescription))
            } else if let user = unlinkedUser {
                let uid = user.uid
                let _ = callback.callDeferred(Variant(true), Variant(uid), Variant(""), Variant(""))
            }
        }
    }
    
    @Callable
    func delete_current_user(callback: Callable) {
        Auth.auth().currentUser?.delete { error in
            if let error = error {
                let _ = callback.callDeferred(Variant(false), Variant("delete_user"), Variant(""), Variant(error.localizedDescription))
            } else {
                let _ = callback.callDeferred(Variant(true), Variant(""), Variant(""), Variant(""))
            }
        }
    }
    
    // MARK: - Synchronous Getters
    
    @Callable
    func sign_out() {
        do {
            try Auth.auth().signOut()
        } catch {
            // signOut is best-effort; no callback needed
        }
    }
    
    @Callable func get_current_user_id() -> String {
        return Auth.auth().currentUser?.uid ?? ""
    }
    
    @Callable func get_current_user_email() -> String {
        return Auth.auth().currentUser?.email ?? ""
    }
    
    @Callable func get_current_user_display_name() -> String {
        return Auth.auth().currentUser?.displayName ?? ""
    }
    
    @Callable func get_current_auth_provider() -> String {
        if let providerData = Auth.auth().currentUser?.providerData {
            for userInfo in providerData {
                if userInfo.providerID == "apple.com" { return "apple" }
                if userInfo.providerID == "google.com" { return "google" }
            }
        }
        return "anonymous"
    }
    
    @Callable func get_linked_providers() -> Variant {
        let gDict = VariantDictionary()
        if let providerData = Auth.auth().currentUser?.providerData {
            for userInfo in providerData {
                let pid = userInfo.providerID.replacingOccurrences(of: ".com", with: "")
                let email = userInfo.email ?? userInfo.displayName ?? "Linked Account"
                gDict[Variant(pid)] = Variant(email)
            }
        }
        return Variant(gDict)
    }
    
    @Callable
    func get_id_token(forceRefresh: Bool, callback: Callable) {
        guard let user = Auth.auth().currentUser else {
            let _ = callback.callDeferred(Variant(false), Variant("get_id_token"), Variant(""), Variant("No user logged in"))
            return
        }
        user.getIDTokenForcingRefresh(forceRefresh) { token, error in
            if let error = error {
                let errorDesc = error.localizedDescription
                let _ = callback.callDeferred(Variant(false), Variant("get_id_token"), Variant(""), Variant(errorDesc))
            } else if let token = token {
                let _ = callback.callDeferred(Variant(true), Variant("get_id_token"), Variant(token), Variant(""))
            } else {
                let _ = callback.callDeferred(Variant(false), Variant("get_id_token"), Variant(""), Variant("Unknown error fetching ID token"))
            }
        }
    }
}
