import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Plattform-spezifischer Datei-Export (Web-Download vs. Teilen-Dialog).
import 'csv_export_io.dart'
    if (dart.library.js_interop) 'csv_export_web.dart';
import 'pdf_invoice.dart';

// ===================================================================
// BauDoc – Flutter/Dart-Portierung des HTML-Prototyps
// Eine Datei, damit der Einstieg einfach bleibt. Später gern aufteilen.
// ===================================================================

// ---------- Konstanten ----------
const kBg = Color(0xFF0E1218);
const kBg2 = Color(0xFF151B24);
const kCard = Color(0xFF1A212C);
const kCard2 = Color(0xFF222B38);
const kLine = Color(0xFF2A3340);
const kInk = Color(0xFFEEF2F7);
const kInk2 = Color(0xFFC2CCD8);
const kMuted = Color(0xFF7D8A9A);
const kAccent = Color(0xFFF6A623);
const kAccentInk = Color(0xFF1A1300);
const kGreen = Color(0xFF36C46A);
const kBlue = Color(0xFF4F9DFF);
const kViolet = Color(0xFFA78BFA);
const kRed = Color(0xFFEF5F55);

// Standard-Kategorien (Gewerke) – nur zum Erstbefüllen. Zur Laufzeit ist die
// Liste über Store.I.arten pro Firma bearbeitbar und wird persistiert.
const defaultArten = [
  'Solaranlage',
  'Wärmepumpe',
  'Heizung',
  'Sanitär',
  'Elektro',
  'Dach',
  'Neubau',
  'Sonstiges'
];
const rollen = ['Baustelle', 'Büro/Buchhaltung', 'Administrator'];
const einheiten = ['Stk', 'm', 'm²', 'm³', 'kg', 't', 'l', 'h', 'Pkt'];

// ---------- Helfer ----------
int _seq = 0;
String uid() => '${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
String today() => DateTime.now().toIso8601String().substring(0, 10);
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

// ---------- Modelle ----------
class AppUser {
  String id, name, role, pin;
  AppUser(
      {required this.id,
      required this.name,
      required this.role,
      required this.pin});
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'role': role, 'pin': pin};
  factory AppUser.fromJson(Map<String, dynamic> j) =>
      AppUser(id: j['id'], name: j['name'], role: j['role'], pin: j['pin']);
}

class CatalogItem {
  String id, name, unit;
  double price;
  CatalogItem(
      {required this.id,
      required this.name,
      required this.unit,
      required this.price});
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'unit': unit, 'price': price};
  factory CatalogItem.fromJson(Map<String, dynamic> j) => CatalogItem(
      id: j['id'],
      name: j['name'],
      unit: j['unit'],
      price: (j['price'] as num).toDouble());
}

class WorkHours {
  String id, worker, date, task;
  double h;
  bool synced;
  WorkHours(
      {required this.id,
      required this.worker,
      required this.date,
      required this.task,
      required this.h,
      required this.synced});
  Map<String, dynamic> toJson() => {
        'id': id,
        'worker': worker,
        'date': date,
        'task': task,
        'h': h,
        'synced': synced
      };
  factory WorkHours.fromJson(Map<String, dynamic> j) => WorkHours(
      id: j['id'],
      worker: j['worker'],
      date: j['date'],
      task: j['task'] ?? '',
      h: (j['h'] as num).toDouble(),
      synced: j['synced'] ?? true);
}

class MaterialItem {
  String id, name, unit, date;
  double qty, price;
  bool synced;
  MaterialItem(
      {required this.id,
      required this.name,
      required this.unit,
      required this.date,
      required this.qty,
      required this.price,
      required this.synced});
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'unit': unit,
        'date': date,
        'qty': qty,
        'price': price,
        'synced': synced
      };
  factory MaterialItem.fromJson(Map<String, dynamic> j) => MaterialItem(
      id: j['id'],
      name: j['name'],
      unit: j['unit'],
      date: j['date'] ?? '',
      qty: (j['qty'] as num).toDouble(),
      price: (j['price'] as num).toDouble(),
      synced: j['synced'] ?? true);
}

