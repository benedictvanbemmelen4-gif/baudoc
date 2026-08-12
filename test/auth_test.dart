// Absicherung der Anmeldung.
//
// Geprüft wird das Zusammenspiel von Konto und lokalem Benutzer: zu jedem
// angemeldeten Konto muss ein [AppUser] mit **derselben** Kennung existieren.
// Daran hängen Rechte, Stundenlohn und die Zuordnung erfasster Zeiten – geht
// das auseinander, ist der Monteur angemeldet und sieht trotzdem nichts.

import 'package:baudoc/auth/auth_repository.dart';
import 'package:baudoc/data/firestore_master_data_repository.dart';
import 'package:baudoc/main.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_auth_repository.dart';

/// Frischer Store mit eingesetzter Test-Anmeldung.
///
/// [Store] ist ein Einzelstück; die Tests laufen deshalb nacheinander auf
/// derselben Instanz. `watchAuth()` hört bei jedem Aufruf neu hin, dadurch
/// beginnt jeder Test wieder beim gemeldeten Zustand des neuen Fakes.
///
/// [warten] steuert, wer die Meldung des Anmeldezustands abholt. In `test()`
/// tut das ein kurzes Warten. In `testWidgets()` darf hier **nicht** gewartet
/// werden: dort läuft eine künstliche Uhr, die sich erst mit `pump()` bewegt –
/// ein `Future.delayed` würde nie zurückkommen, und der Test hinge fest.
Future<FakeAuthRepository> _neuerStore({bool warten = true}) async {
  SharedPreferences.setMockInitialValues({});
  final fake = FakeAuthRepository();
  Store.I.auth = fake;
  await Store.I.load();
  Store.I.watchAuth();
  if (warten) await Future<void>.delayed(Duration.zero);
  return fake;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Anmeldezustand', () {
    test('ohne Anmeldung ist niemand angemeldet, der Zustand steht aber fest',
        () async {
      await _neuerStore();
      expect(Store.I.authReady, isTrue,
          reason: 'sonst hängt die App im Ladezustand fest');
      expect(Store.I.sessionId, isNull);
      expect(Store.I.currentUser, isNull);
    });

    test('nach dem Anmelden entsteht ein lokaler Benutzer mit der Konto-Kennung',
        () async {
      final fake = await _neuerStore();
      fake.hinterlege(
          email: 'chef@betrieb.de',
          password: 'geheim1',
          name: 'Anna Bauer',
          role: 'Administrator');

      await fake.signIn(email: 'chef@betrieb.de', password: 'geheim1');
      await Future<void>.delayed(Duration.zero);

      final me = Store.I.currentUser;
      expect(me, isNotNull);
      expect(me!.id, Store.I.sessionId);
      expect(me.name, 'Anna Bauer');
      expect(me.email, 'chef@betrieb.de');
      expect(me.role, 'Administrator');
      expect(me.hasAccount, isTrue);
      // Der Administrator muss alles dürfen, sonst ist die Verwaltung zu.
      expect(Store.I.can('wages'), isTrue);
    });

    test('ohne Anzeigenamen dient der Teil vor dem @ als Name', () async {
      final fake = await _neuerStore();
      fake.hinterlege(
          email: 'max.mustermann@betrieb.de',
          password: 'geheim1',
          role: 'Handwerker');

      await fake.signIn(
          email: 'max.mustermann@betrieb.de', password: 'geheim1');
      await Future<void>.delayed(Duration.zero);

      expect(Store.I.currentUser!.name, 'max.mustermann');
    });

    test('eine unbekannte Rolle wird übernommen und bekommt Rechte', () async {
      final fake = await _neuerStore();
      fake.hinterlege(
          email: 'polier@betrieb.de', password: 'geheim1', role: 'Polier');

      await fake.signIn(email: 'polier@betrieb.de', password: 'geheim1');
      await Future<void>.delayed(Duration.zero);

      expect(Store.I.roles, contains('Polier'));
      expect(Store.I.rolePerms.containsKey('Polier'), isTrue);
    });

    test('Konto ohne Rolle führt in den Hinweis statt in eine leere App',
        () async {
      final fake = await _neuerStore();
      fake.hinterlege(email: 'neu@betrieb.de', password: 'geheim1');

      await fake.signIn(email: 'neu@betrieb.de', password: 'geheim1');
      await Future<void>.delayed(Duration.zero);

      expect(Store.I.awaitingRole, isTrue);
      expect(Store.I.can('wages'), isFalse);
    });

    test('falsches Passwort meldet einen Fehler und meldet niemanden an',
        () async {
      final fake = await _neuerStore();
      fake.hinterlege(
          email: 'chef@betrieb.de', password: 'geheim1', role: 'Administrator');

      await expectLater(
        fake.signIn(email: 'chef@betrieb.de', password: 'falsch'),
        throwsA(isA<AuthFailure>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(Store.I.sessionId, isNull);
    });

    test('Abmelden räumt die Sitzung, der Benutzer bleibt im Bestand',
        () async {
      final fake = await _neuerStore();
      fake.hinterlege(
          email: 'chef@betrieb.de', password: 'geheim1', role: 'Administrator');
      await fake.signIn(email: 'chef@betrieb.de', password: 'geheim1');
      await Future<void>.delayed(Duration.zero);
      final anzahl = Store.I.users.length;

      await Store.I.logout();
      await Future<void>.delayed(Duration.zero);

      expect(Store.I.sessionId, isNull);
      expect(Store.I.currentUser, isNull);
      // Der Datensatz bleibt: an ihm hängen Stundenlohn und erfasste Zeiten.
      expect(Store.I.users.length, anzahl);
    });

    test(
        'ein zweites Anmelden desselben Kontos legt keinen zweiten Benutzer an',
        () async {
      final fake = await _neuerStore();
      fake.hinterlege(
          email: 'chef@betrieb.de', password: 'geheim1', role: 'Administrator');

      await fake.signIn(email: 'chef@betrieb.de', password: 'geheim1');
      await Future<void>.delayed(Duration.zero);
      final anzahl = Store.I.users.length;

      await Store.I.logout();
      await Future<void>.delayed(Duration.zero);
      await fake.signIn(email: 'chef@betrieb.de', password: 'geheim1');
      await Future<void>.delayed(Duration.zero);

      expect(Store.I.users.length, anzahl);
    });

    test('ein neues Konto überlebt den Bestand aus der Datenbank', () async {
      // Der Fall eines neuen Mitarbeiters am ersten Tag: die Datenbank ist
      // längst befüllt, sein Konto steht dort aber noch nicht. Beim Verbinden
      // wird der gesamte Bestand durch den der Datenbank ersetzt – wird er
      // dabei nicht erneut eingetragen, ist er angemeldet und die App fällt
      // trotzdem auf den Anmeldebildschirm zurück.
      final db = FakeFirebaseFirestore();
      await db.collection('settings').doc('migration').set({'done': true});
      await db
          .collection('users')
          .doc('uid_kollege')
          .set({'name': 'Max M.', 'role': 'Handwerker', 'email': 'max@b.de'});

      final fake = await _neuerStore();
      Store.I.backendBuilder =
          () => FirestoreMasterDataRepository(firestore: db);
      addTearDown(
          () => Store.I.backendBuilder = FirestoreMasterDataRepository.new);

      fake.hinterlege(
          email: 'neu@betrieb.de',
          password: 'geheim1',
          name: 'Neu Mitarbeiter',
          role: 'Handwerker');
      await fake.signIn(email: 'neu@betrieb.de', password: 'geheim1');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(Store.I.backendAktiv, isTrue);
      expect(Store.I.currentUser, isNotNull,
          reason: 'sonst landet der Angemeldete wieder auf dem Login');
      expect(Store.I.currentUser!.name, 'Neu Mitarbeiter');
      // Der Kollege aus der Datenbank ist dabei nicht verloren gegangen.
      expect(Store.I.users.map((u) => u.id), contains('uid_kollege'));
      // Und das Konto steht jetzt auch in der gemeinsamen Ablage.
      final drin = await db.collection('users').get();
      expect(drin.docs.map((d) => d.data()['email']),
          contains('neu@betrieb.de'));
    });
  });

  group('Bildschirmwahl', () {
    testWidgets('ohne Anmeldung erscheint der Anmeldebildschirm',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _neuerStore(warten: false);
      await tester.pumpWidget(const BauDocApp());
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Anmelden'), findsOneWidget);
      // Der Weg zum ersten Konto muss auffindbar sein.
      expect(find.text('Ersteinrichtung'), findsOneWidget);
    });

    testWidgets('nach dem Anmelden erscheint die Auftragsliste',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fake = await _neuerStore(warten: false);
      fake.hinterlege(
          email: 'chef@betrieb.de',
          password: 'geheim1',
          name: 'Anna Bauer',
          role: 'Administrator');

      await tester.pumpWidget(const BauDocApp());
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);

      await fake.signIn(email: 'chef@betrieb.de', password: 'geheim1');
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });
}
