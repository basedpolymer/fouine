#!/bin/sh
# appcast.sh — fabrique dist/appcast.xml, le flux que Sparkle lit (audit D13).
# SPEC §11.2. Propriété : A-Pack. Appelé par `RELEASING.md` étape 4 bis et par
# .github/workflows/release.yml après le DMG.
#
# ─── CE QUE FAIT CE SCRIPT ─────────────────────────────────────────────────
# `generate_appcast`, livré dans l'artefact Sparkle, ouvre chaque archive de
# `dist/`, y lit l'Info.plist de l'app, et écrit un `appcast.xml` où chaque
# entrée porte : sparkle:shortVersionString (= CFBundleShortVersionString),
# sparkle:version (= CFBundleVersion, l'entier monotone posé par `make stamp` —
# c'est CE champ que Sparkle compare), la taille, l'URL de téléchargement et
# une SIGNATURE EdDSA du fichier. Sans cette signature, Sparkle refuse
# l'installation : c'est tout l'intérêt du dispositif.
#
# ─── LA CLÉ PRIVÉE ─────────────────────────────────────────────────────────
# Deux sources, dans cet ordre :
#   1. $SPARKLE_PRIVATE_KEY — le contenu de la clé, passé sur l'entrée standard
#      (`--ed-key-file -`). C'est le chemin de la CI : le secret GitHub tient la
#      clé, rien ne touche le disque du runner.
#   2. le trousseau du Mac (compte « ed25519 »), où `generate_keys` l'a rangée.
#      C'est le chemin d'une publication à la main, et le bon : la clé ne quitte
#      jamais le trousseau.
# Elle n'est JAMAIS écrite dans le dépôt, ni dans `dist/`, ni dans un journal.
# Perdre cette clé, c'est perdre la possibilité de mettre à jour les copies déjà
# installées : sauvegardez-la comme un mot de passe maître (RELEASING.md).
#
# Usage : appcast.sh [répertoire des archives] [version]
#         appcast.sh dist 1.0.0
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST="${1:-$ROOT/dist}"
VERSION="${2:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"

# Dépôt public : sert à fabriquer l'URL de téléchargement des assets et le lien
# « page du projet » que Sparkle propose quand le téléchargement échoue.
REPO="${FOUINE_REPO:-basedpolymer/fouine}"

# `generate_appcast` vit dans l'artefact binaire de Sparkle, téléchargé par
# `swift package resolve`. Son chemin exact dépend de la version de SwiftPM :
# on le cherche, on ne le devine pas.
GENERATE="${SPARKLE_GENERATE_APPCAST:-}"
if [ -z "$GENERATE" ]; then
    GENERATE=$(find "$ROOT/.build/artifacts" -type f -name generate_appcast \
                    -perm -u+x -print 2>/dev/null | head -n 1)
fi
if [ -z "$GENERATE" ] || [ ! -x "$GENERATE" ]; then
    echo "appcast.sh : generate_appcast introuvable sous .build/artifacts." >&2
    echo "  Lancez \`swift package resolve\` (il télécharge l'artefact Sparkle)," >&2
    echo "  ou passez son chemin dans SPARKLE_GENERATE_APPCAST." >&2
    exit 1
fi

if [ ! -d "$DIST" ]; then
    echo "appcast.sh : $DIST n'existe pas — lancez d'abord \`make dmg\`." >&2
    exit 1
fi

