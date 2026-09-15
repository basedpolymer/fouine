#!/bin/sh
# bundle.sh — construit Fouine.app à partir des produits release SwiftPM.
# SPEC §11.2. Propriété : A-Pack. Appelé par `make bundle` / `make release`.
#
#   Fouine.app/Contents/
#     Info.plist
#     PkgInfo                                     APPL????
#     MacOS/Fouine                                = exécutable FouineApp, renommé
#     MacOS/FouineAgent                           = démon du §5.7
#     Helpers/fouine                              = CLI (audit produit D1/V9)
#     Resources/Fouine.icns                       = icône (CFBundleIconFile)
#     Resources/{en,fr}.lproj/InfoPlist.strings   = descriptions TCC traduites
#     Resources/{en,fr}.lproj/Localizable.strings = interface traduite (U1)
#     Resources/Metadata.appintents               = actions Raccourcis (INT-R1)
#     Frameworks/Sparkle.framework                = mises à jour (audit D13)
#     Library/LaunchAgents/io.github.basedpolymer.fouine.agent.plist   (SMAppService.agent)
#
# Ce script NE SIGNE PAS : la signature se fait de l'intérieur vers l'extérieur
# dans le Makefile, dans l'ordre imposé par le §11.2.
#
# Usage : bundle.sh <chemin des binaires release> [chemin du .app]
set -eu

BIN_DIR="${1:?usage: bundle.sh <bin-path> [app-path]}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="${2:-$ROOT/Fouine.app}"

for binary in FouineApp FouineAgent fouine; do
    if [ ! -x "$BIN_DIR/$binary" ]; then
        echo "bundle.sh : $BIN_DIR/$binary introuvable — lancez d'abord" \
             "\`swift build -c release\`" >&2
        exit 1
    fi
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Helpers" \
         "$APP/Contents/Resources" \
         "$APP/Contents/Frameworks" \
         "$APP/Contents/Library/LaunchAgents"

# Contents/MacOS/Fouine DOIT correspondre à CFBundleExecutable de l'Info.plist.
cp "$BIN_DIR/FouineApp"   "$APP/Contents/MacOS/Fouine"
cp "$BIN_DIR/FouineAgent" "$APP/Contents/MacOS/FouineAgent"

# La CLI voyage AVEC l'app (audit produit D1, vérification V9 : `find Fouine.app`
# ne rendait que six fichiers, sans `fouine`). Sans elle, `fouine root add`,
# `fouine search --json`, Raycast et le futur serveur MCP exigent de compiler le
# dépôt. L'app propose « Installer l'outil en ligne de commande… », qui lie
# /usr/local/bin/fouine sur CE fichier ; base par défaut et `FOUINE_DB` sont
# communes à l'app et à la CLI, elles regardent donc le même index.
#
# PAS dans Contents/MacOS : le disque de démarrage d'un Mac est insensible à la
# casse par DÉFAUT, et « fouine » y désigne le même fichier que « Fouine »,
# l'exécutable de l'app. Le `cp` écrasait donc silencieusement l'app par la CLI
# — bundle de 8,5 Mo, `Fouine.app` qui « ne s'ouvre pas », rien dans les logs.
# Vérifié : Contents/MacOS/Fouine faisait exactement la taille de .build/
# release/fouine. D'où un dossier à part, où le nom `fouine` est libre.
cp "$BIN_DIR/fouine"      "$APP/Contents/Helpers/fouine"
chmod 755 "$APP/Contents/MacOS/Fouine" "$APP/Contents/MacOS/FouineAgent" \
          "$APP/Contents/Helpers/fouine"

# Garde-fou explicite : si un jour quelqu'un remet la CLI dans Contents/MacOS,
# le bundle sort cassé sans le moindre message. On compare les tailles.
if [ "$(stat -f%z "$APP/Contents/MacOS/Fouine")" \
     != "$(stat -f%z "$BIN_DIR/FouineApp")" ]; then
    echo "bundle.sh : Contents/MacOS/Fouine n'est pas FouineApp — collision de" \
         "casse dans Contents/MacOS ?" >&2
    exit 1
