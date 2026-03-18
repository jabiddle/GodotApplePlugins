//
//  FirebaseCrashlyticsManager.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 3/18/26.
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import FirebaseCrashlytics

@Godot
class FirebaseCrashlyticsManager: RefCounted, @unchecked Sendable {
    
    @Callable
    func record_error(domain: String, code: Int, description: String) {
        let error = NSError(domain: domain, code: code, userInfo: [
            NSLocalizedDescriptionKey: description
        ])
        Crashlytics.crashlytics().record(error: error)
    }
    
    @Callable
    func set_user_identifier(userId: String) {
        Crashlytics.crashlytics().setUserID(userId)
    }
    
    @Callable
    func log_message(message: String) {
        Crashlytics.crashlytics().log(message)
    }
    
    @Callable
    func set_custom_key(key: String, value: String) {
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }
}