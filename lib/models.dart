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
  /// Bei Konten aus Firebase ist das die Auth-Kennung (uid), bei Altbestand die
  /// früher vergebene laufende Nummer.
  String id;
  String name, role;

  /// Anmeldename. Leer bei Benutzern aus der Zeit vor der Kontoanmeldung –
  /// daran erkennt die Verwaltung, für wen noch ein Konto fehlt.
  String email;

  /// Alter PIN-Zugang. Wird nicht mehr zur Anmeldung benutzt; das Feld bleibt,
  /// damit vorhandene Datenstände unverändert lesbar bleiben, und fällt mit dem
  /// Umzug der Benutzer nach Firestore weg.
  String pin;

  double wage; // Stundenlohn €/h (0 = nicht hinterlegt)
  AppUser(
      {required this.id,
      required this.name,
      required this.role,
      this.email = '',
      this.pin = '',
      this.wage = 0});

  /// Kann sich dieser Benutzer anmelden?
  bool get hasAccount => email.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'role': role,
        'email': email,
        'pin': pin,
        'wage': wage,
      };
  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
      id: j['id'],
      name: j['name'],
      role: j['role'],
      email: j['email'] ?? '',
      pin: j['pin'] ?? '',
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

// Zum früher hier stehenden Feld `synced`: es stand in jeder Stunden- und
// Materialzeile, wurde beim Anlegen einmal gesetzt und danach nie wieder
// angefasst – die Anzeige „nicht synchronisiert" konnte also nichts Wahres
// melden. Den Übertragungsstand kennt jetzt die Datenbank selbst: Firestore
// meldet ausstehende Schreibvorgänge. Er wird deshalb nicht mehr in der Zeile
// mitgespeichert, sondern erfragt (MasterDataRepository.pendingIn). Alte
// Datenstände dürfen das Feld weiterhin enthalten, es wird beim Lesen ignoriert.

class WorkHours {
  String id, worker, date, task;
  double h;
  WorkHours(
      {required this.id,
      required this.worker,
      required this.date,
      required this.task,
      required this.h});
  Map<String, dynamic> toJson() =>
      {'id': id, 'worker': worker, 'date': date, 'task': task, 'h': h};
  factory WorkHours.fromJson(Map<String, dynamic> j) => WorkHours(
      id: j['id'],
      worker: j['worker'],
      date: j['date'],
      task: j['task'] ?? '',
      h: (j['h'] as num).toDouble());
}

class MaterialItem {
  String id, name, unit, date;
  double qty, price;
  MaterialItem(
      {required this.id,
      required this.name,
      required this.unit,
      required this.date,
      required this.qty,
      required this.price});
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'unit': unit,
        'date': date,
        'qty': qty,
        'price': price
      };
  factory MaterialItem.fromJson(Map<String, dynamic> j) => MaterialItem(
      id: j['id'],
      name: j['name'],
      unit: j['unit'],
      date: j['date'] ?? '',
      qty: (j['qty'] as num).toDouble(),
      price: (j['price'] as num).toDouble());
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

/// Ein Foto zum Auftrag.
///
/// Das Bild selbst liegt in der Dateiablage (Cloud Storage), im Datensatz
/// steht nur der Verweis darauf. Anders geht es nicht: ein Firestore-Dokument
/// darf 1 MB groß sein, ein Foto als Base64 belegt davon 135–340 KB. Nach ein
/// paar Bildern ließe sich der Auftrag schlicht nicht mehr speichern – und
/// jedes Laden der Auftragsliste zöge alle Bilder über das Mobilfunknetz mit,
/// auch wenn sie niemand ansieht.
class Photo {
  String id;

