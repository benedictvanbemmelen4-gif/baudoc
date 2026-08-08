// Auswertung der Arbeitsstunden über alle Aufträge hinweg.
//
// Bewusst ohne Flutter-Widgets: die gesamte Rechnerei – Zeiträume, Filter,
// Summen, CSV – ist damit ohne Gerät und ohne Oberfläche testbar (siehe
// test/timesheet_data_test.dart). Der Bildschirm darüber macht nur noch
// Anzeige.
//
// `WorkHours` liegt in der App verstreut in `Project.hours`. Erst diese
// Datei macht daraus eine flache, sortierbare Liste, die die zwei Fragen des
// Betriebs beantwortet: „Was habe ich diese Woche gearbeitet?“ und „Was hat
// Mitarbeiter X im Juli gemacht?“

import '../main.dart' show Project, WorkHours, csvCell, csvNum, dLong;

// ---------------------------------------------------------------------------
// Zeitraum
// ---------------------------------------------------------------------------

enum TimesheetPeriod { thisWeek, lastWeek, thisMonth, lastMonth, custom }

extension TimesheetPeriodX on TimesheetPeriod {
  String get label => switch (this) {
        TimesheetPeriod.thisWeek => 'Diese Woche',
        TimesheetPeriod.lastWeek => 'Letzte Woche',
        TimesheetPeriod.thisMonth => 'Dieser Monat',
        TimesheetPeriod.lastMonth => 'Letzter Monat',
        TimesheetPeriod.custom => 'Frei',
      };

  /// Grenzen als ISO-Tage (`yyyy-MM-dd`), beide **einschließlich**.
  ///
  /// `WorkHours.date` ist selbst ein ISO-String, deshalb reicht danach ein
  /// lexikalischer Vergleich – kein Parsen je Zeile.
  (String from, String to) range(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    switch (this) {
      case TimesheetPeriod.thisWeek:
        // DateTime.weekday: Montag = 1 … Sonntag = 7.
        final monday = today.subtract(Duration(days: today.weekday - 1));
        return (isoDay(monday), isoDay(monday.add(const Duration(days: 6))));
      case TimesheetPeriod.lastWeek:
        final monday = today
            .subtract(Duration(days: today.weekday - 1))
            .subtract(const Duration(days: 7));
        return (isoDay(monday), isoDay(monday.add(const Duration(days: 6))));
      case TimesheetPeriod.thisMonth:
        final first = DateTime(today.year, today.month, 1);
        // Tag 0 des Folgemonats = letzter Tag dieses Monats. Deckt Schaltjahre
        // und Monatslängen ohne Sonderfälle ab.
        final last = DateTime(today.year, today.month + 1, 0);
        return (isoDay(first), isoDay(last));
      case TimesheetPeriod.lastMonth:
        final first = DateTime(today.year, today.month - 1, 1);
        final last = DateTime(today.year, today.month, 0);
        return (isoDay(first), isoDay(last));
      case TimesheetPeriod.custom:
        // Der Aufrufer setzt die Grenzen selbst.
        return ('', '');
    }
  }
}

/// `DateTime` → `yyyy-MM-dd`.
String isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Ist [iso] ein plausibler Tag? Leere und kaputte Daten sollen nicht
/// stillschweigend in irgendeinen Zeitraum rutschen.
///
/// Die Prüfung geht über `DateTime.tryParse` hinaus: das nimmt auch den
/// 31. Februar an und rollt still auf den 3. März weiter. Ein solcher
/// Eintrag würde sonst mitgezählt *und* am falschen Tag einsortiert.
/// Deshalb muss das Datum den Hin- und Rückweg unverändert überstehen.
bool isValidDay(String iso) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(iso)) return false;
  final d = DateTime.tryParse(iso);
  return d != null && isoDay(d) == iso;
}

// ---------------------------------------------------------------------------
// Filter und Ergebnis
// ---------------------------------------------------------------------------

class TimesheetFilter {
  TimesheetPeriod period;

