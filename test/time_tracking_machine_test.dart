// Tests des Zeiterfassungs-Automaten.
//
// Der Automat ist eine reine Funktion – deshalb braucht hier nichts ein Gerät,
// GPS, Benachrichtigungen oder eine Uhr. Jeder Ablauf wird mit festen
// Zeitstempeln durchgespielt.

import 'package:flutter_test/flutter_test.dart';

import 'package:baudoc/timetracking/core/time_tracking_machine.dart';
import 'package:baudoc/timetracking/core/tracking_rules.dart';
import 'package:baudoc/timetracking/models/time_entry.dart';
import 'package:baudoc/timetracking/models/tracking_state.dart';

void main() {
  // Deterministische IDs, damit Erwartungen stabil bleiben.
  var counter = 0;
  final machine = TimeTrackingMachine(newId: () => 'id_${counter++}');

  const user = 'u1';
  const order = 'p1';

  // Ein normaler Arbeitstag: Ankunft 07:00.
  DateTime at(int hour, [int minute = 0]) =>
      DateTime(2026, 8, 10, hour, minute);

  TrackingSession start({DateTime? arrival}) {
    final r = machine.transition(
      null,
      GeofenceEntered(order, arrival ?? at(7)),
      userId: user,
    );
    return r.session!;
  }

  setUp(() => counter = 0);

  group('Ankunft', () {
    test('Geofence-Eintritt startet unbestätigten Timer mit exakter Zeit', () {
      final r = machine.transition(
        null,
        GeofenceEntered(order, at(7, 12)),
        userId: user,
      );

      expect(r.session!.state, TimeTrackingState.trackingUnconfirmed);
      expect(r.session!.entry.startTime, at(7, 12));
      expect(r.session!.entry.status, TimeEntryStatus.unconfirmed);
      expect(r.session!.entry.createdViaGeofence, isTrue);
      expect(r.session!.entry.geofenceEntryTime, at(7, 12));
      expect(r.effects.whereType<ShowArrivalNotification>(), hasLength(1));
      expect(r.effects.whereType<StartForegroundService>(), hasLength(1));
    });

    test('manueller Start gilt sofort als bestätigt und zeigt keine Push', () {
      final r = machine.transition(
        null,
        ManualStartRequested(order, at(8)),
        userId: user,
      );

      expect(r.session!.state, TimeTrackingState.trackingConfirmed);
      expect(r.session!.entry.status, TimeEntryStatus.confirmed);
      expect(r.session!.entry.createdViaGeofence, isFalse);
      expect(r.effects.whereType<ShowArrivalNotification>(), isEmpty);
      // Geofence wird trotzdem registriert – sonst kein Feierabend-Erkennen.
      expect(r.effects.whereType<RegisterGeofence>(), hasLength(1));
    });

    test('Sicherheitsnetz wird beim Start eingeplant', () {
      final r = machine.transition(null, GeofenceEntered(order, at(7)),
          userId: user);
      expect(r.effects.whereType<ScheduleSafetyWarning>(), hasLength(1));
      expect(r.effects.whereType<ScheduleSafetyCap>(), hasLength(1));
    });
  });

  group('Doppelstart-Schutz', () {
    test('zweiter Eintritt am selben Ort wird strikt ignoriert', () {
      final s = start();
      final r = machine.transition(
        s,
        GeofenceEntered(order, at(7, 5)),
        userId: user,
      );

      expect(r.wasIgnored, isTrue);
      expect(r.session, same(s));
      expect(r.effects, isEmpty);
      // Startzeit bleibt die *erste* Ankunft.
      expect(r.session!.entry.startTime, at(7));
    });

    test('manueller Start bei laufendem Timer wird abgelehnt', () {
      final s = start();
      final r = machine.transition(
        s,
        ManualStartRequested('p2', at(9)),
        userId: user,
      );

      expect(r.wasIgnored, isTrue);
      expect(r.session!.entry.orderId, order);
    });

    test('Eintritt an anderer Baustelle schließt den alten Eintrag ab', () {
      final s = start();
      final r = machine.transition(
        s,
        GeofenceEntered('p2', at(11)),
        userId: user,
      );

      expect(r.session!.entry.orderId, 'p2');
      expect(r.session!.entry.startTime, at(11));

      final persisted =
          r.effects.whereType<PersistCompletedEntry>().single.entry;
      expect(persisted.orderId, order);
      expect(persisted.endTime, at(11));
      // Lückenloser Übergang: kein Zeitverlust zwischen den Baustellen.
      expect(persisted.status, TimeEntryStatus.flaggedForReview);
    });
  });

  group('Bestätigen / Anpassen / Verwerfen', () {
    test('Bestätigen macht den Eintrag belastbar', () {
      final r = machine.transition(start(), UserConfirmed(at(7, 30)),
          userId: user);

      expect(r.session!.state, TimeTrackingState.trackingConfirmed);
      expect(r.session!.entry.status, TimeEntryStatus.confirmed);
      expect(r.effects.whereType<DismissNotifications>(), hasLength(1));
    });

    test('Anpassen verschiebt Start und spannt das Sicherheitsnetz neu', () {
      final r = machine.transition(
        start(),
        UserAdjusted(at(6, 30), at(7, 30)),
        userId: user,
      );

      expect(r.session!.entry.startTime, at(6, 30));
      expect(r.session!.entry.status, TimeEntryStatus.confirmed);
      expect(r.effects.whereType<CancelScheduledAlarms>(), hasLength(1));
      expect(r.effects.whereType<ScheduleSafetyWarning>(), hasLength(1));
    });

    test('Verworfener Eintrag bleibt als rejected erhalten', () {
      final r = machine.transition(start(), UserDiscarded(at(7, 10)),
          userId: user);

      expect(r.session, isNull);
      final persisted =
          r.effects.whereType<PersistCompletedEntry>().single.entry;
      expect(persisted.status, TimeEntryStatus.rejected);
      expect(r.effects.whereType<RemoveGeofence>(), hasLength(1));
    });
  });

  group('Safety Net: Push ignorieren', () {
    test('Timer läuft trotz ignorierter Push weiter und bleibt unbestätigt',
        () {
      final s = start();
      // Kein UserConfirmed – der Monteur reagiert nicht.
      expect(s.state, TimeTrackingState.trackingUnconfirmed);
      expect(s.state.isActive, isTrue);
      expect(s.state.needsAttention, isTrue);

      // Nach acht Stunden ist die Zeit vollständig erfasst.
      expect(s.entry.grossDuration(now: at(15)), const Duration(hours: 8));
    });

    test('Austritt beendet auch einen nie bestätigten Timer', () {
      final r = machine.transition(
        start(),
        GeofenceExited(order, at(16)),
        userId: user,
      );

      expect(r.session!.state, TimeTrackingState.stoppedUnconfirmed);
      expect(r.session!.entry.endTime, at(16));
      expect(r.session!.entry.status, TimeEntryStatus.unconfirmed);
      expect(r.effects.whereType<ShowDepartureNotification>(), hasLength(1));
    });
  });

  group('Pausen', () {
    test('Pause zählt nicht als Arbeitszeit', () {
      var s = start();
      s = machine.transition(s, PauseStarted(at(12)), userId: user).session!;
      expect(s.state, TimeTrackingState.paused);
      expect(s.pauseEndsAt, at(12, 30));

      s = machine.transition(s, PauseEnded(at(12, 30)), userId: user).session!;
      expect(s.state, TimeTrackingState.trackingConfirmed);
      expect(s.entry.breakDurationMinutes, 30);

      // 07:00–16:00 brutto = 9 h, minus 30 min Pause = 8,5 h.
      expect(s.entry.netDuration(now: at(16)), const Duration(hours: 8, minutes: 30));
      expect(s.entry.netHours(now: at(16)), 8.5);
    });

    test('Pause plant eine Erinnerung ein', () {
      final r = machine.transition(start(), PauseStarted(at(12)), userId: user);
      final reminder = r.effects.whereType<SchedulePauseReminder>().single;
      expect(reminder.fireAt, at(12, 30));
    });

    test('zweite Pause während der Pause wird ignoriert', () {
      var s = start();
      s = machine.transition(s, PauseStarted(at(12)), userId: user).session!;
      final r = machine.transition(s, PauseStarted(at(12, 5)), userId: user);
      expect(r.wasIgnored, isTrue);
    });

    test('Rückkehr auf die Baustelle beendet die Pause', () {
      var s = start();
      s = machine.transition(s, PauseStarted(at(12)), userId: user).session!;
      final r =
          machine.transition(s, GeofenceEntered(order, at(12, 20)), userId: user);

      expect(r.session!.state, TimeTrackingState.trackingConfirmed);
      expect(r.session!.entry.breakDurationMinutes, 20);
    });

    test('Feierabend während der Pause rechnet die Pause korrekt ab', () {
      var s = start();
      s = machine.transition(s, PauseStarted(at(12)), userId: user).session!;
      final r =
          machine.transition(s, GeofenceExited(order, at(12, 15)), userId: user);

      expect(r.session!.state, TimeTrackingState.stoppedUnconfirmed);
      expect(r.session!.entry.breakDurationMinutes, 15);
    });
  });

  group('Gesetzlicher Pausenabzug', () {
    test('unter 6 Stunden kein Abzug', () {
      expect(TrackingRules.legalBreakMinutes(const Duration(hours: 5)), 0);
      expect(TrackingRules.legalBreakMinutes(const Duration(hours: 6)), 0);
    });

    test('über 6 Stunden 30 Minuten', () {
      expect(
          TrackingRules.legalBreakMinutes(const Duration(hours: 6, minutes: 1)),
          30);
      expect(TrackingRules.legalBreakMinutes(const Duration(hours: 9)), 30);
    });

    test('über 9 Stunden 45 Minuten', () {
      expect(TrackingRules.legalBreakMinutes(const Duration(hours: 10)), 45);
    });

    test('bereits erfasste Pausen werden angerechnet', () {
      // 8 h Arbeit → 30 min Pflicht, 20 min schon genommen → 10 min fehlen.
      expect(
        TrackingRules.suggestedAdditionalBreak(const Duration(hours: 8), 20),
        10,
      );
      // Mehr genommen als nötig → kein weiterer Abzug.
      expect(
        TrackingRules.suggestedAdditionalBreak(const Duration(hours: 8), 45),
        0,
      );
    });
  });

  group('Nacht-Sicherheitsnetz', () {
    test('Kappung setzt Endzeit auf 17:00 und markiert zur Prüfung', () {
      final s = start();
      final r = machine.transition(
        s,
        AutoSafetyCapTriggered(
            TrackingRules.cappedEndTime(s.entry.startTime), at(22)),
        userId: user,
      );

      expect(r.session!.state, TimeTrackingState.stoppedUnconfirmed);
      expect(r.session!.entry.endTime, at(17));
      expect(r.session!.entry.isAutoCapped, isTrue);
      expect(r.session!.entry.status, TimeEntryStatus.flaggedForReview);
    });

    test('gekappter Eintrag bleibt auch nach Abschluss prüfbedürftig', () {
      var s = start();
      s = machine
          .transition(
              s,
              AutoSafetyCapTriggered(
                  TrackingRules.cappedEndTime(s.entry.startTime), at(22)),
              userId: user)
          .session!;
      final r = machine.transition(
          s, EntryFinalized(at(22), breakMinutes: 30), userId: user);

      expect(r.session!.entry.status, TimeEntryStatus.flaggedForReview);
    });

    test('Warnzeit ist der frühere von 11 h Laufzeit und 19:00', () {
      // Start 07:00 → 11 h wären 18:00, das ist früher als 19:00.
      expect(TrackingRules.safetyWarningTime(at(7)), at(18));
      // Start 10:00 → 11 h wären 21:00, also greift 19:00.
      expect(TrackingRules.safetyWarningTime(at(10)), at(19));
    });

    test('Start nach 19:00 nutzt nur die Laufzeitgrenze', () {
      final s = at(20);
      expect(TrackingRules.safetyWarningTime(s), s.add(const Duration(hours: 11)));
    });

    test('Kappungszeit rutscht bei Nachtschicht auf den Folgetag', () {
      final night = at(23);
      expect(TrackingRules.safetyCapTime(night),
          DateTime(2026, 8, 11, TrackingRules.autoCapHour));
    });
  });

  group('Fehlauslösungen', () {
    test('sehr kurzer Aufenthalt wird verworfen statt erfasst', () {
      final r = machine.transition(
        start(),
        GeofenceExited(order, at(7, 2)),
        userId: user,
      );

      expect(r.session, isNull);
      final persisted =
          r.effects.whereType<PersistCompletedEntry>().single.entry;
      expect(persisted.status, TimeEntryStatus.rejected);
    });

    test('Austritt aus fremdem Geofence lässt den Timer unberührt', () {
      final s = start();
      final r =
          machine.transition(s, GeofenceExited('p2', at(9)), userId: user);

      expect(r.wasIgnored, isTrue);
      expect(r.session!.state, TimeTrackingState.trackingUnconfirmed);
    });

    test('Ereignis ohne laufenden Timer ist folgenlos', () {
      final r =
          machine.transition(null, GeofenceExited(order, at(9)), userId: user);
      expect(r.session, isNull);
      expect(r.effects, isEmpty);
      expect(r.wasIgnored, isTrue);
    });
  });

  group('Abschluss', () {
    test('Feierabend übernimmt Pausenabzug und persistiert', () {
      var s = start();
      s = machine
          .transition(s, GeofenceExited(order, at(16)), userId: user)
          .session!;
      final r = machine.transition(
          s, EntryFinalized(at(16), breakMinutes: 30), userId: user);

      expect(r.session!.state, TimeTrackingState.completed);
      final done = r.effects.whereType<PersistCompletedEntry>().single.entry;
      expect(done.status, TimeEntryStatus.confirmed);
      expect(done.breakDurationMinutes, 30);
      // 07:00–16:00 = 9 h brutto, minus 30 min = 8,5 h netto.
      expect(done.netHours(), 8.5);
      expect(r.effects.whereType<StopForegroundService>(), hasLength(1));
      expect(r.effects.whereType<RemoveGeofence>(), hasLength(1));
    });

    test('Bestätigen im gestoppten Zustand zieht die Pause automatisch ab', () {
      var s = start();
      s = machine
          .transition(s, GeofenceExited(order, at(16)), userId: user)
          .session!;
      final r = machine.transition(s, UserConfirmed(at(16, 5)), userId: user);

      // 9 h brutto → gesetzlich 30 min.
      expect(r.session!.entry.breakDurationMinutes, 30);
      expect(r.session!.entry.netHours(), 8.5);
    });

    test('Rückkehr nach Feierabend startet einen neuen Abschnitt', () {
      var s = start();
      s = machine
          .transition(s, GeofenceExited(order, at(12)), userId: user)
          .session!;
      final r =
          machine.transition(s, GeofenceEntered(order, at(13)), userId: user);

      expect(r.session!.entry.startTime, at(13));
      expect(r.effects.whereType<PersistCompletedEntry>(), hasLength(1));
    });
  });

  group('Serialisierung', () {
    test('Sitzung übersteht einen Speicher-Zyklus unverändert', () {
      var s = start();
      s = machine.transition(s, PauseStarted(at(12)), userId: user).session!;

      final restored = TrackingSession.fromJson(s.toJson())!;

      expect(restored.state, s.state);
      expect(restored.entry.id, s.entry.id);
      expect(restored.entry.startTime, s.entry.startTime);
      expect(restored.pauseStartedAt, s.pauseStartedAt);
      expect(restored.pauseEndsAt, s.pauseEndsAt);
    });

    test('kaputte Felder führen nicht zum Datenverlust', () {
      final e = TimeEntry.fromJson({'id': 'x', 'orderId': 'p1', 'status': 'quatsch'});
      expect(e.id, 'x');
      expect(e.status, TimeEntryStatus.unconfirmed);
    });
  });
}
