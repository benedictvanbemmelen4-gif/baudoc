// Fassung für Plattformen mit dart:io.
//
// Das umfasst neben Android auch Windows, macOS und Linux – dort gibt es die
// Plugins aber nicht. Deshalb entscheidet zusätzlich eine Laufzeitprüfung;
// ohne sie stürzte die Windows-Fassung beim Start ab.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../services/geofence_gateway.dart';
import '../services/geofence_gateway_android.dart';
import '../services/notification_gateway.dart';
import '../services/notification_gateway_android.dart';
import '../services/running_indicator_gateway.dart';

class TrackingGateways {
  final GeofenceGateway geofence;
  final NotificationGateway notifications;
  final RunningIndicatorGateway runningIndicator;

  /// Nur auf Android gesetzt – die Nachhol-Aufrufe gibt es sonst nicht.
  final AndroidGeofenceGateway? _androidGeofence;
  final AndroidNotificationGateway? _androidNotifications;

  const TrackingGateways({
    required this.geofence,
    required this.notifications,
    required this.runningIndicator,
    AndroidGeofenceGateway? androidGeofence,
    AndroidNotificationGateway? androidNotifications,
  })  : _androidGeofence = androidGeofence,
        _androidNotifications = androidNotifications;

  /// Holt nach, was anfiel, während die App geschlossen war.
  ///
  /// Reihenfolge ist wichtig: erst die Zäune nach einem Geräteneustart wieder
  /// setzen, dann die aufgelaufenen Übertritte einspielen, zuletzt die
  /// Button-Klicks. Ein „Bestätigen“ soll auf die Ankunft treffen, die es
  /// bestätigt – nicht umgekehrt.
  Future<void> afterControllerInit() async {
    final g = _androidGeofence;
    final n = _androidNotifications;
    if (g == null && n == null) return;

    try {
      await g?.restoreAfterReboot();
      await g?.replayPendingEvents();
      await n?.replayPendingActions();
    } catch (e, st) {
      // Nachholen darf den Start nie verhindern: der Monteur muss auch dann
      // an seine Aufträge kommen.
      debugPrint('Zeiterfassung: Nachholen fehlgeschlagen: $e\n$st');
    }
  }
}

TrackingGateways buildTrackingGateways() {
  if (!Platform.isAndroid) {
    return TrackingGateways(
      geofence: NoopGeofenceGateway(),
      notifications: NoopNotificationGateway(),
      runningIndicator: const NoopRunningIndicator(),
    );
  }

  final geofence = AndroidGeofenceGateway();
  // Eine Instanz für beides: die Benachrichtigungen und der Hinweis auf den
  // laufenden Timer teilen sich denselben Plugin-Zustand.
  final notifications = AndroidNotificationGateway();

  return TrackingGateways(
    geofence: geofence,
    notifications: notifications,
    runningIndicator: notifications,
    androidGeofence: geofence,
    androidNotifications: notifications,
  );
}
