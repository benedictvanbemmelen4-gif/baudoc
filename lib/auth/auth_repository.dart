// Anmeldung und Kontoverwaltung hinter einem Vertrag.
//
// Gleiches Muster wie `data/master_data_repository.dart` und
// `timetracking/data/tracking_repository.dart`: die Oberfläche kennt nur diesen
// Vertrag, nicht Firebase. Dadurch bleiben Anmeldebildschirm und
// Benutzerverwaltung ohne Netz und ohne Gerät testbar.

/// Ein Anmelde-Konto, so wie der Server es kennt.
///
/// Bewusst getrennt von [AppUser]: dort stehen die betrieblichen Angaben
/// (Stundenlohn, Zuordnung zu Aufträgen), hier nur, was zur Anmeldung gehört.
/// Verbunden sind beide über dieselbe Kennung – [uid] ist `AppUser.id`.
class Account {
  final String uid;
  final String email;
  final String name;

  /// Kommt aus dem Anmelde-Token (Custom Claim), nicht aus der App. Leer, wenn
  /// dem Konto noch keine Rolle zugewiesen wurde.
  final String role;

  const Account({
    required this.uid,
    required this.email,
    this.name = '',
    this.role = '',
  });
}

/// Fehler, dessen [message] man einem Benutzer unverändert zeigen kann.
///
/// Alles, was aus Firebase kommt, wird in der Umsetzung übersetzt – auf der
/// Baustelle nützt „firebase_auth/invalid-credential" niemandem.
class AuthFailure implements Exception {
  final String message;
  const AuthFailure(this.message);
  @override
  String toString() => message;
}

abstract class AuthRepository {
  /// Meldet jede Änderung des Anmeldezustands, beginnend mit dem aktuellen.
  ///
  /// Firebase stellt die Sitzung beim App-Start selbst wieder her; deshalb
  /// kommt hier nach einem Neustart ohne Zutun wieder das angemeldete Konto.
  Stream<Account?> changes();

  /// Das gerade angemeldete Konto, oder null.
  Account? get current;

  Future<Account> signIn({required String email, required String password});
  Future<void> signOut();

  /// Verschickt eine E-Mail zum Zurücksetzen des Passworts.
  Future<void> sendPasswordReset(String email);

  /// Ändert das eigene Passwort.
  ///
  /// [current] wird gebraucht, weil Firebase für diesen Schritt eine frische
  /// Anmeldung verlangt – sonst könnte jeder, der ein entsperrtes Handy in die
  /// Hand bekommt, das Konto übernehmen.
  Future<void> changeOwnPassword({
    required String current,
    required String next,
  });

  // -- Verwaltung. Läuft über die Funktionen unter functions/, weil Konten
  //    anzulegen und Rollen zu vergeben nicht Sache des Geräts sein darf.

  /// Legt das allererste Administrator-Konto an. Schlägt fehl, sobald es
  /// bereits einen Administrator gibt.
  Future<Account> bootstrapAdmin({
    required String email,
    required String password,
    required String name,
  });

  Future<Account> createUser({
    required String email,
    required String password,
    required String name,
    required String role,
  });

  /// Ändert Name, Passwort und/oder Rolle. Weggelassene Angaben bleiben.
  Future<void> updateUser({
    required String uid,
    String? name,
    String? password,
    String? role,
  });

  Future<void> deleteUser(String uid);

  /// Alle tatsächlich vorhandenen Konten – die Verwaltung gleicht damit ihre
  /// eigene Benutzerliste ab.
  Future<List<Account>> listUsers();
}
