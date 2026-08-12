// Absicherung der gemeinsamen Datenbank.
//
// Die wichtigsten Punkte, die hier hängen bleiben sollen:
//
//  * Stunden liegen als **eigene** Dokumente im Auftrag. Speichert jemand den
//    Auftrag, dürfen die Stunden eines Kollegen nicht mit überschrieben werden –
//    das wären abrechenbare Stunden.
//  * Stundenlöhne liegen getrennt von den Benutzern. Firestore vergibt Rechte
//    nur je Dokument; im Benutzer-Dokument läse den Lohn jeder mit.
//  * Die einmalige Übernahme darf genau einmal laufen, sonst überschreibt ein
//    Gerät beim Start den Stand des Büros mit seinem alten.

import 'package:baudoc/data/firestore_master_data_repository.dart';
import 'package:baudoc/data/master_data_repository.dart';
import 'package:baudoc/models.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

MasterData _bestand() {
  final data = MasterData.empty();
  data.customers = [
    Customer(
        id: 'k1',
        name: 'Familie Müller',
        address: 'Müllerstr. 12',
        contact: '0621 123456')
  ];
  data.catalog = [
    CatalogItem(id: 'c1', name: 'Beton C25/30', unit: 'm³', price: 115)
  ];
  data.users = [
    AppUser(
        id: 'u1',
        name: 'Anna Bauer',
        role: 'Administrator',
        email: 'anna@betrieb.de',
        wage: 60)
  ];
  data.projects = [
    Project(
      id: 'p1',
      name: 'Neubau Müllerstr. 12',
      type: 'Neubau',
      address: 'Müllerstr. 12, Speyer',
      status: 'active',
      customerId: 'k1',
      hours: [
        WorkHours(
            id: 'h1', worker: 'Max M.', date: '2026-08-01', task: 'Mauern', h: 8, synced: true)
      ],
      materials: [],
      tasks: [],
    )
  ];
  data.rolePerms = {
    'Administrator': ['wages'],
    'Handwerker': <String>[],
  };
  data.roles = ['Administrator', 'Handwerker'];
  return data;
}