class Task {
  String id, title, due;
  bool done;
  Task(
      {required this.id,
      required this.title,
      required this.due,
      required this.done});
  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'due': due, 'done': done};
  factory Task.fromJson(Map<String, dynamic> j) => Task(
      id: j['id'],
      title: j['title'],
      due: j['due'] ?? '',
      done: j['done'] ?? false);
}

class Note {
  String id, date, text;
  Note({required this.id, required this.date, required this.text});
  Map<String, dynamic> toJson() => {'id': id, 'date': date, 'text': text};
  factory Note.fromJson(Map<String, dynamic> j) =>
      Note(id: j['id'], date: j['date'] ?? '', text: j['text'] ?? '');
}

class Project {
  String id, name, type, address, status, date, due;
  List<WorkHours> hours;
  List<MaterialItem> materials;
  List<Task> tasks;
  List<Note> notes;
  List<String> photos;
  Project(
      {required this.id,
      required this.name,
      required this.type,
      required this.address,
      required this.status,
      required this.hours,
      required this.materials,
      required this.tasks,
      this.date = '',
      this.due = '',
      List<Note>? notes,
      List<String>? photos})
      : notes = notes ?? [],
        photos = photos ?? [];
  bool get isOpen => status == 'active';
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'address': address,
        'status': status,
        'date': date,
        'due': due,
        'hours': hours.map((e) => e.toJson()).toList(),
        'materials': materials.map((e) => e.toJson()).toList(),
        'tasks': tasks.map((e) => e.toJson()).toList(),
        'notes': notes.map((e) => e.toJson()).toList(),
        'photos': photos,
      };
  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'],
        name: j['name'],
        type: j['type'] ?? '',
        address: j['address'] ?? '',
        status: j['status'] ?? 'active',
        date: j['date'] ?? '',
        due: j['due'] ?? '',
        hours: ((j['hours'] ?? []) as List)
            .map((e) => WorkHours.fromJson(e))
            .toList(),
        materials: ((j['materials'] ?? []) as List)
            .map((e) => MaterialItem.fromJson(e))
            .toList(),
        tasks:
            ((j['tasks'] ?? []) as List).map((e) => Task.fromJson(e)).toList(),
        notes:
            ((j['notes'] ?? []) as List).map((e) => Note.fromJson(e)).toList(),
        photos: ((j['photos'] ?? []) as List).map((e) => e as String).toList(),
      );
}

// ---------- Store (Daten + Persistenz) ----------
class Store extends ChangeNotifier {
  static final Store I = Store._();
  Store._();

  List<CatalogItem> catalog = [];
  List<Project> projects = [];
  List<AppUser> users = [];
  List<String> arten = List.of(defaultArten); // Kategorien/Gewerke (bearbeitbar)
  bool online = true;
  bool _adminSeeded = false;
  String? sessionId;
  late SharedPreferences _p;

  static const _key = 'baudoc.flutter';
  static const _skey = 'baudoc.session';

  AppUser? get currentUser {
    for (final u in users) {
      if (u.id == sessionId) return u;
    }
    return null;
  }