fi

cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Packaging/io.github.basedpolymer.fouine.agent.plist" \
   "$APP/Contents/Library/LaunchAgents/io.github.basedpolymer.fouine.agent.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icône : Packaging/Fouine.icns (squircle chaleureux + 🦦). Le nom du fichier
# DOIT correspondre à CFBundleIconFile de l'Info.plist. C'est une ressource
# scellée : elle doit être en place AVANT le codesign du bundle, sinon
# `codesign --verify` signale une ressource ajoutée après coup.
if [ -f "$ROOT/Packaging/Fouine.icns" ]; then
    cp "$ROOT/Packaging/Fouine.icns" "$APP/Contents/Resources/Fouine.icns"
else
    echo "bundle.sh : ATTENTION — Packaging/Fouine.icns absent, icône générique" >&2
fi

# ─── Licences (audit B1-10) ────────────────────────────────────────────────
# MIT impose que la notice de copyright accompagne toute copie du logiciel ;
# Apache-2.0 § 4(a) impose de remettre une copie de la licence au destinataire.
# Rien de tout cela ne voyageait avec le binaire : ni NOTICE, ni
# THIRD_PARTY_LICENSES, ni dans le bundle, ni dans le DMG, ni dans l'interface.
#
# ICI, et pas ailleurs : ce sont des ressources SCELLÉES, comme l'icône et les
# .lproj. Ajoutées après le codesign, `codesign --verify` les signale comme
# ressources surnuméraires et Gatekeeper refuse le paquet. bundle.sh ne signe
# pas — le Makefile signe après lui — c'est donc le dernier moment.
#
# ÉCHEC DUR et non avertissement : un DMG livré sans ces deux fichiers est un
# défaut de conformité, pas un défaut de confort. `make ci-bundle` revérifie
# leur présence dans le bundle produit.
for licence in LICENSE THIRD_PARTY_LICENSES.md; do
    if [ ! -s "$ROOT/$licence" ]; then
        echo "bundle.sh : $licence absent ou vide à la racine du dépôt —" \
             "il doit être livré dans le bundle (audit B1-10)." >&2
        exit 1
    fi
    cp "$ROOT/$licence" "$APP/Contents/Resources/$licence"
done

# ─── Le guide de l'application (BU-27, DC1) ────────────────────────────────
# Le menu Aide ▸ « Guide de Fouine » (⌘?) affiche le guide, rendu en HTML par
# MarkdownHTML. Il voyage DANS le bundle, en DEUX langues, sous un nom qui dit
# la sienne : `GuideLocator` choisit d'après la langue de l'application, avec
# repli sur l'anglais.
#
# Même endroit et même sévérité que les licences : ressource scellée, copiée
# avant la signature, et ÉCHEC DUR si l'une manque — sans elle, le menu Aide
# rouvre une fenêtre qui s'excuse, c'est-à-dire le défaut que ce guide corrige.
for guide in "docs/app.md:Guide.en.md" "docs/fr/app.md:Guide.fr.md"; do
    src="${guide%%:*}"
    dest="${guide##*:}"
    if [ ! -s "$ROOT/$src" ]; then
        echo "bundle.sh : $src absent ou vide — c'est le guide affiché par" \
             "le menu Aide (BU-27, DC1)." >&2
        exit 1
    fi
    cp "$ROOT/$src" "$APP/Contents/Resources/$dest"
done

