import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Zugangsdaten des Firebase-Projekts, erzeugt von `flutterfire configure`.
import 'firebase_options.dart';

// Anmeldung hinter einem Vertrag (lib/auth/).
import 'auth/auth_repository.dart';
import 'auth/firebase_auth_repository.dart';

// Datenmodelle und Stammdaten-Konstanten. Weitergereicht (`export`), weil
// andere Module sie bisher aus main.dart bezogen haben – etwa
// `import '../main.dart' show Store, WorkHours;` in tracking_bridge.dart.
export 'models.dart';
import 'models.dart';

// Speicherung der Stammdaten hinter einem Vertrag (lib/data/).
import 'data/master_data_repository.dart';
import 'data/prefs_master_data_repository.dart';

// Plattform-spezifischer Datei-Export (Web-Download vs. Teilen-Dialog).
import 'csv_export_io.dart' if (dart.library.js_interop) 'csv_export_web.dart';
import 'pdf_invoice.dart';
import 'weather.dart';

// Zeiterfassung (eigenes Modul unter lib/timetracking/).
import 'timetracking/tracking_bridge.dart';
import 'timetracking/ui/tracking_permissions_ui.dart';
import 'timetracking/ui/tracking_ui.dart';
// Auswertung der Stunden über alle Aufträge (lib/timesheet/).
import 'timesheet/timesheet_screen.dart';

// ===================================================================
// BauDoc – Flutter/Dart-Portierung des HTML-Prototyps
// Eine Datei, damit der Einstieg einfach bleibt. Später gern aufteilen.
// ===================================================================

// ---------- Farbpalette ----------
// Helles, professionelles Business-Theme mit Petrol/Teal-Akzent.
// Die Namen sind semantisch (Hintergrund/Fläche/Text/Akzent), damit ein
// Palettenwechsel zentral hier möglich bleibt.
// ---- Farbpalette: hell/dunkel zur Laufzeit umschaltbar ----
// gDark schaltet alle semantischen Farben um; die MaterialApp wird bei
// Änderung neu gebaut (ValueListenableBuilder in BauDocApp); die Wahl wird
// in SharedPreferences persistiert (Store.setDarkMode → übersteht Neustart).
final ValueNotifier<bool> gDark = ValueNotifier<bool>(false);
Color _pick(int light, int dark) => Color(gDark.value ? dark : light);

Color get kBg => _pick(0xFFF5F7F9, 0xFF0E1218); // Seitenhintergrund
Color get kBg2 => _pick(0xFFFFFFFF, 0xFF161C24); // AppBar / Kopfflächen
Color get kCard => _pick(0xFFFFFFFF, 0xFF161C24); // Karten
Color get kCard2 => _pick(0xFFEEF2F5, 0xFF1B222B); // Eingabefelder / Flächen
Color get kLine => _pick(0xFFDDE3E9, 0xFF252D38); // feine Ränder / Trennlinien
Color get kInk => _pick(0xFF0F1D28, 0xFFE7ECF2); // Haupttext
Color get kInk2 => _pick(0xFF3E4C59, 0xFFA7B1BE); // Sekundärtext
Color get kMuted => _pick(0xFF6B7A88, 0xFF6C7784); // gedämpfter Text / Icons
Color get kAccent => _pick(0xFF0E7C86, 0xFF2BA6B1); // Akzent: Petrol/Teal
Color get kAccentInk => _pick(0xFFFFFFFF, 0xFFFFFFFF); // Text/Icon auf Akzent
Color get kGreen => _pick(0xFF1E9E63, 0xFF4CB47B); // Erfolg / offen
Color get kBlue => _pick(0xFF2563EB, 0xFF6C9BF5); // Info
Color get kViolet => _pick(0xFF7C3AED, 0xFFA78BFA); // Akzent sekundär
Color get kRed => _pick(0xFFD64545, 0xFFF0716C); // Fehler / Löschen


// ---------- Helfer ----------
String eur(num n) => '${n.toStringAsFixed(2).replaceAll('.', ',')} €';
String dShort(String d) {
  if (d.isEmpty) return '';
  final parts = d.split('-');
  if (parts.length < 3) return d;
  return '${parts[2]}.${parts[1]}.';
}

String dLong(String d) {
  if (d.isEmpty) return '—';
  final parts = d.split('-');
  if (parts.length < 3) return d;
  return '${parts[2]}.${parts[1]}.${parts[0]}';
}

Future<String?> pickDate(BuildContext context, String current) async {
  final now = DateTime.now();
  final init = current.isEmpty ? now : (DateTime.tryParse(current) ?? now);
  final d = await showDatePicker(
    context: context,
    initialDate: init,
    firstDate: DateTime(now.year - 3),
    lastDate: DateTime(now.year + 5),
  );
  if (d == null) return null;
  return d.toIso8601String().substring(0, 10);
}

String initials(String name) {
  final n = name.trim();
  if (n.isEmpty) return '?';
  final words = n.split(RegExp(r'\s+'));
  final buf = StringBuffer();
  for (final w in words.take(2)) {
    if (w.isNotEmpty) buf.write(w[0]);
  }
  final s = buf.toString().toUpperCase();
  return s.isEmpty ? '?' : s;
}


// ---------- Store (Daten + Persistenz) ----------
class Store extends ChangeNotifier {
  static final Store I = Store._();
  Store._();

  /// Die Speicherung. Heute SharedPreferences, ab Schritt 4 wahlweise
  /// Firestore – hier wird dann eine Zeile getauscht, sonst nichts.
  final MasterDataRepository _repo = PrefsMasterDataRepository();

  /// Die Anmeldung.
  ///
  /// `late` mit Vorbelegung, nicht sofort erzeugt: `FirebaseAuth.instance`
  /// verlangt ein gestartetes Firebase. Ein Test, der vorher eine eigene
  /// Umsetzung zuweist, kommt so ganz ohne Firebase aus.
  late AuthRepository auth = FirebaseAuthRepository();

  /// Der Bestand. Die Listen sind **dieselben Objekte**, die auch das
  /// Repository hält: was die Oberfläche an einem Auftrag ändert, sieht die
  /// Speicherung ohne Umweg.
  MasterData _data = MasterData.empty();

  List<CatalogItem> get catalog => _data.catalog;
  List<Customer> get customers => _data.customers;
  List<Pauschale> get pauschalen => _data.pauschalen;
  List<Project> get projects => _data.projects;
  List<AppUser> get users => _data.users;
  List<String> get arten => _data.arten; // Kategorien/Gewerke (bearbeitbar)
  List<String> get roles => _data.roles; // Rollen (bearbeitbar)
  Map<String, List<String>> get rolePerms => _data.rolePerms;
  bool get online => _data.online;

  /// Kennung des angemeldeten Kontos (Firebase-uid). Wird ausschließlich aus
  /// [_onAccount] gesetzt – die Anmeldung führt Firebase, nicht die App.
  String? sessionId;

  /// Steht der Anmeldezustand schon fest?
  ///
  /// Firebase stellt eine bestehende Sitzung beim Start wieder her, das dauert
  /// einen Augenblick. Ohne dieses Kennzeichen blitzte in dieser Zeit der
  /// Anmeldebildschirm auf, obwohl der Benutzer längst angemeldet ist.
  bool authReady = false;

  /// Angemeldet, aber ohne zugewiesene Rolle – siehe [RootGate].
  bool get awaitingRole => sessionId != null && (currentUser?.role ?? '').isEmpty;

  StreamSubscription<Account?>? _authSub;

  /// Nur noch für den Dunkelmodus zuständig – die Stammdaten laufen über
  /// [_repo], die Sitzung über [auth].
  late SharedPreferences _p;

  /// Alter Schlüssel der selbstgebauten Sitzung. Bleibt nur, um ihn einmal
  /// aufzuräumen; die Sitzung führt jetzt Firebase.
  static const _skey = 'baudoc.session';

  AppUser? get currentUser {
    for (final u in users) {
      if (u.id == sessionId) return u;
    }
    return null;
  }

  // Hat der aktuelle Benutzer das Recht `perm`? Administrator immer alles.
  bool can(String perm) {
    final r = currentUser?.role;
    if (r == null) return false;
    if (r == kAdminRole) return true;
    return (rolePerms[r] ?? const <String>[]).contains(perm);
  }

  // Verwaltungs-Bereich sichtbar?
  bool get canManageAny => kManagePerms.any(can);

  // Standard-Rechte für eine (neue) Rolle beim Erstbefüllen.
  List<String> _defaultPermsFor(String role) {
    switch (role) {
      case kAdminRole:
      case 'Büro':
      case 'Büro/Buchhaltung':
        return kPerms.keys.toList();
      case 'Meister':
        return ['exportDocs', 'editProjects', 'deleteProjects'];
      default: // Handwerker, Baustelle, neue Rollen
        return [];
    }
  }

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    gDark.value = _p.getBool('darkMode') ?? false;

    await _repo.init();
    final loaded = await _repo.load();
    final ok = loaded != null;
    _data = loaded ?? _seed();
    if (users.isEmpty) _data.users = _defaultUsers();

    // Einmalige Migration: einen Administrator-Benutzer sicherstellen
    var changed = false;
    if (!_data.adminSeeded) {
      if (!users.any((u) => u.role == kAdminRole)) {
        users.add(AppUser(
            id: uid(), name: 'Administrator', role: kAdminRole, pin: '0000'));
      }
      _data.adminSeeded = true;
      changed = true;
    }
    // Einmalige Migration: alte Rollennamen auf das neue Rollen-Set abbilden.
    if (!_data.rolesMigrated) {
      for (final u in users) {
        final mapped = kRoleRename[u.role];
        if (mapped != null) u.role = mapped;
      }
      _data.roles = List.of(defaultRollen);
      _data.rolesMigrated = true;
      changed = true;
    }
    // Sicherstellen: jede benutzte Rolle existiert und hat einen Rechte-Eintrag.
    for (final u in users) {
      if (!roles.contains(u.role)) roles.add(u.role);
    }
    for (final r in roles) {
      if (!rolePerms.containsKey(r)) {
        rolePerms[r] = _defaultPermsFor(r);
        changed = true;
      }
    }

    // Erstbefüllung und Migrationen in *einem* Schreibvorgang festhalten.
    // Frisch geseedete Daten müssen unbedingt mit: `_seed()` setzt selbst
    // `adminSeeded` und `rolesMigrated` und füllt `rolePerms` – ohne das
    // `!ok` griffe keine der Bedingungen, und es landete nie etwas auf der
    // Platte. Folge wäre bei jedem Start eine neue Auftrags-Id, während die
    // Zeiterfassung ihre Sitzung sehr wohl behält.
    if (!ok || changed) await _repo.replaceAll(_data);

