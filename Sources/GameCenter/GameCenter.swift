//
//  GameCenter.swift
//  SwiftGodotAppleTemplate
//
//  Created by Miguel de Icaza on 11/15/25.
//

@preconcurrency import SwiftGodotRuntime
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

import GameKit

@Godot
class GameCenterManager: RefCounted, @unchecked Sendable {
    @Signal var authentication_error: SignalWithArguments<String>
    @Signal var authentication_result: SignalWithArguments<Bool>

    var isAuthenticated: Bool = false
    
    @Export var localPlayer: AppleLocalPlayer

    required init(_ context: InitContext) {
        localPlayer = AppleLocalPlayer()
        super.init(context)
    }

    @Callable
    func authenticate() {
        let localPlayer = GKLocalPlayer.local
        localPlayer.authenticateHandler = { viewController, error in
            GD.print("AppleLocalPlayer: authentication callback")
            MainActor.assumeIsolated {
                if let vc = viewController {
                    GD.print("Presenting VC")
                    presentOnTop(vc)
                    return
                }

                if let error = error {
                    GD.print("God an error: \(error)")
                    self.authentication_error.emit(String(describing: error))
                }
                GD.print("Raising events")
                self.isAuthenticated = GKLocalPlayer.local.isAuthenticated
                self.authentication_result.emit(self.isAuthenticated)
            }
        }
    }
}

#initSwiftExtension(cdecl: "godot_game_center_init", types: [
    GameCenterManager.self,
    AppleLocalPlayer.self,
    ApplePlayer.self,
    AppleLeaderboard.self,
    AppleLeaderboardSet.self,
    AppleAchievement.self,
    AppleAchievementDescription.self
])
