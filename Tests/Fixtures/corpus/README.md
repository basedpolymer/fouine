# Corpus de fixtures versionné

39 fichiers et paquets (42 documents indexables), 392 Kio, **dans le dépôt** : `git clone && make test` exerce Fouine
sur de vrais documents. Avant lui, tout ce qui touchait un document réel
dépendait du corpus personnel du mainteneur et se sautait *en vert* chez tout le
monde (audit E5, D12/M23).

## La source de vérité est `manifest.json`

Ce README situe ; **`manifest.json` décrit**, et c'est lui que les tests lisent.
Une entrée par fichier :

| Champ | Ce qu'il dit |
|---|---|
| `name`, `ext` | le fichier, tel qu'il est dans ce dossier |
| `kind` | `text` (couche texte native), `scanned` (le texte ne sort que par l'OCR), `trap` (doit échouer proprement), `ignored` (hors registre : ne doit pas entrer dans `docs`) |
| `state` | l'état attendu dans `docs` après extraction — `extracted`, `failed`, `skipped` |
| `pages` | le nombre de pages attendu |
| `note` | pourquoi ce fichier existe |
| `witnesses` | les termes témoins : `term` (ou `query`), les `pages` qui doivent répondre, et la `source` attendue (`native` ou `ocr`) |

Le manifeste décrit le **contenu attendu**, jamais une empreinte : une
régénération produit des fichiers équivalents, pas identiques.

## Régénérer

```sh
make fixtures          # -> Tests/Fixtures/corpus, depuis Tools/make_fixtures.swift
```

Aucune dépendance hors macOS. Pour ajouter une extension du registre
d'extraction, ajoutez-la au générateur **et** au manifeste : sans fixture ni
mention, `CorpusFixturesTests` échoue en nommant l'extension manquante.

## Ce que ce corpus ne contient PAS : les images

Les images seules (`png`, `heic`, `webp`, `gif`, `bmp`, `psd`, RAW…) n'entrent
dans l'index que sous le réglage `extract.images`, que la recette d'intégration
n'allume pas — un fichier image versionné ici ne serait donc jamais indexé, et
le compte du manifeste ne tomberait plus juste. À quoi s'ajoute leur poids :
chacune devrait dépasser 64 Kio pour franchir le plancher d'OCR, de quoi
doubler un corpus qu'on veut menu. Elles sont fabriquées dans un dossier
temporaire par `ImageExtractorTests` et `ImageFormatRenderTests` — y compris le
webp, qu'ImageIO ne sait pas écrire et que les tests écrivent à la main en VP8L
sans perte (lot INT-F2). Le seul fichier image du dossier, `pieges/photo.png`,
est là pour prouver l'INVERSE : hors réglage, le crawler ne doit pas le voir.

**Ni les sons et les vidéos** (lot INT-F3), et pour exactement la même raison :
ils n'entrent que sous `extract.media`, que la recette n'allume pas davantage.
Les trois fixtures médias — `voix.aiff` (une phrase dite par la synthèse vocale
du système), `voix.m4a` et `clip.mp4` (les mêmes, avec titre et artiste) — sont
versionnées **à côté**, dans `Tests/Fixtures/media/`, sans entrée au manifeste,
et se refabriquent par `make fixtures-media`.
