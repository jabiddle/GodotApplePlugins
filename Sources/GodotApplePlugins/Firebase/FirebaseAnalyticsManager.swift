//
//  FirebaseAnalyticsManager.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 3/18/26.
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import FirebaseAnalytics

@Godot
class FirebaseAnalyticsManager: RefCounted, @unchecked Sendable {
    
    @Callable
    func log_event(name: String, parameters: VariantDictionary) {
        var props: [String: Any] = [:]
        for key in parameters.keys() {
            if let k = String(key), let variantVal = parameters[key] {
                props[k] = FirebaseVariantConverter.variantToAny(variantVal)
            }
        }
        Analytics.logEvent(name, parameters: props)
    }
    
    @Callable
    func set_user_identifier(userId: String) {
        Analytics.setUserID(userId)
    }
    
    @Callable
    func set_user_property(name: String, value: String) {
        Analytics.setUserProperty(value, forName: name)
    }
}