    // Die selbstgebaute Sitzung ist abgelöst. Der alte Eintrag wird einmalig
    // entfernt, damit nach einem Abmelden nichts zurückbleibt, das aussieht,
    // als wäre noch jemand angemeldet.
    await _p.remove(_skey);
  }

  // ---------------------------------------------------------------------
  // Anmeldung
  // ---------------------------------------------------------------------

  /// Hört auf den Anmeldezustand. Einmal beim App-Start aufgerufen.
  ///
  /// Ein zweiter Aufruf hört neu hin statt einen zweiten Empfänger anzuhängen –
  /// so kann ein Test eine eigene Anmeldung einsetzen, ohne dass die alte
  /// weiterläuft.
  void watchAuth() {
    _authSub?.cancel();
    _authSub = auth.changes().listen(_onAccount, onError: (Object e) {
      // Kein Netz oder kaputte Konfiguration: dann eben nicht angemeldet.
      // Blockieren darf das den Start nicht.
      debugPrint('Anmeldezustand nicht lesbar: $e');
      authReady = true;
      notifyListeners();
    });
  }

  /// Übernimmt ein angemeldetes Konto in den lokalen Bestand.
  ///
  /// Zu jedem Konto gehört ein [AppUser] mit **derselben** Kennung – daran
  /// hängen Stundenlohn, Zeiterfassung und die Zuordnung erfasster Stunden.
  /// Fehlt er (frisches Gerät, neu angelegtes Konto), wird er hier angelegt.
  /// Name und Rolle kommen dabei vom Server: dort stehen sie verbindlich, in
  /// der App nur zur Anzeige.
  void _onAccount(Account? account) {
    authReady = true;

    if (account == null) {
      sessionId = null;
      notifyListeners();
      return;
    }

    sessionId = account.uid;
    final name = account.name.trim().isNotEmpty
        ? account.name.trim()
        : account.email.split('@').first;

    final i = users.indexWhere((u) => u.id == account.uid);
    if (i < 0) {
      final neu = AppUser(
        id: account.uid,
        name: name,
        role: account.role,
        email: account.email,
      );
      users.add(neu);
      _sicherstellenRolleBekannt(neu.role);
      saveUser(neu);
    } else {
      final u = users[i];
      final geaendert =
          u.name != name || u.email != account.email || u.role != account.role;
      u.name = name;
      u.email = account.email;
      // Leere Rolle heißt „Server hat (noch) keine": den lokalen Stand dann
      // nicht überschreiben, sonst verliert ein Administrator im Funkloch
      // seine Rechte, nur weil das Token nicht erneuert werden konnte.
      if (account.role.isNotEmpty) u.role = account.role;
      _sicherstellenRolleBekannt(u.role);
      if (geaendert) saveUser(u);
    }
    notifyListeners();
  }

  /// Eine vom Server vergebene Rolle kann in dieser Installation unbekannt
  /// sein. Dann wird sie aufgenommen, damit Rechte-Ansicht und Auswahllisten
  /// sie zeigen.
  void _sicherstellenRolleBekannt(String role) {
    if (role.isEmpty || roles.contains(role)) return;
    roles.add(role);
    rolePerms[role] = _defaultPermsFor(role);
    _write(_repo.saveSettings());
  }

  // ---------------------------------------------------------------------
  // Speichern
  //
  // Je Datensatz statt „alles". Für SharedPreferences läuft es zwar weiterhin
  // auf einen einzigen Schreibvorgang hinaus, aber die Aufrufer sagen jetzt,
  // *was* sich geändert hat – und genau das braucht ein Backend, damit nicht
  // jede Kleinigkeit den ganzen Bestand überschreibt (und dabei die Änderungen
  // der Kollegen mit).
  // ---------------------------------------------------------------------

  void saveProject(Project p) => _write(_repo.saveProject(p));
  void removeProject(String id) => _write(_repo.deleteProject(id));

  void saveCustomer(Customer c) => _write(_repo.saveCustomer(c));
  void removeCustomer(String id) => _write(_repo.deleteCustomer(id));

  void saveUser(AppUser u) => _write(_repo.saveUser(u));
  void removeUser(String id) => _write(_repo.deleteUser(id));

  void saveCatalogItem(CatalogItem c) => _write(_repo.saveCatalogItem(c));
  void removeCatalogItem(String id) => _write(_repo.deleteCatalogItem(id));

  void savePauschale(Pauschale p) => _write(_repo.savePauschale(p));
  void removePauschale(String id) => _write(_repo.deletePauschale(id));

  /// Kategorien, Rollen und Rechte – Listen ohne eigene Id.
  void saveSettings() => _write(_repo.saveSettings());

  /// Gemeinsamer Abschluss: Oberfläche sofort auffrischen, Schreibfehler
  /// protokollieren statt die Bedienung zu blockieren. Der Bestand im Speicher
  /// ist bereits geändert – ein fehlgeschlagener Schreibvorgang darf die
  /// Anzeige nicht zurückwerfen.
  void _write(Future<void> op) {
    notifyListeners();
    op.catchError((Object e, StackTrace st) {
      debugPrint('Stammdaten konnten nicht gespeichert werden: $e\n$st');
    });
  }

  void setDarkMode(bool v) {
    gDark.value = v;
    _p.setBool('darkMode', v);
  }

  List<CatalogItem> _defaultCatalog() => [
        CatalogItem(id: uid(), name: 'Beton C25/30', unit: 'm³', price: 115),
        CatalogItem(id: uid(), name: 'Baustahl', unit: 'kg', price: 1.2),
        CatalogItem(id: uid(), name: 'Mauerstein', unit: 'Stk', price: 0.85),
        CatalogItem(
            id: uid(), name: 'Dämmplatte 100mm', unit: 'm²', price: 18.5),
        CatalogItem(id: uid(), name: 'Estrich', unit: 'm²', price: 22),
      ];

  List<AppUser> _defaultUsers() => [
        AppUser(
            id: uid(),
            name: 'Administrator',
            role: 'Administrator',
            pin: '0000'),
        AppUser(
            id: uid(),
            name: 'Bauleiter',
            role: 'Meister',
            pin: '1111',
            wage: 60),
        AppUser(id: uid(), name: 'Büro', role: 'Büro', pin: '2222'),
        AppUser(
            id: uid(),
            name: 'Max M.',
            role: 'Handwerker',
            pin: '3333',
            wage: 45),
      ];

  Map<String, List<String>> _defaultRolePerms() =>
      {for (final r in defaultRollen) r: _defaultPermsFor(r)};

  List<Pauschale> _defaultPauschalen() => [
        Pauschale(id: uid(), name: 'Anfahrtspauschale', amount: 50),
        Pauschale(id: uid(), name: 'Kleinmaterial', amount: 30),
      ];

  /// Beispieldaten für den allerersten Start. Liefert den fertigen Bestand,
  /// statt Felder zu setzen – so kann [load] ihn unverändert übernehmen.
  MasterData _seed() {
    final kunde = Customer(
        id: uid(),
        name: 'Familie Müller',
        address: 'Müllerstr. 12, Speyer',
        contact: '0621 123456');
    final projekte = [
      Project(
        id: uid(),
        name: 'Neubau Müllerstr. 12',
        type: 'Neubau',
        address: 'Müllerstr. 12, Speyer',
        status: 'active',
        customerId: kunde.id,
        date: today(),
        hours: [
          WorkHours(
              id: uid(),
              worker: 'Max M.',
              date: today(),
              h: 8,
              task: 'Mauern EG',
              synced: true),
        ],
        materials: [
          MaterialItem(
              id: uid(),
              name: 'Beton C25/30',
              unit: 'm³',
              date: today(),
              qty: 12,
              price: 115,
              synced: true),
        ],
        tasks: [
          Task(id: uid(), title: 'Fundament gießen', due: '', done: true),
          Task(id: uid(), title: 'Estrich verlegen', due: '', done: false),
        ],
      ),
    ];

    return MasterData(
      catalog: _defaultCatalog(),
      customers: [kunde],
      pauschalen: _defaultPauschalen(),
      projects: projekte,
      users: _defaultUsers(),
      arten: List.of(defaultArten),
      roles: List.of(defaultRollen),
      rolePerms: _defaultRolePerms(),
      online: true,
      adminSeeded: true,
      rolesMigrated: true,
    );
  }

  /// Abmelden. Der Rest läuft über [_onAccount], sobald Firebase die Änderung
  /// meldet – deshalb wird hier nichts von Hand zurückgesetzt.
  Future<void> logout() => auth.signOut();

  Project? projectById(String id) {
    for (final p in projects) {
      if (p.id == id) return p;
    }
    return null;
  }

  Customer? customerById(String id) {
    if (id.isEmpty) return null;
    for (final c in customers) {
      if (c.id == id) return c;
    }
    return null;
  }
}

double sumHours(Project p) => p.hours.fold(0.0, (a, h) => a + h.h);
double sumMaterial(Project p) =>
    p.materials.fold(0.0, (a, m) => a + m.qty * m.price);
int pending(Project p) =>
    p.hours.where((h) => !h.synced).length +
    p.materials.where((m) => !m.synced).length;

// Warn-/Amber-Ton (Fälligkeit bald, offene Mängel) – ergänzt die Kernpalette.
Color get kWarn => _pick(0xFFB4791A, 0xFFE0A94A); // Warnung / bald fällig

// Stabile Farbzuordnung je Gewerk (Kategorien sind frei benennbar) – gleiche
// Kategorie bekommt immer dieselbe Farbe (Summe der Zeichencodes → Palette).
const _tradePalette = <Color>[
  Color(0xFF2166B8), // Blau
  Color(0xFFB07914), // Ocker
  Color(0xFFBB562A), // Orange
  Color(0xFF6D46C4), // Violett
  Color(0xFF0E7C86), // Petrol
  Color(0xFF1E9E63), // Grün
  Color(0xFFC0468A), // Magenta
  Color(0xFF4653C4), // Indigo
];
Color tradeColor(String type) {
  if (type.isEmpty) return kMuted;
  final h = type.codeUnits.fold<int>(0, (a, c) => a + c);
  return _tradePalette[h % _tradePalette.length];
}

// ===================================================================
// App
// ===================================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initFirebase();
  await Store.I.load();
  // Nach load(): der Anmeldezustand trägt einen Benutzer in den Bestand ein
  // und braucht ihn deshalb bereits geladen. Bewusst nicht abgewartet – die
  // Oberfläche zeigt so lange den Ladezustand, statt den Start zu verzögern.
  Store.I.watchAuth();
  // Stellt einen laufenden Timer nach App-Neustart oder OS-Kill wieder her.
  await initTimeTracking();
  runApp(const BauDocApp());
}

/// Grundverbindung zum Firebase-Projekt. Muss vor allem anderen stehen, weil
/// Anmeldung und Datenbank später darauf aufbauen.
///
/// Fehler werden geschluckt – wie bei [initTimeTracking]: die App muss auch
/// ohne Netz oder mit kaputter Konfiguration starten, sonst kommt der Monteur
/// auf der Baustelle nicht an seine Aufträge. Solange die Daten lokal liegen,
/// ist der Betrieb davon ohnehin nicht betroffen.
Future<void> _initFirebase() async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e, st) {
    debugPrint('Firebase konnte nicht starten: $e\n$st');
  }
}

class BauDocApp extends StatelessWidget {
  const BauDocApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: gDark,
      builder: (context, dark, _) {
        final base = ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
          useMaterial3: true,
        );
        return MaterialApp(
          title: 'BauDoc',
          debugShowCheckedModeBanner: false,
          theme: base.copyWith(
            scaffoldBackgroundColor: kBg,
            colorScheme: base.colorScheme.copyWith(
              primary: kAccent,
              secondary: kAccent,
              surface: kCard,
              onSurface: kInk,
              error: kRed,
            ),
            textTheme: base.textTheme.apply(
                bodyColor: kInk,
                displayColor: kInk,
                fontFamilyFallback: const [
                  'Segoe UI',
                  'Roboto',
                  'Helvetica',
                  'Arial'
                ]),
            cardColor: kCard,
            cardTheme: CardThemeData(
              color: kCard,
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: kLine)),
            ),
            dividerTheme: DividerThemeData(color: kLine, thickness: 1),
            appBarTheme: AppBarTheme(
              backgroundColor: kBg2,
              foregroundColor: kInk,
              elevation: 0,
              scrolledUnderElevation: 0.5,
              surfaceTintColor: Colors.transparent,
              shadowColor: const Color(0x14000000),
              centerTitle: false,
              titleTextStyle: TextStyle(
                  color: kInk,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.2),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: kAccentInk,
                elevation: 0,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                textStyle:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
            floatingActionButtonTheme: FloatingActionButtonThemeData(
              backgroundColor: kAccent,
              foregroundColor: kAccentInk,
              elevation: 2,
            ),
            chipTheme: base.chipTheme.copyWith(
              backgroundColor: kCard2,
              side: BorderSide(color: kLine),
              labelStyle: TextStyle(color: kInk2, fontSize: 13),
            ),
            snackBarTheme: SnackBarThemeData(
              backgroundColor: kInk,
              contentTextStyle: const TextStyle(color: Colors.white),
              behavior: SnackBarBehavior.floating,
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: kCard2,
              hintStyle: TextStyle(color: kMuted),
              labelStyle: TextStyle(color: kMuted),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: kLine)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: kLine)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: kAccent, width: 1.6)),
            ),
          ),
          home: const RootGate(),
        );
      },
    );
  }
}

class RootGate extends StatelessWidget {
  const RootGate({super.key});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.I,
      builder: (_, __) {
        final s = Store.I;
        // Solange Firebase die gespeicherte Sitzung wiederherstellt, ist noch
        // nicht entschieden, wer angemeldet ist. Ohne diesen Zwischenschritt
        // sähe der Benutzer bei jedem Start kurz den Anmeldebildschirm.
        if (!s.authReady) return const _StartingScreen();
        if (s.currentUser == null) return const LoginScreen();
        // Konto vorhanden, aber ohne Rolle: die App wäre bedienbar und doch
        // überall leer. Lieber ehrlich sagen, woran es liegt.
        if (s.awaitingRole) return const _NoRoleScreen();
        return const HomeScreen();
      },
    );
  }
}

/// Ladezustand beim Start – bewusst schlicht und ohne Text, er ist meist nur
/// Sekundenbruchteile zu sehen.
class _StartingScreen extends StatelessWidget {
  const _StartingScreen();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(child: CircularProgressIndicator(color: kAccent)),
      );
}

/// Angemeldet, aber dem Konto wurde keine Rolle zugewiesen.
class _NoRoleScreen extends StatelessWidget {
  const _NoRoleScreen();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.hourglass_empty, size: 48, color: kMuted),
                  const SizedBox(height: 16),
                  const Text('Noch keine Rolle zugewiesen',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(
                    'Dein Konto ist angelegt, aber es fehlt die Zuordnung zu '
                    'einer Rolle. Die Verwaltung kann sie eintragen.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kMuted, height: 1.4),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton(
                    onPressed: () => Store.I.logout(),
                    child: const Text('Abmelden'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- Login ----------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  String? error;
  bool busy = false;
  bool showPassword = false;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  /// Anmelden. Bei Erfolg passiert hier nichts weiter – [RootGate] wechselt
  /// den Bildschirm, sobald Firebase den neuen Zustand meldet.
  Future<void> _doLogin() async {
    if (busy) return;
    if (email.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => error = 'Bitte E-Mail-Adresse und Passwort eingeben.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Store.I.auth
          .signIn(email: email.text, password: password.text);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _resetPassword() async {
    final adresse = email.text.trim();
    if (adresse.isEmpty) {
      setState(() => error =
          'Bitte zuerst die E-Mail-Adresse eintragen, dann erneut tippen.');
      return;
    }
    try {
      await Store.I.auth.sendPasswordReset(adresse);
      if (!mounted) return;
      snack(context, 'E-Mail zum Zurücksetzen wurde an $adresse geschickt.');
    } on AuthFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  void _openSetup() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const _SetupScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(20),
              shrinkWrap: true,
              children: [
                const SizedBox(height: 32),
                Center(
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                        color: kAccent,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                              color: kAccent.withValues(alpha: .28),
                              blurRadius: 18,
                              offset: const Offset(0, 8))
                        ]),
                    child: Icon(Icons.apartment, color: kAccentInk, size: 36),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('BauDoc',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.5)),
                const SizedBox(height: 4),
                Text('Baustellen- & Auftragsdokumentation',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kMuted, fontSize: 14)),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Anmeldung',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 16),
                        Text('E-Mail',
                            style: TextStyle(color: kMuted, fontSize: 13)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: email,
                          enabled: !busy,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          autofillHints: const [AutofillHints.username],
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                              hintText: 'name@betrieb.de'),
                        ),
                        const SizedBox(height: 12),
                        Text('Passwort',
                            style: TextStyle(color: kMuted, fontSize: 13)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: password,
                          enabled: !busy,
                          obscureText: !showPassword,
                          autofillHints: const [AutofillHints.password],
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _doLogin(),
                          decoration: InputDecoration(
                            hintText: '••••••',
                            // Auf der Baustelle wird mit Handschuhen getippt –
                            // ohne Sichtbarkeitsschalter wird das mühsam.
                            suffixIcon: IconButton(
                              icon: Icon(
                                  showPassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: kMuted),
                              onPressed: () =>
                                  setState(() => showPassword = !showPassword),
                            ),
                          ),
                        ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(error!,
                                style: TextStyle(color: kRed, fontSize: 13)),
                          ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: kAccent,
                                foregroundColor: kAccentInk),
                            onPressed: busy ? null : _doLogin,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: busy
                                  ? SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: kAccentInk),
                                    )
                                  : const Text('Anmelden'),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: busy ? null : _resetPassword,
                            child: const Text('Passwort vergessen?'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Nur für eine frische Installation gedacht. Steht bewusst
                // sichtbar da: sonst findet niemand den Weg zum ersten Konto.
                // Der Server lässt den Aufruf genau einmal zu.
                Center(
                  child: TextButton.icon(
                    onPressed: busy ? null : _openSetup,
                    icon: Icon(Icons.settings_outlined, size: 18, color: kMuted),
                    label: Text('Ersteinrichtung',
                        style: TextStyle(color: kMuted)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Legt das erste Administrator-Konto an.
///
/// Nur bei einer frischen Installation nutzbar: der Server verweigert den
/// Aufruf, sobald irgendwo ein Administrator existiert. Deshalb steht hier auch
/// keine Rechteprüfung – zu diesem Zeitpunkt gibt es niemanden, der prüfen
/// könnte.
class _SetupScreen extends StatefulWidget {
  const _SetupScreen();
  @override
  State<_SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<_SetupScreen> {
  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  final repeat = TextEditingController();
  String? error;
  bool busy = false;

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    password.dispose();
    repeat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (busy) return;
    if (name.text.trim().isEmpty || email.text.trim().isEmpty) {
      setState(() => error = 'Name und E-Mail-Adresse werden gebraucht.');
      return;
    }
    if (password.text.length < 6) {
      setState(() => error = 'Das Passwort muss mindestens 6 Zeichen haben.');
      return;
    }
    if (password.text != repeat.text) {
      setState(() => error = 'Die beiden Passwörter stimmen nicht überein.');
      return;
    }

    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Store.I.auth.bootstrapAdmin(
        email: email.text,
        password: password.text,
        name: name.text,
      );
      // Das Konto steht auf dem Server – anmelden muss sich das Gerät noch
      // selbst. Danach übernimmt RootGate.
      await Store.I.auth.signIn(email: email.text, password: password.text);
      if (mounted) Navigator.of(context).pop();
    } on AuthFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ersteinrichtung')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(20),
              shrinkWrap: true,
              children: [
                Text(
                  'Hiermit wird das erste Administrator-Konto angelegt. '
                  'Alle weiteren Benutzer legt danach die Verwaltung in der '
                  'App an.',
                  style: TextStyle(color: kMuted, height: 1.4),
                ),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _feld('Name', name,
                            hint: 'Vor- und Nachname', enabled: !busy),
                        const SizedBox(height: 12),
                        _feld('E-Mail', email,
                            hint: 'name@betrieb.de',
                            enabled: !busy,
                            typ: TextInputType.emailAddress),
                        const SizedBox(height: 12),
                        _feld('Passwort', password,
                            hint: 'mindestens 6 Zeichen',
                            enabled: !busy,
                            geheim: true),
                        const SizedBox(height: 12),
                        _feld('Passwort wiederholen', repeat,
                            enabled: !busy, geheim: true),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(error!,
                                style: TextStyle(color: kRed, fontSize: 13)),
                          ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: kAccent,
                                foregroundColor: kAccentInk),
                            onPressed: busy ? null : _submit,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: busy
                                  ? SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: kAccentInk),
                                    )
                                  : const Text('Konto anlegen'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _feld(String label, TextEditingController c,
      {String? hint,
      bool geheim = false,
      bool enabled = true,
      TextInputType? typ}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: kMuted, fontSize: 13)),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          enabled: enabled,
          obscureText: geheim,
          autocorrect: false,
          keyboardType: typ,
          decoration: InputDecoration(hintText: hint),
        ),
      ],
    );
  }
}

