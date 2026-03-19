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
    
    @Signal("is_logged_in", "uid") var auth_state_changed: SignalWithArguments<Bool, String>
    @Signal("request_id", "token", "error") var id_token_response: SignalWithArguments<String, String, String>
    
    private var authStateHandle: AuthStateDidChangeListenerHandle?
    
    @Callable
    func sign_in_anonymously() {
        Auth.auth().signInAnonymously { [weak self] authResult, error in
            guard let self = self else { return }
            if let user = authResult?.user {
                let uid = user.uid
                DispatchQueue.main.async { self.auth_state_changed.emit(true, uid) }
            } else {
                DispatchQueue.main.async { self.auth_state_changed.emit(false, "") }
            }
        }
    }
    
    @Callable
    func sign_in_with_google(idToken: String, accessToken: String) {
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        handle_credential(credential: credential)
    }
    
    @Callable
    func sign_in_with_apple(idToken: String, rawNonce: String) {
        let credential = OAuthProvider.credential(providerID: .apple, idToken: idToken, rawNonce: rawNonce)
        handle_credential(credential: credential)
    }
    
    // Helper function to handle linking vs signing in
    private func handle_credential(credential: AuthCredential) {
        if let currentUser = Auth.auth().currentUser, currentUser.isAnonymous {
            // Attempt to link the new credential to the anonymous account
            currentUser.link(with: credential) { [weak self] authResult, error in
                guard let self = self else { return }
                
                if let _ = error {
                    // Linking failed (e.g., this Apple/Google account is already attached to another Firebase UID).
                    // Fall back to a standard sign-in, which will switch them to that existing account.
                    self.perform_standard_sign_in(credential: credential)
                } else if let user = authResult?.user {
                    let uid = user.uid
                    DispatchQueue.main.async { self.auth_state_changed.emit(true, uid) }
                }
            }
        } else {
            // No anonymous user to link to, perform standard sign in
            perform_standard_sign_in(credential: credential)
        }
    }
    
    private func perform_standard_sign_in(credential: AuthCredential) {
        Auth.auth().signIn(with: credential) { [weak self] authResult, error in
            guard let self = self else { return }
            if let user = authResult?.user {
                let uid = user.uid
                DispatchQueue.main.async { self.auth_state_changed.emit(true, uid) }
            } else {
                DispatchQueue.main.async { self.auth_state_changed.emit(false, "") }
            }
        }
    }
    
    @Callable
    func create_user_with_email_and_password(email: String, password: String) {
        Auth.auth().createUser(withEmail: email, password: password) { [weak self] authResult, error in
            guard let self = self else { return }
            if let user = authResult?.user {
                let uid = user.uid
                DispatchQueue.main.async { self.auth_state_changed.emit(true, uid) }
            } else {
                DispatchQueue.main.async { self.auth_state_changed.emit(false, "") }
            }
        }
    }
    
    @Callable
    func sign_in_with_email_and_password(email: String, password: String) {
        Auth.auth().signIn(withEmail: email, password: password) { [weak self] authResult, error in
            guard let self = self else { return }
            if let user = authResult?.user {
                let uid = user.uid
                DispatchQueue.main.async { self.auth_state_changed.emit(true, uid) }
            } else {
                DispatchQueue.main.async { self.auth_state_changed.emit(false, "") }
            }
        }
    }
    
    @Callable
    func start_auth_listener() {
        if authStateHandle == nil {
            authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] auth, user in
                guard let self = self else { return }
                if let user = user {
                    let uid = user.uid
                    DispatchQueue.main.async { self.auth_state_changed.emit(true, uid) }
                } else {
                    DispatchQueue.main.async { self.auth_state_changed.emit(false, "") }
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
    
    @Callable
    func sign_out() {
        do {
            try Auth.auth().signOut()
            self.auth_state_changed.emit(false, "")
        } catch {
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
    
    @Callable
    func get_id_token(requestId: String, forceRefresh: Bool) {
        guard let user = Auth.auth().currentUser else {
            DispatchQueue.main.async { self.id_token_response.emit(requestId, "", "No user logged in") }
            return
        }
        user.getIDTokenForcingRefresh(forceRefresh) { [weak self] token, error in
            guard let self = self else { return }
            if let error = error {
                let errorDesc = error.localizedDescription
                DispatchQueue.main.async { self.id_token_response.emit(requestId, "", errorDesc) }
            } else if let token = token {
                DispatchQueue.main.async { self.id_token_response.emit(requestId, token, "") }
            } else {
                DispatchQueue.main.async { self.id_token_response.emit(requestId, "", "Unknown error fetching ID token") }
            }
        }
    }
}