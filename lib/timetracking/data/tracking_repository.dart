// Persistenz der Zeiterfassung (Offline-First).
//
// Bewusst als Interface: die App speichert heute alles als JSON in
// SharedPreferences (siehe Store in main.dart). Bleibt der Zugriff hinter
// diesem Vertrag, lässt sich später ohne Änderung am Automaten oder
// Controller auf SQLite/Hive oder ein Backend umstellen.

import '../models/time_entry.dart';
import '../models/tracking_state.dart';

abstract class TrackingRepository {
  /// Muss vor jeder anderen Nutzung aufgerufen werden.
  Future<void> init();

  /// Laufende Sitzung laden – null, wenn kein Timer aktiv war.
  ///
  /// Das ist der Wiederherstellungspfad nach App-Neustart oder OS-Kill.
  Future<TrackingSession?> loadSession();

  /// Laufende Sitzung sichern. null löscht sie.
  ///
  /// Wird nach *jedem* Zustandsübergang aufgerufen, damit ein Prozess-Kill
  /// zwischen zwei Ereignissen keine Arbeitszeit kostet.
  Future<void> saveSession(TrackingSession? session);

  /// Abgeschlossenen Eintrag anhängen (append-only Journal).
  Future<void> appendEntry(TimeEntry entry);

  /// Alle gespeicherten Einträge, neueste zuerst.
  Future<List<TimeEntry>> loadEntries();

  /// Einen Eintrag ersetzen (Korrektur durch Büro/Meister).
  Future<void> updateEntry(TimeEntry entry);
}
