// Absicherung der gemeinsamen Zeiterfassung.
//
// Die Punkte, die hier hängen bleiben sollen:
//
//  * Abgeschlossene Zeiten liegen im Netz, nicht nur auf dem Handy – sonst
//    sieht das Büro sie nie.
//  * Die **laufende** Sitzung bleibt auf dem Gerät. Sie ist Gerätezustand und
//    wird nach jedem Tastendruck gesichert; sie gehört nicht ins Netz.
//  * Anlegen und Korrigieren treffen dasselbe Dokument. Eine doppelt
//    zugestellte Benachrichtigung darf keine zweite Zeit erzeugen.
//  * Das bisher nur lokale Journal wird einmalig übernommen – aber nur, was
//    dem Angemeldeten gehört. Zeit im Namen eines anderen einzutragen lässt
//    der Server nicht zu, und das ist richtig so.

import 'dart:convert';

import 'package:baudoc/timetracking/data/firestore_tracking_repository.dart';
import 'package:baudoc/timetracking/data/prefs_tracking_repository.dart';
import 'package:baudoc/timetracking/models/time_entry.dart';
import 'package:baudoc/timetracking/models/tracking_state.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ich = 'uid_anna';

TimeEntry _eintrag({
  String id = 'tt_1',
  String userId = _ich,
  String orderId = 'p1',
  String task = 'Mauern',
  int stunden = 8,
}) =>
    TimeEntry(
      id: id,
      orderId: orderId,
      userId: userId,
      startTime: DateTime(2026, 8, 12, 7),
      endTime: DateTime(2026, 8, 12, 7 + stunden),
      status: TimeEntryStatus.confirmed,
      task: task,
    );

