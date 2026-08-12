// Einrichtung der automatischen Ankunftserkennung.
//
// Ohne diesen Ablauf ist die ganze Funktion wirkungslos: die Gateways können
// Berechtigungen anfordern, aber niemand tut es. `armGeofenceForNavigation`
// gibt dann stillschweigend `false` zurück, und der Monteur erfährt nie,
// warum nichts passiert.
//
// Die Reihenfolge ist nicht frei wählbar. Android 11 und neuer verlangt:
// erst „während der Nutzung“, danach *getrennt* „immer zulassen“. Eine
// kombinierte Abfrage lehnt das System stillschweigend ab – der Dialog
// erscheint dann gar nicht erst.

import 'package:flutter/material.dart';

import '../../main.dart'
    show kAccent, kAccentInk, kCard, kGreen, kInk, kLine, kMuted, kRed, kWarn;
import '../services/geofence_gateway.dart';
import '../tracking_bridge.dart';

/// Öffnet die Einrichtung. Liefert true, wenn am Ende Hintergrund-Ortung
/// erlaubt ist – nur dann arbeitet die Erkennung bei geschlossener App.
Future<bool> showAutoTrackingSetup(BuildContext context) async {
  if (!gTracking.supportsAutomaticTracking) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('Nicht verfügbar', style: TextStyle(color: kInk)),
        content: Text(
          LocationPermissionResult.unsupported.message,
          style: TextStyle(color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Verstanden'),
          ),
        ],
      ),
    );
    return false;
  }

  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => const _SetupSheet(),
  );
  return result ?? false;
}

class _SetupSheet extends StatefulWidget {
  const _SetupSheet();

  @override
  State<_SetupSheet> createState() => _SetupSheetState();
}

class _SetupSheetState extends State<_SetupSheet> {
  LocationPermissionResult? _location;
  bool? _notifications;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final loc = await gTracking.checkLocationPermission();
    if (!mounted) return;
    setState(() => _location = loc);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _askNotifications() => _run(() async {
        final ok = await gTracking.requestNotificationPermission();
        if (mounted) setState(() => _notifications = ok);
      });

  Future<void> _askLocation() => _run(() async {
        final r = await gTracking.requestLocationPermission();
        if (mounted) setState(() => _location = r);
      });

  Future<void> _askBackground() => _run(() async {
        final r =
            await gTracking.requestLocationPermission(includeBackground: true);
        if (mounted) setState(() => _location = r);
      });

  @override
  Widget build(BuildContext context) {
    final loc = _location;
    final foreground = loc?.allowsForeground ?? false;
    final background = loc?.allowsBackground ?? false;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: kLine,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Ankunft automatisch erfassen',
            style: TextStyle(
              color: kInk,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'BauDoc kann beim Erreichen einer Baustelle nachfragen, ob die '
            'Zeit laufen soll – und beim Verlassen an den Feierabend '
            'erinnern. Dafür sind zwei Freigaben nötig.',
            style: TextStyle(color: kMuted, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 18),

          _step(
            number: 1,
            title: 'Benachrichtigungen',
            subtitle: 'Ohne sie kommt die Nachfrage nicht an.',
            done: _notifications == true,
            actionLabel: _notifications == true ? null : 'Erlauben',
            onPressed: _askNotifications,
          ),
          const SizedBox(height: 10),
          _step(
            number: 2,
            title: 'Standort',
            subtitle: foreground
                ? 'Erteilt.'
                : 'Nötig, um die Baustelle zu erkennen.',
            done: foreground,
            actionLabel: foreground ? null : 'Erlauben',
            onPressed: _askLocation,
          ),
          const SizedBox(height: 10),
          _step(
            number: 3,
            title: 'Auch bei geschlossener App',
            subtitle: background
                ? 'Erteilt – die Ankunft wird auch erkannt, wenn BauDoc zu ist.'
                : 'In den Systemeinstellungen „Immer zulassen“ wählen.',
            done: background,
            // Erst anbieten, wenn Schritt 2 steht: vorher zeigt Android den
            // Dialog gar nicht an.
            actionLabel: !foreground || background ? null : 'Einstellen',
            onPressed: _askBackground,
          ),

          if (loc != null && !background) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (loc == LocationPermissionResult.deniedForever ||
                        loc == LocationPermissionResult.serviceDisabled)
                    ? kRed.withValues(alpha: 0.08)
                    : kWarn.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                loc.message,
                style: TextStyle(color: kInk, fontSize: 12.5, height: 1.35),
              ),
            ),
          ],

          const SizedBox(height: 20),
          Row(
            children: [
              TextButton(
                onPressed:
                    _busy ? null : () => Navigator.pop(context, background),
                child: Text(
                  background ? 'Fertig' : 'Später',
                  style: TextStyle(color: kMuted),
                ),
              ),
              const Spacer(),
              if (_busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _step({
    required int number,
    required String title,
    required String subtitle,
    required bool done,
    required String? actionLabel,
    required VoidCallback onPressed,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done ? kGreen : kAccent,
            shape: BoxShape.circle,
          ),
          child: done
              ? Icon(Icons.check, size: 16, color: kAccentInk)
              : Text(
                  '$number',
                  style: TextStyle(
                    color: kAccentInk,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: kInk,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.3),
              ),
            ],
          ),
        ),
        if (actionLabel != null) ...[
          const SizedBox(width: 8),
          TextButton(
            onPressed: _busy ? null : onPressed,
            child: Text(actionLabel),
          ),
        ],
      ],
    );
  }
}
