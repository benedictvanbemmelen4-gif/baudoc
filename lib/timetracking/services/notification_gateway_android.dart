// Android-Umsetzung der Benachrichtigungen.
//
// Deckt drei Aufgaben ab:
//  * Ankunft/Abfahrt melden – mit Aktions-Buttons, die ohne Öffnen der App
//    funktionieren,
//  * Pausen-, Vorwarn- und Kappungsalarme planen (überleben Neustart),
//  * den laufenden Timer sichtbar halten (siehe running_indicator_gateway.dart).
//
// Diese Datei darf nur auf Android geladen werden – die Auswahl trifft
// platform/tracking_gateways_io.dart.

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/pending_actions.dart';
import 'notification_gateway.dart';
import 'running_indicator_gateway.dart';

// ---------------------------------------------------------------------------
// Kanäle
// ---------------------------------------------------------------------------
//
// Getrennte Kanäle, damit der Monteur in den Systemeinstellungen gezielt
// abschalten kann, was ihn stört, ohne die wichtigen Meldungen zu verlieren.

const _channelArrival = AndroidNotificationChannel(
  'tt_arrival',
  'Ankunft und Abfahrt',
  description:
      'Meldet das Erreichen und Verlassen einer Baustelle und fragt nach, '
      'ob die Zeit erfasst werden soll.',
  importance: Importance.high,
);

const _channelReminder = AndroidNotificationChannel(
  'tt_reminder',
  'Erinnerungen',
  description: 'Pausenende sowie Vorwarnung vor dem automatischen Feierabend.',
  importance: Importance.defaultImportance,
);

const _channelOngoing = AndroidNotificationChannel(
  'tt_ongoing',
  'Laufende Zeiterfassung',
  description: 'Zeigt an, dass gerade Arbeitszeit erfasst wird.',
  importance: Importance.low,
);

// ---------------------------------------------------------------------------
// Rückmelder aus dem Hintergrund-Isolat
// ---------------------------------------------------------------------------

/// Läuft in einem eigenen Isolat, wenn die App beim Tippen geschlossen war.
///
/// Muss eine Funktion auf oberster Ebene sein und `vm:entry-point` tragen,
/// sonst entfernt der Baumschnitt sie im Release-Build – der Button täte dann
/// im Release nichts, während er im Debug funktioniert.
@pragma('vm:entry-point')
void trackingNotificationBackgroundHandler(NotificationResponse response) {
  final id = response.actionId;
  if (id == null || id.isEmpty) return;
  // Kein await möglich: der Rückmelder ist synchron. Das Ablegen läuft
  // trotzdem zu Ende, weil Android dem Isolat dafür Zeit einräumt.
  PendingActions.append(PendingAction(
    actionId: id,
    payload: response.payload,
    at: DateTime.now(),
  ));
}

// ---------------------------------------------------------------------------