// ---------- Home / Aufträge ----------
typedef _HomeData = ({
  List<Project> list,
  int openN,
  int doneN,
  int tabCount,
  List<String> chipCats,
  int Function(String) countFor,
  int overdue,
  int openDefects,
  int dueWeek,
});

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String tab = 'offen';
  String? filter;
  String query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Store.I;
    final wide = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      appBar: wide
          ? null
          : AppBar(
              leading: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: GestureDetector(
                  onTap: () => showProfileSheet(context),
                  child: Center(
                    child: CircleAvatar(
                      radius: 17,
                      backgroundColor: kAccent,
                      child: Text(initials(s.currentUser?.name ?? '?'),
                          style: TextStyle(
                              color: kAccentInk,
                              fontWeight: FontWeight.w800,
                              fontSize: 13)),
                    ),
                  ),
                ),
              ),
              title: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Aufträge',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                  Text('Alle laufenden Baustellen',
                      style: TextStyle(
                          fontWeight: FontWeight.w400,
                          fontSize: 11.5,
                          color: kMuted,
                          height: 1.1)),
                ],
              ),
            ),
      floatingActionButton: (!wide && Store.I.can('editProjects'))
          ? FloatingActionButton(
              backgroundColor: kAccent,
              foregroundColor: kAccentInk,
              onPressed: () => showProjectForm(context),
              child: const Icon(Icons.add),
            )
          : null,
      body: AnimatedBuilder(
        animation: s,
        builder: (_, __) {
          final openN = s.projects.where((p) => p.isOpen).length;
          final doneN = s.projects.length - openN;
          var list = s.projects
              .where((p) => tab == 'offen' ? p.isOpen : !p.isOpen)
              .toList();
          if (filter != null) {
            list = list.where((p) => p.type == filter).toList();
          }
          if (query.trim().isNotEmpty) {
            final q = query.trim().toLowerCase();
            list = list
                .where((p) =>
                    p.name.toLowerCase().contains(q) ||
                    p.address.toLowerCase().contains(q))
                .toList();
          }
          // neueste zuerst (leeres Datum ans Ende)
          list.sort((a, b) => b.date.compareTo(a.date));

          // Anzahl je Gewerk im aktuellen Tab (offen bzw. abgeschlossen)
          final tabProjects =
              s.projects.where((p) => tab == 'offen' ? p.isOpen : !p.isOpen);
          int countFor(String t) =>
              tabProjects.where((p) => p.type == t).length;
          // Chips nur für Kategorien, die im aktuellen Tab vorkommen –
          // Store-Reihenfolge zuerst, unbekannte Typen (z. B. gelöschte
          // Kategorie, aber noch am Auftrag) hinten angehängt.
          final present =
              tabProjects.map((p) => p.type).where((t) => t.isNotEmpty).toSet();
          final chipCats = <String>[
            ...s.arten.where(present.contains),
            ...present.where((t) => !s.arten.contains(t)),
          ];

          // Kennzahlen über alle Aufträge (nicht nur aktueller Tab)
          final overdue =
              s.projects.where((p) => p.isOpen && _isOverdue(p)).length;
          final openDefects = s.projects.where((p) => p.isOpen).fold<int>(
              0, (a, p) => a + p.defects.where((d) => !d.done).length);
          final dueWeek = s.projects.where((p) {
            if (!p.isOpen) return false;
            final d = _dueDays(p);
            return d != null && d >= 0 && d <= 7;
          }).length;

          final data = (
            list: list,
            openN: openN,
            doneN: doneN,
            tabCount: tabProjects.length,
            chipCats: chipCats,
            countFor: countFor,
            overdue: overdue,
            openDefects: openDefects,
            dueWeek: dueWeek,
          );
          if (wide) return _wideBody(context, data);
          return Column(
            children: [
              // Laufende/unbestätigte Zeiterfassung – zeigt sich nur, wenn es
              // etwas zu sehen gibt, und ist das Netz für ignorierte Pushs.
              const TrackingBanner(),
              // Kennzahlen-Strip
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                child: _statStrip(
                    active: openN,
                    overdue: overdue,
                    defects: openDefects,
                    dueWeek: dueWeek),
              ),
              // Segmented Control
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: kCard2,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kLine),
                  ),
                  child: Row(children: [
                    _tabBtn('Offen', openN, 'offen'),
                    _tabBtn('Abgeschlossen', doneN, 'done'),
                  ]),
                ),
              ),
              // Suche
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 20, color: kMuted),
                    hintText: 'Auftrag oder Kunde suchen …',
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _search.clear();
                              setState(() => query = '');
                            },
                          ),
                  ),
                ),
              ),
              // Filter-Chips: alle Gewerke, mit Farbtupfer je Kategorie
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  children: [
                    _chip('Alle', filter == null,
                        () => setState(() => filter = null),
                        count: tabProjects.length),
                    for (final t in chipCats)
                      _chip(t, filter == t, () => setState(() => filter = t),
                          count: countFor(t), swatch: tradeColor(t)),
                  ],
                ),
              ),
              Expanded(child: _buildList(list)),
            ],
          );
        },
      ),
    );
  }

  Widget _tabBtn(String label, int count, String value, {bool expand = true}) {
    final on = tab == value;
    final btn = GestureDetector(
      onTap: () => setState(() => tab = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(vertical: 9, horizontal: expand ? 0 : 16),
        decoration: BoxDecoration(
          color: on ? kCard : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          boxShadow: on
              ? [
                  BoxShadow(
                      color: kInk.withValues(alpha: .07),
                      blurRadius: 5,
                      offset: const Offset(0, 1))
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: on ? kInk : kMuted)),
            const SizedBox(width: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: (on ? kAccent : kMuted).withValues(alpha: .15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$count',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 11.5,
                      color: on ? kAccent : kMuted)),
            ),
          ],
        ),
      ),
    );
    return expand ? Expanded(child: btn) : btn;
  }

  Widget _chip(String label, bool on, VoidCallback onTap,
      {int? count, Color? swatch, bool noPad = false}) {
    final c = on ? kAccent : kInk2;
    final chip = GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: on ? kAccent.withValues(alpha: .13) : kCard,
          borderRadius: BorderRadius.circular(10),
          border:
              Border.all(color: on ? kAccent.withValues(alpha: .55) : kLine),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (swatch != null) ...[
              Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: swatch, shape: BoxShape.circle)),
              const SizedBox(width: 7),
            ],
            Text(label,
                style: TextStyle(
                    color: c, fontSize: 12.5, fontWeight: FontWeight.w600)),
            if (count != null) ...[
              const SizedBox(width: 6),
              Text('$count',
                  style: TextStyle(
                      color: c.withValues(alpha: .7),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
    );
    return noPad
        ? chip
        : Padding(padding: const EdgeInsets.only(right: 8), child: chip);
  }

  Widget _buildList(List<Project> list) {
    if (list.isEmpty) {
      final msg = filter != null
          ? 'Keine „$filter"-Aufträge unter ${tab == 'offen' ? 'Offen' : 'Abgeschlossen'}.'
          : (tab == 'offen'
              ? 'Es sind keine offenen Aufträge vorhanden.\nMit „+" legen Sie einen neuen Auftrag an.'
              : 'Es liegen noch keine abgeschlossenen Aufträge vor.');
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                    color: kCard2,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: kLine)),
                child: Icon(Icons.apartment_outlined, color: kMuted, size: 30),
              ),
              const SizedBox(height: 16),
              Text(msg,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kMuted, fontSize: 14, height: 1.5)),
            ],
          ),
        ),
      );
    }
    // Flache Liste dichter Auftragskarten (Gewerk steckt jetzt im Badge).
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 90),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _jobCard(list[i]),
    );
  }

  // ===== Breite / Desktop-Ansicht (Layout wie Mockup) =====
  Widget _wideBody(BuildContext context, _HomeData d) {
    return Column(
      children: [
        _topBar(context, d),
        const TrackingBanner(),
        Expanded(
          child: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1140),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 64),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _pageHeader(context),
                      const SizedBox(height: 20),
                      _statCards(d),
                      const SizedBox(height: 22),
                      _wideToolbar(d),
                      const SizedBox(height: 16),
                      if (d.list.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 40),
                          child: _emptyState(),
                        )
                      else
                        for (final p in d.list)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _jobCard(p),
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _topBar(BuildContext context, _HomeData d) {
    final u = Store.I.currentUser;
    return Container(
      decoration: BoxDecoration(
        color: kBg2,
        border: Border(bottom: BorderSide(color: kLine)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1140),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [kAccent, const Color(0xFF0B646C)],
                    ),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(Icons.apartment, size: 18, color: kAccentInk),
                ),
                const SizedBox(width: 10),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('BauDoc',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            letterSpacing: -.2)),
                    Text('Baustellendoku',
                        style: TextStyle(
                            fontSize: 10.5, color: kMuted, height: 1)),
                  ],
                ),
                const SizedBox(width: 22),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: _topSearch(),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                PopupMenuButton<String?>(
                  tooltip: 'Nach Gewerk filtern',
                  position: PopupMenuPosition.under,
                  onSelected: (v) => setState(() => filter = v),
                  itemBuilder: (_) => <PopupMenuEntry<String?>>[
                    const PopupMenuItem<String?>(
                        value: null, child: Text('Alle Gewerke')),
                    for (final t in d.chipCats)
                      PopupMenuItem<String?>(value: t, child: Text(t)),
                  ],
                  child: _iconBox(Icons.tune),
                ),
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(11),
                  onTap: () => showProfileSheet(context),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
                    decoration: BoxDecoration(
                      color: kCard2,
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: kLine),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: kAccent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(initials(u?.name ?? '?'),
                              style: TextStyle(
                                  color: kAccentInk,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13)),
                        ),
                        const SizedBox(width: 9),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(u?.name ?? 'Konto',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 13)),
                            Text(u?.role ?? '',
                                style: TextStyle(
                                    fontSize: 11, color: kMuted, height: 1)),
                          ],
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.keyboard_arrow_down,
                            size: 18, color: kMuted),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topSearch() => SizedBox(
        height: 38,
        child: TextField(
          controller: _search,
          onChanged: (v) => setState(() => query = v),
          style: const TextStyle(fontSize: 13.5),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: kCard2,
            contentPadding:
                const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
            prefixIcon: Icon(Icons.search, size: 18, color: kMuted),
            hintText: 'Aufträge, Kunden, Adressen durchsuchen …',
            hintStyle: TextStyle(fontSize: 13, color: kMuted),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: kLine),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: kAccent, width: 1.4),
            ),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () {
                      _search.clear();
                      setState(() => query = '');
                    },
                  ),
          ),
        ),
      );

  Widget _iconBox(IconData ic) => Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: kCard2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kLine),
        ),
        child: Icon(ic, size: 18, color: kInk2),
      );

  Widget _pageHeader(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Aufträge',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                        letterSpacing: -.5)),
                const SizedBox(height: 3),
                Text('Übersicht aller laufenden Baustellen und Projekte',
                    style: TextStyle(fontSize: 13.5, color: kInk2)),
              ],
            ),
          ),
          if (Store.I.can('editProjects'))
            _primaryBtn(
                'Neuer Auftrag', Icons.add, () => showProjectForm(context)),
        ],
      );

  Widget _primaryBtn(String label, IconData ic, VoidCallback onTap) => Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [kAccent, const Color(0xFF0B646C)],
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                    color: kAccent.withValues(alpha: .25),
                    blurRadius: 8,
                    offset: const Offset(0, 2)),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(ic, size: 18, color: kAccentInk),
                const SizedBox(width: 8),
                Text(label,
                    style: TextStyle(
                        color: kAccentInk,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5)),
              ],
            ),
          ),
        ),
      );

  // IntrinsicHeight ist nötig, weil die Karten via CrossAxisAlignment.stretch
  // gleich hoch sein sollen, der Strip aber in einem SingleChildScrollView
  // sitzt – dort ist die Höhe unbegrenzt und "stretch" allein würde eine
  // unendliche Höhe erzwingen.
  Widget _statCards(_HomeData d) => IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
                child: _statCard(Icons.apartment, '${d.openN}', 'Aktiv',
                    'Aufträge in Bearbeitung', kAccent)),
            const SizedBox(width: 12),
            Expanded(
                child: _statCard(
                    Icons.error_outline,
                    '${d.overdue}',
                    'Überfällig',
                    d.overdue > 0 ? 'Sofort handeln' : 'Alles im Plan',
                    kRed,
                    tint: d.overdue > 0)),
            const SizedBox(width: 12),
            Expanded(
                child: _statCard(
                    Icons.warning_amber_rounded,
                    '${d.openDefects}',
                    'Offene Mängel',
                    d.openDefects > 0 ? 'Zu beheben' : 'Keine offen',
                    kWarn,
                    tint: d.openDefects > 0)),
            const SizedBox(width: 12),
            Expanded(
                child: _statCard(Icons.event, '${d.dueWeek}', 'Diese Woche',
                    'fällig bis Sonntag', kBlue)),
          ],
        ),
      );

  Widget _statCard(IconData ic, String value, String label, String sub, Color c,
          {bool tint = false}) =>
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(label.toUpperCase(),
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: .4,
                            color: kMuted)),
                  ),
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                        color: c.withValues(alpha: .13),
                        borderRadius: BorderRadius.circular(9)),
                    child: Icon(ic, size: 16, color: c),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(value,
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.5,
                      height: 1,
                      color: tint ? c : kInk)),
              const SizedBox(height: 5),
              Text(sub,
                  style: TextStyle(
                      fontSize: 12,
                      color: tint ? c : kInk2,
                      fontWeight: tint ? FontWeight.w600 : FontWeight.w400)),
            ],
          ),
        ),
      );

  Widget _wideToolbar(_HomeData d) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: kCard2,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: kLine),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _tabBtn('Offen', d.openN, 'offen', expand: false),
              _tabBtn('Abgeschlossen', d.doneN, 'done', expand: false),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip(
                    'Alle', filter == null, () => setState(() => filter = null),
                    count: d.tabCount, noPad: true),
                for (final t in d.chipCats)
                  _chip(t, filter == t, () => setState(() => filter = t),
                      count: d.countFor(t), swatch: tradeColor(t), noPad: true),
              ],
            ),
          ),
        ],
      );

  String _ref(Project p) => '#${1000 + p.id.hashCode.abs() % 9000}';

  Widget _emptyState() {
    final msg = filter != null
        ? 'Keine „$filter"-Aufträge unter ${tab == 'offen' ? 'Offen' : 'Abgeschlossen'}.'
        : (tab == 'offen'
            ? 'Es sind keine offenen Aufträge vorhanden.\nMit „Neuer Auftrag" legen Sie einen neuen an.'
            : 'Es liegen noch keine abgeschlossenen Aufträge vor.');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                  color: kCard2,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: kLine)),
              child: Icon(Icons.apartment_outlined, color: kMuted, size: 30),
            ),
            const SizedBox(height: 16),
            Text(msg,
                textAlign: TextAlign.center,
                style: TextStyle(color: kMuted, fontSize: 14, height: 1.5)),
          ],
        ),
      ),
    );
  }

  // ---------- Auftragskarte ----------
  Widget _jobCard(Project p) {
    final tc = tradeColor(p.type);
    final doneT = p.tasks.where((t) => t.done).length;
    final totT = p.tasks.length;
    final openDef = p.defects.where((d) => !d.done).length;
    final h = sumHours(p);
    final mat = sumMaterial(p);

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => ProjectScreen(projectId: p.id))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Kopf: Gewerk-Badge + Fälligkeit
              Row(children: [
                if (p.type.isNotEmpty) Flexible(child: _tradeBadge(p.type, tc)),
                const SizedBox(width: 8),
                Text(_ref(p),
                    style: TextStyle(
                        fontSize: 12,
                        color: kMuted,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                _duePill(p),
              ]),
              const SizedBox(height: 11),
              // Titel + Kunde/Adresse + Quick-Action
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15.5,
                                letterSpacing: -.2)),
                        const SizedBox(height: 3),
                        _subline(p),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _quickAction(p),
                ],
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: kLine),
              const SizedBox(height: 11),
              // Fuß: Fortschritt + Mängel + Stunden + Material
              Wrap(
                spacing: 16,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _progress(doneT, totT),
                  if (openDef > 0)
                    _meta(Icons.warning_amber_rounded,
                        '$openDef ${openDef == 1 ? 'Mangel' : 'Mängel'}', kRed)
                  else
                    _meta(Icons.check_circle_outline, 'Keine Mängel', kGreen),
                  _meta(Icons.schedule,
                      h > 0 ? '${_hrs(h)} h' : 'Nicht gestartet', kMuted,
                      strong: h > 0),
                  if (mat > 0)
                    _meta(Icons.inventory_2_outlined, eur(mat), kMuted,
                        strong: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tradeBadge(String type, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: c.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: c.withValues(alpha: .28)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(type,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: c, fontSize: 11.5, fontWeight: FontWeight.w800)),
          ),
        ]),
      );

  Widget _duePill(Project p) {
    if (!p.isOpen) return _pill(Icons.check, 'Abgeschlossen', kGreen);
    final days = _dueDays(p);
    if (days == null) {
      return _pill(Icons.event_outlined, 'Kein Termin', kMuted, subtle: true);
    }
    if (days < 0) {
      final d = -days;
      return _pill(Icons.error_outline,
          d == 1 ? '1 Tag überfällig' : '$d Tage überfällig', kRed);
    }
    if (days <= 7) {
      return _pill(Icons.event_outlined, 'Fällig ${dShort(p.due)}', kWarn);
    }
    return _pill(Icons.event_outlined, 'Fällig ${dShort(p.due)}', kMuted,
        subtle: true);
  }

  Widget _pill(IconData ic, String label, Color c, {bool subtle = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: subtle ? kCard2 : c.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(8),
          border: subtle ? Border.all(color: kLine) : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ic, size: 13, color: subtle ? kMuted : c),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  color: subtle ? kInk2 : c,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _subline(Project p) {
    final cust = Store.I.customerById(p.customerId)?.name;
    final txt = [
      if (cust != null && cust.isNotEmpty) cust,
      if (p.address.isNotEmpty) p.address,
    ].join('  ·  ');
    if (txt.isEmpty) return const SizedBox.shrink();
    return Row(children: [
      Icon(Icons.place_outlined, size: 13, color: kMuted),
      const SizedBox(width: 4),
      Expanded(
        child: Text(txt,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: kMuted, fontSize: 12.5)),
      ),
    ]);
  }

  Widget _quickAction(Project p) {
    final pend = pending(p);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (pend > 0)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Icon(Icons.cloud_upload_outlined,
              size: 16, color: kAccent.withValues(alpha: .8)),
        ),
      Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: kCard2,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: kLine),
        ),
        child: Icon(Icons.chevron_right, size: 19, color: kInk2),
      ),
    ]);
  }

  Widget _progress(int done, int total) {
    if (total == 0) {
      return _meta(Icons.checklist_rtl, 'Keine Aufgaben', kMuted);
    }
    final pct = (done / total).clamp(0.0, 1.0);
    final full = done >= total;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 70,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 6,
            backgroundColor: kLine,
            valueColor: AlwaysStoppedAnimation(full ? kGreen : kAccent),
          ),
        ),
      ),
      const SizedBox(width: 9),
      Text('$done/$total Aufgaben',
          style: TextStyle(
              color: kInk2, fontSize: 12.5, fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _meta(IconData ic, String label, Color c, {bool strong = false}) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ic, size: 14, color: c),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                color: strong ? kInk2 : c,
                fontSize: 12.5,
                fontWeight: strong ? FontWeight.w700 : FontWeight.w600)),
      ]);

  // ---------- Kennzahlen-Strip ----------
  Widget _statStrip(
      {required int active,
      required int overdue,
      required int defects,
      required int dueWeek}) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          _statTile(Icons.apartment, '$active', 'Aktiv', kAccent),
          _statDiv(),
          _statTile(Icons.error_outline, '$overdue', 'Überfällig',
              overdue > 0 ? kRed : kMuted,
              tintValue: overdue > 0),
          _statDiv(),
          _statTile(Icons.warning_amber_rounded, '$defects', 'Mängel',
              defects > 0 ? kWarn : kMuted,
              tintValue: defects > 0),
          _statDiv(),
          _statTile(Icons.event, '$dueWeek', 'Diese Woche', kInk2),
        ]),
      ),
    );
  }

  Widget _statDiv() => Container(width: 1, height: 40, color: kLine);

  Widget _statTile(IconData ic, String value, String label, Color c,
          {bool tintValue = false}) =>
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Column(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                  color: c.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(ic, size: 16, color: c),
            ),
            const SizedBox(height: 7),
            Text(value,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.5,
                    color: tintValue ? c : kInk)),
            const SizedBox(height: 1),
            Text(label.toUpperCase(),
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(
                    fontSize: 9.5,
                    color: kMuted,
                    height: 1.15,
                    letterSpacing: .4,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
      );

  // Tage bis Fälligkeit (negativ = überfällig); null wenn kein Termin.
  int? _dueDays(Project p) {
    if (p.due.isEmpty) return null;
    final d = DateTime.tryParse(p.due);
    if (d == null) return null;
    final n = DateTime.now();
    return DateTime(d.year, d.month, d.day)
        .difference(DateTime(n.year, n.month, n.day))
        .inDays;
  }

  bool _isOverdue(Project p) {
    final d = _dueDays(p);
    return d != null && d < 0;
  }

  String _hrs(double h) => h.toStringAsFixed(1).replaceAll('.', ',');
}

