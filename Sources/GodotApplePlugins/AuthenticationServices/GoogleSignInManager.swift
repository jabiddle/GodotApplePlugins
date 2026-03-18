//
//  GoogleSignInManager.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 3/18/26.
//

import Foundation
import SwiftGodotRuntime
import GoogleSignIn

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@Godot
class GoogleSignInManager: RefCounted {
    
    #signal("sign_in_completed", arguments: ["id_token": String.self, "access_token": String.self])
    #signal("sign_in_failed", arguments: ["error": String.self])
    
    @Callable
    func sign_in() {
        DispatchQueue.main.async {
            #if os(iOS)
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow }),
                  let rootViewController = window.rootViewController else {
                self.emit(signal: "sign_in_failed", "Could not find root view controller.")
                return
            }
            let presentingOrigin = rootViewController
            #elseif os(macOS)
            guard let window = NSApplication.shared.windows.first else {
                self.emit(signal: "sign_in_failed", "Could not find main window.")
                return
            }
            let presentingOrigin = window
            #endif
            
            GIDSignIn.sharedInstance.signIn(withPresenting: presentingOrigin) { signInResult, error in
                if let error = error {
                    self.emit(signal: "sign_in_failed", error.localizedDescription)
                    return
                }
                
                guard let result = signInResult else {
                    self.emit(signal: "sign_in_failed", "Unknown sign in error.")
                    return
                }
                
                let idToken = result.user.idToken?.tokenString ?? ""
                let accessToken = result.user.accessToken.tokenString
                
                self.emit(signal: "sign_in_completed", idToken, accessToken)
            }
        }
    }
    
    @Callable
    func sign_out() {
        GIDSignIn.sharedInstance.signOut()
    }
}