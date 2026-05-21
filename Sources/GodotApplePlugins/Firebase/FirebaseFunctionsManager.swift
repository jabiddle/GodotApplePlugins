//
//  FirebaseFunctionsManager.swift
//  GodotApplePlugins
//

import Foundation
@preconcurrency import SwiftGodotRuntime
import FirebaseFunctions

@Godot
class FirebaseFunctionsManager: RefCounted, @unchecked Sendable {
    
    @Signal("name", "result") var function_result: SignalWithArguments<String, Variant>
    @Signal("name", "error") var function_error: SignalWithArguments<String, String>
    
    private var region: String = ""
    
    @Callable
    func setup(region: String) {
        self.region = region
    }
    
    @Callable
    func call_function(name: String, parameters: VariantDictionary) {
        let functions = region.isEmpty ? Functions.functions() : Functions.functions(region: region)
        var props: [String: Any] = [:]
        for key in parameters.keys() {
            if let k = String(key) {
                props[k] = FirebaseVariantConverter.variantToAny(parameters[key])
            }
        }
        functions.httpsCallable(name).call(props) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error as NSError? {
                var errorDesc = error.localizedDescription
                if error.domain == FunctionsErrorDomain {
                    let message = error.localizedDescription
                    if let details = error.userInfo[FunctionsErrorDetailsKey] {
                        errorDesc = "\(message) (\(details))"
                    }
                }
                DispatchQueue.main.async { self.function_error.emit(name, errorDesc) }
            } else if let data = result?.data {
                if let vData = FirebaseVariantConverter.anyToVariant(data) {
                    DispatchQueue.main.async { self.function_result.emit(name, vData) }
                } else {
                    // Fallback to null Variant if the conversion fails
                    DispatchQueue.main.async { self.function_result.emit(name, Variant()) }
                }
            } else {
                DispatchQueue.main.async { self.function_result.emit(name, Variant()) }
            }
        }
    }
}
