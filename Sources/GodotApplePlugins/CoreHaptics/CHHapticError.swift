//
//  CHHapticError.swift
//  GodotApplePlugins
//
//  Created by Jacob Biddle on 2/24/26.
//

@preconcurrency import SwiftGodotRuntime
import CoreHaptics

@Godot
class CHHapticError: RefCounted, @unchecked Sendable {
    @Export var code: Int = 0
    @Export var message: String = ""
    @Export var domain: String = ""
    
    enum Code: Int, CaseIterable {
        case BAD_EVENT_ENTRY
        case BAD_PARAMETER_ENTRY
        case ENGINE_NOT_RUNNING
        case ENGINE_START_TIMEOUT
        case FILE_NOT_FOUND
        case INSUFFICIENT_POWER
        case INVALID_AUDIO_RESOURCE
        case INVALID_AUDIO_SESSION
        case INVALID_ENGINE_PARAMETER
        case INVALID_EVENT_DURATION
        case INVALID_EVENT_TIME
        case INVALID_EVENT_TYPE
        case INVALID_PARAMETER_TYPE
        case INVALID_PATTERN_DATA
        case INVALID_PATTERN_DICTIONARY
        case INVALID_PATTERN_PLAYER
        case INVALID_TIME
        case MEMORY_ERROR
        case NOT_SUPPORTED
        case OPERATION_NOT_PERMITTED
        case RESOURCE_NOT_AVAILABLE
        case SERVER_INTERRUPTED
        case SERVER_INIT_FAILED
        case UNKNOWN_ERROR
    }
    
    convenience init(error: Error) {
        self.init()
        self.message = error.localizedDescription
        self.domain = (error as NSError).domain
        self.code = Self.mapCode(error)
    }

    static func from(_ error: Error?) -> Variant? {
        guard let error else { return nil }
        return Variant(CHHapticError(error: error))
    }

    static func mapCode(_ error: Error) -> Int {
        if let chHapticsError = error as? CoreHaptics.CHHapticError {
            switch chHapticsError.code {
            case .badEventEntry: return Code.BAD_EVENT_ENTRY.rawValue
            case .badParameterEntry: return Code.BAD_PARAMETER_ENTRY.rawValue
            case .engineNotRunning: return Code.ENGINE_NOT_RUNNING.rawValue
            case .engineStartTimeout: return Code.ENGINE_START_TIMEOUT.rawValue
            case .fileNotFound: return Code.FILE_NOT_FOUND.rawValue
            case .insufficientPower: return Code.INSUFFICIENT_POWER.rawValue
            case .invalidAudioResource: return Code.INVALID_AUDIO_RESOURCE.rawValue
            case .invalidAudioSession: return Code.INVALID_AUDIO_SESSION.rawValue
            case .invalidEngineParameter: return Code.INVALID_ENGINE_PARAMETER.rawValue
            case .invalidEventDuration: return Code.INVALID_EVENT_DURATION.rawValue
            case .invalidEventTime: return Code.INVALID_EVENT_TIME.rawValue
            case .invalidEventType: return Code.INVALID_EVENT_TYPE.rawValue
            case .invalidParameterType: return Code.INVALID_PARAMETER_TYPE.rawValue
            case .invalidPatternData: return Code.INVALID_PATTERN_DATA.rawValue
            case .invalidPatternDictionary: return Code.INVALID_PATTERN_DICTIONARY.rawValue
            case .invalidPatternPlayer: return Code.INVALID_PATTERN_PLAYER.rawValue
            case .invalidTime: return Code.INVALID_TIME.rawValue
            case .memoryError: return Code.MEMORY_ERROR.rawValue
            case .notSupported: return Code.NOT_SUPPORTED.rawValue
            case .operationNotPermitted: return Code.OPERATION_NOT_PERMITTED.rawValue
            case .resourceNotAvailable: return Code.RESOURCE_NOT_AVAILABLE.rawValue
            case .serverInterrupted: return Code.SERVER_INTERRUPTED.rawValue
            case .serverInitFailed: return Code.SERVER_INIT_FAILED.rawValue
            case .unknownError: return Code.UNKNOWN_ERROR.rawValue
                
            @unknown default: return Code.UNKNOWN_ERROR.rawValue
            }
        }
        return Code.UNKNOWN_ERROR.rawValue
    }
}
