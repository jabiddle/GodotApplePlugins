//
//  CHHapticPattern.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 2/24/26.
//

import CoreHaptics
@preconcurrency import SwiftGodotRuntime

//
//  CHHapticPattern.swift
//  GodotApplePlugins
//

import CoreHaptics
@preconcurrency import SwiftGodotRuntime

@Godot
class CHHapticPattern: RefCounted, @unchecked Sendable {
    var pattern: CoreHaptics.CHHapticPattern = try! CoreHaptics.CHHapticPattern(events: [], parameters: [])

    required init(_ context: InitContext) {
        super.init(context)
    }
    
    init(pattern: CoreHaptics.CHHapticPattern) {
        self.pattern = pattern
        guard let ctxt = InitContext.createObject(className: Self.godotClassName) else {
            fatalError("Could not create object")
        }
        super.init(ctxt)
    }

    @Export var duration: Double {
        pattern.duration
    }

    // MARK: - Standard Initialization
    
    @Callable
    func create(events: TypedArray<CHHapticEvent?>, parameters: TypedArray<CHHapticDynamicParameter?>) -> Variant? {
        var nativeEvents: [CoreHaptics.CHHapticEvent] = []
        for e in events {
            guard let e else { continue }
            nativeEvents.append(e.event)
        }
        
        var nativeParams: [CoreHaptics.CHHapticDynamicParameter] = []
        for p in parameters {
            guard let p else { continue }
            nativeParams.append(p.parameter)
        }

        do {
            self.pattern = try CoreHaptics.CHHapticPattern(events: nativeEvents, parameters: nativeParams)
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }

    // MARK: - JSON Mapping (AHAP Format)
    // Non-native functions to provide alternate to GDictionary by instead using JSON
    // mappings to the Apple Haptic Audio Pattern file format.
    // These provide an alternative to mapping Variant <-> Any for the expected export_dictionary
    // and create_from_dictionary methods.
    @Callable
    func create_from_json(jsonString: String) -> Variant? {
        // Convert the Godot String to native Data
        guard let data = jsonString.data(using: .utf8) else {
            return CHHapticError.from(NSError(domain: "CHHapticPattern", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON String."]))
        }
        
        do {
            // Let Apple's native parser generate the [String: Any] dictionary
            guard let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                throw NSError(domain: "CHHapticPattern", code: -1, userInfo: [NSLocalizedDescriptionKey: "JSON must be a dictionary."])
            }
            
            // Map the String keys to Apple's strict CHHapticPattern.Key type
            var hapticDict: [CoreHaptics.CHHapticPattern.Key: Any] = [:]
            for (key, value) in jsonObject {
                hapticDict[CoreHaptics.CHHapticPattern.Key(rawValue: key)] = value
            }
            
            self.pattern = try CoreHaptics.CHHapticPattern(dictionary: hapticDict)
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }
    
    @Callable
    func export_json() -> String {
        do {
            // Get the native Apple dictionary
            let hapticDict = try pattern.exportDictionary()
            
            // Convert strict keys back to standard Strings
            var swiftDict: [String: Any] = [:]
            for (key, value) in hapticDict {
                swiftDict[key.rawValue] = value
            }
            
            // Let Apple natively serialize it back to a JSON string
            let data = try JSONSerialization.data(withJSONObject: swiftDict, options: .prettyPrinted)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{ \"error\": \"\(error.localizedDescription)\" }"
        }
    }
}
