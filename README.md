# StremioTV

Clients **natifs Apple** (SwiftUI + **VLCKit**) qui se connectent à **ton compte
Stremio**, récupèrent **tous tes add-ons** (dont **RealDebrid**) et lisent le
contenu directement sur l'appareil — **sans mirroring** :

- **iPhone / iPad** (`StremioTV-iOS`) : app universelle **tactile** (navigation
  adaptative onglets/barre latérale, lecteur tactile, scrubber, feuilles de
  pistes) — livrée sur **TestFlight**.
- **Apple TV** (`StremioTV`) : app **télécommande / focus** d'origine.

Le code métier (modèles, services, view-models, cœur de lecture VLC) est
**partagé** entre les deux plateformes ; seules les vues diffèrent.

> Pourquoi ce projet ? En juin 2026, Stremio a été retiré de l'App Store (iOS/tvOS)
> et l'« IPA tvOS officielle » annoncée n'est pas distribuée proprement (la page
> de téléchargement n'expose que l'Android TV, le desktop et l'iOS via AltStore PAL).
> Builder un client natif est la voie fiable pour avoir Stremio *sur l'écran* de
> l'Apple TV.

## Fonctionnalités

- **Connexion au compte Stremio** (e-mail / mot de passe), authKey stocké dans le **Keychain**, session restaurée au lancement (`loginWithToken`).
- **Récupération automatique des add-ons du compte** via `addonCollectionGet` — y compris ton add-on **RealDebrid**.
- **Accueil** : une rangée par catalogue, posters focusables, lien « Tout voir ».
- **Recherche** multi-add-ons.
- **Catalogues paginés** (chargement progressif via l'extra `skip`).
- **Fiches** films & séries (synopsis, note IMDb, liste d'épisodes).
- **Lecture universelle (VLCKit)** : HLS, MP4, **MKV**, AVI… tout ce que RealDebrid renvoie (avec contrôles télécommande : play/pause, saut ±15 s, progression).
- **Réglages** : compte (connexion/déconnexion, rafraîchir), add-ons (compte + manuels), ajout manuel.
- **Lumières Hue (Ambilight)** : les lampes d'une zone de divertissement Philips Hue suivent les couleurs de l'image pendant la lecture (voir plus bas).
- **Mode invité** (Cinemeta) sans compte.
- **App Icon / Top Shelf** (brand assets tvOS).

## Qualité / tests

- `swiftc -typecheck` contre le SDK **tvOS 26.5** : **0 erreur**.
- **15 tests unitaires XCTest** (décodage Manifest/Catalog/Meta/Stream/AddonCollection, erreurs API, normalisation d'URL, classification des flux, repository) : **tous verts** sur l'émulateur.
- **Tests UI XCUITest** sur l'émulateur Apple TV : écran de connexion + parcours invité → accueil → **chargement réel des catalogues Cinemeta**.

Contrat de l'API compte vérifié à la source (`Stremio/stremio-core`) :
`POST https://api.strem.io/api/login` → `{result:{authKey,user}}` ;
`POST .../addonCollectionGet` → `{result:{addons:[{transportUrl,manifest,flags}]}}`.

## Prérequis

- macOS + **Xcode 26.5** (SDK tvOS 26.5)
- **Homebrew** + **XcodeGen** (`brew install xcodegen`)
- Runtime simulateur tvOS (`xcodebuild -downloadPlatform tvOS`) pour les tests
- Un **compte Apple Developer payant** (signature ~1 an + enregistrement de l'Apple TV)

## 1. Générer / ouvrir le projet

```bash
cd ~/Projects/StremioTV
bash scripts/fetch_vlckit.sh  # récupère TVVLCKit + MobileVLCKit (~1 Go) dans Vendor/ (une fois)
xcodegen generate             # (re)génère StremioTV.xcodeproj depuis project.yml
open StremioTV.xcodeproj
```

Deux schémas sont disponibles :

- **`StremioTV-iOS`** → iPhone / iPad (simulateur ou appareil).
- **`StremioTV`** → Apple TV (simulateur ou appareil).

```bash
# Build rapide iOS (simulateur) sans signature
xcodebuild build -scheme StremioTV-iOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

# (Ré)générer l'icône iOS si besoin
python3 scripts/make_ios_icon.py
```

> **Déploiement TestFlight** (iOS + tvOS, tests internes, automatique au push
> d'un tag `v*`) : voir **[DEPLOYMENT.md](DEPLOYMENT.md)**.

> Relance `xcodegen generate` après tout ajout/suppression de fichier dans
> `Sources/`, `Tests/` ou `UITests/`.

## 2. Lancer les tests sur l'émulateur

```bash
# Créer un Apple TV simulé (une fois)
xcrun simctl create "StremioTV-ATV" \
  com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K \
  com.apple.CoreSimulator.SimRuntime.tvOS-26-5

# Tests unitaires + UI
xcodebuild test -project StremioTV.xcodeproj -scheme StremioTV \
  -destination 'platform=tvOS Simulator,name=StremioTV-ATV' \
  CODE_SIGNING_ALLOWED=NO
```

## 3. Déployer sur ta vraie Apple TV

1. **Signing** (cible StremioTV → Signing & Capabilities) : *Automatically manage signing* + ton **Team** Apple Developer. Adapte le **Bundle Identifier** si besoin (ex. `com.tonnom.stremiotv`). Profil de dev valable **~1 an**.
2. **Appairer l'Apple TV** (même réseau) : Apple TV → *Réglages → Télécommandes et appareils → Remote App et appareils*, puis Xcode → *Window → Devices and Simulators* → **Pair** + code à l'écran.
3. Sélectionne l'Apple TV comme destination → **▶︎ Run**. (Au 1er lancement : *Réglages → Général → VPN et gestion des appareils* de l'Apple TV pour faire confiance au certificat.)
4. Dans l'app : **connexion à ton compte Stremio** → tes add-ons (dont RealDebrid) sont chargés automatiquement.

## RealDebrid / lecture

Les add-ons **debrid** (RealDebrid via Torrentio/Comet/MediaFusion…) renvoient des
**URLs HTTPS directes**, lues par **VLCKit** — donc **HLS, MP4, MKV, AVI…** sans
distinction (là où AVPlayer échouerait sur le MKV, très fréquent). Comme ils sont
dans ta collection de compte, ils arrivent automatiquement après connexion.

Les flux **torrent purs** (`infoHash` sans `url`) ne sont pas lisibles directement :
l'app les affiche mais les marque non lisibles (il faudrait le streaming-server
`Stremio/stremio-service` sur le réseau). Avec RealDebrid, ce cas ne se présente pas.

## Lumières Hue (Ambilight)

Pendant la lecture d'une vidéo dans StremioTV (Apple TV, iPhone, iPad), les
lampes de la **zone de divertissement** Hue choisie prennent la couleur des bords
de l'image, en direct, via l'**API Hue Entertainment** (flux HueStream v2 chiffré
en DTLS sur le réseau local, ~50 mises à jour/s). Aucun boîtier HDMI ni cloud :
l'app parle directement au pont.

**Prérequis**

- Un **pont Hue carré** (Bridge v2) sur le même réseau que l'appareil.
- Une **zone de divertissement** créée une fois dans l'app Hue
  (*Réglages › Zones de divertissement*), lampes placées autour de la TV ;
  idéalement de type « TV ». Max. 20 canaux (un ruban gradient en compte plusieurs).

**Appairage** (*Réglages › Lumières Hue*)

1. **Rechercher le pont** (Bonjour + `discovery.meethue.com`), ou saisir son
   **adresse IP** (visible dans l'app Hue : *Réglages › Mes ponts Hue*).
2. **Associer**, puis appuyer sur le **gros bouton rond du pont** dans les 30 s.
   Les identifiants (clé d'application + clé DTLS) sont gardés dans le **Keychain** ;
   le certificat du pont est épinglé au premier contact.
3. Choisir la **zone** (la première zone « TV » est présélectionnée), puis
   **Tester les lumières** (rouge, vert, bleu, blanc sur chaque lampe).

Sur iPhone/iPad, iOS demande l'autorisation d'accès au **réseau local** au premier
usage : il faut l'accepter (sinon *Réglages iOS › StremioTV › Réseau local*).

**Réglages** : activation pendant la lecture, luminosité (10–100 %), saturation
(100–160 %), réactivité (douce / équilibrée / rapide), **retard des lumières**
(0–600 ms, pour se caler sur une TV ou une barre de son qui retarde l'image) et
méthode de capture.

**Limites**

- Uniquement pendant la **lecture dans StremioTV**, app **au premier plan**
  (pas Netflix ni les autres apps : pour celles-ci, utilise l'app officielle
  Hue Sync de ta TV ou un Sync Box). La zone est libérée à l'arrêt de la
  vidéo et quand l'app passe en arrière-plan (en pause, les lampes gardent
  la dernière couleur).
- Méthode de capture **« Automatique »** : essaie la **capture de la vue** vidéo,
  puis bascule sur les **snapshots VLC** (moins fluides, ~4 img/s) si la première ne
  renvoie que du noir ; la méthode qui marche est mémorisée.
- Bandes noires (letterbox / pillarbox) ignorées, sous-titres exclus des lampes du bas.

**Dépannage**

- *« La zone est déjà utilisée par une autre app »* : une seule app peut diffuser
  sur une zone à la fois. Arrête **Hue Sync** (app de la TV, PC/Mac, Sync Box)
  ou choisis une autre zone, puis relance la vidéo.
- *Aucun pont trouvé* : vérifie que l'appareil et le pont sont sur le même réseau
  (pas de réseau invité / isolation Wi-Fi), puis saisis l'**IP manuelle**.
- *Les lumières sont en avance sur l'image* : augmente le **retard des lumières**.
- *Lumières figées ou noires* : force la méthode de capture « Snapshot VLC ».

## Architecture

```
Sources/
  Shared/                     ── code commun iOS + tvOS ──
    Models/                   Manifest, MetaItem, StreamItem, InstalledAddon,
                              LibraryItem, PlaybackRequest/Preferences, StremioAPI…
    Services/                 AddonClient, StremioAPIClient, KeychainStore,
                              AddonRepository, SessionStore, LibraryStore
    ViewModels/               Home, Search, CatalogGrid, Detail (@Observable)
    Common/                   Theme (couleurs/backdrop/langues), TrackController
    Player/
      VLCPlayerCore.swift     cœur de lecture VLC partagé (UIViewController) :
                              reprise, pistes audio/sous-titres, progression.
                              import conditionnel TVVLCKit / MobileVLCKit.
    Hue/                      Lumières Hue : API CLIP v2, appairage, découverte,
                              Keychain, DTLS PSK, paquets HueStream, HueSyncService.
    Ambilight/                capture d'image (vue / snapshots VLC) et pipeline
                              couleur (bandes noires, bords, saturation).
  tvOS/                       ── habillage Apple TV (focus / télécommande) ──
    StremioTVApp.swift        @main tvOS
    Views/                    Root, MainTab, Home, MetaDetail, StreamsList,
                              PlayerView (overlay + télécommande), Settings…
    Assets.xcassets           App Icon & Top Shelf (brand assets tvOS)
  iOS/                        ── habillage iPhone / iPad (tactile) ──
    StremioApp.swift          @main iOS
    Views/                    RootView, MainShell (onglets/sidebar adaptatifs),
                              HomeScreen, SearchScreen, LibraryScreen,
                              CatalogGridScreen, DetailScreen, StreamsScreen,
                              PlayerView (contrôles tactiles), TrackSelectionSheet,
                              SettingsScreen, LoginScreen, PosterComponents…
    Assets.xcassets           AppIcon (icône iOS générée)
Vendor/
  TVVLCKit.xcframework        lecteur VLC tvOS   (scripts/fetch_vlckit.sh)
  MobileVLCKit.xcframework    lecteur VLC iOS    (scripts/fetch_vlckit.sh)
Tests/                        XCTest unitaires (décodage + logique + repository)
UITests/                      XCUITest (login + parcours invité) — cible tvOS
fastlane/                     Fastfile/Appfile — livraison TestFlight (voir DEPLOYMENT.md)
.github/workflows/testflight.yml  CI : build + upload TestFlight au tag v*
scripts/fetch_vlckit.sh       récupère TVVLCKit + MobileVLCKit
scripts/make_assets.py        génère les brand assets tvOS
scripts/make_ios_icon.py      génère l'icône iOS
scripts/test_account.sh       teste le pipeline compte+RealDebrid (sortie caviardée)
```

## Limites connues

- Pas encore de sync « Continuer à regarder » / progression / Trakt.
- Lecture torrent native non incluse (RealDebrid couvre le besoin).
- Re-signer ~1×/an (profils de dev, hors App Store).

## Licences

Protocole et `stremio-core` sous **MIT** ; cet outil personnel ne redistribue
aucun binaire Stremio. Usage personnel.
