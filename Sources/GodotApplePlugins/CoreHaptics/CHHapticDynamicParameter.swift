//
//  CHHapticDynamicParameter.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 2/24/26.
//

import CoreHaptics
@preconcurrency import SwiftGodotRuntime

@Godot
class CHHapticDynamicParameter: RefCounted, @unchecked Sendable {
    var parameter: CoreHaptics.CHHapticDynamicParameter = CoreHaptics.CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 1.0, relativeTime: 0)

    required init(_ context: InitContext) {
        super.init(context)
    }

    @Callable
    func create(parameterID: String, value: Float, relativeTime: Double) {
        self.parameter = CoreHaptics.CHHapticDynamicParameter(parameterID: CoreHaptics.CHHapticDynamicParameter.ID(rawValue: parameterID), value: value, relativeTime: relativeTime)
    }

    @Export var value: Float {
        get { parameter.value }
        set { parameter.value = newValue }
    }
    
    @Export var relativeTime: Double {
        get { parameter.relativeTime }
        set { parameter.relativeTime = newValue }
    }
}
