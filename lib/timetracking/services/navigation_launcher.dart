// Öffnet die Karten-App des Geräts mit der Baustellenadresse.
//
// Anders als Geofencing funktioniert das auf *allen* Zielen – Android, iOS
// und auch in der Web-PWA. Deshalb liegt es bewusst nicht hinter einem
// Plattform-Gateway.
//
// Strategie je Plattform, jeweils mit Rückfallebene:
//  * Android: `google.navigation:` startet direkt die Zielführung. Fehlt
//    Google Maps, greift `geo:` und lässt den Nutzer eine App wählen.
//  * iOS: `maps://` öffnet Apple Karten. Da BauDoc auf dem iPhone als PWA
//    läuft, greift dort praktisch immer die Web-Variante darunter.
//  * Web/Desktop: die universelle Google-Maps-URL, die im Browser und auf
//    dem iPhone im Zweifel die Karten-App anbietet.

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

enum MapsApp { auto, google, apple }

class NavigationLauncher {
  const NavigationLauncher._();

  /// Startet die Zielführung zur [address].
  ///
  /// Liefert false, wenn keine Karten-App geöffnet werden konnte – der
  /// Aufrufer sollte dann eine Meldung zeigen statt still zu scheitern.
  static Future<bool> navigateTo(
    String address, {
    MapsApp prefer = MapsApp.auto,
    double? latitude,
    double? longitude,
  }) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty && latitude == null) return false;

    for (final uri in _candidates(trimmed, prefer, latitude, longitude)) {
      try {
        if (await canLaunchUrl(uri)) {
          final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
          if (ok) return true;
        }
      } catch (_) {
        // Nächsten Kandidaten versuchen.
      }
    }
    return false;
  }

  /// Kandidaten in absteigender Präferenz.
  static List<Uri> _candidates(
    String address,
    MapsApp prefer,
    double? lat,
    double? lng,
  ) {
    // Koordinaten sind eindeutiger als eine Adresszeile – wenn vorhanden,
    // bekommen sie den Vorzug, die Adresse dient nur als Beschriftung.
    final hasCoords = lat != null && lng != null;
    final q = Uri.encodeComponent(address);
    final coords = hasCoords ? '$lat,$lng' : '';
    final dest = hasCoords ? coords : q;

    final web = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$dest&travelmode=driving',
    );
    final appleWeb = Uri.parse('https://maps.apple.com/?daddr=$dest&dirflg=d');

    if (kIsWeb) {
      // In der PWA sind eigene URL-Schemata nicht zuverlässig; die iPhone-
      // Variante zuerst, weil Safari daraus Apple Karten anbietet.
      return prefer == MapsApp.apple ? [appleWeb, web] : [web];
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => [
          Uri.parse('google.navigation:q=$dest&mode=d'),
          Uri.parse('geo:${hasCoords ? coords : '0,0'}?q=$dest'),
          web,
        ],
      TargetPlatform.iOS => [
          Uri.parse('maps://?daddr=$dest&dirflg=d'),
          appleWeb,
          web,
        ],
      _ => [web],
    };
  }
}
