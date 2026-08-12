// Serverseitige Benutzerverwaltung für BauDoc.
//
// Warum überhaupt Server-Code? Legt die App selbst ein Konto an
// (`createUserWithEmailAndPassword`), meldet Firebase das Gerät **sofort als
// diesen neuen Benutzer** an – der Administrator wäre mitten in der
// Benutzerverwaltung ausgeloggt. Anlegen gehört deshalb hierher.
//
// Der zweite Grund: die Rolle wird als *Custom Claim* ins Anmelde-Token
// geschrieben. Nur so können die Firestore-Sicherheitsregeln (Schritt 4) die
// Rolle prüfen, ohne für jeden Zugriff einen Datensatz nachzuladen. Claims darf
// ausschließlich das Admin-SDK setzen, also der Server.
//
// Alle Funktionen laufen in europe-west3 (Frankfurt) – dieselbe Gegend wie die
// spätere Datenbank, das spart Laufzeit bei Aufrufen zwischen beiden.

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');

initializeApp();

const REGION = 'europe-west3';
const ADMIN_ROLE = 'Administrator'; // muss zu kAdminRole in lib/models.dart passen

// ---------------------------------------------------------------------------
// Hilfen
// ---------------------------------------------------------------------------

/// Wirft, wenn der Aufrufer kein Administrator ist.
///
/// Geprüft wird der Claim im Token, nicht irgendeine Angabe aus der App: die
/// Oberfläche kann lügen, ein von Firebase signiertes Token nicht.
function requireAdmin(request) {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Nicht angemeldet.');
  }
  if (request.auth.token.role !== ADMIN_ROLE) {
    throw new HttpsError(
      'permission-denied',
      'Nur ein Administrator darf Benutzer verwalten.',
    );
  }
}

/// Pflichtfeld aus den Aufrufdaten holen.
function requireText(data, feld, bezeichnung) {
  const wert = (data[feld] || '').trim();
  if (!wert) {
    throw new HttpsError('invalid-argument', `${bezeichnung} fehlt.`);
  }
  return wert;
}

/// Übersetzt die Fehler des Admin-SDK in Meldungen, die in der App etwas
/// nützen. Alles Unbekannte kommt als 'internal' durch – dann steht der
/// Klartext im Funktions-Protokoll und nicht auf dem Handy des Monteurs.
function alsHttpsError(e) {
  switch (e.code) {
    case 'auth/email-already-exists':
      return new HttpsError(
        'already-exists',
        'Diese E-Mail-Adresse wird bereits verwendet.',
      );
    case 'auth/invalid-email':
      return new HttpsError('invalid-argument', 'Die E-Mail-Adresse ist ungültig.');
    case 'auth/invalid-password':
      return new HttpsError(
        'invalid-argument',
        'Das Passwort muss mindestens 6 Zeichen haben.',
      );
    case 'auth/user-not-found':
      return new HttpsError('not-found', 'Dieser Benutzer existiert nicht (mehr).');
    default:
      console.error('Unerwarteter Fehler:', e);
      return new HttpsError('internal', 'Der Vorgang ist fehlgeschlagen.');
  }
}

/// Gibt es schon irgendwo ein Administrator-Konto?
///
/// Durchsucht die Konten seitenweise. Für einen Handwerksbetrieb sind das
/// Dutzende, nicht Tausende – ein einzelner Durchlauf genügt also.
async function adminVorhanden() {
  let seite;
  do {
    const ergebnis = await getAuth().listUsers(1000, seite);
    const treffer = ergebnis.users.some(
      (u) => u.customClaims && u.customClaims.role === ADMIN_ROLE,
    );
    if (treffer) return true;
    seite = ergebnis.pageToken;
  } while (seite);
  return false;
}

// ---------------------------------------------------------------------------
// Ersteinrichtung
// ---------------------------------------------------------------------------

/// Legt das allererste Administrator-Konto an.
///
/// Henne und Ei: Benutzer anlegen darf nur ein Administrator, aber am Anfang
/// gibt es keinen. Diese Funktion ist der Ausweg – und sie schließt sich selbst:
/// sobald irgendein Konto den Administrator-Claim trägt, verweigert sie jede
/// weitere Anfrage. Das Zeitfenster ist genau ein Aufruf lang.
exports.bootstrapAdmin = onCall({ region: REGION }, async (request) => {
  const email = requireText(request.data, 'email', 'E-Mail-Adresse');
  const password = requireText(request.data, 'password', 'Passwort');
  const name = requireText(request.data, 'name', 'Name');

  if (await adminVorhanden()) {
    throw new HttpsError(
      'failed-precondition',
      'Es gibt bereits einen Administrator. Bitte normal anmelden.',
    );
  }

  try {
    const benutzer = await getAuth().createUser({
      email,
      password,
      displayName: name,
    });
    await getAuth().setCustomUserClaims(benutzer.uid, { role: ADMIN_ROLE });
    console.log('Ersteinrichtung: Administrator angelegt', benutzer.uid);
    return { uid: benutzer.uid, role: ADMIN_ROLE };
  } catch (e) {
    throw alsHttpsError(e);
  }
});

