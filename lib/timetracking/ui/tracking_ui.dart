// Oberfläche der Zeiterfassung.
//
// Drei Bausteine, die main.dart einbindet:
//  * TrackingBanner        – dauerhaft sichtbarer Status auf der Startseite
//  * ProjectTrackingCard   – Navigation + Start/Stopp im Auftrag
//  * TrackingReviewScreen  – Prüfliste für Büro/Meister
//
// Die Widgets holen ihren Zustand ausschließlich über gTracking und lösen
// Aktionen ausschließlich über dessen öffentliche Methoden aus. Sie kennen
// weder den Automaten noch die Persistenz.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart'
    show
        Project,
        Store,
        snack,
        kAccent,
        kAccentInk,
        kBlue,
        kCard,
        kGreen,
        kInk,
        kLine,
        kMuted,
        kRed,
        kWarn;
import '../core/tracking_rules.dart';
import '../models/time_entry.dart';
import '../models/tracking_state.dart';
import '../services/geofence_gateway.dart' show LocationPermissionResultX;
import '../services/navigation_launcher.dart';
import '../services/time_tracking_controller.dart';
import '../tracking_bridge.dart';
import 'tracking_permissions_ui.dart';

// ---------------------------------------------------------------------------
// Formatierung
// ---------------------------------------------------------------------------

String hhmm(DateTime? t) => t == null
    ? '--:--'
    : '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';

/// Dauer als „7:45 h“ – die im Handwerk übliche Schreibweise.
String fmtDur(Duration d) {
  final m = d.inMinutes;
  return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')} h';
}

String _dayLabel(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.'
    '${d.year}';

// ===========================================================================
// Banner auf der Startseite
// ===========================================================================

/// Das Sicherheitsnetz in der App: solange ein Timer läuft oder ein Eintrag
/// auf eine Entscheidung wartet, ist das hier sichtbar – auch dann, wenn die
/// Push-Benachrichtigung ignoriert oder weggewischt wurde.
class TrackingBanner extends StatefulWidget {
  const TrackingBanner({super.key});

  @override
  State<TrackingBanner> createState() => _TrackingBannerState();
}

class _TrackingBannerState extends State<TrackingBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Die Anzeige ist minutengenau, 20 s Takt reicht und kostet praktisch
    // nichts. Neu gezeichnet wird nur, solange wirklich eine Uhr läuft.
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && gTracking.isTracking) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: gTracking,
        builder: (context, _) => _content(context),
      );

  Widget _content(BuildContext context) {
    final s = gTracking.session;
    if (s == null || s.state == TimeTrackingState.idle) {
      return const SizedBox.shrink();
    }
    final name = Store.I.projectById(s.entry.orderId)?.name ?? 'Auftrag';

    return switch (s.state) {
      TimeTrackingState.trackingUnconfirmed => _shell(
          color: kWarn,
          icon: Icons.timer_outlined,
          title: '$name · seit ${hhmm(s.entry.startTime)}',
          subtitle: 'Automatisch erfasst – bitte bestätigen. '
              'Die Zeit läuft solange weiter.',
          actions: [
            _act('Bestätigen', primary: true, onTap: gTracking.confirm),
            _act('Anpassen', onTap: () => _adjustStart(context)),
            _act('Verwerfen', danger: true, onTap: () => _discard(context)),
          ],
        ),
      TimeTrackingState.trackingConfirmed => _shell(
          color: kAccent,
          icon: Icons.play_circle_outline,
          title: '$name · ${fmtDur(gTracking.elapsed)}',
          subtitle: 'Beginn ${hhmm(s.entry.startTime)}'
              '${s.entry.breakDurationMinutes > 0 ? ' · '
                  '${s.entry.breakDurationMinutes} min Pause' : ''}',
          actions: [
            _act('Pause 30 min', onTap: () => gTracking.startPause()),
            _act('Feierabend',
                primary: true, onTap: () => _finalize(context)),
          ],
        ),
      TimeTrackingState.paused => _shell(
          color: kBlue,
          icon: Icons.pause_circle_outline,
          title: '$name · Pause',
          subtitle: s.pauseEndsAt == null
              ? 'Pause läuft'
              : 'Pause bis ${hhmm(s.pauseEndsAt)} · '
                  'erfasst ${fmtDur(gTracking.elapsed)}',
          actions: [
            _act('Weiterarbeiten', primary: true, onTap: gTracking.endPause),
            _act('Feierabend', onTap: () => _finalize(context)),
          ],
        ),
      TimeTrackingState.stoppedUnconfirmed => _shell(
          color: s.entry.isAutoCapped ? kRed : kWarn,
          icon: s.entry.isAutoCapped
              ? Icons.warning_amber_outlined
              : Icons.home_outlined,
          title: s.entry.isAutoCapped
              ? '$name · automatisch beendet'
              : '$name · Baustelle verlassen',
          subtitle: s.entry.isAutoCapped
              ? 'Auf ${hhmm(s.entry.endTime)} gekappt, weil keine Rückmeldung '
                  'kam. Bitte prüfen und korrigieren.'
              : 'Ende ${hhmm(s.entry.endTime)} · '
                  '${fmtDur(s.entry.grossDuration())} brutto. '
                  'Feierabend eintragen?',
          actions: [
            _act('Eintragen', primary: true, onTap: () => _finalize(context)),
            _act('Anpassen', onTap: () => _adjustStart(context)),
            _act('Verwerfen', danger: true, onTap: () => _discard(context)),
          ],
        ),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _shell({
    required Color color,
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> actions,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                            color: kInk)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, color: kMuted, height: 1.25)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(spacing: 4, children: actions),
        ],
      ),
    );
  }

  Widget _act(String label,
      {required VoidCallback onTap, bool primary = false, bool danger = false}) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor: danger ? kRed : (primary ? kAccent : kMuted),
        textStyle: TextStyle(
            fontWeight: primary ? FontWeight.w800 : FontWeight.w600,
            fontSize: 13.5),
      ),
      child: Text(label),
    );
  }

  Future<void> _adjustStart(BuildContext context) =>
      showAdjustStartDialog(context);

  Future<void> _finalize(BuildContext context) =>
      showFinalizeSheet(context);

  Future<void> _discard(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Zeit verwerfen?'),
        content: const Text(
            'Der Eintrag wird nicht in die Auftragsstunden übernommen. '
            'Er bleibt für die Nachvollziehbarkeit als „verworfen“ erhalten.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              style: TextButton.styleFrom(foregroundColor: kRed),
              child: const Text('Verwerfen')),
        ],
      ),
    );
    if (ok == true) await gTracking.discard();
  }
}

