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
    func sign_in_with_google(idToken: String, accessToken: String, forceSignIn: Bool, callback: Callable) {
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        handle_credential(credential: credential, forceSignIn: forceSignIn, callback: callback)
    }
    
    @Callable
    func sign_in_with_apple(idToken: String, rawNonce: String, forceSignIn: Bool, callback: Callable) {
        let credential = OAuthProvider.credential(providerID: .apple, idToken: idToken, rawNonce: rawNonce)
        handle_credential(credential: credential, forceSignIn: forceSignIn, callback: callback)
    }
    
    /// Helper that attempts account linking first, then falls back to a standard sign-in.
    private func handle_credential(credential: AuthCredential, forceSignIn: Bool, callback: Callable) {
        if !forceSignIn, let currentUser = Auth.auth().currentUser, currentUser.isAnonymous {
            currentUser.link(with: credential) { authResult, error in
                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == AuthErrorDomain &&
                       (nsError.code == AuthErrorCode.credentialAlreadyInUse.rawValue ||
                        nsError.code == AuthErrorCode.emailAlreadyInUse.rawValue) {
                        let _ = callback.callDeferred(Variant(false), Variant(credential.provider), Variant("link_conflict"), Variant(error.localizedDescription))
                    } else if nsError.domain == AuthErrorDomain && nsError.code == AuthErrorCode.userNotFound.rawValue {
                        let _ = callback.callDeferred(Variant(false), Variant(credential.provider), Variant("user_not_found"), Variant(error.localizedDescription))
                    } else {
                        // Fall back to a standard sign-in for other errors
                        self.perform_standard_sign_in(credential: credential, callback: callback)
                    }
                } else if let user = authResult?.user {
                    let uid = user.uid
                    let _ = callback.callDeferred(Variant(true), Variant(uid), Variant(""), Variant(""))
                }
            }
        } else {
            perform_standard_sign_in(credential: credential, callback: callback)
        }
    }
    
    private func perform_standard_sign_in(credential: AuthCredential, callback: Callable) {
        Auth.auth().signIn(with: credential) { authResult, error in
            if let error = error {
                let nsError = error as NSError
                if nsError.domain == AuthErrorDomain && nsError.code == AuthErrorCode.userNotFound.rawValue {
                    let _ = callback.callDeferred(Variant(false), Variant(credential.provider), Variant("user_not_found"), Variant(error.localizedDescription))
                } else {
                    let _ = callback.callDeferred(Variant(false), Variant(credential.provider), Variant(""), Variant(error.localizedDescription))
                }
            } else if let user = authResult?.user {
                let uid = user.uid
                let _ = callback.callDeferred(Variant(true), Variant(uid), Variant(""), Variant(""))
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
