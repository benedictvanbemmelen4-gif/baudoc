// Tests für die Laufzeit-Verdrahtung.
//
// Der Automat selbst ist in time_tracking_machine_test.dart abgedeckt. Hier
// geht es um das, was der Controller darum herum tut: Zustand sichern und
// wiederherstellen, Effekte an die Gateways geben und – am wichtigsten –
// abgeschlossene Einträge nach draußen melden, damit sie in den
// Auftragsstunden landen.

import 'package:flutter_test/flutter_test.dart';

import 'package:baudoc/timetracking/data/tracking_repository.dart';
import 'package:baudoc/timetracking/models/time_entry.dart';
import 'package:baudoc/timetracking/models/tracking_state.dart';
import 'package:baudoc/timetracking/services/geofence_gateway.dart';
import 'package:baudoc/timetracking/services/notification_gateway.dart';
import 'package:baudoc/timetracking/services/time_tracking_controller.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Speichert im Arbeitsspeicher und merkt sich, wie oft gesichert wurde.
class FakeRepository implements TrackingRepository {
  TrackingSession? session;
  final List<TimeEntry> entries = [];
  int saveCount = 0;

  @override
  Future<void> init() async {}

  @override
  Future<TrackingSession?> loadSession() async => session;

  @override
  Future<void> saveSession(TrackingSession? s) async {
    session = s;
    saveCount++;
  }

  @override
  Future<void> appendEntry(TimeEntry entry) async {
    final i = entries.indexWhere((e) => e.id == entry.id);
    if (i >= 0) {
      entries[i] = entry;
    } else {
      entries.add(entry);
    }
  }

  @override
  Future<List<TimeEntry>> loadEntries() async => List.of(entries);

  @override
  Future<void> updateEntry(TimeEntry entry) => appendEntry(entry);
}

/// Geofence-Gateway, das Ein- und Austritte auf Zuruf auslöst.
class FakeGeofence implements GeofenceGateway {
  final List<String> registered = [];
  GeofenceCallback? _cb;

  /// Simuliert, was Play services auf einem echten Gerät tut, wenn die
  /// Standortfreigabe fehlt: es wirft. Die Zeiterfassung darf daran nicht
  /// zerbrechen.
  bool failRegister = false;

  void enter(String orderId, DateTime at) => _cb?.call(orderId, true, at);
  void exit(String orderId, DateTime at) => _cb?.call(orderId, false, at);

  @override
  bool get isSupported => true;

  @override
  Future<LocationPermissionResult> checkPermission() async =>
      LocationPermissionResult.always;

  @override
  Future<LocationPermissionResult> requestPermission(
          {bool includeBackground = false}) async =>
      LocationPermissionResult.always;

  @override
  Future<GeoPoint?> resolveAddress(String address) async =>
      const GeoPoint(52.0, 13.0);

  /// Auftragsnamen, mit denen ein Zaun registriert wurde. Auf Android landet
  /// der Name in der Meldung, die das Hintergrund-Isolat zeigt – ein leerer
  /// Name faellt dort erst auf dem Geraet auf.
  final Map<String, String> registeredNames = {};

  @override
  Future<void> registerGeofence({
    required String orderId,
    required GeoPoint center,
    required double radiusMeters,
    String orderName = 'Auftrag',
  }) async {
    if (failRegister) {
      throw StateError('GEOFENCE_NOT_AVAILABLE');
    }
    if (!registered.contains(orderId)) registered.add(orderId);
    registeredNames[orderId] = orderName;
  }

  @override
  Future<void> removeGeofence(String orderId) async =>
      registered.remove(orderId);

  @override
  Future<void> removeAll() async => registered.clear();

  @override
  void setCallback(GeofenceCallback? callback) => _cb = callback;
}

/// Protokolliert, welche Benachrichtigungen gezeigt würden, und kann
/// Aktions-Buttons auslösen, als wäre die App geschlossen gewesen.
class FakeNotifications implements NotificationGateway {
  final List<String> shown = [];
  NotificationActionCallback? _cb;

  void tap(String actionId) => _cb?.call(actionId, null);

