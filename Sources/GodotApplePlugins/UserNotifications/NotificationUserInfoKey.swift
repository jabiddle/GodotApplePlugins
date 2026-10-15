/// The keys a local notification's `userInfo` carries and the notification centre's delegate reads
/// back. Free of Godot, so an app extension that posts a notification compiles this same file: a
/// payload under any other key opens the app with no route and no error anywhere.
enum NotificationUserInfoKey {
    static let payload = "payload"
    static let presentInForeground = "present_in_foreground"
    static let sound = "sound"
}
