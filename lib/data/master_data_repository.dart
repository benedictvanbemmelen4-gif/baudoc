// Persistenz der Stammdaten (Aufträge, Kunden, Katalog, Benutzer, Rechte).
//
// Vorbild ist `timetracking/data/tracking_repository.dart`: solange der Zugriff
// hinter diesem Vertrag bleibt, lässt sich die Speicherung austauschen, ohne
// die Oberfläche anzufassen. Genau das ist der Zweck – hinter demselben
// Vertrag folgt später eine Firestore-Umsetzung.
//
// Bewusst *ein* Vertrag mit Operationen je Datensatz statt mehrerer getrennter
// Repositories: was ein Backend braucht, ist „schreibe **diesen** Auftrag" –
// nicht „schreibe alles". Die heutige Umsetzung schreibt zwar weiterhin einen
// einzigen JSON-Text, aber das ist dann ihr Detail und nicht mehr das der App.

import '../models.dart';

/// Der gesamte Bestand auf einmal.
///
/// Die Listen werden von [Store] und der Umsetzung **gemeinsam** benutzt (es
/// sind dieselben Objekte, keine Kopien). Dadurch sieht die Speicherung jede
/// Änderung, die die Oberfläche an einem Auftrag vornimmt, ohne dass irgendwo
/// zwei Stände auseinanderlaufen können.
class MasterData {
  List<CatalogItem> catalog;
  List<Customer> customers;
  List<Pauschale> pauschalen;
  List<Project> projects;
  List<AppUser> users;

  /// Kategorien/Gewerke – frei benennbar, deshalb persistiert.
  List<String> arten;
  List<String> roles;
  Map<String, List<String>> rolePerms;

  /// Einmalige Migrationen, die nicht zweimal laufen dürfen.
  bool adminSeeded;
  bool rolesMigrated;

  MasterData({
    required this.catalog,
    required this.customers,
    required this.pauschalen,
    required this.projects,
    required this.users,
    required this.arten,
    required this.roles,
    required this.rolePerms,
    this.adminSeeded = false,
    this.rolesMigrated = false,
  });

  /// Leerer Bestand – Ausgangspunkt vor dem Erstbefüllen.
  MasterData.empty()
      : catalog = [],
        customers = [],
        pauschalen = [],
        projects = [],
        users = [],
        arten = List.of(defaultArten),
        roles = List.of(defaultRollen),
        rolePerms = {},
        adminSeeded = false,
        rolesMigrated = false;

  Map<String, dynamic> toJson() => {
        'catalog': catalog.map((e) => e.toJson()).toList(),
        'customers': customers.map((e) => e.toJson()).toList(),
        'pauschalen': pauschalen.map((e) => e.toJson()).toList(),
        'projects': projects.map((e) => e.toJson()).toList(),
        'users': users.map((e) => e.toJson()).toList(),
        'arten': arten,
        'roles': roles,
        'rolePerms': rolePerms,
        'adminSeeded': adminSeeded,
        'rolesMigrated': rolesMigrated,
      };

  factory MasterData.fromJson(Map<String, dynamic> j) {
    // Ältere Datenstände ohne 'arten'/'roles' bekommen die Standardlisten.
    final rawArten = (j['arten'] as List?)?.cast<String>();
    final rawRoles = (j['roles'] as List?)?.cast<String>();
    final rawPerms = (j['rolePerms'] as Map?) ?? {};

    return MasterData(
      catalog: ((j['catalog'] ?? []) as List)
          .map((e) => CatalogItem.fromJson(e))
          .toList(),
      customers: ((j['customers'] ?? []) as List)
          .map((e) => Customer.fromJson(e))
          .toList(),
      pauschalen: ((j['pauschalen'] ?? []) as List)
          .map((e) => Pauschale.fromJson(e))
          .toList(),
      projects: ((j['projects'] ?? []) as List)
          .map((e) => Project.fromJson(e))
          .toList(),
      users:
          ((j['users'] ?? []) as List).map((e) => AppUser.fromJson(e)).toList(),
      arten: (rawArten == null || rawArten.isEmpty)
          ? List.of(defaultArten)
          : rawArten,
      roles: (rawRoles == null || rawRoles.isEmpty)
          ? List.of(defaultRollen)
          : rawRoles,
      rolePerms: rawPerms.map((k, v) =>
          MapEntry(k as String, ((v as List?) ?? const []).cast<String>())),
      adminSeeded: j['adminSeeded'] ?? false,
      rolesMigrated: j['rolesMigrated'] ?? false,
    );
  }
}