  bool get canAdmin =>
      currentUser?.role == 'Büro/Buchhaltung' ||
      currentUser?.role == 'Administrator';

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p.getString(_key);
    var ok = false;
    if (raw != null) {
      try {
        _fromJson(jsonDecode(raw) as Map<String, dynamic>);
        ok = true;
      } catch (_) {}
    }
    if (!ok) _seed();
    if (users.isEmpty) users = _defaultUsers();
    // Einmalige Migration: einen Administrator-Benutzer sicherstellen
    if (!_adminSeeded) {
      if (!users.any((u) => u.role == 'Administrator')) {
        users.add(AppUser(
            id: uid(),
            name: 'Administrator',
            role: 'Administrator',
            pin: '0000'));
      }
      _adminSeeded = true;
      save();
    }
    sessionId = _p.getString(_skey);
  }

  void save() {
    _p.setString(_key, jsonEncode(_toJson()));
    notifyListeners();
  }

  void _saveSession() {
    if (sessionId != null) {
      _p.setString(_skey, sessionId!);
    } else {
      _p.remove(_skey);
    }
  }

  Map<String, dynamic> _toJson() => {
        'catalog': catalog.map((e) => e.toJson()).toList(),
        'projects': projects.map((e) => e.toJson()).toList(),
        'users': users.map((e) => e.toJson()).toList(),
        'arten': arten,
        'online': online,
        'adminSeeded': _adminSeeded,
      };

  void _fromJson(Map<String, dynamic> j) {
    catalog = ((j['catalog'] ?? []) as List)
        .map((e) => CatalogItem.fromJson(e))
        .toList();
    projects = ((j['projects'] ?? []) as List)
        .map((e) => Project.fromJson(e))
        .toList();
    users =
        ((j['users'] ?? []) as List).map((e) => AppUser.fromJson(e)).toList();
    // Migration: ältere Datenstände ohne 'arten' bekommen die Standardliste.
    final rawArten = (j['arten'] as List?)?.cast<String>();
    arten = (rawArten == null || rawArten.isEmpty)
        ? List.of(defaultArten)
        : rawArten;
    online = j['online'] ?? true;
    _adminSeeded = j['adminSeeded'] ?? false;
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
        AppUser(id: uid(), name: 'Bauleiter', role: 'Baustelle', pin: '1111'),
        AppUser(id: uid(), name: 'Büro', role: 'Büro/Buchhaltung', pin: '2222'),
      ];

  void _seed() {
    catalog = _defaultCatalog();
    users = _defaultUsers();
    arten = List.of(defaultArten);
    projects = [
      Project(
        id: uid(),
        name: 'Neubau Müllerstr. 12',
        type: 'Neubau',
        address: 'Müllerstr. 12, Speyer',
        status: 'active',
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
    online = true;
    _adminSeeded = true;
  }

  // Auth
  bool login(String id, String pin) {
    for (final u in users) {
      if (u.id == id && u.pin == pin) {
        sessionId = u.id;
        _saveSession();
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  void logout() {
    sessionId = null;
    _saveSession();
    notifyListeners();
  }

  Project? projectById(String id) {
    for (final p in projects) {
      if (p.id == id) return p;
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

// ===================================================================
// App
// ===================================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.I.load();
  runApp(const BauDocApp());
}

class BauDocApp extends StatelessWidget {
  const BauDocApp({super.key});
  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'BauDoc',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: kBg,
        colorScheme: base.colorScheme.copyWith(
          primary: kAccent,
          secondary: kAccent,
          surface: kCard,
        ),
        cardColor: kCard,
        appBarTheme: const AppBarTheme(
            backgroundColor: kBg2, foregroundColor: kInk, elevation: 0),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: kCard2,
          hintStyle: const TextStyle(color: kMuted),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kLine)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kLine)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: kAccent)),
        ),
      ),
      home: const RootGate(),
    );
  }
}

class RootGate extends StatelessWidget {
  const RootGate({super.key});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Store.I,
      builder: (_, __) => Store.I.currentUser == null
          ? const LoginScreen()
          : const HomeScreen(),
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
  String? userId;
  final pin = TextEditingController();
  String? error;

  @override
  void initState() {
    super.initState();
    if (Store.I.users.isNotEmpty) userId = Store.I.users.first.id;
  }

