// Android-Umsetzung des Geofencing über die Plattform-Schnittstelle.
//
// Entscheidend für den Akku: Android verwaltet die Zäune selbst. Die App muss
// den Standort *nicht* dauerhaft abfragen; das System weckt sie beim Übertritt
// – auch wenn sie beendet wurde. Dafür startet Flutter ein eigenes Isolat.
//
// Was dieses Isolat NICHT hat: den Store, den Controller, den Zustandsautomaten
// der laufenden App. Es kann deshalb nur zwei Dinge tun – sofort melden und das
// Ereignis ablegen (siehe data/pending_geofence_events.dart). Die fachliche
// Bewertung (Entprellung, Mindestdauer, Zustandsübergang) holt das Haupt-Isolat
// beim nächsten Start nach. Das ist unkritisch, weil jedes Ereignis seinen
// echten Zeitstempel mitführt: die erfassten Zeiten stimmen, nur ihre
// Verarbeitung ist verzögert.

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:native_geofence/native_geofence.dart' as ng;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/pending_geofence_events.dart';
import 'geofence_gateway.dart';
import 'notification_gateway_android.dart';

/// Auftragsnamen für das Hintergrund-Isolat.
///
/// Wird beim Registrieren eines Zauns geschrieben, weil das Isolat den Store
/// nicht erreichen kann und eine Meldung „Auftrag“ ohne Namen wertlos wäre.
const _kGeofenceNamesKey = 'tt_geofence_names';

Future<void> _rememberName(String orderId, String name) async {
  final prefs = SharedPreferencesAsync();
  final raw = await prefs.getString(_kGeofenceNamesKey) ?? '';
  final map = _decodeNames(raw)..[orderId] = name;
  await prefs.setString(_kGeofenceNamesKey, _encodeNames(map));
}

Future<String> _lookupName(String orderId) async {
  final prefs = SharedPreferencesAsync();
  final raw = await prefs.getString(_kGeofenceNamesKey) ?? '';
  return _decodeNames(raw)[orderId] ?? 'Auftrag';
}

// Bewusst ein eigenes, primitives Format statt JSON: ein einzelner kaputter
// Eintrag soll nicht die ganze Tabelle unlesbar machen. Als Trenner dient ein
// Steuerzeichen, das in Auftragsnamen nicht vorkommen kann; es steht hier als
// Escape-Folge, damit kein rohes Steuerzeichen in der Quelldatei liegt.
const _sep = '\u0001';

Map<String, String> _decodeNames(String raw) {
  final out = <String, String>{};
  for (final line in raw.split('\n')) {
    final i = line.indexOf(_sep);
    if (i > 0) out[line.substring(0, i)] = line.substring(i + 1);
  }
  return out;
}

String _encodeNames(Map<String, String> m) => [
      for (final e in m.entries)
        '${e.key}$_sep${e.value.replaceAll('\n', ' ')}',
    ].join('\n');

// ---------------------------------------------------------------------------
// Rückmelder aus dem Hintergrund-Isolat
// ---------------------------------------------------------------------------

/// Wird vom System bei jedem Übertritt gerufen – auch bei beendeter App.
///
/// Muss auf oberster Ebene stehen und `vm:entry-point` tragen, sonst entfernt
/// der Baumschnitt die Funktion im Release-Build.
@pragma('vm:entry-point')
Future<void> trackingGeofenceBackgroundHandler(
  ng.GeofenceCallbackParams params,
) async {
  final at = DateTime.now();
  final entered = params.event == ng.GeofenceEvent.enter;

  // Verweil-Ereignisse (dwell) und Austritte sauber trennen: nur Eintritt und
  // Austritt interessieren den Automaten.
  if (params.event != ng.GeofenceEvent.enter &&
      params.event != ng.GeofenceEvent.exit) {
    return;
  }

  for (final fence in params.geofences) {
    await PendingGeofenceEvents.append(PendingGeofenceEvent(
      orderId: fence.id,
      entered: entered,
      at: at,
    ));

    // Sofort melden. Die App verarbeitet das Ereignis erst beim nächsten
    // Start; der Monteur soll aber jetzt reagieren können.
    try {
      await _notifyFromBackground(fence.id, entered, at);
    } catch (e) {
      debugPrint('Geofence-Meldung fehlgeschlagen: $e');
    }
  }
}

/// Zeigt die Ankunfts-/Abfahrtsmeldung aus dem Hintergrund-Isolat.
///
/// Das Gateway-Objekt der App existiert hier nicht: das Isolat wird vom System
/// frisch gestartet und kennt nichts, was `main()` aufgebaut hat. Deshalb eine
/// eigene, kurzlebige Instanz – und deshalb ausdrücklich keine von außen
/// gesetzte Fabrik, deren Registrierung hier nie stattgefunden hätte.
Future<void> _notifyFromBackground(
  String orderId,
  bool entered,
  DateTime at,
) async {
  final gateway = AndroidNotificationGateway();
  await gateway.init();
  final name = await _lookupName(orderId);
  if (entered) {
    await gateway.showArrival(
      orderId: orderId,
      orderName: name,
      arrivalTime: at,
    );
  } else {
    await gateway.showDeparture(
      orderId: orderId,
      orderName: name,
      exitTime: at,
    );
  }
}


