// Eine Anmeldung ohne Firebase – für Tests.
//
// Bildet nur nach, was das Verhalten der App beeinflusst: wer angemeldet ist,
// welche Rolle im Token steht und welche Fehler auftreten können. Die
// Feinheiten von Firebase (Token-Erneuerung, Netzverhalten) gehören nicht
// hierher; die prüft man auf einem Gerät.

import 'dart:async';

import 'package:baudoc/auth/auth_repository.dart';

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository();

  final _ctrl = StreamController<Account?>.broadcast();

  /// Vorhandene Konten: uid -> Konto.
  final Map<String, Account> konten = {};

  /// Passwörter: E-Mail -> Passwort.
  final Map<String, String> passwoerter = {};

  /// Mitschrift der Aufrufe – damit ein Test belegen kann, dass die App den
  /// Server fragt, statt Konten selbst anzulegen.
  final List<String> aufrufe = [];

  Account? _current;
  int _naechsteUid = 1;

  /// Legt ein Konto an, ohne den Anmeldezustand zu ändern (Testaufbau).
  Account hinterlege(
      {required String email,
      required String password,
      String name = '',
      String role = ''}) {
    final konto = Account(
        uid: 'uid${_naechsteUid++}', email: email, name: name, role: role);
    konten[konto.uid] = konto;
    passwoerter[email] = password;
    return konto;
  }

  @override
  Account? get current => _current;

  @override
  Stream<Account?> changes() async* {
    yield _current;
    yield* _ctrl.stream;
  }

  void _melde(Account? a) {
    _current = a;
    _ctrl.add(a);
  }

  @override
  Future<Account> signIn(
      {required String email, required String password}) async {
    aufrufe.add('signIn:$email');
    if (passwoerter[email.trim()] != password) {
      throw const AuthFailure('E-Mail-Adresse oder Passwort stimmt nicht.');
    }
    final konto =
        konten.values.firstWhere((k) => k.email == email.trim());
    _melde(konto);
    return konto;
  }

  @override
  Future<void> signOut() async {
    aufrufe.add('signOut');
    _melde(null);
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    aufrufe.add('reset:$email');
  }

  @override
  Future<void> changeOwnPassword(
      {required String current, required String next}) async {
    final konto = _current;
    if (konto == null) throw const AuthFailure('Nicht angemeldet.');
    if (passwoerter[konto.email] != current) {
      throw const AuthFailure('Das bisherige Passwort stimmt nicht.');
    }
    passwoerter[konto.email] = next;
    aufrufe.add('changeOwnPassword');
  }

  @override
  Future<Account> bootstrapAdmin(
      {required String email,
      required String password,
      required String name}) async {
    aufrufe.add('bootstrapAdmin:$email');
    if (konten.values.any((k) => k.role == kAdminRolleImTest)) {
      throw const AuthFailure(
          'Es gibt bereits einen Administrator. Bitte normal anmelden.');
    }
    return hinterlege(
        email: email.trim(),
        password: password,
        name: name.trim(),
        role: kAdminRolleImTest);
  }

  @override
  Future<Account> createUser(
      {required String email,
      required String password,
      required String name,
      required String role}) async {
    aufrufe.add('createUser:$email:$role');
    if (passwoerter.containsKey(email.trim())) {
      throw const AuthFailure('Diese E-Mail-Adresse wird bereits verwendet.');
    }
    return hinterlege(
        email: email.trim(),
        password: password,
        name: name.trim(),
        role: role);
  }

  @override
  Future<void> updateUser(
      {required String uid, String? name, String? password, String? role}) async {
    aufrufe.add('updateUser:$uid:${role ?? '-'}');
    final alt = konten[uid];
    if (alt == null) throw const AuthFailure('Dieser Benutzer existiert nicht.');
    konten[uid] = Account(
      uid: uid,
      email: alt.email,
      name: name?.trim() ?? alt.name,
      role: role ?? alt.role,
    );
    if (password != null) passwoerter[alt.email] = password;
  }

  @override
  Future<void> deleteUser(String uid) async {
    aufrufe.add('deleteUser:$uid');
    final weg = konten.remove(uid);
    if (weg != null) passwoerter.remove(weg.email);
  }

  @override
  Future<List<Account>> listUsers() async {
    aufrufe.add('listUsers');
    return konten.values.toList();
  }

  void dispose() => _ctrl.close();
}

/// Doppelt gehalten statt aus models.dart importiert: der Fake soll auch dann
/// noch aussagekräftig sein, wenn jemand die Konstante in der App umbenennt –
/// dann fällt der Test auf, statt stillschweigend mitzugehen.
const kAdminRolleImTest = 'Administrator';