// ===========================================================================
// Dialoge
// ===========================================================================

/// Startzeit korrigieren („Anpassen“ aus Push und Banner).
Future<void> showAdjustStartDialog(BuildContext context) async {
  final entry = gTracking.currentEntry;
  if (entry == null) return;

  final picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(entry.startTime),
    helpText: 'Tatsächlicher Arbeitsbeginn',
  );
  if (picked == null) return;

  // Datum bleibt der Ankunftstag; nur die Uhrzeit wird ersetzt.
  final start = DateTime(
    entry.startTime.year,
    entry.startTime.month,
    entry.startTime.day,
    picked.hour,
    picked.minute,
  );

  // Ein Beginn nach dem Ende wäre eine negative Arbeitszeit.
  final end = entry.endTime;
  if (end != null && !start.isBefore(end)) {
    if (context.mounted) {
      snack(context, 'Der Beginn muss vor dem Ende (${hhmm(end)}) liegen.');
    }
    return;
  }
  await gTracking.adjustStart(start);
}

/// Tagesabschluss mit Pausenabzug.
Future<void> showFinalizeSheet(BuildContext context) async {
  final entry = gTracking.currentEntry;
  if (entry == null) return;

  var breakMinutes = gTracking.suggestedBreakMinutes;
  final task = TextEditingController(text: entry.task);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
          18, 16, 18, MediaQuery.of(ctx).viewInsets.bottom + 20),
      child: StatefulBuilder(
        builder: (ctx, setSt) {
          final gross = entry.grossDuration();
          final already = entry.breakDurationMinutes;
          final net = gross - Duration(minutes: already + breakMinutes);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Feierabend eintragen',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              _kv('Beginn', hhmm(entry.startTime)),
              _kv('Ende', hhmm(entry.endTime ?? DateTime.now())),
              _kv('Brutto', fmtDur(gross)),
              if (already > 0) _kv('Bereits erfasste Pause', '$already min'),
              const SizedBox(height: 10),
              Text('Zusätzlicher Pausenabzug',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: kMuted)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [0, 15, 30, 45]
                    .map((m) => ChoiceChip(
                          label: Text('$m min'),
                          selected: breakMinutes == m,
                          onSelected: (_) => setSt(() => breakMinutes = m),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 6),
              Text(
                _breakHint(gross, already),
                style: TextStyle(fontSize: 11.5, color: kMuted, height: 1.3),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: task,
                decoration: const InputDecoration(
                  labelText: 'Tätigkeit (optional)',
                  hintText: 'z. B. Rohinstallation OG',
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: kAccent.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    'Netto ${fmtDur(net.isNegative ? Duration.zero : net)}',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: kAccent),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: kAccent, foregroundColor: kAccentInk),
                  onPressed: () {
                    Navigator.pop(ctx);
                    gTracking.finalizeEntry(
                      breakMinutes: breakMinutes,
                      task: task.text.trim(),
                    );
                  },
                  child: const Text('Zeit übernehmen'),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
  task.dispose();
}

/// Erklärt den Vorschlag, damit die Zahl nicht willkürlich wirkt.
String _breakHint(Duration gross, int already) {
  final required = TrackingRules.legalBreakMinutes(gross);
  if (required == 0) {
    return 'Unter ${TrackingRules.breakThreshold1Hours} Stunden ist keine '
        'Pause vorgeschrieben.';
  }
  final open = required - already;
  if (open <= 0) {
    return 'Vorgeschrieben sind $required min – bereits erfasst.';
  }
  return 'Nach ArbZG § 4 sind bei ${fmtDur(gross)} insgesamt $required min '
      'Pause vorgeschrieben, davon offen: $open min.';
}

Widget _kv(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
              width: 170,
              child: Text(k, style: TextStyle(fontSize: 13, color: kMuted))),
          Text(v,
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700)),
        ],
      ),
    );

