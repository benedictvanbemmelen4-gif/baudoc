// Fassung für Plattformen ohne Hintergrund-Geofencing (Web/PWA).
//
// Die manuelle Zeiterfassung – Start, Pause, Feierabend – funktioniert damit
// vollständig. Nur die automatische Ankunftserkennung entfällt.

import '../services/geofence_gateway.dart';
import '../services/notification_gateway.dart';
import '../services/running_indicator_gateway.dart';

class TrackingGateways {
  final GeofenceGateway geofence;
  final NotificationGateway notifications;
  final RunningIndicatorGateway runningIndicator;

  const TrackingGateways({
    required this.geofence,
    required this.notifications,
    required this.runningIndicator,
  });

  /// Wird nach `TimeTrackingController.init()` gerufen, wenn die Rückmelder
  /// gesetzt sind. Hier holt Android nach, was bei geschlossener App anfiel.
  Future<void> afterControllerInit() async {}
}

TrackingGateways buildTrackingGateways() => TrackingGateways(
      geofence: NoopGeofenceGateway(),
      notifications: NoopNotificationGateway(),
      runningIndicator: const NoopRunningIndicator(),
    );
