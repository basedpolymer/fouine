#!/bin/sh
# package_model.sh — fabrique l'archive du modèle sémantique et son empreinte.
# Propriété : A-Embed (palier 3, audit D6).
#
# L'asset publié en release doit être REGÉNÉRABLE : sans ce script, la seule
# façon de refaire l'archive serait de se souvenir des options exactes de ditto,
# et une option de travers change l'empreinte donc casse `fouine model download`.
#
#   Tools/package_model.sh <dossier-du-modele> <archive.zip>
#
# Écrit <archive.zip> et <archive.zip>.sha256, et rappelle les trois constantes
# à recopier dans Sources/FouineEmbed/ModelDownload.swift. Procédure complète :
# RELEASING.md, section « Publier le modèle sémantique ».
#
# `ditto -c -k --keepParent` et non `zip` : c'est l'outil du système, il conserve
# le DOSSIER DE TÊTE (`e5-small/`) — la disposition exacte que l'installateur
# valide — et il produit un zip que `ditto -x -k`, seule voie de décompression
# du produit, relit sans surprise.
#
# L'archive n'est PAS reproductible bit à bit d'une fabrication à l'autre : le
# zip porte les horodatages des fichiers. Ce n'est pas un problème ici, parce
# que l'empreinte publiée est celle de L'ARCHIVE RÉELLEMENT PUBLIÉE, calculée
# par ce script sur ce fichier-là. Refabriquer l'archive impose donc de
# republier l'empreinte — d'où le rappel en fin de script.

set -eu

if [ $# -ne 2 ]; then
    echo "usage: $0 <dossier-du-modele> <archive.zip>" >&2
    echo "exemple : $0 ~/Library/Application\\ Support/Fouine/models/e5-small dist/e5-small-v1.zip" >&2
    exit 64
fi

source_dir=$1
archive=$2

[ -d "$source_dir" ] || { echo "$0: dossier introuvable : $source_dir" >&2; exit 1; }

# Les trois pièces qu'`EmbedPaths.modelAvailable` exige. Mieux vaut refuser ici
# que publier 220 Mo d'archive que l'installateur rejettera.
for piece in meta.json vocab.json E5Small.mlmodelc; do
    if [ ! -e "$source_dir/$piece" ]; then
        echo "$0: pièce manquante dans $source_dir : $piece" >&2
        exit 1
    fi
done

# Le dossier de tête de l'archive est le NOM du dossier source : l'installateur
# attend « e5-small/ », pas autre chose.
leaf=$(basename "$source_dir")
if [ "$leaf" != "e5-small" ]; then
    echo "$0: avertissement — le dossier de tête sera « $leaf/ » et non" >&2
    echo "    « e5-small/ » : fouine model download refusera cette archive." >&2
fi

mkdir -p "$(dirname "$archive")"
rm -f "$archive" "$archive.sha256"

echo "archivage de $source_dir …"
/usr/bin/ditto -c -k --keepParent "$source_dir" "$archive"

bytes=$(/usr/bin/stat -f %z "$archive")
digest=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/cut -d' ' -f1)
# Même format que `shasum -a 256 fichier > fichier.sha256`, pour que
# `shasum -a 256 -c archive.zip.sha256` fonctionne tel quel.
printf '%s  %s\n' "$digest" "$(basename "$archive")" > "$archive.sha256"

cat <<EOF

archive : $archive
taille  : $bytes octets
sha-256 : $digest

À recopier dans Sources/FouineEmbed/ModelDownload.swift :
    public static let expectedBytes: Int64 = $bytes
    public static let expectedSHA256 = "$digest"
et à vérifier : defaultURLString doit porter le tag de la release à publier.
EOF
