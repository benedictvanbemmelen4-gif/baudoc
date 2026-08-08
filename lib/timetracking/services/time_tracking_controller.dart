// Laufzeit-Verdrahtung der Zeiterfassung.
//
// Der Controller ist die einzige Stelle, an der der reine Automat auf die
// unreine Welt trifft: er lädt und sichert den Zustand, führt die vom
// Automaten *beschriebenen* Effekte aus und meldet Änderungen an die UI.
//
// Er ist ein ChangeNotifier, weil die übrige App (Store in main.dart) genau
// dieses Muster nutzt – AnimatedBuilder/ListenableBuilder funktionieren damit
// unverändert.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/time_tracking_machine.dart';
import '../core/tracking_rules.dart';
import '../models/time_entry.dart';
import '../models/tracking_state.dart';
import '../data/tracking_repository.dart';
import 'geofence_gateway.dart';
import 'notification_gateway.dart';

/// Die Auftragsdaten, die die Zeiterfassung braucht. Wird per Callback aus der
/// Haupt-App geliefert, damit dieses Modul main.dart nicht importieren muss
/// (keine zirkuläre Abhängigkeit).
class TrackedOrder {
  final String id;
  final String name;
  final String address;
  final GeoPoint? position;

  const TrackedOrder({
    required this.id,
    required this.name,
    required this.address,
    this.position,
  });
}

class TimeTrackingController extends ChangeNotifier {
  final TrackingRepository repository;
  final GeofenceGateway geofence;
  final NotificationGateway notifications;
  final TimeTrackingMachine machine;

  /// Liefert den aktuell angemeldeten Mitarbeiter.
  final String Function() currentUserId;

  /// Liefert die Auftragsdaten zu einer ID (null, wenn gelöscht).
  final TrackedOrder? Function(String orderId) orderLookup;

  /// Wird gerufen, sobald ein Eintrag abgeschlossen ist. Hier hängt die
  /// Haupt-App die Übernahme in `Project.hours` ein, damit PDF- und
  /// CSV-Export unverändert weiterfunktionieren.
  final void Function(TimeEntry entry)? onEntryCompleted;

  TimeTrackingController({
    required this.repository,
    required this.geofence,
    required this.notifications,
    required this.currentUserId,
    required this.orderLookup,
    this.onEntryCompleted,
    TimeTrackingMachine? machine,
  }) : machine = machine ??
            TimeTrackingMachine(
              newId: () =>
                  'tt_${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
            );

  static int _seq = 0;

  TrackingSession? _session;
  List<TimeEntry> _entries = const [];
  bool _ready = false;

  /// Serialisiert Ereignisse. Zwei gleichzeitig eintreffende Geofence-
  /// Meldungen dürfen sich nicht überholen, sonst entstehen Doppeleinträge.
  Future<void> _queue = Future.value();

  // ---- Lesezugriffe für die UI ----

  bool get isReady => _ready;
  TrackingSession? get session => _session;
  TimeTrackingState get state => _session?.state ?? TimeTrackingState.idle;
  TimeEntry? get currentEntry => _session?.entry;
  List<TimeEntry> get entries => _entries;

  bool get isTracking => state.isActive;
  bool get needsAttention => state.needsAttention;

  /// Einträge, die Büro/Meister prüfen müssen.
  List<TimeEntry> get entriesNeedingReview => _entries
      .where((e) =>
          e.status == TimeEntryStatus.unconfirmed ||
          e.status == TimeEntryStatus.flaggedForReview)
      .toList();

  /// Laufende Nettozeit für die Anzeige.
  Duration get elapsed {
    final s = _session;
    if (s == null) return Duration.zero;
    // In der Pause zählt die Uhr nicht weiter.
    if (s.state == TimeTrackingState.paused && s.pauseStartedAt != null) {
      final until = s.pauseStartedAt!;
      final gross = until.difference(s.entry.startTime);
      final net = gross - Duration(minutes: s.entry.breakDurationMinutes);
      return net.isNegative ? Duration.zero : net;
    }
    return s.entry.netDuration();
  }

  // -------------------------------------------------------------------------
  // Start / Wiederherstellung
  // -------------------------------------------------------------------------

  /// Stellt den Zustand nach App-Start, Neustart oder OS-Kill wieder her.
  Future<void> init() async {
    await repository.init();
    await notifications.init();

    _session = await repository.loadSession();
    _entries = await repository.loadEntries();

    geofence.setCallback(_onGeofenceEvent);
    notifications.setActionCallback(_onNotificationAction);

    // Sicherheitsnetz nachholen: war das Gerät zur geplanten Kappungszeit aus,
    // ist der Alarm nie ausgelöst worden. Beim nächsten Start nachziehen –
    // sonst läuft ein vergessener Timer tagelang weiter.
    await _catchUpSafetyCap();

    _ready = true;
    notifyListeners();
  }

