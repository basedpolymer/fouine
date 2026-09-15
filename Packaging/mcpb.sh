#!/bin/sh
# mcpb.sh — extension de bureau Claude Desktop (contre-expertise D2 § 5.10).
# Propriété : A-MCP. Appelé par `make mcpb`.
#
#   Usage : Packaging/mcpb.sh <chemin du .app> [chemin du .mcpb]
#   Variables lues dans l'environnement (posées par le Makefile) :
#       VERSION           numéro de version ; doit égaler celui du manifeste
#       MCPB_ALLOW_THIN   1 = accepter un binaire mono-architecture (essais locaux)
#       MCPB_ALLOW_ADHOC  1 = accepter une signature ad hoc (essais locaux)
#
# Un `.mcpb` est une ARCHIVE ZIP, rien de plus : Claude Desktop la dézippe et
# lance ce que `manifest.json` désigne. Le contenu livré ici :
#
#   manifest.json             schéma « 0.3 », `server.type = "binary"`
#   bin/fouine                la CLI, telle qu'elle est dans Fouine.app
#   LICENSE                   la licence de Fouine (source-available, LI1)
#   THIRD_PARTY_LICENSES.md   les notices des composants redistribués (B1-10)
#
# CE SCRIPT NE COMPILE RIEN, et c'est la règle qui compte. Il recopie le binaire
# de `$APP/Contents/Helpers/fouine`, celui que `make release` a signé Developer
# ID et que `make notarize` a fait viser par Apple. Un binaire fraîchement bâti
# ici ne le serait pas : extrait d'une archive téléchargée, il porterait
# l'attribut de quarantaine, Gatekeeper le refuserait, et le serveur ne
# démarrerait jamais — sans autre message chez l'utilisateur qu'une extension
# qui ne répond pas. D'où l'ordre imposé par RELEASING.md :
#
#       make release  →  make notarize  →  make mcpb
#
# Le binaire doit aussi être UNIVERSEL : le `.mcpb` publié s'installe sur des
# Mac Apple Silicon comme sur des Intel, et une tranche manquante ne se voit
# qu'à l'exécution, chez l'autre. `MCPB_ALLOW_THIN=1` lève l'exigence pour un
# essai local, et le nom de l'archive n'en garde aucune trace : ne publiez pas
# ce qu'il produit.
#
# Le doublon avec l'application installée est ASSUMÉ (D2 § 5.10, point 3) : le
# `.mcpb` embarque son propre exécutable pour que Claude Desktop marche sans que
# la ligne de commande soit installée. Pour Claude Code, qui sait lancer une
# commande arbitraire, la voie documentée reste `/usr/local/bin/fouine`
# (docs/mcp.md, § Installation).
set -eu

NAME_ONLY=0
if [ "${1:-}" = "--name-only" ]; then
    NAME_ONLY=1
    shift
fi

APP="${1:?usage: mcpb.sh [--name-only] <app> [mcpb]}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"

if [ -n "${2:-}" ]; then
    MCPB="$2"
elif [ -z "${CI:-}" ] && ! git -C "$ROOT" describe --exact-match --tags >/dev/null 2>&1; then
    BUILD_NUM=""
    if [ -f "$APP/Contents/Info.plist" ]; then
        BUILD_NUM=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)
    fi
    if [ -z "$BUILD_NUM" ]; then
        BUILD_NUM=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)
    fi
    MCPB="$ROOT/dist/Fouine-$VERSION-b$BUILD_NUM.mcpb"
else
    MCPB="$ROOT/dist/Fouine-$VERSION.mcpb"
fi

if [ "$NAME_ONLY" = 1 ]; then
    echo "$MCPB"
    exit 0
fi
MANIFEST="$ROOT/Packaging/mcpb/manifest.json"
BIN="$APP/Contents/Helpers/fouine"

# `plutil` lit le JSON aussi bien que le plist ; c'est le seul analyseur dont ce
# script ait besoin, et il est dans macOS (SPEC §2.2 : aucune dépendance neuve).
json() { plutil -extract "$1" raw -o - "$2"; }

# ─── ce dont on part ────────────────────────────────────────────────────────

