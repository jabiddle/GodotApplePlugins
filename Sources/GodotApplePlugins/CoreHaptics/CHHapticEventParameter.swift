//
//  CHHapticEventParameter.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 2/24/26.
//

import CoreHaptics
@preconcurrency import SwiftGodotRuntime

@Godot
class CHHapticEventParameter: RefCounted, @unchecked Sendable {
    var parameter: CoreHaptics.CHHapticEventParameter = CoreHaptics.CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)

    required init(_ context: InitContext) {
        super.init(context)
    }

    @Callable
    func create(parameterID: String, value: Float) {
        self.parameter = CoreHaptics.CHHapticEventParameter(parameterID: CoreHaptics.CHHapticEvent.ParameterID(rawValue: parameterID), value: value)
    }
    
    @Export var value: Float {
        get { parameter.value }
        set { parameter.value = newValue }
    }
}
