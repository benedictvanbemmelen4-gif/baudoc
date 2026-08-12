// Speicherung der Stammdaten in SharedPreferences.
//
// Das ist die bisherige Speicherung der App, nur hinter den Vertrag gezogen:
// weiterhin *ein* JSON-Text unter dem Schlüssel `baudoc.flutter`. Dass jeder
// Schreibvorgang den ganzen Bestand neu serialisiert, ist ab jetzt ein Detail
// dieser Klasse – die Oberfläche sagt bereits „speichere diesen Auftrag", und
// die Firestore-Umsetzung wird genau das dann auch tun.
//
// Der Datenstand bleibt unverändert lesbar: Format und Schlüssel sind
// dieselben wie vorher, es gibt also nichts zu migrieren.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'master_data_repository.dart';

class PrefsMasterDataRepository implements MasterDataRepository {
  static const _key = 'baudoc.flutter';

  late SharedPreferences _p;

  /// Derselbe Bestand, den auch der Store hält – bewusst dieselben Listen und
  /// nicht Kopien. Deshalb genügt bei jedem Schreibvorgang das Serialisieren;
  /// die Änderung *im* Objekt hat die Oberfläche schon vorgenommen.
  MasterData? _data;

  /// Wird hier nie gerufen: eine Datei auf dem Gerät ändert sich nicht von
  /// selbst. Der Setzer existiert nur, weil der Vertrag ihn verlangt.
  @override
  set onRemoteChange(void Function() rueckmelder) {}

  /// Auf dem Gerät wartet nichts: `setString` ist zurück, wenn es geschrieben
  /// ist. Ein „nicht übertragen" gibt es hier schlicht nicht.
  @override
  int pendingIn(String projectId) => 0;

  @override
  bool get hasPendingWrites => false;

  @override
  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
  }

  @override
  Future<MasterData?> load() async {
    final raw = _p.getString(_key);
    if (raw == null) return null;
    try {
      final data = MasterData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      _data = data;
      return data;
    } catch (e) {
      // Kaputte Daten dürfen den Start nicht verhindern: der Aufrufer befüllt
      // dann neu. Das war auch bisher so (leeres catch in Store.load).
      debugPrint('Stammdaten unlesbar, wird neu befüllt: $e');
      return null;
    }
  }

  @override
  Future<void> replaceAll(MasterData data) async {
    _data = data;
    await _write();
  }

  // ---------------------------------------------------------------------
  // Einzelne Datensätze
  //
  // Alle Wege enden im selben `_write()`. Das ist bei einem einzigen JSON-Text
  // unvermeidlich – der Gewinn liegt darin, dass die *Aufrufer* jetzt sagen,
  // was sich geändert hat.
  // ---------------------------------------------------------------------

  @override
  Future<void> saveProject(Project project) =>
      _upsert(_data?.projects, project, (p) => p.id, project.id);

  @override
  Future<void> deleteProject(String id) =>
      _remove(_data?.projects, (p) => p.id, id);

  /// Hier liegen die Stunden weiterhin im Auftrag – bei *einem* JSON-Text gibt
  /// es nichts zu trennen. Die eigene Operation ist trotzdem richtig: sie sagt
  /// dem Backend, was sich wirklich geändert hat.
  @override
  Future<void> saveWorkHours(String projectId, WorkHours row) async {
    final p = _projekt(projectId);
    if (p == null) return;
    final i = p.hours.indexWhere((h) => h.id == row.id);
    if (i >= 0) {
      p.hours[i] = row;
    } else {
      p.hours.add(row);
    }
    await _write();
  }

  @override
  Future<void> deleteWorkHours(String projectId, String rowId) async {
    final p = _projekt(projectId);
    if (p == null) return;
    p.hours.removeWhere((h) => h.id == rowId);
    await _write();
  }

  /// Ohne Backend gibt es keine Dateiablage – das Bild bleibt als Base64 beim
  /// Auftrag, so wie die App es immer gehalten hat. Die 1-MB-Grenze, die den
  /// Umbau nötig macht, gilt hier nicht: SharedPreferences kennt keine.
  @override
  Future<Photo?> addPhoto(String projectId, Uint8List bytes,
      {required String uploadedBy}) async {
    final p = _projekt(projectId);
    if (p == null) return null;
    final foto = Photo(
      id: uid(),
      uploadedBy: uploadedBy,
      createdAt: DateTime.now().toIso8601String(),
      data: base64Encode(bytes),
    );
    p.photos.add(foto);
    await _write();
    return foto;
  }

  @override
  Future<void> deletePhoto(String projectId, Photo photo) async {
    final p = _projekt(projectId);
    if (p == null) return;
    p.photos.removeWhere((f) => f.id == photo.id);
    await _write();
  }

  Project? _projekt(String id) {
    for (final p in _data?.projects ?? const <Project>[]) {
      if (p.id == id) return p;
    }
    return null;
  }

  @override
  Future<void> saveCustomer(Customer customer) =>
      _upsert(_data?.customers, customer, (c) => c.id, customer.id);

  @override
  Future<void> deleteCustomer(String id) =>
      _remove(_data?.customers, (c) => c.id, id);

  @override
  Future<void> saveUser(AppUser user) =>
      _upsert(_data?.users, user, (u) => u.id, user.id);

  @override
  Future<void> deleteUser(String id) => _remove(_data?.users, (u) => u.id, id);

  @override
  Future<void> saveCatalogItem(CatalogItem item) =>
      _upsert(_data?.catalog, item, (c) => c.id, item.id);

  @override
  Future<void> deleteCatalogItem(String id) =>
      _remove(_data?.catalog, (c) => c.id, id);

  @override
  Future<void> savePauschale(Pauschale pauschale) =>
      _upsert(_data?.pauschalen, pauschale, (p) => p.id, pauschale.id);

  @override
  Future<void> deletePauschale(String id) =>
      _remove(_data?.pauschalen, (p) => p.id, id);

  @override
  Future<void> saveSettings() => _write();

  // ---------------------------------------------------------------------

  /// Anlegen oder ersetzen. Der Datensatz ist meist schon in der Liste – die
  /// Oberfläche arbeitet direkt auf den Objekten –, deshalb ist das hier
  /// überwiegend ein Abgleich und nur bei neuen Datensätzen ein Anhängen.
  Future<void> _upsert<T>(
    List<T>? list,
    T item,
    String Function(T) idOf,
    String id,
  ) async {
    if (list == null) return;
    final i = list.indexWhere((e) => idOf(e) == id);
    if (i >= 0) {
      list[i] = item;
    } else {
      list.add(item);
    }
    await _write();
  }

  Future<void> _remove<T>(
      List<T>? list, String Function(T) idOf, String id) async {
    if (list == null) return;
    list.removeWhere((e) => idOf(e) == id);
    await _write();
  }

  Future<void> _write() async {
    final data = _data;
    if (data == null) return;
    await _p.setString(_key, jsonEncode(data.toJson()));
  }
}
