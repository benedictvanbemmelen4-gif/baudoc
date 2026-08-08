import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'main.dart' show Project, Customer, Pauschale, dLong, today;
import 'pdf_common.dart';

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
    footer: pdfFooter,
  ));
  return doc.save();
}

// Erzeugt ein Angebot / Kostenvoranschlag als PDF für einen Auftrag.
// estHours × hourlyRate = geschätzte Arbeit; vatRate in Prozent (0 = ohne MwSt).
Future<Uint8List> buildProjectQuotePdf(Project p,
    {Customer? customer,
    double estHours = 0,
    double hourlyRate = 0,
    List<Pauschale> pauschalen = const [],
    double vatRate = 19,
    String? validUntil}) async {
  final doc = pw.Document();
  final matCost = p.materials.fold<double>(0, (s, e) => s + e.qty * e.price);
  final showLabor = estHours > 0 && hourlyRate > 0;
  final labor = showLabor ? estHours * hourlyRate : 0.0;
  final pausSum = pauschalen.fold<double>(0, (s, e) => s + e.amount);

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (ctx) => [
      _header(p, customer, title: 'Angebot / Kostenvoranschlag'),
      pw.SizedBox(height: 16),
      _materialSection(p, matCost),
      if (showLabor) pw.SizedBox(height: 16),
      if (showLabor) _estimateSection(estHours, hourlyRate, labor),
      if (pauschalen.isNotEmpty) pw.SizedBox(height: 16),
      if (pauschalen.isNotEmpty) _pauschalenSection(pauschalen, pausSum),
      pw.SizedBox(height: 16),
      _quoteTotals(matCost, labor, pausSum, vatRate),
      pw.SizedBox(height: 16),
      pw.Text(
        'Angebot freibleibend.${validUntil != null && validUntil.isNotEmpty ? ' Gültig bis: ${dLong(validUntil)}' : ''}',
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
      ),
    ],
    footer: pdfFooter,
  ));
  return doc.save();
}

pw.Widget _estimateSection(double estHours, double hourlyRate, double labor) {
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pdfSectionTitle('Geschätzte Arbeit'),
    pw.SizedBox(height: 4),
    pdfTable(
      headers: ['Position', 'Std.', '€/h', 'Betrag'],
      data: [
        [
          'Arbeitsleistung (geschätzt)',
          pdfHours(estHours),
          pdfEur(hourlyRate),
          pdfEur(labor)
        ],
      ],
      rightAligned: const {1, 2, 3},
    ),
  ]);
}

pw.Widget _quoteTotals(double mat, double labor, double paus, double vatRate) {
  final netto = mat + labor + paus;
  final mwst = netto * vatRate / 100;
  final brutto = netto + mwst;
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
    pw.Divider(),
    if (labor > 0) pdfTotalLine('Arbeit (gesch.):', pdfEur(labor)),
    pdfTotalLine('Material:', pdfEur(mat)),
    if (paus > 0) pdfTotalLine('Pauschalen:', pdfEur(paus)),
    if (vatRate > 0) ...[
      pw.SizedBox(height: 2),
      pdfTotalLine('Netto:', pdfEur(netto)),
      pdfTotalLine('MwSt (${pdfHours(vatRate)} %):', pdfEur(mwst)),
      pw.SizedBox(height: 2),
      pdfTotalLine('Brutto:', pdfEur(brutto), bold: true),
    ] else ...[
      pw.SizedBox(height: 2),
      pdfTotalLine('Gesamt:', pdfEur(netto), bold: true),
    ],
  ]);
}

pw.Widget _header(Project p, Customer? customer,
    {String title = 'Leistungsnachweis / Rechnung'}) {
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
    pw.Text(title,
        style:
            const pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
    pw.SizedBox(height: 2),
    pw.Text(pdfText(p.name), style: const pw.TextStyle(fontSize: 14)),
    pw.Divider(),
    if (customer != null) row('Kunde:', pdfText(customer.name)),
    if (customer != null && customer.address.isNotEmpty)
      row('Anschrift:', pdfText(customer.address)),
    if (customer != null && customer.contact.isNotEmpty)
      row('Kontakt:', pdfText(customer.contact)),
    if (p.type.isNotEmpty) row('Gewerk:', pdfText(p.type)),
    if (p.address.isNotEmpty) row('Adresse:', pdfText(p.address)),
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
    final r = [dLong(h.date), pdfText(h.worker), pdfText(h.task), pdfHours(h.h)];
    if (showLohn) {
      r.add(pdfEur(wageFor(h.worker)));
      r.add(pdfEur(h.h * wageFor(h.worker)));
    }
    return r;
  }).toList();
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pdfSectionTitle('Arbeitsstunden'),
    pw.SizedBox(height: 4),
    if (p.hours.isEmpty)
      pw.Text('Keine Einträge.',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey))
    else
      pdfTable(
        headers: headers,
        data: data,
        rightAligned: const {3, 4, 5},
      ),
    pw.SizedBox(height: 4),
    pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text(
        showLohn
            ? 'Summe Stunden: ${pdfHours(totalH)} h · Lohn: ${pdfEur(lohn)}'
            : 'Summe Stunden: ${pdfHours(totalH)} h',
        style:
            const pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
      ),
    ),
  ]);
}

pw.Widget _pauschalenSection(List<Pauschale> items, double sum) {
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pdfSectionTitle('Pauschalen'),
    pw.SizedBox(height: 4),
    pdfTable(
      headers: ['Bezeichnung', 'Betrag'],
      data: items.map((e) => [pdfText(e.name), pdfEur(e.amount)]).toList(),
      rightAligned: const {1},
    ),
    pw.SizedBox(height: 4),
    pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Summe Pauschalen: ${pdfEur(sum)}',
          style: const pw.TextStyle(
              fontSize: 10, fontWeight: pw.FontWeight.bold)),
    ),
  ]);
}

pw.Widget _materialSection(Project p, double matCost) {
  final data = p.materials
      .map((m) => [
            pdfText(m.name),
            pdfNum(m.qty),
            pdfText(m.unit),
            pdfEur(m.price),
            pdfEur(m.qty * m.price),
          ])
      .toList();
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pdfSectionTitle('Material'),
    pw.SizedBox(height: 4),
    if (p.materials.isEmpty)
      pw.Text('Keine Einträge.',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey))
    else
      pdfTable(
        headers: ['Bezeichnung', 'Menge', 'Einheit', 'Einzelpreis', 'Gesamt'],
        data: data,
        rightAligned: const {1, 3, 4},
      ),
    pw.SizedBox(height: 4),
    pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Summe Material: ${pdfEur(matCost)}',
          style: const pw.TextStyle(
              fontSize: 10, fontWeight: pw.FontWeight.bold)),
    ),
  ]);
}

pw.Widget _totals(double mat, double lohn, double paus, double gesamt,
    bool showLohn, bool showPaus) {
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
    pw.Divider(),
    if (showLohn) pdfTotalLine('Lohn:', pdfEur(lohn)),
    pdfTotalLine('Material:', pdfEur(mat)),
    if (showPaus) pdfTotalLine('Pauschalen:', pdfEur(paus)),
    pw.SizedBox(height: 2),
    pdfTotalLine('Gesamt:', pdfEur(gesamt), bold: true),
  ]);
}
