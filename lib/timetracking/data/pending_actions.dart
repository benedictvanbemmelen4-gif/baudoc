// Briefkasten für Aktions-Buttons aus Benachrichtigungen.
//
// Gleiches Problem wie bei den Geofence-Ereignissen (siehe
// pending_geofence_events.dart): drückt der Monteur „Bestätigen“, während die
// App geschlossen ist, läuft der Rückmelder in einem eigenen Hintergrund-
// Isolat ohne Zugriff auf Controller und Store.
//
// Die Alternative wäre, die Buttons mit `showsUserInterface: true` die App
// öffnen zu lassen. Das ist einfacher, nimmt dem Aktions-Button aber seinen
// Sinn: der Monteur soll gerade *nicht* die App aufmachen müssen, um seine
// Ankunft zu bestätigen – oft genug mit Handschuhen und im Regen.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class PendingAction {
  final String actionId;
  final String? payload;
  final DateTime at;

  const PendingAction({
    required this.actionId,
    required this.at,
    this.payload,
  });

  Map<String, dynamic> toJson() => {
        'actionId': actionId,
        'payload': payload,
        'at': at.toIso8601String(),
      };

  static PendingAction? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['actionId'];
    final at = DateTime.tryParse(j['at']?.toString() ?? '');
    if (id is! String || id.isEmpty || at == null) return null;
    return PendingAction(
      actionId: id,
      payload: j['payload']?.toString(),
      at: at,
    );
  }

  @override
  String toString() => 'PendingAction($actionId, $payload, $at)';
}

class PendingActions {
  const PendingActions._();

  static const _key = 'tt_pending_actions';
  static const _maxActions = 30;

  static Future<void> append(PendingAction action) async {
    final prefs = SharedPreferencesAsync();
    final list = await _read(prefs);
    list.add(action);
    while (list.length > _maxActions) {
      list.removeAt(0);
    }
    await prefs.setString(_key, jsonEncode([for (final a in list) a.toJson()]));
  }

  static Future<List<PendingAction>> drain() async {
    final prefs = SharedPreferencesAsync();
    final list = await _read(prefs);
    if (list.isNotEmpty) await prefs.remove(_key);
    return list;
  }

  static Future<List<PendingAction>> _read(SharedPreferencesAsync prefs) async {
    final raw = await prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final item in decoded)
          if (PendingAction.fromJson(item) case final a?) a,
      ];
    } catch (_) {
      return [];
    }
  }
}
