// Die Stammdaten in Cloud Firestore – die gemeinsame Ablage für alle Geräte.
//
// Derselbe Vertrag wie `PrefsMasterDataRepository`, nur liegen die Daten jetzt
// im Netz statt auf einem Handy. Was der Monteur auf der Baustelle erfasst,
// sieht das Büro; was das Büro ändert, sieht der Monteur.
//
// Ohne Netz geht es weiter: Firestore hält einen lokalen Zwischenspeicher und
// reicht Schreibvorgänge nach, sobald wieder Verbindung besteht. Genau deshalb
// gibt es hier keine selbstgebaute Synchronisierung – im Funkloch auf der
// Baustelle arbeitet die App unverändert weiter.
//
// Aufteilung der Daten (siehe auch firestore.rules):
//
//   projects/{id}            Kopfdaten + Material, Aufgaben, Notizen, Mängel
//   projects/{id}/hours/{id} je Stundenzeile ein Dokument
//   projects/{id}/photos/{id} je Foto ein Dokument
//   customers/{id}, catalog/{id}, pauschalen/{id}
//   users/{uid}              Name, Rolle, E-Mail
//   wages/{uid}              Stundenlohn – **getrennt**, weil Firestore Rechte
//                            nur je Dokument vergibt und den Lohn sonst jeder
//                            läse, der die Namen liest
//   roles/{rolle}            Rechte der Rolle
//   settings/categories      Kategorien/Gewerke

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models.dart';
import 'master_data_repository.dart';

class FirestoreMasterDataRepository implements MasterDataRepository {
  FirestoreMasterDataRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// Derselbe Bestand, den auch der Store hält – wie bei der
  /// SharedPreferences-Umsetzung dieselben Listen, keine Kopien. Die Zuhörer
  /// unten ändern sie an Ort und Stelle.
  MasterData? _data;

  void Function()? _onRemoteChange;

  final List<StreamSubscription<Object?>> _zuhoerer = [];

  /// Läuft gerade ein eigener Schreibvorgang?
  ///
  /// Firestore meldet jede eigene Änderung sofort auch als Ereignis zurück.
  /// Ohne diese Sperre schriebe die App ihre eigene Änderung erneut in den
  /// Bestand und riefe die Oberfläche auf – harmlos, aber unnötig.
  bool _eigenerSchreibvorgang = false;

  /// Dokumente, deren Schreibvorgang noch nicht beim Server angekommen ist –
  /// je Sammlung eine Menge.
  ///
  /// Das ist der echte Übertragungsstand, den früher das erfundene Feld
  /// `synced` in jeder Zeile vorgab. Firestore kennt ihn selbst: jedes
  /// Dokument, das lokal geschrieben, aber noch nicht bestätigt ist, trägt
  /// `metadata.hasPendingWrites`. Je Sammlung getrennt, weil ein Schnappschuss
  /// immer nur über seine eigene Sammlung vollständig Auskunft gibt.
  ///
  /// Schlüssel: bei `hours` `auftragId/zeilenId`, sonst die Dokument-Id.
  final Map<String, Set<String>> _wartend = {};

  @override
  set onRemoteChange(void Function() rueckmelder) =>
      _onRemoteChange = rueckmelder;

  @override
  int pendingIn(String projectId) {
    var offen = _wartend['projects']?.contains(projectId) ?? false ? 1 : 0;
    for (final schluessel in _wartend['hours'] ?? const <String>{}) {
      if (schluessel.startsWith('$projectId/')) offen++;
    }
    return offen;
  }

  @override
  bool get hasPendingWrites => _wartend.values.any((m) => m.isNotEmpty);