  Future<void> _catchUpSafetyCap() async {
    final s = _session;
    if (s == null || !s.state.isActive) return;

    final capAt = TrackingRules.safetyCapTime(s.entry.startTime);
    if (DateTime.now().isAfter(capAt)) {
      await _dispatch(AutoSafetyCapTriggered(
        TrackingRules.cappedEndTime(s.entry.startTime),
        DateTime.now(),
      ));
    }
  }

  // -------------------------------------------------------------------------
  // Öffentliche Aktionen
  // -------------------------------------------------------------------------

  /// Navigation zum Auftrag beginnt: Geofence scharfschalten.
  ///
  /// Der Deep-Link in die Karten-App wird vom Aufrufer ausgelöst (siehe
  /// navigation_launcher.dart); hier geht es nur um die Ankunftserkennung.
  /// Liefert false, wenn kein Hintergrund-Geofencing möglich ist.
  Future<bool> armGeofenceForNavigation(TrackedOrder order) async {
    if (!geofence.isSupported) return false;

    final permission = await geofence.checkPermission();
    if (!permission.allowsBackground) return false;

    final center = order.position ?? await geofence.resolveAddress(order.address);
    if (center == null) return false;

    await geofence.registerGeofence(
      orderId: order.id,
      center: center,
      radiusMeters: TrackingRules.geofenceRadiusMeters,
    );
    return true;
  }

  Future<void> startManually(String orderId) =>
      _dispatch(ManualStartRequested(orderId, DateTime.now()));

  Future<void> confirm() => _dispatch(UserConfirmed(DateTime.now()));

  Future<void> adjustStart(DateTime newStart) =>
      _dispatch(UserAdjusted(newStart, DateTime.now()));

  Future<void> discard() => _dispatch(UserDiscarded(DateTime.now()));

  Future<void> startPause({int minutes = TrackingRules.defaultPauseMinutes}) =>
      _dispatch(PauseStarted(DateTime.now(), plannedMinutes: minutes));

  Future<void> endPause() => _dispatch(PauseEnded(DateTime.now()));

  Future<void> stop() => _dispatch(ManualStopRequested(DateTime.now()));

  /// Tagesabschluss mit Pausenabzug. Ohne Angabe wird der gesetzliche
  /// Mindestabzug vorgeschlagen.
  Future<void> finalizeEntry({int? breakMinutes}) {
    final s = _session;
    final suggested = s == null
        ? 0
        : TrackingRules.suggestedAdditionalBreak(
            s.entry.grossDuration(),
            s.entry.breakDurationMinutes,
          );
    return _dispatch(EntryFinalized(
      DateTime.now(),
      breakMinutes: breakMinutes ?? suggested,
    ));
  }

  /// Vorschlag für den gesetzlichen Pausenabzug (für den Abschluss-Dialog).
  int get suggestedBreakMinutes {
    final s = _session;
    if (s == null) return 0;
    return TrackingRules.suggestedAdditionalBreak(
      s.entry.grossDuration(),
      s.entry.breakDurationMinutes,
    );
  }

