// SharedPreferences-Implementierung der Zeiterfassungs-Persistenz.
//
// Warum kein Hive/SQLite: die App hält ihren gesamten Datenbestand bereits als
// JSON in SharedPreferences (Store in main.dart). Ein zweiter Speichermotor
// nur für dieses Feature bringt eine native Abhängigkeit, einen zweiten
// Migrationspfad und ein zweites Backup-Format mit – bei der hier zu
// erwartenden Datenmenge (einige tausend Einträge) ohne Gegenwert.
// SharedPreferences schreibt synchron auf Platte und übersteht App-Kill und
// Geräteneustart, was die eigentliche Anforderung ist.
//
// Wächst das Journal irgendwann über ein paar MB, wird hier gegen eine
// SQLite-Implementierung getauscht – der Rest des Codes merkt davon nichts.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/time_entry.dart';
import '../models/tracking_state.dart';
import 'tracking_repository.dart';

class PrefsTrackingRepository implements TrackingRepository {
  static const _sessionKey = 'tt_session_v1';
  static const _entriesKey = 'tt_entries_v1';

  SharedPreferences? _prefs;

  /// Zwischenspeicher, damit Lesezugriffe (Banner, Listen) nicht bei jedem
  /// Rebuild JSON dekodieren müssen.
  List<TimeEntry>? _cache;

  SharedPreferences get _p {
    final p = _prefs;
    if (p == null) {
      throw StateError('PrefsTrackingRepository.init() wurde nicht gerufen');
    }
    return p;
  }

  @override
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // ---- Sitzung ----

  @override
  Future<TrackingSession?> loadSession() async {
    final raw = _p.getString(_sessionKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final session = TrackingSession.fromJson(decoded);
      if (session == null) return null;

      // `completed` ist ein Durchgangszustand. Steht er noch im Speicher,
      // wurde die App zwischen Abschluss und Aufräumen beendet – der Eintrag
      // liegt bereits im Journal, die Sitzung ist also Müll.
      if (session.state == TimeTrackingState.completed) {
        await saveSession(null);
        return null;
      }
      return session;
    } catch (_) {
      // Kaputter Datensatz darf die App nicht blockieren: verwerfen und
      // sauber weiterlaufen.
      await saveSession(null);
      return null;
    }
  }

  @override
  Future<void> saveSession(TrackingSession? session) async {
    if (session == null) {
      await _p.remove(_sessionKey);
    } else {
      await _p.setString(_sessionKey, jsonEncode(session.toJson()));
    }
  }

  // ---- Journal ----

  @override
  Future<List<TimeEntry>> loadEntries() async {
    final cached = _cache;
    if (cached != null) return List.unmodifiable(cached);

    final raw = _p.getString(_entriesKey);
    final list = <TimeEntry>[];
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              // Ein defekter Einzeleintrag darf nicht das ganze Journal
              // kosten – deshalb wird pro Eintrag abgefangen.
              try {
                list.add(TimeEntry.fromJson(Map<String, dynamic>.from(item)));
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
    }
    list.sort((a, b) => b.startTime.compareTo(a.startTime));
    _cache = list;
    return List.unmodifiable(list);
  }

  @override
  Future<void> appendEntry(TimeEntry entry) async {
    final list = List<TimeEntry>.from(await loadEntries());
    // Idempotent: derselbe Eintrag darf durch eine doppelt zugestellte
    // Benachrichtigung nicht zweimal im Journal landen.
    final existing = list.indexWhere((e) => e.id == entry.id);
    if (existing >= 0) {
      list[existing] = entry;
    } else {
      list.add(entry);
    }
    await _write(list);
  }

  @override
  Future<void> updateEntry(TimeEntry entry) async {
    final list = List<TimeEntry>.from(await loadEntries());
    final i = list.indexWhere((e) => e.id == entry.id);
    if (i < 0) return;
    list[i] = entry;
    await _write(list);
  }

  Future<void> _write(List<TimeEntry> list) async {
    list.sort((a, b) => b.startTime.compareTo(a.startTime));
    _cache = list;
    await _p.setString(
      _entriesKey,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }
}
