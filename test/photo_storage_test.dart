// Absicherung der Fotos in der Dateiablage.
//
// Der Punkt des Umbaus, der hier hängen bleiben soll: **das Bild gehört nicht
// in die Datenbank.** Ein Firestore-Dokument darf 1 MB groß sein, ein Foto als
// Base64 belegt davon 135–340 KB – nach ein paar Bildern ließe sich der Auftrag
// nicht mehr speichern, und jedes Laden der Auftragsliste zöge sämtliche Bilder
// über das Mobilfunknetz mit.
//
// Der zweite Punkt ist der Altbestand. Vor diesem Schritt war ein Foto genau
// eine Base64-Zeichenkette und sonst nichts. Solche Einträge liegen auf jedem
// Gerät, das die App bisher benutzt hat; sie dürfen beim Aktualisieren nicht
// verschwinden.

import 'dart:convert';
import 'dart:typed_data';

import 'package:baudoc/data/firestore_master_data_repository.dart';
import 'package:baudoc/data/master_data_repository.dart';
import 'package:baudoc/data/prefs_master_data_repository.dart';
import 'package:baudoc/models.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ein paar Bytes, die für ein Bild durchgehen. Der Inhalt spielt keine Rolle –
/// geprüft wird, *wohin* er wandert.
final _bild = Uint8List.fromList(List.generate(64, (i) => i));

MasterData _bestand({List<Photo>? fotos}) {
  final data = MasterData.empty();
  data.projects = [
    Project(
      id: 'p1',
      name: 'Neubau Müllerstr. 12',
      type: 'Neubau',
      address: 'Müllerstr. 12, Speyer',
      status: 'active',
      hours: [],
      materials: [],
      tasks: [],
      photos: fotos,
    )
  ];
  return data;
}

typedef _Aufbau = (
  FirestoreMasterDataRepository,
  FakeFirebaseFirestore,
  MockFirebaseStorage
);

Future<_Aufbau> _befuellt({List<Photo>? fotos}) async {
  final db = FakeFirebaseFirestore();
  final ablage = MockFirebaseStorage();
  final repo = FirestoreMasterDataRepository(firestore: db, storage: ablage);
  await repo.init();
  await repo.replaceAll(_bestand(fotos: fotos));
  return (repo, db, ablage);
}

/// Eine Dateiablage, die nicht erreichbar ist – wie im Funkloch.
///
/// `noSuchMethod` reicht alles Übrige durch; gefragt ist hier nur, was
/// passiert, wenn schon der erste Zugriff scheitert.
class _KeineAblage implements FirebaseStorage {
  @override
  Reference ref([String? path]) => throw FirebaseException(
      plugin: 'firebase_storage', code: 'retry-limit-exceeded');

  @override
  dynamic noSuchMethod(Invocation aufruf) => super.noSuchMethod(aufruf);
}