// ---------- Auftrag-Übersicht ----------
class ProjectScreen extends StatelessWidget {
  final String projectId;
  const ProjectScreen({super.key, required this.projectId});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.I,
      builder: (_, __) {
        final p = Store.I.projectById(projectId);
        if (p == null) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => Navigator.of(context).maybePop());
          return const Scaffold(body: SizedBox.shrink());
        }
        final done = p.tasks.where((t) => t.done).length;
        final openDefects = p.defects.where((d) => !d.done).length;
        return Scaffold(
          appBar: AppBar(title: Text(p.name), actions: [
            if (Store.I.can('exportDocs'))
              IconButton(
                icon: const Icon(Icons.request_quote_outlined),
                tooltip: 'Angebot als PDF',
                onPressed: () => exportProjectQuote(context, p),
              ),
            if (Store.I.can('exportDocs'))
              IconButton(
                icon: const Icon(Icons.picture_as_pdf_outlined),
                tooltip: 'Rechnung als PDF',
                onPressed: () => exportProjectPdf(context, p),
              ),
          ]),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
            children: [
              if (p.type.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 4),
                  child: Text(p.type,
                      style: TextStyle(
                          color: kMuted,
                          fontWeight: FontWeight.w700,
                          letterSpacing: .6)),
                ),
              Row(children: [
                _stat(sumHours(p).toStringAsFixed(sumHours(p) % 1 == 0 ? 0 : 1),
                    'Stunden', kAccent),
                const SizedBox(width: 10),
                _stat(eur(sumMaterial(p)), 'Material', kInk),
                const SizedBox(width: 10),
                _stat('$done/${p.tasks.length}', 'Aufgaben', kInk),
              ]),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (Store.I.customerById(p.customerId) != null)
                    _infoChip(Icons.badge_outlined,
                        Store.I.customerById(p.customerId)!.name, kGreen),
                  if (p.date.isNotEmpty)
                    _infoChip(Icons.event, 'Start: ${dLong(p.date)}', kBlue),
                  if (p.due.isNotEmpty)
                    _infoChip(Icons.flag_outlined, 'Fällig: ${dLong(p.due)}',
                        kViolet),
                  _infoChip(
                      Icons.cloud_outlined,
                      pending(p) > 0
                          ? '${pending(p)} nicht synchronisiert'
                          : 'Alles synchronisiert',
                      pending(p) > 0 ? kAccent : kGreen),
                ],
              ),
              const SizedBox(height: 14),
              ProjectTrackingCard(project: p),
              const SizedBox(height: 4),
              Card(
                child: Column(children: [
                  _navTile(
                      context,
                      Icons.schedule,
                      kAccent,
                      'Arbeitsstunden',
                      '${sumHours(p).toStringAsFixed(sumHours(p) % 1 == 0 ? 0 : 1)} h · ${p.hours.length} Einträge',
                      () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => HoursScreen(projectId: p.id)))),
                  Divider(height: 1, color: kLine),
                  _navTile(
                      context,
                      Icons.inventory_2_outlined,
                      kBlue,
                      'Material',
                      '${eur(sumMaterial(p))} · ${p.materials.length} Posten',
                      () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  MaterialsScreen(projectId: p.id)))),
                  Divider(height: 1, color: kLine),
                  _navTile(
                      context,
                      Icons.check_circle_outline,
                      kGreen,
                      'Aufgaben',
                      '$done/${p.tasks.length} erledigt',
                      () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => TasksScreen(projectId: p.id)))),
                  Divider(height: 1, color: kLine),
                  _navTile(
                      context,
                      Icons.report_problem_outlined,
                      kRed,
                      'Mängel',
                      p.defects.isEmpty
                          ? 'Keine Mängel'
                          : '$openDefects offen · ${p.defects.length} gesamt',
                      () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => DefectsScreen(projectId: p.id)))),
                ]),
              ),
              const SizedBox(height: 14),
              const _SectionTitle('Fotos'),
              _photoStrip(context, p),
              const SizedBox(height: 14),
              Row(children: [
                const _SectionTitle('Bautagebuch'),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Eintrag'),
                  onPressed: () => showNoteForm(context, p),
                ),
              ]),
              if (p.notes.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text('Noch keine Einträge.',
                      style: TextStyle(color: kMuted)),
                )
              else
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(children: [
                    for (var i = p.notes.length - 1; i >= 0; i--) ...[
                      ListTile(
                        title: Text(p.notes[i].text),
                        subtitle: Text(
                            [
                              dLong(p.notes[i].date),
                              if (p.notes[i].weather.isNotEmpty)
                                [p.notes[i].weather, p.notes[i].temp]
                                    .where((x) => x.isNotEmpty)
                                    .join(', ')
                            ].join(' · '),
                            style: TextStyle(color: kMuted)),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline, color: kMuted),
                          onPressed: () {
                            p.notes.removeAt(i);
                            Store.I.saveProject(p);
                          },
                        ),
                      ),
                      if (i > 0) Divider(height: 1, color: kLine),
                    ],
                  ]),
                ),
              const SizedBox(height: 14),
              if (Store.I.can('editProjects'))
                OutlinedButton(
                  onPressed: () {
                    p.status = p.isOpen ? 'done' : 'active';
                    Store.I.saveProject(p);
                  },
                  child: Text(p.isOpen
                      ? 'Auftrag als abgeschlossen markieren'
                      : 'Wieder als offen setzen'),
                ),
              if (Store.I.can('deleteProjects')) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: kRed),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Auftrag löschen'),
                  onPressed: () async {
                    final ok = await confirm(context,
                        'Auftrag wirklich löschen? Alle Einträge gehen verloren.');
                    if (ok) {
                      // Der AnimatedBuilder-Guard oben schließt den Screen automatisch,
                      // sobald das Projekt entfernt ist (kein doppeltes pop).
                      Store.I.removeProject(p.id);
                    }
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _stat(String num, String lbl, Color c) => Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
            child: Column(children: [
              Text(num,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800, color: c)),
              const SizedBox(height: 4),
              Text(lbl, style: TextStyle(fontSize: 10.5, color: kMuted)),
            ]),
          ),
        ),
      );

  Widget _navTile(BuildContext c, IconData ic, Color col, String t, String s,
          VoidCallback onTap) =>
      ListTile(
        onTap: onTap,
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
              color: col.withValues(alpha: .13),
              borderRadius: BorderRadius.circular(12)),
          child: Icon(ic, color: col, size: 22),
        ),
        title: Text(t),
        subtitle: Text(s, style: TextStyle(color: kMuted)),
        trailing: Icon(Icons.chevron_right, color: kMuted),
      );

  Widget _infoChip(IconData ic, String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ic, size: 14, color: c),
          const SizedBox(width: 6),
          Text(text,
              style: TextStyle(
                  color: c, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _photoStrip(BuildContext context, Project p) => SizedBox(
        height: 92,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final ph in p.photos)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(base64Decode(ph),
                        width: 92, height: 92, fit: BoxFit.cover),
                  ),
                  Positioned(
                    right: 2,
                    top: 2,
                    child: GestureDetector(
                      onTap: () async {
                        final ok = await confirm(context, 'Foto löschen?');
                        if (ok) {
                          p.photos.remove(ph);
                          Store.I.saveProject(p);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                            color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(Icons.close,
                            size: 15, color: Colors.white),
                      ),
                    ),
                  ),
                ]),
              ),
            GestureDetector(
              onTap: () => _addPhoto(context, p),
              child: Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  color: kCard2,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kLine),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_a_photo_outlined, color: kAccent),
                    const SizedBox(height: 4),
                    Text('Foto', style: TextStyle(color: kMuted, fontSize: 11)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  Future<void> _addPhoto(BuildContext context, Project p) async {
    try {
      final x = await ImagePicker().pickImage(
          source: ImageSource.gallery, imageQuality: 55, maxWidth: 1280);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      p.photos.add(base64Encode(bytes));
      Store.I.saveProject(p);
    } catch (_) {
      if (context.mounted) {
        snack(context, 'Foto konnte nicht geladen werden.');
      }
    }
  }
}

