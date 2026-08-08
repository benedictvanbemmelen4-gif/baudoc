// Fachliche Regeln der Zeiterfassung: Pausen und Nacht-Sicherheitsnetz.
//
// Bewusst als reine Funktionen und Konstanten gehalten – keine Uhr, kein
// Speicher, keine Plugins. Alles, was „jetzt“ braucht, bekommt den Zeitpunkt
// übergeben; nur so sind die Regeln deterministisch testbar.

/// Zentrale Stellschrauben. Ein Betrieb kann hiervon abweichen – die Werte
/// liegen deshalb an einer Stelle statt verstreut im Code.
class TrackingRules {
  const TrackingRules._();

  // ---- Pausen ----

  /// Standardlänge der 1-Klick-Pause.
  static const int defaultPauseMinutes = 30;

  /// Gesetzlicher Mindestabzug nach ArbZG § 4:
  /// mehr als 6 bis 9 Stunden → 30 Minuten, mehr als 9 Stunden → 45 Minuten.
  static const int breakThreshold1Hours = 6;
  static const int breakMinutes1 = 30;
  static const int breakThreshold2Hours = 9;
  static const int breakMinutes2 = 45;

  // ---- Nacht-Sicherheitsnetz ----

  /// Nach dieser Laufzeit gilt ein Timer als vergessen.
  static const int maxRunningHours = 11;

  /// Uhrzeit, ab der abends gewarnt wird (auch bei kürzerer Laufzeit).
  static const int eveningWarningHour = 19;

  /// Uhrzeit, zu der ohne Reaktion zwangsweise gekappt wird.
  static const int autoCapHour = 22;

  /// Endzeit, auf die ein gekappter Timer gesetzt wird.
  static const int cappedEndHour = 17;

  /// Radius des Geofence um die Baustelle in Metern.
  ///
  /// 100 m ist ein bewusster Kompromiss: kleinere Radien lösen wegen
  /// GPS-Ungenauigkeit in Häuserschluchten unzuverlässig aus, größere
  /// erfassen die Ankunft schon in der Nachbarstraße.
  static const double geofenceRadiusMeters = 100;

  /// Mindestabstand zwischen zwei Geofence-Ereignissen desselben Ortes.
  /// Fängt „Flattern“ an der Radiusgrenze ab.
  static const Duration geofenceDebounce = Duration(minutes: 2);

  /// Kürzer erfasste Einträge werden als Fehlauslösung behandelt
  /// (Durchfahren, kurzes Anhalten).
  static const Duration minimumMeaningfulDuration = Duration(minutes: 5);

  // ---- abgeleitete Berechnungen ----

  /// Gesetzlich vorgeschriebener Pausenabzug für eine Bruttoarbeitszeit.
  ///
  /// Liefert den Mindestabzug; bereits erfasste Pausen werden über
  /// [suggestedAdditionalBreak] verrechnet.
  static int legalBreakMinutes(Duration grossWork) {
    final hours = grossWork.inMinutes / 60;
    if (hours > breakThreshold2Hours) return breakMinutes2;
    if (hours > breakThreshold1Hours) return breakMinutes1;
    return 0;
  }

  /// Wie viele Pausenminuten beim Tagesabschluss noch fehlen.
  ///
  /// Hat der Monteur schon 20 Minuten Pause erfasst und stünden ihm 30 zu,
  /// werden nur die fehlenden 10 vorgeschlagen – nicht die vollen 30.
  static int suggestedAdditionalBreak(
    Duration grossWork,
    int alreadyTakenMinutes,
  ) {
    final required = legalBreakMinutes(grossWork);
    final missing = required - alreadyTakenMinutes;
    return missing > 0 ? missing : 0;
  }

  /// Zeitpunkt der Vorwarnung: der frühere von „11 h Laufzeit“ und „19:00“,
  /// aber nie in der Vergangenheit relativ zum Start.
  static DateTime safetyWarningTime(DateTime startTime) {
    final byDuration = startTime.add(const Duration(hours: maxRunningHours));
    final byClock = DateTime(
      startTime.year,
      startTime.month,
      startTime.day,
      eveningWarningHour,
    );
    // Startet jemand erst um 20:00, liegt die 19:00-Grenze schon hinter ihm –
    // dann zählt nur die Laufzeitgrenze.
    if (byClock.isBefore(startTime)) return byDuration;
    return byDuration.isBefore(byClock) ? byDuration : byClock;
  }

  /// Zeitpunkt der Zwangs-Kappung: 22:00 des Starttages, bzw. des Folgetages,
  /// falls der Start bereits nach 22:00 lag (Nachtschicht).
  static DateTime safetyCapTime(DateTime startTime) {
    var cap = DateTime(
      startTime.year,
      startTime.month,
      startTime.day,
      autoCapHour,
    );
    if (!cap.isAfter(startTime)) cap = cap.add(const Duration(days: 1));
    return cap;
  }

  /// Endzeit für einen gekappten Timer: 17:00 des Starttages.
  ///
  /// Liegt der Start danach, wird auf den Start zurückgefallen (Dauer 0)
  /// statt eine negative Arbeitszeit zu erzeugen – der Eintrag wird ohnehin
  /// als prüfbedürftig markiert.
  static DateTime cappedEndTime(DateTime startTime) {
    final capped = DateTime(
      startTime.year,
      startTime.month,
      startTime.day,
      cappedEndHour,
    );
    return capped.isAfter(startTime) ? capped : startTime;
  }
}
