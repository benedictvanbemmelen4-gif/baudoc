// Gemeinsame Bausteine aller BauDoc-PDFs.
//
// Rechnung/Angebot (pdf_invoice.dart) und Stundenzettel
// (timesheet/timesheet_pdf.dart) müssen gleich aussehen und – wichtiger –
// Sonderzeichen identisch behandeln. Deshalb liegen die Helfer hier statt
// doppelt in beiden Dateien.

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Zahl mit Dezimalkomma (deutsche Schreibweise).
String pdfNum(num v) => v.toStringAsFixed(2).replaceAll('.', ',');

/// Die eingebauten PDF-Standardfonts können das €-Glyph (U+20AC) nicht
/// zeichnen; "EUR" ist auf deutschen Rechnungen ohnehin üblich und bleibt
/// lesbar.
String pdfEur(num v) => '${pdfNum(v)} EUR';

/// Stunden ohne unnötige Nachkommastellen.
String pdfHours(double h) => h % 1 == 0 ? h.toStringAsFixed(0) : pdfNum(h);

/// Nutzertext auf Latin-1 abbilden: die Standardfonts decken WinAnsi ab
/// (inkl. Umlaute/ß), aber keine typografischen Sonderzeichen. Häufige davon
/// ersetzen, alles andere außerhalb Latin-1 als '?' – so bleiben keine
/// stillen Lücken im PDF.
///
/// Die Zeichen stehen bewusst als Escape-Sequenzen: gerade Anführungszeichen
/// und Bindestriche sind im Quelltext optisch kaum auseinanderzuhalten.
String pdfText(String t) {
  const map = {
    '–': '-', // – Halbgeviertstrich
    '—': '-', // — Geviertstrich
    '‑': '-', // ‑ geschützter Bindestrich
    '„': '"', // „
    '“': '"', // "
    '”': '"', // "
    '‟': '"', // ‟
    '‘': "'", // '
    '’': "'", // '
    '‚': "'", // ‚
    '…': '...', // …
    '€': 'EUR', // €
    ' ': ' ', // geschütztes Leerzeichen
  };
  final b = StringBuffer();
  for (final r in t.runes) {
    final ch = String.fromCharCode(r);
    if (map.containsKey(ch)) {
      b.write(map[ch]);
    } else if (r <= 0xFF) {
      b.write(ch);
    } else {
      b.write('?');
    }
  }
  return b.toString();
}

/// Einheitlich gestaltete Tabelle. [rightAligned] enthält die Spalten-Indizes,
/// die rechtsbündig stehen sollen (Zahlen und Beträge).
pw.Widget pdfTable({
  required List<String> headers,
  required List<List<String>> data,
  Set<int> rightAligned = const {},
}) =>
    pw.TableHelper.fromTextArray(
      headers: headers,
      data: data,
      headerStyle:
          const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
      cellStyle: const pw.TextStyle(fontSize: 9),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
      cellAlignments: {
        for (final i in rightAligned) i: pw.Alignment.centerRight,
      },
      border: pw.TableBorder.all(color: PdfColors.grey400, width: .5),
    );

/// Abschnittsüberschrift.
pw.Widget pdfSectionTitle(String title) => pw.Text(
      title,
      style: const pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
    );

/// Rechtsbündige Zeile eines Summenblocks.
pw.Widget pdfTotalLine(String label, String value, {bool bold = false}) {
  final style = pw.TextStyle(
    fontSize: 11,
    fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
  );
  return pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.end,
    children: [
      pw.Text('$label  ', style: style),
      pw.SizedBox(
        width: 100,
        child: pw.Text(value, textAlign: pw.TextAlign.right, style: style),
      ),
    ],
  );
}

/// Fußzeile mit Seitenzählung – in allen Dokumenten gleich.
pw.Widget pdfFooter(pw.Context ctx) => pw.Container(
      alignment: pw.Alignment.centerRight,
      margin: const pw.EdgeInsets.only(top: 12),
      child: pw.Text(
        'erstellt mit BauDoc · Seite ${ctx.pageNumber}/${ctx.pagesCount}',
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey),
      ),
    );
