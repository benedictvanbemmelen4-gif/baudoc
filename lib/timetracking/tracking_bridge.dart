// Bindeglied zwischen dem Zeiterfassungs-Modul und der übrigen App.
//
// Nur diese Datei kennt beide Seiten. Der Kern unter core/ und models/ bleibt
// dadurch frei von main.dart und weiterhin ohne Gerät testbar.
//
// Aufgaben:
//  * den einen Controller bereitstellen (gTracking),
//  * ihm den angemeldeten Benutzer und die Auftragsdaten liefern,
//  * abgeschlossene Einträge in `Project.hours` übernehmen, damit PDF- und
//    CSV-Export unverändert weiterfunktionieren.

import 'package:flutter/foundation.dart';

import '../main.dart' show Store, WorkHours;
import 'data/prefs_tracking_repository.dart';
import 'models/time_entry.dart';
import 'services/geofence_gateway.dart';
import 'services/notification_gateway.dart';
import 'services/time_tracking_controller.dart';

TimeTrackingController? _controller;

/// Der Controller der App. Wird beim ersten Zugriff erzeugt, ist aber erst
/// nach [initTimeTracking] mit Daten befüllt (`isReady`).
///
/// Bewusst kein `late final`: so liefert auch ein Widget-Test ohne Init einen
/// gültigen, leeren Controller statt einer LateInitializationError.
TimeTrackingController get gTracking => _controller ??= _build();

/// Wird aus `main()` nach `Store.I.load()` gerufen.
///
/// Fehler werden geschluckt: eine kaputte Zeiterfassung darf niemals den
/// Start der App verhindern – der Monteur muss auch dann an seine Aufträge
/// kommen.
Future<void> initTimeTracking() async {
  try {
    await gTracking.init();
  } catch (e, st) {
    debugPrint('Zeiterfassung konnte nicht starten: $e\n$st');
  }
}

TimeTrackingController _build() => TimeTrackingController(
      repository: PrefsTrackingRepository(),
      geofence: _geofenceGateway(),
      notifications: _notificationGateway(),
      currentUserId: () => Store.I.currentUser?.id ?? '',
      orderLookup: _lookupOrder,
      onEntryCompleted: _writeToWorkHours,
    );

// ---------------------------------------------------------------------------
// Plattform-Auswahl
// ---------------------------------------------------------------------------

// Hintergrund-Geofencing und lokale Push mit Aktions-Buttons gibt es nur
// nativ. Solange die Android-Umsetzung fehlt, greifen die No-Op-Varianten:
// die manuelle Erfassung (Start, Pause, Feierabend) funktioniert damit
// vollständig, nur die *automatische* Ankunftserkennung entfällt.
//
// Für Android hier später die konkreten Gateways einsetzen – am Rest der App
// ändert sich dadurch nichts.
GeofenceGateway _geofenceGateway() => NoopGeofenceGateway();

NotificationGateway _notificationGateway() => NoopNotificationGateway();

// ---------------------------------------------------------------------------
// Auftragsdaten
// ---------------------------------------------------------------------------

TrackedOrder? _lookupOrder(String orderId) {
  final p = Store.I.projectById(orderId);
  if (p == null) return null;
  return TrackedOrder(id: p.id, name: p.name, address: p.address);
}

// ---------------------------------------------------------------------------
// Übernahme in die Auftragsstunden
// ---------------------------------------------------------------------------

/// Schreibt einen abgeschlossenen Eintrag als [WorkHours] an den Auftrag.
///
/// Die WorkHours-ID wird aus der Eintrags-ID abgeleitet. Dadurch ist der
/// Schreibvorgang idempotent: eine spätere Korrektur durch das Büro
/// überschreibt denselben Datensatz, statt einen zweiten anzulegen.
void _writeToWorkHours(TimeEntry entry) {
  final p = Store.I.projectById(entry.orderId);
  if (p == null) return;

  final hours = entry.netHours();
  final rowId = 'tt_${entry.id}';
  final existing = p.hours.indexWhere((h) => h.id == rowId);

  // Verworfene Zeiten zählen nicht, und nach Abzug der Pausen kann null
  // übrig bleiben (20 min Aufenthalt, 30 min Pause). In beiden Fällen keine
  // Zeile anlegen – und eine früher geschriebene wieder entfernen.
  if (entry.status == TimeEntryStatus.rejected || hours <= 0) {
    if (existing >= 0) {
      p.hours.removeAt(existing);
      Store.I.save();
    }
    return;
  }

  final row = WorkHours(
    id: rowId,
    worker: _workerName(entry.userId),
    date: _isoDay(entry.startTime),
    task: entry.task.trim().isEmpty
        ? 'Zeiterfassung ${_hhmm(entry.startTime)}–${_hhmm(entry.endTime)}'
        : entry.task.trim(),
    h: hours,
    synced: Store.I.online,
  );

  if (existing >= 0) {
    p.hours[existing] = row;
  } else {
    p.hours.add(row);
  }
  Store.I.save();
}

String _workerName(String userId) {
  for (final u in Store.I.users) {
    if (u.id == userId) return u.name;
  }
  // Benutzer gelöscht oder Eintrag ohne Anmeldung entstanden – die Stunden
  // gehen trotzdem nicht verloren.
  return Store.I.currentUser?.name ?? 'Unbekannt';
}

String _isoDay(DateTime d) => d.toIso8601String().substring(0, 10);

String _hhmm(DateTime? d) => d == null
    ? '--:--'
    : '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