Future<(FirestoreTrackingRepository, FakeFirebaseFirestore)> _repo({
  Map<String, Object> prefs = const {},
  String uid = _ich,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final db = FakeFirebaseFirestore();
  final repo = FirestoreTrackingRepository(
    currentUserId: () => uid,
    firestore: db,
    sitzungsspeicher: PrefsTrackingRepository(),
  );
  await repo.init();
  return (repo, db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Journal im Netz', () {
    test('ein abgeschlossener Eintrag landet in timeEntries', () async {
      final (repo, db) = await _repo();
      await repo.appendEntry(_eintrag());

      final docs = await db.collection('timeEntries').get();
      expect(docs.docs, hasLength(1));
      expect(docs.docs.single.id, 'tt_1');
      expect(docs.docs.single.data()['userId'], _ich);
      expect(docs.docs.single.data()['task'], 'Mauern');
    });

    test('eine Korrektur trifft dasselbe Dokument', () async {
      final (repo, db) = await _repo();
      await repo.appendEntry(_eintrag());
      await repo.updateEntry(_eintrag(task: 'Putz EG'));

      final docs = await db.collection('timeEntries').get();
      expect(docs.docs, hasLength(1),
          reason: 'sonst stünde die Zeit zweimal in der Abrechnung');
      expect(docs.docs.single.data()['task'], 'Putz EG');
    });

    test('der eigene Eintrag steht sofort in der Liste', () async {
      // Der Controller liest direkt nach dem Schreiben. Wartete er auf die
      // Rückmeldung von Firestore, fehlte die gerade beendete Zeit kurz.
      final (repo, _) = await _repo();
      await repo.appendEntry(_eintrag());
      expect((await repo.loadEntries()).single.id, 'tt_1');
    });

    test('ein fremder Eintrag kommt an und meldet sich', () async {
      final (repo, db) = await _repo();
      var gemeldet = 0;
      repo.onRemoteChange = () => gemeldet++;

      // Der Kollege erfasst auf seinem Gerät.
      await db.collection('timeEntries').doc('tt_kollege').set({
        'orderId': 'p1',
        'userId': 'uid_max',
        'startTime': '2026-08-12T08:00:00.000',
        'endTime': '2026-08-12T16:00:00.000',
        'status': 'confirmed',
        'task': 'Fundament',
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(gemeldet, greaterThan(0),
          reason: 'der Prüf-Bildschirm muss davon erfahren');
      final liste = await repo.loadEntries();
      expect(liste.map((e) => e.id), contains('tt_kollege'));
      expect(liste.firstWhere((e) => e.id == 'tt_kollege').task, 'Fundament');
    });
  });

  group('Laufende Sitzung', () {
    test('bleibt auf dem Gerät und geht nicht ins Netz', () async {
      final (repo, db) = await _repo();

      await repo.saveSession(TrackingSession(
        state: TimeTrackingState.trackingConfirmed,
        entry: _eintrag(id: 'tt_laeuft'),
      ));

      // Nichts im Netz: die Sitzung wird nach jedem Zustandswechsel
      // gesichert – das wäre ein Schreibvorgang je Tastendruck für etwas,
      // das niemand sonst liest.
      expect((await db.collection('timeEntries').get()).docs, isEmpty);
      // Aber wiederherstellbar, das ist ihr eigentlicher Zweck.
      expect((await repo.loadSession())?.entry.id, 'tt_laeuft');
    });
  });

  group('Übernahme des Gerätejournals', () {
    Map<String, Object> journalMit(List<TimeEntry> eintraege) => {
          'tt_entries_v1':
              jsonEncode(eintraege.map((e) => e.toJson()).toList()),
        };

    test('eigene Zeiten wandern in die gemeinsame Ablage', () async {
      final (_, db) = await _repo(
        prefs: journalMit([_eintrag(id: 'alt1'), _eintrag(id: 'alt2')]),
      );

      final docs = await db.collection('timeEntries').get();
      expect(docs.docs.map((d) => d.id), containsAll(['alt1', 'alt2']));
    });

    test('eine Zeit ohne Kennung bekommt den Angemeldeten', () async {
      // Aus der Zeit vor der Anmeldung mit Konto. Der Eintrag ist auf diesem
      // Gerät entstanden, also gehört er dem, der hier arbeitet.
      final (_, db) = await _repo(
        prefs: journalMit([_eintrag(id: 'ohne', userId: '')]),
      );

      final d = await db.collection('timeEntries').doc('ohne').get();
      expect(d.data()!['userId'], _ich);
    });

    test('die Zeit eines anderen Kontos bleibt liegen', () async {
      final (_, db) = await _repo(
        prefs: journalMit([_eintrag(id: 'fremd', userId: 'uid_max')]),
      );

      expect((await db.collection('timeEntries').doc('fremd').get()).exists,
          isFalse,
          reason: 'Arbeitszeit im Namen eines anderen einzutragen wäre '
              'schlimmer als eine fehlende Zeile');
    });

    test('läuft nur einmal – der Stand des Büros bleibt stehen', () async {
      final prefs = journalMit([_eintrag(id: 'alt1', task: 'alter Text')]);
      final (_, db) = await _repo(prefs: prefs);

      // Das Büro korrigiert die übernommene Zeit.
      await db
          .collection('timeEntries')
          .doc('alt1')
          .set({'task': 'korrigiert'}, SetOptions(merge: true));

      // Dasselbe Gerät startet erneut – mit demselben Gerätespeicher.
      final zweiter = FirestoreTrackingRepository(
        currentUserId: () => _ich,
        firestore: db,
        sitzungsspeicher: PrefsTrackingRepository(),
      );
      await zweiter.init();

      final d = await db.collection('timeEntries').doc('alt1').get();
      expect(d.data()!['task'], 'korrigiert',
          reason: 'der alte Gerätestand darf die Korrektur nicht ersetzen');
    });

    test('ohne Anmeldung wird nichts übernommen', () async {
      final (_, db) = await _repo(
        prefs: journalMit([_eintrag(id: 'alt1')]),
        uid: '',
      );
      expect((await db.collection('timeEntries').get()).docs, isEmpty);
    });
  });
}