// ---------- Stunden ----------
class HoursScreen extends StatelessWidget {
  final String projectId;
  const HoursScreen({super.key, required this.projectId});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.I,
      builder: (_, __) {
        final p = Store.I.projectById(projectId);
        if (p == null) return const Scaffold(body: SizedBox.shrink());
        return Scaffold(
          appBar: AppBar(title: const Text('Arbeitsstunden')),
          floatingActionButton: FloatingActionButton(
            backgroundColor: kAccent,
            foregroundColor: kAccentInk,
            onPressed: () => showHoursForm(context, p),
            child: const Icon(Icons.add),
          ),
          body: p.hours.isEmpty
              ? Center(
                  child: Text('Noch keine Stunden erfasst.',
                      style: TextStyle(color: kMuted)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 90),
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      child: Column(
                        children: p.hours.reversed
                            .map((h) => ListTile(
                                  title: Text('${h.worker} · ${h.h} h'),
                                  subtitle: Text(
                                      '${dShort(h.date)} · ${h.task.isEmpty ? '—' : h.task}',
                                      style: TextStyle(color: kMuted)),
                                  trailing: IconButton(
                                    icon: Icon(Icons.delete_outline,
                                        color: kMuted),
                                    onPressed: () {
                                      p.hours.removeWhere((x) => x.id == h.id);
                                      Store.I.saveProject(p);
                                    },
                                  ),
                                ))
                            .toList(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 12, right: 4),
                      child: Text(
                          'Gesamt: ${sumHours(p).toStringAsFixed(sumHours(p) % 1 == 0 ? 0 : 1)} h',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

// ---------- Material ----------
class MaterialsScreen extends StatelessWidget {
  final String projectId;
  const MaterialsScreen({super.key, required this.projectId});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.I,
      builder: (_, __) {
        final p = Store.I.projectById(projectId);
        if (p == null) return const Scaffold(body: SizedBox.shrink());
        return Scaffold(
          appBar: AppBar(title: const Text('Material')),
          floatingActionButton: FloatingActionButton(
            backgroundColor: kAccent,
            foregroundColor: kAccentInk,
            onPressed: () => showMaterialForm(context, p),
            child: const Icon(Icons.add),
          ),
          body: p.materials.isEmpty
              ? Center(
                  child: Text('Noch kein Material erfasst.',
                      style: TextStyle(color: kMuted)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 90),
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      child: Column(
                        children: p.materials.reversed
                            .map((m) => ListTile(
                                  title: Text(m.name),
                                  subtitle: Text(
                                      '${m.qty} ${m.unit} × ${eur(m.price)} · ${dShort(m.date)}',
                                      style: TextStyle(color: kMuted)),
                                  trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(eur(m.qty * m.price),
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700)),
                                        IconButton(
                                          icon: Icon(Icons.delete_outline,
                                              color: kMuted),
                                          onPressed: () {
                                            p.materials.removeWhere(
                                                (x) => x.id == m.id);
                                            Store.I.saveProject(p);
                                          },
                                        ),
                                      ]),
                                ))
                            .toList(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 12, right: 4),
                      child: Text('Summe: ${eur(sumMaterial(p))}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 16)),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

// ---------- Aufgaben ----------
class TasksScreen extends StatelessWidget {
  final String projectId;
  const TasksScreen({super.key, required this.projectId});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.I,
      builder: (_, __) {
        final p = Store.I.projectById(projectId);
        if (p == null) return const Scaffold(body: SizedBox.shrink());
        return Scaffold(
          appBar: AppBar(title: const Text('Aufgaben')),
          floatingActionButton: FloatingActionButton(
            backgroundColor: kAccent,
            foregroundColor: kAccentInk,
            onPressed: () => showTaskForm(context, p),
            child: const Icon(Icons.add),
          ),
          body: p.tasks.isEmpty
              ? Center(
                  child: Text('Noch keine Aufgaben.',
                      style: TextStyle(color: kMuted)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 90),
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      child: Column(
                        children: p.tasks
                            .map((t) => ListTile(
                                  leading: GestureDetector(
                                    onTap: () {
                                      t.done = !t.done;
                                      Store.I.saveProject(p);
                                    },
                                    child: Icon(
                                        t.done
                                            ? Icons.check_box
                                            : Icons.check_box_outline_blank,
                                        color: t.done ? kGreen : kMuted),
                                  ),
                                  title: Text(t.title,
                                      style: TextStyle(
                                          decoration: t.done
                                              ? TextDecoration.lineThrough
                                              : null,
                                          color: t.done ? kMuted : kInk)),
                                  subtitle: t.due.isEmpty
                                      ? null
                                      : Text('fällig ${dShort(t.due)}',
                                          style: TextStyle(color: kMuted)),
                                  trailing: IconButton(
                                    icon: Icon(Icons.delete_outline,
                                        color: kMuted),
                                    onPressed: () {
                                      p.tasks.removeWhere((x) => x.id == t.id);
                                      Store.I.saveProject(p);
                                    },
                                  ),
                                ))
                            .toList(),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

// ---------- Mängel ----------
class DefectsScreen extends StatelessWidget {
  final String projectId;
  const DefectsScreen({super.key, required this.projectId});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.I,
      builder: (_, __) {
        final p = Store.I.projectById(projectId);
        if (p == null) return const Scaffold(body: SizedBox.shrink());
        return Scaffold(
          appBar: AppBar(title: const Text('Mängel')),
          floatingActionButton: FloatingActionButton(
            backgroundColor: kAccent,
            foregroundColor: kAccentInk,
            onPressed: () => showDefectForm(context, p, null),
            child: const Icon(Icons.add),
          ),
          body: p.defects.isEmpty
              ? Center(
                  child: Text('Keine Mängel erfasst.',
                      style: TextStyle(color: kMuted)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 90),
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
                      child: Column(
                        children: p.defects
                            .map((d) => ListTile(
                                  leading: GestureDetector(
                                    onTap: () {
                                      d.done = !d.done;
                                      Store.I.saveProject(p);
                                    },
                                    child: Icon(
                                        d.done
                                            ? Icons.check_box
                                            : Icons.check_box_outline_blank,
                                        color: d.done ? kGreen : kRed),
                                  ),
                                  title: Text(d.title,
                                      style: TextStyle(
                                          decoration: d.done
                                              ? TextDecoration.lineThrough
                                              : null,
                                          color: d.done ? kMuted : kInk)),
                                  subtitle: d.description.isEmpty
                                      ? null
                                      : Text(d.description,
                                          style: TextStyle(color: kMuted)),
                                  onTap: () => showDefectForm(context, p, d),
                                  trailing: IconButton(
                                    icon: Icon(Icons.delete_outline,
                                        color: kMuted),
                                    onPressed: () {
                                      p.defects
                                          .removeWhere((x) => x.id == d.id);
                                      Store.I.saveProject(p);
                                    },
                                  ),
                                ))
                            .toList(),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

// ---------- Verwaltung (rollen-gated) ----------
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.I,
      builder: (_, __) {
        if (!Store.I.canManageAny) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => Navigator.of(context).maybePop());
          return const Scaffold(body: SizedBox.shrink());
        }
        final s = Store.I;
        final tiles = <Widget>[];
        void tile(String key, IconData icon, Color color, String title,
            String subtitle) {
          tiles.add(Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: Icon(icon, color: color),
              title: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(subtitle, style: TextStyle(color: kMuted)),
              trailing: Icon(Icons.chevron_right, color: kMuted),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      _AdminSectionScreen(sectionKey: key, title: title))),
            ),
          ));
        }

        if (s.can('usersRoles')) {
          tile('users', Icons.group_outlined, kAccent, 'Benutzer & Rollen',
              '${s.users.length} Benutzer · ${s.roles.length} Rollen');
        }
        if (s.can('materialPrices')) {
          tile('materialPrices', Icons.euro, kViolet, 'Material-Preisliste',
              '${s.catalog.length} Einträge');
        }
        if (s.can('pauschalen')) {
          tile('pauschalen', Icons.receipt_long_outlined, kViolet, 'Pauschalen',
              '${s.pauschalen.length} Einträge');
        }
        if (s.can('categories')) {
          tile('categories', Icons.category_outlined, kBlue,
              'Kategorien / Gewerke', '${s.arten.length} Kategorien');
        }
        // Prüfliste der Zeiterfassung: unbestätigte und automatisch beendete
        // Zeiten, die Büro/Meister freigeben oder korrigieren müssen.
        if (s.can('editProjects')) {
          final open = gTracking.entriesNeedingReview.length;
          tiles.add(Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              leading: Icon(Icons.fact_check_outlined,
                  color: open > 0 ? kWarn : kGreen),
              title: const Text('Zeiten prüfen',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                  open > 0
                      ? '$open Eintrag${open == 1 ? '' : 'e'} offen'
                      : 'Alles bestätigt',
                  style: TextStyle(color: kMuted)),
              trailing: Icon(Icons.chevron_right, color: kMuted),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const TrackingReviewScreen())),
            ),
          ));
        }

        return Scaffold(
          appBar: AppBar(title: const Text('Verwaltung')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
            children: tiles,
          ),
        );
      },
    );
  }
}

class _AdminSectionScreen extends StatelessWidget {
  final String sectionKey;
  final String title;
  const _AdminSectionScreen({required this.sectionKey, required this.title});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.I,
      builder: (_, __) {
        final s = Store.I;
        return Scaffold(
          appBar: AppBar(title: Text(title)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
            children: _body(context, s),
          ),
        );
      },
    );
  }

  List<Widget> _body(BuildContext context, Store s) {
    switch (sectionKey) {
      case 'materialPrices':
        return [
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: s.catalog
                  .map((c) => ListTile(
                        onTap: () => showCatalogForm(context, c),
                        leading: Icon(Icons.euro, color: kViolet),
                        title: Text(c.name),
                        subtitle: Text('${eur(c.price)} / ${c.unit}',
                            style: TextStyle(color: kMuted)),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline, color: kMuted),
                          onPressed: () {
                            s.removeCatalogItem(c.id);
                          },
                        ),
                      ))
                  .toList(),
            ),
          ),
          _adminAddBtn(
              'Preis hinzufügen', () => showCatalogForm(context, null)),
        ];
      case 'pauschalen':
        return [
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: s.pauschalen
                  .map((pa) => ListTile(
                        onTap: () => showPauschaleForm(context, pa),
                        leading:
                            Icon(Icons.receipt_long_outlined, color: kViolet),
                        title: Text(pa.name),
                        subtitle: Text(eur(pa.amount),
                            style: TextStyle(color: kMuted)),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline, color: kMuted),
                          onPressed: () {
                            s.removePauschale(pa.id);
                          },
                        ),
                      ))
                  .toList(),
            ),
          ),
          _adminAddBtn(
              'Pauschale hinzufügen', () => showPauschaleForm(context, null)),
        ];
      case 'categories':
        return [
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: s.arten.map((a) {
                final used = s.projects.where((p) => p.type == a).length;
                return ListTile(
                  onTap: () => showCategoryForm(context, a),
                  leading: Icon(Icons.category_outlined, color: kBlue),
                  title: Text(a),
                  subtitle: Text(
                      used == 0
                          ? 'Nicht verwendet'
                          : '$used Auftrag${used == 1 ? '' : 'e'}',
                      style: TextStyle(color: kMuted)),
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline, color: kMuted),
                    onPressed: () => _delCategory(context, a),
                  ),
                );
              }).toList(),
            ),
          ),
          _adminAddBtn(
              'Kategorie hinzufügen', () => showCategoryForm(context, null)),
        ];
      case 'users':
        return [
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: s.users
                  .map((u) => ListTile(
                        onTap: () => showUserForm(context, u),
                        leading: Icon(Icons.person_outline, color: kAccent),
                        title: Text(
                            '${u.name}${u.id == s.sessionId ? '  (du)' : ''}'),
                        subtitle: Text(
                            '${u.role}${u.wage > 0 ? ' · ${eur(u.wage)}/h' : ''}'
                            ' · ${u.hasAccount ? u.email : 'kein Zugang'}',
                            style: TextStyle(
                                color: u.hasAccount ? kMuted : kWarn)),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline, color: kMuted),
                          onPressed: () => _delUser(context, u),
                        ),
                      ))
                  .toList(),
            ),
          ),
          _adminAddBtn(
              'Benutzer hinzufügen', () => showUserForm(context, null)),
          const SizedBox(height: 6),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.shield_outlined, color: kBlue),
              title: const Text('Rollen & Berechtigungen',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${s.roles.length} Rollen',
                  style: TextStyle(color: kMuted)),
              trailing: Icon(Icons.chevron_right, color: kMuted),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const _AdminSectionScreen(
                      sectionKey: 'roles', title: 'Rollen & Berechtigungen'))),
            ),
          ),
        ];
      case 'roles':
        return [
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: s.roles.map((r) {
                final admin = r == kAdminRole;
                final n =
                    admin ? kPerms.length : (s.rolePerms[r] ?? const []).length;
                final count = s.users.where((u) => u.role == r).length;
                return ListTile(
                  onTap: () => showRolePermsForm(context, r),
                  leading: Icon(Icons.shield_outlined,
                      color: admin ? kAccent : kBlue),
                  title: Text(r),
                  subtitle: Text(
                      '${admin ? 'alle' : '$n'} Rechte · $count Benutzer',
                      style: TextStyle(color: kMuted)),
                  trailing: admin
                      ? Icon(Icons.lock_outline, color: kMuted, size: 20)
                      : IconButton(
                          icon: Icon(Icons.delete_outline, color: kMuted),
                          onPressed: () => _delRole(context, r),
                        ),
                );
              }).toList(),
            ),
          ),
          _adminAddBtn('Rolle hinzufügen', () => showRoleForm(context, null)),
        ];
      default:
        return const [];
    }
  }

  void _delCategory(BuildContext context, String a) async {
    final s = Store.I;
    final used = s.projects.where((p) => p.type == a).length;
    if (used > 0) {
      snack(context,
          'Kategorie wird von $used Auftrag${used == 1 ? '' : 'en'} genutzt und kann nicht gelöscht werden.');
      return;
    }
    if (s.arten.length <= 1) {
      snack(context, 'Es muss mindestens eine Kategorie bleiben.');
      return;
    }
    final ok = await confirm(context, 'Kategorie „$a" wirklich löschen?');
    if (ok) {
      s.arten.remove(a);
      s.saveSettings();
    }
  }

  void _delUser(BuildContext context, AppUser u) async {
    if (u.id == Store.I.sessionId) {
      snack(context,
          'Der aktuell angemeldete Benutzer kann nicht gelöscht werden.');
      return;
    }
    if (Store.I.users.length <= 1) {
      snack(context, 'Es muss mindestens ein Benutzer bleiben.');
      return;
    }
    final ok = await confirm(context, 'Benutzer wirklich löschen?');
    if (!ok) return;

    // Erst das Konto, dann der lokale Datensatz. Andersherum bliebe bei einem
    // Fehler ein Zugang bestehen, den niemand mehr in der Liste sieht.
    if (u.hasAccount) {
      try {
        await Store.I.auth.deleteUser(u.id);
      } on AuthFailure catch (e) {
        if (context.mounted) snack(context, e.message);
        return;
      }
    }
    Store.I.removeUser(u.id);
  }

  void _delRole(BuildContext context, String r) async {
    final s = Store.I;
    if (r == kAdminRole) return;
    final used = s.users.where((u) => u.role == r).length;
    if (used > 0) {
      snack(context,
          'Rolle wird von $used Benutzer${used == 1 ? '' : 'n'} genutzt und kann nicht gelöscht werden.');
      return;
    }
    if (s.roles.length <= 1) {
      snack(context, 'Es muss mindestens eine Rolle bleiben.');
      return;
    }
    final ok = await confirm(context, 'Rolle „$r" wirklich löschen?');
    if (ok) {
      s.roles.remove(r);
      s.rolePerms.remove(r);
      s.saveSettings();
    }
  }
}