// ===========================================================================
// Karte im Auftrag
// ===========================================================================

/// Navigation starten und Zeit erfassen – direkt im Auftrag.
class ProjectTrackingCard extends StatelessWidget {
  final Project project;
  const ProjectTrackingCard({super.key, required this.project});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: gTracking,
      builder: (context, _) {
        final entry = gTracking.currentEntry;
        final runsHere = entry != null && entry.orderId == project.id;
        final runsElsewhere = entry != null && !runsHere;
        final otherName = runsElsewhere
            ? Store.I.projectById(entry.orderId)?.name ?? 'einem anderen Auftrag'
            : '';

        return Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.schedule_outlined, color: kAccent, size: 20),
                    const SizedBox(width: 8),
                    const Text('Zeiterfassung',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    const Spacer(),
                    if (runsHere)
                      Text(gTracking.state.label,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: kAccent)),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _navigate(context),
                        icon: const Icon(Icons.navigation_outlined, size: 18),
                        label: const Text('Navigation'),
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
                        onPressed: runsElsewhere
                            ? null
                            : () => runsHere
                                ? showFinalizeSheet(context)
                                : gTracking.startManually(project.id),
                        icon: Icon(
                            runsHere
                                ? Icons.stop_circle_outlined
                                : Icons.play_arrow,
                            size: 18),
                        label: Text(runsHere ? 'Feierabend' : 'Zeit starten'),
                        style: FilledButton.styleFrom(
                          backgroundColor: kAccent,
                          foregroundColor: kAccentInk,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                if (runsElsewhere)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Es läuft bereits eine Zeit auf „$otherName“. '
                      'Es kann immer nur ein Timer aktiv sein.',
                      style:
                          TextStyle(fontSize: 11.5, color: kWarn, height: 1.3),
                    ),
                  ),
                // Läuft die Zeit, aber ein Teil der Automatik nicht, muss das
                // sichtbar sein: sonst verlässt sich der Monteur auf eine
                // Erkennung, die gar nicht scharf ist.
                if (runsHere && gTracking.degradedHint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      gTracking.degradedHint!,
                      style:
                          TextStyle(fontSize: 11.5, color: kWarn, height: 1.3),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Karten-App öffnen und – wo möglich – den Geofence scharfschalten.
  Future<void> _navigate(BuildContext context) async {
    final address = project.address.trim();
    if (address.isEmpty) {
      snack(context, 'Für diesen Auftrag ist keine Adresse hinterlegt.');
      return;
    }

    final order =
        TrackedOrder(id: project.id, name: project.name, address: address);

    var armed = await gTracking.armGeofenceForNavigation(order);
    final opened = await NavigationLauncher.navigateTo(address);

    if (!context.mounted) return;
    if (!opened) {
      snack(context, 'Es konnte keine Karten-App geöffnet werden.');
      return;
    }
    if (armed) return;

    // Nicht scharfgeschaltet. Fehlen nur die Berechtigungen, ist das
    // behebbar – dann die Einrichtung anbieten, statt den Monteur mit einem
    // Hinweis abzuspeisen, aus dem er nicht schließen kann, was zu tun ist.
    if (!gTracking.supportsAutomaticTracking) {
      snack(context,
          'Zielführung gestartet. Die Ankunft bitte manuell erfassen.');
      return;
    }

    final permission = await gTracking.checkLocationPermission();
    if (!context.mounted) return;

    if (!permission.allowsBackground) {
      final granted = await showAutoTrackingSetup(context);
      if (granted) {
        armed = await gTracking.armGeofenceForNavigation(order);
      }
      if (!context.mounted) return;
      if (armed) {
        snack(context, 'Ankunft wird jetzt automatisch erkannt.');
        return;
      }
    }

    snack(context,
        'Zielführung gestartet. Die Ankunft bitte manuell erfassen.');
  }
}

