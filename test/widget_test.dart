// Smoke-Test: App startet und zeigt den Login-Screen.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baudoc/main.dart';

void main() {
  testWidgets('App startet und zeigt den Login', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    await Store.I.load();

    await tester.pumpWidget(const BauDocApp());
    await tester.pumpAndSettle();

    // Der Login-Screen muss erscheinen (App rendert ohne Fehler).
    expect(find.byType(BauDocApp), findsOneWidget);
  });
}