# ─── Localisation : String Catalogs → .lproj (palier 3.2, audit U1) ────────
# Fouine parle anglais (langue de base) et français (traduction). Les deux
# catalogues .xcstrings sont la SOURCE ; ce que macOS lit, ce sont les .strings
# compilés, rangés par langue :
#
#   Packaging/InfoPlist.xcstrings          → Resources/{en,fr}.lproj/InfoPlist.strings
#   Sources/FouineApp/Resources/Localizable.xcstrings
#                                          → Resources/{en,fr}.lproj/Localizable.strings
#
# POURQUOI ICI, et pas dans SwiftPM. La cible FouineApp est bâtie par
# `swift build`, dont les ressources atterrissent dans un bundle voisin
# (Fouine_FouineApp.bundle) que `Bundle.module` cherche À CÔTÉ de l'exécutable
# — c'est-à-dire hors de Fouine.app une fois l'exécutable copié ici. L'accesseur
# généré fait alors un `fatalError` AU LANCEMENT. On passe donc par
# `Bundle.main`, qui est le .app lui-même : SwiftUI (`Text`, `Button`, `.help`…)
# et `String(localized:)` y cherchent leurs clés sans une ligne de code de plus,
# et il suffit que les .lproj soient dans Contents/Resources.
#
# AVANT LA SIGNATURE, comme l'icône : ce sont des ressources scellées ; ajoutées
# après coup, `codesign --verify` les signale et Gatekeeper refuse le paquet.
# bundle.sh ne signe pas — le Makefile signe après lui —, c'est donc le bon
# endroit et le dernier moment.
#
# En DÉVELOPPEMENT (`swift run FouineApp`), Bundle.main n'a aucun .lproj :
# l'app affiche les clés, qui SONT les phrases anglaises. C'est le comportement
# voulu de la langue de base, pas une panne.
if ! XCSTRINGSTOOL=$(xcrun --find xcstringstool 2>/dev/null); then
    echo "bundle.sh : xcstringstool introuvable — installez les outils de" \
         "développement Xcode (xcode-select --install ne suffit pas, il faut" \
         "Xcode). Sans lui, l'app serait livrée SANS aucune traduction, et les" \
         "boîtes de dialogue TCC parleraient anglais à tout le monde." >&2
    exit 1
fi

for catalog in "$ROOT/Packaging/InfoPlist.xcstrings" \
               "$ROOT/Sources/FouineApp/Resources/Localizable.xcstrings"; do
    if [ ! -f "$catalog" ]; then
        echo "bundle.sh : catalogue $catalog introuvable." >&2
        exit 1
    fi
    "$XCSTRINGSTOOL" compile "$catalog" \
        --output-directory "$APP/Contents/Resources"
done

# Garde-fou : une erreur de langue dans un catalogue (une clé sans traduction
# `fr`, un `sourceLanguage` changé) fait disparaître un .lproj entier sans que
# rien n'échoue. On exige les deux, et un fichier non vide dans chacun.
#
# Le `.stringsdict` est exigé au même titre : c'est LUI qui porte les
# variations de pluriel (« 1 page » / « 2 pages »). Sans lui, tous les comptes
# parlés de l'interface repassent au pluriel — « 1 pages trouvées » —, et rien
# d'autre ne le signalerait.
for lang in en fr; do
    for f in "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings" \
             "$APP/Contents/Resources/$lang.lproj/Localizable.strings" \
             "$APP/Contents/Resources/$lang.lproj/Localizable.stringsdict"; do
        if [ ! -s "$f" ]; then
            echo "bundle.sh : ${f##*/Resources/} absent ou vide — le catalogue" \
                 "correspondant ne traduit pas cette langue." >&2
            exit 1
        fi
    done
done

# ─── Les phrases dictées à Siri (lot L2, audit BU-35) ──────────────────────
# `AppShortcut.phrases` est la SEULE chaîne visible de Fouine qui ne passe pas
# par un catalogue : AppIntents cherche ses traductions dans un fichier
# `<langue>.lproj/AppShortcuts.strings`, dont les clés sont les phrases
# sources — le `\(.applicationName)` du code s'y écrit `${applicationName}`.
# Ils sont donc écrits à la main sous Packaging/Resources/ et copiés ici, à
# côté des .strings compilés et AVANT la signature comme eux.
#
# ÉCHEC DUR si l'un manque : « Dis Siri, cherche dans Fouine » ne marchait
# qu'en anglais jusqu'au 10/09/2026 (BU-35), et rien nulle part ne le disait —
# les TITRES des actions, eux, étaient bien traduits, ce qui rendait le défaut
# invisible dans Raccourcis.
for lang in en fr; do
    src="$ROOT/Packaging/Resources/$lang.lproj/AppShortcuts.strings"
    if [ ! -s "$src" ]; then
        echo "bundle.sh : Packaging/Resources/$lang.lproj/AppShortcuts.strings" \
             "absent ou vide — les phrases dictées à Siri ne seraient pas" \
             "traduites dans cette langue." >&2
        exit 1
    fi
    cp "$src" "$APP/Contents/Resources/$lang.lproj/AppShortcuts.strings"
