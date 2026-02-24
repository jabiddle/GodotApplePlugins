//
//  CHHapticEvent.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 2/24/26.
//

import CoreHaptics
@preconcurrency import SwiftGodotRuntime

@Godot
class CHHapticEvent: RefCounted, @unchecked Sendable {
    var event: CoreHaptics.CHHapticEvent = CoreHaptics.CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0)

    required init(_ context: InitContext) {
        super.init(context)
    }

    @Callable
    func create(eventType: String, parameters: TypedArray<CHHapticEventParameter?>, relativeTime: Double, duration: Double) {
        var nativeParams: [CoreHaptics.CHHapticEventParameter] = []
        for p in parameters {
            guard let p else { continue }
            nativeParams.append(p.parameter)
        }
        
        if duration > 0 {
            self.event = CoreHaptics.CHHapticEvent(eventType: CoreHaptics.CHHapticEvent.EventType(rawValue: eventType), parameters: nativeParams, relativeTime: relativeTime, duration: duration)
        } else {
            self.event = CoreHaptics.CHHapticEvent(eventType: CoreHaptics.CHHapticEvent.EventType(rawValue: eventType), parameters: nativeParams, relativeTime: relativeTime)
        }
    }

    @Export var relativeTime: Double {
        get { event.relativeTime }
        set { event.relativeTime = newValue }
    }

    @Export var duration: Double {
        get { event.duration }
        set { event.duration = newValue }
    }
}