Future<List<Map<String, dynamic>>> _fotoDokumente(
        FakeFirebaseFirestore db) async =>
    (await db.collection('projects').doc('p1').collection('photos').get())
        .docs
        .map((d) => {...d.data(), 'id': d.id})
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Ablegen', () {
    test('das Bild geht in die Dateiablage, in die Datenbank nur der Verweis',
        () async {
      final (repo, db, ablage) = await _befuellt();

      final foto = await repo.addPhoto('p1', _bild, uploadedBy: 'u1');

      expect(foto, isNotNull, reason: 'sonst hat der Monteur kein Foto');
      expect(foto!.url, isNotEmpty);
      expect(foto.storagePath, 'projects/p1/${foto.id}.jpg');
      expect(foto.uploadedBy, 'u1');

      // Das eigentliche Versprechen dieses Schritts.
      final docs = await _fotoDokumente(db);
      expect(docs, hasLength(1));
      expect(docs.single.containsKey('data'), isFalse,
          reason: 'Bilddaten haben in der Datenbank nichts zu suchen');
      expect(docs.single['url'], foto.url);
      expect(docs.single['storagePath'], foto.storagePath);

      // Und das Bild liegt tatsächlich in der Ablage.
      expect(await ablage.ref(foto.storagePath).getData(), _bild);
    });

    test('das Foto-Dokument bleibt winzig', () async {
      final (repo, db, _) = await _befuellt();
      // Ein Bild in der Größenordnung, die die App wirklich erzeugt.
      await repo.addPhoto('p1', Uint8List(250 * 1024), uploadedBy: 'u1');

      final laenge = jsonEncode((await _fotoDokumente(db)).single).length;
      expect(laenge, lessThan(2000),
          reason: 'ein Dokument darf 1 MB groß sein – hiervon passen viele '
              'in einen Auftrag, von Base64 nicht');
    });

    test('Löschen entfernt Verweis und Bilddatei', () async {
      final (repo, db, ablage) = await _befuellt();
      final foto = (await repo.addPhoto('p1', _bild, uploadedBy: 'u1'))!;

      await repo.deletePhoto('p1', foto);

      expect(await _fotoDokumente(db), isEmpty);
      // Die Datei bliebe sonst für immer stehen – bezahlt wird nach belegtem
      // Speicher.
      expect(ablage.storedDataMap.containsKey(foto.storagePath), isFalse);
    });

    test('geht die Ablage nicht, entsteht kein halbes Foto', () async {
      // Der Funkloch-Fall. Die Datenbank nähme den Schreibvorgang lokal an und
      // reichte ihn nach – die Dateiablage kann das nicht. Es darf dann weder
      // ein Verweis auf ein nicht vorhandenes Bild entstehen noch eine
      // stillschweigende Nicht-Reaktion: der Aufrufer muss ein Nein bekommen.
      final db = FakeFirebaseFirestore();
      final repo =
          FirestoreMasterDataRepository(firestore: db, storage: _KeineAblage());
      await repo.init();
      await repo.replaceAll(_bestand());

      final foto = await repo.addPhoto('p1', _bild, uploadedBy: 'u1');

      expect(foto, isNull, reason: 'sonst hält der Monteur es für gesichert');
      expect(await _fotoDokumente(db), isEmpty,
          reason: 'ein Verweis ohne Bild wäre ein dauerhaft kaputtes Foto');
    });

    test('mit einem gelöschten Auftrag gehen auch seine Bilddateien',
        () async {
      final (repo, _, ablage) = await _befuellt();
      final foto = (await repo.addPhoto('p1', _bild, uploadedBy: 'u1'))!;

      await repo.deleteProject('p1');

      expect(ablage.storedDataMap.containsKey(foto.storagePath), isFalse);
    });
  });

  group('Altbestand', () {
    test('ein Base64-Foto wird in die Dateiablage gehoben', () async {
      // So sah ein Foto vor diesem Schritt aus, und so liegt es auf jedem
      // Gerät, das die App bisher benutzt hat.
      final alt = Photo(id: 'foto_0', data: base64Encode(_bild));
      final (repo, db, ablage) = await _befuellt(fotos: [alt]);

      // Die Übernahme läuft nebenher, damit der Start nicht darauf wartet.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final doc = (await _fotoDokumente(db)).single;
      expect(doc['url'], isNotEmpty, reason: 'Bild ist jetzt in der Ablage');
      expect(doc.containsKey('data'), isFalse,
          reason: 'und steht nicht mehr in der Datenbank');
      expect(doc['storagePath'], 'projects/p1/foto_0.jpg');
      expect(await ablage.ref('projects/p1/foto_0.jpg').getData(), _bild);
    });

    test('bis dahin ist das Bild trotzdem da', () async {
      // Zwischen „liegt als Base64 in der Datenbank" und „liegt in der Ablage"
      // vergeht Zeit – im Funkloch beliebig viel. In dieser Zeit darf in der
      // Auftragsliste kein Bild fehlen.
      final db = FakeFirebaseFirestore();
      await db.collection('settings').doc('migration').set({'done': true});
      await db.collection('projects').doc('p1').set({'name': 'Neubau'});
      await db
          .collection('projects')
          .doc('p1')
          .collection('photos')
          .doc('foto_0')
          .set({'data': base64Encode(_bild)});

      final repo = FirestoreMasterDataRepository(
          firestore: db, storage: MockFirebaseStorage());
      await repo.init();
      final data = await repo.load();

      final foto = data!.projects.single.photos.single;
      expect(foto.inCloud, isFalse);
      expect(base64Decode(foto.data), _bild,
          reason: 'die Anzeige greift solange hierauf zurück');
    });

    test('die Übernahme wiederholt sich nicht', () async {
      final alt = Photo(id: 'foto_0', data: base64Encode(_bild));
      final (repo, db, ablage) = await _befuellt(fotos: [alt]);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Die Datei aus der Ablage nehmen. Lüde die Übernahme beim nächsten Mal
      // erneut hoch, wäre sie gleich wieder da – und jeder Start schöbe alle
      // Bilder des Betriebs noch einmal durchs Netz.
      const pfad = 'projects/p1/foto_0.jpg';
      await ablage.ref(pfad).delete();

      // Zweiter Start derselben App. Erkannt wird das am Foto selbst: es hat
      // eine Abrufadresse und kein Base64 mehr. Ein Kennzeichen, das dabei
      // schieflaufen könnte, braucht es dafür nicht.
      await repo.load();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(ablage.storedDataMap.containsKey(pfad), isFalse);
      expect(await _fotoDokumente(db), hasLength(1));
    });
  });

  // Beide Tests hier laufen nicht durch, und zwar aus demselben Grund wie der
  // übersprungene Stunden-Test in firestore_repository_test.dart: der
  // Firestore-Nachbau meldet bei sammlungsübergreifenden Abfragen keine
  // laufenden Änderungen – `collectionGroup().snapshots()` bleibt stumm,
  // `get()` funktioniert. Nachgewiesen wurde dieser Weg stattdessen am Gerät.
  group('Zusammenarbeit', () {
    test('ein Foto vom anderen Gerät erscheint ohne Neuladen',
        skip: 'fake_cloud_firestore kennt collectionGroup().snapshots() nicht',
        () async {
      // Der Zweck des ganzen Umbaus: der Monteur fotografiert die Baustelle,
      // und im Büro liegt das Bild da, ohne dass jemand die App neu startet.
      final (repo, db, _) = await _befuellt();
      final bestand = await repo.load();
      var gemeldet = 0;
      repo.onRemoteChange = () => gemeldet++;

      await db
          .collection('projects')
          .doc('p1')
          .collection('photos')
          .doc('von_draussen')
          .set({
        'url': 'https://ablage/von_draussen.jpg',
        'storagePath': 'projects/p1/von_draussen.jpg',
        'uploadedBy': 'u2',
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(gemeldet, greaterThan(0), reason: 'die Anzeige muss davon hören');
      final fotos = bestand!.projects.single.photos;
      expect(fotos.map((f) => f.id), contains('von_draussen'));
      expect(fotos.firstWhere((f) => f.id == 'von_draussen').inCloud, isTrue);
    });

    test('ein anderswo gelöschtes Foto verschwindet auch hier',
        skip: 'fake_cloud_firestore kennt collectionGroup().snapshots() nicht',
        () async {
      final (repo, db, _) = await _befuellt();
      final foto = (await repo.addPhoto('p1', _bild, uploadedBy: 'u1'))!;
      final bestand = await repo.load();
      expect(bestand!.projects.single.photos, hasLength(1));

      await db
          .collection('projects')
          .doc('p1')
          .collection('photos')
          .doc(foto.id)
          .delete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(bestand.projects.single.photos, isEmpty);
    });
  });

  group('Gelesene Datenstände', () {
    test('eine alte Fotoliste aus reinem Base64 bleibt lesbar', () async {
      // Genau das steht heute im JSON-Text auf dem Gerät des Nutzers: eine
      // Liste von Zeichenketten, kein Objekt weit und breit.
      final p = Project.fromJson({
        'id': 'p1',
        'name': 'Neubau',
        'hours': [],
        'materials': [],
        'tasks': [],
        'photos': ['AAAA', 'BBBB'],
      });

      expect(p.photos, hasLength(2));
      expect(p.photos.first.data, 'AAAA');
      expect(p.photos.first.inCloud, isFalse);
      // Die Ersatz-Namen folgen der Benennung in der Datenbank, damit ein
      // übernommener Altbestand nicht doppelt erscheint.
      expect(p.photos.map((f) => f.id), ['foto_0', 'foto_1']);
    });

    test('ein neues Foto schreibt kein leeres Base64-Feld', () {
      final j = Photo(id: 'f1', url: 'https://…', storagePath: 'x').toJson();
      expect(j.containsKey('data'), isFalse);
    });

    test('gespeicherte Fotos überstehen einen Speicher-Zyklus', () {
      final p = Project.fromJson(Project(
        id: 'p1',
        name: 'Neubau',
        type: '',
        address: '',
        status: 'active',
        hours: [],
        materials: [],
        tasks: [],
        photos: [
          Photo(
              id: 'f1',
              url: 'https://ablage/f1.jpg',
              storagePath: 'projects/p1/f1.jpg',
              uploadedBy: 'u1')
        ],
      ).toJson());

      expect(p.photos.single.id, 'f1');
      expect(p.photos.single.url, 'https://ablage/f1.jpg');
      expect(p.photos.single.inCloud, isTrue);
    });
  });

  group('Ohne Backend', () {
    test('auf dem Gerät bleibt das Bild beim Datensatz', () async {
      // Ohne Firebase gibt es keine Dateiablage. Dort ist Base64 kein Altlast,
      // sondern der einzig mögliche Weg – und die 1-MB-Grenze gibt es nicht.
      SharedPreferences.setMockInitialValues({});
      final repo = PrefsMasterDataRepository();
      await repo.init();
      await repo.replaceAll(_bestand());

      final foto = await repo.addPhoto('p1', _bild, uploadedBy: 'u1');

      expect(foto, isNotNull);
      expect(foto!.inCloud, isFalse);
      expect(base64Decode(foto.data), _bild);

      // Und es übersteht einen Neustart.
      final neu = PrefsMasterDataRepository();
      await neu.init();
      final geladen = await neu.load();
      expect(geladen!.projects.single.photos.single.data, foto.data);
    });
  });
}