done

# ─── Métadonnées App Intents : Fouine dans Raccourcis (lot INT-R1) ─────────
# Raccourcis (et, sur macOS 26, Spotlight) ne DÉCOUVRE les actions d'une
# application que par un dossier `Contents/Resources/Metadata.appintents`. Ce
# dossier n'est pas produit par la compilation : c'est
# `appintentsmetadataprocessor` qui le fabrique, à partir des `.swiftconstvalues`
# que `swift build` n'écrit que sous les drapeaux de `CONST_VALUES_FLAGS`
# (Makefile, cible `release-build`). Xcode fait cette étape tout seul ; en
# SwiftPM pur, elle est ici.
#
# ÉCHEC DUR, comme les licences. Un bundle sans ce dossier se lance, s'indexe et
# cherche parfaitement — il n'a simplement AUCUNE action dans Raccourcis, et
# rien, nulle part, ne le dit. Mieux vaut l'apprendre au build.
#
# AVANT LA SIGNATURE, comme l'icône et les .lproj : ressource scellée.
#
# DEUX FORMES DE `.swiftconstvalues`, ET IL FAUT LES DEUX. En debug, SwiftPM
# compile fichier par fichier et écrit un `<source>.swift.swiftconstvalues` par
# source ; en RELEASE, il compile le module d'un bloc (optimisation globale) et
# n'écrit qu'un seul `FouineApp.swiftconstvalues` pour tout le module. C'est
# celui-là que voit la chaîne de publication.
#
# Les fichiers PAR SOURCE sont filtrés par la liste des sources : un fichier
# supprimé ou renommé laisse le sien derrière lui dans .build, et le processeur
# s'arrête alors sur « Unable to find matching source file » (mesuré le
# 08/09/2026). Le fichier de MODULE, lui, est toujours gardé.
if ! PROCESSOR=$(xcrun --find appintentsmetadataprocessor 2>/dev/null); then
    echo "bundle.sh : appintentsmetadataprocessor introuvable — installez" \
         "Xcode (les outils en ligne de commande seuls ne le contiennent pas)." \
         "Sans lui, Fouine n'apparaîtrait dans aucun raccourci." >&2
    exit 1
fi

# Le répertoire d'objets se DÉDUIT de BIN_DIR, jamais d'un `find` sur tout
# .build : deux builds release y cohabitent — une architecture seule sous
# .build/<triplet>/release (le gate, `ci-bundle ARCHS=$(uname -m)`), universel
# sous .build/apple (`make release`, ARCHS par défaut), et prendre l'un pour
# l'autre écrirait les métadonnées d'un AUTRE binaire, en silence. Les deux
# dispositions, mesurées le 08/09/2026 :
#   une architecture : <bin>/FouineApp.build/<source>.swift.swiftconstvalues
#                      (debug) ou <bin>/FouineApp.build/FouineApp.swiftconstvalues
#                      (release, module d'un bloc) ;
#   universel        : .build/apple/Intermediates.noindex/<paquet>.build/<Config>/
#                      FouineApp.build/Objects-normal/<arch>/FouineApp-primary.swiftconstvalues
#                      — une tranche par architecture, la première suffit, les
#                      métadonnées n'en dépendent pas (vérifié : `make ci-bundle
#                      ARCHS="x86_64 arm64"`, les trois actions dans le bundle).
CONFIG=$(basename "$BIN_DIR")
if [ -d "$BIN_DIR/FouineApp.build" ]; then
    CONST_DIR="$BIN_DIR/FouineApp.build"
else
    CONST_DIR=$(find "$ROOT/.build/apple/Intermediates.noindex" -maxdepth 3 -type d \
                -path "*/$CONFIG/FouineApp.build" 2>/dev/null | head -n 1)
