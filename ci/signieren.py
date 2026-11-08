#!/usr/bin/env python3
"""Signatur für TestFlight ohne registriertes Gerät – über die App-Store-Connect-API.

  einrichten  – Schlüssel + CSR erzeugen, Verteilungszertifikat anlegen, je Bundle-ID ein App-Store-Profil,
                alles in einen Wegwerf-Schlüsselbund bzw. den Profil-Ordner legen. Schreibt $GITHUB_ENV:
                NX_PROFIL_APP / _WIDGET / _TEILEN (Profilnamen) und NX_SIGNATUR (Pfad zur Aufräumliste).
  aufraeumen  – Wegwerf-Schlüsselbund + Schlüssel löschen. Das Zertifikat des Laufs widerruft erst der NÄCHSTE
                Lauf (fertige TestFlight-Builds bleiben gültig) – so sammeln sich keine Zertifikate an (Limit!).

Umgebung: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (Pfad zur .p8), RUNNER_TEMP, GITHUB_RUN_NUMBER.
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request

import jwt  # PyJWT (auf dem Build-Rechner installiert)

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLES = {"APP": "de.infinitras.nitrax", "WIDGET": "de.infinitras.nitrax.widget", "TEILEN": "de.infinitras.nitrax.teilen"}
TMP = os.environ.get("RUNNER_TEMP", "/tmp")
ORDNER = os.path.join(TMP, "signatur")
LISTE = os.path.join(ORDNER, "angelegt.json")
KC = os.path.join(TMP, "nitrax-signatur.keychain-db")
KC_PW = "nx-" + os.environ.get("GITHUB_RUN_ID", "lokal")


def token():
    jetzt = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": jetzt, "exp": jetzt + 900, "aud": "appstoreconnect-v1"},
                      open(os.environ["ASC_KEY_PATH"]).read(), algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def api(methode, pfad, daten=None):
    req = urllib.request.Request(API + pfad, method=methode, data=json.dumps(daten).encode() if daten else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as a:
            roh = a.read()
            return json.loads(roh) if roh else {}
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "ignore")
        raise SystemExit("::error::App-Store-Connect %s %s -> %s: %s" % (methode, pfad.split("?")[0], e.code, text[:600]))


def sh(*args, **kw):
    subprocess.run(args, check=True, **kw)


def env_setzen(name, wert):
    with open(os.environ["GITHUB_ENV"], "a") as f:
        f.write("%s=%s\n" % (name, wert))


def einrichten():
    os.makedirs(ORDNER, exist_ok=True)
    lauf = os.environ.get("GITHUB_RUN_NUMBER", "0")
    angelegt = {"profile": [], "zertifikat": None}

    # Reste früherer Läufe wegräumen: unsere »NitraX CI«-Profile und -Zertifikate (erst jetzt, damit Apple den
    # vorigen Upload in Ruhe verarbeiten konnte). Fremde Zertifikate werden nie angefasst.
    # Apple schreibt den Zertifikatsnamen um - unsere Zertifikate erkennt man an den »NitraX CI«-Profilen, die sie nutzen.
    ci_zert = set()
    for p in api("GET", "/profiles?limit=200&fields[profiles]=name&include=certificates").get("data", []):
        if p["attributes"]["name"].startswith("NitraX CI "):
            for c in (p.get("relationships", {}).get("certificates", {}).get("data") or []):
                ci_zert.add(c["id"])
            api("DELETE", "/profiles/" + p["id"])
    for cid in ci_zert:
        try:
            api("DELETE", "/certificates/" + cid)
            print("altes CI-Zertifikat widerrufen:", cid)
        except SystemExit as e:
            print(e)

    # 1) Schlüssel + Zertifikatsanfrage
    key = os.path.join(ORDNER, "schluessel.pem")
    csr = os.path.join(ORDNER, "anfrage.csr")
    sh("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr,
       "-subj", "/CN=NitraX CI %s/O=NitraX/C=DE" % lauf)

    # 2) Verteilungszertifikat
    z = api("POST", "/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": open(csr).read()}}})["data"]
    angelegt["zertifikat"] = z["id"]
    json.dump(angelegt, open(LISTE, "w"))
    cer = os.path.join(ORDNER, "zertifikat.cer")
    open(cer, "wb").write(base64.b64decode(z["attributes"]["certificateContent"]))
    print("Zertifikat angelegt:", z["attributes"].get("name"), z["attributes"].get("serialNumber"))

    # 3) Wegwerf-Schlüsselbund
    sh("security", "create-keychain", "-p", KC_PW, KC)
    sh("security", "set-keychain-settings", "-lut", "21600", KC)
    sh("security", "unlock-keychain", "-p", KC_PW, KC)
    sh("security", "import", key, "-k", KC, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    sh("security", "import", cer, "-k", KC, "-T", "/usr/bin/codesign")
    sh("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", KC_PW, KC,
       stdout=subprocess.DEVNULL)
    vorher = subprocess.run(["security", "list-keychains", "-d", "user"], capture_output=True, text=True).stdout
    alte = [z.strip().strip('"') for z in vorher.splitlines() if z.strip()]
    sh("security", "list-keychains", "-d", "user", "-s", KC, *alte)
    sh("security", "find-identity", "-v", "-p", "codesigning", KC)

    # 4) App-Store-Profile je Bundle-ID
    zielordner = [os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),
                  os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")]
    for o in zielordner:
        os.makedirs(o, exist_ok=True)
    for kurz, bundle in BUNDLES.items():
        treffer = [b for b in api("GET", "/bundleIds?filter[identifier]=%s&limit=50" % bundle).get("data", [])
                   if b["attributes"]["identifier"] == bundle and b["attributes"].get("platform") in ("IOS", "UNIVERSAL")]
        if not treffer:
            raise SystemExit("::error::App-ID %s fehlt im Entwicklerportal" % bundle)
        name = "NitraX CI %s %s" % (lauf, kurz.lower())
        p = api("POST", "/profiles", {"data": {"type": "profiles", "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                                                "relationships": {
                                                    "bundleId": {"data": {"type": "bundleIds", "id": treffer[0]["id"]}},
                                                    "certificates": {"data": [{"type": "certificates", "id": z["id"]}]}}}})["data"]
        angelegt["profile"].append(p["id"])
        json.dump(angelegt, open(LISTE, "w"))
        inhalt = base64.b64decode(p["attributes"]["profileContent"])
        for o in zielordner:
            open(os.path.join(o, p["attributes"]["uuid"] + ".mobileprovision"), "wb").write(inhalt)
        env_setzen("NX_PROFIL_" + kurz, name)
        print("Profil angelegt:", name)
    env_setzen("NX_KEYCHAIN", KC)


def aufraeumen():
    """Nur den Wegwerf-Schlüsselbund löschen. Zertifikat/Profile bleiben bis zum nächsten Lauf (Upload-Verarbeitung)."""
    subprocess.run(["security", "delete-keychain", KC])
    import shutil
    shutil.rmtree(ORDNER, ignore_errors=True)


if __name__ == "__main__":
    {"einrichten": einrichten, "aufraeumen": aufraeumen}[sys.argv[1]]()
