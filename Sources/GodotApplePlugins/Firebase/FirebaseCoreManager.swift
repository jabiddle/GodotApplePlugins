//
//  FirebaseCoreManager.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 3/18/26.
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import FirebaseCore

@Godot
class FirebaseCoreManager: RefCounted, @unchecked Sendable {
    
    @Callable
    func initialize() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }
}