  /// Nachträgliche Korrektur durch Büro/Meister.
  Future<void> reviewEntry(TimeEntry entry) async {
    await repository.updateEntry(entry);
    _entries = await repository.loadEntries();
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Ereignisverarbeitung
  // -------------------------------------------------------------------------

  void _onGeofenceEvent(String orderId, bool entered, DateTime at) {
    _dispatch(entered
        ? GeofenceEntered(orderId, at)
        : GeofenceExited(orderId, at));
  }

  void _onNotificationAction(String actionId, String? payload) {
    final now = DateTime.now();
    switch (actionId) {
      case TrackingAction.confirm:
        _dispatch(UserConfirmed(now));
      case TrackingAction.discard:
        _dispatch(UserDiscarded(now));
      case TrackingAction.endOfDay:
        // Endzeit ist der Geofence-Austritt, nicht der Moment des Tippens –
        // der Monteur drückt den Button oft erst zu Hause.
        final exit = _session?.entry.geofenceExitTime ?? now;
        _dispatch(EntryFinalized(exit, breakMinutes: suggestedBreakMinutes));
      case TrackingAction.resumeWork:
        _dispatch(PauseEnded(now));
      case TrackingAction.keepRunning:
        // Timer läuft bewusst weiter: Sicherheitsnetz neu spannen.
        final s = _session;
        if (s != null) {
          notifications.scheduleSafetyWarning(
            now.add(const Duration(hours: 2)),
            orderName: orderLookup(s.entry.orderId)?.name,
          );
        }
      case TrackingAction.adjust:
        // „Anpassen“ braucht eine Eingabe – die App öffnet dafür den Dialog.
        // Hier passiert bewusst nichts außer dem Wecken der UI.
        notifyListeners();
    }
  }

  /// Zentrale Verarbeitung. Serialisiert, damit gleichzeitige Ereignisse
  /// nicht denselben Zustand überschreiben.
  Future<void> _dispatch(TrackingEvent event) {
    _queue = _queue.then((_) => _apply(event)).catchError((Object e, StackTrace st) {
      // Ein Fehler in einem Effekt darf die Warteschlange nicht blockieren:
      // sonst kommt keine spätere Ankunft mehr durch.
      debugPrint('Zeiterfassung: Ereignis fehlgeschlagen ($event): $e\n$st');
    });
    return _queue;
  }

  Future<void> _apply(TrackingEvent event) async {
    final result = machine.transition(
      _session,
      event,
      userId: currentUserId(),
    );

    if (result.wasIgnored && result.session == _session) {
      // Bewusst verworfen (z. B. Doppelstart) – nichts zu tun.
      debugPrint('Zeiterfassung: ignoriert – ${result.ignoredReason}');
      return;
    }

    _session = result.session;

    // Erst sichern, dann Effekte ausführen: stirbt der Prozess mitten in den
    // Effekten, ist der Zustand trotzdem korrekt und wird beim Start
    // rekonstruiert.
    final toStore = result.session?.state == TimeTrackingState.completed
        ? null
        : result.session;
    await repository.saveSession(toStore);
    if (toStore == null) _session = null;

    for (final effect in result.effects) {
      await _runEffect(effect);
    }

    _entries = await repository.loadEntries();
    notifyListeners();
  }

  Future<void> _runEffect(TrackingEffect effect) async {
    switch (effect) {
      case PersistCompletedEntry(:final entry):
        await repository.appendEntry(entry);
        // Verworfene Einträge nicht in die Auftragsstunden übernehmen.
        if (entry.status != TimeEntryStatus.rejected) {
          onEntryCompleted?.call(entry);
        }

      case ShowArrivalNotification(:final orderId, :final arrivalTime):
        await notifications.showArrival(
          orderId: orderId,
          orderName: orderLookup(orderId)?.name ?? 'Auftrag',
          arrivalTime: arrivalTime,
        );

      case ShowDepartureNotification(:final orderId, :final exitTime):
        await notifications.showDeparture(
          orderId: orderId,
          orderName: orderLookup(orderId)?.name ?? 'Auftrag',
          exitTime: exitTime,
        );

      case SchedulePauseReminder(:final fireAt):
        await notifications.schedulePauseReminder(fireAt);

      case ScheduleSafetyWarning(:final fireAt):
        await notifications.scheduleSafetyWarning(
          fireAt,
          orderName: orderLookup(_session?.entry.orderId ?? '')?.name,
        );

      case ScheduleSafetyCap(:final fireAt):
        // Der eigentliche Kappungs-Alarm wird von der Plattform gestellt; die
        // Nachhol-Prüfung beim App-Start (siehe _catchUpSafetyCap) ist das
        // zweite Netz, falls das Gerät zu dem Zeitpunkt aus war.
        await notifications.scheduleSafetyWarning(fireAt);

      case CancelScheduledAlarms():
        await notifications.cancelScheduled();

      case DismissNotifications():
        await notifications.dismissAll();

      case RegisterGeofence(:final orderId):
        final order = orderLookup(orderId);
        if (order == null || !geofence.isSupported) break;
        final center =
            order.position ?? await geofence.resolveAddress(order.address);
        if (center == null) break;
        await geofence.registerGeofence(
          orderId: orderId,
          center: center,
          radiusMeters: TrackingRules.geofenceRadiusMeters,
        );

      case RemoveGeofence(:final orderId):
        await geofence.removeGeofence(orderId);

      case StartForegroundService():
      case StopForegroundService():
        // Vom Android-Gateway umgesetzt; auf anderen Plattformen wirkungslos.
        break;
    }
  }

  @override
  void dispose() {
    geofence.setCallback(null);
    notifications.setActionCallback(null);
    super.dispose();
  }
}
