//
//  CHHapticParameterCurve.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 2/24/26.
//

import CoreHaptics
@preconcurrency import SwiftGodotRuntime

@Godot
class CHHapticParameterCurve: RefCounted, @unchecked Sendable {
    var curve: CoreHaptics.CHHapticParameterCurve = CoreHaptics.CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [], relativeTime: 0)
    
    required init(_ context: InitContext) {
        super.init(context)
    }
    
    @Callable
    func create(parameterID: String, controlPoints: TypedArray<CHHapticParameterCurveControlPoint?>, relativeTime: Double) {
        var nativePoints: [CoreHaptics.CHHapticParameterCurve.ControlPoint] = []
        for p in controlPoints {
            guard let p else { continue }
            nativePoints.append(p.point)
        }
        
        self.curve = CoreHaptics.CHHapticParameterCurve(parameterID: CoreHaptics.CHHapticDynamicParameter.ID(rawValue: parameterID), controlPoints: nativePoints, relativeTime: relativeTime)
    }
    
    @Export var relativeTime: Double {
        get { curve.relativeTime }
        set { curve.relativeTime = newValue }
    }
}
