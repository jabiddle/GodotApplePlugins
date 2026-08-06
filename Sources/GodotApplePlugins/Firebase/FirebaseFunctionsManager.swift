//
//  FirebaseFunctionsManager.swift
//  GodotApplePlugins
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import FirebaseFunctions

@Godot
class FirebaseFunctionsManager: RefCounted, @unchecked Sendable {
    
    // Results are now delivered via the Callable callback accepted by call_function.
    // Callback signature: (success: Bool, name: String, result_data: Variant, error_msg: String)
    
    private var region: String = ""
    
    @Callable
    func setup(region: String) {
        self.region = region
    }
    
    @Callable
    func call_function(name: String, parameters: VariantDictionary, callback: SwiftGodotRuntime.Callable) {
        let functions = region.isEmpty ? Functions.functions() : Functions.functions(region: region)
        var props: [String: Any] = [:]
        for key in parameters.keys() {
            let k = FirebaseVariantConverter.stringifyKey(key)
            props[k] = FirebaseVariantConverter.variantToAny(parameters[key])
        }
        functions.httpsCallable(name).call(props) { result, error in
            if let error = error as NSError? {
                var errorDesc = error.localizedDescription
                if error.domain == FunctionsErrorDomain {
                    let message = error.localizedDescription
                    if let details = error.userInfo[FunctionsErrorDetailsKey] {
                        errorDesc = "\(message) (\(details))"
                    }
                }
                let _ = callback.callDeferred(Variant(false), Variant(name), Variant(""), Variant(errorDesc))
            } else if let data = result?.data {
                let vData = FirebaseVariantConverter.anyToVariant(data)
                let _ = callback.callDeferred(Variant(true), Variant(name), vData ?? Variant(""), Variant(""))
            } else {
                let _ = callback.callDeferred(Variant(true), Variant(name), Variant(""), Variant(""))
            }
        }
    }
}