  void _doLogin() {
    if (userId == null) return;
    if (!Store.I.login(userId!, pin.text.trim())) {
      setState(() => error = 'PIN ist falsch.');
    }
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
                const SizedBox(height: 24),
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                      color: kAccent.withValues(alpha: .13),
                      borderRadius: BorderRadius.circular(20)),
                  child: const Icon(Icons.apartment, color: kAccent, size: 34),
                ),
                const SizedBox(height: 14),
                const Text('BauDoc',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                const Text('Bitte anmelden',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kMuted)),
                const SizedBox(height: 22),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Benutzer',
                            style: TextStyle(color: kMuted, fontSize: 13)),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          initialValue: userId,
                          dropdownColor: kCard2,
                          isExpanded: true,
                          items: Store.I.users
                              .map((u) => DropdownMenuItem(
                                  value: u.id,
                                  child: Text('${u.name} — ${u.role}',
                                      overflow: TextOverflow.ellipsis)))
                              .toList(),
                          onChanged: (v) => setState(() => userId = v),
                        ),
                        const SizedBox(height: 12),
                        const Text('PIN',
                            style: TextStyle(color: kMuted, fontSize: 13)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: pin,
                          obscureText: true,
                          keyboardType: TextInputType.number,
                          onSubmitted: (_) => _doLogin(),
                          decoration: const InputDecoration(hintText: '••••'),
                        ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(error!,
                                style:
                                    const TextStyle(color: kRed, fontSize: 13)),
                          ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: kAccent,
                                foregroundColor: kAccentInk),
                            onPressed: _doLogin,
                            child: const Padding(
                                padding: EdgeInsets.symmetric(vertical: 6),
                                child: Text('Anmelden')),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Demo-Zugänge:\nAdministrator · PIN 0000\nBauleiter · PIN 1111\nBüro/Buchhaltung · PIN 2222',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: kMuted, fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- Home / Aufträge ----------
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
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: GestureDetector(
            onTap: () => showProfileSheet(context),
            child: Center(
              child: CircleAvatar(
                radius: 17,
                backgroundColor: kAccent,
                child: Text(initials(s.currentUser?.name ?? '?'),
                    style: const TextStyle(
                        color: kAccentInk,
                        fontWeight: FontWeight.w800,
                        fontSize: 13)),
              ),
            ),
          ),
        ),
        title: const Text('Aufträge',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: kAccent,
        foregroundColor: kAccentInk,
        onPressed: () => showProjectForm(context),
        child: const Icon(Icons.add),
      ),
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

          return Column(
            children: [
              // Reiter
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                child: Row(children: [
                  _tabBtn('Offen', openN, 'offen'),
                  const SizedBox(width: 8),
                  _tabBtn('Abgeschlossen', doneN, 'done'),
                ]),
              ),
              // Suche
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon:
                        const Icon(Icons.search, size: 20, color: kMuted),
                    hintText: 'Auftrag suchen …',
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
              // Filter-Chips: alle Gewerke
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
                      _chip(t, filter == t,
                          () => setState(() => filter = t),
                          count: countFor(t)),
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

  Widget _tabBtn(String label, int count, String value) {
    final on = tab == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => tab = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: on ? kAccent : kCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? kAccent : kLine),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      color: on ? kAccentInk : kMuted)),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: (on ? kAccentInk : kMuted).withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$count',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                        color: on ? kAccentInk : kMuted)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap, {int? count}) {
    final c = on ? kAccent : kInk2;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: on ? kAccent.withValues(alpha: .15) : kCard2,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: on ? kAccent : kLine),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label,
                  style: TextStyle(
                      color: c,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600)),
              if (count != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: c.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text('$count',
                      style: TextStyle(
                          color: c,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(List<Project> list) {
    if (list.isEmpty) {
      final msg = filter != null
          ? 'Keine „$filter"-Aufträge unter ${tab == 'offen' ? 'Offen' : 'Abgeschlossen'}.'
          : (tab == 'offen'
              ? 'Keine offenen Aufträge.\nTippe auf +, um einen anzulegen.'
              : 'Noch keine abgeschlossenen Aufträge.');
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(30),
        child: Text(msg,
            textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
      ));
    }
    if (filter != null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 90),
        children: [_projectCard(list)],
      );
    }
    // gruppiert nach Gewerk
    final groups = <String, List<Project>>{};
    for (final p in list) {
      groups.putIfAbsent(p.type.isEmpty ? 'Ohne Art' : p.type, () => []).add(p);
    }
    final keys = groups.keys.toList()..sort();
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 90),
      children: [
        for (final k in keys) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
            child: Text('$k  (${groups[k]!.length})',
                style: const TextStyle(
                    color: kMuted,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: .6)),
          ),
          _projectCard(groups[k]!),
        ],
      ],
    );
  }

  Widget _projectCard(List<Project> items) {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            _projectRow(items[i]),
            if (i < items.length - 1) const Divider(height: 1, color: kLine),
          ]
        ],
      ),
    );
  }

  Widget _projectRow(Project p) {
    final pend = pending(p);
    final sub = [
      if (p.address.isNotEmpty) p.address,
      '${sumHours(p).toStringAsFixed(sumHours(p) % 1 == 0 ? 0 : 1)} h',
      eur(sumMaterial(p)),
    ].join(' · ');
    return ListTile(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => ProjectScreen(projectId: p.id))),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
            color: (p.isOpen ? kGreen : kInk2).withValues(alpha: .13),
            borderRadius: BorderRadius.circular(12)),
        child:
            Icon(Icons.apartment, color: p.isOpen ? kGreen : kInk2, size: 22),
      ),
      isThreeLine: p.tasks.isNotEmpty,
      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kMuted)),
          if (p.tasks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: Row(children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: p.tasks.where((t) => t.done).length /
                          p.tasks.length,
                      minHeight: 5,
                      backgroundColor: kLine,
                      valueColor: const AlwaysStoppedAnimation(kGreen),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                    '${p.tasks.where((t) => t.done).length}/${p.tasks.length}',
                    style: const TextStyle(color: kMuted, fontSize: 11)),
              ]),
            ),
        ],
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (pend > 0)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.schedule, size: 14, color: kAccent),
              Text('$pend',
                  style: const TextStyle(
                      color: kAccent, fontWeight: FontWeight.w700)),
            ]),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
              color: (p.isOpen ? kGreen : kMuted).withValues(alpha: .15),
              borderRadius: BorderRadius.circular(20)),
          child: Text(p.isOpen ? 'Offen' : 'Abgeschlossen',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: p.isOpen ? kGreen : kMuted)),
        ),
      ]),
    );
  }
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
        return Scaffold(
          appBar: AppBar(title: Text(p.name), actions: [
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: 'Als PDF exportieren',
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
                      style: const TextStyle(
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
                  const Divider(height: 1, color: kLine),
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
                  const Divider(height: 1, color: kLine),
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
                const Padding(
                  padding: EdgeInsets.only(left: 4, bottom: 4),
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
                        subtitle: Text(dLong(p.notes[i].date),
                            style: const TextStyle(color: kMuted)),
                        trailing: IconButton(
                          icon:
                              const Icon(Icons.delete_outline, color: kMuted),
                          onPressed: () {
                            p.notes.removeAt(i);
                            Store.I.save();
                          },
                        ),
                      ),
                      if (i > 0) const Divider(height: 1, color: kLine),
                    ],
                  ]),
                ),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () {
                  p.status = p.isOpen ? 'done' : 'active';
                  Store.I.save();
                },
                child: Text(p.isOpen
                    ? 'Auftrag als abgeschlossen markieren'
                    : 'Wieder als offen setzen'),
              ),
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
                    Store.I.projects.removeWhere((x) => x.id == p.id);
                    Store.I.save();
                  }
                },
              ),
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
              Text(lbl, style: const TextStyle(fontSize: 10.5, color: kMuted)),
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
        subtitle: Text(s, style: const TextStyle(color: kMuted)),
        trailing: const Icon(Icons.chevron_right, color: kMuted),
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
                          Store.I.save();
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
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_a_photo_outlined, color: kAccent),
                    SizedBox(height: 4),
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
      Store.I.save();
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
              ? const Center(
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
                                      style: const TextStyle(color: kMuted)),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        color: kMuted),
                                    onPressed: () {
                                      p.hours.removeWhere((x) => x.id == h.id);
                                      Store.I.save();
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
              ? const Center(
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
                                      style: const TextStyle(color: kMuted)),
                                  trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(eur(m.qty * m.price),
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700)),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline,
                                              color: kMuted),
                                          onPressed: () {
                                            p.materials.removeWhere(
                                                (x) => x.id == m.id);
                                            Store.I.save();
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
              ? const Center(
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
                                      Store.I.save();
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
                                          style:
                                              const TextStyle(color: kMuted)),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        color: kMuted),
                                    onPressed: () {
                                      p.tasks.removeWhere((x) => x.id == t.id);
                                      Store.I.save();
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
        if (!Store.I.canAdmin) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => Navigator.of(context).maybePop());
          return const Scaffold(body: SizedBox.shrink());
        }
        final s = Store.I;
        return Scaffold(
          appBar: AppBar(title: const Text('Verwaltung')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
            children: [
              const _SectionTitle('Material-Preisliste'),
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: s.catalog
                      .map((c) => ListTile(
                            onTap: () => showCatalogForm(context, c),
                            leading: const Icon(Icons.euro, color: kViolet),
                            title: Text(c.name),
                            subtitle: Text('${eur(c.price)} / ${c.unit}',
                                style: const TextStyle(color: kMuted)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: kMuted),
                              onPressed: () {
                                s.catalog.removeWhere((x) => x.id == c.id);
                                s.save();
                              },
                            ),
                          ))
                      .toList(),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Preis hinzufügen'),
                  onPressed: () => showCatalogForm(context, null),
                ),
              ),
              const SizedBox(height: 10),
              const _SectionTitle('Kategorien / Gewerke'),
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: s.arten.map((a) {
                    final used = s.projects.where((p) => p.type == a).length;
                    return ListTile(
                      onTap: () => showCategoryForm(context, a),
                      leading: const Icon(Icons.category_outlined, color: kBlue),
                      title: Text(a),
                      subtitle: Text(
                          used == 0
                              ? 'Nicht verwendet'
                              : '$used Auftrag${used == 1 ? '' : 'e'}',
                          style: const TextStyle(color: kMuted)),
                      trailing: IconButton(
                        icon:
                            const Icon(Icons.delete_outline, color: kMuted),
                        onPressed: () => _delCategory(context, a),
                      ),
                    );
                  }).toList(),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Kategorie hinzufügen'),
                  onPressed: () => showCategoryForm(context, null),
                ),
              ),
              const SizedBox(height: 10),
              const _SectionTitle('Benutzer'),
              Card(
                margin: EdgeInsets.zero,
                child: Column(
                  children: s.users
                      .map((u) => ListTile(
                            onTap: () => showUserForm(context, u),
                            leading: const Icon(Icons.person_outline,
                                color: kAccent),
                            title: Text(
                                '${u.name}${u.id == s.sessionId ? '  (du)' : ''}'),
                            subtitle: Text('${u.role} · PIN ${u.pin}',
                                style: const TextStyle(color: kMuted)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: kMuted),
                              onPressed: () => _delUser(context, u),
                            ),
                          ))
                      .toList(),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Benutzer hinzufügen'),
                  onPressed: () => showUserForm(context, null),
                ),
              ),
            ],
          ),
        );
      },
    );
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
      s.save();
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
    if (ok) {
      Store.I.users.removeWhere((x) => x.id == u.id);
      Store.I.save();
    }
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 9),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
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
                child: const Text('OK', style: TextStyle(color: kRed))),
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
    backgroundColor: kBg2,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 18,
          bottom: 18 + MediaQuery.of(ctx).viewInsets.bottom),
      child: builder(ctx),
    ),
  );
}

