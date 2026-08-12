// Auswahl der Plattform-Umsetzungen.
//
// Gleiches Muster wie beim CSV-Export (lib/csv_export_web.dart /
// lib/csv_export_io.dart): der bedingte Export sorgt dafür, dass die
// Android-Plugins beim Bauen der Web-Fassung gar nicht erst mitkompiliert
// werden.

export 'tracking_gateways_stub.dart'
    if (dart.library.io) 'tracking_gateways_io.dart';