Widget _adminAddBtn(String label, VoidCallback onTap) => Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
          icon: const Icon(Icons.add), label: Text(label), onPressed: onTap),
    );

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 9),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                color: kMuted,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                letterSpacing: .6)),
      );
}

// ===================================================================
// Sheets / Dialoge
// ===================================================================
Future<bool> confirm(BuildContext context, String msg) async {
  return await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kBg2,
          content: Text(msg),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Abbrechen')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('OK', style: TextStyle(color: kRed))),
          ],
        ),
      ) ??
      false;
}

void snack(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

Future<T?> _sheet<T>(
    BuildContext context, Widget Function(BuildContext) builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kBg,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 10,
          bottom: 18 + MediaQuery.of(ctx).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                  color: kLine, borderRadius: BorderRadius.circular(4)),
            ),
          ),
          Flexible(child: builder(ctx)),
        ],
      ),
    ),
  );
}

Widget _label(String t) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6, left: 2),
      child: Text(t,
          style: TextStyle(
              color: kMuted, fontSize: 13, fontWeight: FontWeight.w600)),
    );

Widget _pickField(String hint, String value, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
        decoration: BoxDecoration(
          color: kCard2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kLine),
        ),
        child: Row(children: [
          Icon(Icons.event, size: 18, color: kMuted),
          const SizedBox(width: 8),
          Text(value.isEmpty ? hint : dLong(value),
              style: TextStyle(color: value.isEmpty ? kMuted : kInk)),
        ]),
      ),
    );

/// Speichern-Knopf am Fuß eines Formulars. [onTap] darf null sein – dann ist
/// der Knopf ausgegraut, etwa während ein Serveraufruf läuft.
Widget _saveBtn(String label, VoidCallback? onTap) => Padding(
      padding: const EdgeInsets.only(top: 18),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kAccent, foregroundColor: kAccentInk),
          onPressed: onTap,
          child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(label)),
        ),
      ),
    );

// ---- PDF-Export (Leistungsnachweis / Rechnung pro Auftrag) ----
String fileSlug(String s) {
  final slug = s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return slug.isEmpty ? 'auftrag' : slug;
}

Future<void> exportProjectPdf(BuildContext context, Project p) async {
  final sel = <String>{}; // ausgewählte Pauschalen-IDs
  await _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      final paus = Store.I.pauschalen;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('PDF exportieren',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
              'Leistungsnachweis / Rechnung. Löhne werden je Mitarbeiter '
              'automatisch berechnet.',
              style: TextStyle(color: kMuted, fontSize: 13)),
          if (paus.isNotEmpty) ...[
            _label('Pauschalen aufschlagen'),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: paus
                      .map((pa) => CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            activeColor: kAccent,
                            value: sel.contains(pa.id),
                            onChanged: (v) => setSt(() {
                              if (v == true) {
                                sel.add(pa.id);
                              } else {
                                sel.remove(pa.id);
                              }
                            }),
                            title: Text(pa.name),
                            secondary: Text(eur(pa.amount)),
                          ))
                      .toList(),
                ),
              ),
            ),
          ],
          _saveBtn('PDF erstellen', () async {
            Navigator.pop(ctx);
            final wages = {for (final u in Store.I.users) u.name: u.wage};
            final chosen =
                Store.I.pauschalen.where((pa) => sel.contains(pa.id)).toList();
            final bytes = await buildProjectInvoicePdf(p,
                customer: Store.I.customerById(p.customerId),
                wages: wages,
                pauschalen: chosen);
            final fname = 'baudoc_${fileSlug(p.name)}_${today()}.pdf';
            await downloadBytes(fname, bytes, 'application/pdf');
            if (context.mounted) snack(context, 'PDF erstellt: $fname');
          }),
        ],
      );
    });
  });
}

Future<void> exportProjectQuote(BuildContext context, Project p) async {
  final hoursC = TextEditingController();
  final rateC = TextEditingController();
  final vatC = TextEditingController(text: '19');
  String validUntil = '';
  final sel = <String>{}; // ausgewählte Pauschalen-IDs
  await _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      final paus = Store.I.pauschalen;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Angebot exportieren',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
              'Angebot / Kostenvoranschlag: Material aus dem Auftrag plus '
              'geschätzte Arbeit, mit MwSt-Ausweis.',
              style: TextStyle(color: kMuted, fontSize: 13)),
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('Geschätzte Stunden'),
                    TextField(
                        controller: hoursC,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(hintText: 'z. B. 8')),
                  ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('Stundensatz (€/h)'),
                    TextField(
                        controller: rateC,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(hintText: 'z. B. 55')),
                  ]),
            ),
          ]),
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('MwSt (%)'),
                    TextField(
                        controller: vatC,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration:
                            const InputDecoration(hintText: '19 – 0 = ohne')),
                  ]),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('Gültig bis'),
                    _pickField('Datum', validUntil, () async {
                      final r = await pickDate(ctx, validUntil);
                      if (r != null) setSt(() => validUntil = r);
                    }),
                  ]),
            ),
          ]),
          if (paus.isNotEmpty) ...[
            _label('Pauschalen aufschlagen'),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: paus
                      .map((pa) => CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            activeColor: kAccent,
                            value: sel.contains(pa.id),
                            onChanged: (v) => setSt(() {
                              if (v == true) {
                                sel.add(pa.id);
                              } else {
                                sel.remove(pa.id);
                              }
                            }),
                            title: Text(pa.name),
                            secondary: Text(eur(pa.amount)),
                          ))
                      .toList(),
                ),
              ),
            ),
          ],
          _saveBtn('Angebot erstellen', () async {
            Navigator.pop(ctx);
            double parse(String s) =>
                double.tryParse(s.trim().replaceAll(',', '.')) ?? 0;
            final chosen =
                Store.I.pauschalen.where((pa) => sel.contains(pa.id)).toList();
            final bytes = await buildProjectQuotePdf(p,
                customer: Store.I.customerById(p.customerId),
                estHours: parse(hoursC.text),
                hourlyRate: parse(rateC.text),
                pauschalen: chosen,
                vatRate: parse(vatC.text),
                validUntil: validUntil);
            final fname = 'baudoc_angebot_${fileSlug(p.name)}_${today()}.pdf';
            await downloadBytes(fname, bytes, 'application/pdf');
            if (context.mounted) snack(context, 'Angebot erstellt: $fname');
          }),
        ],
      );
    });
  });
}

// ---- CSV-Export ----
String csvCell(String s) {
  if (s.contains('"') ||
      s.contains(';') ||
      s.contains(',') ||
      s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String csvNum(num n) => n.toStringAsFixed(2).replaceAll('.', ',');

// Eine Zeile pro Auftrag, inkl. Stunden- und Materialkosten-Summe.
// Semikolon als Trenner + Dezimalkomma → öffnet sauber in deutschem Excel.
String buildProjectsCsv(List<Project> projects) {
  const sep = ';';
  final rows = <String>[];
  rows.add([
    'Auftrag',
    'Art/Gewerk',
    'Adresse',
    'Status',
    'Start',
    'Fällig',
    'Stunden gesamt',
    'Materialkosten (€)',
    'Aufgaben erledigt',
    'Aufgaben gesamt',
  ].map(csvCell).join(sep));
  for (final p in projects) {
    final totalH = p.hours.fold<double>(0, (s, e) => s + e.h);
    final matCost = p.materials.fold<double>(0, (s, e) => s + e.qty * e.price);
    final doneTasks = p.tasks.where((t) => t.done).length;
    rows.add([
      p.name,
      p.type,
      p.address,
      p.isOpen ? 'Aktiv' : 'Abgeschlossen',
      dLong(p.date),
      dLong(p.due),
      csvNum(totalH),
      csvNum(matCost),
      '$doneTasks',
      '${p.tasks.length}',
    ].map(csvCell).join(sep));
  }
  return rows.join('\r\n');
}

// Auswahl-Sheet: nach Gewerk / Status / Zeitraum filtern und exportieren.
Future<void> exportProjectsCsv(BuildContext context) async {
  final all = Store.I.projects;
  if (all.isEmpty) {
    snack(context, 'Keine Aufträge zum Exportieren.');
    return;
  }
  // Zustand überlebt setSt-Rebuilds, daher außerhalb des Builders.
  String? gewerk; // null = alle Gewerke
  String statusF = 'alle'; // 'alle' | 'offen' | 'done'
  String von = ''; // ISO yyyy-MM-dd, '' = unbegrenzt (filtert auf Startdatum)
  String bis = '';
  final selected = all.map((p) => p.id).toSet(); // Standard: alle ausgewählt

  await _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      List<Project> visible() => all.where((p) {
            if (gewerk != null && p.type != gewerk) return false;
            if (statusF == 'offen' && !p.isOpen) return false;
            if (statusF == 'done' && p.isOpen) return false;
            if (von.isNotEmpty &&
                (p.date.isEmpty || p.date.compareTo(von) < 0)) {
              return false;
            }
            if (bis.isNotEmpty &&
                (p.date.isEmpty || p.date.compareTo(bis) > 0)) {
              return false;
            }
            return true;
          }).toList();

      // Bei Filteränderung sichtbare Aufträge automatisch komplett auswählen.
      void applyFilter(VoidCallback change) => setSt(() {
            change();
            selected
              ..clear()
              ..addAll(visible().map((p) => p.id));
          });

      final vis = visible();
      final selCount = vis.where((p) => selected.contains(p.id)).length;
      final hasFilter = gewerk != null ||
          statusF != 'alle' ||
          von.isNotEmpty ||
          bis.isNotEmpty;

      InputDecoration dense(String label) => InputDecoration(
            labelText: label,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          );

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Aufträge exportieren',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('$selCount von ${vis.length} ausgewählt',
              style: TextStyle(color: kMuted, fontSize: 13)),
          const SizedBox(height: 12),
          // ---- Filter ----
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String?>(
                initialValue: gewerk,
                isExpanded: true,
                dropdownColor: kCard2,
                decoration: dense('Gewerk'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Alle')),
                  ...Store.I.arten
                      .map((a) => DropdownMenuItem(value: a, child: Text(a))),
                ],
                onChanged: (v) => applyFilter(() => gewerk = v),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: statusF,
                isExpanded: true,
                dropdownColor: kCard2,
                decoration: dense('Status'),
                items: const [
                  DropdownMenuItem(value: 'alle', child: Text('Alle')),
                  DropdownMenuItem(value: 'offen', child: Text('Offen')),
                  DropdownMenuItem(value: 'done', child: Text('Abgeschl.')),
                ],
                onChanged: (v) => applyFilter(() => statusF = v ?? 'alle'),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: _pickField('Von', von, () async {
                final r = await pickDate(ctx, von.isEmpty ? today() : von);
                if (r != null) applyFilter(() => von = r);
              }),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _pickField('Bis', bis, () async {
                final r = await pickDate(ctx, bis.isEmpty ? today() : bis);
                if (r != null) applyFilter(() => bis = r);
              }),
            ),
          ]),
          if (hasFilter)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: kMuted),
                icon: const Icon(Icons.clear, size: 16),
                label: const Text('Filter zurücksetzen'),
                onPressed: () => applyFilter(() {
                  gewerk = null;
                  statusF = 'alle';
                  von = '';
                  bis = '';
                }),
              ),
            ),
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: kAccent,
            checkColor: kAccentInk,
            value: vis.isNotEmpty && selCount == vis.length,
            title: const Text('Alle auswählen',
                style: TextStyle(fontWeight: FontWeight.w600)),
            onChanged: vis.isEmpty
                ? null
                : (v) => setSt(() {
                      final ids = vis.map((p) => p.id);
                      if (v == true) {
                        selected.addAll(ids);
                      } else {
                        selected.removeAll(ids);
                      }
                    }),
          ),
          Divider(color: kLine, height: 1),
          // ---- Liste (gefiltert, scrollbar) ----
          Flexible(
            child: vis.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text('Keine Aufträge für diesen Filter.',
                        style: TextStyle(color: kMuted)))
                : ListView(
                    shrinkWrap: true,
                    children: vis.map((p) {
                      return CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: kAccent,
                        checkColor: kAccentInk,
                        value: selected.contains(p.id),
                        title: Text(p.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${p.type}${p.address.isEmpty ? '' : ' · ${p.address}'}'
                            '${p.date.isEmpty ? '' : ' · ${dLong(p.date)}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: kMuted, fontSize: 12)),
                        onChanged: (v) => setSt(() {
                          if (v == true) {
                            selected.add(p.id);
                          } else {
                            selected.remove(p.id);
                          }
                        }),
                      );
                    }).toList(),
                  ),
          ),
          _saveBtn('CSV exportieren', () async {
            final chosen = vis.where((p) => selected.contains(p.id)).toList();
            if (chosen.isEmpty) {
              snack(ctx, 'Bitte mindestens einen Auftrag wählen.');
              return;
            }
            final fname = 'baudoc_auftraege_${today()}.csv';
            Navigator.pop(ctx);
            try {
              await downloadCsv(fname, buildProjectsCsv(chosen));
              if (context.mounted) snack(context, 'CSV-Export erstellt: $fname');
            } catch (e) {
              if (context.mounted) snack(context, 'Export fehlgeschlagen: $e');
            }
          }),
        ],
      );
    });
  });
}