Widget _label(String t) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6, left: 2),
      child: Text(t,
          style: const TextStyle(
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
          const Icon(Icons.event, size: 18, color: kMuted),
          const SizedBox(width: 8),
          Text(value.isEmpty ? hint : dLong(value),
              style: TextStyle(color: value.isEmpty ? kMuted : kInk)),
        ]),
      ),
    );

Widget _saveBtn(String label, VoidCallback onTap) => Padding(
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
String _fileSlug(String s) {
  final slug = s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return slug.isEmpty ? 'auftrag' : slug;
}

Future<void> exportProjectPdf(BuildContext context, Project p) async {
  final ctrl = TextEditingController();
  await _sheet(context, (ctx) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('PDF exportieren',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('Leistungsnachweis / Rechnung für diesen Auftrag.',
            style: TextStyle(color: kMuted, fontSize: 13)),
        _label('Stundensatz (€/h, optional)'),
        TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            hintText: 'z.B. 45 – leer lassen für nur Stundenanzahl',
            isDense: true,
          ),
        ),
        _saveBtn('PDF erstellen', () async {
          final satz =
              double.tryParse(ctrl.text.trim().replaceAll(',', '.')) ?? 0;
          Navigator.pop(ctx);
          final bytes = await buildProjectInvoicePdf(p, stundensatz: satz);
          final fname = 'baudoc_${_fileSlug(p.name)}_${today()}.pdf';
          await downloadBytes(fname, bytes, 'application/pdf');
          if (context.mounted) snack(context, 'PDF erstellt: $fname');
        }),
      ],
    );
  });
}

