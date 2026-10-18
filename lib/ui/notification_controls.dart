/// What the settings screen needs from the notification layer, kept apart
/// from the plugin so screens and tests do not depend on it.
abstract class NotificationControls {
  /// False on platforms without reminder support (everything but Android for now).
  bool get supported;

  /// Asks for the notification and exact-alarm permissions; true if reminders can fire on time.
  Future<bool> requestPermissions();

  Future<({bool notifications, bool exact})> permissionStatus();
}
