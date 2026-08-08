// Datenmodell eines einzelnen Zeiterfassungs-Eintrags.
//
// Ein TimeEntry beschreibt genau einen Arbeitsabschnitt auf einer Baustelle:
// von der Ankunft (Geofence-Eintritt oder manueller Start) bis zum Feierabend.
// Er ist bewusst unabhängig von der übrigen App modelliert, damit der
// Zeiterfassungs-Kern ohne main.dart getestet werden kann.

/// Prüfstatus eines Eintrags. Steuert, ob Büro/Meister nacharbeiten müssen.
enum TimeEntryStatus {
  /// Automatisch erfasst, vom Monteur noch nicht bestätigt.
  unconfirmed,

  /// Vom Monteur bestätigt (oder manuell angelegt) – gilt als belastbar.
  confirmed,

  /// Vom Monteur verworfen (Fehlauslösung). Bleibt zur Nachvollziehbarkeit
  /// erhalten, zählt aber nicht in Summen.
  rejected,

  /// Braucht menschliche Prüfung – z. B. vom Nacht-Kapper beendet.
  flaggedForReview,
}

extension TimeEntryStatusX on TimeEntryStatus {
  String get label => switch (this) {
        TimeEntryStatus.unconfirmed => 'Unbestätigt',
        TimeEntryStatus.confirmed => 'Bestätigt',
        TimeEntryStatus.rejected => 'Verworfen',
        TimeEntryStatus.flaggedForReview => 'Prüfen',
      };

  /// Nur bestätigte Einträge fließen in Lohn- und Rechnungssummen ein.
  bool get countsTowardsPayroll => this == TimeEntryStatus.confirmed;
}

class TimeEntry {
  final String id;

  /// Auftrag (Project.id in der Haupt-App).
  final String orderId;

  /// Mitarbeiter (AppUser.id in der Haupt-App).
  final String userId;

  /// Beginn der Arbeitszeit. Bei Geofence-Erfassung der exakte Ankunfts-
  /// zeitstempel – auch dann, wenn die Push erst später bestätigt wird.
  DateTime startTime;

  /// Ende der Arbeitszeit. null, solange der Timer läuft.
  DateTime? endTime;

  TimeEntryStatus status;

  /// Summe aller Pausen in Minuten (manuell + gesetzlicher Abzug).
  int breakDurationMinutes;

  /// true, wenn der Nacht-Kapper den Eintrag zwangsweise beendet hat.
  bool isAutoCapped;

  /// true, wenn der Eintrag durch einen Geofence entstand (statt manuell).
  final bool createdViaGeofence;

  DateTime? geofenceEntryTime;
  DateTime? geofenceExitTime;

  /// Freitext-Tätigkeit, wird beim Abschluss in die Auftragsstunden übernommen.
  String task;

  TimeEntry({
    required this.id,
    required this.orderId,
    required this.userId,
    required this.startTime,
    this.endTime,
    this.status = TimeEntryStatus.unconfirmed,
    this.breakDurationMinutes = 0,
    this.isAutoCapped = false,
    this.createdViaGeofence = false,
    this.geofenceEntryTime,
    this.geofenceExitTime,
    this.task = '',
  });

  /// Läuft der Eintrag noch?
  bool get isOpen => endTime == null;

  /// Bruttozeit (ohne Pausenabzug). Bei laufendem Timer bis [now].
  Duration grossDuration({DateTime? now}) =>
      (endTime ?? now ?? DateTime.now()).difference(startTime);

  /// Nettozeit = Brutto minus Pausen, nie negativ.
  Duration netDuration({DateTime? now}) {
    final net =
        grossDuration(now: now) - Duration(minutes: breakDurationMinutes);
    return net.isNegative ? Duration.zero : net;
  }

  /// Nettostunden als Dezimalwert, kaufmännisch auf 2 Stellen gerundet –
  /// passend zum `double h` der bestehenden WorkHours-Klasse.
  double netHours({DateTime? now}) {
    final minutes = netDuration(now: now).inMinutes;
    return (minutes / 60 * 100).round() / 100;
  }

  TimeEntry copyWith({
    DateTime? startTime,
    DateTime? endTime,
    TimeEntryStatus? status,
    int? breakDurationMinutes,
    bool? isAutoCapped,
    DateTime? geofenceEntryTime,
    DateTime? geofenceExitTime,
    String? task,
  }) =>
      TimeEntry(
        id: id,
        orderId: orderId,
        userId: userId,
        startTime: startTime ?? this.startTime,
        endTime: endTime ?? this.endTime,
        status: status ?? this.status,
        breakDurationMinutes:
            breakDurationMinutes ?? this.breakDurationMinutes,
        isAutoCapped: isAutoCapped ?? this.isAutoCapped,
        createdViaGeofence: createdViaGeofence,
        geofenceEntryTime: geofenceEntryTime ?? this.geofenceEntryTime,
        geofenceExitTime: geofenceExitTime ?? this.geofenceExitTime,
        task: task ?? this.task,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'orderId': orderId,
        'userId': userId,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'status': status.name,
        'breakDurationMinutes': breakDurationMinutes,
        'isAutoCapped': isAutoCapped,
        'createdViaGeofence': createdViaGeofence,
        'geofenceEntryTime': geofenceEntryTime?.toIso8601String(),
        'geofenceExitTime': geofenceExitTime?.toIso8601String(),
        'task': task,
      };

  /// Toleranter Parser: unbekannte/fehlende Felder dürfen einen Eintrag nicht
  /// verlieren – im Handwerk ist ein grob rekonstruierter Eintrag besser als
  /// gar keiner.
  static TimeEntry fromJson(Map<String, dynamic> j) => TimeEntry(
        id: (j['id'] ?? '').toString(),
        orderId: (j['orderId'] ?? '').toString(),
        userId: (j['userId'] ?? '').toString(),
        startTime: _date(j['startTime']) ?? DateTime.now(),
        endTime: _date(j['endTime']),
        status: TimeEntryStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => TimeEntryStatus.unconfirmed,
        ),
        breakDurationMinutes:
            (j['breakDurationMinutes'] as num?)?.toInt() ?? 0,
        isAutoCapped: j['isAutoCapped'] == true,
        createdViaGeofence: j['createdViaGeofence'] == true,
        geofenceEntryTime: _date(j['geofenceEntryTime']),
        geofenceExitTime: _date(j['geofenceExitTime']),
        task: (j['task'] ?? '').toString(),
      );

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse(v) : null;
}
