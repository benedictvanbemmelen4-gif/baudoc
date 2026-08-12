// Smoke-Test: App startet und zeigt den Login-Screen.
//
// Die Anmeldung wird durch eine Test-Umsetzung ersetzt – ohne sie griffe der
// Store nach `FirebaseAuth.instance`, und das verlangt ein gestartetes
// Firebase, das es im Test nicht gibt. Was die Anmeldung *tut*, prüft
// auth_test.dart.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baudoc/main.dart';

import 'fake_auth_repository.dart';

void main() {
  testWidgets('App startet und zeigt den Login', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    Store.I.auth = FakeAuthRepository();
    await Store.I.load();
    Store.I.watchAuth();

    await tester.pumpWidget(const BauDocApp());
    await tester.pumpAndSettle();

    // Der Login-Screen muss erscheinen (App rendert ohne Fehler).
    expect(find.byType(BauDocApp), findsOneWidget);
    expect(find.byType(LoginScreen), findsOneWidget);
  });
}
