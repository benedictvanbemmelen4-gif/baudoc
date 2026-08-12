// Sichtbarer Hinweis, solange ein Timer läuft.
//
// Der Automat kennt dafür die Effekte StartForegroundService und
// StopForegroundService (models/tracking_state.dart). Deren ursprüngliche
// Begründung – „Android-Pflicht, damit der Prozess nicht weggeräumt wird“ –
// trifft in dieser Umsetzung nicht mehr zu: die Ankunftserkennung läuft über
// Androids eigene Geofencing-Schnittstelle, und die verwaltet das
// Betriebssystem selbst. Es weckt die App beim Übertritt, auch wenn sie
// beendet wurde.
//
// Ein echter Vordergrunddienst würde deshalb nur Akku kosten, eine
// prüfpflichtige Berechtigung (FOREGROUND_SERVICE_LOCATION) verlangen und
// nichts absichern. Was bleibt, ist der *sichtbare* Zweck: der Monteur soll
// erkennen können, dass die Uhr läuft, ohne die App zu öffnen. Dafür genügt
// eine feste Benachrichtigung.

abstract class RunningIndicatorGateway {
  /// Zeigt an, dass seit [since] am Auftrag [orderName] erfasst wird.
  Future<void> showRunning({
    required String orderName,
    required DateTime since,
  });

  /// Entfernt den Hinweis.
  Future<void> hideRunning();
}

class NoopRunningIndicator implements RunningIndicatorGateway {
  const NoopRunningIndicator();

  @override
  Future<void> showRunning({
    required String orderName,
    required DateTime since,
  }) async {}

  @override
  Future<void> hideRunning() async {}
}
