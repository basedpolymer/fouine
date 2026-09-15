#!/bin/sh
# l10n-lint.sh — aucune chaîne visible n'échappe aux catalogues (audit U1).
#
# Ce garde-fou est ce qui empêche la PROCHAINE contribution de réintroduire du
# texte non traduit : `Text("Nouveau bouton")` sans entrée de catalogue fait
# échouer le test `L10nLintTests`, qui appelle ce script.
#
#   ./Tools/l10n-lint.sh
#
# Sortie 0 : tout est traduit. Sortie 1 : la liste des manques, avec le fichier
# et la ligne. Voir docs/i18n.md pour la marche à suivre.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if ! command -v python3 >/dev/null 2>&1; then
    echo "l10n-lint : python3 introuvable (il est livré avec les outils de" \
         "développement d'Xcode)." >&2
    exit 1
fi

exec python3 "$ROOT/Tools/l10n/lint.py"