// ---------------------------------------------------------------------------
// Laufende Verwaltung
// ---------------------------------------------------------------------------

/// Legt einen Benutzer an und hinterlegt seine Rolle im Token.
exports.createUser = onCall({ region: REGION }, async (request) => {
  requireAdmin(request);

  const email = requireText(request.data, 'email', 'E-Mail-Adresse');
  const password = requireText(request.data, 'password', 'Passwort');
  const name = requireText(request.data, 'name', 'Name');
  const role = requireText(request.data, 'role', 'Rolle');

  try {
    const benutzer = await getAuth().createUser({
      email,
      password,
      displayName: name,
    });
    await getAuth().setCustomUserClaims(benutzer.uid, { role });
    return { uid: benutzer.uid, role };
  } catch (e) {
    throw alsHttpsError(e);
  }
});

/// Ändert Rolle, Name oder Passwort eines Benutzers.
///
/// Achtung beim Rollenwechsel: der Betroffene behält seine bisherigen Rechte,
/// bis sein Token erneuert wird (spätestens nach einer Stunde, sofort beim
/// nächsten App-Start – die App holt das Token beim Start bewusst frisch).
exports.updateUser = onCall({ region: REGION }, async (request) => {
  requireAdmin(request);

  const uid = requireText(request.data, 'uid', 'Benutzer-Kennung');
  const { name, password, role } = request.data;

  try {
    const aenderungen = {};
    if (name && name.trim()) aenderungen.displayName = name.trim();
    if (password && password.trim()) aenderungen.password = password.trim();
    if (Object.keys(aenderungen).length > 0) {
      await getAuth().updateUser(uid, aenderungen);
    }

    if (role && role.trim()) {
      // Der letzte Administrator darf sich nicht selbst degradieren – sonst
      // kommt niemand mehr an die Verwaltung.
      if (
        uid === request.auth.uid &&
        role.trim() !== ADMIN_ROLE &&
        !(await weitererAdminVorhanden(uid))
      ) {
        throw new HttpsError(
          'failed-precondition',
          'Du bist der einzige Administrator. Ernenne zuerst einen zweiten.',
        );
      }
      await getAuth().setCustomUserClaims(uid, { role: role.trim() });
    }
    return { uid };
  } catch (e) {
    throw e instanceof HttpsError ? e : alsHttpsError(e);
  }
});

/// Löscht ein Konto.
exports.deleteUser = onCall({ region: REGION }, async (request) => {
  requireAdmin(request);
  const uid = requireText(request.data, 'uid', 'Benutzer-Kennung');

  if (uid === request.auth.uid) {
    throw new HttpsError(
      'failed-precondition',
      'Das eigene Konto kann nicht gelöscht werden.',
    );
  }

  try {
    await getAuth().deleteUser(uid);
    return { uid };
  } catch (e) {
    throw alsHttpsError(e);
  }
});

/// Gibt es außer [ausser] noch einen weiteren Administrator?
async function weitererAdminVorhanden(ausser) {
  let seite;
  do {
    const ergebnis = await getAuth().listUsers(1000, seite);
    const treffer = ergebnis.users.some(
      (u) =>
        u.uid !== ausser &&
        u.customClaims &&
        u.customClaims.role === ADMIN_ROLE,
    );
    if (treffer) return true;
    seite = ergebnis.pageToken;
  } while (seite);
  return false;
}

/// Alle Konten samt Rolle – Grundlage der Benutzerliste in der Verwaltung.
///
/// Die App führt zwar eine eigene Benutzerliste, aber die kann von den
/// tatsächlichen Konten abweichen (etwa nach einer Neuinstallation). Diese
/// Abfrage zeigt, was wirklich existiert.
exports.listUsers = onCall({ region: REGION }, async (request) => {
  requireAdmin(request);
  try {
    const alle = [];
    let seite;
    do {
      const ergebnis = await getAuth().listUsers(1000, seite);
      for (const u of ergebnis.users) {
        alle.push({
          uid: u.uid,
          email: u.email || '',
          name: u.displayName || '',
          role: (u.customClaims && u.customClaims.role) || '',
          disabled: u.disabled,
        });
      }
      seite = ergebnis.pageToken;
    } while (seite);
    return { users: alle };
  } catch (e) {
    throw alsHttpsError(e);
  }
});