// ---- CSV-Export ----
String _csvCell(String s) {
  if (s.contains('"') ||
      s.contains(';') ||
      s.contains(',') ||
      s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String _num(num n) => n.toStringAsFixed(2).replaceAll('.', ',');

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
  ].map(_csvCell).join(sep));
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
      _num(totalH),
      _num(matCost),
      '$doneTasks',
      '${p.tasks.length}',
    ].map(_csvCell).join(sep));
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
      final hasFilter =
          gewerk != null || statusF != 'alle' || von.isNotEmpty || bis.isNotEmpty;

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
              style: const TextStyle(color: kMuted, fontSize: 13)),
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
          const Divider(color: kLine, height: 1),
          // ---- Liste (gefiltert, scrollbar) ----
          Flexible(
            child: vis.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
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
                            style:
                                const TextStyle(color: kMuted, fontSize: 12)),
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
                    style: const TextStyle(
                        color: kAccentInk,
                        fontWeight: FontWeight.w800,
                        fontSize: 20))),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(u.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              Text(u.role, style: const TextStyle(color: kMuted)),
            ]),
          ]),
          const SizedBox(height: 14),
          if (Store.I.canAdmin) ...[
            ListTile(
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AdminScreen()));
              },
              leading: const Icon(Icons.admin_panel_settings_outlined,
                  color: kViolet),
              title: const Text('Verwaltung'),
              subtitle: const Text('Material-Preise, Kategorien, Benutzer',
                  style: TextStyle(color: kMuted, fontSize: 12)),
              tileColor: kCard,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            const SizedBox(height: 8),
            ListTile(
              onTap: () async {
                Navigator.pop(ctx);
                await exportProjectsCsv(context);
              },
              leading: const Icon(Icons.download, color: kBlue),
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
              showPinForm(context);
            },
            leading: const Icon(Icons.tune, color: kAccent),
            title: const Text('PIN ändern'),
            tileColor: kCard,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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

