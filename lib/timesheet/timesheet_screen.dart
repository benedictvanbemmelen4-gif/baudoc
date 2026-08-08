// Stundenzettel: Arbeitsstunden über alle Aufträge hinweg.
//
// Beantwortet die zwei Fragen, für die es in BauDoc bisher keine Ansicht gab:
// „Was habe ich diese Woche gearbeitet?“ (Monteur) und „Was hat Mitarbeiter X
// im Juli gemacht, und was kostet das?“ (Büro).
//
// Rechte: der Mitarbeiterfilter hängt an `exportDocs`, alle Geldbeträge an
// `wages`. Ein Meister sieht damit fremde Stunden, aber keine Löhne – genau
// so sind die Rollen in main.dart vorbelegt.

import 'package:flutter/material.dart';

import '../main.dart'
    show
        ProjectScreen,
        Store,
        dLong,
        dShort,
        eur,
        fileSlug,
        kAccent,
        kAccentInk,
        kBlue,
        kCard2,
        kGreen,
        kInk,
        kLine,
        kMuted,
        kWarn,
        pickDate,
        snack;
import '../csv_export_io.dart'
    if (dart.library.js_interop) '../csv_export_web.dart';
import '../timetracking/tracking_bridge.dart';
import '../timetracking/ui/tracking_ui.dart' show TrackingReviewScreen;
import 'timesheet_data.dart';
import 'timesheet_pdf.dart';

class TimesheetScreen extends StatefulWidget {
  const TimesheetScreen({super.key});

  @override
  State<TimesheetScreen> createState() => _TimesheetScreenState();
}

class _TimesheetScreenState extends State<TimesheetScreen> {
  late TimesheetFilter _filter;

  /// Darf der Benutzer fremde Stunden sehen?
  bool get _maySeeAll => Store.I.can('exportDocs');

  /// Darf der Benutzer Geldbeträge sehen?
  bool get _maySeeWages => Store.I.can('wages');

  @override
  void initState() {
    super.initState();
    // Ohne das Recht auf fremde Stunden ist der Filter fest auf den
    // angemeldeten Benutzer – nicht nur ausgeblendet, sondern gesetzt.
    _filter = TimesheetFilter(
      worker: _maySeeAll ? null : Store.I.currentUser?.name,
    );
  }

