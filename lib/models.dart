// Datenmodelle und die dazugehörigen Konstanten.
//
// Ausgelagert aus main.dart, damit die Datenschicht unter lib/data/ die
// Modelle benutzen kann, ohne die App-Datei zurückzuimportieren. Enthält
// bewusst nichts aus Flutter – dadurch bleiben die Modelle ohne Gerät und
// ohne Oberfläche testbar.

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
// Rollen sind zur Laufzeit über Store.roles frei bearbeitbar; diese Liste dient
// nur dem Erstbefüllen. 'Administrator' ist geschützt und hat immer alle Rechte.
const kAdminRole = 'Administrator';
const defaultRollen = ['Administrator', 'Büro', 'Meister', 'Handwerker'];

// Berechtigungen: Schlüssel → Anzeigename (erweiterbar). Jede Rolle bekommt in
// Store.rolePerms eine Teilmenge davon zugewiesen.
const kPerms = <String, String>{
  'wages': 'Stundenlöhne verwalten',
  'pauschalen': 'Pauschalen verwalten',
  'materialPrices': 'Material-Preise verwalten',
  'categories': 'Kategorien verwalten',
  'usersRoles': 'Benutzer & Rollen verwalten',
  'exportDocs': 'Rechnung / CSV exportieren',
  'editProjects': 'Aufträge anlegen & bearbeiten',
  'deleteProjects': 'Aufträge löschen',
};
// Diese Rechte machen den Verwaltungs-Bereich sichtbar.
const kManagePerms = [
  'pauschalen',
  'materialPrices',
  'categories',
  'usersRoles'
];
// Legacy-Rollennamen → neue Rollen (einmalige Migration bestehender Daten).
const kRoleRename = {'Büro/Buchhaltung': 'Büro', 'Baustelle': 'Handwerker'};

const einheiten = ['Stk', 'm', 'm²', 'm³', 'kg', 't', 'l', 'h', 'Pkt'];

// ---------- Id-Vergabe ----------
int _seq = 0;
String uid() => '${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
String today() => DateTime.now().toIso8601String().substring(0, 10);

// ---------- Modelle ----------
class AppUser {
  String id, name, role, pin;
  double wage; // Stundenlohn €/h (0 = nicht hinterlegt)
  AppUser(
      {required this.id,
      required this.name,
      required this.role,
      required this.pin,
      this.wage = 0});
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'role': role, 'pin': pin, 'wage': wage};
  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
      id: j['id'],
      name: j['name'],
      role: j['role'],
      pin: j['pin'],
      wage: (j['wage'] as num?)?.toDouble() ?? 0);
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

class Pauschale {
  String id, name;
  double amount;
  Pauschale({required this.id, required this.name, required this.amount});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'amount': amount};
  factory Pauschale.fromJson(Map<String, dynamic> j) => Pauschale(
      id: j['id'],
      name: j['name'] ?? '',
      amount: (j['amount'] as num?)?.toDouble() ?? 0);
}

class Customer {
  String id, name, address, contact;
  Customer(
      {required this.id,
      required this.name,
      this.address = '',
      this.contact = ''});
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'address': address, 'contact': contact};
  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
      id: j['id'],
      name: j['name'] ?? '',
      address: j['address'] ?? '',
      contact: j['contact'] ?? '');
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

class Defect {
  String id, title, description, date;
  bool done;
  Defect(
      {required this.id,
      required this.title,
      this.description = '',
      this.date = '',
      this.done = false});
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'date': date,
        'done': done
      };
  factory Defect.fromJson(Map<String, dynamic> j) => Defect(
      id: j['id'],
      title: j['title'] ?? '',
      description: j['description'] ?? '',
      date: j['date'] ?? '',
      done: j['done'] ?? false);
}

class Note {
  String id, date, text, weather, temp;
  Note(
      {required this.id,
      required this.date,
      required this.text,
      this.weather = '',
      this.temp = ''});
  Map<String, dynamic> toJson() =>
      {'id': id, 'date': date, 'text': text, 'weather': weather, 'temp': temp};
  factory Note.fromJson(Map<String, dynamic> j) => Note(
      id: j['id'],
      date: j['date'] ?? '',
      text: j['text'] ?? '',
      weather: j['weather'] ?? '',
      temp: j['temp'] ?? '');
}

class Project {
  String id, name, type, address, status, date, due, customerId;
  List<WorkHours> hours;
  List<MaterialItem> materials;
  List<Task> tasks;
  List<Note> notes;
  List<String> photos;
  List<Defect> defects;
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
      this.customerId = '',
      List<Note>? notes,
      List<String>? photos,
      List<Defect>? defects})
      : notes = notes ?? [],
        photos = photos ?? [],
        defects = defects ?? [];
  bool get isOpen => status == 'active';
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'address': address,
        'status': status,
        'date': date,
        'due': due,
        'customerId': customerId,
        'hours': hours.map((e) => e.toJson()).toList(),
        'materials': materials.map((e) => e.toJson()).toList(),
        'tasks': tasks.map((e) => e.toJson()).toList(),
        'notes': notes.map((e) => e.toJson()).toList(),
        'photos': photos,
        'defects': defects.map((e) => e.toJson()).toList(),
      };
  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'],
        name: j['name'],
        type: j['type'] ?? '',
        address: j['address'] ?? '',
        status: j['status'] ?? 'active',
        date: j['date'] ?? '',
        due: j['due'] ?? '',
        customerId: j['customerId'] ?? '',
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
        defects: ((j['defects'] ?? []) as List)
            .map((e) => Defect.fromJson(e))
            .toList(),
      );
}
