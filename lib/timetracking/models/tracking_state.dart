// Zustände, Ereignisse und Effekte des Zeiterfassungs-Automaten.
//
// Alles hier ist reines Dart ohne Plugins: der Automat lässt sich damit
// vollständig ohne Gerät, Standort oder Benachrichtigungen testen.

import 'time_entry.dart';

/// Zustände der Zeiterfassung für *einen* Mitarbeiter.
///
/// Es kann immer nur ein Timer gleichzeitig laufen – das ist die zentrale
/// Regel gegen doppelte Erfassung (siehe TimeTrackingMachine).
enum TimeTrackingState {
  /// Kein Timer aktiv.
  idle,

  /// Timer läuft, vom Monteur aber noch nicht bestätigt (Geofence-Start).
  trackingUnconfirmed,

  /// Timer läuft und ist bestätigt.
  trackingConfirmed,

  /// Timer läuft, Pause aktiv (Pausenzeit wird abgezogen).
  paused,

  /// Timer wurde beendet, das Ergebnis ist noch nicht abgesegnet
  /// (z. B. nach Geofence-Austritt oder Nacht-Kappung).
  stoppedUnconfirmed,

  /// Abgeschlossen und in die Auftragsstunden übernommen.
  completed,
}

extension TimeTrackingStateX on TimeTrackingState {
  /// Läuft die Uhr? (Pause zählt als laufend, wird aber abgezogen.)
  bool get isActive =>
      this == TimeTrackingState.trackingUnconfirmed ||
      this == TimeTrackingState.trackingConfirmed ||
      this == TimeTrackingState.paused;

  /// Braucht der Zustand eine Handlung des Monteurs?
  bool get needsAttention =>
      this == TimeTrackingState.trackingUnconfirmed ||
      this == TimeTrackingState.stoppedUnconfirmed;

  String get label => switch (this) {
        TimeTrackingState.idle => 'Keine Erfassung',
        TimeTrackingState.trackingUnconfirmed => 'Läuft (unbestätigt)',
        TimeTrackingState.trackingConfirmed => 'Läuft',
        TimeTrackingState.paused => 'Pause',
        TimeTrackingState.stoppedUnconfirmed => 'Beendet (unbestätigt)',
        TimeTrackingState.completed => 'Abgeschlossen',
      };
}

// ---------------------------------------------------------------------------
// Ereignisse
// ---------------------------------------------------------------------------

/// Auslöser eines Zustandswechsels. Sealed, damit der Automat in `switch`
/// vollständig geprüft wird – ein neues Ereignis erzeugt sofort einen
/// Compile-Fehler an jeder Stelle, die es noch nicht behandelt.
sealed class TrackingEvent {
  const TrackingEvent();

  /// Zeitpunkt, zu dem das Ereignis fachlich gilt (nicht zwingend „jetzt“:
  /// eine verzögert zugestellte Geofence-Meldung trägt ihren Originalzeit-
  /// stempel, damit keine Arbeitszeit verloren geht).
  DateTime get at;
}

class GeofenceEntered extends TrackingEvent {
  final String locationId; // = Project.id
  @override
  final DateTime at;
  const GeofenceEntered(this.locationId, this.at);
}

class GeofenceExited extends TrackingEvent {
  final String locationId;
  @override
  final DateTime at;
  const GeofenceExited(this.locationId, this.at);
}

class UserConfirmed extends TrackingEvent {
  @override
  final DateTime at;
  const UserConfirmed(this.at);
}

class UserAdjusted extends TrackingEvent {
  final DateTime newStartTime;
  @override
  final DateTime at;
  const UserAdjusted(this.newStartTime, this.at);
}

class UserDiscarded extends TrackingEvent {
  @override
  final DateTime at;
  const UserDiscarded(this.at);
}

class PauseStarted extends TrackingEvent {
  /// Geplante Pausenlänge; nach Ablauf erinnert eine Push ans Weiterarbeiten.
  final int plannedMinutes;
  @override
  final DateTime at;
  const PauseStarted(this.at, {this.plannedMinutes = 30});
}

class PauseEnded extends TrackingEvent {
  @override
  final DateTime at;
  const PauseEnded(this.at);
}

class ManualStopRequested extends TrackingEvent {
  @override
  final DateTime at;
  const ManualStopRequested(this.at);
}

class ManualStartRequested extends TrackingEvent {
  final String orderId;
  @override
  final DateTime at;
  const ManualStartRequested(this.orderId, this.at);
}

/// Nacht-Sicherheitsnetz: der Timer wird zwangsweise gekappt.
class AutoSafetyCapTriggered extends TrackingEvent {
  /// Zeitpunkt, auf den die Endzeit gesetzt wird (Standard 17:00).
  final DateTime cappedEndTime;
  @override
  final DateTime at;
  const AutoSafetyCapTriggered(this.cappedEndTime, this.at);
}

/// Der Eintrag wird endgültig übernommen (Tagesabschluss).
class EntryFinalized extends TrackingEvent {
  /// Gesetzlicher Pausenabzug, den der Monteur beim Abschluss übernimmt.
  final int breakMinutes;
  @override
  final DateTime at;
  const EntryFinalized(this.at, {required this.breakMinutes});
}

// ---------------------------------------------------------------------------
// Effekte
// ---------------------------------------------------------------------------

/// Nebenwirkungen, die der Automat *beschreibt* statt sie auszuführen.
///
/// Der Automat bleibt dadurch eine reine Funktion; das Ausführen übernimmt
/// der Controller über die Gateways. Genau das macht die Abläufe testbar:
/// ein Test prüft die zurückgegebene Effektliste, ohne Push oder GPS.
sealed class TrackingEffect {
  const TrackingEffect();
}

