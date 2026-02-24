//
//  CHHapticAdvancedPatternPlayer.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 2/24/26.
//

import CoreHaptics
@preconcurrency import SwiftGodotRuntime

@Godot
class CHHapticAdvancedPatternPlayer: RefCounted, @unchecked Sendable {
    var player: CoreHaptics.CHHapticAdvancedPatternPlayer?
    
    @Signal("completed") var completed: SignalWithArguments<CHHapticError?>
    
    required init(_ context: InitContext) {
        super.init(context)
    }

    init(player: CoreHaptics.CHHapticAdvancedPatternPlayer) {
        self.player = player
        guard let ctxt = InitContext.createObject(className: Self.godotClassName) else {
            fatalError("Could not create object")
        }
        super.init(ctxt)

        self.player?.completionHandler = { [weak self] error in
            guard let self = self else { return }
            
            Task { @MainActor in
                if let error = error {
                    _ = self.completed.emit(CHHapticError(error: error))
                } else {
                    _ = self.completed.emit(nil)
                }
            }
        }
    }

    @Export var loopEnabled: Bool {
        get { player?.loopEnabled ?? false }
        set { player?.loopEnabled = newValue }
    }

    @Export var loopEnd: Double {
        get { player?.loopEnd ?? 0.0 }
        set { player?.loopEnd = newValue }
    }

    @Export var playbackRate: Float {
        get { player?.playbackRate ?? 1.0 }
        set { player?.playbackRate = newValue }
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
    func pause(atTime time: Double) -> Variant? {
        do {
            try player?.pause(atTime: time)
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }

    @Callable
    func resume(atTime time: Double) -> Variant? {
        do {
            try player?.resume(atTime: time)
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }

    @Callable
    func seek(toOffset offset: Double) -> Variant? {
        do {
            try player?.seek(toOffset: offset)
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
    func send_parameters(parameters: TypedArray<CHHapticDynamicParameter?>, atTime time: Double) -> Variant? {
        var nativeParams: [CoreHaptics.CHHapticDynamicParameter] = []
        for p in parameters {
            guard let p else { continue }
            nativeParams.append(p.parameter)
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