Future<(FirestoreMasterDataRepository, FakeFirebaseFirestore)> _befuellt() async {
  final db = FakeFirebaseFirestore();
  final repo = FirestoreMasterDataRepository(firestore: db);
  await repo.init();
  await repo.replaceAll(_bestand());
  return (repo, db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Übernahme', () {
    test('leere Datenbank meldet sich als leer, damit der Aufrufer befüllt',
        () async {
      final repo = FirestoreMasterDataRepository(firestore: FakeFirebaseFirestore());
      await repo.init();
      expect(await repo.load(), isNull);
    });

    test('nach der Übernahme steht alles da', () async {
      final (repo, _) = await _befuellt();
      final geladen = await repo.load();

      expect(geladen, isNotNull);
      expect(geladen!.projects.single.name, 'Neubau Müllerstr. 12');
      expect(geladen.customers.single.name, 'Familie Müller');
      expect(geladen.catalog.single.unit, 'm³');
      expect(geladen.arten, isNotEmpty);
      expect(geladen.rolePerms['Administrator'], ['wages']);
    });

    test('die Stunden kommen aus der Unterkollektion zurück', () async {
      final (repo, db) = await _befuellt();

      // Wirklich als eigenes Dokument abgelegt?
      final unter =
          await db.collection('projects').doc('p1').collection('hours').get();
      expect(unter.docs, hasLength(1));
      // Und nicht zusätzlich im Auftrag selbst.
      final auftrag = await db.collection('projects').doc('p1').get();
      expect(auftrag.data()!.containsKey('hours'), isFalse);

      final geladen = await repo.load();
      expect(geladen!.projects.single.hours.single.h, 8.0);
      expect(geladen.projects.single.hours.single.worker, 'Max M.');
    });

    test('eine zweite Übernahme überschreibt den Stand nicht', () async {
      final (repo, db) = await _befuellt();

      // Das Büro hat inzwischen den Auftrag umbenannt.
      await db
          .collection('projects')
          .doc('p1')
          .set({'name': 'Umbau Bahnhofstr.'}, SetOptions(merge: true));

      // Ein zweites Geraet meldet sich zum ersten Mal an und will uebernehmen.
      final zweites = FirestoreMasterDataRepository(firestore: db);
      await zweites.init();
      await zweites.replaceAll(_bestand());

      final j = await db.collection('projects').doc('p1').get();
      expect(j.data()!['name'], 'Umbau Bahnhofstr.',
          reason: 'der alte Geraetestand darf den Stand des Buero nicht ersetzen');
    });
  });

  group('Stundenlöhne', () {
    test('stehen getrennt von den Benutzern', () async {
      final (_, db) = await _befuellt();

      final benutzer = await db.collection('users').doc('u1').get();
      expect(benutzer.data()!.containsKey('wage'), isFalse,
          reason: 'sonst laese den Lohn jeder, der die Namen liest');

      final lohn = await db.collection('wages').doc('u1').get();
      expect(lohn.data()!['wage'], 60);
    });

    test('werden beim Laden wieder zusammengeführt', () async {
      final (repo, _) = await _befuellt();
      final geladen = await repo.load();
      expect(geladen!.users.single.wage, 60);
      expect(geladen.users.single.email, 'anna@betrieb.de');
    });
  });

  group('Einzelne Datensätze', () {
    test('ein Auftrag wird ohne seine Stunden geschrieben', () async {
      final (repo, db) = await _befuellt();
      final geladen = await repo.load();
      final p = geladen!.projects.single;

      p.name = 'Umbau Bahnhofstr.';
      await repo.saveProject(p);

      final j = await db.collection('projects').doc('p1').get();
      expect(j.data()!['name'], 'Umbau Bahnhofstr.');
      // Entscheidend: die Stundenzeile lebt weiter.
      final unter =
          await db.collection('projects').doc('p1').collection('hours').get();
      expect(unter.docs, hasLength(1));
    });

    test('eine Stundenzeile trifft nur ihr eigenes Dokument', () async {
      final (repo, db) = await _befuellt();

      await repo.saveWorkHours(
          'p1',
          WorkHours(
              id: 'h2', worker: 'Anna', date: '2026-08-02', task: 'Putz', h: 4, synced: true));

      final unter =
          await db.collection('projects').doc('p1').collection('hours').get();
      expect(unter.docs, hasLength(2));
      // Die erste Zeile ist unangetastet.
      final h1 =
          await db.collection('projects').doc('p1').collection('hours').doc('h1').get();
      expect(h1.data()!['h'], 8);
    });

    test('eine gelöschte Stundenzeile verschwindet', () async {
      final (repo, db) = await _befuellt();
      await repo.deleteWorkHours('p1', 'h1');

      final unter =
          await db.collection('projects').doc('p1').collection('hours').get();
      expect(unter.docs, isEmpty);
    });

    test('ein gelöschter Auftrag nimmt seine Stunden mit', () async {
      final (repo, db) = await _befuellt();
      await repo.deleteProject('p1');

      expect((await db.collection('projects').get()).docs, isEmpty);
      final unter =
          await db.collection('projects').doc('p1').collection('hours').get();
      expect(unter.docs, isEmpty,
          reason: 'Firestore raeumt Unterkollektionen nicht von selbst auf');
    });

    test('Kategorien und Rechte gehen über saveSettings', () async {
      final (repo, db) = await _befuellt();
      final geladen = await repo.load();
      geladen!.arten.add('Solaranlage');
      geladen.rolePerms['Handwerker'] = ['exportDocs'];
      await repo.saveSettings();

      final s = await db.collection('settings').doc('categories').get();
      expect((s.data()!['arten'] as List), contains('Solaranlage'));
      final r = await db.collection('roles').doc('Handwerker').get();
      expect(r.data()!['perms'], ['exportDocs']);
    });
  });

  group('Änderungen von außen', () {
    test('ein fremder Auftrag meldet sich und landet im Bestand', () async {
      final (repo, db) = await _befuellt();
      final bestand = (await repo.load())!;

      var gemeldet = 0;
      repo.onRemoteChange = () => gemeldet++;

      // Das Büro legt einen Auftrag an.
      await db.collection('projects').doc('p2').set({
        'name': 'Dachsanierung',
        'type': 'Dach',
        'address': '',
        'status': 'active',
        'date': '2026-08-12',
        'due': '',
        'customerId': '',
        'materials': [],
        'tasks': [],
        'notes': [],
        'defects': [],
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(gemeldet, greaterThan(0), reason: 'die Oberflaeche muss erfahren davon');
      expect(bestand.projects.map((p) => p.name), contains('Dachsanierung'));
    });

    // Nicht automatisch prüfbar: der Firestore-Nachbau meldet bei
    // sammlungsübergreifenden Abfragen keine laufenden Änderungen
    // (`collectionGroup().snapshots()` bleibt stumm, `get()` funktioniert).
    // Nachgewiesen wurde dieser Weg stattdessen auf dem Gerät – Stunden im
    // Emulator erfasst, im Browser ohne Neuladen erschienen.
    test('eine fremde Stundenzeile hängt sich an den richtigen Auftrag',
        skip: 'fake_cloud_firestore kennt collectionGroup().snapshots() nicht',
        () async {
      final (repo, db) = await _befuellt();
      final bestand = (await repo.load())!;
      repo.onRemoteChange = () {};

      await db
          .collection('projects')
          .doc('p1')
          .collection('hours')
          .doc('h9')
          .set({
        'worker': 'Kollege',
        'date': '2026-08-12',
        'task': 'Fundament',
        'h': 6.5,
        'synced': true,
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final p = bestand.projects.firstWhere((p) => p.id == 'p1');
      expect(p.hours.map((h) => h.id), contains('h9'));
      expect(p.hours.firstWhere((h) => h.id == 'h9').h, 6.5);
      // Die eigene Zeile bleibt daneben stehen.
      expect(p.hours.map((h) => h.id), contains('h1'));
    });
  });
}