fi
if [ -z "$CONST_DIR" ] || [ ! -d "$CONST_DIR" ]; then
    echo "bundle.sh : aucun répertoire d'objets pour FouineApp à côté de" \
         "$BIN_DIR — lancez \`make release-build\`." >&2
    exit 1
fi
APPINTENTS_ARCH=""
if [ -d "$CONST_DIR/Objects-normal" ]; then
    APPINTENTS_ARCH=$(ls "$CONST_DIR/Objects-normal" | sort | head -n 1)
fi

APPINTENTS_SOURCES=$(mktemp)
APPINTENTS_CONSTS=$(mktemp)
find "$ROOT/Sources/FouineApp" -name '*.swift' | sort > "$APPINTENTS_SOURCES"
: > "$APPINTENTS_CONSTS"
APPINTENTS_FOUND=$(mktemp)
if [ -n "$APPINTENTS_ARCH" ]; then
    find "$CONST_DIR" -name '*.swiftconstvalues' -path "*/$APPINTENTS_ARCH/*" \
        | sort > "$APPINTENTS_FOUND"
else
    find "$CONST_DIR" -maxdepth 1 -name '*.swiftconstvalues' | sort > "$APPINTENTS_FOUND"
fi
while IFS= read -r vals; do
    # `if` et non `[ … ] && …` : sous `set -e`, une liste `&&` dont le test
    # échoue rend 1 et ferait sortir le script au premier fichier écarté.
    if [ ! -f "$vals" ]; then continue; fi
    base=$(basename "$vals" .swiftconstvalues)
    case "$base" in
        *.swift)
            # Fichier par source : gardé seulement si le source existe encore.
            if grep -q "/$base\$" "$APPINTENTS_SOURCES"; then
                printf '%s\n' "$vals" >> "$APPINTENTS_CONSTS"
            fi
            ;;
        *)
            # Fichier de module (release) : toujours gardé.
            printf '%s\n' "$vals" >> "$APPINTENTS_CONSTS"
            ;;
    esac
done < "$APPINTENTS_FOUND"
rm -f "$APPINTENTS_FOUND"

if [ ! -s "$APPINTENTS_CONSTS" ]; then
    echo "bundle.sh : aucun .swiftconstvalues sous $CONST_DIR — le release a" \
         "été bâti SANS les drapeaux d'émission des valeurs constantes." >&2
    echo "  Passez par \`make release-build\` (cible \`bundle\`), qui pose" \
         "CONST_VALUES_FLAGS ; un \`swift build -c release\` nu ne suffit pas." >&2
    rm -f "$APPINTENTS_SOURCES" "$APPINTENTS_CONSTS"
    exit 1
fi

# Le triplet se lit dans le chemin des objets — .build/<triplet>/release/… pour
# une architecture, Objects-normal/<arch> pour l'universel — et la cible de
# déploiement est celle de Package.swift (`platforms: [.macOS(.v13)]`).
if [ -n "$APPINTENTS_ARCH" ]; then
    APPINTENTS_TRIPLE="${APPINTENTS_ARCH}-apple-macosx13.0"
else
    APPINTENTS_TRIPLE=$(basename "$(dirname "$(dirname "$CONST_DIR")")")13.0
fi
# `xcodebuild -version` rend deux lignes ; la seconde est « Build version 17C52 ».
XCODE_BUILD=$(xcodebuild -version 2>/dev/null | sed -n 's/^Build version //p')

# `--no-app-shortcuts-localization` : le processeur n'a pas à FABRIQUER les
# fichiers de phrases — il les exigerait sous la forme d'un `--stringsdata-file`
# par langue, que SwiftPM ne produit pas. Les phrases traduites sont copiées
# quelques lignes plus haut, telles qu'AppIntents les lit à l'exécution
# (`{en,fr}.lproj/AppShortcuts.strings`, lot L2). Les titres et descriptions des
# actions, eux, sont des LocalizedStringResource que Raccourcis résout dans
# Localizable.strings, déjà compilé plus haut.
"$PROCESSOR" \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$PROCESSOR")")")" \
    --module-name FouineApp \
    --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$XCODE_BUILD" \
    --platform-family macOS \
    --deployment-target 13.0 \
    --target-triple "$APPINTENTS_TRIPLE" \
    --source-file-list "$APPINTENTS_SOURCES" \
    --swift-const-vals-list "$APPINTENTS_CONSTS" \
    --compile-time-extraction \
    --no-app-shortcuts-localization
