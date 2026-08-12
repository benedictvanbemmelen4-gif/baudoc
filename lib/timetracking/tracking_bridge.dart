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
import 'data/firestore_tracking_repository.dart';
import 'models/time_entry.dart';
import 'platform/tracking_gateways.dart';
import 'services/time_tracking_controller.dart';

TimeTrackingController? _controller;

/// Die Ablage der Zeiten – gemerkt, um beim Abmelden die Zuhörer zu lösen.
FirestoreTrackingRepository? _ablage;

/// Läuft die Zeiterfassung schon?
///
/// [initTimeTracking] hängt am Anmeldezustand, und der meldet sich auch beim
/// bloßen Erneuern des Tokens erneut. Ohne diese Sperre liefe die
/// Wiederherstellung dann jedes Mal neu.
bool _gestartet = false;

/// Die Plattform-Umsetzungen dieser App. Einmal aufgebaut, damit die
/// Nachhol-Aufrufe nach `init()` dieselben Objekte treffen wie der Controller.
TrackingGateways? _gateways;

/// Der Controller der App. Wird beim ersten Zugriff erzeugt, ist aber erst
/// nach [initTimeTracking] mit Daten befüllt (`isReady`).
///
/// Bewusst kein `late final`: so liefert auch ein Widget-Test ohne Init einen
/// gültigen, leeren Controller statt einer LateInitializationError.
TimeTrackingController get gTracking => _controller ??= _build();

/// Wird gerufen, sobald eine Anmeldung feststeht (siehe `Store._onAccount`).
///
/// **Erst dann**, nicht schon in `main()`: die Zeiten liegen jetzt in der
/// gemeinsamen Datenbank, und die weist jeden Zugriff ohne Anmeldung ab. Ohne
/// Konto gibt es außerdem niemanden, dem eine Zeit gehören könnte.
///
/// Fehler werden geschluckt: eine kaputte Zeiterfassung darf niemals den
/// Start der App verhindern – der Monteur muss auch dann an seine Aufträge
/// kommen.
Future<void> initTimeTracking() async {
  if (_gestartet) return;
  _gestartet = true;
  try {
    await gTracking.init();
    // Erst nach init(): dort setzt der Controller seine Rückmelder. Vorher
    // eingespielte Ereignisse liefen ins Leere.
    await _gateways?.afterControllerInit();
  } catch (e, st) {
    debugPrint('Zeiterfassung konnte nicht starten: $e\n$st');
  }
}

/// Beim Abmelden: Zuhörer lösen und Controller verwerfen.
///
/// Sonst liefen die Firestore-Zuhörer ohne Anmeldung weiter – die Regeln
/// weisen sie mit Fehlern ab – und der Nächste, der sich an diesem Gerät
/// anmeldet, bekäme die Liste seines Vorgängers zu sehen. Die laufende Sitzung
/// bleibt auf dem Gerät und wird beim nächsten Anmelden wiederhergestellt.
void disposeTimeTracking() {
  _ablage?.dispose();
  _ablage = null;
  _controller = null;
  _gestartet = false;
}

TimeTrackingController _build() {
  // Auf Android die echten Umsetzungen, sonst die wirkungslosen – die Auswahl
  // trifft platform/tracking_gateways.dart. Für Web und Desktop bedeutet das:
  // die manuelle Erfassung läuft vollständig, nur die automatische
  // Ankunftserkennung entfällt.
  final gateways = _gateways ??= buildTrackingGateways();

  final ablage = _ablage = FirestoreTrackingRepository(currentUserId: _wer);

  return TimeTrackingController(
    repository: ablage,
    geofence: gateways.geofence,
    notifications: gateways.notifications,
    runningIndicator: gateways.runningIndicator,
    currentUserId: _wer,
    orderLookup: _lookupOrder,
    onEntryCompleted: _writeToWorkHours,
    // Wer die Abrechnung erstellt, prüft auch die Zeiten der anderen. Alle
    // übrigen sehen in der Prüfliste nur ihre eigenen.
    canReviewOthers: () => Store.I.can('exportDocs'),
  );
}

/// Wem gehört die erfasste Zeit? Nach der Umstellung auf echte Konten ist das
/// die Firebase-Kennung – dieselbe, die auch der Server prüft.
String _wer() => Store.I.currentUser?.id ?? '';

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
      Store.I.removeWorkHours(p.id, rowId);
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
  );

  if (existing >= 0) {
    p.hours[existing] = row;
  } else {
    p.hours.add(row);
  }
  // Nur diese eine Zeile schreiben, nicht den ganzen Auftrag: das Büro kann
  // gerade an demselben Auftrag arbeiten, und dessen Änderung darf nicht
  // verloren gehen (siehe Store.saveWorkHours).
  Store.I.saveWorkHours(p.id, row);
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