  /// Nur bei [TimesheetPeriod.custom] ausgewertet, sonst aus `period` berechnet.
  String from;
  String to;

  /// Name des Mitarbeiters; null = alle.
  String? worker;

  TimesheetFilter({
    this.period = TimesheetPeriod.thisWeek,
    this.from = '',
    this.to = '',
    this.worker,
  });

  /// Tatsächlich wirksame Grenzen.
  (String from, String to) resolve(DateTime now) =>
      period == TimesheetPeriod.custom ? (from, to) : period.range(now);

  /// Beschriftung für Kopfzeilen und Dateinamen.
  String rangeLabel(DateTime now) {
    final (f, t) = resolve(now);
    if (f.isEmpty && t.isEmpty) return 'Gesamter Zeitraum';
    if (f.isEmpty) return 'bis ${dLong(t)}';
    if (t.isEmpty) return 'ab ${dLong(f)}';
    return '${dLong(f)} – ${dLong(t)}';
  }
}

/// Eine Stundenzeile mit dem Auftrag, zu dem sie gehört.
class TimesheetRow {
  final Project project;
  final WorkHours entry;

  const TimesheetRow(this.project, this.entry);

  /// Stammt die Zeile aus der automatischen Zeiterfassung?
  ///
  /// Die Bridge (`timetracking/tracking_bridge.dart`) vergibt für erfasste
  /// Zeiten die ID `tt_<Eintrags-ID>`. Handisch eingetragene Stunden haben
  /// eine reine `uid()`.
  bool get fromTracking => entry.id.startsWith('tt_');
}

class TimesheetData {
  /// Alle Zeilen im Zeitraum, neueste zuerst.
  final List<TimesheetRow> rows;

  /// ISO-Tag → Zeilen dieses Tages, absteigend nach Tag.
  final Map<String, List<TimesheetRow>> byDay;

  /// Auftragsname → Stunden im Zeitraum, absteigend nach Stunden.
  final Map<String, double> byProject;

  /// Mitarbeiter → Stunden im Zeitraum, absteigend nach Stunden.
  final Map<String, double> byWorker;

  final double totalHours;

  /// Lohnkosten; 0, wenn keine Stundenlöhne übergeben wurden.
  final double totalWage;

  /// Einträge ohne verwertbares Datum. Sie zählen in **keiner** Summe mit –
  /// die Zahl wird angezeigt, statt sie stillschweigend zu verschlucken.
  final int undatedCount;

  const TimesheetData({
    required this.rows,
    required this.byDay,
    required this.byProject,
    required this.byWorker,
    required this.totalHours,
    required this.totalWage,
    required this.undatedCount,
  });

  bool get isEmpty => rows.isEmpty;

  /// Anzahl der Tage, an denen überhaupt etwas erfasst wurde.
  int get dayCount => byDay.length;
}

// ---------------------------------------------------------------------------
// Aggregation
// ---------------------------------------------------------------------------

