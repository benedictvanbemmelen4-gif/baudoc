// Stundenzettel als PDF.
//
// Gleiche Optik wie Rechnung und Angebot – die Bausteine kommen aus
// pdf_common.dart, damit Schrift, Tabellen und Sonderzeichenbehandlung in
// allen BauDoc-Dokumenten identisch bleiben.

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../main.dart' show dLong, today;
import '../pdf_common.dart';
import 'timesheet_data.dart';

/// Baut den Stundenzettel für den bereits gefilterten [data].
///
/// [worker] ist der Name des Mitarbeiters oder null für „alle“.
/// [includeWages] blendet die Geldspalten ein – die Entscheidung darüber
/// trifft der Aufrufer anhand der Rechte, nicht dieses Modul.
Future<Uint8List> buildTimesheetPdf(
  TimesheetData data, {
  required String rangeLabel,
  String? worker,
  bool includeWages = false,
  Map<String, double> wages = const {},
}) async {
  final doc = pw.Document();

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (ctx) => [
      _header(rangeLabel, worker, data),
      pw.SizedBox(height: 16),
      ..._dailySections(data, includeWages, wages),
      if (data.byProject.length > 1) ...[
        pw.SizedBox(height: 16),
        _projectSummary(data),
      ],
      if (worker == null && data.byWorker.length > 1) ...[
        pw.SizedBox(height: 16),
        _workerSummary(data, includeWages, wages),
      ],
      pw.SizedBox(height: 16),
      _totals(data, includeWages),
      if (data.undatedCount > 0) ...[
        pw.SizedBox(height: 12),
        pw.Text(
          '${data.undatedCount} Eintrag/Einträge ohne Datum konnten keinem '
          'Zeitraum zugeordnet werden und fehlen in dieser Aufstellung.',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
        ),
      ],
    ],
    footer: pdfFooter,
  ));

  return doc.save();
}

pw.Widget _header(String rangeLabel, String? worker, TimesheetData data) {
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
    pw.Text('Stundenzettel',
        style:
            const pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
    pw.SizedBox(height: 2),
    pw.Text(pdfText(rangeLabel), style: const pw.TextStyle(fontSize: 14)),
    pw.Divider(),
    row('Mitarbeiter:', worker == null ? 'Alle' : pdfText(worker)),
    row('Einträge:', '${data.rows.length}'),
    row('Arbeitstage:', '${data.dayCount}'),
    row('Erstellt:', dLong(today())),
  ]);
}

/// Je Tag eine kleine Tabelle – so liest sich der Zettel wie ein Kalender
/// und nicht wie ein Datenbankauszug.
List<pw.Widget> _dailySections(
  TimesheetData data,
  bool includeWages,
  Map<String, double> wages,
) {
  if (data.isEmpty) {
    return [
      pw.Text('Keine Einträge im gewählten Zeitraum.',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey)),
    ];
  }

  final headers = [
    'Auftrag',
    'Mitarbeiter',
    'Tätigkeit',
    'Std.',
    if (includeWages) 'Betrag',
  ];

  final out = <pw.Widget>[];
  for (final day in data.byDay.keys) {
    final rows = data.byDay[day]!;
    final dayHours = rows.fold<double>(0, (s, r) => s + r.entry.h);
    final dayWage = rows.fold<double>(
        0, (s, r) => s + r.entry.h * (wages[r.entry.worker] ?? 0));

    out.add(pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(height: 8),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(dLong(day),
                  style: const pw.TextStyle(
                      fontSize: 11, fontWeight: pw.FontWeight.bold)),
              pw.Text(
                includeWages
                    ? '${pdfHours(dayHours)} h · ${pdfEur(dayWage)}'
                    : '${pdfHours(dayHours)} h',
                style: const pw.TextStyle(
                    fontSize: 10, fontWeight: pw.FontWeight.bold),
              ),
            ],
          ),
          pw.SizedBox(height: 3),
          pdfTable(
            headers: headers,
            data: rows.map((r) {
              final wage = wages[r.entry.worker] ?? 0;
              return [
                pdfText(r.project.name),
                pdfText(r.entry.worker),
                pdfText(r.entry.task.isEmpty
                    ? (r.fromTracking ? 'automatisch erfasst' : '—')
                    : r.entry.task),
                pdfHours(r.entry.h),
                if (includeWages) pdfEur(r.entry.h * wage),
              ];
            }).toList(),
            rightAligned: includeWages ? const {3, 4} : const {3},
          ),
        ]));
  }
  return out;
}

pw.Widget _projectSummary(TimesheetData data) {
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pdfSectionTitle('Verteilung auf Aufträge'),
    pw.SizedBox(height: 4),
    pdfTable(
      headers: ['Auftrag', 'Std.', 'Anteil'],
      data: data.byProject.entries
          .map((e) => [
                pdfText(e.key),
                pdfHours(e.value),
                data.totalHours == 0
                    ? '—'
                    : '${(e.value / data.totalHours * 100).round()} %',
              ])
          .toList(),
      rightAligned: const {1, 2},
    ),
  ]);
}

pw.Widget _workerSummary(
  TimesheetData data,
  bool includeWages,
  Map<String, double> wages,
) {
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pdfSectionTitle('Verteilung auf Mitarbeiter'),
    pw.SizedBox(height: 4),
    pdfTable(
      headers: [
        'Mitarbeiter',
        'Std.',
        if (includeWages) '€/h',
        if (includeWages) 'Lohnkosten',
      ],
      data: data.byWorker.entries.map((e) {
        final wage = wages[e.key] ?? 0;
        return [
          pdfText(e.key),
          pdfHours(e.value),
          if (includeWages) pdfEur(wage),
          if (includeWages) pdfEur(e.value * wage),
        ];
      }).toList(),
      rightAligned: includeWages ? const {1, 2, 3} : const {1},
    ),
  ]);
}

pw.Widget _totals(TimesheetData data, bool includeWages) {
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
    pw.Divider(),
    pdfTotalLine('Arbeitstage:', '${data.dayCount}'),
    pdfTotalLine('Stunden gesamt:', '${pdfHours(data.totalHours)} h',
        bold: !includeWages),
    if (includeWages)
      pdfTotalLine('Lohnkosten:', pdfEur(data.totalWage), bold: true),
  ]);
}
