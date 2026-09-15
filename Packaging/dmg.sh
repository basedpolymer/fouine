#!/bin/sh
# dmg.sh — image disque de distribution (audit D13, palier 1.5).
# Propriété : A-Pack. Appelé par `make dmg`.
#
#   Usage : Packaging/dmg.sh <chemin du .app> [chemin du .dmg]
#   Variables lues dans l'environnement (posées par le Makefile) :
#       IDENTITY   identité codesign ; vide = ad hoc, le DMG n'est PAS signé
#       VERSION    numéro de version, sert au nom par défaut
#
# `hdiutil` SEUL, volontairement : le projet s'interdit toute dépendance
# nouvelle (SPEC §2.2), Homebrew compris. `create-dmg`, recommandé par l'audit,
# apporterait une fenêtre décorée avec image de fond et positions d'icônes ;
# c'est un confort, pas une exigence, et il coûterait un outil externe à
# installer sur toute machine qui publie — runner GitHub compris. Le contenu
# livré ici est celui qui compte :
#
#   /Volumes/Fouine/
#     Fouine.app          l'application signée
#     Applications        lien symbolique — le geste « glisser dans
#                         Applications » sans ouvrir une seconde fenêtre
#     LICENSE             la licence, lisible avant l'installation
#
# UDZO (zlib) et non UDBZ/ULFO : c'est le format que tout macOS depuis 10.4
# monte sans surprise, et le gain des autres est marginal sur un bundle déjà
# compressé. Le DMG est signé quand une vraie identité est disponible : c'est
# LUI qui est notarisé et agrafé pour une release publique (Packaging/notarize.sh),
# parce qu'une agrafe posée sur l'app seule est perdue dès qu'on la recopie
# dans une image construite après coup.
set -eu

NAME_ONLY=0
if [ "${1:-}" = "--name-only" ]; then
    NAME_ONLY=1
    shift
fi

APP="${1:?usage: dmg.sh [--name-only] <app> [dmg]}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"

if [ -n "${2:-}" ]; then
    DMG="$2"
elif [ -z "${CI:-}" ] && ! git -C "$ROOT" describe --exact-match --tags >/dev/null 2>&1; then
    BUILD_NUM=""
    if [ -f "$APP/Contents/Info.plist" ]; then
        BUILD_NUM=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)
    fi
    if [ -z "$BUILD_NUM" ]; then
        BUILD_NUM=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)
    fi
    DMG="$ROOT/dist/Fouine-$VERSION-b$BUILD_NUM.dmg"
else
    DMG="$ROOT/dist/Fouine-$VERSION.dmg"
fi

if [ "$NAME_ONLY" = 1 ]; then
    echo "$DMG"
    exit 0
fi
VOLNAME="Fouine"

[ -d "$APP" ] || { echo "dmg.sh : $APP introuvable — \`make release\` d'abord" >&2; exit 1; }

# Une image faite à partir d'un bundle non signé se monte très bien et échoue
# chez l'utilisateur. On refuse tôt.
codesign --verify --deep --strict "$APP" 2>/dev/null || {
    echo "dmg.sh : $APP n'est pas signé — \`make release\` d'abord" >&2; exit 1; }

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"

# Dossier de mise en scène : hdiutil prend une ARBORESCENCE, pas une liste de
# fichiers. Il est jetable, et nettoyé même en cas d'échec.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/fouine-dmg.XXXXXX")
cleanup() {
    # Un montage laissé derrière soi verrouille l'image ; on le défait avant de
    # supprimer quoi que ce soit.
    if [ -n "${MOUNT:-}" ]; then
        hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
        rmdir "$MOUNT" 2>/dev/null || true
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT

echo "== 1/5  mise en scène"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# LICENSE et THIRD_PARTY_LICENSES.md voyagent tous les deux dans l'image :
# quelqu'un qui n'a que le DMG doit trouver la licence du produit ET les notices
# MIT et Apache-2.0 des composants redistribués (audit B1-10). Ils sont AUSSI dans
# Fouine.app/Contents/Resources/ (bundle.sh) — ici, ils sont visibles sans avoir
# à ouvrir le paquet.
for licence in LICENSE THIRD_PARTY_LICENSES.md; do
    if [ -f "$ROOT/$licence" ]; then
        cp "$ROOT/$licence" "$STAGE/$licence"
    else
        echo "dmg.sh : ATTENTION — $licence absent, image sans cette notice" >&2
    fi
done

echo "== 2/5  hdiutil create ($VOLNAME, UDZO)"
hdiutil create -quiet \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG"

# Signer le DMG n'a de sens qu'avec un vrai certificat : `codesign --sign -`
# sur une image produit une signature ad hoc que Gatekeeper ignore, et que la
# notarisation refuse. En mode ad hoc on livre donc un DMG NON signé, et on le
# dit.
if [ -n "${IDENTITY:-}" ]; then
    echo "== 3/5  codesign du DMG ($IDENTITY)"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
else
    echo "== 3/5  DMG NON signé : IDENTITY est vide (mode ad hoc)."
    echo "        Cette image ne peut être ni notarisée ni ouverte ailleurs ;"
    echo "        elle sert au test local du montage. Voir Makefile.local."
fi

echo "== 4/5  hdiutil verify"
hdiutil verify -quiet "$DMG"

# Contrôle final, celui qui attrape les vraies pannes : une image qui passe
# `verify` mais ne se monte pas (volume plein, lien symbolique cassé) existe.
echo "== 5/5  montage / démontage d'essai"
MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/fouine-mnt.XXXXXX")
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -quiet -mountpoint "$MOUNT"
[ -d "$MOUNT/Fouine.app" ] || {
    echo "dmg.sh : Fouine.app absente du volume monté" >&2; exit 1; }
[ -L "$MOUNT/Applications" ] || {
    echo "dmg.sh : lien /Applications absent du volume monté" >&2; exit 1; }
ls -1 "$MOUNT"
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT" 2>/dev/null || true
MOUNT=""

echo "dmg.sh : $DMG"
echo "  $(du -h "$DMG" | cut -f1)  $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