  @override
  Future<void> init() async {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> showArrival({
    required String orderId,
    required String orderName,
    required DateTime arrivalTime,
  }) async =>
      shown.add('arrival:$orderId');

  @override
  Future<void> showDeparture({
    required String orderId,
    required String orderName,
    required DateTime exitTime,
  }) async =>
      shown.add('departure:$orderId');

  @override
  Future<void> schedulePauseReminder(DateTime fireAt) async =>
      shown.add('pause');

  @override
  Future<void> scheduleSafetyWarning(DateTime fireAt,
          {String? orderName}) async =>
      shown.add('safety');

  @override
  Future<void> cancelScheduled() async {}

  @override
  Future<void> dismissAll() async {}

  @override
  void setActionCallback(NotificationActionCallback? callback) => _cb = callback;
}

// ---------------------------------------------------------------------------

void main() {
  late FakeRepository repo;
  late FakeGeofence geo;
  late FakeNotifications push;
  late List<TimeEntry> completed;
  late TimeTrackingController c;

  /// Aufträge, die es nicht (mehr) gibt – gelöscht oder mit neuer ID.
  late Set<String> missingOrders;

  TimeTrackingController build() => TimeTrackingController(
        repository: repo,
        geofence: geo,
        notifications: push,
        currentUserId: () => 'u1',
        orderLookup: (id) => missingOrders.contains(id)
            ? null
            : TrackedOrder(
                id: id, name: 'Baustelle $id', address: 'Musterweg 1'),
        onEntryCompleted: completed.add,
      );

  setUp(() async {
    repo = FakeRepository();
    geo = FakeGeofence();
    push = FakeNotifications();
    completed = [];
    missingOrders = {};
    c = build();
    await c.init();
  });

  group('Start und Abschluss', () {
    test('manueller Start läuft sofort als bestätigt', () async {
      await c.startManually('a1');

      expect(c.isTracking, isTrue);
      expect(c.state, TimeTrackingState.trackingConfirmed);
      expect(c.currentEntry!.orderId, 'a1');
      // Auch beim manuellen Start muss der Geofence stehen, sonst wird der
      // Feierabend beim Verlassen nicht erkannt.
      expect(geo.registered, contains('a1'));
    });

    test('Feierabend meldet den Eintrag nach draußen', () async {
      await c.startManually('a1');
      await c.stop();
      await c.finalizeEntry(breakMinutes: 0, task: 'Rohinstallation');

      expect(completed, hasLength(1));
      expect(completed.single.status, TimeEntryStatus.confirmed);
      expect(completed.single.task, 'Rohinstallation');
      expect(c.state, TimeTrackingState.idle);
      expect(repo.session, isNull, reason: 'Sitzung muss aufgeräumt sein');
    });

    test('zweiter Start während eines laufenden Timers wird ignoriert',
        () async {
      await c.startManually('a1');
      await c.startManually('a2');

      expect(c.currentEntry!.orderId, 'a1');
      expect(completed, isEmpty);
    });
  });

  group('Automatische Erfassung', () {
    test('Ankunft startet unbestätigt und zeigt die Push', () async {
      geo.enter('a1', DateTime(2026, 8, 8, 7, 12));
      await Future<void>.delayed(Duration.zero);

      expect(c.state, TimeTrackingState.trackingUnconfirmed);
      expect(c.currentEntry!.startTime.hour, 7);
      expect(c.currentEntry!.startTime.minute, 12);
      expect(push.shown, contains('arrival:a1'));
    });

    test('Bestätigen über den Push-Button wirkt wie im Banner', () async {
      geo.enter('a1', DateTime.now().subtract(const Duration(hours: 1)));
      await Future<void>.delayed(Duration.zero);

      push.tap(TrackingAction.confirm);
      await Future<void>.delayed(Duration.zero);

      expect(c.state, TimeTrackingState.trackingConfirmed);
      expect(c.currentEntry!.status, TimeEntryStatus.confirmed);
    });

    test('Verwerfen meldet den Eintrag als abgelehnt', () async {
      geo.enter('a1', DateTime.now().subtract(const Duration(hours: 1)));
      await Future<void>.delayed(Duration.zero);
      await c.discard();

      expect(c.state, TimeTrackingState.idle);
      expect(completed.single.status, TimeEntryStatus.rejected);
      expect(geo.registered, isEmpty, reason: 'Geofence muss abgemeldet sein');
    });
  });

  group('Wiederherstellung', () {
    test('laufender Timer übersteht einen App-Neustart', () async {
      await c.startManually('a1');
      final startedAt = c.currentEntry!.startTime;

      // Neuer Controller auf demselben Speicher = App neu gestartet.
      final restarted = build();
      await restarted.init();

      expect(restarted.state, TimeTrackingState.trackingConfirmed);
      expect(restarted.currentEntry!.startTime, startedAt);
    });

    test('vergessener Timer wird beim Start nachträglich gekappt', () async {
      // Vorgestern begonnen, nie beendet – der Kappungsalarm ist nie
      // ausgelöst worden, weil das Gerät aus war.
      final long = DateTime.now().subtract(const Duration(days: 2));
      repo.session = TrackingSession(
        state: TimeTrackingState.trackingConfirmed,
        entry: TimeEntry(
          id: 'alt',
          orderId: 'a1',
          userId: 'u1',
          startTime: long,
          status: TimeEntryStatus.confirmed,
        ),
      );

      final restarted = build();
      await restarted.init();

      expect(restarted.currentEntry!.isAutoCapped, isTrue);
      expect(restarted.currentEntry!.status, TimeEntryStatus.flaggedForReview);
      expect(restarted.state, TimeTrackingState.stoppedUnconfirmed);
    });
  });

  group('Fehlertoleranz', () {
    test('scheiternder Geofence stoppt die restlichen Effekte nicht', () async {
      geo.failRegister = true;
      await c.startManually('a1');

      // Der Timer läuft – und die Oberfläche erfährt davon.
      expect(c.isTracking, isTrue);
      expect(c.currentEntry!.orderId, 'a1');
      // Entscheidend: die Sicherheitsalarme kommen *nach* dem Geofence in der
      // Effektliste. Vorher fielen sie mit aus, und der vergessene Timer lief
      // die ganze Nacht durch.
      expect(push.shown, contains('safety'));
      // Und der Monteur sieht, dass die Automatik nicht scharf ist.
      expect(c.degradedHint, isNotNull);
    });

    test('Hinweis verschwindet, sobald der Geofence wieder steht', () async {
      geo.failRegister = true;
      await c.startManually('a1');
      expect(c.degradedHint, isNotNull);

      await c.stop();
      await c.finalizeEntry(breakMinutes: 0);
      geo.failRegister = false;
      await c.startManually('a1');

      expect(c.degradedHint, isNull);
    });

    test('Sitzung auf einem gelöschten Auftrag blockiert die App nicht',
        () async {
      // Genau der Fall aus dem Gerätetest: die Sitzung überlebt, der Auftrag
      // nicht. Ohne Aufräumen ist der Timer unstoppbar.
      repo.session = TrackingSession(
        state: TimeTrackingState.trackingConfirmed,
        entry: TimeEntry(
          id: 'verwaist',
          orderId: 'weg',
          userId: 'u1',
          startTime: DateTime.now().subtract(const Duration(hours: 1)),
          status: TimeEntryStatus.confirmed,
        ),
      );
      missingOrders = {'weg'};

      final restarted = build();
      await restarted.init();

      expect(restarted.state, TimeTrackingState.idle);
      expect(repo.session, isNull);
      // Die Zeit ist nicht verloren, sondern liegt beim Büro auf dem Tisch.
      expect(restarted.entriesNeedingReview, hasLength(1));
      expect(completed.single.status, TimeEntryStatus.flaggedForReview);
    });
  });

  group('Prüfung durch Büro/Meister', () {
    test('gekappte Einträge stehen auf der Prüfliste', () async {
      await c.startManually('a1');
      await c.stop();
      await c.finalizeEntry(breakMinutes: 0);

      // Nachträglich zur Prüfung markieren, wie es der Nacht-Kapper täte.
      final flagged = c.entries.single
          .copyWith(status: TimeEntryStatus.flaggedForReview);
      await c.reviewEntry(flagged);

      expect(c.entriesNeedingReview, hasLength(1));
    });

    test('Korrektur wird nach draußen gemeldet', () async {
      await c.startManually('a1');
      await c.discard();
      expect(completed.single.status, TimeEntryStatus.rejected);

      // Büro hebt die Ablehnung auf – die Stunden müssen wieder auftauchen.
      await c.reviewEntry(
          c.entries.single.copyWith(status: TimeEntryStatus.confirmed));

      expect(completed.last.status, TimeEntryStatus.confirmed);
      expect(completed.last.id, completed.first.id,
          reason: 'gleiche ID → die Übernahme bleibt idempotent');
    });
  });

  group('Pausen', () {
    test('Pause hält die Uhr an und wird abgezogen', () async {
      await c.startManually('a1');
      await c.startPause(minutes: 30);

      expect(c.state, TimeTrackingState.paused);
      expect(push.shown, contains('pause'));

      await c.endPause();
      expect(c.state, TimeTrackingState.trackingConfirmed);
    });
  });
}
