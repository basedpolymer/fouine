#!/bin/sh
# cask.sh — remplit le cask Homebrew avec la version et l'empreinte du DMG
# publié (audit D13). Propriété : A-App, palier 3.4. Appelé par RELEASING.md
# étape 7.
#
#   Packaging/cask.sh 1.0.0 dist            > /tmp/fouine.rb
#   Packaging/cask.sh 1.0.0 dist ~/homebrew-fouine/Casks/fouine.rb
#
# Le cask sort sur la SORTIE STANDARD (ou dans le fichier passé en troisième
# argument), prêt à déposer dans le tap. Deux lignes changent d'une version à
# l'autre — `version` et `sha256` — et ce script est là pour qu'on ne les
# recopie pas à la main : un `sha256` faux ne se voit qu'au moment où un
# utilisateur tente d'installer.
#
# L'EMPREINTE VIENT DE `dist/SHA256SUMS`, le fichier que l'étape 4 fabrique
# (`shasum -a 256 dist/*.dmg`) et que la release publie. C'est donc EXACTEMENT
# la valeur que l'utilisateur peut vérifier lui-même contre l'asset téléchargé ;
# la recalculer ici depuis un DMG local, qui n'est pas forcément celui que la CI
# a publié, aurait été une occasion de plus de se tromper.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMPLATE="$ROOT/Packaging/homebrew/fouine.rb"

usage() {
    echo "usage: $0 <version> [répertoire dist] [fichier de sortie]" >&2
    echo "   ex: $0 1.0.0 dist ~/homebrew-fouine/Casks/fouine.rb" >&2
    exit 2
}

[ $# -ge 1 ] || usage
VERSION="$1"
DIST="${2:-$ROOT/dist}"
OUTPUT="${3:-}"

case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "cask.sh : « $VERSION » n'est pas une version x.y.z" >&2; exit 1 ;;
esac

[ -f "$TEMPLATE" ] || { echo "cask.sh : $TEMPLATE est introuvable" >&2; exit 1; }

SUMS="$DIST/SHA256SUMS"
DMG="Fouine-$VERSION.dmg"
if [ ! -f "$SUMS" ]; then
    echo "cask.sh : $SUMS est introuvable — fabriquez le DMG et ses sommes" >&2
    echo "          d'abord (RELEASING.md étapes 4 et 4 bis)." >&2
    exit 1
fi

# La ligne du DMG de CETTE version, et elle seule : `dist/` peut contenir les
# images de plusieurs versions après un essai de bout en bout (étape 4 quater),
# et prendre la première venue installerait la mauvaise.
SHA=$(awk -v want="$DMG" '{
        name = $2
        sub(/^\*/, "", name)          # shasum -b préfixe le nom d une étoile
        n = split(name, parts, "/")
        if (parts[n] == want) { print $1; exit }
      }' "$SUMS")

if [ -z "$SHA" ]; then
    echo "cask.sh : aucune ligne pour « $DMG » dans $SUMS" >&2
    echo "          présent : $(awk '{print $2}' "$SUMS" | tr '\n' ' ')" >&2
    exit 1
fi

case "$SHA" in
    ????????????????????????????????????????????????????????????????) ;;
    *) echo "cask.sh : empreinte de longueur inattendue : « $SHA »" >&2; exit 1 ;;
esac

# `sed` sur les DEUX lignes nommées, pas une réécriture du fichier : tout le
# reste du cask — `zap`, `uninstall launchctl:`, les caveats — doit passer tel
# quel, commentaires compris.
RENDERED=$(sed \
    -e "s|^  version \".*\"$|  version \"$VERSION\"|" \
    -e "s|^  sha256 \".*\"$|  sha256 \"$SHA\"|" \
    "$TEMPLATE")

# Contrôle : les deux lignes ont-elles VRAIMENT changé ? Un modèle réorganisé
# ferait sortir un cask à l'empreinte de gabarit, qui refuserait d'installer
# chez l'utilisateur sans que rien ici n'ait rougi.
echo "$RENDERED" | grep -q "^  version \"$VERSION\"$" \
    || { echo "cask.sh : la ligne « version » n'a pas été remplacée" >&2; exit 1; }
echo "$RENDERED" | grep -q "^  sha256 \"$SHA\"$" \
    || { echo "cask.sh : la ligne « sha256 » n'a pas été remplacée" >&2; exit 1; }

if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$RENDERED" > "$OUTPUT"
    echo "cask.sh : $OUTPUT — version $VERSION, sha256 $SHA" >&2
else
    printf '%s\n' "$RENDERED"
fi
