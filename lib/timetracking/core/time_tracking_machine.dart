// Der Zeiterfassungs-Automat.
//
// Kernidee: `transition` ist eine **reine Funktion**. Sie bekommt den
// aktuellen Zustand und ein Ereignis und liefert den neuen Zustand plus eine
// Liste von Effekten (Push zeigen, Alarm planen, Geofence abmelden …). Sie
// ruft selbst nichts auf – kein GPS, keine Benachrichtigung, keine Datenbank.
//
// Vorteile im Alltag dieser App:
//  * Jeder Ablauf ist ohne Gerät testbar (siehe test/time_tracking_test.dart).
//  * Verzögert zugestellte Geofence-Meldungen sind unkritisch, weil jedes
//    Ereignis seinen eigenen fachlichen Zeitstempel mitbringt.
//  * Doppelstarts sind an genau einer Stelle ausgeschlossen statt verstreut.

import '../models/time_entry.dart';
import '../models/tracking_state.dart';
import 'tracking_rules.dart';

class TimeTrackingMachine {
  /// Erzeugt IDs für neue Einträge. Injiziert, damit Tests deterministisch
  /// bleiben können.
  final String Function() newId;

  const TimeTrackingMachine({required this.newId});

  /// Führt einen Zustandsübergang aus.
  ///
  /// [session] ist der aktuelle Zustand (null = idle), [event] das Ereignis,
  /// [userId] der angemeldete Mitarbeiter (nur beim Anlegen neuer Einträge
  /// verwendet).
  TransitionResult transition(
    TrackingSession? session,
    TrackingEvent event, {
    required String userId,
  }) {
    // Kein laufender Timer: nur Start-Ereignisse sind sinnvoll.
    if (session == null || session.state == TimeTrackingState.idle) {
      return _fromIdle(event, userId);
    }

    return switch (session.state) {
      TimeTrackingState.trackingUnconfirmed ||
      TimeTrackingState.trackingConfirmed =>
        _fromRunning(session, event, userId),
      TimeTrackingState.paused => _fromPaused(session, event, userId),
      TimeTrackingState.stoppedUnconfirmed =>
        _fromStopped(session, event, userId),
      // `completed` ist ein Durchgangszustand: der Controller persistiert und
      // räumt sofort auf. Trifft doch ein Ereignis ein, beginnt alles neu.
      TimeTrackingState.completed => _fromIdle(event, userId),
      TimeTrackingState.idle => _fromIdle(event, userId),
    };
  }

  // -------------------------------------------------------------------------
  // idle
  // -------------------------------------------------------------------------

  TransitionResult _fromIdle(TrackingEvent event, String userId) {
    switch (event) {
      case GeofenceEntered(:final locationId, :final at):
        return _startSession(
          orderId: locationId,
          userId: userId,
          start: at,
          viaGeofence: true,
        );

      case ManualStartRequested(:final orderId, :final at):
        return _startSession(
          orderId: orderId,
          userId: userId,
          start: at,
          viaGeofence: false,
        );

      // Alles andere ohne laufenden Timer ist gegenstandslos. Wichtig: das
      // ist kein Fehler – eine Austritts-Meldung kann nach dem Abschluss
      // verspätet eintreffen.
      default:
        return TransitionResult(
          null,
          const [],
          ignoredReason: 'Kein laufender Timer für ${event.runtimeType}',
        );
    }
  }

