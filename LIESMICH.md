# NitraX für iPhone

Native iOS-App (SwiftUI, ab iOS 17) für NitraX AI Studio – gebaut in der Cloud, ohne eigenen Mac.

## Was die App kann
- **Studio**: PC-Status (Engine, GPU, Spiel-Erkennung), laufende Aufträge live, Warteschlange anhalten/fortsetzen, wartende abbrechen, zuletzt Fertiges, Schnellstart
- **Erstellen**: alle Workflows deines PCs (Video, Bild, Audio) – Formulare kommen vom PC, inkl. Fotos/Kamera, Videos, Songs, Zeichnen (Apple Pencil), Melodie aufnehmen, Stimmen, Bildmodelle, 🪄 Prompt-Helfer
- **Aufträge**: Liste mit Filter und Suche, Fortschritt live, Video/Bild/Ton abspielen, Teilen, in Fotos sichern, Abbrechen, ▶ Fortsetzen (Musikvideo/Film); Weitermachen: 🎲 Variante, ⤢ 2×/4× größer, 💎 Maximal, 🎞 Film-Look, ▶ Animieren, ◧ Ändern, ⇥ Verlängern, 👍/👎 (NitraX lernt mit)
- **Chat**: Workflow-Agent und Chat mit Live-Antwort, Bilder anhängen, Werkzeug-Schritte, Sprung zu den angelegten Aufträgen
- **Helfer**: dein 3D-Helfer – Figur, Touch-Gesten, Gespräch mit Stimme, 🎤 Sprechen (App nimmt auf, stoppt von selbst, klappt auch im WLAN), 📷 Kamera (Foto zeigen, er schaut es sich an), Spiele, Listen, Wecker
- **Push-Mitteilungen**: sofort vom PC über Apple – Auftrag fertig (in der Stimme deines Helfers), Fehler, Selfies, Wecker; Antippen öffnet den Auftrag bzw. der Helfer sagt dir die Nachricht
- **Siri & Kurzbefehle**: »Frag NitraX«, »Wie weit ist NitraX«, »Erstelle mit NitraX«, »Male mit NitraX«, »Pausiere NitraX«, »NitraX weitermachen« – ohne die App zu öffnen
- **Widget**: Home- und Sperrbildschirm – laufende Aufträge mit Fortschrittsring, Warteschlange, zuletzt fertig

Verbindung: QR-Code aus NitraX AI Studio → Einstellungen → Handy. Zu Hause über WLAN, unterwegs über Tailscale (zweiten QR-Code mit der Tailscale-Adresse in der App unter Einstellungen hinzufügen).

## Einmalig einrichten (ca. 20 Minuten)

### 1. Apple Developer (developer.apple.com → Certificates, Identifiers & Profiles)
1. **Identifiers → App Groups → +**: `group.de.infinitras.nitrax`
2. **Identifiers → App IDs → +** (App): Bundle-ID `de.infinitras.nitrax`, Capability **App Groups** an → obige Gruppe zuordnen
3. Zwei weitere App-IDs: `de.infinitras.nitrax.widget` und `de.infinitras.nitrax.teilen`, beide mit **App Groups** (dieselbe Gruppe)
4. Bei der App-ID `de.infinitras.nitrax` zusätzlich **Push Notifications** anhaken
5. **Keys → +**: Name »NitraX Push«, **Apple Push Notifications service (APNs)** anhaken → herunterladen (`AuthKey_….p8`, geht nur EINMAL) und die **Key-ID** notieren
6. **Membership**: Team-ID notieren (10 Zeichen)

### 2. App Store Connect (appstoreconnect.apple.com)
1. **Meine Apps → + → Neue App**: Plattform iOS, Name »NitraX« (oder ein freier Name), Sprache Deutsch, Bundle-ID `de.infinitras.nitrax`, SKU z. B. `nitrax-ios`
2. **Benutzer und Zugriff → Integrationen → App Store Connect API → Team-Schlüssel → +**: Name »GitHub«, Zugriff **Admin**
   - `.p8`-Datei herunterladen (geht nur EINMAL!), **Key-ID** und **Issuer-ID** notieren

### 3. GitHub (github.com, kostenloses Konto)
1. Neues **privates** Repository anlegen, z. B. `nitrax-ios`
2. Diesen Ordner hochladen (am einfachsten mit **GitHub Desktop**: »Add local repository« → diesen Ordner → Publish, »Keep this code private« an)
3. **Settings → Secrets and variables → Actions → New repository secret** – vier Einträge:
   | Name | Inhalt |
   |---|---|
   | `APPLE_TEAM_ID` | Team-ID |
   | `ASC_KEY_ID` | Key-ID |
   | `ASC_ISSUER_ID` | Issuer-ID |
   | `ASC_PRIVATE_KEY` | kompletter Inhalt der `.p8`-Datei (mit `-----BEGIN …` und `-----END …`) |

### 4. Bauen
- Nach dem Hochladen läuft **»Prüfen«** von selbst (Reiter **Actions**) – grün = Code fehlerfrei.
- **Actions → iOS → Run workflow** (Häkchen »Zu TestFlight hochladen«) → nach ~15 min liegt der Build in TestFlight.
- Beim ersten Build fragt App Store Connect evtl. nach der Exportkonformität – ist schon beantwortet (keine eigene Verschlüsselung).

### 5. Aufs iPhone
- App **TestFlight** aus dem App Store laden, dich in App Store Connect unter **TestFlight → Interne Tests** als Tester eintragen → Einladung annehmen → NitraX installieren.
- In NitraX: **QR-Code scannen** (am PC: Einstellungen → Handy → Handy-Zugang an). iOS fragt nach »Lokales Netzwerk« → erlauben.

### 6. Push am PC einschalten
NitraX AI Studio → **Einstellungen → Handy → 📲 iPhone-Push**: Team-ID und Key-ID eintragen, **🔑 .p8-Datei wählen** (die APNs-Datei aus Schritt 1.5), **Speichern**. Sobald die App auf dem iPhone Mitteilungen erlaubt hat, steht dort »1 iPhone angemeldet« → **🔔 Test-Push**.

## Neue Version
Code ändern → hochladen → **Run workflow**. Die Build-Nummer zählt automatisch hoch.

## Gut zu wissen
- Ohne eingerichteten Push meldet die App sich über die iOS-Hintergrundaktualisierung (alle 15–60 min) – mit Push sofort.
- Der PC sendet Push direkt an Apple (eigener kleiner HTTP/2-Sender in NitraX, keine Fremddienste dazwischen).
- Der Schlüssel aus dem QR-Code bleibt auf dem iPhone (App-Gruppe, nur für App und Widget).
