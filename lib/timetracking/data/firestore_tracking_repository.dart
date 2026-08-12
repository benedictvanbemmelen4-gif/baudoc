// Die erfassten Zeiten in Cloud Firestore – damit das Büro sie überhaupt sieht.
//
// Bisher lag das Journal ausschließlich auf dem Handy des Monteurs. Erfasste
// Zeiten kamen nur dann im Büro an, wenn jemand hinterher den Stundenzettel
// abtippte. Hier landen sie in `timeEntries/{id}`, und der Prüf-Bildschirm des
// Büros zeigt sie, sobald sie entstehen.
//
// **Die laufende Sitzung bleibt auf dem Gerät.** Das ist Absicht, nicht
// Bequemlichkeit:
//
//  * Sie ist Gerätezustand. Der Geofence, die Benachrichtigung und die
//    laufende Uhr gehören zu genau diesem Telefon; kein anderer liest sie.
//  * Sie wird nach *jedem* Zustandsübergang gesichert – Ankunft, Pause,
//    Weiterarbeiten. Das ins Netz zu schreiben wäre ein Schreibvorgang je
//    Tastendruck für etwas, das niemand abruft.
//  * Sie muss beim Start sofort lesbar sein, auch bevor Firebase die Anmeldung
//    wiederhergestellt hat. Sonst stünde nach einem Neustart mitten im
//    Arbeitstag kein Timer mehr da.
//
// Das Journal dagegen ist die gemeinsame Wahrheit und gehört ins Netz. Ohne
// Verbindung geht auch das weiter: Firestore nimmt den Eintrag lokal an und
// reicht ihn nach, sobald wieder Netz da ist – im Funkloch auf der Baustelle
// merkt der Monteur nichts davon.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/time_entry.dart';
import '../models/tracking_state.dart';
import 'prefs_tracking_repository.dart';
import 'tracking_repository.dart';

class FirestoreTrackingRepository implements TrackingRepository {
  FirestoreTrackingRepository({
    required this.currentUserId,
    FirebaseFirestore? firestore,
    TrackingRepository? sitzungsspeicher,
  })  : _uebergeben = firestore,
        _sitzung = sitzungsspeicher ?? PrefsTrackingRepository();

  final FirebaseFirestore? _uebergeben;

  /// Erst beim ersten Zugriff, nicht schon im Konstruktor: die Oberfläche
  /// baut den Controller mit, sobald irgendein Widget die Zeiterfassung
  /// anzeigt – auch dann, wenn Firebase gar nicht gestartet ist. Ein
  /// Konstruktor, der in diesem Fall wirft, reißt den ganzen Bildschirm ab.
  late final FirebaseFirestore _db = _uebergeben ?? FirebaseFirestore.instance;

  /// Wer ist angemeldet? Der Server lässt nur zu, dass jemand Zeiten im
  /// eigenen Namen anlegt – siehe firestore.rules.
  final String Function() currentUserId;

  /// Die laufende Sitzung liegt weiterhin auf dem Gerät, siehe Kopfkommentar.
  final TrackingRepository _sitzung;

  CollectionReference<Map<String, dynamic>> get _sammlung =>
      _db.collection('timeEntries');

  List<TimeEntry> _eintraege = [];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _zuhoerer;
  void Function()? _onRemoteChange;

  @override
  set onRemoteChange(void Function() rueckmelder) =>
      _onRemoteChange = rueckmelder;

  @override
  Future<void> init() async {
    await _sitzung.init();

    // Jeder Schritt einzeln abgesichert: keiner von ihnen darf die
    // Zeiterfassung als Ganzes verhindern. Der Monteur muss seine Zeit auch
    // dann starten und stoppen können, wenn die Ablage gerade nicht erreichbar
    // ist – die Sitzung liegt ohnehin auf dem Gerät.
    try {
      _uebernimm(await _sammlung.get());
    } catch (e) {
      debugPrint('Zeiten nicht lesbar: $e');
    }

    try {
      await _uebernahmeDesGeraetejournals();
    } catch (e) {
      debugPrint('Gerätejournal nicht übernommen: $e');
    }

    try {
      _zuhoerer = _sammlung.snapshots().listen(
        (s) {
          _uebernimm(s);
          _onRemoteChange?.call();
        },
        onError: (Object e) => debugPrint('Zeiten-Zuhörer abgebrochen: $e'),
      );
    } catch (e) {
      debugPrint('Zeiten-Zuhörer nicht angehängt: $e');
    }
  }

  void _uebernimm(QuerySnapshot<Map<String, dynamic>> schnappschuss) {
    final liste = <TimeEntry>[];
    for (final d in schnappschuss.docs) {
      try {
        liste.add(TimeEntry.fromJson({...d.data(), 'id': d.id}));
      } catch (_) {
        // Ein defekter Einzeleintrag darf nicht das ganze Journal kosten.
      }
    }
    liste.sort((a, b) => b.startTime.compareTo(a.startTime));
    _eintraege = liste;
  }