/// Sammelt alle Stunden aus [projects], die auf [filter] passen.
///
/// [wages] bildet Mitarbeitername → €/h ab (wie in `buildProjectInvoicePdf`).
/// Fehlt ein Eintrag, zählt der Lohn als 0 – die **Stunden** bleiben davon
/// unberührt, sonst würde ein fehlender Stundensatz Arbeitszeit verschwinden
/// lassen.
TimesheetData collectTimesheet(
  List<Project> projects,
  TimesheetFilter filter, {
  Map<String, double> wages = const {},
  DateTime? now,
}) {
  final (from, to) = filter.resolve(now ?? DateTime.now());
  final rows = <TimesheetRow>[];
  var undated = 0;

  for (final p in projects) {
    for (final h in p.hours) {
      if (filter.worker != null && h.worker != filter.worker) continue;

      if (!isValidDay(h.date)) {
        // Nur zählen, wenn der Mitarbeiterfilter passt – sonst meldeten wir
        // dem Monteur fremde Datenfehler.
        undated++;
        continue;
      }
      // Lexikalischer Vergleich ist bei ISO-Tagen gleichbedeutend mit einem
      // Datumsvergleich. Leere Grenze = unbegrenzt.
      if (from.isNotEmpty && h.date.compareTo(from) < 0) continue;
      if (to.isNotEmpty && h.date.compareTo(to) > 0) continue;

      rows.add(TimesheetRow(p, h));
    }
  }

  // Neueste zuerst; innerhalb eines Tages nach Auftrag, damit die Reihenfolge
  // zwischen zwei Aufrufen stabil bleibt.
  rows.sort((a, b) {
    final byDate = b.entry.date.compareTo(a.entry.date);
    return byDate != 0 ? byDate : a.project.name.compareTo(b.project.name);
  });

  final byDay = <String, List<TimesheetRow>>{};
  final byProject = <String, double>{};
  final byWorker = <String, double>{};
  var totalHours = 0.0;
  var totalWage = 0.0;

  for (final r in rows) {
    byDay.putIfAbsent(r.entry.date, () => []).add(r);
    byProject[r.project.name] = (byProject[r.project.name] ?? 0) + r.entry.h;
    byWorker[r.entry.worker] = (byWorker[r.entry.worker] ?? 0) + r.entry.h;
    totalHours += r.entry.h;
    totalWage += r.entry.h * (wages[r.entry.worker] ?? 0);
  }

  return TimesheetData(
    rows: rows,
    byDay: byDay,
    byProject: _sortedByValue(byProject),
    byWorker: _sortedByValue(byWorker),
    totalHours: _round2(totalHours),
    totalWage: _round2(totalWage),
    undatedCount: undated,
  );
}

/// Absteigend nach Wert – die größten Posten zuerst.
Map<String, double> _sortedByValue(Map<String, double> m) {
  final entries = m.entries.toList()
    ..sort((a, b) {
      final byValue = b.value.compareTo(a.value);
      return byValue != 0 ? byValue : a.key.compareTo(b.key);
    });
  return {for (final e in entries) e.key: _round2(e.value)};
}

/// Summen aus `double`-Additionen sauber halten (0.1 + 0.2 …).
double _round2(double v) => (v * 100).round() / 100;

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------

/// Eine Zeile **pro Eintrag** – anders als `buildProjectsCsv`, das je Auftrag
/// nur eine Summe ausgibt. Für die Lohnbuchhaltung ist genau die Einzelzeile
/// das, was zählt.
///
/// Semikolon als Trenner + Dezimalkomma wie im übrigen Export: öffnet ohne
/// Nacharbeit in deutschem Excel.
String buildTimesheetCsv(
  TimesheetData data, {
  required bool includeWages,
  Map<String, double> wages = const {},
}) {
  const sep = ';';
  final rows = <String>[];

  rows.add([
    'Datum',
    'Mitarbeiter',
    'Auftrag',
    'Gewerk',
    'Tätigkeit',
    'Stunden',
    if (includeWages) 'Stundenlohn (€)',
    if (includeWages) 'Lohnkosten (€)',
    'Erfassung',
  ].map(csvCell).join(sep));

  for (final r in data.rows) {
    final wage = wages[r.entry.worker] ?? 0;
    rows.add([
      dLong(r.entry.date),
      r.entry.worker,
      r.project.name,
      r.project.type,
      r.entry.task,
      csvNum(r.entry.h),
      if (includeWages) csvNum(wage),
      if (includeWages) csvNum(r.entry.h * wage),
      r.fromTracking ? 'automatisch' : 'manuell',
    ].map(csvCell).join(sep));
  }

  // Summenzeile: das Erste, wonach im Büro gesucht wird.
  rows.add('');
  rows.add([
    'Summe',
    '',
    '',
    '',
    '',
    csvNum(data.totalHours),
    if (includeWages) '',
    if (includeWages) csvNum(data.totalWage),
    '',
  ].map(csvCell).join(sep));

  return rows.join('\r\n');
}
