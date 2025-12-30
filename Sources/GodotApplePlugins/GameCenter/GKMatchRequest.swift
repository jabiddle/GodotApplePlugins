//
//  GKMatchRequest.swift
//  GodotApplePlugins
//
//  Created by Miguel de Icaza on 11/17/25.
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
class GKMatchRequest: RefCounted, @unchecked Sendable {
    var request = GameKit.GKMatchRequest()

    enum MatchType: Int, CaseIterable {
        case PEER_TO_PEER
        case HOSTED
        case TURN_BASED
        func toGameKit() -> GameKit.GKMatchType {
            switch self {
            case .PEER_TO_PEER: return .peerToPeer
            case .HOSTED: return .hosted
            case .TURN_BASED: return .turnBased
            }
        }
    }

    @Export var minPlayers: Int {
        get { request.minPlayers }
        set { request.minPlayers = newValue }
    }

    @Export var maxPlayers: Int {
        get { request.maxPlayers }
        set { request.maxPlayers = newValue }
    }
    @Export var defaultNumberOfPlayers: Int {
        get { request.defaultNumberOfPlayers }
        set { request.defaultNumberOfPlayers = newValue }
    }

    @Callable
    static func max_players_allowed_for_match(forType: MatchType) -> Int {
        return GameKit.GKMatchRequest.maxPlayersAllowedForMatch(of: forType.toGameKit())
    }

    @Export var inviteMessage: String {
        get { request.inviteMessage ?? "" }
        set { request.inviteMessage = newValue }
    }
}
