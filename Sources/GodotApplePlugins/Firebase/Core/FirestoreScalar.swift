import Foundation

/// The Godot scalar a number read from Firestore becomes; nil for a value that is not a number.
/// Foundation only, so `FirestoreValueCoreTests` runs it with no Godot runtime.
public enum FirestoreScalar: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)

    /// Firestore answers a boolean with the `kCFBooleanTrue` or `kCFBooleanFalse` NSNumber, which
    /// `as? Int` accepts as 1 or 0, so the boolean is told apart by its CF type before any numeric
    /// cast. `as? Bool` cannot be that test: it accepts an integer 0 or 1 just as readily.
    public init?(_ value: Any) {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
        } else if let int = value as? Int {
            self = .int(int)
        } else if let double = value as? Double {
            self = .double(double)
        } else {
            return nil
        }
    }
}
