#!/usr/bin/env bash
#
# Récupère TVVLCKit.xcframework (lecteur VLC universel pour tvOS) dans Vendor/.
# Le binaire (~560 Mo extrait) n'est PAS versionné ; lance ce script après un
# clone, puis `xcodegen generate`.
#
# Source : binaires officiels VideoLAN (contiennent la tranche simulateur tvOS).
set -euo pipefail

VERSION_URL="https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.3-319ed2c0-79128878.tar.xz"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor"
TMP="$(mktemp -d)"

echo "→ Téléchargement TVVLCKit 3.7.3…"
curl -L --fail -o "$TMP/tvvlckit.tar.xz" "$VERSION_URL"

echo "→ Extraction…"
tar -xJf "$TMP/tvvlckit.tar.xz" -C "$TMP"

mkdir -p "$DEST"
rm -rf "$DEST/TVVLCKit.xcframework"
cp -R "$TMP/TVVLCKit-binary/TVVLCKit.xcframework" "$DEST/"
rm -rf "$TMP"

echo "✅ Vendor/TVVLCKit.xcframework installé."
echo "   Lance maintenant : xcodegen generate"
