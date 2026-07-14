import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'main.dart' show Project, dLong, today;

// Zahl mit Dezimalkomma (deutsche Schreibweise).
String _n(num v) => v.toStringAsFixed(2).replaceAll('.', ',');
// Die eingebauten PDF-Standardfonts können das €-Glyph (U+20AC) nicht zeichnen;
// "EUR" ist auf deutschen Rechnungen ohnehin üblich und bleibt lesbar.
String _eur(num v) => '${_n(v)} EUR';
// Stunden ohne unnötige Nachkommastellen.
String _hours(double h) => h % 1 == 0 ? h.toStringAsFixed(0) : _n(h);

// Nutzertext auf Latin-1 abbilden: die Standardfonts decken WinAnsi ab
// (inkl. Umlaute/ß), aber keine typografischen Sonderzeichen. Häufige davon
// ersetzen, alles andere außerhalb Latin-1 als '?' – so bleiben keine
// stillen Lücken im PDF.
String _s(String t) {
  const map = {
    '–': '-', '—': '-', '‑': '-',
    '„': '"', '“': '"', '”': '"', '‟': '"',
    '‘': "'", '’': "'", '‚': "'",
    '…': '...', '€': 'EUR', ' ': ' ',
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

// Erzeugt einen Leistungsnachweis/Rechnung als PDF für einen Auftrag.
// stundensatz > 0 → Lohnspalte + Lohnsumme werden ausgewiesen.
Future<Uint8List> buildProjectInvoicePdf(Project p,
    {double stundensatz = 0}) async {
  final doc = pw.Document();
  final totalH = p.hours.fold<double>(0, (s, e) => s + e.h);
  final matCost = p.materials.fold<double>(0, (s, e) => s + e.qty * e.price);
  final lohn = stundensatz > 0 ? totalH * stundensatz : 0.0;
  final gesamt = matCost + lohn;

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (ctx) => [
      _header(p),
      pw.SizedBox(height: 16),
      _hoursSection(p, stundensatz, totalH),
      pw.SizedBox(height: 16),
      _materialSection(p, matCost),
      pw.SizedBox(height: 16),
      _totals(matCost, lohn, gesamt, stundensatz),
    ],
    footer: (ctx) => pw.Container(
      alignment: pw.Alignment.centerRight,
      margin: const pw.EdgeInsets.only(top: 12),
      child: pw.Text(
        'erstellt mit BauDoc · Seite ${ctx.pageNumber}/${ctx.pagesCount}',
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey),
      ),
    ),
  ));
  return doc.save();
}

pw.Widget _header(Project p) {
  pw.Widget row(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 2),
        child: pw.Row(children: [
          pw.SizedBox(
            width: 90,
            child: pw.Text(k,
                style: const pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 10)),
          ),
          pw.Expanded(
              child: pw.Text(v, style: const pw.TextStyle(fontSize: 10))),
        ]),
      );
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Text('Leistungsnachweis / Rechnung',
        style:
            const pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
    pw.SizedBox(height: 2),
    pw.Text(_s(p.name), style: const pw.TextStyle(fontSize: 14)),
    pw.Divider(),
    if (p.type.isNotEmpty) row('Gewerk:', _s(p.type)),
    if (p.address.isNotEmpty) row('Adresse:', _s(p.address)),
    row('Status:', p.isOpen ? 'Aktiv' : 'Abgeschlossen'),
    if (p.date.isNotEmpty) row('Start:', dLong(p.date)),
    if (p.due.isNotEmpty) row('Fällig:', dLong(p.due)),
    row('Erstellt:', dLong(today())),
  ]);
}

pw.Widget _hoursSection(Project p, double satz, double totalH) {
  final headers = satz > 0
      ? ['Datum', 'Mitarbeiter', 'Tätigkeit', 'Std.', 'Betrag']
      : ['Datum', 'Mitarbeiter', 'Tätigkeit', 'Std.'];
  final data = p.hours.map((h) {
    final r = [dLong(h.date), _s(h.worker), _s(h.task), _hours(h.h)];
    if (satz > 0) r.add(_eur(h.h * satz));
    return r;
  }).toList();
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Text('Arbeitsstunden',
        style:
            const pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
    pw.SizedBox(height: 4),
    if (p.hours.isEmpty)
      pw.Text('Keine Einträge.',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey))
    else
      pw.TableHelper.fromTextArray(
        headers: headers,
        data: data,
        headerStyle:
            const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
        cellStyle: const pw.TextStyle(fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
        cellAlignments: {
          3: pw.Alignment.centerRight,
          4: pw.Alignment.centerRight,
        },
        border: pw.TableBorder.all(color: PdfColors.grey400, width: .5),
      ),
    pw.SizedBox(height: 4),
    pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text(
        satz > 0
            ? 'Summe Stunden: ${_hours(totalH)} h · Lohn: ${_eur(totalH * satz)}'
            : 'Summe Stunden: ${_hours(totalH)} h',
        style:
            const pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
      ),
    ),
  ]);
}

pw.Widget _materialSection(Project p, double matCost) {
  final data = p.materials
      .map((m) => [
            _s(m.name),
            _n(m.qty),
            _s(m.unit),
            _eur(m.price),
            _eur(m.qty * m.price),
          ])
      .toList();
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Text('Material',
        style:
            const pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
    pw.SizedBox(height: 4),
    if (p.materials.isEmpty)
      pw.Text('Keine Einträge.',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey))
    else
      pw.TableHelper.fromTextArray(
        headers: ['Bezeichnung', 'Menge', 'Einheit', 'Einzelpreis', 'Gesamt'],
        data: data,
        headerStyle:
            const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
        cellStyle: const pw.TextStyle(fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
        cellAlignments: {
          1: pw.Alignment.centerRight,
          3: pw.Alignment.centerRight,
          4: pw.Alignment.centerRight,
        },
        border: pw.TableBorder.all(color: PdfColors.grey400, width: .5),
      ),
    pw.SizedBox(height: 4),
    pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Summe Material: ${_eur(matCost)}',
          style: const pw.TextStyle(
              fontSize: 10, fontWeight: pw.FontWeight.bold)),
    ),
  ]);
}

pw.Widget _totals(double mat, double lohn, double gesamt, double satz) {
  pw.Widget line(String k, String v, {bool bold = false}) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.end,
        children: [
          pw.Text('$k  ',
              style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight:
                      bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          pw.SizedBox(
            width: 100,
            child: pw.Text(v,
                textAlign: pw.TextAlign.right,
                style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight:
                        bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          ),
        ],
      );
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
    pw.Divider(),
    if (satz > 0) line('Lohn:', _eur(lohn)),
    line('Material:', _eur(mat)),
    pw.SizedBox(height: 2),
    line('Gesamt:', _eur(gesamt), bold: true),
  ]);
}
