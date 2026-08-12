// Anmeldung über Firebase Authentication.
//
// Zwei Bausteine: `firebase_auth` für Anmelden/Abmelden auf dem Gerät und
// `cloud_functions` für alles, was nur ein Server darf – Konten anlegen und
// Rollen vergeben (siehe functions/index.js).

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';

import 'auth_repository.dart';

/// Gegend der Funktionen. Muss zu `REGION` in functions/index.js passen –
/// steht der Wert falsch, findet der Aufruf die Funktion schlicht nicht.
const kFunctionsRegion = 'europe-west3';

class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository({fb.FirebaseAuth? auth, FirebaseFunctions? functions})
      : _auth = auth ?? fb.FirebaseAuth.instance,
        _functions = functions ??
            FirebaseFunctions.instanceFor(region: kFunctionsRegion);

  final fb.FirebaseAuth _auth;
  final FirebaseFunctions _functions;

  /// Zuletzt gelesenes Konto. Gepflegt von [changes], damit [current] ohne
  /// Warten antworten kann – die Rolle steckt im Token und wäre sonst nur
  /// asynchron zu haben.
  Account? _current;

  @override
  Account? get current => _current;

  @override
  Stream<Account?> changes() =>
      _auth.authStateChanges().asyncMap(_toAccount).map((a) {
        _current = a;
        return a;
      });

  /// Firebase-Benutzer + Rolle aus dem Token zu einem [Account].
  Future<Account?> _toAccount(fb.User? user) async {
    if (user == null) return null;
    return Account(
      uid: user.uid,
      email: user.email ?? '',
      name: user.displayName ?? '',
      role: await _readRole(user),
    );
  }

  /// Die Rolle steht als Custom Claim im Token.
  ///
  /// Zuerst wird ein frisches Token geholt: hat der Administrator die Rolle
  /// geändert, gilt sie sonst bis zu einer Stunde lang nicht. Ohne Netz
  /// scheitert das – dann zählt das zwischengespeicherte Token. Das ist
  /// beabsichtigt: im Funkloch weiterarbeiten zu können wiegt schwerer als eine
  /// Rollenänderung sofort zu sehen. Die Sicherheitsregeln auf dem Server
  /// prüfen ohnehin gegen das echte Token.
  Future<String> _readRole(fb.User user) async {
    try {
      final t = await user.getIdTokenResult(true);
      return (t.claims?['role'] as String?) ?? '';
    } catch (_) {
      try {
        final t = await user.getIdTokenResult();
        return (t.claims?['role'] as String?) ?? '';
      } catch (e) {
        debugPrint('Rolle konnte nicht gelesen werden: $e');
        return '';
      }
    }
  }

  // -------------------------------------------------------------------------
  // Anmelden
  // -------------------------------------------------------------------------

  @override
  Future<Account> signIn(
      {required String email, required String password}) async {
    try {
      final c = await _auth.signInWithEmailAndPassword(
          email: email.trim(), password: password);
      final account = await _toAccount(c.user);
      if (account == null) {
        throw const AuthFailure('Die Anmeldung ist fehlgeschlagen.');
      }
      _current = account;
      return account;
    } on fb.FirebaseAuthException catch (e) {
      throw AuthFailure(_meldung(e));
    }
  }

  @override
  Future<void> signOut() async {
    await _auth.signOut();
    _current = null;
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on fb.FirebaseAuthException catch (e) {
      throw AuthFailure(_meldung(e));
    }
  }

  @override
  Future<void> changeOwnPassword({
    required String current,
    required String next,
  }) async {
    final user = _auth.currentUser;
    if (user == null || (user.email ?? '').isEmpty) {
      throw const AuthFailure('Nicht angemeldet.');
    }
    try {
      // Erneut bestätigen. Ohne das antwortet Firebase mit
      // `requires-recent-login`, sobald die Anmeldung älter als ein paar
      // Minuten ist – und das ist sie auf einem Baustellen-Handy immer.
      await user.reauthenticateWithCredential(
        fb.EmailAuthProvider.credential(email: user.email!, password: current),
      );
      await user.updatePassword(next);
    } on fb.FirebaseAuthException catch (e) {
      if (e.code == 'invalid-credential' || e.code == 'wrong-password') {
        throw const AuthFailure('Das bisherige Passwort stimmt nicht.');
      }
      throw AuthFailure(_meldung(e));
    }
  }

  /// Firebase-Fehlercodes in Klartext.
  ///
  /// `invalid-credential` fasst seit einer Weile falsches Passwort *und*
  /// unbekannte Adresse zusammen – absichtlich, damit sich nicht ausprobieren
  /// lässt, welche Adressen es gibt. Die Meldung bleibt deshalb bewusst
  /// unbestimmt.
  String _meldung(fb.FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'E-Mail-Adresse oder Passwort stimmt nicht.';
      case 'invalid-email':
        return 'Das ist keine gültige E-Mail-Adresse.';
      case 'user-disabled':
        return 'Dieses Konto wurde gesperrt.';
      case 'too-many-requests':
        return 'Zu viele Versuche. Bitte einige Minuten warten.';
      case 'network-request-failed':
        return 'Keine Verbindung. Zum Anmelden wird einmalig Netz gebraucht.';
      case 'operation-not-allowed':
        return 'Die Anmeldung per E-Mail ist im Projekt nicht freigeschaltet.';
      case 'weak-password':
        return 'Das Passwort muss mindestens 6 Zeichen haben.';
      case 'email-already-in-use':
        return 'Diese E-Mail-Adresse wird bereits verwendet.';
      default:
        debugPrint('Unbehandelter Anmeldefehler: ${e.code} ${e.message}');
        return 'Anmeldung fehlgeschlagen (${e.code}).';
    }
  }

  // -------------------------------------------------------------------------
  // Verwaltung über die Funktionen
  // -------------------------------------------------------------------------

  @override
  Future<Account> bootstrapAdmin({
    required String email,
    required String password,
    required String name,
  }) async {
    final antwort = await _call('bootstrapAdmin', {
      'email': email.trim(),
      'password': password,
      'name': name.trim(),
    });
    return Account(
      uid: antwort['uid'] as String,
      email: email.trim(),
      name: name.trim(),
      role: antwort['role'] as String? ?? '',
    );
  }

  @override
  Future<Account> createUser({
    required String email,
    required String password,
    required String name,
    required String role,
  }) async {
    final antwort = await _call('createUser', {
      'email': email.trim(),
      'password': password,
      'name': name.trim(),
      'role': role,
    });
    return Account(
      uid: antwort['uid'] as String,
      email: email.trim(),
      name: name.trim(),
      role: role,
    );
  }

  @override
  Future<void> updateUser({
    required String uid,
    String? name,
    String? password,
    String? role,
  }) async {
    await _call('updateUser', {
      'uid': uid,
      if (name != null) 'name': name.trim(),
      if (password != null && password.isNotEmpty) 'password': password,
      if (role != null) 'role': role,
    });
  }

  @override
  Future<void> deleteUser(String uid) => _call('deleteUser', {'uid': uid});

  @override
  Future<List<Account>> listUsers() async {
    final antwort = await _call('listUsers', const {});
    final liste = (antwort['users'] as List?) ?? const [];
    return liste.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return Account(
        uid: m['uid'] as String,
        email: m['email'] as String? ?? '',
        name: m['name'] as String? ?? '',
        role: m['role'] as String? ?? '',
      );
    }).toList();
  }

  /// Gemeinsamer Aufruf samt Übersetzung der Fehler.
  ///
  /// Die Funktionen schicken bei erwarteten Fällen bereits einen deutschen
  /// Klartext mit; der wird durchgereicht. Nur für alles Übrige steht hier ein
  /// Ersatztext.
  Future<Map<String, dynamic>> _call(
      String name, Map<String, dynamic> daten) async {
    try {
      final ergebnis = await _functions.httpsCallable(name).call(daten);
      return Map<String, dynamic>.from(ergebnis.data as Map? ?? const {});
    } on FirebaseFunctionsException catch (e) {
      final text = e.message;
      if (text != null && text.isNotEmpty && e.code != 'internal') {
        throw AuthFailure(text);
      }
      debugPrint('Funktion $name fehlgeschlagen: ${e.code} ${e.message}');
      throw AuthFailure(_funktionsMeldung(e.code));
    } catch (e) {
      debugPrint('Funktion $name fehlgeschlagen: $e');
      throw const AuthFailure(
          'Der Server ist nicht erreichbar. Bitte Verbindung prüfen.');
    }
  }

  String _funktionsMeldung(String code) {
    switch (code) {
      case 'unauthenticated':
        return 'Nicht angemeldet.';
      case 'permission-denied':
        return 'Dafür fehlen dir die Rechte.';
      case 'unavailable':
      case 'deadline-exceeded':
        return 'Der Server ist nicht erreichbar. Bitte Verbindung prüfen.';
      case 'not-found':
        return 'Die Serverfunktion fehlt. Wurde sie schon veröffentlicht?';
      default:
        return 'Der Vorgang ist fehlgeschlagen.';
    }
  }
}