void showPinForm(BuildContext context) {
  final pin = TextEditingController();
  _sheet(context, (ctx) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('PIN ändern',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          _label('Neuer PIN (4-stellig)'),
          TextField(
              controller: pin,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(hintText: '••••')),
          _saveBtn('Speichern', () {
            final v = pin.text.trim();
            if (!RegExp(r'^\d{4}$').hasMatch(v)) {
              snack(ctx, 'Bitte 4 Ziffern eingeben.');
              return;
            }
            Store.I.currentUser!.pin = v;
            Store.I.save();
            Navigator.pop(ctx);
          }),
        ]);
  });
}

// ---- Auftrag ----
void showProjectForm(BuildContext context) {
  final name = TextEditingController();
  final addr = TextEditingController();
  String type = Store.I.arten.isNotEmpty ? Store.I.arten.first : 'Sonstiges';
  String date = today();
  String due = '';
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
              Store.I.projects.insert(
                  0,
                  Project(
                      id: uid(),
                      name: name.text.trim(),
                      type: type,
                      address: addr.text.trim(),
                      status: 'active',
                      date: date,
                      due: due,
                      hours: [],
                      materials: [],
                      tasks: []));
              Store.I.save();
              Navigator.pop(ctx);
            }),
          ]);
    });
  });
}

