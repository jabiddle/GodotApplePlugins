//
//  CHHapticEngine.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 2/24/26.
//

import CoreHaptics
@preconcurrency import SwiftGodotRuntime

@Godot
class CHHapticEngine: RefCounted, @unchecked Sendable {
    var engine: CoreHaptics.CHHapticEngine?

    @Signal("stopped") var stopped: SignalWithArguments<Int> // Passes CHHapticEngine.StoppedReason.rawValue
    @Signal("reset") var reset: SimpleSignal

    required init(_ context: InitContext) {
        super.init(context)
    }
    
    @Callable
    func create() -> Variant? {
        do {
            engine = try CoreHaptics.CHHapticEngine()
            
            engine?.stoppedHandler = { reason in
                MainActor.assumeIsolated {
                    _ = self.stopped.emit(reason.rawValue)
                }
            }
            
            engine?.resetHandler = {
                MainActor.assumeIsolated {
                    _ = self.reset.emit()
                }
            }
            
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }

    @Export var playsHapticsOnly: Bool {
        get { engine?.playsHapticsOnly ?? false }
        set { engine?.playsHapticsOnly = newValue }
    }

    @Export var playsAudioOnly: Bool {
        get { engine?.playsAudioOnly ?? false }
        set { engine?.playsAudioOnly = newValue }
    }

    @Export var isMutedForAudio: Bool {
        get { engine?.isMutedForAudio ?? false }
        set { engine?.isMutedForAudio = newValue }
    }

    @Export var isMutedForHaptics: Bool {
        get { engine?.isMutedForHaptics ?? false }
        set { engine?.isMutedForHaptics = newValue }
    }

    @Export var isAutoShutdownEnabled: Bool {
        get { engine?.isAutoShutdownEnabled ?? false }
        set { engine?.isAutoShutdownEnabled = newValue }
    }

    @Export var currentTime: Double {
        engine?.currentTime ?? 0.0
    }

    @Callable
    func start(callback: Callable) {
        engine?.start { error in
            _ = callback.call(CHHapticError.from(error))
        }
    }

    @Callable
    func stop(callback: Callable) {
        engine?.stop { error in
            _ = callback.call(CHHapticError.from(error))
        }
    }

    @Callable
    func play_pattern_from_url(urlPath: String) -> Variant? {
        guard let engine = engine else { return CHHapticError.from(NSError(domain: "CHHapticEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])) }
        guard let url = URL(string: urlPath) else { return CHHapticError.from(NSError(domain: "CHHapticEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])) }
        do {
            try engine.playPattern(from: url)
            return nil
        } catch {
            return CHHapticError.from(error)
        }
    }

    @Callable
    func make_player(pattern: CHHapticPattern) -> Variant? {
        guard let engine = engine else { return CHHapticError.from(NSError(domain: "CHHapticEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])) }
        do {
            let player = try engine.makePlayer(with: pattern.pattern)
            let wrappedPlayer = CHHapticPatternPlayer(player: player)
            return Variant(wrappedPlayer)
        } catch {
            return CHHapticError.from(error)
        }
    }

    @Callable
    func make_advanced_player(pattern: CHHapticPattern) -> Variant? {
        guard let engine = engine else { return CHHapticError.from(NSError(domain: "CHHapticEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])) }
        do {
            let player = try engine.makeAdvancedPlayer(with: pattern.pattern)
            let wrappedPlayer = CHHapticAdvancedPatternPlayer(player: player)
            return Variant(wrappedPlayer)
        } catch {
            return CHHapticError.from(error)
        }
    }
}