/// Push „Am Ziel angekommen“ mit [Bestätigen] [Anpassen] [Verwerfen].
class ShowArrivalNotification extends TrackingEffect {
  final String orderId;
  final DateTime arrivalTime;
  const ShowArrivalNotification(this.orderId, this.arrivalTime);
}

/// Push „Baustelle verlassen. Feierabend um HH:MM eintragen?“
class ShowDepartureNotification extends TrackingEffect {
  final String orderId;
  final DateTime exitTime;
  const ShowDepartureNotification(this.orderId, this.exitTime);
}

/// Push nach Ablauf der Pause: „Pause vorbei – weiterarbeiten?“
class SchedulePauseReminder extends TrackingEffect {
  final DateTime fireAt;
  const SchedulePauseReminder(this.fireAt);
}

/// Warnung vor der Zwangs-Kappung („Timer läuft seit 11 h“).
class ScheduleSafetyWarning extends TrackingEffect {
  final DateTime fireAt;
  const ScheduleSafetyWarning(this.fireAt);
}

/// Zwangs-Kappung planen (Standard 22:00).
class ScheduleSafetyCap extends TrackingEffect {
  final DateTime fireAt;
  const ScheduleSafetyCap(this.fireAt);
}

/// Alle geplanten Alarme/Erinnerungen zurücknehmen.
class CancelScheduledAlarms extends TrackingEffect {
  const CancelScheduledAlarms();
}

/// Offene Benachrichtigungen entfernen (z. B. nach Bestätigung).
class DismissNotifications extends TrackingEffect {
  const DismissNotifications();
}

/// Geofence für einen Auftrag registrieren bzw. wieder abmelden.
class RegisterGeofence extends TrackingEffect {
  final String orderId;
  const RegisterGeofence(this.orderId);
}

class RemoveGeofence extends TrackingEffect {
  final String orderId;
  const RemoveGeofence(this.orderId);
}

/// Laufenden Timer als Vordergrunddienst anzeigen bzw. beenden
/// (Android-Pflicht, damit der Prozess nicht weggeräumt wird).
class StartForegroundService extends TrackingEffect {
  final String orderId;
  const StartForegroundService(this.orderId);
}

class StopForegroundService extends TrackingEffect {
  const StopForegroundService();
}

/// Fertiger Eintrag soll in die Auftragsstunden übernommen werden.
class PersistCompletedEntry extends TrackingEffect {
  final TimeEntry entry;
  const PersistCompletedEntry(this.entry);
}

// ---------------------------------------------------------------------------
// Sitzung (persistierter Automatenzustand)
// ---------------------------------------------------------------------------

/// Der vollständige, persistierbare Zustand der Zeiterfassung.
///
/// Genau dieses Objekt wird gespeichert; daraus lässt sich der Automat nach
/// App-Neustart oder OS-Kill exakt rekonstruieren.
class TrackingSession {
  final TimeTrackingState state;
  final TimeEntry entry;

  /// Beginn der laufenden Pause (nur im Zustand [TimeTrackingState.paused]).
  final DateTime? pauseStartedAt;

  /// Geplantes Pausenende – für die Erinnerung nach Neustart.
  final DateTime? pauseEndsAt;

  const TrackingSession({
    required this.state,
    required this.entry,
    this.pauseStartedAt,
    this.pauseEndsAt,
  });

  TrackingSession copyWith({
    TimeTrackingState? state,
    TimeEntry? entry,
    DateTime? pauseStartedAt,
    DateTime? pauseEndsAt,
    bool clearPause = false,
  }) =>
      TrackingSession(
        state: state ?? this.state,
        entry: entry ?? this.entry,
        pauseStartedAt: clearPause ? null : (pauseStartedAt ?? this.pauseStartedAt),
        pauseEndsAt: clearPause ? null : (pauseEndsAt ?? this.pauseEndsAt),
      );

  Map<String, dynamic> toJson() => {
        'state': state.name,
        'entry': entry.toJson(),
        'pauseStartedAt': pauseStartedAt?.toIso8601String(),
        'pauseEndsAt': pauseEndsAt?.toIso8601String(),
      };

  static TrackingSession? fromJson(Map<String, dynamic> j) {
    final rawEntry = j['entry'];
    if (rawEntry is! Map) return null;
    return TrackingSession(
      state: TimeTrackingState.values.firstWhere(
        (s) => s.name == j['state'],
        orElse: () => TimeTrackingState.idle,
      ),
      entry: TimeEntry.fromJson(Map<String, dynamic>.from(rawEntry)),
      pauseStartedAt: j['pauseStartedAt'] is String
          ? DateTime.tryParse(j['pauseStartedAt'] as String)
          : null,
      pauseEndsAt: j['pauseEndsAt'] is String
          ? DateTime.tryParse(j['pauseEndsAt'] as String)
          : null,
    );
  }
}

/// Ergebnis eines Zustandsübergangs: neuer Zustand + auszuführende Effekte.
///
/// [session] ist null, wenn danach kein Timer mehr aktiv ist (Zustand idle).
class TransitionResult {
  final TrackingSession? session;
  final List<TrackingEffect> effects;

  /// Gesetzt, wenn das Ereignis bewusst ignoriert wurde – z. B. ein zweiter
  /// Geofence-Eintritt bei bereits laufendem Timer. Für Diagnose und Tests.
  final String? ignoredReason;

  const TransitionResult(this.session, this.effects, {this.ignoredReason});

  bool get wasIgnored => ignoredReason != null;
}