abstract class MasterDataRepository {
  /// Muss vor jeder anderen Nutzung aufgerufen werden.
  Future<void> init();

  /// Meldet Änderungen, die **von außen** kommen – vom Büro, vom Gerät eines
  /// Kollegen. Die Umsetzung ändert dabei den bereits übergebenen [MasterData]
  /// an Ort und Stelle und ruft danach diesen Rückmelder, damit die Oberfläche
  /// sich auffrischt.
  ///
  /// Die SharedPreferences-Umsetzung ruft ihn nie: dort gibt es kein Außen.
  set onRemoteChange(void Function() rueckmelder);

  /// Wie viele Änderungen an diesem Auftrag warten noch auf die Übertragung?
  ///
  /// Das ist der *echte* Übertragungsstand und ersetzt das frühere Feld
  /// `synced` in jeder Zeile, das nie umgeschaltet wurde. Gezählt werden der
  /// Auftrag selbst und seine Stunden- und Foto-Dokumente.
  ///
  /// Die SharedPreferences-Umsetzung meldet immer 0 – was auf der Platte
  /// liegt, wartet auf nichts.
  int pendingIn(String projectId);

  /// Wartet irgendwo noch etwas auf die Übertragung?
  ///
  /// Gilt für den gesamten Bestand, nicht nur für Aufträge – daran hängt die
  /// Anzeige „alles übertragen" im Kopf der App.
  bool get hasPendingWrites;

  /// Gespeicherten Bestand laden – null, wenn noch nie etwas gespeichert
  /// wurde oder die Daten unlesbar sind. In beiden Fällen befüllt der Aufrufer
  /// neu und ruft [replaceAll].
  Future<MasterData?> load();

  /// Einen Auftrag anlegen oder ersetzen (erkannt an der Id).
  ///
  /// Betrifft die Kopfdaten und die Listen, die üblicherweise eine Person
  /// bearbeitet (Material, Aufgaben, Notizen, Mängel). **Nicht** die Stunden –
  /// die haben eigene Operationen, siehe [saveWorkHours].
  Future<void> saveProject(Project project);
  Future<void> deleteProject(String id);

  /// Eine einzelne Stundenzeile schreiben.
  ///
  /// Bewusst getrennt vom Auftrag: die Zeiterfassung des Monteurs schreibt
  /// Stunden, während das Büro womöglich denselben Auftrag bearbeitet. Ginge
  /// beides über [saveProject], überschriebe der spätere Schreibvorgang die
  /// Zeile des anderen – und das wären abrechenbare Stunden.
  Future<void> saveWorkHours(String projectId, WorkHours row);
  Future<void> deleteWorkHours(String projectId, String rowId);

  Future<void> saveCustomer(Customer customer);
  Future<void> deleteCustomer(String id);

  Future<void> saveUser(AppUser user);
  Future<void> deleteUser(String id);

  Future<void> saveCatalogItem(CatalogItem item);
  Future<void> deleteCatalogItem(String id);

  Future<void> savePauschale(Pauschale pauschale);
  Future<void> deletePauschale(String id);

  /// Listen ohne eigene Id: Kategorien, Rollen, Rechte und die Kennzeichen.
  /// Sie sind klein und ändern sich selten, deshalb genügt „alles davon".
  Future<void> saveSettings();

  /// Kompletten Bestand schreiben. Nur fürs Erstbefüllen und für die
  /// einmalige Übernahme in ein Backend – **nicht** im laufenden Betrieb, das
  /// wäre genau das Verhalten, das dieser Umbau abschafft.
  Future<void> replaceAll(MasterData data);
}
