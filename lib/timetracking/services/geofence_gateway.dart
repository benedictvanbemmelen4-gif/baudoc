// Schnittstelle zur Standort-/Geofence-Plattform.
//
// Der Automat und der Controller kennen nur diesen Vertrag. Dadurch:
//  * baut und läuft die App weiterhin für Web (PWA) und Desktop, wo es kein
//    Hintergrund-Geofencing gibt – dort greift die No-Op-Implementierung;
//  * lässt sich der gesamte Ablauf im Test mit einem Fake durchspielen;
//  * bleibt die Android-Umsetzung an genau einer Stelle austauschbar.

/// Ergebnis der Berechtigungsabfrage.
enum LocationPermissionResult {
  /// Hintergrund-Standort erteilt („Immer zulassen“) – Geofencing möglich.
  always,

  /// Nur während der Nutzung. Ankunft wird nur bei offener App erkannt.
  whileInUse,

  /// Abgelehnt, kann erneut gefragt werden.
  denied,

  /// Dauerhaft abgelehnt – nur noch über die Systemeinstellungen änderbar.
  deniedForever,

  /// Ortungsdienste sind geräteweit aus.
  serviceDisabled,

  /// Plattform unterstützt kein Geofencing (Web, Desktop).
  unsupported,
}

extension LocationPermissionResultX on LocationPermissionResult {
  /// Reicht die Berechtigung für Hintergrund-Geofencing?
  bool get allowsBackground => this == LocationPermissionResult.always;

  /// Reicht sie wenigstens für Erkennung bei offener App?
  bool get allowsForeground =>
      this == LocationPermissionResult.always ||
      this == LocationPermissionResult.whileInUse;

  String get message => switch (this) {
        LocationPermissionResult.always =>
          'Ankunft wird auch bei geschlossener App erkannt.',
        LocationPermissionResult.whileInUse =>
          'Ankunft wird nur erkannt, solange BauDoc geöffnet ist. '
              'Für die automatische Erfassung im Hintergrund bitte '
              '„Immer zulassen“ wählen.',
        LocationPermissionResult.denied =>
          'Ohne Standortfreigabe kann die Ankunft nicht erkannt werden.',
        LocationPermissionResult.deniedForever =>
          'Die Standortfreigabe ist gesperrt. Bitte in den '
              'Systemeinstellungen für BauDoc wieder erlauben.',
        LocationPermissionResult.serviceDisabled =>
          'Die Ortungsdienste des Geräts sind ausgeschaltet.',
        LocationPermissionResult.unsupported =>
          'Automatische Ankunftserfassung ist auf diesem Gerät nicht '
              'verfügbar. Die Zeit lässt sich weiterhin manuell erfassen.',
      };
}

/// Geografische Position einer Baustelle.
class GeoPoint {
  final double latitude;
  final double longitude;
  const GeoPoint(this.latitude, this.longitude);

  Map<String, dynamic> toJson() => {'lat': latitude, 'lng': longitude};

  static GeoPoint? fromJson(Object? j) {
    if (j is! Map) return null;
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return GeoPoint(lat, lng);
  }
}

/// Rückmeldung der Plattform bei Ein-/Austritt.
typedef GeofenceCallback = void Function(
  String orderId,
  bool entered,
  DateTime at,
);

abstract class GeofenceGateway {
  /// Unterstützt die Plattform Hintergrund-Geofencing?
  bool get isSupported;

  /// Aktuellen Berechtigungsstand abfragen, ohne einen Dialog zu zeigen.
  Future<LocationPermissionResult> checkPermission();

  /// Berechtigung anfordern.
  ///
  /// Wichtig für die Datenschutzkonformität: erst „während der Nutzung“,
  /// danach separat „immer“ – Android 11+ verlangt diese Reihenfolge und
  /// lehnt eine kombinierte Abfrage stillschweigend ab.
  Future<LocationPermissionResult> requestPermission({
    bool includeBackground = false,
  });

  /// Adresse zu Koordinaten auflösen (für Aufträge ohne gespeicherte Position).
  Future<GeoPoint?> resolveAddress(String address);

  /// Geofence registrieren. Mehrfachaufrufe für dieselbe [orderId] ersetzen
  /// den bestehenden Eintrag.
  Future<void> registerGeofence({
    required String orderId,
    required GeoPoint center,
    required double radiusMeters,
  });

  Future<void> removeGeofence(String orderId);

  Future<void> removeAll();

  /// Callback für Ein-/Austritte setzen.
  void setCallback(GeofenceCallback? callback);
}

/// Implementierung für Plattformen ohne Hintergrund-Geofencing (Web, Desktop).
///
/// Alle Aufrufe sind wirkungslos, aber gültig – der Rest der App braucht
/// keine Plattformabfragen. Die manuelle Zeiterfassung funktioniert davon
/// völlig unabhängig weiter.
class NoopGeofenceGateway implements GeofenceGateway {
  @override
  bool get isSupported => false;

  @override
  Future<LocationPermissionResult> checkPermission() async =>
      LocationPermissionResult.unsupported;

  @override
  Future<LocationPermissionResult> requestPermission({
    bool includeBackground = false,
  }) async =>
      LocationPermissionResult.unsupported;

  @override
  Future<GeoPoint?> resolveAddress(String address) async => null;

  @override
  Future<void> registerGeofence({
    required String orderId,
    required GeoPoint center,
    required double radiusMeters,
  }) async {}

  @override
  Future<void> removeGeofence(String orderId) async {}

  @override
  Future<void> removeAll() async {}

  @override
  void setCallback(GeofenceCallback? callback) {}
}
