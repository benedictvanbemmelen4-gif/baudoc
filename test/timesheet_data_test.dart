// Tests der Stunden-Auswertung.
//
// Hier liegt die Rechnerei, aus der am Monatsende Lohn wird – entsprechend
// gründlich geprüft: Zeitraumgrenzen (inklusive Monats- und Jahreswechsel),
// Rechte-abhängige Geldspalten, und der Umgang mit kaputten Daten.

import 'package:flutter_test/flutter_test.dart';

import 'package:baudoc/main.dart' show Project, WorkHours;
import 'package:baudoc/timesheet/timesheet_data.dart';

// ---------------------------------------------------------------------------
// Hilfen
// ---------------------------------------------------------------------------

int _seq = 0;

WorkHours h(String date, String worker, double hours,
        {String task = '', String? id}) =>
    WorkHours(
      id: id ?? 'manual_${_seq++}',
      worker: worker,
      date: date,
      task: task,
      h: hours,
      synced: true,
    );

Project project(String name, List<WorkHours> hours, {String type = 'Rohbau'}) =>
    Project(
      id: 'p_${name.hashCode}',
      name: name,
      type: type,
      address: '',
      status: 'active',
      hours: hours,
      materials: [],
      tasks: [],
    );

void main() {
  // Mittwoch, 12. August 2026.
  final mittwoch = DateTime(2026, 8, 12);

  group('Zeitraumgrenzen', () {
    test('Diese Woche läuft von Montag bis Sonntag', () {
      final (from, to) = TimesheetPeriod.thisWeek.range(mittwoch);
      expect(from, '2026-08-10'); // Montag
      expect(to, '2026-08-16'); // Sonntag
    });

    test('Sonntag gehört noch zur laufenden Woche', () {
      final sonntag = DateTime(2026, 8, 16);
      final (from, to) = TimesheetPeriod.thisWeek.range(sonntag);
      expect(from, '2026-08-10');
      expect(to, '2026-08-16');
    });

    test('Letzte Woche schließt lückenlos an, ohne Überlappung', () {
      final (lastFrom, lastTo) = TimesheetPeriod.lastWeek.range(mittwoch);
      final (thisFrom, _) = TimesheetPeriod.thisWeek.range(mittwoch);
      expect(lastFrom, '2026-08-03');
      expect(lastTo, '2026-08-09');
      expect(lastTo.compareTo(thisFrom), lessThan(0));
    });

    test('Monat endet auf dem richtigen letzten Tag', () {
      final (from, to) = TimesheetPeriod.thisMonth.range(mittwoch);
      expect(from, '2026-08-01');
      expect(to, '2026-08-31');
    });

    test('Februar im Schaltjahr hat 29 Tage', () {
      final (_, to) = TimesheetPeriod.thisMonth.range(DateTime(2028, 2, 10));
      expect(to, '2028-02-29');
    });

    test('Letzter Monat über den Jahreswechsel', () {
      final (from, to) = TimesheetPeriod.lastMonth.range(DateTime(2026, 1, 15));
      expect(from, '2025-12-01');
      expect(to, '2025-12-31');
    });

    test('Woche über den Monatswechsel', () {
      // Dienstag, 1. September 2026 → Woche beginnt am 31. August.
      final (from, to) = TimesheetPeriod.thisWeek.range(DateTime(2026, 9, 1));
      expect(from, '2026-08-31');
      expect(to, '2026-09-06');
    });
  });

  group('Filter', () {
    final projects = [
      project('Neubau Nord', [
        h('2026-08-10', 'Anna', 8),
        h('2026-08-11', 'Bert', 6),
        h('2026-08-03', 'Anna', 4), // letzte Woche
      ]),
      project('Sanierung Süd', [
        h('2026-08-12', 'Anna', 2.5),
      ]),
    ];

    test('Zeitraum grenzt korrekt ein', () {
      final d = collectTimesheet(
          projects, TimesheetFilter(), now: mittwoch);
      expect(d.rows, hasLength(3), reason: 'der 03.08. liegt davor');
      expect(d.totalHours, 16.5);
    });

    test('Mitarbeiter und Zeitraum greifen gleichzeitig', () {
      final d = collectTimesheet(
          projects, TimesheetFilter(worker: 'Anna'), now: mittwoch);
      expect(d.rows, hasLength(2));
      expect(d.totalHours, 10.5);
      expect(d.byWorker.keys, ['Anna']);
    });

    test('freier Zeitraum überschreibt die Vorgabe', () {
      final d = collectTimesheet(
        projects,
        TimesheetFilter(
            period: TimesheetPeriod.custom,
            from: '2026-08-01',
            to: '2026-08-31'),
        now: mittwoch,
      );
      expect(d.rows, hasLength(4), reason: 'jetzt ist der 03.08. dabei');
      expect(d.totalHours, 20.5);
    });

    test('offene Grenzen sind unbegrenzt', () {
      final d = collectTimesheet(
        projects,
        TimesheetFilter(period: TimesheetPeriod.custom),
        now: mittwoch,
      );
      expect(d.rows, hasLength(4));
    });

    test('Grenztage zählen mit', () {
      final d = collectTimesheet(
        projects,
        TimesheetFilter(
            period: TimesheetPeriod.custom,
            from: '2026-08-10',
            to: '2026-08-10'),
        now: mittwoch,
      );
      expect(d.rows, hasLength(1));
      expect(d.rows.single.entry.date, '2026-08-10');
    });
  });

  group('Summen', () {
    test('Lohn wird je Mitarbeiter gerechnet', () {
      final d = collectTimesheet(
        [
          project('Bau', [
            h('2026-08-10', 'Anna', 8),
            h('2026-08-10', 'Bert', 8),
          ])
        ],
        TimesheetFilter(),
        wages: {'Anna': 30, 'Bert': 25},
        now: mittwoch,
      );
      expect(d.totalHours, 16);
      expect(d.totalWage, 440); // 8*30 + 8*25
    });

    test('fehlender Stundenlohn lässt keine Arbeitszeit verschwinden', () {
      final d = collectTimesheet(
        [
          project('Bau', [
            h('2026-08-10', 'Anna', 8),
            h('2026-08-10', 'Unbekannt', 5),
          ])
        ],
        TimesheetFilter(),
        wages: {'Anna': 30},
        now: mittwoch,
      );
      expect(d.totalHours, 13, reason: 'Stunden zählen unabhängig vom Lohn');
      expect(d.totalWage, 240);
    });

    test('ohne Löhne bleibt die Lohnsumme null', () {
      final d = collectTimesheet(
        [
          project('Bau', [h('2026-08-10', 'Anna', 8)])
        ],
        TimesheetFilter(),
        now: mittwoch,
      );
      expect(d.totalHours, 8);
      expect(d.totalWage, 0);
    });

    test('Rundungsfehler summieren sich nicht auf', () {
      final d = collectTimesheet(
        [
          project('Bau', [
            for (var i = 0; i < 10; i++) h('2026-08-10', 'Anna', 0.1),
          ])
        ],
        TimesheetFilter(),
        now: mittwoch,
      );
      expect(d.totalHours, 1.0);
    });

    test('Verteilungen sind absteigend sortiert', () {
      final d = collectTimesheet(
        [
          project('Klein', [h('2026-08-10', 'Anna', 2)]),
          project('Groß', [h('2026-08-11', 'Anna', 9)]),
          project('Mittel', [h('2026-08-12', 'Anna', 5)]),
        ],
        TimesheetFilter(),
        now: mittwoch,
      );
      expect(d.byProject.keys.toList(), ['Groß', 'Mittel', 'Klein']);
    });

    test('Tage werden gruppiert, neueste zuerst', () {
      final d = collectTimesheet(
        [
          project('Bau', [
            h('2026-08-10', 'Anna', 8),
            h('2026-08-12', 'Anna', 4),
            h('2026-08-10', 'Bert', 3),
          ])
        ],
        TimesheetFilter(),
        now: mittwoch,
      );
      expect(d.byDay.keys.toList(), ['2026-08-12', '2026-08-10']);
      expect(d.byDay['2026-08-10'], hasLength(2));
      expect(d.dayCount, 2);
    });
  });

  group('Kaputte Daten', () {
    test('Einträge ohne Datum landen nicht in den Summen', () {
      final d = collectTimesheet(
        [
          project('Bau', [
            h('2026-08-10', 'Anna', 8),
            h('', 'Anna', 99),
            h('kein-datum', 'Anna', 99),
          ])
        ],
        TimesheetFilter(),
        now: mittwoch,
      );
      expect(d.totalHours, 8);
      expect(d.undatedCount, 2);
    });

    test('unmögliches Datum wird abgewiesen', () {
      final d = collectTimesheet(
        [
          project('Bau', [h('2026-02-31', 'Anna', 8)])
        ],
        TimesheetFilter(period: TimesheetPeriod.custom),
        now: mittwoch,
      );
      // DateTime.parse rollt den 31.02. auf den 03.03. – als Arbeitszeit ist
      // das falsch, deshalb muss es als undatiert gelten.
      expect(d.undatedCount, 1);
      expect(d.rows, isEmpty);
    });

    test('fremde Datenfehler tauchen beim Mitarbeiterfilter nicht auf', () {
      final d = collectTimesheet(
        [
          project('Bau', [
            h('', 'Bert', 5),
            h('2026-08-10', 'Anna', 8),
          ])
        ],
        TimesheetFilter(worker: 'Anna'),
        now: mittwoch,
      );
      expect(d.undatedCount, 0);
    });
  });

  group('Herkunft', () {
    test('erkennt automatisch erfasste Zeilen an der ID', () {
      final d = collectTimesheet(
        [
          project('Bau', [
            h('2026-08-10', 'Anna', 8, id: 'tt_12345_0'),
            h('2026-08-10', 'Anna', 2, id: '99887766_1'),
          ])
        ],
        TimesheetFilter(),
        now: mittwoch,
      );
      final auto = d.rows.where((r) => r.fromTracking);
      expect(auto, hasLength(1));
      expect(auto.single.entry.h, 8);
    });
  });

  group('CSV', () {
    TimesheetData data() => collectTimesheet(
          [
            project('Neubau; Halle 4', [
              h('2026-08-10', 'Anna', 8, task: 'Mauern EG', id: 'tt_1'),
            ])
          ],
          TimesheetFilter(),
          wages: {'Anna': 30},
          now: mittwoch,
        );

    test('maskiert Trennzeichen im Auftragsnamen', () {
      final csv = buildTimesheetCsv(data(), includeWages: false);
      expect(csv, contains('"Neubau; Halle 4"'));
    });

    test('Lohnspalten fehlen ohne Recht', () {
      final csv = buildTimesheetCsv(data(), includeWages: false);
      expect(csv, isNot(contains('Lohnkosten')));
      expect(csv.split('\r\n').first.split(';'), hasLength(7));
    });

    test('Lohnspalten erscheinen mit Recht', () {
      final csv = buildTimesheetCsv(data(),
          includeWages: true, wages: {'Anna': 30});
      expect(csv, contains('Lohnkosten (€)'));
      expect(csv, contains('240,00'));
    });

    test('Dezimalkomma und Herkunft stehen in der Zeile', () {
      final csv = buildTimesheetCsv(data(), includeWages: false);
      final row = csv.split('\r\n')[1];
      expect(row, contains('8,00'));
      expect(row, contains('automatisch'));
      expect(row, contains('10.08.2026'));
    });

    test('Summenzeile am Ende', () {
      final csv = buildTimesheetCsv(data(), includeWages: false);
      expect(csv.trimRight().split('\r\n').last, startsWith('Summe;'));
    });
  });

  group('Beschriftung', () {
    test('Zeitraum wird lesbar ausgegeben', () {
      expect(TimesheetFilter().rangeLabel(mittwoch),
          '10.08.2026 – 16.08.2026');
    });

    test('offener Zeitraum ohne Grenzen', () {
      expect(
        TimesheetFilter(period: TimesheetPeriod.custom).rangeLabel(mittwoch),
        'Gesamter Zeitraum',
      );
    });

    test('nur eine Grenze gesetzt', () {
      expect(
        TimesheetFilter(period: TimesheetPeriod.custom, from: '2026-08-01')
            .rangeLabel(mittwoch),
        'ab 01.08.2026',
      );
    });
  });
}
