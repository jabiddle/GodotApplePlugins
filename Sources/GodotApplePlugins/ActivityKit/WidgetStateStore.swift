import Foundation

/// Where a host app and its widget extension exchange a widget's state. Free of Godot, so an
/// extension compiles this same file and cannot derive a different container.
public enum WidgetStateStore {
    public static let key = "widget_state"

    /// The host's App Group: its bundle identifier with the first component replaced by `group`.
    public static func appGroupIdentifier(bundleIdentifier: String?) -> String? {
        guard let identifier = bundleIdentifier, let dot = identifier.firstIndex(of: "."),
              identifier.index(after: dot) < identifier.endIndex else {
            return nil
        }
        return "group" + identifier[dot...]
    }
}