// ---------------------------------------------------------------------------

class AndroidGeofenceGateway implements GeofenceGateway {
  AndroidGeofenceGateway();

  GeofenceCallback? _callback;
  bool _initialized = false;

  @override
  bool get isSupported => true;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await ng.NativeGeofenceManager.instance.initialize();
    _initialized = true;
  }

  // ---- Berechtigungen -----------------------------------------------------

  @override
  Future<LocationPermissionResult> checkPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionResult.serviceDisabled;
    }
    return _map(await Geolocator.checkPermission());
  }

  @override
  Future<LocationPermissionResult> requestPermission({
    bool includeBackground = false,
  }) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionResult.serviceDisabled;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    // Android 11+ lehnt eine kombinierte Abfrage stillschweigend ab: erst muss
    // „während der Nutzung“ erteilt sein, danach darf getrennt nach „immer“
    // gefragt werden. Der zweite Schritt öffnet auf neueren Geräten die
    // Systemeinstellungen statt eines Dialogs – das ist so vorgesehen.
    if (includeBackground && permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }

    return _map(permission);
  }

  LocationPermissionResult _map(LocationPermission p) => switch (p) {
        LocationPermission.always => LocationPermissionResult.always,
        LocationPermission.whileInUse => LocationPermissionResult.whileInUse,
        LocationPermission.denied => LocationPermissionResult.denied,
        LocationPermission.deniedForever =>
          LocationPermissionResult.deniedForever,
        LocationPermission.unableToDetermine =>
          LocationPermissionResult.denied,
      };

  // ---- Adressauflösung ----------------------------------------------------

  @override
  Future<GeoPoint?> resolveAddress(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return null;
    try {
      final geocoder = geo.Geocoding();
      // Auf Geräten ohne Google-Dienste – etwa manchen Emulator-Abbildern –
      // gibt es gar keinen Auflöser. Dann gleich aufgeben, statt in einen
      // Zeitüberlauf zu laufen.
      if (!await geocoder.isPresent()) {
        debugPrint('Kein Geocoder auf diesem Gerät verfügbar.');
        return null;
      }
      final results = await geocoder.locationFromAddress(trimmed);
      if (results.isEmpty) return null;
      return GeoPoint(results.first.latitude, results.first.longitude);
    } catch (e) {
      // Ohne Netz oder bei unbekannter Adresse: kein Zaun. Die manuelle
      // Erfassung bleibt davon unberührt.
      debugPrint('Adresse nicht auflösbar ($trimmed): $e');
      return null;
    }
  }

  // ---- Zäune --------------------------------------------------------------

  @override
  Future<void> registerGeofence({
    required String orderId,
    required GeoPoint center,
    required double radiusMeters,
    String orderName = 'Auftrag',
  }) async {
    await _ensureInitialized();
    await _rememberName(orderId, orderName);

    await ng.NativeGeofenceManager.instance.createGeofence(
      ng.Geofence(
        id: orderId,
        location: ng.Location(
          latitude: center.latitude,
          longitude: center.longitude,
        ),
        radiusMeters: radiusMeters,
        triggers: const {ng.GeofenceEvent.enter, ng.GeofenceEvent.exit},
        androidSettings: const ng.AndroidGeofenceSettings(
          initialTriggers: {ng.GeofenceEvent.enter},
          // Wie träge das System melden darf. Zwei Minuten sparen spürbar
          // Akku und passen zur Entprellung in TrackingRules.
          notificationResponsiveness: Duration(minutes: 2),
        ),
        iosSettings: const ng.IosGeofenceSettings(initialTrigger: true),
      ),
      trackingGeofenceBackgroundHandler,
    );
  }

  @override
  Future<void> removeGeofence(String orderId) async {
    await _ensureInitialized();
    await ng.NativeGeofenceManager.instance.removeGeofenceById(orderId);
  }

  @override
  Future<void> removeAll() async {
    await _ensureInitialized();
    await ng.NativeGeofenceManager.instance.removeAllGeofences();
  }

  @override
  void setCallback(GeofenceCallback? callback) {
    _callback = callback;
  }

  /// Verarbeitet Übertritte, die eintrafen, während die App geschlossen war.
  Future<void> replayPendingEvents() async {
    final pending = await PendingGeofenceEvents.drain();
    for (final e in pending) {
      debugPrint('Zeiterfassung: hole Geofence-Ereignis nach – $e');
      _callback?.call(e.orderId, e.entered, e.at);
    }
  }

  /// Nach einem Geräteneustart müssen die Zäune neu gesetzt werden – Android
  /// verwirft sie beim Booten.
  Future<void> restoreAfterReboot() async {
    try {
      await _ensureInitialized();
      await ng.NativeGeofenceManager.instance.reCreateAfterReboot();
    } catch (e) {
      debugPrint('Geofences nach Neustart nicht wiederhergestellt: $e');
    }
  }
}