  TransitionResult _startSession({
    required String orderId,
    required String userId,
    required DateTime start,
    required bool viaGeofence,
  }) {
    final entry = TimeEntry(
      id: newId(),
      orderId: orderId,
      userId: userId,
      startTime: start,
      // Automatisch erfasste Zeiten sind unbestätigt, manuell gestartete
      // gelten sofort als bestätigt – der Monteur hat sie ja selbst ausgelöst.
      status: viaGeofence
          ? TimeEntryStatus.unconfirmed
          : TimeEntryStatus.confirmed,
      createdViaGeofence: viaGeofence,
      geofenceEntryTime: viaGeofence ? start : null,
    );

    return TransitionResult(
      TrackingSession(
        state: viaGeofence
            ? TimeTrackingState.trackingUnconfirmed
            : TimeTrackingState.trackingConfirmed,
        entry: entry,
      ),
      [
        StartForegroundService(orderId),
        // Auch beim manuellen Start registrieren wir den Geofence: nur so
        // wird der Feierabend beim Verlassen der Baustelle erkannt.
        RegisterGeofence(orderId),
        if (viaGeofence) ShowArrivalNotification(orderId, start),
        ScheduleSafetyWarning(TrackingRules.safetyWarningTime(start)),
        ScheduleSafetyCap(TrackingRules.safetyCapTime(start)),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // trackingUnconfirmed / trackingConfirmed
  // -------------------------------------------------------------------------

  TransitionResult _fromRunning(
    TrackingSession s,
    TrackingEvent event,
    String userId,
  ) {
    switch (event) {
      // --- Doppelstart-Schutz -------------------------------------------
      // Derselbe Ort, obwohl schon ein Timer läuft: GPS-Flattern an der
      // Radiusgrenze oder eine doppelt zugestellte Meldung. Strikt ignorieren.
      case GeofenceEntered(:final locationId) when locationId == s.entry.orderId:
        return TransitionResult(
          s,
          const [],
          ignoredReason: 'Timer für $locationId läuft bereits',
        );

      // Anderer Ort: der Monteur ist weitergefahren, ohne dass der Austritt
      // ankam. Alten Eintrag zum Ankunftszeitpunkt schließen und neu starten,
      // damit keine Zeit verloren geht.
      case GeofenceEntered(:final locationId, :final at):
        final closed = s.entry.copyWith(
          endTime: at,
          status: TimeEntryStatus.flaggedForReview,
        );
        final next = _startSession(
          orderId: locationId,
          userId: userId,
          start: at,
          viaGeofence: true,
        );
        return TransitionResult(
          next.session,
          [
            RemoveGeofence(s.entry.orderId),
            PersistCompletedEntry(closed),
            ...next.effects,
          ],
        );

      case GeofenceExited(:final locationId, :final at)
          when locationId == s.entry.orderId:
        return _stopByGeofence(s, at);

      // Austritt eines fremden Geofence – nicht unser Timer.
      case GeofenceExited(:final locationId):
        return TransitionResult(
          s,
          const [],
          ignoredReason: 'Austritt aus fremdem Geofence $locationId',
        );

      case UserConfirmed():
        if (s.state == TimeTrackingState.trackingConfirmed) {
          return TransitionResult(s, const [],
              ignoredReason: 'Bereits bestätigt');
        }
        return TransitionResult(
          s.copyWith(
            state: TimeTrackingState.trackingConfirmed,
            entry: s.entry.copyWith(status: TimeEntryStatus.confirmed),
          ),
          const [DismissNotifications()],
        );

      case UserAdjusted(:final newStartTime):
        final adjusted = s.entry.copyWith(
          startTime: newStartTime,
          status: TimeEntryStatus.confirmed,
        );
        return TransitionResult(
          s.copyWith(
            state: TimeTrackingState.trackingConfirmed,
            entry: adjusted,
          ),
          [
            const DismissNotifications(),
            // Startzeit verschoben → Sicherheitsnetz neu spannen.
            const CancelScheduledAlarms(),
            ScheduleSafetyWarning(
                TrackingRules.safetyWarningTime(newStartTime)),
            ScheduleSafetyCap(TrackingRules.safetyCapTime(newStartTime)),
          ],
        );

      case UserDiscarded(:final at):
        return _discard(s, at);

      case PauseStarted(:final at, :final plannedMinutes):
        return TransitionResult(
          s.copyWith(
            state: TimeTrackingState.paused,
            pauseStartedAt: at,
            pauseEndsAt: at.add(Duration(minutes: plannedMinutes)),
            // Eine Pause ist eine bewusste Handlung – der Eintrag gilt danach
            // als bestätigt.
            entry: s.entry.copyWith(status: TimeEntryStatus.confirmed),
          ),
          [
            SchedulePauseReminder(at.add(Duration(minutes: plannedMinutes))),
          ],
        );

      case PauseEnded():
        return TransitionResult(s, const [],
            ignoredReason: 'Keine Pause aktiv');

      case ManualStopRequested(:final at):
        return _stopManually(s, at);

      case AutoSafetyCapTriggered(:final cappedEndTime):
        return _applySafetyCap(s, cappedEndTime);

      case EntryFinalized(:final at, :final breakMinutes):
        return _finalize(s, at, breakMinutes);

      case ManualStartRequested():
        // Zentrale Regel: nie zwei Timer gleichzeitig.
        return TransitionResult(
          s,
          const [],
          ignoredReason: 'Es läuft bereits ein Timer',
        );
    }
  }

  // -------------------------------------------------------------------------
  // paused
  // -------------------------------------------------------------------------

  TransitionResult _fromPaused(
    TrackingSession s,
    TrackingEvent event,
    String userId,
  ) {
    switch (event) {
      case PauseEnded(:final at):
        return TransitionResult(
          _closePause(s, at).copyWith(
            state: TimeTrackingState.trackingConfirmed,
            clearPause: true,
          ),
          const [DismissNotifications()],
        );

      case PauseStarted():
        return TransitionResult(s, const [],
            ignoredReason: 'Pause läuft bereits');

      // Verlässt jemand die Baustelle während der Pause, ist die Pause vorbei
      // und der Arbeitstag ebenfalls.
      case GeofenceExited(:final locationId, :final at)
          when locationId == s.entry.orderId:
        return _stopByGeofence(_closePause(s, at), at);

      case ManualStopRequested(:final at):
        return _stopManually(_closePause(s, at), at);

      case AutoSafetyCapTriggered(:final cappedEndTime):
        return _applySafetyCap(_closePause(s, cappedEndTime), cappedEndTime);

      case UserDiscarded(:final at):
        return _discard(s, at);

      case GeofenceEntered(:final locationId) when locationId == s.entry.orderId:
        // Rückkehr aus der Pause auf die Baustelle beendet die Pause.
        final now = event.at;
        return TransitionResult(
          _closePause(s, now).copyWith(
            state: TimeTrackingState.trackingConfirmed,
            clearPause: true,
          ),
          const [DismissNotifications()],
        );

      default:
        return TransitionResult(s, const [],
            ignoredReason: 'In Pause nicht behandelt: ${event.runtimeType}');
    }
  }

  /// Rechnet die laufende Pause in `breakDurationMinutes` ein.
  TrackingSession _closePause(TrackingSession s, DateTime at) {
    final startedAt = s.pauseStartedAt;
    if (startedAt == null) return s;
    final minutes = at.difference(startedAt).inMinutes;
    if (minutes <= 0) return s;
    return s.copyWith(
      entry: s.entry.copyWith(
        breakDurationMinutes: s.entry.breakDurationMinutes + minutes,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // stoppedUnconfirmed
  // -------------------------------------------------------------------------

  TransitionResult _fromStopped(
    TrackingSession s,
    TrackingEvent event,
    String userId,
  ) {
    switch (event) {
      case UserConfirmed(:final at):
        return _finalize(
          s,
          at,
          TrackingRules.suggestedAdditionalBreak(
            s.entry.grossDuration(now: at),
            s.entry.breakDurationMinutes,
          ),
        );

      case EntryFinalized(:final at, :final breakMinutes):
        return _finalize(s, at, breakMinutes);

      case UserAdjusted(:final newStartTime):
        return TransitionResult(
          s.copyWith(
            entry: s.entry.copyWith(
              startTime: newStartTime,
              status: TimeEntryStatus.confirmed,
            ),
          ),
          const [DismissNotifications()],
        );

      case UserDiscarded(:final at):
        return _discard(s, at);

      // Zurück auf die Baustelle: der beendete Eintrag wird gesichert und ein
      // neuer Abschnitt beginnt (z. B. Rückkehr nach dem Materialholen).
      case GeofenceEntered(:final locationId, :final at):
        final next = _startSession(
          orderId: locationId,
          userId: userId,
          start: at,
          viaGeofence: true,
        );
        return TransitionResult(
          next.session,
          [PersistCompletedEntry(s.entry), ...next.effects],
        );

      default:
        return TransitionResult(s, const [],
            ignoredReason: 'Timer bereits beendet: ${event.runtimeType}');
    }
  }

  // -------------------------------------------------------------------------
  // gemeinsame Abschlüsse
  // -------------------------------------------------------------------------

  /// Geofence-Austritt: Timer anhalten, Feierabend-Push anbieten.
  TransitionResult _stopByGeofence(TrackingSession s, DateTime at) {
    // Sehr kurzer Aufenthalt = Fehlauslösung (Durchfahren, Ampel, Nachbarbau).
    if (at.difference(s.entry.startTime) <
        TrackingRules.minimumMeaningfulDuration) {
      return _discard(s, at, reason: 'Aufenthalt zu kurz');
    }

    final stopped = s.entry.copyWith(
      endTime: at,
      geofenceExitTime: at,
    );
    return TransitionResult(
      s.copyWith(state: TimeTrackingState.stoppedUnconfirmed, entry: stopped),
      [
        const CancelScheduledAlarms(),
        const StopForegroundService(),
        ShowDepartureNotification(s.entry.orderId, at),
      ],
    );
  }

  TransitionResult _stopManually(TrackingSession s, DateTime at) {
    final stopped = s.entry.copyWith(
      endTime: at,
      status: TimeEntryStatus.confirmed,
    );
    return TransitionResult(
      s.copyWith(state: TimeTrackingState.stoppedUnconfirmed, entry: stopped),
      [
        const CancelScheduledAlarms(),
        const StopForegroundService(),
        const DismissNotifications(),
      ],
    );
  }

  /// Nacht-Sicherheitsnetz: zwangsweise kappen und zur Prüfung markieren.
  TransitionResult _applySafetyCap(TrackingSession s, DateTime cappedEnd) {
    final end = cappedEnd.isAfter(s.entry.startTime)
        ? cappedEnd
        : s.entry.startTime;
    final capped = s.entry.copyWith(
      endTime: end,
      isAutoCapped: true,
      status: TimeEntryStatus.flaggedForReview,
    );
    return TransitionResult(
      s.copyWith(state: TimeTrackingState.stoppedUnconfirmed, entry: capped),
      [
        const CancelScheduledAlarms(),
        const StopForegroundService(),
        RemoveGeofence(s.entry.orderId),
        // Bewusst nicht sofort persistiert: der Monteur soll den gekappten
        // Eintrag am nächsten Tag noch korrigieren können.
      ],
    );
  }

  /// Verwerfen. Der Eintrag bleibt als `rejected` erhalten – im Handwerk ist
  /// Nachvollziehbarkeit wichtiger als eine saubere Liste.
  TransitionResult _discard(TrackingSession s, DateTime at,
      {String? reason}) {
    final rejected = s.entry.copyWith(
      endTime: s.entry.endTime ?? at,
      status: TimeEntryStatus.rejected,
    );
    return TransitionResult(
      null,
      [
        const CancelScheduledAlarms(),
        const DismissNotifications(),
        const StopForegroundService(),
        RemoveGeofence(s.entry.orderId),
        PersistCompletedEntry(rejected),
      ],
      ignoredReason: reason,
    );
  }

  /// Endgültiger Abschluss inklusive Pausenabzug.
  TransitionResult _finalize(TrackingSession s, DateTime at, int breakMinutes) {
    final end = s.entry.endTime ?? at;
    final done = s.entry.copyWith(
      endTime: end,
      breakDurationMinutes: s.entry.breakDurationMinutes + breakMinutes,
      // Ein gekappter Eintrag bleibt prüfbedürftig, auch wenn er abgeschlossen
      // wird – sonst verschwindet die Warnung fürs Büro.
      status: s.entry.isAutoCapped
          ? TimeEntryStatus.flaggedForReview
          : TimeEntryStatus.confirmed,
    );
    return TransitionResult(
      TrackingSession(state: TimeTrackingState.completed, entry: done),
      [
        const CancelScheduledAlarms(),
        const DismissNotifications(),
        const StopForegroundService(),
        RemoveGeofence(s.entry.orderId),
        PersistCompletedEntry(done),
      ],
    );
  }
}