  /// Verbindung lösen – beim Abmelden.
  void dispose() {
    _zuhoerer?.cancel();
    _zuhoerer = null;
    _eintraege = [];
  }

  // ---- Sitzung: unverändert auf dem Gerät ----

  @override
  Future<TrackingSession?> loadSession() => _sitzung.loadSession();

  @override
  Future<void> saveSession(TrackingSession? session) =>
      _sitzung.saveSession(session);

  // ---- Journal: gemeinsam ----

  @override
  Future<List<TimeEntry>> loadEntries() async => List.unmodifiable(_eintraege);

  @override
  Future<void> appendEntry(TimeEntry entry) => _schreibe(entry);

  @override
  Future<void> updateEntry(TimeEntry entry) => _schreibe(entry);

  /// Anlegen und Ändern sind derselbe Vorgang.
  ///
  /// Die Id kommt vom Automaten, nicht von Firestore. Dadurch ist der
  /// Schreibvorgang idempotent: eine doppelt zugestellte Benachrichtigung legt
  /// keinen zweiten Eintrag an, sie überschreibt denselben.
  Future<void> _schreibe(TimeEntry entry) async {
    final j = entry.toJson()..remove('id');
    // Sofort im eigenen Bestand nachziehen. Firestore meldet den Eintrag
    // gleich darauf ohnehin, aber der Controller liest direkt nach dem
    // Schreiben – ohne das fehlte die gerade abgeschlossene Zeit für einen
    // Wimpernschlag in der Liste.
    final i = _eintraege.indexWhere((e) => e.id == entry.id);
    if (i >= 0) {
      _eintraege[i] = entry;
    } else {
      _eintraege
        ..add(entry)
        ..sort((a, b) => b.startTime.compareTo(a.startTime));
    }

    // **Bewusst nicht abgewartet.** Firestore meldet einen Schreibvorgang erst
    // als erledigt, wenn der Server ihn bestätigt hat. Im Funkloch käme diese
    // Bestätigung nie – und der Automat, der hier wartete, nähme kein weiteres
    // Ereignis mehr an: keine Pause, kein Feierabend, bis wieder Netz da ist.
    // Lokal liegt der Eintrag sofort und dauerhaft vor, nachgereicht wird er
    // von Firestore selbst.
    unawaited(_sammlung.doc(entry.id).set(j).then(
      (_) {},
      onError: (Object e) {
        // Nicht der Offline-Fall, sondern verweigerte Rechte. Die Zeit bleibt
        // trotzdem in der Liste stehen, damit sie der Monteur sieht.
        debugPrint('Zeit nicht geschrieben: $e');
      },
    ));
  }

  // -------------------------------------------------------------------------
  // Einmalige Übernahme des Gerätejournals
  // -------------------------------------------------------------------------

  static const _uebernommen = 'tt_nach_firestore_uebernommen_v1';

  /// Hebt das bisher nur lokal geführte Journal in die gemeinsame Ablage.
  ///
  /// Übernommen wird nur, was dem Angemeldeten gehört. Einträge eines anderen
  /// Kontos bleiben liegen: der Server lässt es nicht zu, Arbeitszeit im Namen
  /// eines anderen einzutragen (firestore.rules), und das ist richtig so –
  /// eine falsch zugeordnete Stunde ist schlimmer als eine fehlende Zeile, die
  /// im Gerätejournal nachweisbar bleibt.
  Future<void> _uebernahmeDesGeraetejournals() async {
    final uid = currentUserId();
    if (uid.isEmpty) return;

    final prefs = _sitzung;
    if (prefs is! PrefsTrackingRepository) return;
    if (await prefs.getFlag(_uebernommen)) return;

    final lokal = await prefs.loadEntries();
    var uebernommen = 0;
    var fremd = 0;

    for (final e in lokal) {
      if (_eintraege.any((v) => v.id == e.id)) continue;
      if (e.userId.isNotEmpty && e.userId != uid) {
        fremd++;
        continue;
      }
      // Ohne Kennung (aus der Zeit vor der Anmeldung mit Konto): Der Eintrag
      // ist auf diesem Gerät entstanden, also gehört er dem, der hier arbeitet.
      final j = e.toJson()
        ..remove('id')
        ..['userId'] = uid;
      try {
        await _sammlung.doc(e.id).set(j);
        uebernommen++;
      } catch (err) {
        debugPrint('Zeit ${e.id} nicht übernommen: $err');
      }
    }

    await prefs.setFlag(_uebernommen, true);
    if (uebernommen > 0 || fremd > 0) {
      debugPrint('Zeiterfassung übernommen: $uebernommen Einträge, '
          '$fremd fremde blieben im Gerätejournal.');
    }
  }
}
