// Absicherung der Stammdaten-Speicherung.
//
// Der wichtigste Test hier ist `liest einen Datenstand im alten Format`: der
// Umbau auf den Repository-Vertrag darf bestehende Installationen nicht
// entwerten. Format und Schlüssel sind unverändert – das muss nachweisbar
// bleiben, sonst startet die App eines Monteurs eines Tages leer.

import 'dart:convert';

import 'package:baudoc/data/master_data_repository.dart';
import 'package:baudoc/data/prefs_master_data_repository.dart';
import 'package:baudoc/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Schlüssel wie in der App. SharedPreferences stellt intern `flutter.` voran.
const _prefsKey = 'flutter.baudoc.flutter';

/// Ein Datenstand, wie ihn die App **vor** diesem Umbau geschrieben hat.
/// Bewusst als Rohtext hinterlegt und nicht aus den Modellen erzeugt – sonst
/// würde der Test eine Formatänderung stillschweigend mitmachen.
const _alterDatenstand = '''
{
  "catalog": [{"id":"c1","name":"Beton C25/30","unit":"m³","price":115.0}],
  "customers": [{"id":"k1","name":"Familie Müller","address":"Müllerstr. 12","contact":"0621 123456"}],
  "pauschalen": [{"id":"pa1","name":"Anfahrtspauschale","amount":50.0}],
  "projects": [{
    "id":"p1","name":"Neubau Müllerstr. 12","type":"Neubau",
    "address":"Müllerstr. 12, Speyer","status":"active","date":"2026-08-01",
    "due":"","customerId":"k1",
    "hours":[{"id":"h1","worker":"Max M.","date":"2026-08-01","task":"Mauern EG","h":8.0,"synced":true}],
    "materials":[],"tasks":[],"notes":[],"photos":[],"defects":[]
  }],
  "users": [{"id":"u1","name":"Administrator","role":"Administrator","pin":"0000","wage":0.0}],
  "arten": ["Neubau","Dach"],
  "roles": ["Administrator","Handwerker"],
  "rolePerms": {"Administrator":["wages"],"Handwerker":[]},
  "online": true,
  "adminSeeded": true,
  "rolesMigrated": true
}
''';

Future<PrefsMasterDataRepository> _repoMit(Map<String, Object> werte) async {
  SharedPreferences.setMockInitialValues(werte);
  final repo = PrefsMasterDataRepository();
  await repo.init();
  return repo;
}

/// Was gerade unter dem Schlüssel auf der Platte steht.
Future<Map<String, dynamic>> _gespeichert() async {
  final p = await SharedPreferences.getInstance();
  return jsonDecode(p.getString('baudoc.flutter')!) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Lesen', () {
    test('liest einen Datenstand im alten Format', () async {
      final repo = await _repoMit({_prefsKey: _alterDatenstand});
      final data = await repo.load();

      expect(data, isNotNull);
      expect(data!.projects, hasLength(1));
      expect(data.projects.single.name, 'Neubau Müllerstr. 12');
      expect(data.projects.single.hours.single.h, 8.0);
      expect(data.customers.single.name, 'Familie Müller');
      expect(data.catalog.single.unit, 'm³');
      expect(data.users.single.role, 'Administrator');
      expect(data.arten, ['Neubau', 'Dach']);
      expect(data.rolePerms['Administrator'], ['wages']);
      expect(data.adminSeeded, isTrue);
      expect(data.rolesMigrated, isTrue);
    });

    test('ohne gespeicherte Daten kommt null – der Aufrufer befüllt dann neu',
        () async {
      final repo = await _repoMit({});
      expect(await repo.load(), isNull);
    });

    test('kaputte Daten blockieren den Start nicht', () async {
      final repo = await _repoMit({_prefsKey: '{kein gültiges JSON'});
      expect(await repo.load(), isNull);
    });

    test('fehlende Felder bekommen Standardwerte', () async {
      final repo = await _repoMit({_prefsKey: '{"projects": []}'});
      final data = await repo.load();

      expect(data, isNotNull);
      // Leere/fehlende Listen fallen auf die Standardvorgaben zurück.
      expect(data!.arten, defaultArten);
      expect(data.roles, defaultRollen);
      expect(data.online, isTrue);
      expect(data.adminSeeded, isFalse);
    });
  });

  group('Schreiben je Datensatz', () {
    late PrefsMasterDataRepository repo;
    late MasterData data;

    setUp(() async {
      repo = await _repoMit({_prefsKey: _alterDatenstand});
      data = (await repo.load())!;
    });

    test('ein geänderter Auftrag landet auf der Platte', () async {
      data.projects.single.name = 'Umbau Bahnhofstr.';
      await repo.saveProject(data.projects.single);

      final j = await _gespeichert();
      expect(j['projects'][0]['name'], 'Umbau Bahnhofstr.');
    });

    test('ein neuer Auftrag wird angehängt, nicht ersetzt', () async {
      final neu = Project(
          id: 'p2',
          name: 'Dachsanierung',
          type: 'Dach',
          address: '',
          status: 'active',
          hours: [],
          materials: [],
          tasks: []);
      await repo.saveProject(neu);

      final j = await _gespeichert();
      expect((j['projects'] as List), hasLength(2));
      expect(j['projects'][1]['name'], 'Dachsanierung');
    });

    test('gelöschter Auftrag verschwindet aus Bestand und Speicher', () async {
      await repo.deleteProject('p1');

      expect(data.projects, isEmpty);
      final j = await _gespeichert();
      expect((j['projects'] as List), isEmpty);
    });

    test('ein Benutzer lässt die übrigen Daten unangetastet', () async {
      await repo.saveUser(AppUser(
          id: 'u2', name: 'Max M.', role: 'Handwerker', pin: '3333', wage: 45));

      final j = await _gespeichert();
      expect((j['users'] as List), hasLength(2));
      // Der Auftrag darf davon nichts mitbekommen.
      expect(j['projects'][0]['name'], 'Neubau Müllerstr. 12');
    });

    test('Kategorien und Rechte gehen über saveSettings', () async {
      data.arten.add('Solaranlage');
      data.rolePerms['Handwerker'] = ['exportDocs'];
      await repo.saveSettings();

      final j = await _gespeichert();
      expect(j['arten'], contains('Solaranlage'));
      expect(j['rolePerms']['Handwerker'], ['exportDocs']);
    });
  });

  test('ein Speicher-Zyklus verändert die Daten nicht', () async {
    final repo = await _repoMit({_prefsKey: _alterDatenstand});
    final vorher = await repo.load();
    await repo.replaceAll(vorher!);

    final wieder = await repo.load();
    expect(jsonEncode(wieder!.toJson()), jsonEncode(vorher.toJson()));
  });
}
