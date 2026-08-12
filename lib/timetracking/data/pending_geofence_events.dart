// Briefkasten zwischen dem Geofence-Hintergrund-Isolat und der App.
//
// Warum das nötig ist: Android liefert Geofence-Übertritte auch dann aus, wenn
// die App beendet ist. Flutter startet dafür ein *eigenes* Isolat, das weder
// den Controller noch den Store der laufenden App kennt – gemeinsamer Speicher
// existiert zwischen Isolaten nicht. Das Hintergrund-Isolat kann das Ereignis
// deshalb nicht direkt zustellen; es legt es hier ab, und das Haupt-Isolat
// holt es beim nächsten Start ab.
//
// Bewusst `SharedPreferencesAsync` statt der zwischengespeicherten Variante:
// die klassische `SharedPreferences`-Instanz hält eine Kopie im Arbeitsspeicher
// und würde Schreibvorgänge des jeweils anderen Isolats nicht sehen.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ein noch nicht verarbeiteter Geofence-Übertritt.
@immutable
class PendingGeofenceEvent {
  final String orderId;
  final bool entered;
  final DateTime at;

  const PendingGeofenceEvent({
    required this.orderId,
    required this.entered,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'orderId': orderId,
        'entered': entered,
        'at': at.toIso8601String(),
      };

  static PendingGeofenceEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['orderId'];
    final at = DateTime.tryParse(j['at']?.toString() ?? '');
    if (id is! String || id.isEmpty || at == null) return null;
    return PendingGeofenceEvent(
      orderId: id,
      entered: j['entered'] == true,
      at: at,
    );
  }

  @override
  String toString() =>
      'PendingGeofenceEvent($orderId, ${entered ? 'ein' : 'aus'}, $at)';
}

class PendingGeofenceEvents {
  const PendingGeofenceEvents._();

  static const _key = 'tt_pending_geofence_events';

  /// Obergrenze, damit ein defekter Zaun das Gerät nicht vollschreibt.
  /// Bei Überlauf fallen die *ältesten* Einträge heraus – der jüngste
  /// Übertritt beschreibt den aktuellen Aufenthalt am besten.
  static const _maxEvents = 50;

  /// Aus dem Hintergrund-Isolat aufgerufen.
  static Future<void> append(PendingGeofenceEvent event) async {
    final prefs = SharedPreferencesAsync();
    final list = await _read(prefs);
    list.add(event);
    while (list.length > _maxEvents) {
      list.removeAt(0);
    }
    await prefs.setString(_key, jsonEncode([for (final e in list) e.toJson()]));
  }

  /// Holt alle offenen Ereignisse und leert den Briefkasten in einem Zug.
  ///
  /// Wird ausschließlich aus dem Haupt-Isolat gerufen. Sollte die Verarbeitung
  /// danach scheitern, sind die Ereignisse verloren – das ist der bewusst
  /// gewählte Kompromiss gegenüber der Alternative, dieselbe Ankunft nach
  /// einem Absturz doppelt zu buchen.
  static Future<List<PendingGeofenceEvent>> drain() async {
    final prefs = SharedPreferencesAsync();
    final list = await _read(prefs);
    if (list.isNotEmpty) await prefs.remove(_key);
    return list;
  }

  static Future<List<PendingGeofenceEvent>> _read(
    SharedPreferencesAsync prefs,
  ) async {
    final raw = await prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final item in decoded)
          if (PendingGeofenceEvent.fromJson(item) case final e?) e,
      ];
    } catch (_) {
      // Kaputter Inhalt darf den Start nicht blockieren.
      return [];
    }
  }
}
