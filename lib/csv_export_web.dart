import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// Web: löst einen echten Browser-Download aus (Blob + <a download>).
Future<void> downloadCsv(String filename, String content) async {
  // UTF-8-BOM voranstellen, damit Excel Umlaute korrekt anzeigt.
  final bom = String.fromCharCode(0xFEFF);
  final bytes = Uint8List.fromList(utf8.encode('$bom$content'));
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'text/csv;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
