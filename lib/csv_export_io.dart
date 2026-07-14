import 'dart:convert';
import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

// Mobil/Desktop: CSV als Datei über den System-Teilen-Dialog ausgeben.
Future<void> downloadCsv(String filename, String content) async {
  final bom = String.fromCharCode(0xFEFF);
  final bytes = Uint8List.fromList(utf8.encode('$bom$content'));
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(bytes, mimeType: 'text/csv', name: filename)],
      fileNameOverrides: [filename],
      subject: filename,
    ),
  );
}

// Mobil/Desktop: beliebige Binärdaten (z.B. PDF) über den Teilen-Dialog ausgeben.
Future<void> downloadBytes(
    String filename, Uint8List bytes, String mimeType) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(bytes, mimeType: mimeType, name: filename)],
      fileNameOverrides: [filename],
      subject: filename,
    ),
  );
}