  Map<String, double> get _wages =>
      {for (final u in Store.I.users) u.name: u.wage};

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.I,
      builder: (context, _) {
        final data = collectTimesheet(
          Store.I.projects,
          _filter,
          wages: _maySeeWages ? _wages : const {},
        );
        final wide = MediaQuery.of(context).size.width >= 900;

        return Scaffold(
          appBar: AppBar(
            title: Text(_maySeeAll ? 'Stundenzettel' : 'Meine Stunden'),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: EdgeInsets.fromLTRB(wide ? 24 : 14, 14, wide ? 24 : 14, 40),
                children: [
                  _filterCard(),
                  const SizedBox(height: 12),
                  _reviewHint(),
                  _summaryCard(data),
                  const SizedBox(height: 12),
                  _exportRow(data),
                  const SizedBox(height: 6),
                  if (data.undatedCount > 0) _undatedHint(data),
                  const SizedBox(height: 6),
                  if (data.isEmpty)
                    _emptyState()
                  else ...[
                    ..._dayGroups(data),
                    if (data.byProject.length > 1) ...[
                      const SizedBox(height: 16),
                      _projectBreakdown(data),
                    ],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Filter
  // -------------------------------------------------------------------------

  Widget _filterCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: TimesheetPeriod.values
                  .map((p) => ChoiceChip(
                        label: Text(p.label),
                        selected: _filter.period == p,
                        onSelected: (_) => setState(() => _filter.period = p),
                      ))
                  .toList(),
            ),
            if (_filter.period == TimesheetPeriod.custom) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _dateField('Von', _filter.from,
                      (v) => setState(() => _filter.from = v))),
                  const SizedBox(width: 10),
                  Expanded(child: _dateField('Bis', _filter.to,
                      (v) => setState(() => _filter.to = v))),
                ],
              ),
            ],
            if (_maySeeAll) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                initialValue: _filter.worker,
                dropdownColor: kCard2,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Mitarbeiter', isDense: true),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('Alle Mitarbeiter')),
                  ...{for (final u in Store.I.users) u.name}
                      .map((n) => DropdownMenuItem<String?>(
                          value: n, child: Text(n))),
                ],
                onChanged: (v) => setState(() => _filter.worker = v),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _dateField(String label, String value, ValueChanged<String> onPick) {
    return InkWell(
      onTap: () async {
        final picked = await pickDate(context, value);
        if (picked != null) onPick(picked);
      },
      borderRadius: BorderRadius.circular(10),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, isDense: true),
        child: Text(value.isEmpty ? 'unbegrenzt' : dLong(value),
            style: TextStyle(color: value.isEmpty ? kMuted : kInk)),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Kopfbereich
  // -------------------------------------------------------------------------

  /// Warnt, wenn noch unbestätigte Zeiten in der Erfassung hängen – sonst
  /// rechnet das Büro mit Zahlen, unter denen noch Offenes liegt.
  Widget _reviewHint() {
    final open = gTracking.entriesNeedingReview.length;
    if (open == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const TrackingReviewScreen())),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: kWarn.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kWarn.withValues(alpha: .45)),
          ),
          child: Row(
            children: [
              Icon(Icons.pending_actions_outlined, color: kWarn, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$open erfasste Zeit${open == 1 ? '' : 'en'} noch nicht '
                  'bestätigt – die Summen unten sind noch nicht endgültig.',
                  style: TextStyle(fontSize: 12.5, color: kInk, height: 1.25),
                ),
              ),
              Icon(Icons.chevron_right, color: kMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryCard(TimesheetData d) {
    Widget stat(String value, String label, Color color) => Expanded(
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 21, fontWeight: FontWeight.w800, color: color)),
              const SizedBox(height: 2),
              Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: kMuted)),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Column(
          children: [
            Text(_filter.rangeLabel(DateTime.now()),
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: kMuted)),
            const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  stat(_h(d.totalHours), 'Stunden', kAccent),
                  stat('${d.dayCount}', 'Arbeitstage', kBlue),
                  if (_maySeeWages)
                    stat(eur(d.totalWage), 'Lohnkosten', kGreen)
                  else
                    stat('${d.rows.length}', 'Einträge', kBlue),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _undatedHint(TimesheetData d) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 4),
        child: Text(
          '${d.undatedCount} Eintrag/Einträge ohne Datum sind hier nicht '
          'enthalten.',
          style: TextStyle(fontSize: 11.5, color: kMuted),
        ),
      );

  // -------------------------------------------------------------------------
  // Export
  // -------------------------------------------------------------------------

  Widget _exportRow(TimesheetData d) {
    final enabled = !d.isEmpty;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: enabled ? () => _exportCsv(d) : null,
            icon: const Icon(Icons.table_view_outlined, size: 18),
            label: const Text('CSV'),
            style: OutlinedButton.styleFrom(
              foregroundColor: kInk,
              side: BorderSide(color: kLine),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            onPressed: enabled ? () => _exportPdf(d) : null,
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: const Text('PDF'),
            style: FilledButton.styleFrom(
              backgroundColor: kAccent,
              foregroundColor: kAccentInk,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  /// Dateiname aus Zeitraum und Mitarbeiter – so sind mehrere Exporte im
  /// Download-Ordner auseinanderzuhalten.
  String _fileBase() {
    final (from, to) = _filter.resolve(DateTime.now());
    final range = from.isEmpty && to.isEmpty ? 'gesamt' : '${from}_$to';
    final who = _filter.worker == null ? 'alle' : fileSlug(_filter.worker!);
    return 'baudoc_stunden_${who}_${fileSlug(range)}';
  }

  Future<void> _exportCsv(TimesheetData d) async {
    try {
      final csv = buildTimesheetCsv(d,
          includeWages: _maySeeWages, wages: _maySeeWages ? _wages : const {});
      final name = '${_fileBase()}.csv';
      await downloadCsv(name, csv);
      if (mounted) snack(context, 'CSV erstellt: $name');
    } catch (e) {
      if (mounted) snack(context, 'Export fehlgeschlagen: $e');
    }
  }

  Future<void> _exportPdf(TimesheetData d) async {
    try {
      final bytes = await buildTimesheetPdf(
        d,
        rangeLabel: _filter.rangeLabel(DateTime.now()),
        worker: _filter.worker,
        includeWages: _maySeeWages,
        wages: _maySeeWages ? _wages : const {},
      );
      final name = '${_fileBase()}.pdf';
      await downloadBytes(name, bytes, 'application/pdf');
      if (mounted) snack(context, 'PDF erstellt: $name');
    } catch (e) {
      if (mounted) snack(context, 'Export fehlgeschlagen: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Liste
  // -------------------------------------------------------------------------

  List<Widget> _dayGroups(TimesheetData d) {
    final out = <Widget>[];
    for (final day in d.byDay.keys) {
      final rows = d.byDay[day]!;
      final hours = rows.fold<double>(0, (s, r) => s + r.entry.h);
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('${_weekday(day)}, ${dLong(day)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13.5)),
            Text('${_h(hours)} h',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                    color: kAccent)),
          ],
        ),
      ));
      out.add(Card(
        margin: EdgeInsets.zero,
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(height: 1, color: kLine),
              _row(rows[i]),
            ],
          ],
        ),
      ));
    }
    return out;
  }

  Widget _row(TimesheetRow r) {
    return ListTile(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ProjectScreen(projectId: r.project.id))),
      leading: Icon(
        r.fromTracking ? Icons.schedule : Icons.edit_outlined,
        color: r.fromTracking ? kAccent : kMuted,
        size: 20,
      ),
      title: Text(r.project.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(
        [
          if (_filter.worker == null) r.entry.worker,
          if (r.entry.task.trim().isNotEmpty) r.entry.task.trim(),
          if (r.entry.task.trim().isEmpty && _filter.worker != null)
            r.fromTracking ? 'automatisch erfasst' : 'ohne Tätigkeit',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: kMuted, fontSize: 12),
      ),
      trailing: Text('${_h(r.entry.h)} h',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
    );
  }

  Widget _projectBreakdown(TimesheetData d) {
    final max = d.byProject.values.isEmpty ? 1.0 : d.byProject.values.first;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Verteilung auf Aufträge',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 10),
            for (final e in d.byProject.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(e.key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5)),
                        ),
                        Text('${_h(e.value)} h',
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: max == 0 ? 0 : e.value / max,
                        minHeight: 6,
                        backgroundColor: kCard2,
                        valueColor: AlwaysStoppedAnimation(kAccent),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() => Padding(
        padding: const EdgeInsets.only(top: 50),
        child: Column(
          children: [
            Icon(Icons.event_busy_outlined, size: 46, color: kMuted),
            const SizedBox(height: 12),
            Text('Keine Stunden im gewählten Zeitraum',
                style: TextStyle(fontWeight: FontWeight.w700, color: kInk)),
            const SizedBox(height: 4),
            Text(
              _filter.worker == null
                  ? 'Wähle einen anderen Zeitraum.'
                  : 'Für ${_filter.worker} wurde hier nichts erfasst.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: kMuted),
            ),
          ],
        ),
      );

  // -------------------------------------------------------------------------

  /// Stunden ohne unnötige Nachkommastellen und mit Dezimalkomma:
  /// 8.0 → „8“, 7.5 → „7,5“, 7.25 → „7,25“.
  String _h(double v) => v
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'\.?0+$'), '')
      .replaceAll('.', ',');

  static const _weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

  String _weekday(String iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? dShort(iso) : _weekdays[d.weekday - 1];
  }
}
