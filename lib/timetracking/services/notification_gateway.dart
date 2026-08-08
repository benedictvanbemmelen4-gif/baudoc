// Schnittstelle für lokale Benachrichtigungen mit Aktions-Buttons.
//
// Anforderung E: die Aktions-Buttons werden vom Betriebssystem geliefert
// (iOS UNNotificationCategory-Actions, Android Notification Actions über einen
// BroadcastReceiver). Beide landen am Ende in genau einem Callback, den der
// Controller in ein TrackingEvent übersetzt.

/// Kennungen der Aktions-Buttons. Die Strings gehen unverändert an die
/// Plattform und dürfen sich nicht ändern – sonst laufen Buttons aus bereits
/// zugestellten Benachrichtigungen ins Leere.
class TrackingAction {
  const TrackingAction._();

  static const confirm = 'tt_confirm';
  static const adjust = 'tt_adjust';
  static const discard = 'tt_discard';
  static const endOfDay = 'tt_end_of_day';
  static const resumeWork = 'tt_resume';
  static const keepRunning = 'tt_keep_running';
}

/// IDs der Benachrichtigungen, damit sie gezielt ersetzt/entfernt werden.
class TrackingNotificationId {
  const TrackingNotificationId._();

  static const arrival = 4101;
  static const departure = 4102;
  static const pauseReminder = 4103;
  static const safetyWarning = 4104;
  static const foregroundService = 4105;
}

/// Wird aufgerufen, wenn der Nutzer einen Aktions-Button drückt – auch dann,
/// wenn die App währenddessen geschlossen war.
typedef NotificationActionCallback = void Function(
  String actionId,
  String? payload,
);

abstract class NotificationGateway {
  Future<void> init();

  /// Benachrichtigungsrecht anfordern (Android 13+ und iOS verlangen das).
  Future<bool> requestPermission();

  /// „Am Ziel angekommen“ mit [Bestätigen] [Anpassen] [Verwerfen].
  Future<void> showArrival({
    required String orderId,
    required String orderName,
    required DateTime arrivalTime,
  });

  /// „Baustelle verlassen – Feierabend eintragen?“
  Future<void> showDeparture({
    required String orderId,
    required String orderName,
    required DateTime exitTime,
  });

  /// Erinnerung nach Ablauf der Pause.
  Future<void> schedulePauseReminder(DateTime fireAt);

  /// Vorwarnung vor der Zwangs-Kappung.
  Future<void> scheduleSafetyWarning(DateTime fireAt, {String? orderName});

  /// Alle geplanten Alarme zurücknehmen.
  Future<void> cancelScheduled();

  /// Alle sichtbaren Benachrichtigungen entfernen.
  Future<void> dismissAll();

  void setActionCallback(NotificationActionCallback? callback);
}

/// Implementierung für Plattformen ohne lokale Benachrichtigungen (Web).
class NoopNotificationGateway implements NotificationGateway {
  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> showArrival({
    required String orderId,
    required String orderName,
    required DateTime arrivalTime,
  }) async {}

  @override
  Future<void> showDeparture({
    required String orderId,
    required String orderName,
    required DateTime exitTime,
  }) async {}

  @override
  Future<void> schedulePauseReminder(DateTime fireAt) async {}

  @override
  Future<void> scheduleSafetyWarning(DateTime fireAt,
      {String? orderName}) async {}

  @override
  Future<void> cancelScheduled() async {}

  @override
  Future<void> dismissAll() async {}

  @override
  void setActionCallback(NotificationActionCallback? callback) {}
}
