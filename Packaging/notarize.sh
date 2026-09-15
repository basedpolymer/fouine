#!/bin/sh
# notarize.sh — notarisation et agrafage de Fouine (SPEC §11.2).
# Propriété : A-Pack.  ***LIVRÉ MAIS NON EXÉCUTÉ AUTOMATIQUEMENT.***
#
# Accepte un .app OU un .dmg :
#     Packaging/notarize.sh Fouine.app                 (via `make notarize`)
#     Packaging/notarize.sh dist/Fouine-1.0.0.dmg      (ce qui est distribué)
# Un .app est zippé avant l'envoi (`ditto -c -k --keepParent`, seul format que
# notarytool accepte pour un bundle) puis agrafé DANS SON ARBORESCENCE ; un DMG
# est envoyé et agrafé tel quel. Pour une release publique c'est le DMG signé
# qu'il faut soumettre et agrafer : l'agrafe sur l'app seule est perdue dès que
# l'app est recopiée dans une image disque construite ensuite.
#
# ┌───────────────────────────────────────────────────────────────────────────┐
# │ GESTE HUMAIN PRÉALABLE, UNE FOIS, ET IMPOSSIBLE À AUTOMATISER            │
# │                                                                           │
# │ `notarytool` exige un profil de trousseau, créé à partir d'une clé App    │
# │ Store Connect (Utilisateurs et accès ▸ Intégrations ▸ Clés API). Trois    │
# │ éléments, tous PERSONNELS et tous hors dépôt :                            │
# │   · le fichier de clé privée  AuthKey_<KEYID>.p8  (téléchargeable UNE     │
# │     seule fois, à ranger hors du dépôt — voir .gitignore : *.p8)          │
# │   · l'identifiant de clé <KEYID>                                          │
# │   · l'ISSUER ID, un UUID lisible uniquement sur appstoreconnect.com       │
# │                                                                           │
# │ À exécuter à la main, une seule fois, en remplaçant les trois valeurs :   │
# │                                                                           │
# │   xcrun notarytool store-credentials <profil> \                           │
# │     --key /chemin/hors-depot/AuthKey_<KEYID>.p8 \                         │
# │     --key-id <KEYID> \                                                    │
# │     --issuer <UUID>                                                       │
# │                                                                           │
# │ Puis, si <profil> n'est pas « fouine », renseignez-le dans Makefile.local │
# │ (FOUINE_NOTARY_PROFILE) ou dans l'environnement. Ensuite seulement :      │
# │ `make notarize`.                                                          │
# │                                                                           │
# │ En intégration continue, on ne passe PAS par le trousseau : release.yml   │
# │ écrit la clé dans un fichier temporaire depuis les secrets et appelle     │
# │ notarytool avec --key/--key-id/--issuer (voir .github/workflows).         │
# └───────────────────────────────────────────────────────────────────────────┘
#
# Rappel du §11.1 : la notarisation ne sert QU'À une chose — que l'app s'ouvre
# sur une AUTRE machine, ou après un transfert qui pose la quarantaine
# (téléchargement, AirDrop, clé USB). Pour l'usage local sur ce Mac, la
# signature Developer ID seule suffit, et elle est déjà faite par `make release`.
# Une signature AD HOC (IDENTITY vide) ne peut pas être notarisée du tout :
# le script le dit et s'arrête.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TARGET="${1:-$ROOT/Fouine.app}"
PROFILE="${FOUINE_NOTARY_PROFILE:-fouine}"

case "$TARGET" in
    *.dmg) KIND=dmg ;;
    *.app) KIND=app ;;
    *)     echo "notarize.sh : attendu un .app ou un .dmg, reçu « $TARGET »" >&2; exit 1 ;;
esac

if [ "$KIND" = app ]; then
    [ -d "$TARGET" ] || {
        echo "notarize.sh : $TARGET introuvable — \`make release\` d'abord" >&2; exit 1; }
else
    [ -f "$TARGET" ] || {
        echo "notarize.sh : $TARGET introuvable — \`make dmg\` d'abord" >&2; exit 1; }
fi

# La notarisation REFUSE un binaire non signé ou sans runtime durci : on vérifie
# avant d'envoyer 30 Mo au serveur d'Apple.
codesign --verify --deep --strict "$TARGET" || {
    echo "notarize.sh : $TARGET n'est pas signé correctement — \`make release\` d'abord" >&2
    exit 1
}

# Refus explicite de l'ad hoc : sans autorité de certification, le serveur
# d'Apple rejette la soumission après plusieurs minutes d'attente. Autant le
# dire tout de suite, et dire quoi faire.
if codesign -dv --verbose=4 "$TARGET" 2>&1 | grep -q 'Signature=adhoc'; then
    echo "notarize.sh : $TARGET porte une signature AD HOC — non notarisable." >&2
    echo "              Renseignez IDENTITY (Makefile.local) puis relancez" >&2
    echo "              \`make release\` avant \`make notarize\`." >&2
    exit 1
fi

# Le runtime durci ne se contrôle que sur un bundle : un DMG n'en a pas.
if [ "$KIND" = app ]; then
    codesign -d --verbose=4 "$TARGET" 2>&1 | grep -q 'flags=.*runtime' || {
        echo "notarize.sh : runtime durci absent (option --options runtime) — voir §11.2" >&2
        exit 1
    }
fi

# Contrôle indicatif du profil de trousseau. En cas de doute on laisse
# notarytool trancher : c'est lui qui a le dernier mot.
if ! security find-generic-password -s 'com.apple.gke.notary.tool' >/dev/null 2>&1; then
    echo "notarize.sh : aucun profil notarytool trouvé dans le trousseau."
    echo "              Exécutez d'abord le \`store-credentials\` documenté en"
    echo "              tête de ce script, puis relancez."
fi

if [ "$KIND" = app ]; then
    ZIP="${TARGET%.app}.zip"
    echo "== 1/4  ditto -c -k --keepParent"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$TARGET" "$ZIP"
    SUBMIT="$ZIP"
else
    echo "== 1/4  (DMG : rien à zipper, notarytool l'accepte tel quel)"
    SUBMIT="$TARGET"
fi

echo "== 2/4  xcrun notarytool submit --keychain-profile $PROFILE --wait"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait

# On agrafe la CIBLE, pas l'archive : l'agrafe se pose dans le .app ou dans le
# .dmg, jamais dans le .zip de transport.
echo "== 3/4  xcrun stapler staple"
xcrun stapler staple "$TARGET"

echo "== 4/4  contrôles S2 et S3 (§8.3)"
if [ "$KIND" = app ]; then
    spctl -a -vv "$TARGET"           # attendu : accepted / source=Notarized Developer ID
else
    spctl -a -t open --context context:primary-signature -vv "$TARGET"
fi
xcrun stapler validate "$TARGET"     # attendu : The validate action worked!