  /// Übernimmt den Wartestand einer Sammlung aus dem Schnappschuss.
  ///
  /// Bewusst die ganze Menge neu aufbauen statt einzelne Änderungen zu
  /// verrechnen: ein Dokument wechselt von „wartet" nach „angekommen", ohne
  /// dass sich sein Inhalt ändert, und diese reinen Metadaten-Ereignisse sind
  /// leicht zu übersehen. Die Mengen sind klein, das kostet nichts.
  void _merkeWartend(
    String sammlung,
    QuerySnapshot<Map<String, dynamic>> schnappschuss,
    String Function(QueryDocumentSnapshot<Map<String, dynamic>>) schluessel,
  ) {
    final neu = <String>{};
    for (final d in schnappschuss.docs) {
      if (d.metadata.hasPendingWrites) neu.add(schluessel(d));
    }
    final alt = _wartend[sammlung] ?? const <String>{};
    if (alt.length == neu.length && alt.containsAll(neu)) return;
    _wartend[sammlung] = neu;
    // Auch wenn sich sonst nichts geändert hat: die Anzeige „nicht
    // übertragen" muss verschwinden, sobald der Server bestätigt hat.
    _onRemoteChange?.call();
  }

  @override
  Future<void> init() async {
    try {
      // Zwischenspeicher ohne Größenbegrenzung: ein Handwerksbetrieb hat
      // Megabytes, nicht Gigabytes – und ein Monteur, dem mitten im Funkloch
      // Daten aus dem Speicher fallen, kann nicht arbeiten.
      _db.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
      );
    } catch (e) {
      // Der Firestore-Nachbau in den Tests kennt diese Einstellung nicht – und
      // braucht sie auch nicht, er hält ohnehin alles im Speicher.
      debugPrint('Zwischenspeicher nicht einstellbar: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Lesen
  // -------------------------------------------------------------------------

  /// Kennzeichen, dass hier schon einmal ein Bestand abgelegt wurde.
  ///
  /// Ohne dieses Dokument könnte die App die leere Datenbank nicht von einer
  /// unterscheiden, aus der jemand alles gelöscht hat – und würde beim nächsten
  /// Start den alten Gerätestand darüberschreiben.
  DocumentReference<Map<String, dynamic>> get _uebernahme =>
      _db.collection('settings').doc('migration');

  @override
  Future<MasterData?> load() async {
    try {
      if (!(await _uebernahme.get()).exists) {
        // Noch nie befüllt: der Aufrufer übergibt seinen Bestand an
        // [replaceAll].
        return null;
      }

      final data = MasterData.empty();

      // Nacheinander statt gleichzeitig: ohne Netz liefert Firestore aus dem
      // Zwischenspeicher, mit Netz sind es acht kleine Abfragen. Die Reihenfolge
      // ist unkritisch, die Übersichtlichkeit zählt mehr.
      data.customers = await _lade('customers', Customer.fromJson);
      data.catalog = await _lade('catalog', CatalogItem.fromJson);
      data.pauschalen = await _lade('pauschalen', Pauschale.fromJson);
      data.users = await _ladeBenutzer();
      data.projects = await _ladeAuftraege();

      final rollen = await _db.collection('roles').get();
      for (final d in rollen.docs) {
        data.rolePerms[d.id] = ((d.data()['perms'] as List?) ?? const [])
            .cast<String>();
      }
      if (data.rolePerms.isNotEmpty) {
        data.roles = data.rolePerms.keys.toList();
      }

      final einstellungen =
          await _db.collection('settings').doc('categories').get();
      final arten = (einstellungen.data()?['arten'] as List?)?.cast<String>();
      if (arten != null && arten.isNotEmpty) data.arten = arten;

      data.adminSeeded = true;
      data.rolesMigrated = true;
      _data = data;
      _hoereZu();
      return data;
    } catch (e, st) {
      // Kein Netz *und* kein Zwischenspeicher, oder die Regeln verweigern den
      // Zugriff. Der Start darf daran nicht scheitern.
      debugPrint('Firestore nicht lesbar: $e\n$st');
      return null;
    }
  }

  Future<List<T>> _lade<T>(
      String sammlung, T Function(Map<String, dynamic>) baue) async {
    final schnappschuss = await _db.collection(sammlung).get();
    return schnappschuss.docs.map((d) => baue({...d.data(), 'id': d.id})).toList();
  }

  /// Benutzer samt Stundenlohn, sofern der Aufrufer ihn sehen darf.
  ///
  /// Ohne das Recht `wages` weisen die Regeln den Zugriff auf `wages/` ab.
  /// Das ist der Normalfall für einen Handwerker und kein Fehler – der Lohn
  /// bleibt dann schlicht bei 0, und die Oberfläche zeigt ihn ohnehin nicht.
  Future<List<AppUser>> _ladeBenutzer() async {
    final docs = await _db.collection('users').get();
    final loehne = <String, double>{};
    try {
      final w = await _db.collection('wages').get();
      for (final d in w.docs) {
        loehne[d.id] = (d.data()['wage'] as num?)?.toDouble() ?? 0;
      }
    } catch (_) {
      // Kein Recht auf Löhne – erwarteter Fall.
    }

    return docs.docs.map((d) {
      final j = d.data();
      return AppUser(
        id: d.id,
        name: j['name'] as String? ?? '',
        role: j['role'] as String? ?? '',
        email: j['email'] as String? ?? '',
        wage: loehne[d.id] ?? 0,
      );
    }).toList();
  }

  /// Aufträge samt Stunden und Fotos.
  ///
  /// Stunden und Fotos liegen in Unterkollektionen. Sie werden mit je *einer*
  /// sammlungsübergreifenden Abfrage geholt und danach den Aufträgen
  /// zugeordnet – sonst wären es zwei Abfragen **pro Auftrag**.
  Future<List<Project>> _ladeAuftraege() async {
    final docs = await _db.collection('projects').get();
    final auftraege = <String, Project>{};
    for (final d in docs.docs) {
      auftraege[d.id] = Project.fromJson({...d.data(), 'id': d.id});
    }
    if (auftraege.isEmpty) return [];

    for (final d in (await _db.collectionGroup('hours').get()).docs) {
      final p = auftraege[d.reference.parent.parent?.id];
      p?.hours.add(WorkHours.fromJson({...d.data(), 'id': d.id}));
    }
    for (final d in (await _db.collectionGroup('photos').get()).docs) {
      final p = auftraege[d.reference.parent.parent?.id];
      final bild = d.data()['data'] as String?;
      if (p != null && bild != null) p.photos.add(bild);
    }

    return auftraege.values.toList();
  }

  // -------------------------------------------------------------------------
  // Zuhören
  // -------------------------------------------------------------------------

  /// Hängt sich an die Sammlungen, damit Änderungen von anderen Geräten ohne
  /// Neuladen ankommen. Das ist der eigentliche Zweck des Umbaus: das Büro
  /// sieht die Stunden des Monteurs, sobald er sie erfasst.
  void _hoereZu() {
    _stoppeZuhoerer();

    // `includeMetadataChanges`: ohne das meldet Firestore nur Inhalts-
    // änderungen. Der Übergang „wartet auf Übertragung" → „angekommen" ist
    // aber genau eine reine Metadaten-Änderung – ohne diesen Schalter bliebe
    // die Anzeige „nicht übertragen" stehen, bis zufällig etwas anderes
    // passiert.
    _zuhoerer.addAll([
      _db
          .collection('projects')
          .snapshots(includeMetadataChanges: true)
          .listen((s) {
        _merkeWartend('projects', s, (d) => d.id);
        _uebernimm(s, (j, id) => Project.fromJson({...j, 'id': id}),
            () => _data!.projects, (p) => p.id);
      }),
      _db
          .collection('customers')
          .snapshots(includeMetadataChanges: true)
          .listen((s) {
        _merkeWartend('customers', s, (d) => d.id);
        _uebernimm(s, (j, id) => Customer.fromJson({...j, 'id': id}),
            () => _data!.customers, (c) => c.id);
      }),
      _db
          .collection('catalog')
          .snapshots(includeMetadataChanges: true)
          .listen((s) {
        _merkeWartend('catalog', s, (d) => d.id);
        _uebernimm(s, (j, id) => CatalogItem.fromJson({...j, 'id': id}),
            () => _data!.catalog, (c) => c.id);
      }),
      _db
          .collection('pauschalen')
          .snapshots(includeMetadataChanges: true)
          .listen((s) {
        _merkeWartend('pauschalen', s, (d) => d.id);
        _uebernimm(s, (j, id) => Pauschale.fromJson({...j, 'id': id}),
            () => _data!.pauschalen, (p) => p.id);
      }),
      _db
          .collectionGroup('hours')
          .snapshots(includeMetadataChanges: true)
          .listen((s) {
        _merkeWartend('hours', s,
            (d) => '${d.reference.parent.parent?.id ?? '?'}/${d.id}');
        _uebernimmStunden(s);
      }),
    ]);
  }

  /// Eine Sammlung in den Bestand übernehmen.
  ///
  /// Beim Auftrag gilt eine Besonderheit: die Stunden stehen **nicht** im
  /// Dokument, sondern in der Unterkollektion. Ein neu gebauter Auftrag hätte
  /// also eine leere Stundenliste – deshalb werden die vorhandenen Stunden
  /// übernommen, bevor der alte Eintrag ersetzt wird.
  void _uebernimm<T>(
    QuerySnapshot<Map<String, dynamic>> schnappschuss,
    T Function(Map<String, dynamic>, String) baue,
    List<T> Function() liste,
    String Function(T) idVon,
  ) {
    if (_data == null || _eigenerSchreibvorgang) return;
    var geaendert = false;
    final ziel = liste();

    for (final aenderung in schnappschuss.docChanges) {
      final id = aenderung.doc.id;
      final i = ziel.indexWhere((e) => idVon(e) == id);

      if (aenderung.type == DocumentChangeType.removed) {
        if (i >= 0) {
          ziel.removeAt(i);
          geaendert = true;
        }
        continue;
      }

      final neu = baue(aenderung.doc.data() ?? const {}, id);
      if (neu is Project && i >= 0) {
        neu.hours.addAll((ziel[i] as Project).hours);
        neu.photos.addAll((ziel[i] as Project).photos);
      }
      if (i >= 0) {
        ziel[i] = neu;
      } else {
        ziel.add(neu);
      }
      geaendert = true;
    }

    if (geaendert) _onRemoteChange?.call();
  }

  void _uebernimmStunden(QuerySnapshot<Map<String, dynamic>> schnappschuss) {
    if (_data == null || _eigenerSchreibvorgang) return;
    var geaendert = false;

    for (final aenderung in schnappschuss.docChanges) {
      final auftragId = aenderung.doc.reference.parent.parent?.id;
      if (auftragId == null) continue;
      final p = _auftrag(auftragId);
      if (p == null) continue;

      final id = aenderung.doc.id;
      final i = p.hours.indexWhere((h) => h.id == id);

      if (aenderung.type == DocumentChangeType.removed) {
        if (i >= 0) {
          p.hours.removeAt(i);
          geaendert = true;
        }
        continue;
      }

      final zeile = WorkHours.fromJson({...aenderung.doc.data()!, 'id': id});
      if (i >= 0) {
        p.hours[i] = zeile;
      } else {
        p.hours.add(zeile);
      }
      geaendert = true;
    }

    if (geaendert) _onRemoteChange?.call();
  }

  Project? _auftrag(String id) {
    for (final p in _data?.projects ?? const <Project>[]) {
      if (p.id == id) return p;
    }
    return null;
  }

  void _stoppeZuhoerer() {
    for (final z in _zuhoerer) {
      z.cancel();
    }
    _zuhoerer.clear();
  }

  /// Verbindung lösen – beim Abmelden. Danach ist dieses Objekt verbraucht.
  void dispose() {
    _stoppeZuhoerer();
    _wartend.clear();
    _data = null;
  }

  // -------------------------------------------------------------------------
  // Schreiben
  // -------------------------------------------------------------------------

  @override
  Future<void> saveProject(Project project) async {
    // Stunden und Fotos gehören nicht ins Auftragsdokument – sie haben eigene
    // Wege. Kämen sie mit, überschriebe jeder Auftrags-Speichervorgang die
    // Stunden, die inzwischen jemand anders erfasst hat.
    final j = project.toJson()
      ..remove('id')
      ..remove('hours')
      ..remove('photos');
    await _schreibe(() => _db.collection('projects').doc(project.id).set(j));
  }

  @override
  Future<void> deleteProject(String id) async {
    await _schreibe(() async {
      // Unterkollektionen verschwinden nicht von selbst, wenn das Dokument
      // gelöscht wird – Firestore kennt keine solche Beziehung.
      final auftrag = _db.collection('projects').doc(id);
      for (final name in ['hours', 'photos']) {
        final unter = await auftrag.collection(name).get();
        for (final d in unter.docs) {
          await d.reference.delete();
        }
      }
      await auftrag.delete();
    });
  }

  @override
  Future<void> saveWorkHours(String projectId, WorkHours row) async {
    final j = row.toJson()..remove('id');
    await _schreibe(() => _db
        .collection('projects')
        .doc(projectId)
        .collection('hours')
        .doc(row.id)
        .set(j));
  }

  @override
  Future<void> deleteWorkHours(String projectId, String rowId) =>
      _schreibe(() => _db
          .collection('projects')
          .doc(projectId)
          .collection('hours')
          .doc(rowId)
          .delete());

  @override
  Future<void> saveCustomer(Customer customer) => _schreibe(() => _db
      .collection('customers')
      .doc(customer.id)
      .set(customer.toJson()..remove('id')));

  @override
  Future<void> deleteCustomer(String id) =>
      _schreibe(() => _db.collection('customers').doc(id).delete());

  @override
  Future<void> saveCatalogItem(CatalogItem item) => _schreibe(() => _db
      .collection('catalog')
      .doc(item.id)
      .set(item.toJson()..remove('id')));

  @override
  Future<void> deleteCatalogItem(String id) =>
      _schreibe(() => _db.collection('catalog').doc(id).delete());

  @override
  Future<void> savePauschale(Pauschale pauschale) => _schreibe(() => _db
      .collection('pauschalen')
      .doc(pauschale.id)
      .set(pauschale.toJson()..remove('id')));

  @override
  Future<void> deletePauschale(String id) =>
      _schreibe(() => _db.collection('pauschalen').doc(id).delete());

  /// Benutzer und Stundenlohn – zwei Dokumente, siehe Kopfkommentar.
  @override
  Future<void> saveUser(AppUser user) async {
    await _schreibe(() async {
      await _db.collection('users').doc(user.id).set({
        'name': user.name,
        'role': user.role,
        'email': user.email,
      });
      // Ohne das Recht dafür weisen die Regeln den Schreibvorgang ab. Das ist
      // kein Fehler: ein Handwerker, der beim Anmelden seinen eigenen Eintrag
      // schreibt, hat schlicht keinen Lohn zu setzen.
      try {
        await _db.collection('wages').doc(user.id).set({'wage': user.wage});
      } catch (e) {
        debugPrint('Stundenlohn nicht geschrieben (fehlendes Recht): $e');
      }
    });
  }

  @override
  Future<void> deleteUser(String id) async {
    await _schreibe(() async {
      await _db.collection('users').doc(id).delete();
      try {
        await _db.collection('wages').doc(id).delete();
      } catch (_) {}
    });
  }

  @override
  Future<void> saveSettings() async {
    final data = _data;
    if (data == null) return;
    await _schreibe(() async {
      await _db
          .collection('settings')
          .doc('categories')
          .set({'arten': data.arten});
      for (final rolle in data.roles) {
        await _db
            .collection('roles')
            .doc(rolle)
            .set({'perms': data.rolePerms[rolle] ?? const <String>[]});
      }
    });
  }

  @override
  Future<void> replaceAll(MasterData data) async {
    _data = data;

    // Nur *ein* Gerät darf übernehmen. Melden sich zwei gleichzeitig zum
    // ersten Mal an, gewinnt hier eines; das andere lädt gleich darauf den
    // Stand des Gewinners, statt seinen eigenen darüberzuschreiben.
    final gewonnen = await _db.runTransaction<bool>((t) async {
      final d = await t.get(_uebernahme);
      if (d.exists) return false;
      t.set(_uebernahme, {
        'done': true,
        'at': FieldValue.serverTimestamp(),
      });
      return true;
    });
    if (!gewonnen) {
      final vorhanden = await load();
      if (vorhanden != null) {
        // Den fremden Stand in dieselben Listen übernehmen, die der Store hält.
        data
          ..customers = vorhanden.customers
          ..catalog = vorhanden.catalog
          ..pauschalen = vorhanden.pauschalen
          ..users = vorhanden.users
          ..projects = vorhanden.projects
          ..arten = vorhanden.arten
          ..roles = vorhanden.roles
          ..rolePerms = vorhanden.rolePerms;
        _data = data;
        _onRemoteChange?.call();
      }
      return;
    }

    await _schreibe(() async {
      for (final c in data.customers) {
        await _db
            .collection('customers')
            .doc(c.id)
            .set(c.toJson()..remove('id'));
      }
      for (final c in data.catalog) {
        await _db.collection('catalog').doc(c.id).set(c.toJson()..remove('id'));
      }
      for (final p in data.pauschalen) {
        await _db
            .collection('pauschalen')
            .doc(p.id)
            .set(p.toJson()..remove('id'));
      }
      for (final u in data.users) {
        await _db.collection('users').doc(u.id).set({
          'name': u.name,
          'role': u.role,
          'email': u.email,
        });
        if (u.wage > 0) {
          try {
            await _db.collection('wages').doc(u.id).set({'wage': u.wage});
          } catch (_) {}
        }
      }
      for (final p in data.projects) {
        final j = p.toJson()
          ..remove('id')
          ..remove('hours')
          ..remove('photos');
        await _db.collection('projects').doc(p.id).set(j);
        for (final h in p.hours) {
          await _db
              .collection('projects')
              .doc(p.id)
              .collection('hours')
              .doc(h.id)
              .set(h.toJson()..remove('id'));
        }
        for (var i = 0; i < p.photos.length; i++) {
          await _db
              .collection('projects')
              .doc(p.id)
              .collection('photos')
              .doc('foto_$i')
              .set({'data': p.photos[i]});
        }
      }
      await _db
          .collection('settings')
          .doc('categories')
          .set({'arten': data.arten});
      for (final rolle in data.roles) {
        await _db
            .collection('roles')
            .doc(rolle)
            .set({'perms': data.rolePerms[rolle] ?? const <String>[]});
      }
    });
    _hoereZu();
  }

  /// Gemeinsamer Rahmen für jeden Schreibvorgang.
  ///
  /// Die Sperre verhindert, dass die eigenen Änderungen als „von außen"
  /// zurückkommen. Auf das Ergebnis wird **nicht** gewartet, wenn kein Netz da
  /// ist: Firestore nimmt den Schreibvorgang lokal an und reicht ihn später
  /// nach – für die Oberfläche ist er damit erledigt.
  Future<void> _schreibe(Future<void> Function() vorgang) async {
    _eigenerSchreibvorgang = true;
    try {
      await vorgang();
    } finally {
      _eigenerSchreibvorgang = false;
    }
  }
}