  /// Abrufadresse in der Dateiablage. Leer, solange das Bild nur als [data]
  /// vorliegt.
  ///
  /// Sie enthält einen Schlüssel und funktioniert deshalb ohne Anmeldung – so
  /// sind die Adressen von Firebase gebaut, und nur deshalb kann ein Browser
  /// sie überhaupt anzeigen. Wer die Adresse hat, sieht das Bild; abgesichert
  /// ist der Weg zur Adresse, nicht das Bild dahinter. Siehe storage.rules.
  String url;

  /// Ablageort in der Dateiablage – nötig zum Löschen. Aus der Abrufadresse
  /// lässt er sich nicht zuverlässig zurückrechnen, deshalb steht er dabei.
  String storagePath;

  /// Wer hat das Foto aufgenommen, und wann.
  String uploadedBy;
  String createdAt;

  /// Das Bild als Base64 – der Altbestand.
  ///
  /// Vor der Dateiablage war ein Foto genau das und sonst nichts. Solche
  /// Einträge liegen auf jedem Gerät, das die App bisher benutzt hat; sie
  /// werden einmalig nachgereicht. Bis dahin zeigt die App sie von hier, damit
  /// in der Zwischenzeit kein Bild fehlt. Ohne Backend bleibt es dabei – auf
  /// dem Gerätespeicher gibt es keine Dateiablage.
  String data;

  Photo({
    required this.id,
    this.url = '',
    this.storagePath = '',
    this.uploadedBy = '',
    this.createdAt = '',
    this.data = '',
  });

  /// Liegt das Bild in der Dateiablage – oder noch als Base64 daneben?
  bool get inCloud => url.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'storagePath': storagePath,
        'uploadedBy': uploadedBy,
        'createdAt': createdAt,
        // Nur mitschreiben, was es gibt: sonst stünde in jedem neuen Foto ein
        // leeres Base64-Feld, das nie wieder etwas enthalten wird.
        if (data.isNotEmpty) 'data': data,
      };

  factory Photo.fromJson(Map<String, dynamic> j) => Photo(
        id: j['id'] ?? '',
        url: j['url'] ?? '',
        storagePath: j['storagePath'] ?? '',
        uploadedBy: j['uploadedBy'] ?? '',
        createdAt: j['createdAt'] ?? '',
        data: j['data'] ?? '',
      );

  /// Aus einem gespeicherten Eintrag beliebigen Alters.
  ///
  /// Früher stand in der Liste nur die Base64-Zeichenkette. Diese Einträge
  /// hier zu erkennen ist der Unterschied zwischen „die Bilder sind noch da"
  /// und „nach dem Aktualisieren verschwunden".
  static Photo fromAny(Object? eintrag, {String? ersatzId}) {
    if (eintrag is Map) {
      final foto = Photo.fromJson(Map<String, dynamic>.from(eintrag));
      if (foto.id.isEmpty) foto.id = ersatzId ?? uid();
      return foto;
    }
    return Photo(id: ersatzId ?? uid(), data: eintrag as String? ?? '');
  }
}

/// Die Fotoliste eines gespeicherten Auftrags – alt wie neu.
///
/// Die Ersatz-Id folgt der Benennung, unter der die Fotos in der Datenbank
/// abgelegt werden, damit ein Altbestand nach der Übernahme dieselben Namen
/// trägt und nicht doppelt erscheint.
List<Photo> _fotosAus(Object? roh) {
  final liste = (roh ?? const []) as List;
  return [
    for (var i = 0; i < liste.length; i++)
      Photo.fromAny(liste[i], ersatzId: 'foto_$i'),
  ];
}

class Project {
  String id, name, type, address, status, date, due, customerId;
  List<WorkHours> hours;
  List<MaterialItem> materials;
  List<Task> tasks;
  List<Note> notes;
  List<Photo> photos;
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
      List<Photo>? photos,
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
        'photos': photos.map((e) => e.toJson()).toList(),
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
        photos: _fotosAus(j['photos']),
        defects: ((j['defects'] ?? []) as List)
            .map((e) => Defect.fromJson(e))
            .toList(),
      );
}