[ -d "$APP" ] || {
    echo "mcpb.sh : $APP introuvable — \`make release\` d'abord" >&2; exit 1; }
[ -f "$MANIFEST" ] || {
    echo "mcpb.sh : $MANIFEST introuvable" >&2; exit 1; }
[ -x "$BIN" ] || {
    echo "mcpb.sh : $BIN absent — le bundle doit porter la CLI" >&2
    echo "          (Packaging/bundle.sh la copie dans Contents/Helpers)." >&2
    exit 1; }

plutil -convert xml1 -o /dev/null "$MANIFEST" || {
    echo "mcpb.sh : $MANIFEST n'est pas du JSON valide" >&2; exit 1; }

# Une seule valeur de version, comme pour VERSION et Version.swift
# (`make check-version`) : un manifeste resté sur la version précédente
# s'installerait sans un mot et n'annoncerait jamais sa mise à jour.
MANIFEST_VERSION=$(json version "$MANIFEST")
if [ "$MANIFEST_VERSION" != "$VERSION" ]; then
    echo "mcpb.sh : manifest.json annonce la version $MANIFEST_VERSION," >&2
    echo "          le dépôt est en $VERSION — mettez les deux d'accord" >&2
    echo "          (RELEASING.md § 1)." >&2
    exit 1
fi

ENTRY=$(json server.entry_point "$MANIFEST")
[ "$ENTRY" = "bin/fouine" ] || {
    echo "mcpb.sh : manifest.json désigne « $ENTRY » ; ce script empaquette" >&2
    echo "          « bin/fouine »." >&2
    exit 1; }

# ─── le binaire : architectures, signature ──────────────────────────────────

ARCHS=$(lipo -archs "$BIN")
echo "mcpb.sh : $BIN"
echo "          tranches : $ARCHS"
case "$ARCHS" in
    *x86_64*arm64*|*arm64*x86_64*) ;;
    *)
        if [ "${MCPB_ALLOW_THIN:-}" = 1 ]; then
            echo "          AVERTISSEMENT : binaire mono-architecture accepté" \
                 "(MCPB_ALLOW_THIN=1)." >&2
            echo "          Cette archive est un ESSAI LOCAL : elle ne" \
                 "fonctionnerait pas sur un Mac" >&2
            echo "          d'une autre architecture. Ne la publiez pas." >&2
        else
            echo "mcpb.sh : le binaire doit être universel (x86_64 arm64)," >&2
            echo "          il ne porte que « $ARCHS »." >&2
            echo "          Rebâtissez : make release ARCHS=\"x86_64 arm64\"" >&2
            echo "          Pour un essai local : MCPB_ALLOW_THIN=1 make mcpb" >&2
            exit 1
        fi ;;
esac

codesign --verify --strict "$BIN" 2>/dev/null || {
    echo "mcpb.sh : $BIN n'est pas signé — \`make release\` d'abord" >&2; exit 1; }

TEAM=$(codesign -dv --verbose=4 "$BIN" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ -z "$TEAM" ] || [ "$TEAM" = "not set" ]; then
    if [ "${MCPB_ALLOW_ADHOC:-}" = 1 ]; then
        echo "          AVERTISSEMENT : signature AD HOC acceptée" \
             "(MCPB_ALLOW_ADHOC=1)." >&2
        echo "          Gatekeeper refusera ce binaire sur toute machine qui" \
             "ne l'a pas bâti." >&2
    else
        echo "mcpb.sh : $BIN porte une signature AD HOC." >&2
        echo "          Extrait d'une archive téléchargée, il portera" >&2
        echo "          l'attribut de quarantaine : Gatekeeper le refusera et" >&2
        echo "          l'extension ne démarrera pas. Il faut une signature" >&2
        echo "          Developer ID ET la notarisation :" >&2
        echo "              make release IDENTITY=\"Developer ID Application: …\"" >&2
        echo "              make notarize" >&2
        echo "              make mcpb" >&2
        echo "          Pour un essai local : MCPB_ALLOW_ADHOC=1 make mcpb" >&2
        exit 1
    fi
else
    echo "          signature : TeamIdentifier=$TEAM"
fi

# ─── mise en scène ──────────────────────────────────────────────────────────

