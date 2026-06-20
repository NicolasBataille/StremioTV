#!/usr/bin/env bash
#
# Connecte le simulateur tvOS StremioTV à ton compte Stremio, SANS exposer
# ton mot de passe ni ton authKey : ils restent strictement locaux
# (ton terminal → le simulateur). Rien n'est affiché ni partagé.
#
# Prérequis : le simulateur « StremioTV-ATV » est démarré et l'app installée
# (Claude la build/installe avant de te demander de lancer ce script).
#
# Usage : bash scripts/login_simulator.sh
set -euo pipefail
BUNDLE="com.stremio.tv.client"

printf "E-mail Stremio : "
read -r EMAIL
printf "Mot de passe (collé depuis l'app Mots de passe — non affiché) : "
read -rs PASSWORD
echo

# 1) Login → authKey (jamais imprimé)
AUTHKEY=$(EMAIL="$EMAIL" PASSWORD="$PASSWORD" python3 - <<'PY'
import os, json, sys, urllib.request
body = json.dumps({"type": "Login", "email": os.environ["EMAIL"],
                   "password": os.environ["PASSWORD"], "facebook": False}).encode()
req = urllib.request.Request("https://api.strem.io/api/login", body,
                             {"Content-Type": "application/json"})
try:
    data = json.load(urllib.request.urlopen(req, timeout=20))
except Exception:
    sys.exit(1)
if data.get("error"):
    sys.exit(1)
print(data["result"]["authKey"])
PY
) || { echo "❌ Connexion refusée (vérifie tes identifiants)."; exit 1; }

# 2) UDID du simulateur Apple TV booté
UDID=$(xcrun simctl list devices booted 2>/dev/null \
       | grep -m1 "StremioTV-ATV" \
       | grep -oiE "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
if [ -z "$UDID" ]; then
    echo "❌ Simulateur « StremioTV-ATV » non démarré."
    exit 1
fi

# 3) Lance l'app connectée (authKey passé localement, jamais affiché)
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE" -uitestAuthKey "$AUTHKEY" >/dev/null

echo "✅ Simulateur connecté à ton compte."
echo "   Ton mot de passe et ton authKey ne sont jamais sortis de ce terminal."
echo "   Dis « c'est connecté » à Claude pour qu'il teste l'UI (il évitera d'afficher ta clé RealDebrid)."
