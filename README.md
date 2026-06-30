# BauDoc – Flutter/Dart-Version

Portierung des HTML-Prototyps (`BauDoc-App.html`) nach **Flutter/Dart**, damit die App
später für **Android, iOS, Web und Desktop** gebaut und in den Stores veröffentlicht werden kann.

## Was drin ist (v1)
- **Login** mit Benutzer + 4-stelligem PIN (lokal)
- **Rollen** `Baustelle` / `Büro/Buchhaltung` – die Verwaltung sehen nur „Büro/Buchhaltung"
- **Aufträge** mit Reitern **Offen / Abgeschlossen**, **Filter** nach Art/Gewerk und **Gruppierung** nach Gewerk
- **Auftrag-Detail**: Statistik + **Arbeitsstunden**, **Material** (mit Preisliste), **Aufgaben** (abhaken)
- **Profil** (Avatar mit Initialen, PIN ändern, Abmelden)
- **Verwaltung**: Material-Preise und Benutzer anlegen/bearbeiten/löschen
- **Lokale Speicherung** über `shared_preferences` (JSON)

## Noch nicht portiert / TODO
- **Fotos** an Aufgaben (braucht `image_picker` + Plattform-Setup) – als Nächstes
- **Sync/Online-Offline** ist im Modell vorhanden, aber UI-seitig vereinfacht
- **Echtes Backend** (Server-Login, Daten-Sync zwischen Geräten) – nötig für „richtige" Veröffentlichung

## Einrichten & Starten
1. **Flutter SDK installieren:** https://docs.flutter.dev/get-started/install/windows
   - Danach `flutter doctor` ausführen und offene Punkte abarbeiten (Android Studio / Geräte-Treiber).
2. In diesem Ordner:
   ```
   flutter pub get
   flutter run            # auf angeschlossenem Gerät/Emulator
   flutter run -d chrome  # schnell im Browser testen
   ```
3. Erste Anmeldung (Demo):
   - **Bauleiter** · PIN **1111** (Rolle Baustelle)
   - **Büro** · PIN **2222** (Rolle Büro/Buchhaltung → sieht die Verwaltung)

## Bauen für die Veröffentlichung
- Android: `flutter build appbundle` → `.aab` in den **Google Play Console** hochladen (einmalig ~25 $).
- iOS: `flutter build ipa` (benötigt Mac + Xcode + Apple Developer Account ~99 $/Jahr).
- Web: `flutter build web` → statisch hosten.

## Projektstruktur
- `pubspec.yaml` – Abhängigkeiten
- `lib/main.dart` – komplette App (Modelle, Store, UI). Später sinnvoll in mehrere Dateien aufteilen
  (`models/`, `store.dart`, `screens/`).