# MIT exige que la notice de copyright accompagne toute copie, Apache-2.0 §4(a)
# qu'une copie de la licence soit remise au destinataire (audit B1-10). Le
# `.mcpb` est une copie du binaire : les deux fichiers voyagent avec lui, et on
# les prend DANS LE BUNDLE — ce sont les exemplaires signés, ceux que
# `make ci-bundle` vérifie déjà.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/fouine-mcpb.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/bin"
# `ditto` et non `cp` : il recopie les attributs étendus tels quels, et une
# recopie qui abîmerait le sceau ne se verrait qu'à l'installation.
ditto "$BIN" "$STAGE/bin/fouine"
chmod 755 "$STAGE/bin/fouine"
cp "$MANIFEST" "$STAGE/manifest.json"

for licence in LICENSE THIRD_PARTY_LICENSES.md; do
    src="$APP/Contents/Resources/$licence"
    [ -s "$src" ] || {
        echo "mcpb.sh : $src absent ou vide — bundle.sh doit le copier" >&2
        echo "          avant la signature (audit B1-10)." >&2
        exit 1; }
    cp "$src" "$STAGE/$licence"
done

# ─── l'archive ──────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$MCPB")"
# `zip` tourne DEPUIS le dossier de mise en scène (c'est ce qui donne des
# chemins relatifs propres dans l'archive) : un chemin de sortie relatif — celui
# que passe le Makefile, `dist/Fouine-<version>.mcpb` — y désignerait un dossier
# qui n'existe pas. On le rend absolu avant de bouger.
MCPB="$(cd "$(dirname "$MCPB")" && pwd)/$(basename "$MCPB")"
rm -f "$MCPB"
# `-X` : pas d'attributs uid/gid ni d'entrées AppleDouble, qui feraient de
# l'archive un dossier `__MACOSX` de plus chez l'utilisateur. Le bit exécutable,
# lui, est conservé — c'est celui qui compte.
( cd "$STAGE" && zip -q -X -r "$MCPB" manifest.json bin LICENSE THIRD_PARTY_LICENSES.md )

# ─── contrôles APRÈS empaquetage : on rouvre ce qu'on vient d'écrire ────────
#
# Tout ce qui précède porte sur des fichiers qu'on maîtrise ; ce qui suit porte
# sur l'archive telle que Claude Desktop la recevra. C'est la seule vérification
# qui vaille.

echo "== contrôles de l'archive"
unzip -tqq "$MCPB" || {
    echo "mcpb.sh : archive illisible" >&2; exit 1; }
echo "   zip valide"

CHECK="$STAGE/check"
mkdir -p "$CHECK"
unzip -qq "$MCPB" -d "$CHECK"

plutil -convert xml1 -o /dev/null "$CHECK/manifest.json" || {
    echo "mcpb.sh : manifest.json illisible dans l'archive" >&2; exit 1; }
echo "   manifest.json : version $(json version "$CHECK/manifest.json"), schéma $(json manifest_version "$CHECK/manifest.json"), $(json tools "$CHECK/manifest.json") outils"

[ -x "$CHECK/$ENTRY" ] || {
    echo "mcpb.sh : $ENTRY absent ou non exécutable dans l'archive" >&2; exit 1; }
echo "   $ENTRY : exécutable, tranches $(lipo -archs "$CHECK/$ENTRY")"

# Le sceau survit-il à l'aller-retour par le zip ? S'il ne survivait pas, on ne
# l'apprendrait que chez l'utilisateur, au premier lancement refusé.
codesign --verify --strict "$CHECK/$ENTRY" 2>/dev/null || {
    echo "mcpb.sh : la signature du binaire n'a pas survécu à l'archivage" >&2
    exit 1; }
echo "   signature vérifiée après extraction"

for licence in LICENSE THIRD_PARTY_LICENSES.md; do
    [ -s "$CHECK/$licence" ] || {
        echo "mcpb.sh : $licence absent de l'archive" >&2; exit 1; }
done
echo "   LICENSE et THIRD_PARTY_LICENSES.md présents"

echo "mcpb.sh : $MCPB ($(du -h "$MCPB" | cut -f1))"
