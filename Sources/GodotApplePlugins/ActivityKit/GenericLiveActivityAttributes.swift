#if canImport(ActivityKit)
import Foundation
import ActivityKit

public struct GenericLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var stateJson: String
        
        public init(stateJson: String) {
            self.stateJson = stateJson
        }
    }
    
    public var attributesJson: String
    
    public init(attributesJson: String) {
        self.attributesJson = attributesJson
    }
}
#endif
