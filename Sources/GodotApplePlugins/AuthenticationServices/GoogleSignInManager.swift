//
//  GoogleSignInManager.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 3/18/26.
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import GoogleSignIn

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@Godot
class GoogleSignInManager: RefCounted, @unchecked Sendable {
    
    @Signal("id_token", "access_token") var sign_in_completed: SignalWithArguments<String, String>
    @Signal("error") var sign_in_failed: SignalWithArguments<String>
    
    @Callable
    func sign_in() {
        DispatchQueue.main.async {
            #if os(iOS)
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow }),
                  let rootViewController = window.rootViewController else {
                self.sign_in_failed.emit("Could not find root view controller.")
                return
            }
            let presentingOrigin = rootViewController
            #elseif os(macOS)
            guard let window = NSApplication.shared.windows.first else {
                self.sign_in_failed.emit("Could not find main window.")
                return
            }
            let presentingOrigin = window
            #endif
            
            GIDSignIn.sharedInstance.signIn(withPresenting: presentingOrigin) { signInResult, error in
                if let error = error {
                    self.sign_in_failed.emit(error.localizedDescription)
                    return
                }
                
                guard let result = signInResult else {
                    self.sign_in_failed.emit("Unknown sign in error.")
                    return
                }
                
                let idToken = result.user.idToken?.tokenString ?? ""
                let accessToken = result.user.accessToken.tokenString
                
                self.sign_in_completed.emit(idToken, accessToken)
            }
        }
    }
    
    @Callable
    func sign_out() {
        GIDSignIn.sharedInstance.signOut()
    }
}