# Au moins une archive à publier, sinon `generate_appcast` rend un flux VIDE
# sans se plaindre, et une release part avec un appcast qui n'annonce rien.
# Une boucle et non `ls "$DIST"/*.dmg "$DIST"/*.zip` : `ls` échoue dès qu'UN de
# ses motifs ne correspond à rien, même si l'autre correspond — le DMG était là
# et le script sortait en erreur parce qu'il n'y avait pas de .zip.
ARCHIVES=0
for archive in "$DIST"/*.dmg "$DIST"/*.zip; do
    [ -e "$archive" ] && ARCHIVES=$((ARCHIVES + 1))
done
if [ "$ARCHIVES" -eq 0 ]; then
    echo "appcast.sh : aucun .dmg ni .zip dans $DIST — rien à publier." >&2
    exit 1
fi

# ─── Garde-fous du CHANGELOG ───────────────────────────────────────────────
# Les notes fabriquées plus bas sont ce que Sparkle affiche à CHAQUE
# utilisateur, et ce que `release.yml` joint à la release. Elles sortent d'une
# SEULE section du CHANGELOG — et trois façons de se tromper les rendraient
# fausses sans que rien n'échoue (audit B1-04, contre-expertise D2-06) :
#
#   a. une section « Non publié » NON VIDE subsiste. Le journal n'a pas été
#      refermé pour cette version : l'awk plus bas trouverait quand même la
#      section « ## [X.Y.Z] » et n'emporterait qu'une partie du travail. C'est
#      le cas mesuré le 02/09/2026, où les notes de la première version
#      publique auraient été le seul avis de faille du palier 0. Le repli
#      `[ -s "$NOTES.tmp" ]` ne le voit PAS : le fichier produit n'est pas
#      vide. D'où un contrôle AVANT l'awk, et non après ;
#   b. il n'y a aucune section pour cette version ;
#   c. le titre porte encore « unreleased » : les notes ne sont pas datées,
#      donc l'étape 2 de `RELEASING.md` n'a pas été faite. Le journal est en
#      anglais depuis le 13/09/2026 (lot DC2) ; la forme française « à venir »
#      reste refusée, pour qu'un titre réintroduit par une fusion ne passe pas.
#
# `exit 1` et non un avertissement : ce script tourne dans `release.yml`, où un
# avertissement ne serait lu par personne. Le même contrôle, sans (c), vit dans
# `make check-changelog` — appelée par `ci.yml`, elle le fait voir AVANT le tag.
CHANGELOG="$ROOT/CHANGELOG.md"

UNRELEASED=$(awk '
    /^## +(Non publié|Unreleased)/ { inside = 1; next }
    inside && /^## /               { exit }
    inside && NF                   { print }
' "$CHANGELOG" | wc -l | tr -d " ")
if [ "$UNRELEASED" -gt 0 ]; then
    echo "appcast.sh : $UNRELEASED ligne(s) sous « ## Non publié » — refermez la" \
         "section dans CHANGELOG.md avant de publier v$VERSION." >&2
    exit 1
fi

TITLE=$(grep "^## \[$VERSION\]" "$CHANGELOG" | head -n 1)
if [ -z "$TITLE" ]; then
    echo "appcast.sh : aucune section « ## [$VERSION] » dans CHANGELOG.md —" \
         "les notes de version de v$VERSION n'existent pas." >&2
    exit 1
fi
case "$TITLE" in
    *unreleased*|*"à venir"*)
        echo "appcast.sh : « $TITLE » — datez le titre" \
             "(« ## [$VERSION] — $(date +%Y-%m-%d) ») dans CHANGELOG.md" \
             "avant de publier v$VERSION (RELEASING.md § 2)." >&2
        exit 1 ;;
esac

# ─── Notes de version ──────────────────────────────────────────────────────
# `generate_appcast` associe à une archive « Fouine-1.0.0.dmg » le fichier de
# notes « Fouine-1.0.0.md » posé À CÔTÉ. On le fabrique depuis le CHANGELOG :
# la section de CETTE version, sans son titre. C'est le seul endroit où les
# notes sont écrites, elles ne peuvent donc pas diverger de la release.
NOTES=""
for archive in "$DIST"/*.dmg "$DIST"/*.zip; do
    [ -e "$archive" ] || continue
    NOTES="${archive%.*}.md"
done

if [ -n "$NOTES" ] && [ ! -f "$NOTES" ]; then
    # awk plutôt que sed : il faut s'arrêter au TITRE SUIVANT, pas à la
    # première ligne vide. `## [1.0.0] — 2026-09-02` ou `## [1.0.0] — à venir`.
    awk -v v="$VERSION" '
        $0 ~ "^## \\[" v "\\]" { inside = 1; next }
        inside && /^## / { exit }
        inside { print }
    ' "$ROOT/CHANGELOG.md" > "$NOTES.tmp"

    if [ -s "$NOTES.tmp" ]; then
        mv "$NOTES.tmp" "$NOTES"
        echo "appcast.sh : notes de version tirées du CHANGELOG → $(basename "$NOTES")"
    else
        # Section présente mais VIDE. Le garde-fou (b) ci-dessus a déjà refusé
        # l'absence de section ; il reste le titre suivi de rien. On ne fabrique
        # pas de notes vides : `--full-release-notes-url` renverra l'utilisateur
        # vers la page des versions.
        rm -f "$NOTES.tmp"
        NOTES=""
        echo "appcast.sh : aucune section « ## [$VERSION] » dans CHANGELOG.md —" \
             "les notes renverront vers la page des versions." >&2
    fi
fi

# ─── Clé de signature ──────────────────────────────────────────────────────
set -- "$DIST" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO" \
    --full-release-notes-url "https://github.com/$REPO/releases" \
    -o "$DIST/appcast.xml"

# Les notes du CHANGELOG sont du Markdown SANS balises HTML : `--embed-release-
# notes` les met dans le flux lui-même, ce qui évite un second fichier à publier
# comme asset de release et une seconde requête réseau au moment de la mise à
# jour.
[ -n "$NOTES" ] && set -- "$@" --embed-release-notes

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    echo "appcast.sh : signature avec la clé fournie par l'environnement"
    # `--ed-key-file -` lit la clé sur l'entrée standard : elle ne passe ni par
    # la ligne de commande (visible dans `ps`), ni par un fichier temporaire.
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE" --ed-key-file - "$@"
else
    echo "appcast.sh : signature avec la clé EdDSA du trousseau (compte ed25519)"
    "$GENERATE" "$@"
fi

# ─── Contrôles ─────────────────────────────────────────────────────────────
# Un appcast sans signature s'installe chez personne : Sparkle rejette l'item et
# l'utilisateur voit « mise à jour impossible » sans savoir pourquoi. Autant
# échouer ici, où la cause est connue.
if [ ! -f "$DIST/appcast.xml" ]; then
    echo "appcast.sh : generate_appcast n'a produit aucun appcast.xml." >&2
    exit 1
fi
if ! grep -q 'sparkle:edSignature' "$DIST/appcast.xml"; then
    echo "appcast.sh : appcast.xml SANS sparkle:edSignature — les entrées ne" >&2
    echo "  s'installeront chez personne. Vérifié le 02/09/2026 :" \
         "generate_appcast" >&2
    echo "  n'échoue PAS dans ce cas, il écrit un flux non signé après une" >&2
    echo "  simple ligne « Warning ». D'où ce contrôle." >&2
    echo >&2
    echo "  Cause la plus fréquente, et de loin : SUPublicEDKey est vide ou" >&2
    echo "  différente dans Packaging/Info.plist. generate_appcast compare la" >&2
    echo "  clé PUBLIQUE embarquée dans l'app à celle qui dérive de la clé" >&2
    echo "  privée, et refuse de signer si elles diffèrent — c'est l'état du" >&2
    echo "  dépôt tant que \`generate_keys\` n'a pas été lancé une fois." >&2
    echo "  Autres causes : trousseau sans clé « ed25519 », ou" >&2
    echo "  SPARKLE_PRIVATE_KEY mal renseignée." >&2
    echo "  Voir RELEASING.md, « Mises à jour Sparkle »." >&2
    exit 1
fi

echo "appcast.sh : $DIST/appcast.xml"
# Ces trois lignes sont le contrôle qui compte : sparkle:version doit être
# l'entier monotone de `make stamp`, et l'URL doit être celle de l'asset de la
# release qu'on s'apprête à publier.
grep -oE 'sparkle:(short)?[Vv]ersion(String)?="[^"]*"' "$DIST/appcast.xml" \
    | sed 's/^/  /'
grep -oE 'url="[^"]*"' "$DIST/appcast.xml" | sed 's/^/  /'
