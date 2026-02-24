//
//  CHHapticPatternPlayer.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 2/24/26.
//

import CoreHaptics
@preconcurrency import SwiftGodotRuntime

@Godot
class CHHapticPatternPlayer: RefCounted, @unchecked Sendable {
    var player: CoreHaptics.CHHapticPatternPlayer?

    required init(_ context: InitContext) {
        super.init(context)
    }

    init(player: CoreHaptics.CHHapticPatternPlayer) {
        self.player = player
        guard let ctxt = InitContext.createObject(className: Self.godotClassName) else {
            fatalError("Could not create object")
        }
        super.init(ctxt)
    }

    @Export var isMuted: Bool {
        get { player?.isMuted ?? false }
        set { player?.isMuted = newValue }
    }

    @Callable
    func start(atTime time: Double) -> Variant? {
        do {
            try player?.start(atTime: time)
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }

    @Callable
    func stop(atTime time: Double) -> Variant? {
        do {
            try player?.stop(atTime: time)
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }

    @Callable
    func cancel() -> Variant? {
        do {
            try player?.cancel()
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }

    @Callable
    func send_parameters(parameters: VariantArray, atTime time: Double) -> Variant? {
        var nativeParams: [CoreHaptics.CHHapticDynamicParameter] = []
        for v in parameters {
            guard let v else { continue }
            if let p = v.asObject(CHHapticDynamicParameter.self) {
                nativeParams.append(p.parameter)
            }
        }
        
        do {
            try player?.sendParameters(nativeParams, atTime: time)
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }

    @Callable
    func schedule_parameter_curve(curve: CHHapticParameterCurve, atTime time: Double) -> Variant? {
        do {
            try player?.scheduleParameterCurve(curve.curve, atTime: time)
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }
}