// ---- Bautagebuch ----
void showNoteForm(BuildContext context, Project p) {
  final text = TextEditingController();
  _sheet(context, (ctx) {
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
          _saveBtn('Eintrag speichern', () {
            if (text.text.trim().isEmpty) return;
            p.notes
                .add(Note(id: uid(), date: today(), text: text.text.trim()));
            Store.I.save();
            Navigator.pop(ctx);
          }),
        ]);
  });
}

// ---- Stunden ----
void showHoursForm(BuildContext context, Project p) {
  final worker = TextEditingController(text: 'Ich');
  final hrs = TextEditingController(text: '8');
  final task = TextEditingController();
  _sheet(context, (ctx) {
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Stunden eintragen',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          _label('Mitarbeiter'),
          TextField(controller: worker),
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
                worker: worker.text.trim().isEmpty ? 'Ich' : worker.text.trim(),
                date: today(),
                task: task.text.trim(),
                h: double.tryParse(hrs.text.replaceAll(',', '.')) ?? 0,
                synced: Store.I.online));
            Store.I.save();
            Navigator.pop(ctx);
          }),
        ]);
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
                    style: const TextStyle(
                        color: kAccent, fontWeight: FontWeight.w600)),
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
              Store.I.save();
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
            Store.I.save();
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
          final dup = s.arten
              .any((a) => a.toLowerCase() == name.toLowerCase() && a != existing);
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
            for (final p in s.projects.where((p) => p.type == existing)) {
              p.type = name;
            }
          }
          s.save();
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
              if (c != null) {
                c.name = name.text.trim();
                c.unit = unit;
                c.price = pr;
              } else {
                Store.I.catalog.add(CatalogItem(
                    id: uid(), name: name.text.trim(), unit: unit, price: pr));
              }
              Store.I.save();
              Navigator.pop(ctx);
            }),
          ]);
    });
  });
}

// ---- Benutzer ----
void showUserForm(BuildContext context, AppUser? u) {
  final name = TextEditingController(text: u?.name ?? '');
  final pin = TextEditingController(text: u?.pin ?? '');
  String role = u?.role ?? rollen.first;
  _sheet(context, (ctx) {
    return StatefulBuilder(builder: (ctx, setSt) {
      return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(u == null ? 'Neuer Benutzer' : 'Benutzer bearbeiten',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            _label('Name'),
            TextField(
                controller: name,
                decoration:
                    const InputDecoration(hintText: 'z. B. Anna Bauer')),
            _label('Rolle'),
            DropdownButtonFormField<String>(
              initialValue: role,
              dropdownColor: kCard2,
              items: rollen
                  .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                  .toList(),
              onChanged: (v) => setSt(() => role = v!),
            ),
            _label('PIN (4-stellig)'),
            TextField(
                controller: pin,
                keyboardType: TextInputType.number,
                maxLength: 4),
            _saveBtn('Speichern', () {
              if (name.text.trim().isEmpty) return;
              if (!RegExp(r'^\d{4}$').hasMatch(pin.text.trim())) {
                snack(ctx, 'Bitte einen 4-stelligen PIN eingeben.');
                return;
              }
              if (u != null) {
                u.name = name.text.trim();
                u.role = role;
                u.pin = pin.text.trim();
              } else {
                Store.I.users.add(AppUser(
                    id: uid(),
                    name: name.text.trim(),
                    role: role,
                    pin: pin.text.trim()));
              }
              Store.I.save();
              Navigator.pop(ctx);
            }),
          ]);
    });
  });
}
