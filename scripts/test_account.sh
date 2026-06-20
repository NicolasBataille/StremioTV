#!/usr/bin/env bash
#
# Teste le pipeline compte Stremio + RealDebrid de bout en bout,
# SANS jamais afficher de secret.
#
# Ce qui reste strictement local et n'est JAMAIS imprimé :
#   - ton mot de passe
#   - ton authKey (jeton de session)
#   - les clés RealDebrid (incluses dans les URLs d'add-ons)
#   - les URLs de flux complètes
#
# Seul un résumé caviardé est affiché → tu peux le partager sans risque.
#
# Usage :
#   bash scripts/test_account.sh              # film de test = Shawshank (tt0111161)
#   bash scripts/test_account.sh tt1375666    # ou un autre IMDb id (ex: Inception)
#
# Le script ne contacte que https://api.strem.io et tes propres add-ons.

MOVIE="${1:-tt0111161}"

printf "E-mail Stremio : "
read -r EMAIL
printf "Mot de passe (collé depuis l'app Mots de passe — non affiché) : "
read -rs PASSWORD
echo

EMAIL="$EMAIL" PASSWORD="$PASSWORD" MOVIE="$MOVIE" python3 - <<'PY'
import os, json, sys, urllib.request, urllib.error
from urllib.parse import urlparse

API = "https://api.strem.io/api/"
email = os.environ["EMAIL"]
pwd = os.environ["PASSWORD"]
movie = os.environ["MOVIE"]

def post(path, payload, timeout=25):
    req = urllib.request.Request(API + path, json.dumps(payload).encode(),
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))

# 1) Login
try:
    res = post("login", {"type": "Login", "email": email, "password": pwd, "facebook": False})
except Exception as e:
    print(f"❌ Login : échec réseau ({type(e).__name__})"); sys.exit(1)
if res.get("error"):
    print(f"❌ Login refusé : {res['error'].get('message','?')}"); sys.exit(1)
authkey = res["result"]["authKey"]
user = (res["result"].get("user") or {}).get("email", "?")
print(f"✅ Login OK — compte « {user} » (authKey reçu, NON affiché)")

# 2) Collection d'add-ons
try:
    col = post("addonCollectionGet", {"type": "AddonCollectionGet", "authKey": authkey, "update": True})
except Exception as e:
    print(f"❌ addonCollectionGet : {type(e).__name__}"); sys.exit(1)
addons = col["result"]["addons"]
print(f"✅ {len(addons)} add-ons récupérés depuis ton compte :")

stream_addons = []
rd_found = False
for a in addons:
    m = a.get("manifest") or {}
    name = m.get("name", "?")
    res_list = [r if isinstance(r, str) else r.get("name") for r in (m.get("resources") or [])]
    has_stream = "stream" in res_list
    url = a.get("transportUrl", "")
    is_rd = any(k in url.lower() for k in ["realdebrid", "real-debrid", "rd=", "debrid"])
    rd_found = rd_found or is_rd
    tags = []
    if has_stream: tags.append("stream")
    if is_rd: tags.append("debrid/RD")
    suffix = f"  [{', '.join(tags)}]" if tags else ""
    print(f"   - {name}{suffix}")
    if has_stream:
        stream_addons.append((name, url))

print(f"{'✅' if rd_found else '⚠'} Add-on debrid/RealDebrid détecté : {'oui' if rd_found else 'non'}")

# 3) Résolution d'un flux pour le film de test
print(f"\nTest de flux pour le film {movie} :")
best = None
for name, url in stream_addons:
    base = url[:-len('/manifest.json')] if url.endswith('/manifest.json') else url.rstrip('/')
    try:
        sd = json.load(urllib.request.urlopen(f"{base}/stream/movie/{movie}.json", timeout=25))
    except Exception:
        print(f"   - {name} : pas de réponse"); continue
    streams = sd.get("streams") or []
    direct = [s for s in streams if isinstance(s.get("url"), str) and s["url"].startswith("http")]
    print(f"   - {name} : {len(streams)} flux, dont {len(direct)} en URL directe")
    if direct and not best:
        best = direct[0]["url"]

# 4) Vérifie qu'une URL directe est réellement lisible (sans l'afficher)
if best:
    host = urlparse(best).hostname or "?"
    try:
        req = urllib.request.Request(best, headers={"Range": "bytes=0-1"})
        r = urllib.request.urlopen(req, timeout=25)
        ct = r.headers.get("Content-Type", "?")
        cl = r.headers.get("Content-Range") or r.headers.get("Content-Length") or "?"
        print(f"\n✅ Flux direct LISIBLE : HTTP {r.status}, type={ct}")
        print(f"   hôte={host}   (URL complète + clé RealDebrid volontairement masquées)")
        print("   → AVPlayer pourra lire ce type de flux sur l'Apple TV.")
    except urllib.error.HTTPError as e:
        print(f"\n⚠ URL directe trouvée mais lecture HTTP {e.code} (lien peut-être expiré).")
    except Exception as e:
        print(f"\n⚠ URL directe trouvée mais vérification échouée ({type(e).__name__}).")
else:
    print("\n⚠ Aucune URL directe trouvée pour ce film.")
    print("  Essaie un film très populaire, ou vérifie que ton add-on RealDebrid a du cache.")
PY
