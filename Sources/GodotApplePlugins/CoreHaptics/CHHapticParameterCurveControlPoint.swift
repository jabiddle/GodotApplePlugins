//
//  CHHapticParameterCurveControlPoint.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 2/24/26.
//

import CoreHaptics
@preconcurrency import SwiftGodotRuntime

@Godot
class CHHapticParameterCurveControlPoint: RefCounted, @unchecked Sendable {
    var point: CoreHaptics.CHHapticParameterCurve.ControlPoint = CoreHaptics.CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 0)
    
    required init(_ context: InitContext) {
        super.init(context)
    }
    
    @Callable
    func create(relativeTime: Double, value: Float) {
        self.point = CoreHaptics.CHHapticParameterCurve.ControlPoint(relativeTime: relativeTime, value: value)
    }
    
    @Export var relativeTime: Double {
        get { point.relativeTime }
        set { point.relativeTime = newValue }
    }
    
    @Export var value: Float {
        get { point.value }
        set { point.value = newValue }
    }
}
