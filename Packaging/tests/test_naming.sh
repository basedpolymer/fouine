#!/bin/sh
# test_naming.sh — vérification du nommage des artefacts (.dmg et .mcpb)
# Test shell léger (audit a4-04).
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")

echo "test_naming : vérification du nommage des artefacts..."

# 1. Hors CI et hors tag, le DMG porte le numéro de build (-b<n>)
# HEAD sur un tag : hors CI aussi, le nom CANONIQUE est attendu (RELEASING § 5),
# et c'est le cas d'un `make release` joué sur le commit tagué d'une version.
ON_TAG=""
git -C "$ROOT" describe --exact-match --tags >/dev/null 2>&1 && ON_TAG=1
DMG_DEV=$(unset CI; "$ROOT/Packaging/dmg.sh" --name-only "$ROOT/Fouine.app")
if [ -n "$ON_TAG" ]; then
    echo "  hors CI, HEAD sur un tag (DMG) : $DMG_DEV"
    [ "$DMG_DEV" = "$ROOT/dist/Fouine-$VERSION.dmg" ] || {
        echo "ÉCHEC : sur un tag, nommage canonique attendu $ROOT/dist/Fouine-$VERSION.dmg, obtenu $DMG_DEV" >&2
        exit 1
    }
else
    echo "  hors CI, hors tag (DMG) : $DMG_DEV"
    case "$DMG_DEV" in
        *"/dist/Fouine-$VERSION-b"*".dmg") ;;
        *) echo "ÉCHEC : nommage dev attendu /dist/Fouine-$VERSION-b*.dmg, obtenu $DMG_DEV" >&2; exit 1 ;;
    esac
fi

# 2. En CI, le DMG a son nom canonique (Fouine-<version>.dmg)
DMG_CI=$(CI=true "$ROOT/Packaging/dmg.sh" --name-only "$ROOT/Fouine.app")
echo "  en CI (DMG) : $DMG_CI"
[ "$DMG_CI" = "$ROOT/dist/Fouine-$VERSION.dmg" ] || {
    echo "ÉCHEC : nommage CI attendu $ROOT/dist/Fouine-$VERSION.dmg, obtenu $DMG_CI" >&2
    exit 1
}

# 3. Argument explicite respecté pour le DMG
DMG_CUSTOM=$("$ROOT/Packaging/dmg.sh" --name-only "$ROOT/Fouine.app" "/tmp/custom.dmg")
echo "  explicite (DMG) : $DMG_CUSTOM"
[ "$DMG_CUSTOM" = "/tmp/custom.dmg" ] || {
    echo "ÉCHEC : nommage explicite non respecté pour le DMG" >&2
    exit 1
}

# 4. Hors CI et hors tag, le MCPB porte le numéro de build (-b<n>)
MCPB_DEV=$(unset CI; "$ROOT/Packaging/mcpb.sh" --name-only "$ROOT/Fouine.app")
if [ -n "$ON_TAG" ]; then
    echo "  hors CI, HEAD sur un tag (MCPB) : $MCPB_DEV"
    [ "$MCPB_DEV" = "$ROOT/dist/Fouine-$VERSION.mcpb" ] || {
        echo "ÉCHEC : sur un tag, nommage canonique attendu $ROOT/dist/Fouine-$VERSION.mcpb, obtenu $MCPB_DEV" >&2
        exit 1
    }
else
    echo "  hors CI, hors tag (MCPB) : $MCPB_DEV"
    case "$MCPB_DEV" in
        *"/dist/Fouine-$VERSION-b"*".mcpb") ;;
        *) echo "ÉCHEC : nommage dev attendu /dist/Fouine-$VERSION-b*.mcpb, obtenu $MCPB_DEV" >&2; exit 1 ;;
    esac
fi

# 5. En CI, le MCPB a son nom canonique (Fouine-<version>.mcpb)
MCPB_CI=$(CI=true "$ROOT/Packaging/mcpb.sh" --name-only "$ROOT/Fouine.app")
echo "  en CI (MCPB) : $MCPB_CI"
[ "$MCPB_CI" = "$ROOT/dist/Fouine-$VERSION.mcpb" ] || {
    echo "ÉCHEC : nommage CI attendu $ROOT/dist/Fouine-$VERSION.mcpb, obtenu $MCPB_CI" >&2
    exit 1
}

# 6. Argument explicite respecté pour le MCPB
MCPB_CUSTOM=$("$ROOT/Packaging/mcpb.sh" --name-only "$ROOT/Fouine.app" "/tmp/custom.mcpb")
echo "  explicite (MCPB) : $MCPB_CUSTOM"
[ "$MCPB_CUSTOM" = "/tmp/custom.mcpb" ] || {
    echo "ÉCHEC : nommage explicite non respecté pour le MCPB" >&2
    exit 1
}

echo "test_naming : OK (tous les cas de nommage validés)"