rm -f "$APPINTENTS_SOURCES" "$APPINTENTS_CONSTS"

# Le processeur sort 0 en n'écrivant rien quand il n'a trouvé aucune intention
# (une refonte qui déplacerait Sources/FouineApp/Intents ailleurs, par exemple).
if [ ! -s "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]; then
    echo "bundle.sh : Metadata.appintents vide ou absent — aucune action" \
         "n'aurait été proposée dans Raccourcis." >&2
    exit 1
fi

# ─── Sparkle.framework (palier 2.9, audit D13) ─────────────────────────────
# Sparkle est la SEULE dépendance dynamique de Fouine : l'exécutable la
# référence en @rpath/Sparkle.framework/Versions/B/Sparkle, et le rpath
# @executable_path/../Frameworks est posé par Package.swift. Sans cette copie,
# l'app se lance… jusqu'à ce que dyld échoue, et le message n'apparaît que dans
# les journaux du système.
#
# D'OÙ ON LA PREND. SwiftPM copie déjà le framework à côté des binaires quand il
# lie une cible contre un XCFramework (« Copying Sparkle.framework » dans la
# sortie de build) : $BIN_DIR est donc la source de VÉRITÉ, celle contre
# laquelle l'exécutable a été lié. On ne retombe sur .build/artifacts que si
# elle manque — et il faut alors deux motifs, parce qu'un build universel range
# ses produits dans .build/apple/Products/Release tandis que l'artefact, lui,
# reste dans .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/.
SPARKLE_SRC=""
if [ -d "$BIN_DIR/Sparkle.framework" ]; then
    SPARKLE_SRC="$BIN_DIR/Sparkle.framework"
else
    # `find` et non un glob : le nom de la tranche (macos-arm64_x86_64) dépend
    # des architectures publiées par la version de Sparkle, et le chemin des
    # artefacts a bougé entre les versions de SwiftPM.
    SPARKLE_SRC=$(find "$ROOT/.build" -type d -path '*/Sparkle.xcframework/macos-*' \
                       -name 'Sparkle.framework' -print 2>/dev/null | head -n 1)
fi

if [ -z "$SPARKLE_SRC" ] || [ ! -d "$SPARKLE_SRC" ]; then
    echo "bundle.sh : Sparkle.framework introuvable (ni dans $BIN_DIR, ni sous" \
         ".build/artifacts). Lancez \`swift package resolve\` puis" \
         "\`swift build -c release\`." >&2
    exit 1
fi

# -R et non -a : on veut suivre la structure versionnée du framework telle
# quelle (Versions/B + liens symboliques Current, Sparkle, Resources…), et `cp
# -R` sur macOS les préserve. `rm -rf` d'abord, sinon un ancien contenu se
# mélangerait au nouveau et la signature scellerait des fichiers fantômes.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"

# XPCServices : Downloader.xpc et Installer.xpc n'existent QUE pour les
# applications en bac à sable. La documentation de Sparkle ne les mentionne que
# sur sa page « sandboxing » (INSTALL de l'artefact : « For integrating XPC
# Services in a Sandboxed Application »), et Fouine tourne en runtime durci SANS
# bac à sable (Packaging/Fouine.entitlements). Les garder coûterait deux bundles
# imbriqués de plus à signer, à notariser et à faire vérifier par Gatekeeper,
# pour du code qui ne s'exécutera jamais. On les retire.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"

# Le lien symbolique de tête pointe sur Versions/Current : s'il subsiste après
# la suppression, il pend dans le vide et `codesign --verify --deep --strict`
# le signale.
rm -f "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

# Garde-fou : les deux exécutables imbriqués QUE LE MAKEFILE DOIT SIGNER avant
# le framework. S'ils changent de nom dans une version future de Sparkle, la
# signature du bundle échouera plus tard avec un message obscur ; autant le dire
# ici, au moment où l'on sait pourquoi.
for nested in Versions/B/Autoupdate Versions/B/Updater.app; do
    if [ ! -e "$APP/Contents/Frameworks/Sparkle.framework/$nested" ]; then
        echo "bundle.sh : Sparkle.framework/$nested absent — la structure du" \
             "framework a changé, revoyez l'ordre de signature du Makefile." >&2
        exit 1
    fi
done

# GRDB_GRDB.bundle (PrivacyInfo.xcprivacy) n'est PAS embarqué : vérifié, la
# bibliothèque GRDB n'appelle `Bundle.module` que dans ses tests, et un manifeste
# de confidentialité ne sert qu'à une soumission App Store — que ce projet ne
# fera jamais. L'embarquer ajouterait un bundle imbriqué à signer séparément
# pour rien.

plutil -lint "$APP/Contents/Info.plist" >/dev/null
plutil -lint "$APP/Contents/Library/LaunchAgents/io.github.basedpolymer.fouine.agent.plist" >/dev/null

# Garde-fou : un exécutable qui n'est pas dans les archis demandées ne se verra
# qu'au lancement sur l'autre Mac. Autant le dire ici.
echo "bundle.sh : $APP construit"
echo "  langues      $(ls -d "$APP"/Contents/Resources/*.lproj \
    | xargs -n1 basename | sed 's/\.lproj$//' | tr '\n' ' ')"
echo "  Fouine       $(lipo -archs "$APP/Contents/MacOS/Fouine")"
echo "  FouineAgent  $(lipo -archs "$APP/Contents/MacOS/FouineAgent")"
echo "  fouine       $(lipo -archs "$APP/Contents/Helpers/fouine")"
echo "  Sparkle      $(lipo -archs \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle")"
echo "  Raccourcis   $(ls "$APP/Contents/Resources/Metadata.appintents" \
    | tr '\n' ' ')"