// ---- Profil ----
void showProfileSheet(BuildContext context) {
  final u = Store.I.currentUser!;
  _sheet(context, (ctx) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Profil',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Row(children: [
            CircleAvatar(
                radius: 28,
                backgroundColor: kAccent,
                child: Text(initials(u.name),
                    style: TextStyle(
                        color: kAccentInk,
                        fontWeight: FontWeight.w800,
                        fontSize: 20))),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(u.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              Text(u.role, style: TextStyle(color: kMuted)),
            ]),
          ]),
          const SizedBox(height: 14),
          if (Store.I.canManageAny) ...[
            ListTile(
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AdminScreen()));
              },
              leading:
                  Icon(Icons.admin_panel_settings_outlined, color: kViolet),
              title: const Text('Verwaltung'),
              subtitle: Text(
                  'Benutzer & Rollen, Preise, Pauschalen, Kategorien',
                  style: TextStyle(color: kMuted, fontSize: 12)),
              tileColor: kCard,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            const SizedBox(height: 8),
          ],
          // Stunden über alle Aufträge. Für jeden sichtbar – wie viel davon,
          // entscheiden die Rechte im TimesheetScreen selbst.
          ListTile(
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const TimesheetScreen()));
            },
            leading: Icon(Icons.assignment_outlined, color: kAccent),
            title: Text(
                Store.I.can('exportDocs') ? 'Stundenzettel' : 'Meine Stunden'),
            subtitle: Text(
                Store.I.can('exportDocs')
                    ? 'Alle Mitarbeiter, mit CSV- und PDF-Export'
                    : 'Meine Woche im Überblick',
                style: TextStyle(color: kMuted, fontSize: 12)),
            tileColor: kCard,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          const SizedBox(height: 8),
          // Automatische Ankunftserkennung. Nur dort anbieten, wo die
          // Plattform sie überhaupt kann – in der Web-Fassung gibt es kein
          // Hintergrund-Geofencing, ein toter Menüpunkt wäre irreführend.
          if (gTracking.supportsAutomaticTracking) ...[
            ListTile(
              onTap: () async {
                Navigator.pop(ctx);
                await showAutoTrackingSetup(context);
              },
              leading: Icon(Icons.my_location, color: kAccent),
              title: const Text('Ankunft automatisch erfassen'),
              subtitle: Text(
                  'Nachfragen, sobald die Baustelle erreicht ist',
                  style: TextStyle(color: kMuted, fontSize: 12)),
              tileColor: kCard,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            const SizedBox(height: 8),
          ],
          if (Store.I.can('exportDocs')) ...[
            ListTile(
              onTap: () async {
                Navigator.pop(ctx);
                await exportProjectsCsv(context);
              },
              leading: Icon(Icons.download, color: kBlue),
              title: const Text('Aufträge als CSV exportieren'),
              tileColor: kCard,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            const SizedBox(height: 8),
          ],
          ListTile(
            onTap: () {
              Navigator.pop(ctx);
              showPasswordForm(context);
            },
            leading: Icon(Icons.key_outlined, color: kAccent),
            title: const Text('Passwort ändern'),
            tileColor: kCard,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<bool>(
            valueListenable: gDark,
            builder: (_, dark, __) => ListTile(
              leading: Icon(dark ? Icons.dark_mode : Icons.light_mode_outlined,
                  color: kAccent),
              title: const Text('Dunkelmodus'),
              trailing: Switch(
                value: dark,
                onChanged: (v) => Store.I.setDarkMode(v),
              ),
              tileColor: kCard,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: kRed),
              icon: const Icon(Icons.logout),
              label: const Text('Abmelden'),
              onPressed: () {
                Navigator.pop(ctx);
                Store.I.logout();
              },
            ),
          ),
        ]);
  });
}

/// Eigenes Passwort ändern.
///
/// Läuft nicht über die Verwaltungs-Funktionen: das darf jeder für sich selbst,
/// und die Bestätigung mit dem bisherigen Passwort erledigt Firebase.
void showPasswordForm(BuildContext context) {
  final alt = TextEditingController();
  final neu = TextEditingController();
  final wdh = TextEditingController();
  String? fehler;
  bool busy = false;

  _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      Future<void> speichern() async {
        if (busy) return;
        if (neu.text.length < 6) {
          setSt(() => fehler = 'Das neue Passwort braucht mindestens 6 Zeichen.');
          return;
        }
        if (neu.text != wdh.text) {
          setSt(() => fehler = 'Die beiden Eingaben stimmen nicht überein.');
          return;
        }
        setSt(() {
          busy = true;
          fehler = null;
        });
        try {
          await Store.I.auth
              .changeOwnPassword(current: alt.text, next: neu.text);
          if (ctx.mounted) {
            Navigator.pop(ctx);
            snack(context, 'Passwort geändert.');
          }
        } on AuthFailure catch (e) {
          setSt(() => fehler = e.message);
        } finally {
          setSt(() => busy = false);
        }
      }

      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Passwort ändern',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            _label('Bisheriges Passwort'),
            TextField(
                controller: alt,
                enabled: !busy,
                obscureText: true,
                autocorrect: false,
                decoration: const InputDecoration(hintText: '••••••')),
            _label('Neues Passwort (mindestens 6 Zeichen)'),
            TextField(
                controller: neu,
                enabled: !busy,
                obscureText: true,
                autocorrect: false,
                decoration: const InputDecoration(hintText: '••••••')),
            _label('Neues Passwort wiederholen'),
            TextField(
                controller: wdh,
                enabled: !busy,
                obscureText: true,
                autocorrect: false,
                decoration: const InputDecoration(hintText: '••••••')),
            if (fehler != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child:
                    Text(fehler!, style: TextStyle(color: kRed, fontSize: 13)),
              ),
            _saveBtn(busy ? 'Bitte warten …' : 'Speichern',
                busy ? null : speichern),
          ]);
    });
  });
}

// ---- Auftrag ----
void showProjectForm(BuildContext context) {
  final name = TextEditingController();
  final addr = TextEditingController();
  String type = Store.I.arten.isNotEmpty ? Store.I.arten.first : 'Sonstiges';
  String date = today();
  String due = '';
  String customerId = '';
  _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Neuer Auftrag',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            _label('Name'),
            TextField(
                controller: name,
                decoration: const InputDecoration(
                    hintText: 'z. B. PV-Anlage Müllerstr. 12')),
            _label('Art / Gewerk'),
            DropdownButtonFormField<String>(
              initialValue: type,
              dropdownColor: kCard2,
              items: {...Store.I.arten, type}
                  .map((a) => DropdownMenuItem(value: a, child: Text(a)))
                  .toList(),
              onChanged: (v) => setSt(() => type = v!),
            ),
            _label('Adresse'),
            TextField(
                controller: addr,
                decoration: const InputDecoration(hintText: 'Straße, Ort')),
            _label('Kunde'),
            DropdownButtonFormField<String>(
              initialValue: customerId,
              dropdownColor: kCard2,
              items: [
                const DropdownMenuItem(
                    value: '', child: Text('– kein Kunde –')),
                ...Store.I.customers.map(
                    (c) => DropdownMenuItem(value: c.id, child: Text(c.name))),
              ],
              onChanged: (v) => setSt(() => customerId = v ?? ''),
            ),
            _label('Start / Fällig'),
            Row(children: [
              Expanded(
                child: _pickField('Start', date, () async {
                  final r = await pickDate(ctx, date);
                  if (r != null) setSt(() => date = r);
                }),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _pickField('Fällig', due, () async {
                  final r = await pickDate(ctx, due);
                  if (r != null) setSt(() => due = r);
                }),
              ),
            ]),
            _saveBtn('Auftrag anlegen', () {
              if (name.text.trim().isEmpty) return;
              // Vorne einsortieren, damit der neue Auftrag oben in der Liste
              // steht – das Speichern findet ihn dann bereits vor.
              final neu = Project(
                  id: uid(),
                  name: name.text.trim(),
                  type: type,
                  address: addr.text.trim(),
                  status: 'active',
                  date: date,
                  due: due,
                  customerId: customerId,
                  hours: [],
                  materials: [],
                  tasks: []);
              Store.I.projects.insert(0, neu);
              Store.I.saveProject(neu);
              Navigator.pop(ctx);
            }),
          ]);
    });
  });
}

// ---- Bautagebuch ----
void showNoteForm(BuildContext context, Project p) {
  final text = TextEditingController();
  bool saving = false;
  _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Tagebuch-Eintrag',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            _label('Notiz'),
            TextField(
              controller: text,
              maxLines: 4,
              decoration:
                  const InputDecoration(hintText: 'Was ist heute passiert?'),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 2),
              child: Row(children: [
                Icon(Icons.cloud_outlined, size: 15, color: kMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Wetter wird beim Speichern automatisch erfasst.',
                      style: TextStyle(color: kMuted, fontSize: 12)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: kAccent, foregroundColor: kAccentInk),
                  onPressed: saving
                      ? null
                      : () async {
                          if (text.text.trim().isEmpty) return;
                          setSt(() => saving = true);
                          final w = await fetchCurrentWeather();
                          p.notes.add(Note(
                              id: uid(),
                              date: today(),
                              text: text.text.trim(),
                              weather: w.desc,
                              temp: w.temp));
                          Store.I.saveProject(p);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: saving
                        ? SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: kAccentInk))
                        : const Text('Eintrag speichern'),
                  ),
                ),
              ),
            ),
          ]);
    });
  });
}

// ---- Stunden ----
void showHoursForm(BuildContext context, Project p) {
  final names = {for (final u in Store.I.users) u.name}.toList();
  String worker =
      Store.I.currentUser?.name ?? (names.isNotEmpty ? names.first : 'Ich');
  if (!names.contains(worker)) names.insert(0, worker);
  final hrs = TextEditingController(text: '8');
  final task = TextEditingController();
  _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Stunden eintragen',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            _label('Mitarbeiter'),
            DropdownButtonFormField<String>(
              initialValue: worker,
              dropdownColor: kCard2,
              isExpanded: true,
              items: names
                  .map((n) => DropdownMenuItem(value: n, child: Text(n)))
                  .toList(),
              onChanged: (v) => setSt(() => worker = v!),
            ),
            _label('Stunden'),
            TextField(
                controller: hrs,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true)),
            _label('Tätigkeit'),
            TextField(
                controller: task,
                decoration: const InputDecoration(hintText: 'z. B. Mauern EG')),
            _saveBtn('Speichern', () {
              p.hours.add(WorkHours(
                  id: uid(),
                  worker: worker,
                  date: today(),
                  task: task.text.trim(),
                  h: double.tryParse(hrs.text.replaceAll(',', '.')) ?? 0,
                  synced: Store.I.online));
              Store.I.saveProject(p);
              Navigator.pop(ctx);
            }),
          ]);
    });
  });
}

// ---- Material ----
void showMaterialForm(BuildContext context, Project p) {
  CatalogItem? sel = Store.I.catalog.isNotEmpty ? Store.I.catalog.first : null;
  final qty = TextEditingController(text: '1');
  _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Material eintragen',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            _label('Material wählen'),
            DropdownButtonFormField<CatalogItem>(
              initialValue: sel,
              dropdownColor: kCard2,
              items: Store.I.catalog
                  .map((c) => DropdownMenuItem(
                      value: c,
                      child: Text('${c.name} — ${eur(c.price)}/${c.unit}')))
                  .toList(),
              onChanged: (v) => setSt(() => sel = v),
            ),
            if (sel != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                    'Preis automatisch: ${eur(sel!.price)} / ${sel!.unit}',
                    style:
                        TextStyle(color: kAccent, fontWeight: FontWeight.w600)),
              ),
              _label('Menge (${sel!.unit})'),
              TextField(
                  controller: qty,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true)),
            ],
            _saveBtn('Speichern', () {
              if (sel == null) return;
              p.materials.add(MaterialItem(
                  id: uid(),
                  name: sel!.name,
                  unit: sel!.unit,
                  date: today(),
                  qty: double.tryParse(qty.text.replaceAll(',', '.')) ?? 0,
                  price: sel!.price,
                  synced: Store.I.online));
              Store.I.saveProject(p);
              Navigator.pop(ctx);
            }),
          ]);
    });
  });
}

// ---- Aufgabe ----
void showTaskForm(BuildContext context, Project p) {
  final title = TextEditingController();
  _sheet(context, (ctx) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Neue Aufgabe',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          _label('Titel'),
          TextField(
              controller: title,
              decoration:
                  const InputDecoration(hintText: 'z. B. Estrich verlegen')),
          _saveBtn('Speichern', () {
            if (title.text.trim().isEmpty) return;
            p.tasks.add(Task(
                id: uid(), title: title.text.trim(), due: '', done: false));
            Store.I.saveProject(p);
            Navigator.pop(ctx);
          }),
        ]);
  });
}