// ===========================================================================
// Prüfliste für Büro/Meister
// ===========================================================================

/// Alle Einträge, die eine menschliche Entscheidung brauchen: unbestätigt
/// stehen gelassen oder vom Nacht-Sicherheitsnetz gekappt.
class TrackingReviewScreen extends StatelessWidget {
  const TrackingReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zeiten prüfen')),
      body: ListenableBuilder(
        listenable: gTracking,
        builder: (context, _) {
          final items = gTracking.entriesNeedingReview
            ..sort((a, b) => b.startTime.compareTo(a.startTime));
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.verified_outlined, size: 46, color: kGreen),
                    const SizedBox(height: 12),
                    Text('Keine offenen Zeiten',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, color: kInk)),
                    const SizedBox(height: 4),
                    Text('Alle erfassten Zeiten sind bestätigt.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12.5, color: kMuted)),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
            itemCount: items.length,
            itemBuilder: (_, i) => _reviewCard(context, items[i]),
          );
        },
      ),
    );
  }

  Widget _reviewCard(BuildContext context, TimeEntry e) {
    final project = Store.I.projectById(e.orderId);
    final color = e.isAutoCapped ? kRed : kWarn;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(project?.name ?? 'Gelöschter Auftrag',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    e.isAutoCapped ? 'Automatisch beendet' : e.status.label,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: color),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${_dayLabel(e.startTime)} · ${hhmm(e.startTime)}–'
              '${hhmm(e.endTime)} · ${fmtDur(e.netDuration())} netto'
              '${e.breakDurationMinutes > 0 ? ' (${e.breakDurationMinutes} min '
                  'Pause)' : ''}',
              style: TextStyle(fontSize: 12.5, color: kMuted),
            ),
            Text(
              e.createdViaGeofence
                  ? 'Automatisch bei Ankunft erfasst'
                  : 'Manuell gestartet',
              style: TextStyle(fontSize: 11.5, color: kMuted),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => gTracking.reviewEntry(
                      e.copyWith(status: TimeEntryStatus.rejected)),
                  style: TextButton.styleFrom(foregroundColor: kRed),
                  child: const Text('Verwerfen'),
                ),
                TextButton(
                  onPressed: () => gTracking.reviewEntry(e.copyWith(
                    status: TimeEntryStatus.confirmed,
                    isAutoCapped: false,
                  )),
                  style: TextButton.styleFrom(
                      foregroundColor: kAccent,
                      textStyle: const TextStyle(fontWeight: FontWeight.w800)),
                  child: const Text('Bestätigen'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