# RAPPEL A-Pack : `Contents/Helpers/fouine` est du CODE IMBRIQUÉ. Il doit être
# signé AVANT le bundle (§11.2, de l'intérieur vers l'extérieur), sinon
# `codesign --verify --deep --strict` refuse le paquet. La cible `release` du
# Makefile porte la ligne — à faire pointer sur Contents/Helpers, pas
# Contents/MacOS (voir le commentaire de la copie ci-dessus).

# SwiftPM lie statiquement ses cibles et le runtime Swift vient du système sur
# macOS 13+ : la SEULE dépendance dynamique relative admise est
# @rpath/Sparkle.framework, que l'on vient de copier dans Contents/Frameworks.
# Toute AUTRE ligne @rpath / @executable_path signale une bibliothèque qui n'est
# pas dans le bundle — l'app se lancerait ici et pas ailleurs.
unexpected=$(otool -L "$APP/Contents/MacOS/Fouine" \
             | grep -E '@rpath|@executable_path' \
             | grep -v '@rpath/Sparkle\.framework/' || true)
if [ -n "$unexpected" ]; then
    echo "bundle.sh : ATTENTION — dépendances dynamiques relatives INATTENDUES :" >&2
    echo "$unexpected" >&2
    echo "  elles doivent être copiées dans Contents/Frameworks ET signées" \
         "avant l'app (§11.2)." >&2
fi

# L'inverse est tout aussi fatal, et silencieux : un rpath manquant se voit au
# lancement, pas au build. On vérifie que le chargeur saura où chercher.
if ! otool -l "$APP/Contents/MacOS/Fouine" \
     | grep -q '@executable_path/../Frameworks'; then
    echo "bundle.sh : LC_RPATH @executable_path/../Frameworks absent de" \
         "Contents/MacOS/Fouine — Sparkle ne sera pas trouvé au lancement." >&2
    echo "  Voir linkerSettings de la cible FouineApp dans Package.swift." >&2
    exit 1
fi