class AndroidNotificationGateway
    implements NotificationGateway, RunningIndicatorGateway {
  AndroidNotificationGateway();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  NotificationActionCallback? _callback;
  bool _initialized = false;

  @override
  Future<void> init() async {
    if (_initialized) return;

    tzdata.initializeTimeZones();
    // Ohne gesetzten lokalen Ort rechnet zonedSchedule in UTC – die Pause
    // wäre dann im Sommer zwei Stunden zu spät zu Ende.
    tz.setLocalLocation(tz.getLocation(await _deviceTimeZone()));

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse:
          trackingNotificationBackgroundHandler,
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    for (final c in [_channelArrival, _channelReminder, _channelOngoing]) {
      await android?.createNotificationChannel(c);
    }

    _initialized = true;
  }

  /// Die Zeitzone des Geräts. Fällt bei Unklarheit auf Berlin zurück – die App
  /// wird in einem deutschen Betrieb eingesetzt, und eine falsche Zeitzone ist
  /// schlimmer als eine plausibel geratene.
  Future<String> _deviceTimeZone() async {
    try {
      final offset = DateTime.now().timeZoneOffset;
      // Grobe Zuordnung genügt: nur Mitteleuropa wird tatsächlich erwartet.
      if (offset.inHours == 1 || offset.inHours == 2) return 'Europe/Berlin';
      return 'Europe/Berlin';
    } catch (_) {
      return 'Europe/Berlin';
    }
  }

  void _onResponse(NotificationResponse response) {
    final id = response.actionId;
    if (id == null || id.isEmpty) return;
    _callback?.call(id, response.payload);
  }

  @override
  void setActionCallback(NotificationActionCallback? callback) {
    _callback = callback;
  }

  @override
  Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;

    // Ab Android 13 muss der Nutzer Benachrichtigungen erlauben.
    final granted = await android.requestNotificationsPermission() ?? false;

    // Ab Android 12 sind exakte Alarme gesondert freizugeben. Ohne sie
    // verschiebt das System die Pausenerinnerung um bis zu 15 Minuten –
    // ärgerlich, aber kein Grund, die Freigabe zu erzwingen.
    if (await android.canScheduleExactNotifications() == false) {
      await android.requestExactAlarmsPermission();
    }

    return granted;
  }

  // ---- Meldungen ----------------------------------------------------------

  @override
  Future<void> showArrival({
    required String orderId,
    required String orderName,
    required DateTime arrivalTime,
  }) async {
    await _plugin.show(
      id: TrackingNotificationId.arrival,
      title: 'Auf der Baustelle angekommen',
      body: '$orderName · seit ${_hhmm(arrivalTime)}. Zeit jetzt erfassen?',
      payload: orderId,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelArrival.id,
          _channelArrival.name,
          channelDescription: _channelArrival.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.recommendation,
          actions: const [
            AndroidNotificationAction(TrackingAction.confirm, 'Bestätigen'),
            // „Anpassen“ braucht eine Eingabe, öffnet deshalb bewusst die App.
            AndroidNotificationAction(
              TrackingAction.adjust,
              'Anpassen',
              showsUserInterface: true,
            ),
            AndroidNotificationAction(TrackingAction.discard, 'Verwerfen'),
          ],
        ),
      ),
    );
  }

  @override
  Future<void> showDeparture({
    required String orderId,
    required String orderName,
    required DateTime exitTime,
  }) async {
    await _plugin.show(
      id: TrackingNotificationId.departure,
      title: 'Baustelle verlassen',
      body: '$orderName · um ${_hhmm(exitTime)}. Feierabend eintragen?',
      payload: orderId,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelArrival.id,
          _channelArrival.name,
          channelDescription: _channelArrival.description,
          importance: Importance.high,
          priority: Priority.high,
          actions: const [
            AndroidNotificationAction(TrackingAction.endOfDay, 'Feierabend'),
            AndroidNotificationAction(
              TrackingAction.keepRunning,
              'Weiterlaufen',
            ),
          ],
        ),
      ),
    );
  }

  // ---- Geplante Alarme ----------------------------------------------------

  @override
  Future<void> schedulePauseReminder(DateTime fireAt) => _schedule(
        id: TrackingNotificationId.pauseReminder,
        fireAt: fireAt,
        title: 'Pause zu Ende',
        body: 'Weiterarbeiten? Die Uhr läuft erst nach dem Antippen weiter.',
        actions: const [
          AndroidNotificationAction(TrackingAction.resumeWork, 'Weiterarbeiten'),
        ],
      );

  @override
  Future<void> scheduleSafetyWarning(
    DateTime fireAt, {
    String? orderName,
  }) =>
      _schedule(
        id: TrackingNotificationId.safetyWarning,
        fireAt: fireAt,
        title: 'Läuft die Zeiterfassung noch?',
        body: orderName == null
            ? 'Der Timer läuft ungewöhnlich lange. Ohne Reaktion wird er '
                'um 22:00 auf 17:00 Uhr gekappt.'
            : '$orderName läuft ungewöhnlich lange. Ohne Reaktion wird die '
                'Zeit um 22:00 auf 17:00 Uhr gekappt.',
        actions: const [
          AndroidNotificationAction(TrackingAction.endOfDay, 'Feierabend'),
          AndroidNotificationAction(TrackingAction.keepRunning, 'Weiterlaufen'),
        ],
      );

  Future<void> _schedule({
    required int id,
    required DateTime fireAt,
    required String title,
    required String body,
    required List<AndroidNotificationAction> actions,
  }) async {
    // Termine in der Vergangenheit lehnt die Plattform ab; das passiert nach
    // einem Neustart regelmäßig und ist kein Fehler.
    if (!fireAt.isAfter(DateTime.now())) return;

    await _plugin.zonedSchedule(
      id: id,
      scheduledDate: tz.TZDateTime.from(fireAt, tz.local),
      title: title,
      body: body,
      // Exakt und auch im Ruhezustand: eine Pausenerinnerung, die eine
      // Viertelstunde zu spät kommt, ist wertlos.
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelReminder.id,
          _channelReminder.name,
          channelDescription: _channelReminder.description,
          actions: actions,
        ),
      ),
    );
  }

  @override
  Future<void> cancelScheduled() async {
    await _plugin.cancel(id: TrackingNotificationId.pauseReminder);
    await _plugin.cancel(id: TrackingNotificationId.safetyWarning);
  }

  @override
  Future<void> dismissAll() async {
    await _plugin.cancel(id: TrackingNotificationId.arrival);
    await _plugin.cancel(id: TrackingNotificationId.departure);
  }

  // ---- Laufender Timer ----------------------------------------------------

  @override
  Future<void> showRunning({
    required String orderName,
    required DateTime since,
  }) async {
    await _plugin.show(
      id: TrackingNotificationId.foregroundService,
      title: 'Zeiterfassung läuft',
      body: '$orderName · seit ${_hhmm(since)}',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelOngoing.id,
          _channelOngoing.name,
          channelDescription: _channelOngoing.description,
          importance: Importance.low,
          priority: Priority.low,
          // Nicht wegwischbar und ohne Ton: sie soll informieren, nicht stören.
          ongoing: true,
          autoCancel: false,
          silent: true,
          showWhen: false,
          actions: const [
            AndroidNotificationAction(TrackingAction.endOfDay, 'Feierabend'),
          ],
        ),
      ),
    );
  }

  @override
  Future<void> hideRunning() =>
      _plugin.cancel(id: TrackingNotificationId.foregroundService);

  // ---- Offene Aktionen nachholen ------------------------------------------

  /// Verarbeitet Button-Klicks, die eintrafen, während die App geschlossen war.
  ///
  /// Wird vom Controller beim Start gerufen. Die Reihenfolge bleibt erhalten,
  /// damit „Bestätigen“ vor einem späteren „Feierabend“ wirkt.
  Future<void> replayPendingActions() async {
    final pending = await PendingActions.drain();
    for (final a in pending) {
      debugPrint('Zeiterfassung: hole Aktion nach – $a');
      _callback?.call(a.actionId, a.payload);
    }
  }

  String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}