// ---- Mangel ----
void showDefectForm(BuildContext context, Project p, Defect? existing) {
  final title = TextEditingController(text: existing?.title ?? '');
  final desc = TextEditingController(text: existing?.description ?? '');
  _sheet(context, (ctx) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(existing == null ? 'Neuer Mangel' : 'Mangel bearbeiten',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          _label('Titel'),
          TextField(
              controller: title,
              decoration:
                  const InputDecoration(hintText: 'z. B. Riss in Wand EG')),
          _label('Beschreibung (optional)'),
          TextField(
              controller: desc,
              maxLines: 3,
              decoration: const InputDecoration(
                  hintText: 'Details, Ort, was zu tun ist')),
          _saveBtn('Speichern', () {
            if (title.text.trim().isEmpty) return;
            if (existing != null) {
              existing.title = title.text.trim();
              existing.description = desc.text.trim();
            } else {
              p.defects.add(Defect(
                  id: uid(),
                  title: title.text.trim(),
                  description: desc.text.trim(),
                  date: today()));
            }
            Store.I.saveProject(p);
            Navigator.pop(ctx);
          }),
        ]);
  });
}

// ---- Preis ----
// ---- Kategorie / Gewerk ----
void showCategoryForm(BuildContext context, String? existing) {
  final ctrl = TextEditingController(text: existing ?? '');
  _sheet(context, (ctx) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(existing == null ? 'Neue Kategorie' : 'Kategorie umbenennen',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        _label('Bezeichnung'),
        TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'z. B. Dachdecker'),
        ),
        _saveBtn('Speichern', () {
          final name = ctrl.text.trim();
          if (name.isEmpty) return;
          final s = Store.I;
          final dup = s.arten.any(
              (a) => a.toLowerCase() == name.toLowerCase() && a != existing);
          if (dup) {
            snack(context, 'Diese Kategorie gibt es bereits.');
            return;
          }
          if (existing == null) {
            s.arten.add(name);
          } else if (existing != name) {
            final i = s.arten.indexOf(existing);
            if (i >= 0) s.arten[i] = name;
            // Vorhandene Aufträge mit der alten Bezeichnung mit umbenennen.
            // Jeder betroffene Auftrag wird einzeln gespeichert – ein Backend
            // bekommt die Umbenennung sonst nie zu sehen.
            for (final p
                in s.projects.where((p) => p.type == existing).toList()) {
              p.type = name;
              s.saveProject(p);
            }
          }
          s.saveSettings();
          Navigator.pop(ctx);
        }),
      ],
    );
  });
}

void showCatalogForm(BuildContext context, CatalogItem? c) {
  final name = TextEditingController(text: c?.name ?? '');
  final price =
      TextEditingController(text: c != null ? c.price.toString() : '');
  String unit = c?.unit ?? einheiten.first;
  _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c == null ? 'Material-Preis anlegen' : 'Preis bearbeiten',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            _label('Bezeichnung'),
            TextField(
                controller: name,
                decoration:
                    const InputDecoration(hintText: 'z. B. Beton C25/30')),
            _label('Einheit'),
            DropdownButtonFormField<String>(
              initialValue: unit,
              dropdownColor: kCard2,
              items: einheiten
                  .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                  .toList(),
              onChanged: (v) => setSt(() => unit = v!),
            ),
            _label('Preis / Einheit (€)'),
            TextField(
                controller: price,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true)),
            _saveBtn('Speichern', () {
              if (name.text.trim().isEmpty) return;
              final pr = double.tryParse(price.text.replaceAll(',', '.')) ?? 0;
              final CatalogItem eintrag;
              if (c != null) {
                c.name = name.text.trim();
                c.unit = unit;
                c.price = pr;
                eintrag = c;
              } else {
                eintrag = CatalogItem(
                    id: uid(), name: name.text.trim(), unit: unit, price: pr);
                Store.I.catalog.add(eintrag);
              }
              Store.I.saveCatalogItem(eintrag);
              Navigator.pop(ctx);
            }),
          ]);
    });
  });
}

// ---- Kunde ----
void showCustomerForm(BuildContext context, Customer? existing) {
  final name = TextEditingController(text: existing?.name ?? '');
  final addr = TextEditingController(text: existing?.address ?? '');
  final contact = TextEditingController(text: existing?.contact ?? '');
  _sheet(context, (ctx) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(existing == null ? 'Neuer Kunde' : 'Kunde bearbeiten',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          _label('Name'),
          TextField(
              controller: name,
              decoration:
                  const InputDecoration(hintText: 'z. B. Familie Müller')),
          _label('Anschrift'),
          TextField(
              controller: addr,
              decoration: const InputDecoration(hintText: 'Straße, Ort')),
          _label('Kontakt (Tel. / E-Mail)'),
          TextField(
              controller: contact,
              decoration: const InputDecoration(hintText: 'z. B. 0621 123456')),
          _saveBtn('Speichern', () {
            if (name.text.trim().isEmpty) return;
            final Customer kunde;
            if (existing != null) {
              existing.name = name.text.trim();
              existing.address = addr.text.trim();
              existing.contact = contact.text.trim();
              kunde = existing;
            } else {
              kunde = Customer(
                  id: uid(),
                  name: name.text.trim(),
                  address: addr.text.trim(),
                  contact: contact.text.trim());
              Store.I.customers.add(kunde);
            }
            Store.I.saveCustomer(kunde);
            Navigator.pop(ctx);
          }),
        ]);
  });
}

// ---- Pauschale ----
void showPauschaleForm(BuildContext context, Pauschale? existing) {
  final name = TextEditingController(text: existing?.name ?? '');
  final amount = TextEditingController(
      text: existing != null ? existing.amount.toString() : '');
  _sheet(context, (ctx) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(existing == null ? 'Neue Pauschale' : 'Pauschale bearbeiten',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          _label('Bezeichnung'),
          TextField(
              controller: name,
              decoration:
                  const InputDecoration(hintText: 'z. B. Anfahrtspauschale')),
          _label('Betrag (€)'),
          TextField(
              controller: amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true)),
          _saveBtn('Speichern', () {
            if (name.text.trim().isEmpty) return;
            final a =
                double.tryParse(amount.text.trim().replaceAll(',', '.')) ?? 0;
            final Pauschale pauschale;
            if (existing != null) {
              existing.name = name.text.trim();
              existing.amount = a;
              pauschale = existing;
            } else {
              pauschale =
                  Pauschale(id: uid(), name: name.text.trim(), amount: a);
              Store.I.pauschalen.add(pauschale);
            }
            Store.I.savePauschale(pauschale);
            Navigator.pop(ctx);
          }),
        ]);
  });
}

// ---- Rolle ----
void showRoleForm(BuildContext context, String? existing) {
  final ctrl = TextEditingController(text: existing ?? '');
  _sheet(context, (ctx) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(existing == null ? 'Neue Rolle' : 'Rolle umbenennen',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        _label('Bezeichnung'),
        TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'z. B. Azubi'),
        ),
        _saveBtn('Speichern', () {
          final name = ctrl.text.trim();
          if (name.isEmpty) return;
          final s = Store.I;
          if (existing == kAdminRole && name != existing) {
            snack(context, 'Administrator kann nicht umbenannt werden.');
            return;
          }
          final dup = s.roles.any(
              (r) => r.toLowerCase() == name.toLowerCase() && r != existing);
          if (dup) {
            snack(context, 'Diese Rolle gibt es bereits.');
            return;
          }
          if (existing == null) {
            s.roles.add(name);
            s.rolePerms[name] = [];
          } else if (existing != name) {
            final i = s.roles.indexOf(existing);
            if (i >= 0) s.roles[i] = name;
            s.rolePerms[name] = s.rolePerms.remove(existing) ?? [];
            // Betroffene Benutzer einzeln nachziehen, sonst zeigt ihr
            // Datensatz weiterhin auf eine Rolle, die es nicht mehr gibt.
            for (final u in s.users.where((u) => u.role == existing).toList()) {
              u.role = name;
              s.saveUser(u);
            }
          }
          s.saveSettings();
          Navigator.pop(ctx);
        }),
      ],
    );
  });
}

// ---- Rolle: Berechtigungen ----
void showRolePermsForm(BuildContext context, String role) {
  final admin = role == kAdminRole;
  final sel = {...(Store.I.rolePerms[role] ?? const <String>[])};
  _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('Rechte – $role',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              if (!admin)
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    showRoleForm(context, role);
                  },
                  child: const Text('Umbenennen'),
                ),
            ]),
            if (admin)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text('Administrator hat immer alle Rechte.',
                    style: TextStyle(color: kMuted)),
              )
            else ...[
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: kPerms.entries
                        .map((e) => CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              activeColor: kAccent,
                              value: sel.contains(e.key),
                              onChanged: (v) => setSt(() {
                                if (v == true) {
                                  sel.add(e.key);
                                } else {
                                  sel.remove(e.key);
                                }
                              }),
                              title: Text(e.value),
                            ))
                        .toList(),
                  ),
                ),
              ),
              _saveBtn('Speichern', () {
                Store.I.rolePerms[role] = sel.toList();
                Store.I.saveSettings();
                Navigator.pop(ctx);
              }),
            ],
          ]);
    });
  });
}

// ---- Benutzer ----
//
// Anlegen und Rolle vergeben laufen über die Funktionen unter functions/ –
// beides darf das Gerät nicht selbst tun (siehe auth/auth_repository.dart).
// Der Stundenlohn bleibt dagegen rein betrieblich und wird nur lokal geführt.
void showUserForm(BuildContext context, AppUser? u) {
  final name = TextEditingController(text: u?.name ?? '');
  final email = TextEditingController(text: u?.email ?? '');
  final password = TextEditingController();
  final wageCtrl = TextEditingController(
      text: (u != null && u.wage > 0) ? u.wage.toString() : '');
  final rollen = Store.I.roles;
  final showWage = Store.I.can('wages');

  // Ein Benutzer aus der PIN-Zeit hat noch kein Konto. Für ihn ist dieses
  // Formular dasselbe wie für einen neuen – nur dass Name, Rolle und
  // Stundenlohn schon dastehen.
  final neuesKonto = u == null || !u.hasAccount;

  String role = u?.role ?? (rollen.isNotEmpty ? rollen.first : kAdminRole);
  String? fehler;
  bool busy = false;

  _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      Future<void> speichern() async {
        if (busy) return;
        if (name.text.trim().isEmpty) {
          setSt(() => fehler = 'Bitte einen Namen eingeben.');
          return;
        }
        if (neuesKonto) {
          if (email.text.trim().isEmpty) {
            setSt(() => fehler = 'Für die Anmeldung wird eine E-Mail gebraucht.');
            return;
          }
          if (password.text.length < 6) {
            setSt(() =>
                fehler = 'Das Passwort muss mindestens 6 Zeichen haben.');
            return;
          }
        } else if (password.text.isNotEmpty && password.text.length < 6) {
          setSt(() => fehler = 'Das Passwort muss mindestens 6 Zeichen haben.');
          return;
        }

        final w = showWage
            ? (double.tryParse(wageCtrl.text.trim().replaceAll(',', '.')) ?? 0)
            : null;

        setSt(() {
          busy = true;
          fehler = null;
        });
        try {
          if (neuesKonto) {
            final konto = await Store.I.auth.createUser(
              email: email.text,
              password: password.text,
              name: name.text,
              role: role,
            );
            if (u != null) {
              // Vorhandenen Datensatz übernehmen. Die Kennung wechselt dabei
              // auf die des Kontos – daran hängen ab jetzt Zeiterfassung und
              // Rechte. Früher automatisch erfasste Zeiten dieses Benutzers
              // bleiben unter der alten Kennung stehen; die Stunden an den
              // Aufträgen sind davon nicht betroffen, die tragen den Namen.
              Store.I.removeUser(u.id);
              u.id = konto.uid;
              u.name = name.text.trim();
              u.email = konto.email;
              u.role = role;
              u.pin = '';
              if (w != null) u.wage = w;
              Store.I.users.add(u);
              Store.I.saveUser(u);
            } else {
              final neu = AppUser(
                id: konto.uid,
                name: name.text.trim(),
                role: role,
                email: konto.email,
                wage: w ?? 0,
              );
              Store.I.users.add(neu);
              Store.I.saveUser(neu);
            }
          } else {
            await Store.I.auth.updateUser(
              uid: u.id,
              name: name.text,
              password: password.text.isEmpty ? null : password.text,
              role: role == u.role ? null : role,
            );
            u.name = name.text.trim();
            u.role = role;
            if (w != null) u.wage = w;
            Store.I.saveUser(u);
          }
          if (ctx.mounted) Navigator.pop(ctx);
        } on AuthFailure catch (e) {
          setSt(() => fehler = e.message);
        } finally {
          setSt(() => busy = false);
        }
      }

      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(u == null ? 'Neuer Benutzer' : 'Benutzer bearbeiten',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            if (u != null && !u.hasAccount)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Dieser Benutzer stammt noch aus der PIN-Zeit und kann sich '
                  'nicht anmelden. Hier bekommt er einen Zugang.',
                  style: TextStyle(color: kMuted, fontSize: 13, height: 1.35),
                ),
              ),
            _label('Name'),
            TextField(
                controller: name,
                enabled: !busy,
                decoration:
                    const InputDecoration(hintText: 'z. B. Anna Bauer')),
            _label('E-Mail'),
            TextField(
              controller: email,
              // Die Anmeldeadresse ist die Kennung des Kontos und wird hier
              // nicht geändert – dafür bräuchte es einen Bestätigungsweg.
              enabled: !busy && neuesKonto,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(hintText: 'name@betrieb.de'),
            ),
            _label(neuesKonto
                ? 'Passwort (mindestens 6 Zeichen)'
                : 'Neues Passwort (leer lassen = unverändert)'),
            TextField(
                controller: password,
                enabled: !busy,
                obscureText: true,
                autocorrect: false,
                decoration: const InputDecoration(hintText: '••••••')),
            _label('Rolle'),
            DropdownButtonFormField<String>(
              initialValue: role,
              dropdownColor: kCard2,
              items: {...rollen, role}
                  .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                  .toList(),
              onChanged: busy ? null : (v) => setSt(() => role = v!),
            ),
            if (showWage) ...[
              _label('Stundenlohn (€/h)'),
              TextField(
                  controller: wageCtrl,
                  enabled: !busy,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      hintText: 'z. B. 45 – leer = nicht hinterlegt')),
            ],
            if (fehler != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child:
                    Text(fehler!, style: TextStyle(color: kRed, fontSize: 13)),
              ),
            _saveBtn(busy ? 'Bitte warten …' : 'Speichern',
                busy ? null : speichern),
          ]);
    });
  });
}
