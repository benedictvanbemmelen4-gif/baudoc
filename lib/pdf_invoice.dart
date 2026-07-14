import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'main.dart' show Project, Customer, Pauschale, dLong, today;

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
// wages: Mitarbeitername → Stundenlohn (€/h); Lohn wird je Mitarbeiter
// automatisch berechnet. pauschalen: ausgewählte Aufschläge.
Future<Uint8List> buildProjectInvoicePdf(Project p,
    {Customer? customer,
    Map<String, double> wages = const {},
    List<Pauschale> pauschalen = const []}) async {
  final doc = pw.Document();
  final totalH = p.hours.fold<double>(0, (s, e) => s + e.h);
  double wageFor(String w) => wages[w] ?? 0;
  final lohn = p.hours.fold<double>(0, (s, e) => s + e.h * wageFor(e.worker));
  final matCost = p.materials.fold<double>(0, (s, e) => s + e.qty * e.price);
  final pausSum = pauschalen.fold<double>(0, (s, e) => s + e.amount);
  final gesamt = matCost + lohn + pausSum;
  final showLohn = lohn > 0;

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (ctx) => [
      _header(p, customer),
      pw.SizedBox(height: 16),
      _hoursSection(p, wageFor, totalH, lohn, showLohn),
      pw.SizedBox(height: 16),
      _materialSection(p, matCost),
      if (pauschalen.isNotEmpty) pw.SizedBox(height: 16),
      if (pauschalen.isNotEmpty) _pauschalenSection(pauschalen, pausSum),
      pw.SizedBox(height: 16),
      _totals(matCost, lohn, pausSum, gesamt, showLohn, pauschalen.isNotEmpty),
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

pw.Widget _header(Project p, Customer? customer) {
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
    if (customer != null) row('Kunde:', _s(customer.name)),
    if (customer != null && customer.address.isNotEmpty)
      row('Anschrift:', _s(customer.address)),
    if (customer != null && customer.contact.isNotEmpty)
      row('Kontakt:', _s(customer.contact)),
    if (p.type.isNotEmpty) row('Gewerk:', _s(p.type)),
    if (p.address.isNotEmpty) row('Adresse:', _s(p.address)),
    row('Status:', p.isOpen ? 'Aktiv' : 'Abgeschlossen'),
    if (p.date.isNotEmpty) row('Start:', dLong(p.date)),
    if (p.due.isNotEmpty) row('Fällig:', dLong(p.due)),
    row('Erstellt:', dLong(today())),
  ]);
}

pw.Widget _hoursSection(Project p, double Function(String) wageFor,
    double totalH, double lohn, bool showLohn) {
  final headers = showLohn
      ? ['Datum', 'Mitarbeiter', 'Tätigkeit', 'Std.', '€/h', 'Betrag']
      : ['Datum', 'Mitarbeiter', 'Tätigkeit', 'Std.'];
  final data = p.hours.map((h) {
    final r = [dLong(h.date), _s(h.worker), _s(h.task), _hours(h.h)];
    if (showLohn) {
      r.add(_eur(wageFor(h.worker)));
      r.add(_eur(h.h * wageFor(h.worker)));
    }
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
          5: pw.Alignment.centerRight,
        },
        border: pw.TableBorder.all(color: PdfColors.grey400, width: .5),
      ),
    pw.SizedBox(height: 4),
    pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text(
        showLohn
            ? 'Summe Stunden: ${_hours(totalH)} h · Lohn: ${_eur(lohn)}'
            : 'Summe Stunden: ${_hours(totalH)} h',
        style:
            const pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
      ),
    ),
  ]);
}

pw.Widget _pauschalenSection(List<Pauschale> items, double sum) {
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Text('Pauschalen',
        style:
            const pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
    pw.SizedBox(height: 4),
    pw.TableHelper.fromTextArray(
      headers: ['Bezeichnung', 'Betrag'],
      data: items.map((e) => [_s(e.name), _eur(e.amount)]).toList(),
      headerStyle:
          const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
      cellStyle: const pw.TextStyle(fontSize: 9),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
      cellAlignments: {1: pw.Alignment.centerRight},
      border: pw.TableBorder.all(color: PdfColors.grey400, width: .5),
    ),
    pw.SizedBox(height: 4),
    pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Summe Pauschalen: ${_eur(sum)}',
          style: const pw.TextStyle(
              fontSize: 10, fontWeight: pw.FontWeight.bold)),
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

pw.Widget _totals(double mat, double lohn, double paus, double gesamt,
    bool showLohn, bool showPaus) {
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
    if (showLohn) line('Lohn:', _eur(lohn)),
    line('Material:', _eur(mat)),
    if (showPaus) line('Pauschalen:', _eur(paus)),
    pw.SizedBox(height: 2),
    line('Gesamt:', _eur(gesamt), bold: true),
  ]);
}
