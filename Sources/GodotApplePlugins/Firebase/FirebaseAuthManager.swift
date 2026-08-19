//
//  FirebaseAuthManager.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 3/18/26.
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import FirebaseAuth
// `FirebaseAuth` does not re-export `FirebaseCore` (its only `@_exported` is
// `FirebaseAuthInternal`), so naming `FirebaseApp` needs this explicitly.
import FirebaseCore

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
                // ⚠️ Do not rely on `delete()` to sign this instance out. It ends in
                // `try self.auth?.signOutByForce(withUserID: self.uid)`, and `User.auth` is a
                // WEAK, `internal` back-pointer that `updateCurrentUser` does NOT reassign — so
                // a `User` that reached us from another `FirebaseApp` instance (the holding
                // slot below is one way that happens) still points at the instance that
                // rehydrated it, not at the default one. `signOutByForce` then guards on
                // `_currentUser?.uid == userID` against the WRONG instance, and the default one
                // is left reporting a `currentUser` for a uid the server no longer has: this
                // callback says success while `get_current_user_id()` keeps handing back a dead
                // uid until some later token refresh fails. Device-only, silent, no log.
                // Signing out explicitly is correct whether or not a user was ever held, so it
                // is not conditional on that.
                try? Auth.auth().signOut()
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

    // MARK: - Held User Slot
    //
    // Moves the signed-in `User` aside into a SECOND `FirebaseApp` instance and copies it back
    // on demand, so a later sign-in that displaces it does not destroy the credential. That
    // works because `Auth.saveUser` keys the keychain *account* field on
    // "\(firebaseAppName)_firebase_user" — the held user is therefore a distinct keychain item
    // and survives relaunch. (The keychain *service* is "firebase_auth_\(googleAppID)", which
    // the two instances SHARE, since the holding app is configured from the default app's own
    // options. The separation is the account field, not the service.)
    //
    // ⚠️ These four primitives decide NOTHING, deliberately. They hold whichever user is
    // current, report what the slot contains, copy it back, and clear it. Whether a session is
    // worth holding, whether restoring beats a fresh sign-in, and how long a held credential
    // stays valid are policy questions this class cannot answer — it has no clock and no
    // storage of its own — and a caller running the same policy against a non-Apple backend
    // cannot see a conditional written here. Keep those decisions in the calling code.

    /// Name of the `FirebaseApp` that owns the holding slot.
    ///
    /// ⚠️ It is part of the on-device contract rather than an implementation detail: it becomes
    /// the keychain account field, so changing it orphans whatever a previous build held.
    /// `FirebaseApp.configure(name:options:)` rejects anything outside alphanumerics, `-` and
    /// `_` with an exception, so keep it plain.
    private static let heldUserAppName = "GodotApplePluginsHeldUser"

    /// The `Auth` instance for the holding app, configuring that app on first use.
    ///
    /// ⚠️ Idempotency has to be this `app(name:)` guard, and cannot be a `try`/`catch`.
    /// Configuring a name twice reaches `FIRApp.appWasConfiguredTwice`, which for a
    /// non-extension process raises an **NSException** — uncatchable from Swift, so a second
    /// `configure` is a hard crash, not a recoverable error. That holds even when the options
    /// are identical; the "ignore the duplicate" path is gated on `isAppExtension`. This
    /// mirrors how `FirebaseCoreManager.initialize()` guards the default app.
    ///
    /// Returns `nil` only when the default app is not configured yet, i.e.
    /// `FirebaseCoreManager.initialize()` has not run. `FirebaseApp.app(name:)` logs
    /// `I-COR000004` on the miss that precedes the first configure — expected once per process,
    /// not an error.
    ///
    /// 🔴 Never call `deleteApp` on this app. A dozen `User` methods reach through the weak
    /// `User.auth` back-pointer under `guard ... else { fatalError() }`, so tearing the
    /// instance down while a `User` still points at it is a crash, not an error.
    private static func heldUserAuth() -> Auth? {
        if let existing = FirebaseApp.app(name: heldUserAppName) {
            return Auth.auth(app: existing)
        }
        guard let options = FirebaseApp.app()?.options else {
            return nil
        }
        FirebaseApp.configure(name: heldUserAppName, options: options)
        guard let configured = FirebaseApp.app(name: heldUserAppName) else {
            return nil
        }
        return Auth.auth(app: configured)
    }

    /// Copies the signed-in user into the holding slot. Resolves `(true, uid, "", "")`.
    ///
    /// Holds whichever user is current, with no eligibility test — see the ⚠️ above. A caller
    /// that only wants some sessions held has to decide that before calling, and has to compare
    /// the uid it held against the uid it ends up signed in as afterwards: this can only copy
    /// whatever `currentUser` is at the moment it runs.
    ///
    /// `updateCurrentUser` COPIES rather than moves: it only makes a `reload` round trip when
    /// the two `requestConfiguration.apiKey`s differ, and they cannot differ here because the
    /// holding app is configured from the default app's own options — so it takes the unchecked
    /// branch and never clears the source. The user is therefore not transiently signed out,
    /// and no auth-state event fires on the default instance; the listener `start_auth_listener`
    /// installs is bound to that instance with `object: self` and is structurally deaf to this
    /// one either way.
    @Callable
    func hold_current_user(callback: Callable) {
        guard let holding = Self.heldUserAuth() else {
            report(callback, false, "hold_current_user", "", "Firebase is not configured.")
            return
        }
        guard let user = Auth.auth().currentUser else {
            report(callback, false, "hold_current_user", "", "No user is signed in.")
            return
        }
        holding.updateCurrentUser(user) { error in
            if let error {
                self.report(callback, false, "hold_current_user", "", error.localizedDescription)
                return
            }
            self.report(callback, true, user.uid, "", "")
        }
    }

    /// The uid currently held, or `""` when the slot is empty.
    ///
    /// Honest on the first call after launch despite the holding instance rehydrating from the
    /// keychain asynchronously: `Auth.protectedDataInitialization` enqueues that load with
    /// `kAuthGlobalWorkQueue.async` during `init`, and `currentUser` reads back through
    /// `kAuthGlobalWorkQueue.sync`. That queue is serial, so FIFO ordering puts this read behind
    /// the load that was already queued before `heldUserAuth()` returned.
    @Callable func get_held_user_id() -> String {
        return Self.heldUserAuth()?.currentUser?.uid ?? ""
    }

    /// Copies the held user back into the default instance. Resolves `(true, uid, "", "")`.
    ///
    /// An empty slot resolves as a failure carrying payload `"no_slot"`, so a caller can tell
    /// "nothing was held" apart from "the copy failed". That is a report of what the slot
    /// contains, not a decision about what to do about it.
    ///
    /// 🔴 SUCCESS HERE IS OPTIMISTIC, and a caller that needs certainty has to add its own
    /// check. `updateCurrentUser` only makes a `reload` round trip when the two instances' API
    /// keys DIFFER, and they never do here, so the copy takes the unchecked branch and never
    /// asks the server whether the account still exists. A deleted, disabled or server-side
    /// purged account therefore restores "successfully" and surfaces much later as some
    /// unrelated token refresh failing. A forced `get_id_token(forceRefresh: true)` is the
    /// cheapest call that makes the server adjudicate the restored account.
    ///
    /// ⚠️ The restored `User`'s weak `auth` back-pointer still names whichever instance
    /// rehydrated it; `updateCurrentUser` does not reassign it and it is `internal`, so it
    /// cannot be corrected from here. `delete_current_user` compensates by signing out
    /// explicitly rather than trusting the SDK's internal `signOutByForce`.
    @Callable
    func restore_held_user(callback: Callable) {
        guard let holding = Self.heldUserAuth() else {
            report(callback, false, "restore_held_user", "", "Firebase is not configured.")
            return
        }
        guard let user = holding.currentUser else {
            report(callback, false, "restore_held_user", "no_slot", "No user is being held.")
            return
        }
        Auth.auth().updateCurrentUser(user) { error in
            if let error {
                self.report(callback, false, "restore_held_user", "", error.localizedDescription)
                return
            }
            self.report(callback, true, user.uid, "", "")
        }
    }

    /// Clears the holding slot. Best-effort and synchronous, mirroring `sign_out()`.
    ///
    /// ⚠️ On a keychain fault this leaves the slot INTACT rather than half-cleared: `signOut`
    /// routes through `updateCurrentUser(nil, byForce: false, ...)`, and `byForce: false` means
    /// the in-memory user is dropped only once the keychain write actually succeeded. So the
    /// failure is recoverable, but it is silent here — `get_held_user_id()` still returning a
    /// uid afterwards is how the caller detects it.
    @Callable
    func clear_held_user() {
        guard let holding = Self.heldUserAuth() else {
            return
        }
        try? holding.signOut()
    }
}
