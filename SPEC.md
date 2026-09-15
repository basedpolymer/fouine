# Fouine — spécifications d'implémentation

> **Internal specification, kept in French.** It is the implementation contract
> the AI agents work from, and it is not part of the published documentation.
> The public documentation is in English, under `docs/`.

**Version** 1.1 · **Date** 2026-08-31 · **Cible** macOS 13+ universel (x86_64 + arm64)
**Destinataire** IA d'exécution opérant avec des sous-agents en une session.
**Auteur** Mathis Demory — AGPL-3.0-or-later

> **Amendement du 13/09/2026 (LI1, lot licence)** — La licence du projet n'est
> plus l'AGPL-3.0-or-later mais la **Licence Fouine source-available** 1.0
> (`LICENSE`, identifiant SPDX `LicenseRef-Fouine-Source-Available`). Le code
> reste lisible, compilable et modifiable pour un usage personnel ou pour
> proposer une contribution ; la redistribution — sources modifiées ou non,
> binaires compris — est fermée, parce que l'application se vend en licence
> perpétuelle. **Partout où ce document nomme l'AGPL pour désigner la licence
> de Fouine (§2.2, §9.1, §10.1, §12 amendement MCP), lire cette licence-là** ;
> les licences tierces citées (MIT, Apache-2.0, GPL de PyMuPDF, Ghostscript,
> Surya, OSRA) sont inchangées, et `Sources/FouineMCPKit` reste sous MIT. Ce
> que cela change concrètement pour les dépendances : on ne cherche plus la
> compatibilité copyleft, on cherche des licences permissives — le critère
> retenu au §2.2 y suffisait déjà. Détail : `LICENSING.md`.

## Journal des révisions

**v1.0 → v1.1** — révision après contre-expertise interne. Ce qui change :

- **Le corpus vit sur le SSD interne.** Aucune racine n'est configurée par défaut (décision D1) : les racines s'ajoutent explicitement par `fouine root add` ou via l'application (ex. `~/Documents/Cours`, `~/Livres`) ; `fouine index` sans racine sort en code 5. Le volume externe ExFAT passe **hors périmètre v1** ; le modèle `volumes(UUID)`/`roots` est conservé tel quel et ses pièges spécifiques sont relégués en **annexe A**.
- **OCR : passe unique `.accurate`, `.fast` retiré** (décision D1). Mesuré : rappel de mots-clés **90,5 % contre 19,9 %**. Budget porté de 10–14 h à **~20 h**, assumées.
- **`prefix = '2 3'` supprimé du schéma** (décision D3) : c'est la seule façon de tenir P5 (1,64 Go au lieu de 2,12 Go).
- **Suppression par rowid** dans `page_fts` : `DELETE … WHERE doc_id = ?` est un balayage complet (143 ms sur 600 k lignes contre 3 ms). Rowid structuré `doc_id·10⁵ + page` imposé.
- **Recherche floue : table FTS5 `trigram` en SQL**, alimentée par `fts5vocab`, à la place de l'index trigramme en mémoire. Le critère P9 disparaît, 185 Mo de RSS avec lui ; coût mesuré : 55 Mo de disque à 1 M de termes — **sans `detail='none'`, que la contre-expertise recommandait à tort** (vérifié : il casse le `MATCH` trigramme). Plafond de distance : **d = 0 sous 6 lettres**.
- **Trois dépendances SwiftPM autorisées** : GRDB.swift (MIT), swift-argument-parser (Apache-2.0) et Sparkle (MIT, XCFramework binaire sur l'application seule). Dépôt **GitHub public sous licence AGPL-3.0-or-later**.
- **PDFKit confirmé** (décision D2), avec réouverture du `PDFDocument` toutes les 100 pages et `nil` converti en erreur explicite.
- **TCC devient le piège n°1**, l'AppleDouble ExFAT sort du §7. `~/Documents` est protégé, les dossiers hors TCC ne le sont pas : `fouine doctor` doit tester chaque racine.
- **Durcissements OCR** : préchauffage Vision par processus, filtrage par `confidence`, `customWords` depuis `fts5vocab`, plafond de rendu ~4 Mpx, garde-fou sur `CPU_Speed_Limit` et non sur `thermalState`, OCR des images embarquées `word/media/*` et `ppt/media/*`.
- **Fixtures et tests ré-ancrés** sur le corpus interne : T1, T6, T7, T8, T9, T13, T15 réécrits ; P1 dédoublé, P3 réduit à `.accurate`, P9 supprimé.
- **Plan d'exécution : au plus 2 sous-agents en parallèle**, en quatre vagues successives (§9).
- **Nouveautés** : `fouine root add/list/remove`, `fouine ocr export/import` (annexe B, poste GPU), colonnes moteur/révision/confiance dans `page_src`, recherche hybride avec `page_vec` et `vec_meta` (schéma v3/v4).

---

## 0 · Comment lire ce document

Ce document est le contrat. Ce qui n'y figure pas est hors périmètre : ne l'ajoute pas.

Quatre règles pour la session :

1. **Les interfaces du §4 sont gelées en vague 0** par l'orchestrateur, avant qu'aucun sous-agent ne démarre. Elles ne changent plus. Un agent qui a besoin d'une modification d'interface s'arrête et remonte à l'orchestrateur ; il ne l'édite pas lui-même.
2. **Aucun sous-agent n'écrit dans un fichier qu'il ne possède pas** (carte de propriété au §9.2). C'est la seule protection contre les conflits d'édition en parallèle.
3. **Au plus deux sous-agents tournent en parallèle**, en vagues successives (§9.2). Ce n'est pas une préférence de style : c'est la contrainte d'exécution de la session.
4. **Chaque chiffre est marqué mesuré ou estimé.** Les valeurs marquées *mesuré* l'ont été sur la machine cible et sur le corpus réel, en v1.0 puis re-mesurées en contre-expertise ; ce sont des seuils d'acceptation. Les valeurs marquées *estimé* ou *supposé* n'engagent rien tant qu'elles ne sont pas mesurées, et il est interdit de les transformer en seuil.

Les tranches du §9.1 sont ordonnées pour que la session puisse s'arrêter proprement à la fin de n'importe laquelle. La tranche A seule constitue déjà un outil utilisable. Si le budget se resserre, coupe par la fin, jamais par le milieu.

---

## 1 · Objectif

Construire **Fouine**, un moteur de recherche plein texte pour macOS ciblant un corpus documentaire personnel — les racines s'ajoutent par l'utilisateur via l'application ou la ligne de commande (`fouine root add <chemin>`, par exemple `~/Documents/Cours` ou `~/Livres`) —, avec **OCR automatique et non destructif** des PDF dépourvus de couche texte.

Référence fonctionnelle : FoxTrot Professional Search, déjà installé sur la machine. Fouine ne cherche pas à l'égaler en largeur (300+ formats, sources Mail/Notes/Messages, serveur, compagnon iOS) mais à le dépasser sur trois points précis :

| | FoxTrot Pro 8.6.2 | Fouine v1 |
|---|---|---|
| OCR | manuel, par lot, **réécrit le PDF** | automatique pendant l'indexation, **n'écrit jamais dans le fichier source** |
| Granularité | document | **page** (proximité, navigation, reprise) |
| Surlignage sur page scannée | via la couche texte réécrite | **boîtes Vision** stockées, superposées à l'image |
| Formats | 300+ | 17 formats de base (23 extensions au registre, soit ~98 % du corpus réel mesuré) |

Les ~2 % restants sont assumés et nommés : 22 fichiers `.pages` (ZIP de protobuf Apple `Index/*.iwa`, aucun texte extractible sans parseur dédié — mesuré), 9 `.hsc`, 3 `.mat`, les `.mp4`. Ne pas les compter comme des échecs à la recette ; les marquer `.skipped` avec un `err` explicite.

> **Amendement du 10/09/2026 (PR-12, lot DV1).** Ce paragraphe et la ligne
> « Formats » du tableau décrivent le périmètre de la vague 0. Au 10/09/2026, le
> registre d'extraction compte **114 extensions** (dont les 68 extensions de
> code lues comme du texte), plus **19 images** et **19 formats son et vidéo**
> sous interrupteur, soit **152** en tout. Les `.pages`, `.numbers` et `.key`
> sont lus (lot INT-F2, par l'aperçu que le fichier embarque), les `.mp4`
> aussi (lot INT-F3 : métadonnées, chapitres, et mise par écrit facultative).
> Le chiffre n'est pas à recopier ailleurs : la seule source est
> `Sources/FouineExtract/ExtractorRegistry.swift`, et le compte change à chaque
> format ajouté.

### Non-objectifs v1

Sources applicatives (Mail, Notes, Messages, Contacts, Safari, Calendrier) · partage réseau, mode serveur, multi-utilisateur · compagnon iOS · recherche sémantique / embeddings (voir §12) · indexation du reste du dossier personnel · synchronisation iCloud · OCR d'images isolées hors archives BD et hors médias embarqués OOXML · **indexation d'un volume externe** (le modèle de données la permet, l'ergonomie et la recette de la v1 ne la couvrent pas — voir annexe A) · **OCR mathématique et chimique** (LaTeX/SMILES : 21 à 140 h de CPU supplémentaires *estimés*, formats hors périmètre d'une recherche plein texte : on cherche les mots **autour** de la formule — voir §6.6).

> **Amendement du 10/09/2026 (PR-12, PR-14, lot DV1).** Trois de ces
> non-objectifs sont tombés avant la 1.0.0, et un quatrième doit rester ferme :
>
> - **Sources applicatives** : **Apple Notes** et **Bear** sont livrés (lot
>   INT-F4), en lecture seule stricte, sous une case éteinte au départ ; le
>   texte des notes est recopié en Markdown dans un dossier de Fouine, qui
>   devient une racine ordinaire. Mail, Messages, Contacts, Safari et
>   Calendrier restent hors périmètre.
> - **OCR d'images isolées** : livré (lot INT-F2), sous le réglage
>   `extract.images`, éteint par défaut, avec deux planchers de taille et de
>   poids.
> - **Recherche sémantique** : livrée (§12), modèle téléchargeable.
> - **Notion et Craft ne sont PAS promis, et ne doivent pas l'être** : leurs
>   notes ne sont pas lisibles sur le Mac (cache local chiffré côté Notion, noms
>   de fichiers sans identifiant côté Craft). Le geste offert est l'export
>   Markdown, puis un dossier ordinaire. Aucune page de vente, aucun document
>   public ne les cite à côté d'Apple Notes et de Bear.

---

## 2 · Environnement cible (mesuré)

### 2.1 Machine

```
MacBookPro16,3 · Intel Core i5-8257U @ 1,40 GHz · 4 cœurs physiques / 8 logiques
RAM 8 Gio · swap 2 Gio alloués, ~1 Gio déjà utilisés
macOS 15.7.9 (24G830) · SSD interne APFS, 51 Gio libres (mesuré : df -h /)
```

Conséquences non négociables : **pas de Neural Engine** (Vision tourne sur CPU/GPU), la machine **throttle violemment** — `CPU_Speed_Limit` tombe à **46 % en moins de 90 s** d'OCR à 4 processus (mesuré) —, et la marge RAM est étroite. Toute boucle d'indexation doit plafonner sa concurrence et surveiller `CPU_Speed_Limit`, **pas seulement** `thermalState` : mesuré, ce dernier ne dépasse jamais `.fair` pendant que le CPU est bridé de moitié (§7).

La machine démarre déjà à `thermalState = .fair` au repos : la marge entre l'état de repos et un seuil de pause à `.serious` est d'un cran, et ce cran n'est jamais franchi.

### 2.2 Chaîne d'outils (vérifiée présente)

```
Xcode 26.2 (17C52) · Swift 6.2.3 · xcrun notarytool 1.1.0 · stapler · codesign
SQLite système 3.43.2 — FTS5 OK, unicode61 remove_diacritics 2 OK, NEAR OK, snippet/bm25 OK
bsdtar 3.5.3 / libarchive 3.7.4 — lit ZIP et RAR (donc .cbz ET .cbr)
Identité : "Developer ID Application: <Nom> (<TEAMID>)"  ✅ dans le trousseau
Clé App Store Connect : ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
```

*Amendement 02/09/2026 (audit produit D3/D4) : identité et clé sortent du dépôt, voir `Makefile.local` et `RELEASING.md`.*

`ddjvu` (djvulibre) est **absent** — 5 fichiers `.djvu` concernés, marqués `.skipped` (§5.3).

**Trois dépendances externes, pas une de plus.** Le dépôt est publié sous licence **AGPL-3.0-or-later** ; les dépendances retenues sont rigoureusement permissives (MIT, Apache-2.0) pour respecter la chaîne de distribution et les exigences de licence :

| Dépendance | Version | Licence | Ce qu'elle apporte |
|---|---|---|---|
| **GRDB.swift** | 7.11.x | MIT | pool lecture/écriture, migrations, transactions typées. **Lie le SQLite du système** (`.systemLibrary(name:"GRDBSQLite")`), donc exactement le FTS5 mesuré ci-dessus (vérifié). Ouvre aussi la porte au tokenizer personnalisé du §12. |
| **swift-argument-parser** | 1.8.x | Apache-2.0 (Apple) | CLI complète, options, énumérations contraintes, codes de sortie. `ExpressibleByArgument` valide gratuitement les `enum` du §4.2. |
| **Sparkle** | 2.9.6 | MIT | mises à jour signées EdDSA en DMG hors App Store, sur la cible `FouineApp` seule (XCFramework binaire). |

*Amendement du 02/09/2026 (contrat CLI étendu) : la CLI compte 26 commandes et 33 options au total (voir `docs/cli.md`), couvrant notamment `embed`, `model`, `config` et `search --hybrid`.*

> **Amendement du 13/09/2026 (LI1, lot licence)** — Le dépôt n'est plus publié
> sous AGPL-3.0-or-later mais sous **Licence Fouine source-available** 1.0
> (`LICENSE`). La doctrine des trois dépendances ne bouge pas, mais son motif
> change : il ne s'agit plus d'assurer la compatibilité d'un copyleft, il
> s'agit de ne redistribuer que des composants dont la licence **permissive**
> autorise la distribution dans un produit fermé. MIT et Apache-2.0 le font,
> moyennant la notice que porte `THIRD_PARTY_LICENSES.md` ; les trois retenues
> restent donc les bonnes, et le refus des GPL ci-dessous vaut plus qu'avant.

Tout le reste est refusé : ZIPFoundation (ne remplace pas `bsdtar`, seule voie RAR), SwiftSoup, EPUBKit, CoreXLSX (abandonné en 2023), PyMuPDF et Ghostscript (AGPL), Xapian (GPL-2), Tantivy (casse l'atomicité, §3). L'argument « la session n'a pas de réseau » de la v1.0 **ne s'applique plus** : `swift package resolve` est fait en vague 0 par l'orchestrateur, avant tout travail d'agent.

*Amendement 02/09/2026 (audit produit D13, palier 2.9) : **trois** dépendances. **Sparkle 2.9.6** (MIT) rejoint les deux précédentes, sur la cible `FouineApp` **seule** — ni la CLI, ni l'agent, ni aucune bibliothèque du moteur ne la lient, et `swift test` ne la charge jamais. Motif : le dépôt étant public et distribué en DMG hors App Store, il n'existait aucun moyen de porter un correctif de sécurité — la faille `bsdtar` (S1) en est l'exemple — à une copie déjà installée. Sparkle fonctionne en runtime durci sans bac à sable, exactement notre configuration, et vérifie chaque paquet par signature EdDSA. Elle est **éteinte par défaut** (`SUEnableAutomaticChecks = false`), ce qui préserve la propriété « aucune connexion sortante » tant que l'utilisateur n'a rien demandé : voir `docs/mises-a-jour.md`. Elle est le seul framework dynamique du bundle, d'où `Contents/Frameworks/` et la chaîne de signature du `Makefile`.*

> **Amendement du 13/09/2026 (L1C, lot licence) — la propriété « aucune
> connexion sortante » se précise, elle ne se perd pas.** Fouine se vendant
> 39 € avec un essai de 30 jours, une clé doit pouvoir être posée sur un Mac,
> retirée d'un autre, et cesser de servir si elle a été remboursée. **Deux
> connexions s'ajoutent aux deux existantes**, portées par une cible neuve,
> `FouineLicense` (Foundation seule — **aucune dépendance SPM nouvelle**, la
> doctrine du §2.2 tient) : ① **à la demande**, l'activation et la libération
> d'un Mac (bouton des réglages, `fouine license activate|deactivate`) ;
> ② **silencieuse mais bornée**, une revalidation de la clé au lancement de
> l'application, **au plus une fois tous les 30 jours**, et seulement si une clé
> est posée — hors ligne ou service muet, **rien ne change** et l'on réessaie au
> lancement suivant. Ce qui part, exhaustivement : la clé, et le **nom de
> l'ordinateur** à l'activation (l'étiquette que la personne lira dans son
> espace client pour savoir quel Mac libérer). Rien sur les documents, aucun
> identifiant matériel, aucun compte. **L'agent d'arrière-plan ne sort jamais
> sur le réseau**, licence comprise : il lit le fichier, un point c'est tout, et
> `NetworkSilenceTests` — zéro connexion pendant une passe d'extraction — reste
> vrai mot pour mot. L'appel ne va pas à Creem directement, mais à un **relais**
> (`https://basedpolymer.eu/api/fouine/license`, hébergé chez Vercel) qui porte
> la clé d'API secrète du marchand : un binaire distribué qui la porterait la
> donnerait à tout le monde. Détail : `docs/vie-privee.md`.

> **Amendement du 14/09/2026 (LC2, lot licence) — la vérification suit ce que
> Creem répond vraiment.** Le premier aller-retour réel (bac à sable Creem,
> relais servi en local, 14/09/2026) a montré que la revalidation ne lisait que
> le statut de la CLÉ : un Mac libéré depuis le portail client valide en 200,
> clé `active`, instance `deactivated`, et restait donc sous licence pour
> toujours. ① **L'instance compte** : une activation, puis chaque vérification,
> exigent la clé ET l'instance actives. ② **Un Mac libéré n'est pas révoqué** :
> instance `deactivated`, ou 404 d'instance inconnue à la vérification, rendent
> l'état `released` — la clé est retirée de `license.json`, qui ne garde que
> `trial_started` et `"state": "released"`, et l'essai reprend son cours (la
> mise à jour de l'index s'arrête s'il est fini ; la recherche reste). Une clé
> `disabled` ou `expired` reste `revoked`, clé gardée. ③ **Un troisième moment
> de vérification, à la demande** : `fouine license status` joue la même
> vérification que le lancement de l'application, aux mêmes conditions (clé
> posée, pas vue depuis 30 jours) ; les commandes d'indexation et l'agent ne
> sortent toujours jamais. ④ **`FOUINE_LICENSE_RELAY`** remplace l'adresse du
> relais pour les essais, acceptée seulement en `https://` ou
> `http://127.0.0.1:<port>` : c'est une adresse contactée, avec la clé.
> Détail : `docs/privacy.md`.

### 2.3 Corpus cible

Le corpus de référence du mainteneur est mesuré sur le **SSD interne**, en **lecture seule** (selon le gabarit de `Tests/Fixtures/paths.example.json`) :

```
/Users/<vous>/Livres              19 Go   965 fichiers
/Users/<vous>/Documents/Cours     1,8 Go   552 fichiers
Volume    Macintosh HD · APFS · UUID 75F6E680-A01E-49E2-A130-1800826B45AA
Débit     1,31 Go/s à froid, 5,9 Go/s à chaud (mesuré, dd sur 63 Mo hors cache)
```

Trois points à ne pas rediscuter :

- **L'E/S n'est plus jamais le facteur limitant.** Le plancher d'E/S de 12 min du P7 de la v1.0 (volume USB à 33 Mo/s) tombe à **~15 s** pour les 19 Go de `~/Livres`. Tout ce qui suit est borné par le CPU, et par lui seul.
- **L'UUID se lit par `URLResourceKey.volumeUUIDStringKey`, jamais par `diskutil`.** Mesuré : `diskutil info /` annonce `7D3BD418-…` (l'instantané système scellé) alors que `URL(fileURLWithPath:"/Users/<vous>/Livres").resourceValues(forKeys:[.volumeUUIDStringKey])` rend **`75F6E680-…`**. C'est la seconde valeur qui est la bonne, et c'est celle que `mountedVolumeURLs` rend aussi. Résoudre la racine par **préfixe de chemin le plus long** parmi les volumes montés, en ignorant `/System/Volumes/{Preboot,VM,Update}` (mesuré présents).
- **L'utilisateur ajoute des dossiers** avec `fouine root add <chemin absolu>` (§4.3), qui résout seul le couple `(vol_uuid, rel_path)`. Le modèle `volumes(UUID)` + `roots` est conservé **générique** : il resservira le jour où un disque externe revient (annexe A). Il n'y a plus aucune racine par défaut.

### 2.4 Corpus (inventaire mesuré, 2026-08-31)

| Racine | Fichiers | PDF | Autres indexables | Poids | Racine d'exemple |
|---|---:|---:|---|---:|:--:|
| **`~/Livres`** | 965 | **784** | 20 cbz · 14 cbr · 7 epub · 5 djvu · 1 html · 1 md | 19 Go | oui |
| **`~/Documents/Cours`** | 552 | **419** | 27 xlsx · 27 docx · 13 md · 7 pptx · 2 doc · 1 ppt · 1 csv | 1,8 Go | oui |

Hors périmètre dans ces deux racines : 107 jpg et 4 png de `~/Livres` (images isolées), 10 mp4, 9 hsc, 3 mat, 1 zip, 1 rdp.

`~/Livres` : **395 906 pages** sur 783 PDF dénombrables (un 784ᵉ résiste au comptage), médiane **411 pages**, moyenne 506 (mesuré). `~/Documents/Cours` : PDF petits, médiane ~11 pages pour les scannés.

Deux gisements d'images à OCRiser, mesurés et souvent oubliés :

| Gisement | Volume | Comment |
|---|---:|---|
| Archives BD (`cbz`/`cbr`) | **34 archives, 5 291 images** | `bsdtar` → une image = une page |
| Médias embarqués OOXML (`word/media/*`, `ppt/media/*`, `xl/media/*`) | **61 conteneurs, 722 images** | l'extracteur dézippe déjà ces conteneurs (§5.3) |

### 2.5 Couche texte et charge OCR

Échantillonnage n = 40 par racine, **sonde à mi-document** (pages n/2 à n/2+2), seuil 100 car./page :

| Racine | PDF | couche texte | scannés | pages/doc des scannés |
|---|---:|---:|---:|---:|
| `~/Livres` | 784 | **92 %** | **8 %** | 377 en moyenne (820, 304, 8) |
| `~/Documents/Cours` | 419 | 90 % | 8 % | **9** (12, 11, 4) |

**Avertissement de méthode, non négociable.** Sonder les **pages 1 à 3** donne 38 % de « scannés » au lieu de 8 % (mesuré sur le même échantillon) : couvertures, pages de garde, pages de titre sont des images. Toute sonde de couche texte — extraction, bancs d'essai, recette — échantillonne des pages **réparties dans le document**, jamais le début.

Charge OCR de la v1, par gisement :

| Gisement | Pages | Statut |
|---|---:|---|
| Livres scannés (imprimés, gros volumes) | **32 000 – 44 000** | estimé à partir des 8 % × 395 906 p. et de la moyenne des scannés |
| Archives BD | 5 291 | **mesuré** (comptage d'entrées) |
| Médias embarqués OOXML | 722 | **mesuré** |
| Cours scannés (manuscrits, CamScanner, TD) | ~350 | estimé : 8 % × 419 docs × ~11 p. |
| **Total** | **≈ 38 000 – 50 000 pages** | |

Les scannés de `Cours` sont petits, nombreux et à forte valeur (notes manuscrites, CamScanner, TD annotés) : ils passent en priorité 1 (ou priorité 0 si la racine est épinglée par l'utilisateur). Les scannés de `~/Livres` sont rares mais volumineux (Clayden 1 570 p., Bloomfield 820 p., Baudin 1 053 p.) : priorité 2.

### 2.6 Mesures de référence (seuils d'acceptation)

Toutes prises sur la machine cible, sur des fichiers réels des deux racines, **machine sur secteur et par ailleurs au repos**. Les valeurs de la v1.0 qui ne se reproduisent pas ont été remplacées ; celles qui se reproduisent sont conservées.

| Mesure | Valeur | Comment obtenue |
|---|---|---|
| Extraction `pdftotext`, 1 fil | **105,1 pages/s** à chaud, 94,7 à froid | 25 PDF natifs, 21 133 pages, 45,6 Mo de texte |
| Extraction **PDFKit `PDFPage.string`**, 1 fil | **75,6 pages/s** (×1,39) ; 72,1 avec réouverture /100 p | idem, Swift `-O`. **C'est le moteur retenu** (§5.3) |
| Fidélité PDFKit / `pdftotext` | **97,98 %** des caractères (0,923 au pire) | 43,97 M contre 44,87 M de caractères |
| Extraction, 4 jobs | PDFKit **215 p/s** · `pdftotext` 260 p/s | → 32 min / 27 min pour ~415 000 pages |
| Rendu page PDFKit → CGImage, 150 dpi | **0,094 / 0,140 / 0,209 / 0,290 s** (min/méd./p95/max) | 30 pages de 3 scans ; pages natives 0,012–0,158 s |
| Rendu page `pdftoppm`, 300 dpi | 5,6–21,6 s/page | pour mémoire : **20 à 80× plus lent**, ne pas l'utiliser |
| Vision `.accurate` | **1,104 / 2,980 / 4,869 / 4,937 s** (min/méd./p95/max) | 10 pages, 3 exécutions chacune |
| Vision, **chargement du modèle au 1ᵉʳ appel de chaque processus** | **+3,2 s** (`.fast`) · **+8,5 s** (`.accurate`) | non mentionné en v1.0 ; à 4 jobs, 34 s de démarrage pur |
| Débit OCR `.accurate`, rendu compris | 0,402 p/s à 1 job · **0,699 p/s à 4** (+74 %) · 0,576 à 8 (**régression**) | 24 pages pré-rendues, **sous throttling** |
| Latence requête FTS5 | p95 max **6,4 ms**, médiane 0,05 ms | 20 968 pages, 11 formes de requêtes, SQLite système 3.43.2 |
| Poids de l'index, **sans** `prefix` | **1,903×** le texte brut | 86,7 Mo pour 45,56 Mo |
| Poids de l'index, avec `prefix='2 3'` | 2,466× — **refusé** (§4.1, D3) | +29,6 % de disque, ×2,0 sur l'insertion |
| Texte extractible total | **≈ 0,86 Go** | 395 906 p. × 92 % × 2 156 o/p + OCR à venir + Cours |
| RSS extraction PDFKit **naïf** | **1 515 Mo pour UN fil** sur un livre de 1 315 p. | `PDFDocument` ne libère pas les pages analysées |
| RSS extraction PDFKit, réouverture /100 p | **279 Mo/fil → 1,12 Go à 4 jobs** | texte identique au caractère près, débit inchangé |
| RSS Vision | **344 Mo/processus → 1,38 Go à 4 jobs** | |
| Vocabulaire `fts5vocab` | **145 605 termes distincts** pour 20 968 pages | identique avec et sans `prefix` |
| Table trigramme `vocab_tri` (§4.1) | **8,21 Mo / 0,5 s** à 145 605 termes · **55,5 Mo / 4,2 s** à 1 M | SQLite système ; candidats en 0,73 ms de médiane |
| `CPU_Speed_Limit` sous 4 jobs Vision | **46–61 %** en moins de 90 s, `thermalState` restant `.fair` | `pmset -g therm` toutes les 3 s |

### 2.7 Qualité OCR : pourquoi une seule passe `.accurate`

C'est la mesure qui a fait basculer la v1.1. Deux métriques objectives sur 10 pages réelles — **% de mots réels** (jetons de ≥ 4 lettres présents dans un lexique de 260 572 formes construit sur 45 Mo de texte natif du corpus) et **rappel des mots-clés porteurs** (relevés à l'œil sur l'image d'origine) :

| | Vision `.fast` | Vision `.accurate` |
|---|---:|---:|
| Rappel des mots-clés (agrégat 10 pages) | **19,9 %** | **90,5 %** |
| Mots réels dans la sortie | 28,1 % | 88,8 % |
| Pire cas (Baudin FR, Clayden FR, bulletin FR) | **4 – 11 %** de mots réels | 87 – 93 % |
| Meilleur cas (scan EN 301 ppi) | 65,6 % | 98,1 % |
| Débit à 4 jobs, rendu compris | 3,49 p/s | 0,675 p/s |
| **Coût sur le corpus complet** | ≈ 5 h | **≈ 18–20 h** |

Ce que `.fast` produit sur une page de chimie française imprimée (Baudin p. 200, 2 658 caractères) : `C'II,IVl"I'RI. 2 - É(Jllll.IBkb'.%` pour `CHAPITRE 2 – ÉQUILIBRES CHIMIQUES`. **Zéro mot français, et un compte de caractères supérieur à celui de `.accurate`.**

Trois conséquences, toutes actées :

1. **Le compteur de caractères ne mesure pas la qualité.** Le seuil de 100 caractères de la v1.0, censé rattraper les échecs de `.fast`, n'en rattrapait **qu'un sur sept** (mesuré) — et par accident : la page était pivotée à 90°, ce qui faisait échouer `.fast` complètement. Redressée, la même page rend 233 caractères de bruit, donc au-dessus du seuil, donc acceptés définitivement. Le « détecteur d'écriture manuscrite » de la v1.0 était un détecteur de page pivotée.
2. **Le bruit est pire que le vide** — et le coupable n'était pas Tesseract, mais `.fast`. 44 000 pages ainsi traitées verseraient de l'ordre de **6 millions de faux jetons** dans `fts5vocab`, quand le §5.5.2 en attend 800 000 à 1 000 000 au total. L'expansion floue, dont toute la précision dépend de la propreté du vocabulaire, deviendrait inutilisable.
3. **La résolution ne sauve pas `.fast`.** Sur une source bien numérisée (301 ppi), `.fast` remonte à 89,8 % de mots réels à 300 dpi ; sur une source à 72 ppi effectifs — la majorité des livres français scannés de ce corpus — il **descend** à 2,4 %. Sur-échantillonner n'ajoute pas d'information. Pour `.accurate`, la résolution ne change rien : **rendre à 150 dpi, plafonné à ~4 Mpx** (§6.3), pas plus.

**Décision D1, actée le 2026-08-31 : passe unique `.accurate`. `PageSource.ocrFast` reste dans l'énumération pour la compatibilité du schéma et n'est plus jamais émis.** Surcoût assumé : +14,6 h une fois, en arrière-plan, sur secteur, contre +70,6 points de rappel.

### 2.8 Vision contre Tesseract

Tesseract 5.5.3 est présent sur la machine (`/usr/local/bin`) ; `fra.traineddata` (tessdata_fast, 1,1 Mo) a été installé dans un `TESSDATA_PREFIX` local pour que la comparaison soit honnête. Mesuré sur les mêmes PNG 150 dpi que Vision :

| Page | Tesseract | Vision `.accurate` |
|---|---|---|
| Baudin p. 200 (FR imprimé) | **2,01 s** · 93,8 % de mots réels · 100 % MC | 3,19 s · 93,2 % · 100 % |
| Spitsyn p. 120 (EN imprimé) | **1,15 s** · 98,7 % · 100 % | 1,91 s · 98,1 % · 100 % |
| Bulletin de salaire (FR) | **1,20 s** · 53,1 % · 94 % MC | 3,07 s · 53,4 % · **100 %** |
| TD manuscrit + légende | **0,50 s** · 60,7 % · 100 % MC | 1,10 s · 72,2 % · 100 % |
| CamScanner manuscrit **pivoté 90°** | 0,54 s · 123 car. · **0 %** · **0 %** | 1,59 s · 584 car. · 37 % · **43 %** |

Sur du dactylographié propre les deux moteurs se valent — et **Tesseract est 1,6 à 2,6× plus rapide**. La v1.0 affirmait l'inverse (« 4 à 10× plus lent ») en le comparant à `.fast` ; cette raison est **fausse et retirée**. Deux raisons subsistent, et elles suffisent :

1. **Échec total sur le manuscrit et la page photographiée** — 0 % de rappel là où `.accurate` en obtient 43 %, avec `--psm 1` et l'OSD activés. Or c'est exactement la partie du corpus à plus forte valeur (`Cours`, notes manuscrites, CamScanner). Tesseract n'a pas de modèle d'écriture manuscrite et ne redresse pas une page photographiée.
2. **C'est une dépendance externe dans un bundle signé.** Vision est dans le système : rien à embarquer, binaire universel gratuit. Tesseract impose libtesseract + leptonica + les `traineddata`, soit des dylibs à réécrire (`install_name_tool`), à signer une par une et à faire passer le *hardened runtime* — précisément la plomberie que le §11 cherche à éviter.

**Verdict : non retenu, y compris en secours.** Le besoin légitime qu'il pourrait servir — re-OCRiser un lot avec un autre moteur — est couvert proprement par l'**annexe B** (OCR externe par échange JSONL), sans rien embarquer.

Les alternatives CPU-only ne changent rien à ce verdict : PaddleOCR est **20 à 40× plus lent** sur CPU (*estimé, non mesuré ici*), Tesseract est figé depuis mai 2025, et `RecognizeDocumentsRequest` — la seule vraie nouveauté d'Apple — exige macOS 26, inaccessible sur ce Mac Intel.

---

## 3 · Architecture

```
                      SSD interne (~/Library/Application Support/Fouine/)
                      ┌──────────────────────────────────────────┐
                      │  fouine.db   (SQLite + FTS5, WAL)        │
                      │  fouine.lock (verrou d'écriture)         │
                      └──────────────────────────────────────────┘
                                        ▲
                     ┌──────────────────┼──────────────────┐
                     │                  │                  │
              ┌──────┴──────┐    ┌──────┴──────┐    ┌──────┴──────┐
              │ FouineCrawl │    │FouineExtract│    │  FouineOCR  │
              │  FSEvents   │───▶│23 extensions│───▶│ Vision, une │
              │  delta      │    │             │◀───│ passe .accur│
              └─────────────┘    └─────────────┘    └─────────────┘
                     ▲                  ▲                  ▲
                     └──────────────────┴──────────────────┘
                                        │  FouineCore (Store + Query)
                     ┌──────────────────┼──────────────────┐
              ┌──────┴──────┐    ┌──────┴──────┐    ┌──────┴──────┐
              │ fouine (CLI)│    │ Fouine.app  │    │FouineAgent  │
              │             │    │ SwiftUI+PDFKit│  │SMAppService │
              └─────────────┘    └─────────────┘    └─────────────┘

     Racines indexées : LECTURE SEULE. Fouine n'écrit jamais dans le corpus.
```

**Décisions structurantes, à ne pas rediscuter :**

- **L'unité indexée est la page, pas le document.** Sans cela, la proximité n'a plus de sens sur un livre de 1 570 pages, la navigation vers l'occurrence est impossible, et l'OCR n'est pas reprenable.
- **SQLite FTS5, pas Tantivy.** Le bon argument n'est pas la vitesse (p95 6,4 ms sur 20 968 pages, mesuré — Tantivy ne gagnerait que des millisecondes imperceptibles) : c'est **l'atomicité**. Un moteur d'index séparé rend impossible la règle « une page = une transaction » du §6.3, et donc la reprise propre de l'OCR après une interruption. FTS5 fournit en prime la phrase exacte, `NEAR`, les booléens, les préfixes, BM25, `snippet()`, `highlight()` et l'insensibilité aux accents, tous vérifiés sur le SQLite système 3.43.2.
- **L'index vit sur le SSD interne, la clé est l'UUID du volume**, jamais le chemin de montage. Corollaire mesuré (§2.3) : cet UUID se lit par `URLResourceKey.volumeUUIDStringKey`, pas par `diskutil`.
- **Le corps du texte reste stocké dans FTS5** (mode par défaut, pas `content=''`). Coût mesuré **1,903×** sans index préfixe ; gain : `snippet()` et `highlight()` fonctionnent, la recherche secondaire dans un document est un simple `MATCH` filtré, et — argument décisif pour la suite — **le texte stocké est l'actif qui rendra les embeddings du §12 possibles sans ré-extraction ni ré-OCR**. Estimé : ~1,64 Go pour le corpus complet, sur 51 Gio libres.
- **Le corpus est en lecture seule.** Aucune écriture, aucun fichier temporaire, aucun tag Finder dans `~/Livres` ni `~/Documents/Cours`. Tout ce que Fouine produit vit sous `~/Library` (§10).
- **Une connexion SQLite par fil, ou un acteur.** Le SQLite système est compilé `THREADSAFE=2` (mode *multi-thread*, mesuré via `PRAGMA compile_options`), pas `serialized` : deux fils ne doivent jamais toucher la même `sqlite3*`. GRDB (`DatabasePool`) répond exactement à cette contrainte ; `IndexStore: Sendable` ne doit pas être une façade naïve sur une connexion partagée.

---

## 4 · Interfaces gelées

L'orchestrateur écrit ces trois fichiers en vague 0 et les commit sous le message `freeze: contracts`. Ils sont ensuite en lecture seule pour tous les sous-agents.

### 4.1 Schéma SQLite — `Sources/FouineCore/Schema.swift`

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meta(
  k TEXT PRIMARY KEY,
  v TEXT NOT NULL
);  -- schema_version, fouine_version, created_at

CREATE TABLE IF NOT EXISTS volumes(
  uuid       TEXT PRIMARY KEY,
  label      TEXT NOT NULL,
  last_seen  REAL,
  fsevent_id INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS roots(
  id       INTEGER PRIMARY KEY,
  vol_uuid TEXT NOT NULL REFERENCES volumes(uuid) ON DELETE CASCADE,
  rel_path TEXT NOT NULL,               -- ex. "Users/<vous>/Livres" ; "" = racine du volume
  label    TEXT NOT NULL,               -- étiquette de facette : "Livres", "Cours"
  enabled  INTEGER NOT NULL DEFAULT 1,
  UNIQUE(vol_uuid, rel_path)
);

CREATE TABLE IF NOT EXISTS docs(
  id         INTEGER PRIMARY KEY,
  vol_uuid   TEXT    NOT NULL,
  rel_path   TEXT    NOT NULL,          -- relatif à la racine du VOLUME
  ext        TEXT    NOT NULL,          -- minuscule, sans point
  top_folder TEXT    NOT NULL,          -- = roots.label de la racine, PAS le 1er segment
  size       INTEGER NOT NULL,
  mtime      REAL    NOT NULL,          -- epoch ; APFS : granularité nanoseconde
  n_pages    INTEGER NOT NULL DEFAULT 0,
  state      INTEGER NOT NULL DEFAULT 0,  -- DocState, §4.2
  ocr_state  INTEGER NOT NULL DEFAULT 0,  -- OCRState, §4.2
  lang       TEXT,
  err        TEXT,
  indexed_at REAL,
  UNIQUE(vol_uuid, rel_path)
);
CREATE INDEX IF NOT EXISTS idx_docs_state  ON docs(state, ocr_state);
CREATE INDEX IF NOT EXISTS idx_docs_folder ON docs(top_folder, ext);

-- ATTENTION : le nom "page_fts" est imposé. Ne PAS nommer cette table "pages" :
-- une table FTS nommée "pages" à côté d'une colonne nommée "pages" rend le MATCH
-- ambigu en JOIN (reproduit). NB : docs.n_pages, lui, ne pose aucun problème —
-- le commentaire de la v1.0 se trompait de cause, la conclusion reste la bonne.
--
-- PAS de prefix='2 3' : mesuré, il coûte +29,6 % d'index (2,466x contre 1,903x)
-- et x2,0 sur l'insertion, pour n'accélérer QUE les préfixes de 2-3 lettres,
-- qui ramènent 17 000 pages sur 21 000 et n'ont aucune valeur (décision D3).
-- Contrepartie imposée à l'analyse de requête : refuser les préfixes < 4 car.
CREATE VIRTUAL TABLE IF NOT EXISTS page_fts USING fts5(
  body,
  doc_id UNINDEXED,
  page   UNINDEXED,
  tokenize = 'unicode61 remove_diacritics 2'
);

-- ROWID STRUCTURÉ, IMPOSÉ : rowid = doc_id * 100000 + page  (page 1-indexée).
-- Toute insertion dans page_fts fixe explicitement le rowid.
-- Toute suppression se fait PAR ROWID ou par PLAGE de rowid, JAMAIS par doc_id :
--   effacer un document  : DELETE FROM page_fts
--                          WHERE rowid BETWEEN :doc*100000 AND :doc*100000+99999;
--   effacer une page     : DELETE FROM page_fts WHERE rowid = :doc*100000 + :page;
-- Mesuré : DELETE ... WHERE doc_id = ? est un SCAN complet (doc_id est UNINDEXED) :
-- 143 ms sur 600 000 lignes contre 3 ms par rowid. Sur la file OCR, où le §6.3
-- impose une transaction par page, la version naïve coûterait ~2 h de balayage pur.
-- Limite assumée : 99 999 pages par document (maximum du corpus : 1 570).

CREATE TABLE IF NOT EXISTS page_src(
  doc_id    INTEGER NOT NULL,
  page      INTEGER NOT NULL,
  src       INTEGER NOT NULL,   -- PageSource : 0 natif, 1 ocr_fast (mort), 2 ocr_accurate
  nchars    INTEGER NOT NULL,
  engine    INTEGER NOT NULL DEFAULT 0,  -- OCREngineID : 0 aucun/natif, 1 Vision, 2 externe (annexe B)
  engine_rev TEXT,                       -- ex. "vision-rev3", "paddleocr-2.9"
  conf      REAL,                        -- confiance moyenne des lignes retenues, 0..1
  PRIMARY KEY(doc_id, page)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS idx_page_src_conf ON page_src(src, conf);
-- L'index ci-dessus est ce qui rend possible « re-OCRiser les pages douteuses »
-- en une requête (annexe B) : SELECT ... FROM page_src WHERE src != 0 AND conf < 0.5.

CREATE TABLE IF NOT EXISTS ocr_queue(
  doc_id   INTEGER NOT NULL,
  page     INTEGER NOT NULL,
  prio     INTEGER NOT NULL,          -- 0 = le plus urgent
  attempts INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(doc_id, page)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS idx_ocr_prio ON ocr_queue(prio, attempts, doc_id, page);

-- Boîtes des lignes reconnues, pour surligner sur une page scannée.
-- Un enregistrement par page : JSON compressé zlib, [{t,x,y,w,h,c}, …]
-- Coordonnées normalisées 0..1, origine en bas à gauche (convention Vision).
--
-- AMENDEMENT du 01/09/2026 (audit A4) : ROWID STRUCTURÉ, et surtout PAS
-- `WITHOUT ROWID`. Une table `WITHOUT ROWID` est un B-tree d'index, dont le
-- seuil de stockage local vaut 1 002 o contre 4 061 o pour une table à rowid :
-- avec un blob moyen de 2 458 o (mesuré), CHAQUE ligne débordait sur une page
-- de 4 Kio dont elle n'occupait qu'un tiers (38,3 % perdus, ~80 MiB à 46 035
-- pages). Le schéma est créé sous cette forme (amendement J1 du 03/09/2026 :
-- plus de migrations).
-- Les flottants sont par ailleurs arrondis à 4 décimales À L'ÉCRITURE
-- (−40,4 % sur le blob, décodeur inchangé).
CREATE TABLE IF NOT EXISTS ocr_layout(
  rowid INTEGER PRIMARY KEY,            -- doc_id * 100000 + page
  blob  BLOB    NOT NULL
);

-- Vocabulaire trigramme, pour l'expansion floue (§5.5.2). Vérifié sur SQLite 3.43.2 :
--   MATCH 'plica'  ->  applicabian, application
-- N'indexer QUE le vocabulaire (fts5vocab), JAMAIS le corpus : c'est ce qui garde
-- le coût borné. MESURÉ sur la machine : 145 605 termes réels -> 8,21 Mo, construit
-- en 0,5 s ; 1 000 000 de termes -> 55,5 Mo, construit en 4,2 s.
--
-- NE PAS mettre detail='none' NI detail='column' (la contre-expertise recommandait
-- 'none' : c'est une ERREUR, corrigée ici après vérification sur la machine).
-- Le tokenizer trigram traduit MATCH 'plica' en une requête de PHRASE sur les
-- trigrammes 'pli','lic','ica' — qui exige les positions. Mesuré :
--   detail='none'   -> Error: fts5: phrase queries are not supported (detail!=full)
--   detail='column' -> même erreur
-- detail par défaut (full) est donc OBLIGATOIRE, et c'est ce qui coûte les 55 Mo.
--
-- ATTENTION : 'trigram remove_diacritics 1' n'existe qu'à partir de SQLite 3.45 et
-- ÉCHOUE ici (error in tokenizer constructor). Sans conséquence : les termes viennent
-- d'une table déjà en remove_diacritics 2, donc déjà désaccentués.
CREATE VIRTUAL TABLE IF NOT EXISTS vocab_tri USING fts5(
  term,
  tokenize = 'trigram'
);

-- Alimentation, idempotente, dans la même transaction que l'écriture d'index :
--   CREATE VIRTUAL TABLE IF NOT EXISTS vocab USING fts5vocab(page_fts, 'row');
--   INSERT INTO vocab_tri(term)
--     SELECT term FROM vocab
--     WHERE term NOT IN (SELECT term FROM vocab_tri);
-- (en pratique : tenir une table ordinaire vocab_seen(term PRIMARY KEY) WITHOUT ROWID pour que
--  le NOT IN soit un index B-tree et non un balayage de la table trigramme.)
```

**Schéma v5 effectif (`Schema.swift`) :**
Le schéma de production intègre les tables vectorielles créées pour la recherche hybride (v3, fenêtrées en v5) et les tables de configuration et d'état partagés (v4) :
- `page_vec(rowid INTEGER PRIMARY KEY, vec BLOB NOT NULL)` : vecteurs sémantiques par page en **rowid structuré** (`doc_id * 100000 + page`, clé primaire entière sans index secondaire). Le vecteur est unitaire quantifié int8 (384 o/page, ~146 Mo à terme sur le corpus complet ; pression sur P5 mesurée lors de la contre-expertise interne). Invalidation : toute réécriture du texte d'une page (`replacePages`, `completeOCR`, purge) supprime son vecteur ; `fouine embed` réencode incrémentalement.

  > **Amendement du 03/09/2026 — le rowid de `page_vec` identifie une FENÊTRE, pas une page (schéma v5, constat C2-05).** Mesuré sur la base de production : la page moyenne fait **2 282 caractères**, **77,3 %** des pages dépassent les 1 400 caractères que le modèle voit (`EmbedRun.maxChars`, `seq = 256`), et le vecteur d'une page ne couvrait donc que **56,2 %** de son texte. Le rowid structuré est prolongé d'un chiffre de fenêtre : `vrowid = (doc_id * 100000 + page) * 8 + chunk`, `chunk ∈ [0, 7]` (`Schema.vecChunksPerPage`). La fenêtre `k` couvre les caractères `[k*1300, k*1300 + 1400)`, au plus **trois** par page (`win_chars`, `win_stride`, `win_max`, posés dans `vec_meta` par la migration) : la couverture du texte passe à **97,4 %** pour 2,13 inférences par page. La fenêtre 0 est **exactement** le `prefix(1400)` du schéma v3, donc la migration `v5-page-vec-windows` se contente de multiplier les rowids par 8 et de recopier les blobs — les 64 872 vecteurs de la production sont repris sans une seule ré-inférence (mesuré sur une copie : 0,59 s en SQL nu, 1,7 s par l'ouverture du produit, `integrity_check` = ok ; prévoir **2 × la taille de `page_vec`** en espace libre, la table vit en double le temps de la transaction).
  >
  > Trois conséquences de conception, toutes vérifiées par la mesure : ① l'invalidation reste une suppression **par plage** (`Schema.vecRowIDRange`), jamais par `doc_id` ; ② une page est dite **complète** quand son dernier créneau (`win_max - 1`) existe — la pompe l'écrit toujours, avec le vrai vecteur si la fenêtre existe et un **blob vide** sinon (sentinelle, ~4 Mio à 390 000 pages, ignorée au chargement comme tout blob de dimension inattendue) —, ce qui laisse la sélection de lot dans le plan qu'elle avait au schéma v3 : `SCAN f VIRTUAL TABLE INDEX 64:>` + `SEARCH v USING INTEGER PRIMARY KEY (rowid=?) LEFT-JOIN` ; ③ `VectorIndex.topK` **replie ses hits par page** (max-pooling : le meilleur cosinus des fenêtres d'une page) et rend des rowids de page, de sorte que `HybridSearch`, le RRF et `pagePreviews` sont inchangés. Toujours **aucun index secondaire** sur `page_vec` : compter les pages y est un balayage avec modulo, mesuré à 16 ms sur 64 872 lignes et projeté à ~0,2 s sur un corpus entièrement vectorisé, sur des chemins (`status`, `embed --status`) qui ne sont jamais dans une recherche.
  > **Amendement du 04/09/2026 (A1m-05, lot K1) — un rowid de `page_vec` qui n'a pas cette forme est une PANNE, et elle se voit.** Le rowid structuré n'est pas seulement une commodité : c'est la seule chose qui rattache un vecteur à sa page. Une ligne écrite par un binaire d'un autre schéma (rowid v3 `doc_id * 100000 + page`, laissé le 03/09/2026 sur la base de production) se replie quand même — sur la page `rowid / 8` —, et quand cette page existe, le canal sémantique rend un chemin, un numéro de page et un extrait crédibles pour **une page sans rapport avec la requête**. Trois invariants sont désormais VÉRIFIABLES et RÉPARABLES : ① créneau `< win_max` (`foreign_slot`) ; ② `rowid / 8` présent dans `page_fts_docsize` (`orphan_page`) ; ③ sentinelle de complétude posée ⟹ fenêtre 0 présente (`broken_sentinel`) — sans quoi la page se dit finie et la pompe ne la reprendrait jamais. `fouine doctor --deep` les compte et les NOMME (rowids d'exemple) ; `fouine maintain --repair` les retire, sous le verrou nommé et en une transaction, dans cet ordre — les populations sont rendues disjointes par cet ordre, pour que le compte annoncé et le compte retiré soient le même nombre. Une page dont la sentinelle disparaît redevient « à vectoriser » sans autre écriture : `pagesNeedingVector` la resélectionne. Mesuré sur la base de production du 04/09/2026 : 83 837 lignes, 11 051 incohérentes (7 283 + 3 768 + 0), contrôle en 0,6 s, réparation en 1,2 s. Restent les lignes de l'ancienne formule qui tombent par hasard sur un créneau `< 3` d'une page réelle — **indiscernables ligne à ligne** (615 lignes sur 206 pages) : elles se traitent en jetant toutes les fenêtres des pages concernées, jamais en devinant.
- `vec_meta(k TEXT PRIMARY KEY, v TEXT NOT NULL) WITHOUT ROWID` : identité du modèle d'embedding (`model_id`, dimension, révision) et, depuis le schéma v5, géométrie du fenêtrage (`win_chars`, `win_stride`, `win_max`) — de quoi retrouver en SQL ce que couvre un rowid. Changer de modèle invalide l'ensemble des vecteurs de `page_vec` ; la géométrie, elle, est posée par la migration.
- `settings(key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL)` : réglages textuels partagés par l'application, la CLI et l'agent `launchd` (qui ne partage pas le domaine `UserDefaults` de l'application).
- `agent_status(key TEXT PRIMARY KEY, value TEXT NOT NULL)` : état de progression de l'agent d'arrière-plan, lisible atomiquement par l'application et les commandes de diagnostic (`phase`, `detail`, `done`, `total`, `pid`...).
- `vocab_seen(term TEXT PRIMARY KEY) WITHOUT ROWID` : termes déjà versés dans `vocab_tri` pour accélérer l'alimentation incrémentale.

Une requête de recherche s'écrit **toujours** ainsi — sous-requête sur `page_fts`, puis jointure. Toute autre forme déclenche `ambiguous column name` :

```sql
SELECT d.id, d.rel_path, d.top_folder, x.page, x.snip, x.score
FROM (
  SELECT doc_id, page,
         snippet(page_fts, 0, '«', '»', '…', 12) AS snip,
         bm25(page_fts) AS score
  FROM page_fts
  WHERE page_fts MATCH :q
  ORDER BY score
  LIMIT :limit OFFSET :offset
) AS x
JOIN docs d ON d.id = x.doc_id;
```

> **Amendement du 04/09/2026 (A3-02, lot K6) — schéma v6, `docs.inode`.**
> `docs` gagne une colonne `inode INTEGER NOT NULL DEFAULT 0` (`st_ino` du
> volume), indexée par `CREATE INDEX idx_docs_inode ON docs(vol_uuid, inode)` —
> un index, jamais une contrainte : deux liens durs partagent un inode. `0`
> signifie « inconnu » : ligne écrite avant la v6, ou système de fichiers qui ne
> garantit pas la stabilité de l'inode (FAT, SMB, annexe A n° 3). **La clé
> logique du document reste `(vol_uuid, rel_path)`** ; l'inode ne sert qu'à
> reconnaître un fichier DÉPLACÉ (§5.2).
>
> La conséquence sur l'ouverture : **une chaîne de migrations existe de
> nouveau**, bornée par le bas à `Schema.oldestMigratableVersion = 5`. Le lot J1
> l'avait supprimée faute de base v1-v4 réelle ; une base v5 réelle existe, elle,
> et porte des dizaines d'heures d'OCR. Une base ≥ 5 et < la version courante est
> migrée par le premier écrivain qui l'ouvre, sous le verrou nommé, en une
> transaction, `meta.schema_version` écrit en dernier. Une base < 5 reste
> refusée. Une lecture seule ne migre pas : elle nomme le geste
> (`GRDBStore.schemaUpgradeNeeded`) et ne conseille **jamais** de détruire
> l'index.

> **Amendement du 04/09/2026 (A3-10, lot K6) — schéma v7, chemins en NFC.**
> `docs.rel_path` et `roots.rel_path` sont stockés en forme Unicode **NFC**
> (`RelPath.normalized`, `precomposedStringWithCanonicalMapping`), et tout chemin
> reçu de l'extérieur y est ramené avant d'être comparé. SQLite compare des
> OCTETS : un « é » décomposé (U+0065 U+0301), que l'énumérateur de FileManager
> rend historiquement, ne retrouve jamais un « é » précomposé (U+00E9) — ni par
> `rel_path = :path`, ni par le `substr()` du filtre de racine, dont la longueur
> en points de code change aussi. `String` de Swift, lui, tient les deux formes
> pour ÉGALES (équivalence canonique) : un test de non-normalisation DOIT
> comparer les octets.
>
> Migration de données `v7-relpath-nfc` (aucun changement de forme). Deux lignes
> qui ne diffèrent que par la forme du même chemin désignent le même fichier : la
> plus récemment indexée (`indexed_at`, puis l'identifiant le plus grand) est
> gardée, l'autre est purgée COMPLÈTEMENT — `purgeDoc`, donc pages, couche OCR,
> file et vecteurs —, et le bilan est écrit dans `meta.migration_v7_nfc`
> (`rewritten=… purged_duplicates=…`).

> **Amendement du 05/09/2026 (R-02, D-R3, lot M1) — schéma v8, `docs_fts`.**
> Le NOM d'un document ne participait à aucune recherche : « Thermodynamique.pdf »
> ne devait rien à son titre, et un dossier « M2SU » n'aidait pas davantage. Une
> table de plus, une ligne par document :
>
> ```sql
> CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts USING fts5(
>   name,
>   tokenize = 'unicode61 remove_diacritics 2'   -- celui de page_fts
> );
> -- rowid = docs.id ; name = <dernier composant de rel_path sans extension>
> --                          + ' ' + <nom du dossier parent>
> ```
>
> **Surtout PAS une colonne `name` dans `page_fts`** (mesuré le 01/09/2026) : le
> nom serait recopié sur les 378 000 pages de l'index, il faudrait réindexer
> 1,4 Go, et il diluerait l'IDF de `bm25` jusqu'à rendre un mot du titre sans
> poids. Ici, quelques milliers de lignes, et une sonde `docs_fts MATCH` qui rend
> un petit ensemble de `doc_id` en microsecondes.
>
> Tenue à jour dans la MÊME transaction que `docs` — `upsertDoc` (insertion et
> réécriture), `relocateDocs` (un déplacement change le nom ET le dossier),
> `purgeDoc`. Migration `v8-docs-fts` : création puis remplissage depuis `docs`
> (1 499 lignes sur la base réelle, instantané), bilan dans
> `meta.migration_v8_docs_fts` (`indexed=…`). `maintain --repair` la reconstruit,
> `doctor --deep` publie `doc_names` (`docs`, `names`, `consistent`) — un écart
> prive des documents de leur bonus de classement, il ne fausse aucun résultat :
> il est signalé, il n'est pas une panne.

> **Amendement du 11/09/2026 (PR-07, lot DD1) — schéma v9, `docs.doc_date`.**
> La seule date que Fouine connaissait était celle du FICHIER (`docs.mtime`) :
> sur le fonds réel, la facette « Modifié en » ne rendait que cinq valeurs,
> toutes postérieures à 2021, pour 1 527 documents dont la plupart sont des
> ouvrages d'avant 2020. `docs` gagne donc une colonne :
>
> ```sql
> ALTER TABLE docs ADD COLUMN doc_date REAL;        -- migration v9-doc-date
> CREATE INDEX IF NOT EXISTS idx_docs_doc_date ON docs(doc_date);
> -- jour civil À MIDI UTC, NULL quand le document ne porte pas de date
> ```
>
> **Un JOUR, pas un instant.** Une date de document n'a ni heure ni fuseau :
> `strftime('%Y', doc_date, 'unixepoch')` — sans `'localtime'`, contrairement à
> la facette des `mtime` — rend donc la même année partout dans le monde.
> `DocumentDate` (pur) analyse les cinq écritures que les formats emploient
> (ISO 8601, PDF `D:…`, RFC 5322, EXIF), REFUSE ce qui est ambigu
> (« 12/04/2003 »), ce qui vaut le 1ᵉʳ janvier 1900 ou avant — la valeur de
> remplissage des producteurs de PDF — et ce qui suit demain.
>
> **Écrite à l'extraction, jamais devinée.** Chaque extracteur dépose la chaîne
> brute dans `ExtractionResult.meta["date"]` (PDF `CreationDate` — jamais la
> date de modification, qui serait `mtime` sous un autre nom ; EPUB premier
> `<dc:date>` ; OOXML `dcterms:created` ; ODF `meta:creation-date` ; EXIF
> `DateTimeOriginal` ; en-tête `Date:` d'un courriel), et `IndexPass` l'analyse
> au moment où il tient déjà le fichier ouvert. La date écrite dans le NOM du
> fichier n'est PAS lue : ce n'est pas une métadonnée.
>
> **La migration ne remplit rien** — elle ajoute la colonne et son index, sans
> rouvrir un seul fichier. Le rattrapage d'un fonds déjà indexé est un geste
> explicite, `fouine maintain --backfill-dates`, qui lit la SEULE métadonnée de
> date par `MetadataReader` : mesuré le 11/09/2026 sur une copie de la base de
> production, 1 299 documents datés sur 1 516 en 58,6 s, 0 injoignable.

> **Amendement du 13/09/2026 (RC1) — plus de chaîne de migrations.** Fouine n'a
> jamais été distribué : la seule base réelle est au schéma courant, et un
> chemin de reprise qu'aucune base réelle n'éprouve est un risque sans
> contrepartie. `Schema.version` est désormais la SEULE version que le binaire
> ouvre, et celle qu'il inscrit à la création. Une base d'une autre version est
> refusée sans être touchée, avec son geste : plus ancienne, « refaire l'index »
> (*delete it and index again*) ; plus récente, « mettre Fouine à jour »
> (*update the fouine binary*). `GRDBStore.schemaMismatch` porte ces deux
> phrases pour le cœur, la CLI, le serveur MCP et l'application ; l'ouverture en
> lecture seule refuse avec exactement la même. Conséquence assumée : changer
> `Schema.version` oblige l'utilisateur à refaire son index — cela se décide.
>
> Trois mécanismes disparaissent avec la chaîne : `Schema.oldestMigratableVersion`
> et `GRDBStore+Migrations` ; l'option `fouine maintain --backfill-dates` de
> l'amendement PR-07 ci-dessus (la colonne `docs.doc_date` reste au schéma et
> s'écrit **à l'extraction**, seul moment où le fichier est ouvert) ; et la
> reconnaissance de l'ANCIEN identifiant de bundle par la sonde des copies de
> l'application — une `Fouine.app` d'un autre identifiant posée dans
> `/Applications` n'est plus nommée « an older Fouine », elle est simplement
> absente pour LaunchServices, et `doctor --json` continue de publier ce qu'il
> lit sur le disque dans `app_at_expected_path`.

> **Amendement du 13/09/2026 (RC2) — `page_src.src` ne connaît plus la valeur 1.**
> La reconnaissance « rapide » (`PageSource.ocrFast`, `src = 1`) n'est plus
> jamais écrite depuis la décision D1 (§2.7), et la base réelle n'en porte
> aucune (lecture seule, 13/09/2026 : 391 850 pages `src = 0`, 46 649 `src = 2`,
> 11 `src = 3`, zéro `src = 1`). Le cas quitte l'énumération : `PageSource` =
> `native = 0`, `ocrAccurate = 2`, `transcript = 3` (les valeurs stockées ne
> bougent pas, 1 ne se réattribue pas), `PageSource.scanned = [ocrAccurate]`.
> Avec lui disparaissent le libellé `ocr_fast` (JSON de `search` et
> `fouine_read_page`, facette « source », sortie texte de `status`), la clé
> `pages_ocr_fast` de `status --json` (§4.3) et le libellé « scanned (older
> recognition) » de l'application. `OCRLevel.fast` reste : il sert aux bancs
> comparatifs du moteur, pas à une base. Même règle pour le canal des noms de
> documents : `docs_fts` naît avec le schéma, la recherche ne teste plus son
> existence. Côté application, le reste de RC1 suit : le refus
> `foreignCopyInApplications` et l'alerte « An older version of Fouine is
> installed » disparaissent, faute de pouvoir se produire.

### 4.2 Protocoles Swift — `Sources/FouineCore/Contracts.swift`

```swift
import Foundation
import CoreGraphics

public enum PageSource: Int, Sendable, Codable {
    case native = 0
    /// DÉPRÉCIÉ (décision D1, §2.7). La valeur reste dans l'énumération pour la
    /// compatibilité du schéma et la lecture d'anciennes bases ; elle n'est PLUS
    /// JAMAIS écrite. Tout code qui l'émet est un bug de livraison.
    case ocrFast = 1
    case ocrAccurate = 2
}

/// Quel moteur a produit la page (colonne page_src.engine).
public enum OCREngineID: Int, Sendable, Codable {
    case none = 0        // texte natif
    case vision = 1      // Vision, en cours de session
    case external = 2    // importé par `fouine ocr import` (annexe B)
}

public enum DocState: Int, Sendable {
    case discovered = 0   // vu par le crawler, pas encore extrait
    case extracted  = 1   // texte natif indexé
    case failed     = 2   // erreur d'extraction, voir docs.err
    case skipped    = 3   // trop gros, format non pris en charge
}

public enum OCRState: Int, Sendable {
    case notNeeded = 0    // couche texte suffisante partout
    case queued    = 1    // au moins une page en file
    case partial   = 2    // OCR commencé, pas fini (reprise possible)
    case done      = 3
    case failed    = 4
}

public struct PageText: Sendable {
    public let page: Int          // 1-indexé
    public let text: String
    public let source: PageSource
    public init(page: Int, text: String, source: PageSource)
}

public struct ExtractionResult: Sendable {
    public let pages: [PageText]      // uniquement les pages porteuses de texte
    public let pageCount: Int         // total du document (≥ pages.count)
    public let ocrCandidates: [Int]   // n° des pages sous le seuil, à mettre en file
    public let meta: [String: String] // title, author, lang… si disponibles
    public init(pages: [PageText], pageCount: Int,
                ocrCandidates: [Int], meta: [String: String])
}

public protocol TextExtractor: Sendable {
    /// Extensions en minuscules, sans point.
    static var supportedExtensions: Set<String> { get }
    /// Doit être sans effet de bord sur le fichier source.
    func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult
}

public struct ExtractLimits: Sendable {
    public var maxFileBytes: Int   = 2 << 30    // 2 Gio : au-delà -> .skipped
    public var maxTextBytes: Int   = 50 << 20   // 50 Mio de texte par document
    public var pageSplitChars: Int = 4_000      // pagination des formats non paginés
    public var ocrThresholdChars: Int = 100     // §6.1
    public init()
}

public protocol PageRenderer: Sendable {
    /// dpi effectif ; la spec impose 150. Niveaux de gris.
    func render(url: URL, page: Int, dpi: Double) throws -> CGImage
}

/// `.fast` n'est plus jamais demandé par le pipeline (D1) ; le cas reste pour les
/// bancs d'essai comparatifs de A-Recette.
public enum OCRLevel: Sendable { case fast, accurate }

public struct OCRLine: Sendable, Codable {
    public let text: String
    public let x: Double, y: Double, w: Double, h: Double  // normalisé 0..1
    public let confidence: Double                          // 0..1, Vision
}

public struct OCRPage: Sendable {
    public let text: String          // lignes retenues uniquement (§6.2, seuil de confiance)
    public let lines: [OCRLine]      // TOUTES les lignes, y compris rejetées, pour ocr_layout
    public let level: OCRLevel
    public let seconds: Double
    public let engine: OCREngineID   // -> page_src.engine
    public let engineRev: String     // -> page_src.engine_rev, ex. "vision-rev3"
    public let meanConfidence: Double // -> page_src.conf, moyenne des lignes retenues
}

public protocol OCREngine: Sendable {
    /// Identification du moteur, recopiée dans page_src. Sans elle, une
    /// ré-OCRisation sélective (annexe B) est impossible.
    var id: OCREngineID { get }
    var revision: String { get }
    /// Doit être appelé une fois par processus avant le premier lot : mesuré,
    /// Vision charge son modèle en 8,5 s au premier `.accurate` (§6.3).
    func prewarm() throws
    func recognize(_ image: CGImage,
                   level: OCRLevel,
                   languages: [String],
                   customWords: [String]) throws -> OCRPage
}

public struct DocRecord: Sendable {
    public var volUUID: String, relPath: String, ext: String, topFolder: String
    public var size: Int64, mtime: Double, nPages: Int
    public var state: DocState, ocrState: OCRState
    public var lang: String?, err: String?
}

public enum FuzzyMode: String, Sendable { case off, auto, on }
public enum FuzzyScope: String, Sendable { case ocrOnly, all }

public struct SearchQuery: Sendable {
    public var terms: [String] = []        // termes bruts saisis, pour l'expansion
    public var fts: String                 // syntaxe FTS5 déjà normalisée (§5.5)
    public var limit: Int = 50, offset: Int = 0
    public var folders: [String] = []      // filtre top_folder ; vide = tout
    public var exts: [String] = []
    /// Recherche secondaire, restreinte à ces documents ; vide = tout l'index.
    /// PLURIEL délibéré (emprunt à FoxTrot, « rechercher dans les résultats ») :
    /// c'est un geste central d'une recherche documentaire, et l'interface est
    /// gelée en vague 0 — le corriger ensuite coûterait une reprise de contrat.
    public var inDocIDs: [Int64] = []
    public var groupByDoc: Bool = true
    public var fuzzy: FuzzyMode = .auto    // §5.5.2
    public var fuzzyScope: FuzzyScope = .ocrOnly
}

/// Expansion floue d'un terme sur le vocabulaire de l'index (§5.5.2).
/// Le protocole ne change PAS avec le passage à la table FTS5 `vocab_tri` :
/// seule la structure de données sous-jacente change.
public protocol FuzzyExpander: AnyObject, Sendable {
    /// Insère dans vocab_tri les termes de fts5vocab qui n'y sont pas encore.
    /// Idempotent, incrémental, dans la transaction d'écriture de l'index.
    func warm() throws
    /// Voisins triés par distance croissante, terme exact inclus en tête.
    func expand(_ term: String, cap: Int) throws -> [(distance: Int, term: String)]
}

public struct Hit: Sendable {
    public let docID: Int64, path: String, page: Int
    public let score: Double, snippet: String, source: PageSource
    public let fuzzyDistance: Int   // 0 = correspondance exacte
}

public struct SearchResults: Sendable {
    public let hits: [Hit]
    public let totalPages: Int, totalDocs: Int, elapsedMS: Double
}

public enum FacetKey: String, Sendable { case folder, ext, year, source }

> **Amendement du 11/09/2026 (PR-07, lot DD1) — une sixième facette,
> `doc_year`.** `FacetKey` gagne `docYear` (valeur `doc_year` en ligne de
> commande et en JSON), d'expression `coalesce(strftime('%Y', d.doc_date,
> 'unixepoch'), '')` — SANS `'localtime'`, contrairement à `year`, pour la
> raison donnée au §4.1. Elle compte l'année que le document PORTE, là où
> `year` compte celle de son fichier ; les documents sans date sortent sous la
> clé vide, que l'interface écarte comme les valeurs vides des autres facettes.
> `SearchQuery` ne bouge pas : il n'y a pas de filtre `doc_year` dans ce lot.
> Mesuré le 11/09/2026 sur la base de production (`energie`, 29 038 pages,
> médiane de trois passes) : 5 valeurs pour `year` contre 31 pour `doc_year`
> (1915 à 2026), pour le même coût — 246 ms contre 245 ms.

> **Amendement du 05/09/2026 (R-07, R-10, lot U2) — deux filtres de document de
> plus, et une cinquième facette.** `SearchQuery` gagne `langs: [String] = []`
> (codes ISO 639-1 de `docs.lang`, tel que `LanguageDetector` l'écrit ; le jeton
> `FacetKey.undeterminedLanguage`, « und », désigne les documents sans langue
> déterminée — `docs.lang` NULL ou vide) et `modifiedAfter: Double? = nil`
> (borne INFÉRIEURE INCLUSIVE sur `docs.mtime`, en secondes UNIX). `FacetKey`
> gagne `lang`, d'expression `coalesce(d.lang, '')`. Les deux filtres sont de
> VRAIES requêtes : ils s'écrivent dans la sous-requête `SELECT id FROM docs
> WHERE …` de `docFilter`, au même endroit que `top_folder` et `ext`, et les
> totaux annoncés les suivent — contrairement aux facettes `year` et `source`,
> qui filtrent le seul jeu chargé. Ajouts à valeur par défaut : aucun appelant
> existant ne change.
>
> Le canal VECTORIEL du chemin hybride ne lit pas ce SQL : il ne connaît des
> filtres que l'ensemble de documents qu'on lui autorise. `GRDBStore.docIDsMatching(langs:modifiedAfter:)`
> le lui donne, intersecté dans `HybridSearch` avec `docIDsMatchingFilters`.
> Vérifié le 05/09/2026 sur la base de production (1 499 documents, 404 103
> pages) : `search 'logement etudiant' --hybrid` rend 6 pages dont 3 par le seul
> sens, toutes issues de documents sans langue détectée ; avec `--lang fr`, il
> n'en rend plus que 2, toutes françaises. Sans cette intersection, le filtre
> aurait promis le français et rendu autre chose.
>
> Surcoût mesuré sur la même base, binaire de débogage, trois passes :
> `chimie` (2 994 pages appariées) 23,9-26,7 ms sans filtre, 25,1-28,7 ms avec
> `--since`, 26,1-27,8 ms avec `--lang` — dans le bruit.

> **Amendement du 05/09/2026 (PERSP-5, lot P3) — un filtre par PAGE :
> `SearchQuery.sources`.** `SearchQuery` gagne `sources: Set<PageSource>? = nil`
> — `nil`, l'ensemble vide ou les trois valeurs signifient « toutes ». C'est le
> PREMIER filtre qui ne porte pas sur le document : la provenance vit dans
> `page_src`, une ligne par page, et un même ouvrage mêle des pages tapées et
> des planches scannées. La facette `source` et la puce « Pages scannées
> seulement » ne filtraient jusqu'ici que le jeu chargé ; l'amendement ci-dessus
> les décrivait ainsi, ce n'est plus le cas.
>
> **Forme imposée : une JOINTURE, pas une sous-requête.** `docFilter` rend
> désormais un couple (jointure, clause) : `JOIN page_src pf ON pf.doc_id = …
> AND pf.page = … AND pf.src IN (…)` pour les provenances scannées, `LEFT JOIN`
> + `coalesce(pf.src, 0) IN (…)` pour le natif — une page ABSENTE de `page_src`
> est du texte natif, comme partout ailleurs (`pageMeta`, facette `source`).
> C'est la forme que la branche floue emploie déjà pour sa portée `ocr`
> (§5.5.3) ; la clé primaire `(doc_id, page)` en fait un saut de B-tree par page
> appariée, dans la sous-requête FTS donc AVANT le `LIMIT`. L'alias est `pf` et
> non `s` : la branche floue en portée `ocr` occupe déjà ce nom. Le filtre
> s'applique aux DEUX chemins (`ex` et `fz`), aux totaux, aux facettes et à
> `matchedPageCounts`. Sans filtre, la jointure est la chaîne VIDE : le SQL est
> celui d'avant, au caractère près (test dédié).
>
> Le canal VECTORIEL ne peut pas recevoir ce filtre par `allowedDocs`, qui ne
> connaît que des documents : sur un document mixte il laisserait passer les
> mauvaises pages. `HybridSearch` tamise donc sa liste APRÈS le balayage, par
> `pageMeta` (row-values sur la clé primaire) sur au plus `depth * 2` rowids,
> et demande `depth * 2` candidats dès que le filtre est armé.
>
> Surfaces : `fouine search --source native|ocr` (une seule valeur ; `ocr`
> couvre `ocr_fast` et `ocr_accurate`), clé `source` du JSON quand le filtre est
> armé, paramètre `source` de `fouine_search` (énumération du schéma).
>
> Mesuré le 05/09/2026 sur la base de production (1 503 documents, 408 758
> pages, binaire release, médiane de trois passes, `--limit 50`) : `energie`
> 29 005 pages en 263 ms sans filtre, 3 080 en **81 ms** avec `--source ocr`,
> 25 925 en **273 ms** avec `--source native` ; `polymere` 1 694 / 22 ms → 282 /
> 13 ms → 1 412 / 25 ms. Les comptes se partagent exactement. Le filtre allumé
> sur le natif coûte +4 % (la jointure se paie sur presque tout le jeu) ;
> allumé sur le scan il fait GAGNER du temps ; éteint, il ne coûte rien.

> **Amendement du 05/09/2026 (R-10, lot U3) — la langue se rattrape sur le
> texte déjà indexé.** `docs.lang` n'était écrite qu'à l'extraction : 1 369 des
> 1 476 documents extraits de la base réelle étaient restés vides, et la facette
> ci-dessus ne disait donc presque rien. Le texte étant déjà dans `page_fts`, il
> n'y a rien à ré-extraire. `GRDBStore.backfillLanguages(limit:sampleCharacters:chunk:detect:)`
> (fichier `Store/GRDBStore+Language.swift`) relit, pour chaque document sans
> langue (`state = extracted`, `n_pages > 0`, ordre par `id`), les premières
> pages jusqu'à `LanguageDetector.sampleCharacters` — le MÊME échantillon qu'à
> l'extraction, lu par plage de rowid et tronqué par `substr` — et écrit le
> résultat. La détection est INJECTÉE : `LanguageDetector` vit dans FouineIndex,
> qui dépend du cœur. Trois temps par lot de cent documents : lecture
> (transaction de lecture), détection hors transaction, écriture (une
> transaction) — le verrou d'écriture n'attend pas NLLanguageRecognizer.
>
> **Un document dont la langue ne se détermine pas reçoit le jeton
> `FacetKey.undeterminedLanguage` et non NULL** : sans cela il serait recandidat
> à chaque passe pour la même réponse. La facette et le filtre doivent donc
> traiter NULL, `''` et « und » comme une seule valeur ; l'expression de la
> facette `lang` devient `CASE WHEN lang IS NULL OR lang = '' THEN 'und' ELSE
> lower(lang) END` (`GRDBStore.languageSQL`), et le filtre `langs` compare sur
> la même expression. Conséquence assumée : un document scanné pas encore
> OCRisé est marqué « und » et n'est pas revisité quand son texte arrive — sa
> langue s'écrira à sa prochaine ré-extraction.
>
> `IndexPass` joue le rattrapage **en fin de passe**, borné par
> `IndexPassOptions.languageBackfillLimit` (défaut **300**), jamais si la passe
> est annulée, à court de budget ou en erreur, et sans jamais la faire échouer :
> c'est un confort. `IndexPassSummary.counters.languagesDetected` le compte et
> le journal en porte une ligne anglaise (« language detected for N document(s),
> M left »). Les trois pipelines en profitent sans réglage et **aucune chaîne
> visible ne change**. `fouine maintain --detect-languages` fait tout d'un coup ;
> `fouine status` publie `docs_without_language`.
>
> Mesuré le 05/09/2026 sur une copie de la base réelle (1 499 documents,
> 404 103 pages, binaire release) : **1 369 documents relus en 6,4 s**, soit
> 213 documents par seconde — d'où le défaut de 300, qui tient une fin de passe
> sous ~1,4 s. Répartition écrite : `en 600 · fr 443 · und 246 · pt 13 · da 11`
> et quinze autres codes à moins de dix documents. Sur `enthalpie`, la facette
> passe d'une seule valeur (« und », 753 pages, section masquée faute de deux
> valeurs) à `fr 657 · und 86 · en 10`. Sur `attestation` : `fr 25 · und 4`
> contre `fr 21 · und 8` avant le rattrapage, la somme (29 pages) ne bougeant
> pas.

public protocol IndexStore: AnyObject, Sendable {
    func open(at url: URL) throws
    func addRoot(path: URL, label: String?) throws -> Int64   // résout volume + rel_path
    func roots() throws -> [RootRecord]
    func removeRoot(id: Int64) throws                         // purge docs + pages
    func upsertDoc(_ d: DocRecord) throws -> Int64
    func replacePages(docID: Int64, pages: [PageText]) throws // suppression PAR PLAGE DE ROWID
    func setDocState(_ id: Int64, _ s: DocState, err: String?) throws
    func enqueueOCR(docID: Int64, pages: [Int], priority: Int) throws
    func nextOCRBatch(limit: Int) throws -> [(docID: Int64, page: Int, path: String)]
    func completeOCR(docID: Int64, page: Int, result: OCRPage) throws  // rowid déterministe
    func failOCR(docID: Int64, page: Int) throws
    func search(_ q: SearchQuery) throws -> SearchResults
    func facets(_ q: SearchQuery, by: FacetKey) throws -> [(String, Int)]
    func stats() throws -> [String: Int]
    /// Les N termes les plus fréquents de fts5vocab, pour `customWords` (§6.2).
    func topVocabulary(limit: Int, minLength: Int) throws -> [String]
}

public struct RootRecord: Sendable {
    public let id: Int64
    public let volUUID: String, relPath: String, label: String
    public let enabled: Bool
}

// Points d'entrée figés en vague 0 pour que les deux agents de la vague 1
// puissent se câbler sans se relire (§9.2). Aucune implémentation ici.
public enum CrawlMode: Sendable { case full, delta }

public struct CrawlSummary: Sendable {
    public let seen: Int, added: Int, updated: Int, removed: Int, skipped: Int
}

public protocol Crawler: Sendable {
    func crawl(rootID: Int64, mode: CrawlMode, store: any IndexStore) throws -> CrawlSummary
    /// Lit effectivement un fichier de la racine. Renvoie l'erreur TCC telle quelle.
    func probeReadable(rootID: Int64) throws
}

public protocol ExtractorRegistry: Sendable {
    static var supportedExtensions: Set<String> { get }
    func extractor(for ext: String) -> (any TextExtractor)?
}
```

Toute erreur remonte en `FouineError` :

```swift
public enum FouineError: Error, Sendable {
    case volumeNotMounted(uuid: String)   // -> exit 2
    case rootUnreadable(path: String,
                        reason: String)   // -> exit 5 : TCC, droits, dossier disparu
    case databaseFailure(String)          // -> exit 3
    case budgetExhausted(remaining: Int)  // -> exit 4
    case unsupported(ext: String)
    case fileTooLarge(bytes: Int64)
    case extraction(String)               // inclut PDFDocument(url:) == nil (D2)
    case ocr(String)
}
```

> **Amendement du 14/09/2026 (lot MN1) — une phrase partagée vit dans le module
> qui possède le FAIT.** Le contrat s'étend de deux lectures et d'une propriété,
> toutes additives. ① **`SearchQuery.filtersDocuments`** (calculée) : « cette
> requête restreint-elle l'ensemble des DOCUMENTS ? », les onze champs de filtre
> réunis, la provenance exclue puisqu'elle porte sur la page. C'est la garde du
> périmètre du sens (PM-06), que la ligne de commande et le serveur MCP
> portaient chacun en copie depuis le lot CL2 — onze conditions recopiées à deux
> endroits divergent au premier filtre ajouté, c'est-à-dire annoncent deux
> périmètres pour la même requête. ② **`SemanticDisarmReason.noVectorsInScopeNote(_:folders:)`**
> (FouineEmbed) : la phrase chiffrée du périmètre vide, jusqu'ici recopiée au
> mot près dans les deux surfaces, à côté d'`advice` qui dit le fait. Les deux
> ne se publient jamais ensemble. ③ **`GRDBStore.knownLanguages(inFolders:)`** :
> les mêmes langues, restreintes à des racines. `ReadOnlyStore.knownLanguages()`
> l'appelle avec le périmètre de `fouine mcp --folders` (reste du lot IG1) — le
> refus d'une langue inconnue ne doit nommer que les langues des documents
> SERVIS, sans quoi il apprend au modèle qu'il y a autre chose derrière le
> périmètre. Étiquettes vides = la requête d'avant, au caractère près.

### 4.3 Contrat de la CLI

```
fouine root add     <chemin absolu> [--label <nom>]   # résout volume + rel_path seul
fouine root list    [--json]
fouine root remove  <id|label> [--purge]
fouine volume add   --path <chemin monté> [--roots A,B,C]   # cas volume externe, annexe A
fouine volume list
fouine crawl        [--root <id|label>] [--full | --delta]
fouine extract      [--jobs N] [--budget-minutes M] [--only <rel_path>]
fouine ocr          [--jobs N] [--budget-minutes M]
                    [--prio-folder <nom>] [--only <rel_path>]
fouine ocr export   [--pending] [--limit N] [--render-png <dossier>] --out <fichier.jsonl>
fouine ocr import   <fichier.jsonl>
fouine index        [--with-ocr]        # = crawl --delta + extract
fouine search       "<requête>" [--limit N] [--facet folder|ext|year|source]
                    [--in <doc_id>]… [--json] [--raw-fts]
                    [--fuzzy off|auto|on] [--fuzzy-scope ocr|all]
fouine status       [--json]
fouine doctor       [--json]
```

Trois remarques qui engagent :

- **`fouine ocr` n'a plus d'option `--level`.** La passe est `.accurate`, une et une seule (D1). Une option qui ne prend qu'une valeur est une invitation à la réintroduire : elle n'existe pas.
- **`--in` est répétable** (`--in 12 --in 45`) et alimente `SearchQuery.inDocIDs`.
- **`root add` fait le travail** : il résout le volume par `URLResourceKey.volumeUUIDStringKey`, calcule `rel_path` relatif à la racine du volume, prend comme `label` par défaut le dernier segment du chemin, **teste immédiatement la lisibilité** de la racine et refuse en `rootUnreadable` avec le message TCC du §7.1 plutôt que d'enregistrer une racine muette.

Codes de sortie : `0` succès · `1` erreur générique · `2` volume non monté · `3` base verrouillée ou corrompue · `4` budget épuisé, travail restant en file · `5` racine illisible (TCC ou dossier disparu).

> **Amendement du 02/09/2026 (palier 3, audit U1).** (a) Un code s'ajoute : **`64` erreur d'usage** — argument manquant, dossier refusé par `RootPolicy` (`root add`), clé de réglage inconnue (`config get/set/reset`), requête refusée par l'analyseur (`search` : préfixe de moins de quatre lettres, exclusion seule, requête vide). (b) **La ligne de commande, les bibliothèques et l'agent écrivent leurs messages en anglais**, langue de base du projet ; il n'existe pas de version française de la CLI. Le français ne vit que dans l'application, par catalogue (`docs/i18n.md`). Les phrases françaises citées dans cette spécification (§5.5.1, §7.1, §8) décrivent donc ce que l'**application** affiche à un utilisateur français ; la CLI et `docs.err` portent l'équivalent anglais. (c) `FouineError.rootUnreadable(path:reason:)` transporte désormais dans `reason` un **enregistrement sans langue** — `fouine-root-unreadable 1 reason=permission-denied|missing|no-readable-file|system detail=…` (`RootProbe.Reason`) —, comme le message d'occupation du verrou (`fouine-lock-busy 1 path=… pid=… role=… since=…`, `WriteLock.Busy`) depuis le palier 3.2 ; chaque outil le rend dans sa langue. (d) `fouine search --hybrid` sans modèle sémantique retombe sur le plein texte (avertissement sur stderr, `"hybrid": false` dans le JSON) au lieu de sortir en 1 ; une base sans vecteur reste une erreur 3. (e) **Extension des commandes CLI** : le contrat réel compte 26 commandes et 33 options (détaillées dans `docs/cli.md`), intégrant `fouine embed`, `fouine model` (`status`, `download`, `remove`, `check`), `fouine config` (`get`, `set`, `reset`, `list`) et `search --hybrid`.

> **Amendement du 10/09/2026 (PR-06, CM-26, lot BR1) — parcourir, et refuser d'emblée.** ① **Une commande s'ajoute au §4.3 : `fouine list`.** `fouine list [--folder <étiquette>] [--ext <ext>] [--path-contains <fragment>] [--state indexed|failed|skipped|pending]… [--order path|pages|recent] [--limit N] [--offset N] [--json]`. Elle **parcourt** l'index sans requête — ce que `fouine search ""` refuse par construction (« empty query »), et ce que rien ne permettait : le §5.6 comme la CLI supposaient qu'on sache déjà quoi chercher, alors que l'outil MCP `fouine_list_documents` sert cette question depuis le palier 4. Elle est en **lecture seule** au sens du §4.3 — `openReadOnly`, jamais `fouine.lock`, refus en 3 sur un index absent —, et rejoint donc `search`, `status` et `doctor` dans la liste des commandes qui fonctionnent pendant une écriture. Défauts : `--order recent`, `--limit 50`, plafond **500** (au-delà, 64) ; `--state` est répétable et, sans lui, **tous** les états sont rendus ; une étiquette de dossier, un état ou un ordre inconnus sortent en **64** en nommant les valeurs réelles (règle de `FolderCheck`, CM-11). Le `--json` reprend **exactement** les clés de `fouine_list_documents` (`documents`, `total`, `has_more`, `truncated`, et par document `doc_id`, `path`, `link`, `folder`, `ext`, `pages`, `state`), plus `modified` (ISO 8601) : la CLI s'aligne sur l'outil, jamais l'inverse. Aucune lecture nouvelle dans le cœur en dehors de `documentExtensions()` (les extensions présentes, pour le menu « Type » de l'application). ② **`fouine ocr` sous verrou sort en 3.** La file d'OCR se tirant par une lecture, la passe partait, échouait à l'écriture de **chaque** page et rendait **0** : le §4.3 promettait « base verrouillée → 3 » pour toutes les commandes d'écriture, et celle-ci ne le tenait pas. Elle sonde désormais le verrou avant tout travail — une ligne, code 3, file intacte, aucun préchauffage du moteur —, **sauf file vide**, où elle reste un succès à 0 sans toucher au verrou (l'agent et l'application l'appellent en boucle).

> **Amendement du 13/09/2026 (L1C, lot licence) — `fouine license`, et trois
> codes de sortie.** ① **Une commande s'ajoute au §4.3 : `fouine license`**, au
> SINGULIER, à ne pas confondre avec `fouine licenses` (les notices tierces,
> inchangée) : `fouine license status [--json]`,
> `fouine license activate <clé> [--instance-name <nom>]`,
> `fouine license deactivate`. AJOUT au contrat gelé, aucune sortie existante ne
> change. Le `--json` de `status` rend `state` (`trial` | `trial_over` |
> `licensed` | `revoked`), plus `days_left` pendant l'essai, plus `key_suffix`,
> `last_checked` (ISO 8601) et `activation_limit` une fois une clé posée.
> `status` **ne démarre pas** l'essai : la date de départ est posée au premier
> lancement de l'application ou au premier `fouine crawl`, jamais par une
> lecture. ② **Trois codes s'ajoutent au §4.3**, pris dans les valeurs libres :
> **6** essai terminé (les commandes qui écrivent dans l'index — `crawl`,
> `extract`, `index`, `ocr`, `embed` — refusent, une ligne, file et index
> intacts), **7** clé refusée (inconnue, désactivée, expirée, limite
> d'activation atteinte), **8** service de licence injoignable. Le 7 et le 8 se
> distinguent parce que le geste diffère : corriger la clé d'un côté, réessayer
> plus tard de l'autre. ③ **La fin d'essai est DOUCE, et cela fait partie du
> contrat** : `search`, `list`, `status`, `doctor`, `mcp`, `backup`, `config`,
> `root`, `maintain`, `embed --status` et `embed --bench` fonctionnent dans les
> quatre états, révoqué compris, et l'application garde la recherche, l'aperçu
> et l'export. Seule la **mise à jour** de l'index s'arrête. Prendre en otage
> l'index d'un fonds de documents personnel serait un autre produit.

> **Amendement du 14/09/2026 (LC2, lot licence) — `released`, et une
> désactivation qui ne coince plus personne.** ① Le `--json` de `fouine license
> status` gagne une valeur de `state` : **`released`** (ce Mac a été libéré
> ailleurs, depuis le portail client ; clé oubliée), avec `days_left` tant que
> l'essai court. AJOUT : les quatre valeurs existantes ne changent pas de sens.
> ② `status` **vérifie** la clé quand elle n'a pas été vue depuis 30 jours
> (même règle et même décision que l'application, `LicenseCheck`) ; hors ligne,
> rien ne change, une ligne d'avertissement sur stderr, sortie 0. ③ **`fouine
> license deactivate` sur un Mac déjà libéré** — Creem répond 400 « already
> deactivated » ou 404 d'instance inconnue — nettoie le fichier et sort en
> **0** (« This Mac was already released. ») au lieu de sortir en 7 en gardant
> une clé morte. ④ La phrase d'un refus d'activation (toujours **7**) suit le
> texte de Creem : « already in use on 3 Macs » pour la seule limite
> d'activation, « Contact the seller » pour tout autre refus.

> **Amendement du 13/09/2026 (PM-18, PM-16, PM-25, lot MC3) — lire une page,
> ses voisines, et une facette qui dit son nom.** ① **Deux commandes s'ajoutent
> au §4.3** (on ajoute, on ne renomme pas) : `fouine read <doc_id> <page>
> [--max-chars N] [--offset N] [--context 0..2] [--json]`, qui rend le TEXTE
> indexé d'une page — jamais le fichier d'origine —, et `fouine similar <doc_id>
> <page> [--limit N] [--folder <étiquette>] [--ext <ext>]
> [--no-exclude-same-document] [--min-cosine C] [--preview-chars N] [--json]`,
> qui rend les pages les plus proches par le sens à partir des vecteurs DÉJÀ en
> base, sans jamais charger le modèle. Les deux sont en **lecture seule** au
> sens du §4.3 et rejoignent `search`, `list`, `status` et `doctor`. Leurs clés
> `--json` sont, au mot près, celles de `fouine_read_page` et
> `fouine_similar_pages` : `read` PARTAGE son implémentation avec l'outil MCP
> (`PageReading`, FouineCore), sans quoi les deux surfaces dériveraient comme
> `score` et `bm25`. Un document ou une page inexistants sortent en **64** en
> disant combien de pages le document a vraiment ; une page sans vecteur sort en
> **1** avec le geste (`fouine embed`), et non en 0 avec une liste vide. ②
> **`fouine list --json` gagne `error` et `vectorised_pages`**, les deux clés
> que `fouine_list_documents` publiait déjà : la cause d'un échec cessait d'être
> lisible sans seconde commande, et rien ne disait qu'un dossier entier était à
> zéro vecteur. La sortie texte porte la cause à la suite de l'état. ③ **La
> facette `year` publie désormais la clé `modified_year`** — elle suit la date
> de MODIFICATION du fichier, ce que son nom ne disait pas —, et `doc_year`
> passe en premier dans l'aide et la doc. `--facet year` reste **accepté en
> entrée** comme alias silencieux, pour qu'aucun script écrit avant ce lot ne
> tombe en 64.

> **Amendement du 14/09/2026 (PM-16, PM-06, PM-19, PM-22, PM-07, lot CL2) — la
> ligne de commande dit ce que l'assistant dit déjà.** ① **Cinq clés s'ajoutent
> à chaque `hits[]` de `search --json`** (on ajoute, on ne renomme pas) :
> `bm25`, qui porte le MÊME nombre que `score` sous le nom du serveur MCP —
> c'est `score` qui devient **déprécié** (il ne nomme pas son échelle), retiré
> au plus tôt en 1.1 ; `relevance_pct`, le pourcentage que la sortie texte
> imprimait sans le publier, part du MEILLEUR score de la réponse (`HitRelevance`,
> FouineCore, un seul calcul pour les deux surfaces ; en hybride il se lit sur le
> `rrf`) ; `time_seconds`, `slide` et `embedded_image`, qui disent ce qu'une page
> DÉSIGNE. Les quatre dernières sont **toujours présentes**, `null` quand la
> question ne se pose pas — la règle du serveur, où une clé absente n'apprend
> rien. Le `link` d'une page transcrite porte `&t=<secondes>` : le §4.3 disait
> qu'aucune surface ne l'émettait, ce n'est plus vrai, et une page de
> transcription couvre dix minutes de parole. Les mêmes quatre champs rejoignent
> `read --json`, sur la page lue comme sur ses voisines. ② **`search --mark
> guillemets|brackets|asterisks|none`** choisit ce qui entoure les mots trouvés
> (`SearchQuery.snippetMarkers`) ; défaut inchangé, valeurs et sémantique du
> paramètre `marks` du serveur. ③ **Le PÉRIMÈTRE du sens est lu avant tout
> chargement** : `--hybrid` sur un périmètre sans vecteur rend la réponse
> lexicale ENTIÈRE avec `hybrid: false`, `hybrid_disarmed:
> "no_vectors_in_scope"`, la phrase chiffrée sur l'erreur standard, un
> `semantic_coverage_pct` **du périmètre** et `semantic_scope` (`pages`,
> `vectorised`, `filtered`) — les deux clés publiées dès que la fusion a été
> demandée, y compris sur la réponse lexicale. ④ **`--hybrid-auto` s'ajoute au
> §4.3** : fusionne si le modèle et les vecteurs sont là, cherche en plein texte
> sinon, sans avertissement et **sans sortie 3**. C'est un drapeau séparé et non
> `--hybrid=auto` parce qu'une option à valeur facultative n'est pas exprimable
> (`--hybrid azote` aurait avalé la requête) ; `--hybrid` garde son refus en 3
> sur une base sans le moindre vecteur. ⑤ **`similar --encode`** encode la page
> à la volée quand elle n'a pas de vecteur (`PageEmbedding`, le vecteur de la
> campagne), charge donc le modèle — la seule porte, fermée par défaut — et
> publie `source_vector` (`stored` / `computed` / `null`) ; `source_has_vector`
> continue de décrire la BASE. Sans l'option, le refus en **1** nomme l'option.

> **Amendement du 14/09/2026 (lot MN1) — la ligne de commande et le serveur
> disent la même chose des mêmes résultats.** ① **LE QUORUM EST ARMÉ EN
> HYBRIDE** (décision de l'orchestrateur, **réversible**) :
> `SearchQuery.quorum` ne dépend plus du mode (`q.quorum = !noQuorum`), le
> drapeau voyage depuis `HybridResults.quorum` (lot MC2), la sortie texte
> l'annonce sur l'erreur standard (`SearchAdvice.quorum`, comme en lexical),
> `--json` porte `quorum: true` sous la même règle additive, et le `why` d'un
> hit hybride dit `partial` et non `exact`. Motif : le canal lexical de la
> fusion relâchait déjà le ET — c'est la requête que le serveur MCP lui passe
> qui l'arme depuis MC2 —, et deux surfaces qui disent deux choses des mêmes
> résultats sont pires qu'une convention discutable. On garde donc celle du
> serveur. Le quorum a été jugé au banc en LEXICAL (790 jugements, +0,031
> nDCG@10, 6 / 43 / 0, p = 0,040) ; en hybride, il reste à rejouer à couverture
> pleine, d'où « réversible ». `--no-quorum` le désarme dans les deux modes.
> ② **`ocr_pages` rejoint `fouine list --json`** (dernier tiers du constat
> PM-16a) : même méthode et même définition que `fouine_list_documents`
> (`ocrPageCounts`, une requête pour la page de résultats ; une transcription
> n'y compte pas). Les deux surfaces portent désormais le même jeu de clés,
> `abs_path` près, que le lien porte ici. ③ **Une requête qui commence par un
> tiret** (`fouine search -type:pdf réacteur`) sort en **64** sur « Unknown
> option » — ArgumentParser lit les arguments avant que Fouine ne voie la
> chaîne — et le refus est désormais suivi d'UNE ligne qui propose la forme qui
> marche : `fouine search -- '-type:pdf réacteur'`, options avant le `--`. La
> règle du déclenchement est celle d'un filtre (`-<lettres>:<valeur>`, mêmes
> exceptions que `unknownPrefix`), jamais une option mal tapée, et rien après un
> `--` déjà écrit. `--help` et `docs/cli.md` portent la forme. Le point d'entrée
> refait pour cela les trois lignes de `ParsableCommand.main()` : `exit(withError:)`
> écrit son message ET sort, donc rien ne peut s'écrire après lui.

`fouine doctor` (seule option `--json`) est le diagnostic de référence. Il vérifie le contexte de permissions d'exécution (CLI vs agent), l'accessibilité et la taille de la base, la longueur de la file OCR, la disponibilité de la sonde d'extraction, la présence de l'outil externe optionnel `djvulibre` (`djvused`) et l'état d'installation du modèle sémantique Core ML. Pour **chaque racine enregistrée**, il vérifie que le volume est monté et effectue une **lecture effective d'un fichier** de la racine (`RootProbe`, pas seulement un `stat`). En cas de refus de lecture (TCC), il sort en code **5**, nomme le refus et donne le chemin exact dans Réglages Système pour réactiver l'autorisation (§7.1). Il ne sonde pas d'échantillon aléatoire de pages (aucune option d'échantillonnage n'existe).

Sortie `--json` de `search`, schéma stable :

```json
{
  "query": "chromatographie",
  "elapsed_ms": 4.2,
  "total_pages": 37,
  "total_docs": 9,
  "hits": [
    { "doc_id": 12,
      "path": "Users/<vous>/Livres/Chimie/CAPES Tome 2 - Chimie.pdf",
      "folder": "Livres",
      "page": 779,
      "score": -8.31,
      "source": "native",
      "engine": "none",
      "fuzzy_distance": 0,
      "snippet": "…absorbant Applications de la «chromatographie» sur papier…" }
  ],
  "facets": { "folder": { "Livres": 8, "Cours": 1 } }
}
```

> **Amendement du 03/09/2026 (C2-09, D-R4, lot H1).** Au-delà d'un seuil de comptage exact fixé à 50 000 pages (`Schema.approximateCountThreshold`, surchargeable par `SearchQuery.approximateThreshold`), le moteur FTS n'exécute plus de `count(DISTINCT doc_id)` exhaustif sur l'index entier : `total_pages` vaut 50 000, `total_docs` est borné en proportion, et la sortie JSON s'enrichit de la clé `totals_approximate: true` (absente ou fausse sinon). Dans la sortie texte, la CLI affiche `> 50 000 page(s) in > … document(s)`. Chaque ligne de hit dans la sortie texte de la CLI et dans l'application affiche en outre son pourcentage de pertinence relatif au meilleur score de la tranche (`pct = 100 × r_hit / r_best`, borné à 100 au meilleur hit, D-R4), calculé à la présentation et jamais stocké en base.

`fouine status --json` expose au minimum : `docs_total`, `docs_extracted`, `docs_failed`, `docs_skipped`, `pages_indexed`, `pages_native`, `pages_ocr_accurate`, `pages_ocr_low_conf`, `ocr_queue_len`, `db_bytes`, `roots` (tableau : `label`, `path`, `enabled`, `mounted`, `readable`). `pages_ocr_fast` reste exposé et doit valoir **0** sur toute base produite par la v1.1 : c'est le contrôle le plus simple que D1 est bien appliquée.

> **Amendement du 13/09/2026 (RC2).** `pages_ocr_fast` n'est plus exposé : la clé est **absente** de `status --json`, et la ligne `pages` de la sortie texte ne nomme plus `ocr_fast` (§4.1, amendement RC2). `StatusContractTests` prouve l'absence de la clé. `fouine_status` (MCP) ne l'a jamais publiée.

**Amendement du 01/09/2026 (audit A6).** `page_src.conf = 0` est la **sentinelle « aucune ligne reconnue »** que pose `VisionOCREngine` (`meanConfidence = retained.isEmpty ? 0 : …`), pas une confiance faible : sur les 11 109 pages OCRisées de la base, les 510 pages sous 0,30 étaient *exactement* les 510 pages vides. Les deux populations sont donc séparées, et `status --json` expose une clé de plus :

- `pages_ocr_low_conf` — pages **douteuses** : `src != 0 AND 0 < conf < 0,60` (326 pages mesurées, le vrai gisement d'une re-OCRisation) ;
- `pages_ocr_no_lines` — pages dont **aucune ligne** n'a été reconnue : `src != 0 AND (conf IS NULL OR conf <= 0)` (510 pages), à re-rendre, éventuellement à un DPI supérieur.

Côté CLI, `fouine ocr export` sans `--pending` rend les pages douteuses ; `--no-lines` rend les secondes.

> **Amendement du 05/09/2026 (R-16, lot G2).** `fouine ocr requeue [--doubtful|--no-lines] [--limit N] [--json]` remet en file d'attente OCR (`ocr_queue`, `attempts = 0`, priorité 3 — la plus basse de l'échelle, identique à `comicArchives`) les pages scannées de la population choisie (`ocrPagesToRevisit`), sans modifier le texte indexé existant. Les pages déjà présentes en file sont ignorées (laissées avec leur priorité et tentatives existantes).

> **Amendement du 10/09/2026 (CM-11, CM-12, CM-21, CM-22, CM-24, CM-26, C2-14, lot CL1) — la CLI dit pourquoi.** Cinq précisions au contrat de sortie, toutes ADDITIVES.
> **1. Refus nommés (code 64).** La règle déjà tenue par `dossier:` et `--source` — refuser en nommant les valeurs réelles — s'applique aux quatre entrées qui rendaient zéro résultat en silence : `search --lang <inconnue>` (« unknown language “xx” — languages in this index: … », la phrase de l'outil MCP `fouine_search`), `search --in <doc_id inconnu>`, `config set roots.pinned <id inconnu>` (rien n'est écrit), `extract|ocr --only <chemin sans document>`. `config set ocr.languages` est de plus validée **à l'écriture** contre `supportedRecognitionLanguages` de Vision. La règle de `FolderCheck` tient partout : **on ne refuse que ce qu'on peut contredire** — une liste vide ne fonde aucun refus —, et `und` reste toujours accepté.
> **2. `status --json` publie `write_lock`**, sous la forme exacte de `doctor --json` et de l'outil MCP `fouine_status` (`status`, `held`, `probe`, puis `role`, `pid`, `since`) : un constructeur unique, plus deux contrats divergents pour la même question.
> **3. `status --unreadable`** (texte et `--json`) liste les documents que Fouine n'a pas lus — `chemin · extension · motif`, 500 au plus, puis « … and N more ». En JSON, `unreadable[]` (`{doc_id, path, ext, reason, status}`) et `unreadable_total`, présentes **seulement avec l'option**.
> **4. `doctor` dit depuis quand l'agent n'a rien fait.** Quand le service ne tourne pas et que `agent_status` porte un `updated_at` de plus d'une heure, la ligne et le JSON l'écrivent (`last_run`, `idle_seconds`, `guidance`) ; `log_last_line` — la dernière ligne du journal de l'agent — est toujours présente (`null` sans journal). **`ok` ne change pas** : le silence est un défaut à dire, pas un verdict de panne.
> **5. `search --json` tient son schéma gelé dans les DEUX modes.** `score` passe par `JSONNumber.rounded(_, places: 4)` — même grandeur et même arrondi que le `bm25` du serveur MCP —, et le mode hybride ne retire plus `total_pages`, `total_docs` (= les totaux lexicaux), ni `folder` et `engine` par résultat : les clés hybrides viennent en plus, jamais à la place. Seul `score` reste réservé aux résultats que le canal lexical a trouvés. Un constructeur unique (`SearchJSON.hit`) sert les deux modes.

---

## 5 · Modules

### 5.1 FouineCore — Store et Query

Propriétaire : **A-Core**.

Accès SQLite par **GRDB.swift** (§2.2), qui lie le SQLite du système : c'est le FTS5 3.43.2 mesuré, pas un autre. `DatabasePool` — les recherches lisent pendant que l'indexation écrit. Migrations par `DatabaseMigrator`, version reflétée dans `meta.schema_version`. WAL activé, `busy_timeout` à 5 000 ms.

> **Amendement du 03/09/2026 (J1, lot « sans rétrocompatibilité »).** **Il n'y a plus de migrations.** Fouine n'a jamais été distribué : il n'existe pas, hors de cette machine, de base aux schémas v1 à v4, et la seule base réelle est déjà en v5. Les cinq migrations `DatabaseMigrator` (`v1`, `v2-ocr-layout-rowid`, `v3-page-vec`, `v4-settings`, `v5-page-vec-windows`) sont supprimées, avec les scripts de transposition qu'elles portaient et les DDL en double qui existaient pour qu'une base ancienne rattrape une base neuve. `GRDBStore.open(at:)` lit `meta.schema_version` et tranche en trois cas : **absente** — base neuve ou vide —, il **crée** le schéma v5 d'un coup (`Schema.ddl` + géométrie du fenêtrage + les trois clés de `meta`), en une transaction et **sous le verrou nommé** ; **égale à 5**, il ouvre **sans prendre aucun verrou** ; **toute autre valeur**, il **refuse**. Le refus porte le geste, et il n'est pas le même dans les deux sens : « this Fouine index predates 1.0.0 (schema vN) — delete it and index again » vers le bas, « written by a newer version — update the fouine binary » vers le haut. La phrase vit en un seul endroit (`GRDBStore.schemaMismatch`) : le cœur, la CLI, le serveur MCP — qui la rend sur `stderr` et à chaque `tools/call` — et l'application, qui la traduit en un geste pour non-technicien avec une confirmation disant ce qui sera perdu, disent exactement la même chose. Contrepartie assumée : un index d'une version d'essai se refait au lieu de se rattraper, ce qui coûte une campagne d'indexation à la seule personne concernée, et fait disparaître une chaîne de code qu'aucune base réelle n'aurait jamais exercée.

Toutes les écritures d'indexation passent par un verrou exclusif `flock()` sur `fouine.lock`, pour que la CLI et l'agent d'arrière-plan ne se marchent pas dessus. Les lectures (recherche) ne prennent pas le verrou.

> **Amendement du 10/09/2026 (BU-30, CM-06, CM-20, lot CL1) — un verrou par BASE, et une ouverture qui dit la vraie cause.** Le fichier de verrou n'est plus `fouine.lock` quelle que soit la base : il **porte le nom de la base**, à côté d'elle (`FouinePaths.lockURL(for:)` : `fouine.db` → `fouine.lock`, donc **rien ne change en production ni pour l'agent installé** ; `c2.db` → `c2.lock`). Même règle pour le verrou de campagne de vectorisation (`FouinePaths.embedLockURL(for:)` : `<nom>-embed.lock`). Deux bases d'un même dossier — le régime documenté du travail sur copie, `FOUINE_DB=<copie>` — se bloquaient l'une l'autre, et l'application annonçait « un autre programme écrit dans l'index » pour une écriture qui se faisait dans une AUTRE base. Tous les sites d'appel passent par `FouinePaths` (store, droits POSIX, agent, serveur MCP) ; plus aucun littéral `"fouine.lock"` dans `Sources/` hors de ce point unique.
>
> `GRDBStore.openReadOnly(at:)` distingue par ailleurs **trois causes** derrière un seul message : un chemin qui désigne un **répertoire** est refusé avant l'ouverture (« is a folder, not a Fouine index — FOUINE_DB must point at the .db file ») ; un `SQLITE_CANTOPEN` sur une base **dont le `-wal` est absent** est une copie du seul `.db` (`cp`, Time Machine, un autre Mac) et le dit, avec le geste porté par la variable (`FOUINE_DB=<copie> fouine maintain`, ou `fouine backup` pour fabriquer les copies) ; le reste garde `cantOpenGuidance` au caractère près — le serveur MCP et l'application la reconnaissent. Le signe observable est bien l'absence du `-wal` et non celle du `-shm` : mesuré le 10/09/2026, un `.db` accompagné de son `-wal` s'ouvre en lecture seule même sans `-shm`, un `.db` seul jamais.

`replacePages` est transactionnel : **suppression par plage de rowid** (`WHERE rowid BETWEEN doc*100000 AND doc*100000+99999`) puis insertion à rowid explicite, dans une seule transaction. `completeOCR` supprime **par rowid exact**. La forme `WHERE doc_id = ?` est interdite : mesurée à 143 ms sur 600 000 lignes contre 3 ms, elle coûterait ~2 h de balayage pur sur la passe OCR. Après une passe d'indexation complète, exécuter `INSERT INTO page_fts(page_fts) VALUES('optimize')`.

> **Amendement du 04/09/2026 (A1m-13, lot K1).** `replacePages` purge aussi `ocr_queue` et `ocr_layout` des pages disparues, dans la MÊME transaction et sur la MÊME liste de pages que `page_src`. Un document ré-extrait avec moins de pages — pagination qui change, PDF remplacé — laissait sinon en file des pages qui n'existent plus : elles étaient rendues, échouaient, et étaient retentées trois fois avant d'abandonner ; leurs blobs de mise en page, eux, survivaient à ce qu'ils décrivaient. `ocr_layout` s'attaque par PLAGE de rowid structuré (elle n'a plus de colonne `doc_id` depuis le schéma v5), avec l'exclusion sur `rowid % 100000` : c'est la forme de `completeOCR`, et elle reste une sonde de clé primaire.

Agrégation page → document : regrouper par `doc_id`, score du document = somme des 5 meilleurs scores de page, exposer aussi le nombre de pages touchées et la première page.

> **Amendement du 03/09/2026 (C2-08, D-R5, lot H1).** La somme des 5 meilleurs scores de page favorisait artificiellement les gros ouvrages multi-pages face aux notes courtes et denses. L'agrégat document devient :
> `score_doc = r_meilleure_page × (1 + 0,15 · log2(1 + pages_chargées))`
> Le score BM25 étant négatif (plus bas = meilleur), la multiplication par un facteur `> 1` améliore le score global tout en restant bornée par la meilleure page. Le champ `pageCount` reflète les pages chargées dans le lot (`ResultGrouping`), tandis que le compte exhaustif des pages touchées par document n'arrive qu'avec les facettes différées (audit A12).

> **Amendement du 05/09/2026 (R-01 et R-02, D-R2 et D-R3, lot M1) — trois bonus au score de PAGE.** Le canal lexical ne savait rien de l'ORDRE des mots : `energie libre` classait une page où les deux mots sont à trente mots l'un de l'autre exactement comme celle qui porte l'expression. Le score de page devient
> `r' = r × (1 + 0,8·[phrase] + 0,4·[voisinage ≤ 12 jetons] + 0,3·[nom du document])`
> Le score BM25 étant négatif, un facteur `> 1` fait MONTER la page (même convention que l'agrégat document ci-dessus) ; les paliers se cumulent, une page en phrase pèse donc × 2,2. Les trois crochets valent 0 ou 1 et sortent de trois sondes construites sur les termes EXACTS de la requête — une page trouvée par variante floue n'en reçoit aucun, elle est déjà pénalisée par son `1/(1+d)`. Les bonus ne changent **que l'ordre** : ni `counts()`, ni les facettes, ni `matchedPageCounts` ne les voient. `SearchQuery.rankingBoosts` (vrai par défaut) les désarme, exposé en CLI par `fouine search --no-proximity` — option de calibration, comme `--vec-floor`.
> **Amendement du 05/09/2026 (R-02, décision du propriétaire après mesure) — le bonus de nom exige deux mots.** La version ci-dessus accordait le bonus de nom dès un mot. Mesuré le même jour sur la base réelle (404 103 pages), du point de vue de l'application (documents présents dans les 50 premières pages) : `polymere` → 50 pages sur 50 issues du seul livre dont le titre portait le mot (six documents sans bonus, dont un second livre sur les polymères que « polymères » ≠ « polymere » laissait de côté) ; `thermodynamique` → 42/50 au lieu de 16/50 ; `catalyse` → 37/50, trois documents disparus. Un facteur par DOCUMENT appliqué à des scores bm25 presque plats fait monter toutes les pages d'un gros livre d'un bloc. Règle retenue : `rankingProbes` rend `nil` sous deux mots nus — aucune des trois sondes, le nom compris. Le poids (0,3) et la table `docs_fts` ne changent pas.

> **Amendement du 05/09/2026 (lot R1) — un document ne prend pas tout l'écran.** Mesuré sur la base réelle (408 758 pages), sur les 50 premières pages rendues : `loi de hess` → 28 pages d'un seul livre, 4 documents à l'écran ; `gaz parfait` et `catalyse` → 24/50 ; `potentiel chimique` → 23/50, 7 documents ; `equilibre` → 5 documents. Des scores bm25 presque plats à l'intérieur d'un gros ouvrage (−12,15 à −11,06 sur les 50 premières pages de `polymere`) font sortir ses pages en bloc, et l'application — qui regroupe par document — n'affiche plus que quatre ou cinq titres. Le pipeline de classement gagne une couche de **diversité** : dans le jeu apparié, les pages de chaque document sont numérotées par score (`row_number() OVER (PARTITION BY doc_id ORDER BY r)`), et au-delà de `Schema.diversityFullStrengthPages` (3) le score est multiplié par `Schema.diversityDemotion` (0,5) — bm25 étant négatif, la page DESCEND sans disparaître. Le palier est doux : la quatrième page d'un livre très pertinent reste devant la première page d'un document qui n'effleure le sujet. Ne change que l'ordre (totaux, facettes et `matchedPageCounts` sont inchangés) ; désarmé au-delà du seuil de comptage approché (même garde-fou que les sondes : mesuré sur `the`, 351 907 pages, la fenêtre coûtait +500 ms) et dans une recherche restreinte à un seul document (`inDocIDs.count == 1`). `SearchQuery.diversifyDocuments` (vrai par défaut), `fouine search --no-diversity`. Résultat sur les mêmes requêtes : `equilibre` 5 → 24 documents dans les 50 premières pages, `catalyse` 11 → 25, `enthalpie` 10 → 25, `gaz parfait` 8 → 25 ; sur les 42 requêtes du banc, 189 → 222 documents distincts dans les top-10. Coût : +1 à +7 ms en général, +14 ms sur 8 814 pages (`phase transition`), +33 ms sur 19 205 (`free energy`) — la CTE des bonus est `MATERIALIZED`, sans quoi la fenêtre réévaluait les sondes et coûtait le double. Le canal vectoriel de l'hybride applique la même règle en rangs (`HybridSearch.diversified`). **Le pipeline est désormais unique** : exact ou flou, une CTE de base (doc_id, page, r, fz), puis les bonus (`gb`), puis la diversité (`dv`), puis `ORDER BY r ASC, fz ASC, doc_id, page LIMIT` ; le chemin exact ne calcule plus `snippet()` pour toutes les pages appariées mais pour la tranche rendue.

> **Amendement du 05/09/2026 (lot X1, audit AUDIT-R1) — coûts recalés et effet sur D-R5.** Le « +33 ms au pire » ci-dessus est le pire du lot R1, pas de la règle : l'audit mesure +56 ms sur `energie` (29 005 pages), +74 ms sur `note` (34 175) et **+112 ms sur `metal` (46 051 pages)**, juste sous le seuil de 50 000 qui désarme la fenêtre — la morphologie amène davantage de requêtes près de ce seuil. Dans l'application, l'étendue D-R5 (« pages chargées » dans l'ordre des documents) est **neutralisée de fait** : la première tranche ne charge plus qu'environ trois pages par document, le reste étant rétrogradé au-delà des 200, et l'ordre des documents revient à celui de leur meilleure page ; le libellé « 3 / 300 p. » reste exact (« chargées sur touchées »), mais rien ne dit encore à l'utilisateur pourquoi trois, ni que « Charger plus » amène les autres (M5, non tranché — à juger sur le banc et à l'écran). La liste vectorielle de l'hybride ne suit plus « la même règle » que le texte ci-dessus l'affirmait : voir l'amendement du même jour au § 12.

> **Second amendement du 11/09/2026 (RK-07, AUDIT-RK2, orchestrateur) — le malus est ARMÉ par défaut.** Jugé sur le même pool : **+0,021** nDCG@10 pages (13 / 33 / 3, p = 0,019), +0,014 documents, **+0,101 sur les préfixes** (`polymer*` 0,312 → 0,806) ; une vraie perte, `chromato*` (−0,103 : le glossaire du Compendium IUPAC passe pour un sommaire — la sonde lit un patron d'index, entrées courtes et numéros de page). Avec le quorum l'effet s'additionne exactement : +0,052, p < 0,001. `SearchQuery.demoteTableOfContents` vaut donc **vrai** ; `fouine search --no-demote-toc` le désarme ; il s'applique aussi au canal lexical de la fusion hybride. Constat neuf à instruire (RK2A-07) : les pages de bibliographie attirent le canal sémantique sur les préfixes (hybride 0,441 contre lexical 0,618).
> **Amendement du 11/09/2026 (RK-07, lot RK2) — le MALUS des sommaires, désarmé par défaut.** Une table des matières est la page du livre où un mot revient le plus souvent : le classement par fréquence y mène tout droit. Mesuré le 09/09/2026 sur 790 jugements : `spectro*` rend un nDCG@10 de **0,213** avec **huit sommaires, index ou listes de mots-clés sur dix candidats** (`445 p.9`, `787 p.13`, `121 p.13`, `445 p.10`, `791 p.7`, `804 p.14`, `764 p.177`) et une seule page qui traite le sujet (`198 p.822`) ; `thermodyn*` 0,642 avec deux index et une page de références ; les cinq systèmes lexicaux du banc rendent EXACTEMENT le même classement sur les requêtes à préfixe (0,690 partout). `SearchQuery.demoteTableOfContents` (**faux** par défaut, `fouine search --demote-toc`) relit le TEXTE des `Schema.tocProbeDepth` (**50**) premiers candidats lexicaux — après les couches SQL, avant le groupement par document, et seulement sur la première tranche — et déplace les pages jugées sommaires **derrière** les autres, ordre stable, sans en retirer aucune : totaux, facettes et `matchedPageCounts` sont inchangés. Le verdict est une fonction PURE du texte (`TableOfContentsProbe`), sans aucun changement de schéma : deux des trois signes suffisent — (a) ≥ 30 % des lignes non vides finissent par un nombre détaché (un numéro de page ; une décimale « 5.0 » ne compte pas), (b) ≥ 5 % des caractères sont des points de conduite (suites de ≥ 3 points, `…`) ou des tabulations, (c) forme de liste : ≥ 40 % de lignes de moins de six mots, ou ≤ 0,5 mot unique par mot sur ≥ 80 mots. **Calibré sur des pages réelles** (11/09/2026, base de production) : la sonde reconnaît **quatre** des sept pages du constat (`445 p.9`, `121 p.13`, `791 p.7`, `804 p.14`) et **aucune** des vingt-trois pages de prose notées 2 au banc — l'arbitrage assumé étant qu'un sommaire laissé en tête coûte moins qu'une vraie réponse reculée. Le verdict se lit sur la page ENTIÈRE, jamais sur l'extrait : `158 p.583`, l'une des deux bonnes réponses de RK-04, commence par son propre sommaire. Coût mesuré (copie de la base de production) : la lecture du corps de 50 pages par leur rowid, **0,2 ms** à chaud et **13 ms** à la première lecture, pour 139 000 caractères. Mesuré sur `spectro*` : `198 p.822`, la seule page du top-10 qui traite le sujet, passe du rang 10 au rang 6 ; les trois sommaires reconnus descendent aux rangs 8, 9 et 10. `Hit.tableOfContents` porte le fait, et « pourquoi ce résultat » le dit (`table_of_contents` dans le JSON de `fouine search` et de `fouine_search`). Armer par défaut **attend le banc** (systèmes `lexical-toc`, `lexical-quorum-toc`).

> **Amendement du 05/09/2026 (PERSP-Q4, AUDIT-R1 M5, lot P2) — M5 tranché : le compte de pages est le geste.** Le constat ci-dessus (« rien ne dit encore à l'utilisateur pourquoi trois, ni que “Charger plus” amène les autres ») est levé côté application, sans toucher au classement. Quand un document a plus de pages appariées que la liste n'en montre, son compte devient un **bouton** — « 3 of 300 pages · See them all » — dont l'action pose `SearchModel.scope = .document(id:name:)` : la recherche se restreint à ce document, la diversité s'y désarme d'elle-même (`inDocIDs.count == 1`, règle du lot R1 ci-dessus) et **toutes** ses pages appariées reviennent — la liste les présente dans l'ordre des PAGES, `ResultGrouping.group` triant les pages d'un groupe par numéro (ordre de fusion en hybride). L'info-bulle dit la chose en langage simple — Fouine montre d'abord les meilleures pages de chaque document pour qu'un seul ne remplisse pas la liste, les autres sont à un clic — sans le mot « diversité » ni celui de « portée ». Sous la portée du document, le libellé redevient le compte honnête d'avant (audit A12) : le geste n'aurait nulle part où mener, et les pages suivantes s'obtiennent par « Charger plus ». Tant que le comptage différé n'a pas répondu, aucun geste n'est proposé — on ne promet pas ce qu'on ne sait pas encore. La décision (compte seul / geste / compte sous portée) et ses libellés sont une fonction pure (`PageCountAffordance.decide`), testée ; la vue n'en garde que la forme et l'action. Le contrat de classement (§ D-R5, diversité, `matchedPageCounts`) est inchangé : c'est un geste d'interface, pas une règle de moteur.

> **Amendement du 03/09/2026 (B1-26, D2-05, lot H4 — Santé visible).** Le verrou exclusif `fouine.lock` est inspecté sans attente (`WriteLock.inspect(path:)` rendant `.free`, `.held(holder)` ou `.stale(holder)`). Avant toute attente d'acquisition, l'identité du détenteur est immédiatement notifiée via `WriteLock.WaitHandler` (`setWriteLockWaitHandler`), tant dans la CLI (`CLI.warn` immédiat) que dans l'application (`IndexingState` annonçant qui détient le verrou et depuis quand). Le verrou est pris à la première écriture et rendu à chaque point de repos ; les lectures (`fouine search`, `status`, `doctor`) ne le prennent jamais. Les nombres flottants sérialisés en JSON dans la CLI et le cœur sont rendus lisibles et sans artefact binaire via `JSONNumber.rounded(_:places:)`.

> **Amendement du 04/09/2026 (A1m-03, lot K1) — `inspect` REGARDE le verrou, et un nom périmé se nettoie seul.** `WriteLock.inspect` lisait `fouine.lock` et faisait `kill(pid, 0)` : il ne touchait jamais le `flock`, c'est-à-dire la seule chose qui bloque un écrivain. Deux conséquences, mesurées sur cette machine : un `fouine.lock` abandonné par un processus tué n'était **jamais** nettoyé — ni `release()` ni `stamp()` ne passent — et `doctor` répondait `stale (…)` indéfiniment (`pid=1048`, 03/09/2026 19:06) ; et le jour où macOS recycle ce pid (il boucle à 99 999), le même fichier fait dire « held by cli pid 1048 », donc à l'application « L'index se met à jour — patientez… » avant chaque indexation manuelle, **pour toujours**. `inspect` est désormais une SONDE : `open(O_RDONLY)` sans `O_CREAT` — diagnostiquer ne crée rien —, puis `flock(LOCK_EX | LOCK_NB)`. S'il passe, le verrou est LIBRE et le nom lu est périmé : le fichier est tronqué **tant que la sonde tient le flock** (personne d'autre ne peut alors prendre le verrou, donc personne ne peut lire un nom qui ne vaut plus — même règle que `release()`), puis rendu. S'il rend `EWOULDBLOCK`, le verrou est réellement tenu et le nom lu est le bon (`.held`), ou ne vaut rien si le pid inscrit est mort (`.stale`). Coût : un `open` et deux `flock` ; le seul risque est de retarder de 50 ms au plus un acquéreur qui attendait pile à cet instant. `fouine doctor --json` publie `write_lock.probe` (`free` | `held`), le FAIT en deux valeurs à côté des trois de `status`. La barre de santé de l'application et `AppModel` s'appuient dessus sans changer un mot de leurs textes.

**Prudence de concurrence** : `THREADSAFE=2` (§3). Une connexion par fil, jamais une `sqlite3*` partagée. GRDB s'en charge si — et seulement si — on passe par son pool au lieu de garder une connexion dans une propriété.

### 5.2 FouineCrawl

Propriétaire : **A-Ingest**.

Résolution du volume par UUID : parcourir `FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeNameKey])` et comparer, en retenant le volume dont le point de montage est le **préfixe le plus long** du chemin, hors `/System/Volumes/{Preboot,VM,Update}`. **Jamais** par chemin de montage seul, **jamais** par `diskutil` (§2.3). Volume absent → `FouineError.volumeNotMounted`, exit 2, message nommant le label et l'UUID attendus.

**Lisibilité de la racine, avant tout le reste.** Ouvrir et lire réellement un fichier de la racine. `~/Documents` est protégé par TCC, `~/Livres` ne l'est pas : sans ce test, une racine s'indexe et l'autre reste vide **sans le moindre message** (§7.1). Échec → `FouineError.rootUnreadable`, exit 5.

Exclusions **obligatoires**, testées par T8 :

```
.DS_Store · .Trashes · .TemporaryItems · .fseventsd · .Spotlight-V100 · .git
tout composant commençant par "._"     ← AppleDouble : 0 occurrence sur APFS (mesuré),
                                          conservé pour le cas ExFAT de l'annexe A
$RECYCLE.BIN · System Volume Information · Thumbs.db · desktop.ini
tout composant terminant par ".pages" ou ".key" traité comme un FICHIER, jamais parcouru
   (ce sont des paquets ZIP/bundles ; 22 .pages dans le corpus voisin — §1)
```

Il n'y a plus aucune racine par défaut (palier 1, décision D1) : les racines s'ajoutent explicitement par `fouine root add` ou via l'application ; `fouine index` sans racine sort en code 5. `docs.top_folder` reçoit le **label de la racine** (ex. `Livres` ou `Cours`), pas le premier segment du chemin : sur un volume interne, ce premier segment vaut `Users` pour tout le monde et la facette « dossier » n'aurait aucun sens.

Détection de changement : triplet `(rel_path, size, mtime)`. **Ne jamais hacher le contenu** — non par coût d'E/S (le SSD hacherait 19 Go en ~20 s), mais parce que `size + mtime` suffit et qu'un hachage n'apporte rien qu'un `mtime` APFS à la nanoseconde ne donne déjà.

FSEvents : `FSEventStreamCreate` sur chaque racine, `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer`, latence 3 s. Persister `lastEventId` dans `volumes.fsevent_id` à chaque lot traité. Au redémarrage, rejouer depuis cet identifiant ; si l'historique a été purgé (`kFSEventStreamEventFlagHistoryDone` sans événements, ou identifiant invalide), basculer sur un crawl delta complet. **FSEvents sur `~/Documents` est soumis au même TCC que la lecture** : un flux qui ne renvoie jamais rien est un symptôme d'autorisation, pas d'inactivité.

Suppressions : un document dont le chemin n'existe plus après un crawl `--full` est retiré (`docs`, `page_fts` **par plage de rowid**, `page_src`, `ocr_layout`, `ocr_queue`).

> **Amendement du 04/09/2026 (A3-02, lot K6) — un renommage n'est pas une suppression.**
> La règle ci-dessus, appliquée telle quelle, faisait d'un `mv` une destruction :
> renommer un dossier purgeait `page_src`, `page_fts`, `ocr_layout`, `ocr_queue`
> et `page_vec` de tous ses documents, puis les redécouvrait vierges. Sur un
> dossier de livres scannés, cela vaut des heures d'OCR et de vectorisation.
>
> Le crawl délta rapproche donc, **avant la passe de suppression**, les chemins
> disparus et les chemins apparus. Un rapprochement exige les **trois** critères
> ensemble : même `inode`, même `size`, même `mtime`, sur le même volume. Il n'est
> tenté que si `inode != 0` — sur un volume qui ne garantit pas l'inode, l'ancien
> comportement s'applique intégralement. La source doit avoir **vraiment
> disparu** : si le chemin d'origine existe encore, c'est une copie, et le
> nouveau fichier devient un document neuf.
>
> Un rapprochement retenu écrit `UPDATE docs SET rel_path, top_folder, ext, inode`
> — et rien d'autre. Ni `page_src`, ni `page_fts`, ni `ocr_layout`, ni
> `ocr_queue`, ni `page_vec` ne sont touchés : ils sont indexés par `doc_id`, qui
> ne bouge pas. **Tout le lot passe en une transaction** (`IndexStore.relocateDocs`),
> avec une passe de garage intermédiaire pour que `UNIQUE(vol_uuid, rel_path)` ne
> voie jamais l'état transitoire d'un dossier renommé en profondeur.
> `CrawlSummary.moved` compte ces documents, à part de `added` et de `removed`.
>
> Les lignes écrites avant la v6 portent `inode = 0` : le premier crawl les
> renseigne par le même chemin d'écriture, **sans ré-extraction** (taille et
> mtime inchangés), et une seule fois.

> **Amendement du 10/09/2026 (C2-04, lot IX1) — « éteint » n'est jamais « disparu ».**
> La liste d'extensions du crawl est reconstruite à chaque passe depuis les
> réglages (`extract.images`, `extract.media`). Une passe lancée sans l'un des
> deux ne VOIT plus les fichiers de cette catégorie : elle les prenait donc pour
> des chemins disparus et les retirait, avec tout leur OCR. Mesuré : 16 images
> et 12 pages d'OCR (24,5 s de Vision) effacées par un seul `fouine index`. Et
> le piège se déclenche seul — l'agent d'arrière-plan lit la table `settings`,
> jamais la variable d'environnement d'un terminal, donc sa passe suivante
> détruisait ce que ce terminal venait de produire.
>
> La passe de suppression ne retire donc que les documents dont **l'extension
> est dans la liste courante**. Un document d'une catégorie éteinte reste en
> place, état inchangé, sans une écriture, et ne compte pas dans
> `CrawlSummary.removed`. Le retrait n'appartient qu'à un geste explicite
> (`fouine root remove --purge`) ou à un fichier vraiment disparu d'une
> catégorie allumée.

> **Amendement du 14/09/2026 (PM-01, lot IG1) — les exclusions de l'utilisateur, par racine, dans un fichier.**
> Les exclusions ci-dessus sont celles du PRODUIT : des nuisances, les mêmes
> pour tout le monde. Rien ne permettait à l'utilisateur d'en ajouter une — ni
> réglage, ni option — et tout ce qui est sous une racine était donc indexé,
> puis servi à tout assistant branché sur le serveur MCP.
>
> Un fichier `.fouineignore` à la RACINE d'un dossier suivi, **jamais plus bas**
> (une règle par racine, lisible d'un coup d'œil), porte une règle par ligne ;
> `#` ouvre un commentaire, les lignes vides sont ignorées, les chemins sont
> comparés en NFC, **la casse et les accents ne comptent pas** (comme APFS, et
> comme `chemin:`). Trois formes, et pas plus : `Dossier/` ou `A/B/` — un chemin
> relatif à la racine, sous-arbre entier ; le même sans `/` final — ce fichier
> ou ce dossier précis ; `*.ext`, `nom.ext` ou `*mot*` — un motif `fnmatch` sur
> le seul NOM, partout sous la racine. La négation (`!`) n'est **pas** prise en
> charge : la ligne est ignorée avec un avertissement au journal, parce qu'elle
> n'a de sens qu'avec un ordre d'évaluation qu'on ne veut pas avoir à expliquer.
>
> Le fichier est relu au DÉBUT DE CHAQUE PASSE (`IgnoreRules.load`) : un dossier
> exclu est sauté avec ses descendants et compté dans `CrawlSummary.skipped`, un
> fichier exclu n'entre pas dans `present`. Conséquence VOULUE : un document
> déjà indexé qui devient exclu est retiré par la passe de suppression
> existante, et `purgeDoc` emporte ses pages, son OCR et ses vecteurs. C'est ce
> qui rend l'exclusion effective à toutes les étapes sans que l'extraction,
> l'OCR et la vectorisation — qui ne voient que `docs` — aient à la connaître.
> Le contraire vaut aussi : la règle retirée, le document revient à la passe
> suivante. La sonde de lisibilité (`firstFile`) applique les mêmes règles : une
> racine dont tout le contenu lisible est exclu est VIDE, pas illisible. Le
> fichier lui-même est caché, donc jamais indexé, et son écriture remonte un
> événement FSEvents comme n'importe quelle autre (mesuré : 16 ms), donc la
> passe suivante part dans les secondes.
>
> Ce qui est INDEXÉ et ce qu'un assistant peut LIRE sont deux questions : la
> seconde est `fouine mcp --folders` (§12), qui restreint un serveur MCP à
> certaines racines sans rien retirer de l'index.

> **Amendement du 14/09/2026 (IG2, lot IG2) — les exclusions gardées par Fouine, à côté du fichier.**
> Le fichier `.fouineignore` demandait un terminal. **Décision du 14/09/2026**
> (orchestrateur, sur mandat du propriétaire) : l'application N'ÉCRIT PAS dans
> les dossiers de l'utilisateur — le corpus reste en lecture seule stricte
> partout. Les règles saisies dans l'app (Réglages ▸ Dossiers ▸ « Ce que Fouine
> ignore… ») ou par `fouine root ignore add|remove` sont donc gardées par
> Fouine, dans `roots.ignore_rules` : un texte JSON (`["Santé/","*.md"]`) ou
> NULL. **`Schema.version` ne change pas** : la colonne est dans `Schema.ddl`,
> et une base v9 d'avant la reçoit par `ALTER TABLE roots ADD COLUMN` à la
> PREMIÈRE règle enregistrée — pas à l'ouverture, qui n'écrit toujours rien ;
> les lectures, lecture seule comprise, tolèrent son absence. L'écriture ne
> prend pas `fouine.lock` (même régime que `settings`) : aucune passe n'écrit
> la colonne, et l'agent tient ce verrou tout un lot d'OCR.
>
> Le crawl applique l'UNION des deux sources (`IgnoreRules.load(root:stored:)`),
> compilées par le même code : mêmes trois formes, même sémantique, même
> repli casse et accents, et aucune priorité à expliquer puisque la négation
> n'existe dans aucune. Une règle présente dans les deux ne compte qu'une fois.
> Différence voulue : une règle GARDÉE est validée à la saisie — `!`, `#` en
> tête, plusieurs lignes, un chemin à partie vide, `.` ou `..` sont refusés
> avec une phrase (sortie 64 en CLI) et jamais stockés ; le fichier, déjà
> écrit, ne peut qu'avertir. Relue tolérante, comme le fichier : un texte
> abîmé n'applique rien et le dit au journal.
>
> Le prix, assumé : une règle gardée part avec sa racine (`root remove --purge`
> supprime la ligne ; désactiver la garde), là où le fichier suit le dossier.
> Le fichier reste la voie des dossiers partagés et des utilisateurs avancés,
> l'app celle de tout le monde. Parce qu'enregistrer une règle ne remonte aucun
> événement FSEvents, l'agent relit les règles gardées de toutes les racines à
> chaque tic (une requête) et reparcourt celles qui ont changé ; à son
> démarrage, toutes celles qui en portent. `fouine root list` publie
> `ignore_rules` (l'union) et `ignore_rule_list` (chaque règle et sa source,
> `file` ou `settings`).

> **Amendement du 08/09/2026 (INT-F4, lot F4) — les sources applicatives sont des racines comme les autres.**
> Apple Notes et Bear ne rangent pas des fichiers : leurs notes vivent dans une
> base SQLite sous `~/Library/Group Containers/`, hors de tout crawl. Fouine ne
> leur ouvre PAS un second chemin d'indexation. Elle lit ces bases en **lecture
> seule stricte** (`sqlite3_open_v2` en `SQLITE_OPEN_READONLY`, URI
> `?mode=ro&immutable=1` : jamais une écriture, jamais le `-wal` d'une
> application vivante) et **matérialise** chaque note en un fichier Markdown
> sous `~/Library/Application Support/Fouine/Sources/<App>/`, dont le `mtime`
> est celui de la note et dont le corps porte le titre (`# Titre`) — Fouine
> n'indexant pas les noms de fichiers (§5.3 (e)). Ce dossier est enregistré
> comme une racine ordinaire (« Notes », « Bear ») et suit ensuite le chemin de
> tout le monde : crawl delta, extraction, `page_fts`, facettes, Spotlight.
>
> La matérialisation a lieu **au début de toute passe qui parcourt**
> (`IndexPass.run`), avant le crawl, et seulement si `sources.notes` ou
> `sources.bear` est vrai — deux lectures de booléen sinon. Aucune erreur n'y
> est fatale : une base refusée par TCC, une application désinstallée ou un
> schéma changé par une mise à jour de macOS deviennent une note de journal.
>
> `RootPolicy` continue de REFUSER `~/Library` à un geste d'utilisateur : ce
> dossier-ci n'est pas choisi, il est fabriqué par Fouine, qui en connaît le
> contenu au fichier près, et il est enregistré directement par `addRoot`. Le
> crawl n'exclut que `~/Library` **exactement** (`CrawlExclusions.isHomeLibrary`)
> : un dossier situé dessous et désigné comme racine se parcourt normalement.
>
> Éteindre une source retire la racine avec son index **et** efface les
> fichiers : laisser des copies de notes personnelles derrière ferait de la
> désactivation un demi-geste. Notion et Craft ne se lisant pas localement de
> façon fiable, ils passent par leurs **exports** (dossier Markdown ou HTML
> désigné comme racine) ; seul le lien de réouverture d'une page Notion est
> reconstruit, depuis l'identifiant que Notion colle au nom du fichier.

> **Amendement du 14/09/2026 (AN1, lot AN1) — Anki, troisième source applicative.**
> Les cartes d'Anki suivent le chemin ci-dessus (clé `sources.anki`, éteinte par
> défaut, racine « Anki »), avec trois écarts, chacun mesuré.
>
> *Lecture sur copie, et non `immutable=1`.* Anki écrit en WAL sans `-shm` et ne
> replie pas son journal tant qu'il reste ouvert : le 14/09/2026, sur la
> collection du propriétaire, Anki ouvert, `immutable=1` lisait 3 235 notes et la
> base en portait 3 359 — deux jours de cartes n'existaient que dans
> `collection.anki2-wal`. Une ouverture `mode=ro` directe les lit, mais crée un
> `-shm` à côté de la collection. `AnkiSource` clone donc le WAL PUIS la base
> dans un dossier temporaire à lui, recommence si l'un a changé pendant la copie
> (trois essais), et ouvre la copie en `mode=ro` sans `immutable`
> (`SQLiteReader.Access.privateCopy`). Rien n'est jamais écrit dans le dossier
> d'Anki, qui peut rester ouvert. Chaque profil de
> `~/Library/Application Support/Anki2/` est lu ; le schéma 11 (paquets en JSON
> dans `col.decks`) comme les schémas ≥ 15 (table `decks`, niveaux séparés par
> U+001F).
>
> *Un fichier par paquet, une page par note.* Une carte fait 250 caractères en
> moyenne (3 359 notes, 42 paquets) : un fichier par note ferait de chaque
> résultat un document d'une ligne, et quarante cartes rempliraient l'écran
> devant les cours. Un paquet-document montre « 3 pages sur 42 · Les voir
> toutes » et tombe sous la règle de diversité. L'arborescence `::` devient celle
> des dossiers (`SourceNote.relativePath`, revérifié composant par composant par
> `SourceMaterializer`, qui efface aussi les dossiers vidés et compare les noms
> sans casse, comme le disque) ; au-delà de 2 000 notes, un paquet se découpe en
> volumes (« Paquet (2).md ») pour rester sous `maxSplitPages`. Les pages sont
> séparées par U+000C, que `PlainTextExtractor` n'honore QUE dans un fichier dont
> la première ligne porte `fouine-source:` (`MaterializedText`) : aucun autre
> fichier ne change de pagination.
>
> *Texte.* Trous résolus sur leur réponse (l'indice tombe), masques d'occlusion
> d'image, `[sound:…]` et balises `[latex]`/`[$]` retirés, HTML dépouillé par
> l'extracteur. Ni noms de champs ni étiquettes : « Recto », « Texte » ou
> `lot::2026-09-14` reviendraient sur chaque page. Une carte sans texte (une
> image seule) n'est pas recopiée. Les images d'une carte sont NOMMÉES à la suite
> de son texte (`<!-- fouine-image: nom -->`, une ligne chacune) ;
> `MaterializedText.pages` les retire du texte indexé et les rattache à la
> première page de la carte, et l'aperçu les relit dans le fichier par la même
> fonction pour les montrer depuis `collection.media`. Aucune reconnaissance de
> texte ne tourne sur elles : sur la collection mesurée, 2 937 notes sur 3 359
> portent une image, surtout des captures de pages de cours déjà indexées en PDF,
> et `extract.images` y est allumé — l'y soumettre doublerait ces pages dans les
> résultats. Le fichier ne porte pas de `fouine-open:` :
> Anki pour Mac n'a pas de lien vers une note, l'aperçu ouvre l'application
> retrouvée par son identifiant de paquet (`net.ankiweb.anki`, puis
> `net.ankiweb.dtop`), jamais par un chemin lu dans le fichier.
>
> Les `.apkg` et `.colpkg` rangés dans un dossier ne sont PAS lus : depuis
> Anki 2.1.50, un export porte `collection.anki21b`, compressé en zstd (vérifié
> sur une sauvegarde du 14/09/2026 : octets `28 B5 2F FD`, à côté d'un
> `collection.anki2` de 51 Kio qui n'est qu'un bouchon pour les vieilles
> versions), que ni macOS ni les trois dépendances du §2.2 ne savent ouvrir.

> **Amendement du 14/09/2026 (RP1) — le dossier d'une application lue est
> refusé en la nommant.** Le propriétaire a choisi
> `~/Library/Application Support/Anki2/<profil>` avec « Ajouter un dossier… »
> pour retrouver ses cartes, et l'app a répondu « “~/Library” est un dossier
> système : il ne contient pas de documents à indexer » — un refus juste, une
> phrase fausse, et aucun chemin vers la case « Anki ». `RootPolicy.Refusal`
> gagne un neuvième cas, `.applicationData(path:application:)`, rendu pour le
> dossier de données d'Anki (`Application Support/Anki2`), d'Apple Notes
> (`Group Containers/group.com.apple.notes`) ou de Bear (`Group
> Containers/9K33E3U3T4.net.shinyfrog.bear`), et pour tout ce qui est dessous ;
> il est testé AVANT les arbres système qui les contiennent. Le dossier reste
> refusé : ses fichiers sont des bases SQLite, et la source applicative les lit
> déjà. L'app dit, sans chemin, de cocher l'application dans Réglages ▸
> Dossiers ▸ Applications, et son alerte porte « Ouvrir les Réglages » sur cet
> onglet ; `fouine root add` sort toujours en 64 et nomme `fouine sources
> enable <id>`. `RootPolicy.Application` (FouineCrawl, qui ne voit pas
> FouineIndex) recopie les identifiants des sources ; `AppSourcesTests`
> compare les deux listes et leurs dossiers.

> **Amendement du 14/09/2026 (AN2) — une copie se montre comme dans son
> application, et se reconnaît à son emplacement.** Capture du propriétaire à
> l'appui, les paquets Anki paraissaient comme les fichiers qu'ils sont sur le
> disque : « 625 Physico-chimie macromoléculaire.md » sous « Library/Application
> Support/Fouine/… », « p. 1 », « 74 p. », une icône de Markdown, un mode
> « Document » qui dessinait le fichier brut, et l'extrait de la première carte
> ouvert sur « …anki --> ». Quatre décisions.
>
> *L'emplacement décide.* `SourceDocumentLocator` (FouineIndex, pur) reconnaît
> une copie à son chemin — `<Sources>/<Notes|Bear|Anki>/…/x.md`, relatif au
> volume comme `docs.rel_path` — et rend `SourceDocument` : la source, le titre
> (nom du paquet ; pour Notes et Bear, le nom du fichier sans son suffixe
> d'identifiant, `AppSource.documentTitle`) et les paquets parents. Ce qu'un
> fichier écrit en tête ne fait plus reconnaître personne : un `.md` d'une
> racine ordinaire qui se déclarait `fouine-source: notes` obtenait un bouton
> ouvrant son `fouine-open:`, quel qu'il soit (rapport AN1, § 5). Le lien d'une
> note est désormais relu dans la tête de SON fichier, et doit être du schéma
> de son application (`notes:`, `bear:`).
>
> *L'app ne montre plus le fichier.* Partout où un document se nomme — liste,
> aperçu, fenêtre détachée, « Tous vos documents », barre des menus, citation,
> export, Raccourcis, Spotlight —, une copie prend le nom de sa note ou de son
> paquet, son fil d'Ariane (« Anki › M2SU 2026 ») à la place du chemin, et
> l'icône de son application, lue chez LaunchServices par identifiant de paquet
> (`AppSource.bundleIdentifiers` ; aucun logo embarqué). Un paquet compte,
> feuillette et cite des CARTES (une carte par page, `MaterializedText` ; une
> carte de plus de 4 000 caractères en occuperait deux — 0 sur 3 352 mesurées,
> la plus longue fait 2 885 caractères). L'aperçu d'une copie est le texte seul ;
> Coup d'œil, glisser-déposer, « Afficher dans le Finder » et « Ouvrir » cèdent
> la place à « Ouvrir dans Anki / Notes / Bear », sans repli vers le Finder. Le
> dossier d'une application porte son icône dans la barre latérale et les
> Réglages, et n'y offre plus ni Finder, ni renommage (`SourceSync` retrouve sa
> racine par l'étiquette), ni retrait (la passe suivante la recréerait) : son
> menu mène à la rubrique Applications.
>
> *L'en-tête n'est plus du texte.* `MaterializedText.pages` retire les lignes
> `fouine-source:` / `fouine-open:` de tête avant de paginer : indexées, elles
> faisaient répondre la page 1 de chaque copie à « anki », « source »,
> « fouine ». Le fichier les garde (pagination par U+000C, lien de réouverture).
>
> *Le nom d'un paquet n'est plus au-dessus de sa première carte*
> (`SourceNote.titleInText`, faux pour Anki) : chacun de ses mots faisait
> répondre cette carte, et le paquet se trouve par son nom (« documents dont le
> nom contient »). Une note garde son `# Titre` : Fouine n'indexe pas les noms
> de fichiers, et le titre d'une note se cherche. Les paquets déjà recopiés
> changent de taille, donc sont réécrits puis relus à la passe suivante.

> **Amendement du 08/09/2026 (INT-F1, lot F1) — dossiers de construction et
> paquet `Nom.mbox/`.**
> Le code source entre dans l'index (§5.3) ; sans garde-fou, des arbres de
> projets entiers entreraient avec lui. Un dossier nommé `dist`, `build`,
> `out`, `target`, `.next`, `.nuxt`, `coverage`, `vendor`, `bower_components`,
> `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.dart_tool`, `.terraform`,
> `site-packages` ou `__snapshots__` est donc exclu **quand son dossier parent
> porte un marqueur de projet** — `package.json`, `Cargo.toml`, `pom.xml`,
> `build.gradle[.kts]`, `pyproject.toml`, `setup.py`, `go.mod`,
> `Package.swift`, `Gemfile`, `composer.json`, `.git` — et **seulement** dans
> ce cas : `~/Documents/Maison/build` est un dossier de documents, et le faire
> disparaître serait incompréhensible. La décision est pure
> (`CrawlExclusions.isExcludedBuildFolder(component:parentContainsProjectMarker:)`) ;
> le crawler la nourrit d'un `contentsOfDirectory` par dossier parent, mémorisé,
> et seulement pour les noms qui peuvent être des sorties de construction.
>
> `Nom.mbox/` rejoint par ailleurs les paquets-documents (`rtfd`, `pages`,
> `numbers`, `key`) : « Exporter la boîte aux lettres » d'Apple Mail rend un
> dossier, et c'est UNE boîte aux lettres, donc UN document.

> **Amendement du 04/09/2026 (A3-10, lot K6) — chemins en NFC.**
> Le `rel_path` fabriqué par le crawler est ramené en forme Unicode NFC
> (`RelPath.normalized`), comme celui que `root add` résout. L'énumérateur de
> FileManager rend historiquement du NFD ; `docs.rel_path` se compare en SQLite
> par égalité d'octets, et les deux formes ne se retrouvent pas l'une l'autre.

> **Amendement du 04/09/2026 (A3-03, lot K6) — `HistoryDone` n'est pas un symptôme.**
> Le paragraphe FSEvents ci-dessus fait de « `kFSEventStreamEventFlagHistoryDone`
> sans événements » un signe d'historique purgé. **C'est faux, et mesuré comme
> tel** : avec un curseur valide et un disque au repos — le démarrage ordinaire
> d'un agent, plusieurs fois par jour —, FSEvents livre exactement cette salve.
> Fouine relançait donc un crawl delta complet de toutes les racines à chaque
> ouverture de session ou sortie de veille.
>
> Une perte d'historique RÉELLE est signalée par un drapeau — `MustScanSubDirs`,
> `UserDropped`, `KernelDropped`, `EventIdsWrapped` —, déjà traité par
> `FSEventsWatcher.requiresFullDelta(flags:)` ; un identifiant invalide (plus
> récent que celui du système) est intercepté dans `start()` et force le
> parcours. Le repli sur « HistoryDone seul » disparaît, avec l'état
> (`resuming`, `sawFileEvents`) qu'il était seul à porter.

### 5.3 FouineExtract

Propriétaire : **A-Ingest**.

| Extensions | Méthode |
|---|---|
| `pdf` | PDFKit : `PDFDocument` → `PDFPage.string` par page. **Réouvrir le `PDFDocument` toutes les 100 pages** (D2). `PDFDocument(url:) == nil` → `FouineError.extraction`, `state = .failed` |
| `doc` `rtf` `rtfd` | `NSAttributedString(url:options:documentAttributes:)` — sûr et irremplaçable sur ces trois-là (vérifié : `NSDocFormat` 3 489 car., `NSRTF` accents corrects) |
| `docx` `odt` | `bsdtar` + `XMLParser` en mode SAX sur `word/document.xml` / `content.xml`. `NSAttributedString` fonctionne aussi (mesuré 4 907 car. sur un `.docx` réel) mais le SAX est sans surprise et sans thread principal |
| `html` `htm` `webarchive` | **sérialiser sur le thread principal**, ou parser à la main. Mesuré ici : l'import `NSHTML` a rendu 18 020 caractères en 2,74 s depuis un fil de fond sans blocage — mais ce comportement n'est pas documenté-supporté, et le pipeline `--jobs N` n'a pas de run loop. 1 seul fichier concerné dans le corpus : ne pas y consacrer une architecture |
| `txt` `md` `csv` `tex` `json` `log` | lecture directe ; UTF-8, repli ISO-8859-1 puis `String.Encoding.macOSRoman` |
| `xlsx` `pptx` | `bsdtar -xOf` + parse XML (`xl/sharedStrings.xml`, `xl/worksheets/sheet*.xml`, `ppt/slides/slide*.xml`). **Obligatoire** : `NSAttributedString` rend **0 caractère sans erreur** sur ces deux formats (mesuré) |
| `xls` `ppt` | **`.skipped` d'office**, `err = "format binaire OLE non pris en charge"`. Mesuré : un `.ppt` binaire passé à `NSAttributedString` rend `type = NSPlainText` et **316 411 caractères de mojibake** sans lever la moindre erreur (`–œ‡°±· ˛ˇ ˛ˇˇˇ ^ _ a`). Il n'y a pas d'échec à détecter : il y a un faux succès. 2 fichiers concernés |
| `epub` | zip → XHTML dans l'ordre de l'`spine`, **puis `pageSplitChars` À L'INTÉRIEUR de chaque fichier du spine** : un seul XHTML peut porter un livre entier, et « une page = un fichier XHTML » ferait alors exploser `NEAR` et `snippet()` |
| `cbz` `cbr` | `bsdtar` (libarchive lit ZIP et RAR v4, vérifié sur fichiers réels) → images triées → **toutes les pages en file OCR, priorité 3**. 34 archives, **5 291 images** (mesuré) |
| `djvu` | `ddjvu` absent → `.skipped`, `err = "djvu: djvulibre absent"`. 5 fichiers. Détecter `ddjvu`/`djvutxt` dans le `PATH` et s'en servir s'il apparaît un jour : 6 lignes, aucune dépendance embarquée |
| `pages` `numbers` `key` | paquet ou zip → `QuickLook/Preview.pdf` délégué à `PDFExtractor` (amendement 03/09/2026) |

*Amendement du 03/09/2026 (audit E4, D2 § 5.12 — iWork et images seules) :*
*(a) Documents iWork (`pages`, `numbers`, `key`) : pris en charge comme des documents uniques (paquet-répertoire ou archive ZIP). L'extraction délègue au fichier interne `QuickLook/Preview.pdf` via `PDFExtractor` (borné par `Deadline`). En l'absence de `Preview.pdf`, le document est marqué en échec explicite dans `docs.err` (« iWork document without a QuickLook preview — open it once in Pages to generate one »). Le crawler ne descend jamais à l'intérieur des paquets iWork (recette T8).*
*(b) Images seules (`png`, `jpg`, `jpeg`, `heic`, `tif`, `tiff`) : activables derrière le réglage booléen `extract.images` (désactivé par défaut, variable `FOUINE_EXTRACT_IMAGES`). Chaque image valide produit 0 caractère de texte natif, 1 page, et s'inscrit en file d'OCR (100 % `ocrAccurate`). Deux garde-fous écartent les bruits : plancher de taille de fichier (< 64 Kio) et plancher de dimensions (< 300 px de côté), refusés avec `docs.state = skipped` et `docs.err = "image below the OCR size floor"`.*

> **Amendement du 15/09/2026 (DF1, version 1.0.1) — images, sons et vidéos, et transcription allumés par défaut.** Les trois réglages `extract.images`, `extract.media` et `extract.transcribe` passent à **vrai** par défaut (décision du propriétaire, 15/09/2026) : la réserve d'origine — une bibliothèque musicale n'est pas un fonds documentaire, une image passe par l'OCR — reste vraie, mais elle se règle en décochant la case de Réglages ▸ Indexation, pas en cachant trois familles derrière un réglage éteint que le public visé ne trouve pas. Rien ne change pour une valeur déjà écrite dans `settings` : le défaut ne vaut qu'en l'absence de ligne. La recette d'intégration fige les trois variables d'environnement à `false` (`IntegrationSupport.run`), parce que le corpus versionné est compté sans images ni médias (`pieges/photo.png`, fixtures médias hors manifeste). Le premier média transcrit déclenche la demande d'autorisation « Reconnaissance vocale » de macOS, comme avant quand on cochait la case.

> **Amendement du 05/09/2026 (R-13, R-14, lot G1).**
> (a) **Notes de bas de page et de fin DOCX** (R-13) : `word/document.xml`, `word/footnotes.xml` et `word/endnotes.xml` sont extraits en une seule invocation de `bsdtar` (A11.6). Le texte des notes est extrait par le même parseur SAX (`XMLTextCollector`) et ajouté à la suite du corps, séparé par une ligne vide, sous le plafond `TextBudget` (qui coupe les notes avant le corps en cas de budget restreint). Les séparateurs Word (`w:separator`, `w:continuationSeparator`) ne produisent aucun texte.
> (b) **Sous-titres `.srt` et `.vtt`** (R-14) : nouvel extracteur `SubtitleExtractor`. Décodage via `PlainTextExtractor.decode`, extraction du texte des répliques uniquement : numéros de réplique, horodatages, en-tête `WEBVTT`, blocs `NOTE`, réglages de position et balises (`<i>`, `<c.yellow>`, `{\an8}`) sont éliminés ; entités HTML décodées. Une réplique = une ligne ; répliques identiques consécutives fusionnées ; pagination à `pageSplitChars`. Fichier vide refusé en erreur d'extraction nommée.
> (c) **Carnets Jupyter `.ipynb`** (R-14) : nouvel extracteur `NotebookExtractor`. Analyse JSON souple (`JSONSerialization`) ; cellules `markdown`, `code` et `raw` extraites dans l'ordre ; code source des cellules conservé ; sorties de cellules (`outputs`) ignorées (volumineuses et redondantes) ; pagination à `pageSplitChars`. Tout fichier non JSON ou sans tableau `cells` est rejeté en erreur d'extraction nommée.

> **Amendement du 08/09/2026 (INT-F1, lot F1) — trois familles de formats.**
>
> (a) **`xls` et `ppt` ne sont plus refusés d'office.** La ligne « `.skipped`
> d'office » ci-dessus reste vraie sur son constat — `NSAttributedString` rend
> `NSPlainText` et 316 411 caractères de mojibake sur un `.ppt` binaire, et ne
> doit jamais être appelé sur ces formats — mais sa conclusion est remplacée :
> Fouine lit désormais le conteneur OLE elle-même (`Support/CompoundFile` :
> en-tête, FAT, DIFAT, mini-FAT, répertoire, chaînes de secteurs bornées, refus
> nommés), puis le contenu. `xls` : flux `Workbook` (ou `Book` en BIFF5),
> enregistrements `BOUNDSHEET`, `SST` (avec ses `CONTINUE` et le drapeau de
> compression redéclaré à chaque bloc), `LABELSST`, `LABEL`, `NUMBER`, `RK`,
> `MULRK`, et le résultat texte d'une `FORMULA` — **une page par feuille**,
> cellules en ordre ligne puis colonne, tabulation entre cellules. `ppt` : flux
> `PowerPoint Document`, conteneurs `SlideListWithText` (frontières par
> `SlidePersistAtom`, repli sur les conteneurs `Slide`), atomes `TextCharsAtom`,
> `TextBytesAtom` et `CString` — **une page par diapositive**, les notes du
> présentateur rattachées à leur diapositive. Le contrôle de plausibilité
> ci-dessous s'applique page par page : une page qui ne le passe pas n'est pas
> émise. Restent refusés, `skipped` et NOMMÉS : un classeur chiffré
> (`FILEPASS` → « password-protected workbook »), une présentation chiffrée
> (`CryptSession10Container` → « password-protected presentation »), un
> conteneur OLE sans flux de classeur ni de présentation. Les images du flux
> `Pictures` d'un `.ppt` ne partent pas en OCR (les médias des `.pptx`, si).
>
> (b) **Courriels hors `.eml`.** `emlx` (Apple Mail : compteur d'octets en
> première ligne, message, liste de propriétés de drapeaux — les deux
> enveloppes sont écartées ; un fichier sans compteur est lu comme un `.eml`),
> `olk15MsgSource` (Outlook 15/2016, RFC 822 brut) et `mbox`. Un `mbox` est
> découpé sur les lignes qui **commencent** par « From » — un `>From ` de
> citation (mboxo/mboxrd) n'est pas une frontière —, **une page par message**,
> `meta.messages` = leur nombre ; un fichier qui n'est ni une boîte ni un
> message RFC 822 est `skipped` (« not a mailbox »). Un DOSSIER `Nom.mbox/` est
> un paquet-document (§5.2) : son fichier `mbox` s'il en a un, sinon ses
> `Messages/*.emlx` triés naturellement.
>
> (c) **Fichiers techniques.** 68 extensions de code source, de script et de
> configuration passent par `PlainTextExtractor` ; `xml`, `xsd`, `xsl`, `xslt`,
> `svg` et `plist` par un `XMLDocumentExtractor` (texte des nœuds par SAX,
> attributs ignorés, repli sur le texte brut si le document est mal formé,
> `plist` binaire décodé en « clé : valeur »). Deux refus nommés, tous deux
> `skipped` : **source minifiée** (nom en `.min.js` / `.min.css`, ou ligne
> moyenne de plus de 1 000 caractères — critère appliqué aux seules extensions
> techniques, un `.log` tenant légitimement sur une ligne) et **document XML
> sans texte** (« no text »). `DefaultExtractorRegistry.supportedExtensions`
> est désormais CALCULÉ comme l'union des extracteurs, et compte 110
> extensions.

> **Amendement du 10/09/2026 (EX1, C2-15, lot EX1) — les pièces jointes des
> courriels.**
>
> Un `.eml` (`.emlx`, `.olk15MsgSource`) n'indexe plus seulement ses en-têtes et
> son corps : **ses pièces jointes deviennent des pages du même document**,
> numérotées APRÈS le corps et dans l'ordre des parties, comme les médias
> embarqués d'un `.docx`. Une partie est une pièce jointe si son
> `Content-Disposition` porte `attachment`, ou si son `Content-Type` n'est ni
> `text/*` ni `multipart/*` et qu'elle porte un `name=` / `filename=` ; un NOM
> est indispensable (c'est l'extension qui décide de l'extracteur), une partie
> anonyme reste traitée comme avant. La pièce est décodée (base64,
> quoted-printable, 7/8bit) et déposée dans `<tmp>/fouine-eml-<uuid>/<rang>/<nom
> nettoyé>` — jamais de `/`, de `..`, ni de caractère de contrôle, 120 octets au
> plus, extension conservée, un sous-dossier par pièce (deux pièces homonymes ne
> s'écrasent pas) —, puis passée à `ExtractorRegistry.extract(url:limits:)`. Le
> dossier disparaît en `defer`, succès ou erreur. La première page de chaque
> pièce commence par une ligne portant le **nom du fichier**, seul, sans libellé
> traduit. Une pièce dont l'extraction échoue ne fait PAS échouer le courriel :
> le corps reste indexé, la pièce est nommée dans `meta.attachments_skipped`
> (`meta.attachments` compte celles qui ont été lues).
>
> **Bornes.** Dix pièces par courriel (les suivantes comptées dans la note) ;
> une pièce de plus de `maxFileBytes` ignorée ; le texte des pièces passe par le
> budget `maxTextBytes` DU COURRIEL ; le nombre de pages reste borné par
> `maxSplitPages` (le courriel est un format re-paginé). **Exclusions** : les
> archives (`zip`, `cbz`, `cbr`, `rar`, `7z`, `tar`…) ne sont jamais ouvertes
> depuis un courriel (décision du lot SI1) — les conteneurs identifiés (`docx`,
> `xlsx`, `epub`…) le restent ; les sons, les vidéos et les **images** sont
> ignorés (une image jointe ne vaudrait que par l'OCR, et le rendu de page ne
> sait pas produire l'image d'une page de courriel : la mettre en file ne
> donnerait qu'un échec nommé) ; aucune page de pièce n'est mise en file OCR.
> Un courriel joint (`message/rfc822`, ou une pièce d'extension `.eml`,
> `.emlx`, `.olk15MsgSource`, `.mbox`) est rendu DANS le processus, en-têtes et
> corps, sans fichier temporaire, et **ses** pièces ne sont pas suivies : une
> profondeur, pas deux. Les pièces des messages d'un `mbox` ne sont pas lues
> (mille courriels exportés × dix pièces = dix mille pages extraites une à une).
>
> **Seuil OCR à zéro pour les pièces.** Le seuil des 100 caractères du §6.1 ne
> jette pas le texte d'une page pauvre : il le laisse à l'OCR. Une pièce jointe
> n'ayant pas d'OCR, le laisser reviendrait à le perdre — mesuré sur le courriel
> du constat C2-15, dont la facture porte 46 caractères. La règle « jamais une
> page à texte natif en file OCR » est inchangée.

> **Amendement du 08/09/2026 (INT-F2, lot F2) — images étendues, Adobe,
> maquettes.**
>
> (a) **Images seules, liste élargie.** Le principe de l'amendement du
> 03/09/2026 (b) ne change pas — une image = 0 texte natif, 1 page, en file
> d'OCR, sous le seul réglage `extract.images`, avec les deux planchers
> (64 Kio, 300 px). S'ajoutent aux six extensions d'origine : `heif`, `avif`,
> `webp`, `gif`, `bmp`, `psd` et les RAW d'appareil photo `cr2`, `nef`, `raf`,
> `dng`, `arw`, `rw2`, `orf` — dix-neuf en tout. Les dix-neuf sont décodables
> par ImageIO sur macOS 15 (vérifié par `CGImageSourceCopyTypeIdentifiers()`) ;
> sur une machine plus ancienne, un type manquant se refuse sur le motif nommé
> « unreadable image ». Un GIF **animé** vaut sa première image, jamais une page
> par vignette. Un RAW ne se développe PAS (`CIRAWFilter` : des secondes par
> image pour une couleur dont Vision n'a que faire) — sa vignette intégrée est
> rendue comme les autres, à 4 096 px. `FouinePageRenderer` et l'aperçu de
> l'app prennent cette liste à l'extracteur au lieu d'en tenir une copie.
>
> (b) **Illustrator `.ai`.** Un `.ai` enregistré avec « Créer un fichier
> compatible PDF » (par défaut depuis Illustrator 9) EST un PDF : reniflage de
> « %PDF- » dans les 1 024 premiers octets, puis délégation à `PDFExtractor`.
> Quand un en-tête `%!PS-Adobe` précède la couche PDF, celle-ci est recopiée
> dans un fichier temporaire (le fichier de l'utilisateur n'est jamais
> modifié). Sans couche PDF : `skipped`, `err = "ai: no PDF layer — save with
> “Create PDF Compatible File”"`.
>
> (c) **Sketch `.sketch`.** ZIP de JSON. `document.json` donne l'ordre des
> pages, chaque `pages/<uuid>.json` est extrait sans déballer l'archive
> (`bsdtar -xOf`, entrées demandées en une invocation). **Une page Sketch = une
> page Fouine** ; son texte est le nom de la page, puis les noms des planches
> (`artboard`, `symbolMaster`), puis les calques `text`
> (`attributedString.string`, à défaut leur `name`), une ligne chacun, sous
> `TextBudget`. Profondeur de parcours bornée à 64. L'aperçu
> `previews/preview.png` devient une page à OCRiser — la DERNIÈRE — sous
> `extract.images` seulement. Archive sans `document.json` : `skipped`,
> `err = "sketch: no document.json — not a Sketch file"`.
>
> (d) **Figma `.fig` et InDesign `.indd` : l'aperçu, rien d'autre.** Le canevas
> Figma est un binaire « kiwi » ni documenté ni stable, le texte InDesign est
> dans un conteneur propriétaire : **aucun des deux n'est analysé**. Sous
> `extract.images`, une page à OCRiser est produite depuis `thumbnail.png`
> (`.fig`, qui est un ZIP) ou depuis la première image PNG/JPEG intégrée dans
> les 2 Mio de tête (`.indd`) — une signature qui ne décode pas ne compte pas.
> Sinon, `skipped` et NOMMÉ : `"fig: no text layer readable — export the frames
> as PDF or SVG"`, `"indd: no readable text — export as PDF or IDML"`. Ces
> quatre refus rejoignent `ExtractOutcome.skippedReasons`.
>
> (e) **Ce que ces refus ne font PAS.** Fouine n'indexe pas les noms de
> fichiers (mesuré le 08/09/2026 : `fouine search dessin` ne trouve pas
> `dessin.ai`, pourtant extrait). Un document sans page ne ressort donc
> d'aucune recherche : le motif nommé, lu dans la carte « documents illisibles »
> de l'app et dans `docs.err`, est sa seule trace.
>
> `DefaultExtractorRegistry.supportedExtensions` compte désormais **114**
> extensions (`ai`, `sketch`, `fig`, `indd` s'ajoutent aux 110), et
> `imageExtensions` — hors de cette union, active sous `extract.images` — en
> compte 19.

> **Amendement du 10/09/2026 (PR-02, lot MP1) — un CANAL pour les noms de
> fichier, à côté des pages.** Le (e) ci-dessus reste vrai de l'INDEX — aucun
> nom de fichier n'entre dans `page_fts` — mais il ne décrit plus ce que la
> recherche RÉPOND. La table `docs_fts` (schéma v8) porte, par document, le nom
> du fichier et celui de son dossier parent (`Schema.documentIndexName`) ; elle
> ne servait que de bonus de classement (CTE `dn`, à partir de deux mots), si
> bien qu'un document dont SEUL le nom répondait ne pouvait pas entrer dans le
> jeu de résultats. Mesuré le 09/09/2026 sur la base de production : `fouine
> search IP2022` rendait sept pages sans rapport alors que trois fichiers
> s'appellent `IP2022__Analyse_JB_LIVRABLE_…` — le serveur MCP les trouvait par
> `path_contains` en 39 ms, l'utilisateur pas du tout.
>
> `GRDBStore.documentsMatchingName(_:limit:)` lit ces documents par une requête
> DISTINCTE et courte (mesuré : `IP2022` 204 → 173 ms au total, aucun surcoût
> mesurable sur `energie` ni `polymere`), et `SearchResults.nameMatches`
> (`[DocumentListing]`, clé ADDITIVE, cinq au plus, première tranche seulement)
> les transporte. Ils ne modifient NI l'ordre des pages, NI `totalPages`, NI
> `totalDocs` : un nom ne désigne aucune page, et les mélanger annoncerait des
> pages qui n'ont pas été trouvées. Le canal ne s'arme qu'à partir d'un mot de
> trois caractères, applique les filtres `dossier:`/`ext:`/`--in`, décline les
> mots comme la sonde `dn` (morphologie), et écarte les documents que seul le
> DOSSIER PARENT faisait répondre — la phrase affichée parle du nom du fichier.
> Surfaces : bandeau au-dessus des résultats dans l'application (chaque nom
> ouvre la page 1), ligne d'en-tête `N document(s) whose name matches: …` et clé
> `name_matches` en CLI, clé `name_matches` (toujours présente, vide si rien)
> dans `fouine_search`. AUCUN changement de schéma.

> **Amendement du 08/09/2026 (INT-F3, lot F3) — sons et vidéos, en deux
> étages.**
>
> (a) **Une famille de plus, hors de l'union, sous son propre interrupteur.**
> `MediaExtractor.supportedExtensions` — douze extensions de son (`mp3` `m4a`
> `m4b` `aac` `wav` `aiff` `aif` `flac` `caf` `ogg` `oga` `opus`) et sept de
> vidéo (`mp4` `m4v` `mov` `avi` `mkv` `wmv` `webm`) — vit dans
> `DefaultExtractorRegistry.mediaExtensions`, **hors** de
> `supportedExtensions`, exactement comme `imageExtensions`. Elle n'est
> inscrite au registre et ramassée par le crawler que sous `extract.media`
> (booléen, `false`, `FOUINE_EXTRACT_MEDIA`) : une bibliothèque musicale de
> 20 000 titres n'est pas un fonds documentaire.
>
> (b) **Étage 1, les métadonnées, toujours.** `AVURLAsset` : titre, artiste
> (ou `contributor`, sous lequel QuickTime range l'interprète), album, auteur,
> créateur, description, commentaire, éditeur, paroles
> (`iTunesMetadataLyrics`, `id3MetadataUnsynchronizedLyric`), date, durée et
> chapitres (`loadChapterMetadataGroups`). Elles forment la **page 1**,
> provenance `native`, sous forme de lignes « Title: … » **en anglais** — c'est
> du contenu indexé, même règle que les en-têtes `Subject:` d'un courriel. La
> DURÉE SEULE ne compte pas comme une métadonnée : tout conteneur en porte une,
> et une page « Duration: 00:01 » n'est pas cherchable. Un média qui n'a ni
> champ, ni chapitre, ni transcription est `skipped`, `err = "no metadata"` —
> et, Fouine n'indexant pas les noms de fichiers (§5.3 (e)), ce refus nommé est
> sa seule trace.
>
> (c) **Étage 2, la transcription, sur demande et SUR L'APPAREIL.** Sous
> `extract.transcribe` (booléen, `false`, `FOUINE_EXTRACT_TRANSCRIBE`, sans
> effet si `extract.media` est éteint) : `SFSpeechRecognizer` avec
> `requiresOnDeviceRecognition = true`, drapeau qui fait ÉCHOUER la requête
> plutôt que d'envoyer l'audio chez Apple. Langue : la première d'`ocr.languages`
> dont `supportsOnDeviceRecognition` est vraie — **pas de clé de langue
> supplémentaire**. Le son est lu **en flux** (`AVAssetReader` → PCM mono
> 16 kHz → `appendAudioSampleBuffer`), rien n'est écrit sur le disque, et
> chaque **fenêtre de dix minutes devient une page** de provenance
> `transcript`, en paragraphes d'environ 40 s précédés de `[mm:ss]`. Au-delà de
> `transcribe.max_minutes` (entier 1…600, `120`,
> `FOUINE_TRANSCRIBE_MAX_MINUTES`), seules les métadonnées entrent et
> `docs.meta` porte `transcription = "skipped: longer than N min"`. Deux refus
> nommés, `skipped` : « speech: on-device recognition is not installed for … —
> add the language under System Settings ▸ Keyboard ▸ Dictation » et « speech
> recognition not authorised — System Settings ▸ Privacy & Security ▸ Speech
> Recognition » (l'Info.plist du bundle porte
> `NSSpeechRecognitionUsageDescription`) ; quand les métadonnées sont là, le
> refus ne coûte pas le document, il s'écrit dans `docs.meta`.
>
> (d) **`SFSpeechRecognizer.queue` doit être une file DÉDIÉE.** Sa valeur par
> défaut est la file **principale** : un appelant synchrone — ce qu'est tout
> extracteur — n'est alors jamais rappelé. Mesuré le 08/09/2026 : aucun rappel
> en 120 s, ni résultat ni erreur, pendant que Speech tournait à 100 % de
> processeur ; avec une `OperationQueue` à elle, 1,5 s pour 1,95 s d'audio. Une
> tâche abandonnée est annulée dans tous les cas en sortant, sans quoi elle
> réessaie indéfiniment en arrière-plan.
>
> (e) **Conteneurs qu'AVFoundation n'ouvre pas** — `mkv` `avi` `wmv` `webm`
> `ogg` `oga` `opus` — : `ffprobe -v error -show_format -print_format json`
> pour les balises et `ffmpeg -nostdin -v error -i … -vn -ac 1 -ar 16000 -f
> wav` pour la parole, l'un et l'autre cherchés par chemins explicites
> (`ExternalTool.searchPaths`), ffprobe **à côté** de ffmpeg. Sans ffmpeg :
> `skipped`, `err = "<ext>: ffmpeg is missing (missing-tool:ffmpeg)"` — motif à
> **jeton**, que le crawl relit pour revenir sur le refus dès que l'outil
> apparaît (constat A3-05, même mécanique que djvulibre).
>
> (f) **Troisième provenance.** `PageSource.transcript = 3`. La valeur s'écrit
> telle quelle dans `page_src.src`, colonne `INTEGER` sans contrainte : ce
> n'est **pas** une migration de schéma, et une base ancienne ne porte
> simplement aucune ligne à 3. `PageSource.scanned` reste `[ocrFast,
> ocrAccurate]` : une page transcrite n'est pas un scan. Les trois ensembles
> (`typed`, `scanned`, `transcribed`) **partitionnent** l'énumération, et le
> filtre de provenance du §5.5.3 accepte `transcript` en CLI (`--source`) comme
> en MCP (`source`).
>
> **Coût mesuré** (i5 4 cœurs, 08/09/2026) : métadonnées d'un `.flac` réel de
> 4 min 17, 0,058 s. Transcription sur l'appareil, environ **30 s par minute
> d'audio** (4 min 18 de son transcrites en 2 min 10) — soit à peu près la
> moitié du temps réel.

> **Amendement du 15/09/2026 (DF1, version 1.0.1) — images, sons et vidéos, et transcription allumés par défaut.** Les trois réglages `extract.images`, `extract.media` et `extract.transcribe` passent à **vrai** par défaut (décision du propriétaire, 15/09/2026) : la réserve d'origine — une bibliothèque musicale n'est pas un fonds documentaire, une image passe par l'OCR — reste vraie, mais elle se règle en décochant la case de Réglages ▸ Indexation, pas en cachant trois familles derrière un réglage éteint que le public visé ne trouve pas. Rien ne change pour une valeur déjà écrite dans `settings` : le défaut ne vaut qu'en l'absence de ligne. La recette d'intégration fige les trois variables d'environnement à `false` (`IntegrationSupport.run`), parce que le corpus versionné est compté sans images ni médias (`pieges/photo.png`, fixtures médias hors manifeste). Le premier média transcrit déclenche la demande d'autorisation « Reconnaissance vocale » de macOS, comme avant quand on cochait la case.

> **Amendement du 10/09/2026 (CM-23, C2-05, lot SI1) — deux bornes sur la voie des médias.** **(a) Liste blanche des protocoles.** `-protocol_whitelist file` est posé **avant** `-i` dans les DEUX invocations, `MediaDecoder.convert` (ffmpeg) et `MediaMetadata.probe` (ffprobe). Un `.mkv` qui est en réalité une playlist HLS ou un script `ffconcat` porte une adresse `http://` : sans cette borne, c'est la version de ffmpeg installée qui décide de l'ouvrir — ffmpeg 9.0.1 refuse (mesuré), une version plus ancienne ou compilée autrement ne refuserait pas, et la promesse de silence réseau ne serait plus tenue par Fouine. Deux fixtures de `NetworkSilenceTests` (`piege-hls.mkv`, `piege-concat.mkv`) l'éprouvent sur les deux outils. **(b) Transcription sérialisée, résultat vide refusé.** `SpeechTranscriber.transcribe` prend un sémaphore statique à 1 : `SFSpeechRecognizer` ne sert qu'une reconnaissance à la fois et rend un résultat **vide, sans erreur**, aux autres — à `extract.jobs = 4` (le défaut), trois enregistrements sur quatre d'un dossier de dictaphone étaient perdus en silence, avec une ligne de succès et une durée qui trahissait tout (0,2 s pour 30 s d'audio). Le reste de l'extraction garde son parallélisme. Et zéro caractère utile sur une piste d'au moins **5 secondes** devient un `FouineError.extraction("speech recognition returned nothing — try again")` : le document passe en `failed`, donc la passe suivante le retente, au lieu d'être `extracted` avec ses seules métadonnées et de n'être jamais repris.

> **Amendement du 12/09/2026 (TR1) — la transcription entière, et relue quand elle s'allume.**
>
> (a) **La reconnaissance rend la parole par morceaux d'une minute.** Mesuré le
> 12/09/2026 sur macOS 15.7.9 : `SFSpeechRecognizer` sur l'appareil, alimenté
> par `SFSpeechAudioBufferRecognitionRequest`, rend une fenêtre en morceaux
> d'environ 60 s. Chacun arrive comme un résultat `isFinal == false` qui porte
> `speechRecognitionMetadata` ; les morceaux se suivent sans chevauchement,
> horodatés depuis le début de la requête, et seul le dernier est `isFinal`. Sur
> 0–180 s d'un cours : 1,5…60,0 s → 635 caractères, 60,0…119,7 s → 753,
> 120,1…179,4 s → 722. Ne retenir que `isFinal` gardait 722 caractères sur
> 2 110 : la **dernière minute** de chaque fenêtre de dix, pour toutes les
> extensions (voie ffmpeg comprise), avec une passe qui annonçait une réussite
> — 378 et 372 caractères sur deux extraits de 150 s (`.m4a`, `.opus`), 879 au
> lieu d'environ 8 800 sur un cours de 12 min 30. Allumer
> `shouldReportPartialResults` n'est pas le remède (mêmes trois morceaux, le
> texte repart de zéro après chacun, 365 rappels) : il reste éteint.
>
> (b) **Règle de cumul** (`TranscriptChunks`, pure). Un résultat est RETENU s'il
> est final ou porte `speechRecognitionMetadata` ; ses segments s'ajoutent à la
> suite. Les doublons se traitent au niveau du morceau : d'un résultat retenu,
> seuls entrent les segments qui commencent après le début du dernier segment
> déjà cumulé — un final qui répéterait le dernier morceau n'ajoute rien, et
> dans un morceau tout passe, même à horodatage égal. `isFinal` délie
> l'attente ; une erreur la délie aussi en GARDANT le cumul (« No speech
> detected » sur le silence de fin de fenêtre) ; l'échéance annule la tâche et
> rend le cumul, là où elle rendait `[]`. Mesuré après correctif (binaire du
> lot, base jetable, `FOUINE_EXTRACT_JOBS=1`) sur les deux extraits de 150 s :
> 1 806 caractères (`.m4a`) et 1 803 (`.opus`, voie ffmpeg), paragraphes
> `[00:01]`, `[00:42]`, `[01:22]` et `[02:03]`, en 358 s pour les deux (336 s
> avant). Avant, 378 et 372 caractères, et le seul `[02:00]`.
>
> (c) **« no metadata » dit pourquoi.** Transcription éteinte : `err = "no
> metadata"`, inchangé — les lignes déjà en base gardent ce sens exact, ni
> balise ni transcription demandée. Transcription allumée sans rien à mettre
> par écrit : `"no metadata (no audio track)"`, `"no metadata (longer than N
> min)"`, `"no metadata (unknown duration)"`, et `"no metadata (no speech)"`
> (transcrit, rien entendu, sur moins de 5 s — au-delà, c'est l'échec du §
> précédent). Toutes `skipped` : `ExtractOutcome.isMediaSkip` prend le préfixe
> `no metadata`. L'application nomme les deux cas qui ont un geste — cocher
> « Mettre aussi par écrit ce qui est dit », augmenter « Durée maximale mise par
> écrit (minutes) » — et range les autres sous « rien à chercher ».
>
> (d) **Marque `meta.transcription_revision`**, comparée par `IndexPass` juste
> avant la collecte des cibles (les trois pipelines, verrou pris). Valeur
> attendue : `MediaExtractor.transcriptRevision` (`speech-rev2`) quand
> `extract.media` et `extract.transcribe` sont allumés, `off` sinon ; une marque
> absente vaut une marque différente. Égale : rien, une lecture. Différente et
> attendue = révision : en UNE transaction, `state = discovered, err = NULL` pour
> les documents d'extension média qui sont `extracted`, ou `skipped` sur `no
> metadata` exact, ou sur l'un des deux refus de la reconnaissance (dictée non
> installée, autorisation), ainsi que les `failed` dont l'erreur contient
> `speech recognition returned nothing` (échecs causés par le bogue des morceaux) ;
> puis la marque. Journal : `transcription: N media document(s) queued to be written
> down again`. Différente et attendue = `off` : la marque seule, les transcriptions
> existantes restent cherchables. Les autres `failed` et les formes à parenthèse
> ne sont pas repris. **Pas une migration de schéma.** Reliquat accepté :
> décocher puis recocher la transcription retranscrit tous les médias une fois.

> **Amendement du 14/09/2026 (BT2) — une fenêtre se coupe sur un silence, et une
> fenêtre coupée fait échouer le document.** L'échéance fixe de 1 800 s par
> fenêtre de dix minutes supposait une reconnaissance « autour du temps réel ».
> Mesuré : 245 s pour 7 min 45 sur un i5 au repos (281 s en priorité
> d'arrière-plan), au moins six fois plus lent sous une charge de 159, et dans
> l'agent le 13/09 (processeur bridé à 41 %) un morceau de 60 s toutes les
> ~450 s. L'échéance coupait donc un travail vivant, gardait les morceaux reçus et
> perdait le reste de la fenêtre sous un document `extracted` que rien ne
> reprenait : deux vidéos du corpus en sont sorties tronquées (4 min sur 7 min 45 ;
> 2, 5 et 3,5 min sur trois fenêtres de dix). **(a)** L'attente d'une fenêtre
> expire quand la reconnaissance n'a donné AUCUN signe de vie (rappel) depuis
> `FOUINE_SPEECH_TIMEOUT` secondes, **900** par défaut, comptées depuis
> `endAudio` ; pas de plafond de durée, chaque morceau couvrant une minute d'un
> audio fini. **(b)** Une fenêtre coupée fait échouer le document : `failed`,
> `err = "speech recognition stopped answering"`, nommé par l'application
> (« La mise par écrit de cet enregistrement s'est interrompue… »). **(c)** Une
> passe ne relisant que les `discovered`, ce motif rejoint `speech recognition
> returned nothing` dans les `failed` que la révision reprend (point (d)
> ci-dessus), et la révision passe à **`speech-rev3`** : tous les médias
> `extracted` sont retranscrits une fois. La phrase de l'application pour une
> transcription vide ne demande plus un geste qu'elle n'offre pas (« relancez
> l'indexation de ce fichier »). Les appels de Speech hors de l'attente
> (construction, `recognitionTask`, versement des échantillons, `cancel`) ont été
> mesurés à quelques millisecondes, trois processus concurrents compris : ils
> restent non bornés.

> **Amendement du 10/09/2026 (C2-01, C2-02, C2-03, C2-07, C2-09, C2-10, lot IX1) — ce que l'index disait de travers.**
>
> (a) **Deux planchers d'image, deux motifs.** Le plancher de taille de fichier
> passe de 64 Kio à **8 Kio** : il refusait des pages A4 entières dès qu'elles
> étaient bien compressées — la même page de 945 × 1418 px portant 2 291
> caractères passe en PNG (249 Ko), JPEG (289 Ko), HEIC (134 Ko) et WebP
> (125 Ko), et se faisait refuser en AVIF (53 814 octets), format d'export par
> défaut de plusieurs appareils. Un plancher d'octets n'est pas une quantité
> d'information ; c'est celui des dimensions (300 px) qui fait le travail. Les
> deux refus portent désormais leur mesure et **deux motifs distincts** :
> `image file below the OCR weight floor: N bytes` et `image below the OCR size
> floor: WxH px` — dire « image trop petite » d'une page A4 envoyait
> l'utilisateur chercher une image qui n'existe pas. Les deux restent `skipped`.
>
> (b) **Un TIFF vaut ses pages.** `tif`/`tiff` déclarent `pageCount =
> CGImageSourceGetCount(source)` et mettent **toutes** leurs images en file
> d'OCR ; `FouinePageRenderer` rend l'image d'index `page - 1`. Le TIFF
> multi-pages est la sortie normale d'un scanner de bureau, et déclarer une
> seule page en faisait disparaître les deux tiers sans erreur, sans motif et
> sans trace (Fouine n'indexe pas les noms de fichiers). Au-delà de
> `Schema.maxPage`, le refus est celui du PDF. Le GIF animé reste à une page.
>
> (c) **Un tableur s'indexe aussi comme on le lit.** La cellule qui AFFICHE
> « 05/01/2026 » contient `46027`, celle qui affiche « 1 512,50 € » contient
> `1512.5` : chercher une date ou un montant dans un tableur ne marchait pas.
> Pour les `.xlsx`, `xl/styles.xml` (`cellXfs`, `numFmts`) et `workbookPr
> date1904` sont lus, et **les deux formes sont indexées**, la rendue puis la
> brute, séparées par une espace : « 05/01/2026 46027 », « 1 512,50 1512.5 ».
> Deux familles seulement — date/heure et décimal ; pourcentages, fractions,
> notation scientifique et cellules sans format restent bruts. Le rendu est
> français en dur (jj/mm/aaaa, virgule, espace de milliers) : `page_fts` survit
> à un changement de réglage régional. `.numbers`, `.xls` et `.ods` ne passent
> pas par ce parseur et ne changent pas.
>
> (d) **Les mots coupés en fin de ligne sont recollés, les deux formes
> gardées.** Un document justifié porte `dispen-\nser` : 565 coupures sur les
> 41 351 mots de la notice 2042, autant de mots introuvables. La forme jointe
> est AJOUTÉE derrière le second morceau et la forme coupée conservée
> (« porte-\nmanteau portemanteau ») : rien à trancher entre une césure et un
> mot composé. Règle : minuscule avant le tiret, minuscule après le retour.
> Appliqué au texte de page du PDF, du DjVu et à l'assemblage des lignes de
> Vision. Coût mesuré : +2,4 % de texte indexé sur la notice 2042.
>
> (e) **Un DjVu sans couche texte se dit en français.** Le motif brut
> « djvu: no text layer (…) » s'affichait tel quel dans la fenêtre française
> des documents illisibles. Il est désormais classé et rendu : « Ce document
> numérisé n'a pas de couche texte. Fouine ne lit pas encore les images DjVu :
> exportez-le en PDF. » La mise en file d'OCR des DjVu (rendu par `ddjvu`)
> **reste à faire** : ce refus est une phrase juste, pas une lecture.
>
> (f) **La langue se décide sur trois tranches qui votent**, jamais sur les
> 4 000 premiers caractères : préambule Gutenberg, page de garde, en-têtes RFC
> 822 et bruit de scan rangeaient 62 documents d'un fonds franco-anglais en
> hongrois, danois ou finnois, en laissaient 246 sans langue, et rendaient « Le
> Horla » introuvable avec le filtre « Français ». Trois tranches sont prises
> vers 10 %, 50 % et 90 % de la matière, sur une frontière de mot ; chacune
> vote, la majorité l'emporte, une égalité ne tranche rien. Les décalages se
> calculent sur les longueurs de pages : un ouvrage de 1 570 pages n'est jamais
> concaténé. Les en-têtes RFC 822 des quarante premières lignes sont retirés
> avant l'échantillonnage. Le rattrapage lit trois régions séparées, ou le
> document entier s'il tient en six pages. `fouine maintain
> --redetect-languages` rejoue la détection sur TOUS les documents, y compris
> ceux qui portent déjà une langue — sans quoi une base indexée avant ce
> correctif garderait ses langues fausses. Mesuré sur une copie de la base
> réelle : 1 504 documents en 26,6 s, `en` 602 → 798, `und` 246 → 127, langues
> improbables 62 → 32.

**Contrôle de plausibilité, obligatoire pour tout format riche.** Rejeter (`.skipped` + `err`) si `documentType == NSPlainText` alors que l'extension annonçait un format riche, ou si la proportion de caractères non imprimables / hors plages latines dépasse un seuil. Sans ce contrôle, le mojibake entre dans `page_fts`, donc dans `fts5vocab`, donc dans l'expansion floue — dont toute la précision dépend de la propreté du vocabulaire (§5.5.2). C'est exactement le défaut reproché à Tesseract au §2.8, et il rentrerait par la porte de derrière.

> **Amendement du 13/09/2026 (EX2, lot EX2) — chaîne de décodage du texte brut.**
> La ligne « `txt` `md` `csv` `tex` `json` `log` » du tableau ci-dessus
> (« UTF-8, repli ISO-8859-1 puis `macOSRoman` ») devient, pour
> `PlainTextExtractor.decode` et tout ce qui l'appelle (sous-titres, HTML,
> XHTML d'epub, corps de courriel, XML mal formé, DjVu) : **BOM** (UTF-8,
> UTF-16 LE/BE) → **attribut étendu `com.apple.TextEncoding`** quand l'appelant
> passe l'URL (texte brut et sous-titres ; valeur `nom-IANA;nombre`, seul le
> nom compte, un nom inconnu est ignoré) → **UTF-8** → **Windows-1252** →
> **ISO-8859-1** → **MacRoman**. Tout décodage autre que le BOM et l'UTF-8 est
> tenu au contrôle de plausibilité ci-dessus, l'encodage déclaré compris : un
> attribut resté faux ne fait pas entrer de mojibake. Windows-1252 passe devant
> ISO-8859-1 parce que le contrôle ne les départageait pas : les octets
> 0x80–0x9F (€ — “ ” ’ œ sur un PC occidental) décodés en Latin-1 sont une
> poignée de commandes C1, loin des 30 % de suspects ; un fichier Latin-1 sans
> ces octets se décode à l'identique, et les cinq octets sans caractère en
> CP1252 font échouer Foundation, qui retombe sur Latin-1. Deux précisions du
> même lot : le dépouillement HTML garde la cible des liens `http://`,
> `https://`, `mailto:`, `doi:` (« texte (cible) », la cible seule pour un lien
> sans texte, rien si le texte la répète) ; un document de la ligne « lecture
> directe » dont l'échantillon de tête porte une suite de 2 000 caractères
> sans blanc est `.skipped`, `err = "no readable text: <n>-character run
> without a space — data dump?"` (reconnu par préfixe, comme les planchers
> d'image) — les sources gardent leur règle « source minifiée ».

> **Amendement du 14/09/2026 (lot MN1) — deux faux refus de la suite sans
> blanc.** Le garde-fou ci-dessus attrapait deux familles de documents
> parfaitement lisibles, mesurées le 14/09/2026 sur des fichiers fabriqués et
> sur le binaire installé. **(a) Une image EMBARQUÉE n'est pas un vidage de
> données** : un `.md` exporté par Typora ou Obsidian porte ses illustrations en
> `![courbe](data:image/png;base64,…)`, et un compte rendu de deux paragraphes
> était refusé en entier sur une « suite de 12 033 caractères ».
> `Plausibility.longestRunWithoutWhitespace` mesure donc sur l'échantillon
> PRIVÉ de ses adresses `data:` (`withoutDataURIs` : l'introducteur et sa valeur
> jusqu'au premier blanc, casse ignorée). Une colonne de base 64 NUE, sans
> introducteur, reste refusée — c'est le cas que le lot EX2 visait. **(b) Un
> JSON COMPACTÉ non plus** : un export d'API de 36 417 caractères sans un blanc
> était refusé, alors qu'il a une syntaxe, qu'elle se vérifie, et que ses
> valeurs sont ce que l'on cherchera dedans. Un fichier de la ligne « lecture
> directe » qui se parse par `JSONSerialization` (options `.fragmentsAllowed`)
> est donc plausible quelle que soit la longueur de ses lignes. La sonde ne
> tourne que sur le chemin du REFUS — jamais sur un fichier ordinaire — et sous
> un plafond de **4 Mio** (`PlainTextExtractor.jsonProbeMaxBytes`) : au-delà,
> construire en mémoire un arbre de plusieurs fois le poids du fichier pour
> apprendre qu'un vidage de dix mégaoctets est bien formé n'apprend rien, un
> vidage reste un vidage. **(c)** `HTMLExtractor` et `XMLDocumentExtractor`
> passent désormais l'URL à `decode` (leurs octets SONT ceux du fichier, donc
> l'attribut `com.apple.TextEncoding` les décrit) et le message du refus annonce
> la chaîne réelle, Windows-1252 comprise. `EPUBExtractor` et `EMLExtractor` ne
> la passent PAS, et c'est la règle : leurs octets sont une entrée d'archive ou
> une partie MIME, dont le jeu de caractères est déclaré ailleurs — appliquer
> l'étiquette du conteneur à une partie ferait entrer le mojibake que cette
> étiquette sert à éviter.

**Images embarquées dans les conteneurs OOXML.** L'extracteur dézippe déjà ces conteneurs : mettre `word/media/*`, `ppt/media/*` et `xl/media/*` en file OCR au même titre qu'une page de `.cbz`. **61 conteneurs, 722 images** (mesuré). Ce sont les figures scannées et les schémas réactionnels collés dans les diapositives de cours — aujourd'hui totalement invisibles à l'index, pour quelques lignes de code. Une image embarquée est une « page » du document porteur, numérotée après les pages de texte.

**Garde-fou Zip Slip** sur toute extraction d'archive (`cbz`, `cbr`, `epub`, OOXML) : refuser toute entrée dont le chemin normalisé sort du dossier de destination, ou commence par `/` ou `..`. `bsdtar` en sous-processus avec `-O` (sortie standard) évite le problème par construction ; toute variante qui écrit sur disque doit le vérifier.

Pagination des formats non paginés (txt, md, csv, html, docx…) : découper à `pageSplitChars` (4 000) sur la frontière de paragraphe la plus proche. Sans cela, `NEAR` perd son sens sur un fichier de 2 Mo et les extraits ne sont pas navigables.

> **Amendement du 10/09/2026 (MO-01, C2-06, lot SI1).** Deux bornes de plus sur cette pagination. **(a) Un plafond de pages**, `ExtractLimits.maxSplitPages = 5 000`, appliqué en un seul endroit — l'enveloppe rendue par `DefaultExtractorRegistry.extractor(for:)` — aux seules extensions dont l'extracteur découpe par `TextPagination` ; les formats nativement paginés (pdf, djvu, cbz, images, médias, iWork) gardent le plafond du schéma (`Schema.maxPage`). Au-delà, les pages 1…5 000 sont conservées, `pageCount = 5 000`, et `meta["truncated"] = "pages beyond 5000 dropped (N pages)"`. Motif : un `.docx` de 80 Kio dont le corps est 80 Mio de « A » produisait 13 108 pages et ~26 000 fenêtres vectorielles identiques, le seul plafond en vigueur étant celui du texte (50 Mio). **(b) La coupe tombe sur une frontière de mot** : paragraphe, sinon ligne, sinon dernier blanc du tronçon, et coupe dure seulement pour un tronçon sans aucun blanc. La fin de ligne se cherche sur `Character.isNewline` et non sur « \n\n » : dans un fichier CRLF, `\r\n` est UN `Character` de Swift, aucune frontière n'était donc jamais trouvée, et les 806 coupes de *Guerre et Paix* tombaient au milieu d'un mot (« Na | tásha »). La concaténation des pages redonne toujours le texte d'origine. Le **chevauchement** des fenêtres, qui rendrait trouvable une expression à cheval sur deux pages, n'est pas dans cet amendement : il changerait le texte affiché de chaque page.

**Détection des pages à OCRiser : sonder des pages réparties**, jamais les trois premières (§2.5 — 38 % de faux « scannés » sinon). En pratique, l'extraction parcourt de toute façon toutes les pages : la règle est que le **diagnostic** de document scanné, quand il sert à décider avant de tout parcourir, s'appuie sur un échantillon réparti.

**Le repli `--pdf-engine pdfkit|poppler` de la v1.0 est supprimé.** Le critère était « si PDFKit se révèle plus de deux fois plus lent » ; mesuré : **×1,39** (75,6 contre 105,1 p/s), et ×1,46 avec le correctif mémoire. Le critère n'est pas atteint, `pdftotext` vit hors du bundle signé, et `PDFPage.string` donne la page directement là où `pdftotext` impose un découpage sur `\f` fragile sur les documents à pages vides. Le même `PDFDocument` sert ensuite au rendu (§6) et à l'aperçu (§5.6).

> **Amendement du 04/09/2026 (A3-07, lot K3).** La sélection de la file OCR (`nextOCRBatch` et `pendingOCRPages`) passe à l'ordonnancement « plus court reste d'abord » (*Shortest Remaining Processing Time*) : `ORDER BY q.prio, q.attempts, remaining ASC, q.doc_id DESC, q.page` où `remaining = (SELECT count(*) FROM ocr_queue q2 WHERE q2.doc_id = q.doc_id)`. Un document court récemment ajouté ou un document entamé dont il ne reste que quelques pages est servi avant un livre volumineux de même priorité, éliminant la famine de file observée sur les gros volumes.

### 5.4 FouineOCR

Propriétaire : **A-OCR**. Voir §6 pour l'algorithme complet.

### 5.5 Analyse de requête, variantes et recherche floue

Propriétaire : **A-Core**.

#### 5.5.1 Traduction de la saisie

L'utilisateur ne doit pas avoir à connaître la syntaxe FTS5. Traduction :

| Saisie | FTS5 produit |
|---|---|
| `azote reduction` | `azote AND reduction` |
| `"gaz parfait"` | `"gaz parfait"` |
| `spectro*` | `spectro*` |
| `-biologie` | `NOT biologie` (portée document, voir amendement) |
| `pres:5 azote reduction` | `NEAR(azote reduction, 5)` |
| `dossier:Cours enthalpie` | `enthalpie` + filtre `top_folder = 'Cours'` (le label de la racine, §5.2) |
| `ext:pdf ...` | filtre `ext = 'pdf'` |

*Amendement du 02/09/2026 (portée de l'exclusion, arbitrage T5) : l'exclusion `-terme` a une portée DOCUMENT, pas un simple `NOT` FTS5 au niveau de la page. Tout document contenant le terme exclu est rejeté de la sélection (`doc_id NOT IN ...`), conformément au critère d'acceptation T5.*

> **Second amendement du 11/09/2026 (RK-04, AUDIT-RK2, orchestrateur) — le quorum est ARMÉ par défaut.** Les 149 candidats que le quorum et le malus remontaient seuls sur le pool `rk2-2026-09-11` ont été lus et jugés : quorum **+0,031** nDCG@10 pages / +0,032 documents contre le ET strict, 6 victoires / 43 égalités / **0 défaite**, p = 0,040 ; ce qu'il remonte est surtout noté 1 (rappel plutôt que précision), et il n'est pas armé sur toute paraphrase (moins de trois mots longs communs). `SearchQuery.quorum` vaut donc **vrai** ; `fouine search --no-quorum` le désarme (calibration), les systèmes témoins du banc sont `lexical-noquorum` et `lexical-noquorum-notoc`. Toujours pas en hybride.
> **Amendement du 11/09/2026 (RK-04, lot RK2) — le QUORUM des mots, désarmé par défaut.** Le ET implicite du tableau ci-dessus exige **tous** les mots sur la **même page**, mots-outils compris. Le banc jugé du 09/09/2026 (790 jugements) en mesure le coût : `comment mesurer la chaleur degagee par une reaction` rend **0 page**, `la chaleur degagee par une reaction` en rend **10**, et les deux bonnes réponses que l'hybride finissait par trouver (doc 472 p. 258, doc 158 p. 583) portent toutes deux « reaction » — ce sont des pages que le ET strict avait exclues, pas des trouvailles du canal sémantique (dont 93 % des résultats purement sémantiques sont notés 0 : RK-03). `SearchQuery.quorum` (**faux** par défaut, `fouine search --quorum`) ajoute une **seconde passe**, et seulement si la première a rendu moins de `Schema.quorumTrigger` (**10**) pages et que la requête compte au moins **trois** mots nus : l'expression relâchée demande `k = ⌈0,6 × m⌉` des `m` mots de **plus de trois lettres** (`QueryParser.quorumFTS`), sous la forme `(A AND B AND C) OR (A AND B AND D) OR …` — toutes les combinaisons, `m ≤ 6` sinon pas de quorum (C(6,4) = 15 groupes). Les mots de trois lettres ou moins ne sont **jamais** exigés ; chaque mot garde ses formes morphologiques (§5.5.3), la chaîne relâchée passant par `effectiveFTS` comme la stricte. Les pages **strictes gardent la tête** — deux requêtes concaténées, les pages du quorum dédupliquées derrière elles —, et les couches de classement (bonus M1, forme tapée, diversité) sont celles de la requête **tapée**, non de l'expression relâchée. Restent STRICTES : une phrase, un `NEAR`/`pres:`, un préfixe `*`, une exclusion, et toute requête portant un filtre (`dossier:`, `ext:`, langue, date, provenance, `--in`). `SearchResults.quorum` porte le fait ; les trois surfaces l'ANNONCENT (`SearchAdvice.quorum`, clé `quorum` du JSON et du MCP, une ligne sous le champ dans l'application) — une recherche qui change de règle sans le dire est pire qu'une recherche qui ne trouve rien. Coût **nul** quand la stricte rend dix pages ou plus. Le quorum ne s'applique pas en mode hybride (la CLI le dit) et **attend le banc** avant d'être armé par défaut (systèmes `lexical-quorum`, `lexical-quorum-toc`).

> **Amendement du 13/09/2026 (MC1, lot MC1) — quatre exclusions de filtres, `chemin:`, et la saisie recomposée.** (a) **Les exclusions de filtres AGISSAIENT COMME DES MOTS.** `-nom:Pourvue` et `-ext:md` étaient acceptés et produisaient `NOT "nom:Pourvue"` (`QueryParser.parse`, branche `-terme`) : une chaîne qu'aucune page ne porte, donc un filtre SANS EFFET, sur un résultat qui a l'air juste. `-dossier:`/`-folder:`, `-ext:`, `-nom:`/`-name:` et `-chemin:`/`-path:` sont désormais lus AVANT `-terme`, valeur entre guillemets acceptée comme au positif, et deviennent des clauses de DOCUMENT : `top_folder NOT IN`, `ext NOT IN`, `doc_id NOT IN (SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?)`, chemin ne contenant pas la valeur. `SearchQuery` gagne `folderExcludes`, `extExcludes`, `nameExcludes`, `pathContains`, `pathExcludes` (le contrat s'étend, il ne se renomme pas) ; `-dossier:Xyz` est confronté aux étiquettes réelles comme `dossier:Xyz` (`FolderCheck`, sortie 64) ; une requête faite d'exclusions seules reste `exclusionOnly`. Le canal VECTORIEL applique les mêmes exclusions (`docIDsMatchingName`, que `HybridSearch` appelle déjà avec la requête entière, et `docIDsMatchingFilters`, dont les nouveaux paramètres valent vide par défaut). Mesuré sur la base de production : `polymere dossier:M2SU` 750 pages, `… -ext:md` 628, `… -ext:pdf` 140 — avant, 750 et 749. (b) **`chemin:`/`path:`** filtre sur `docs.rel_path` ENTIER, répertoires compris : `instr(fold(d.rel_path), fold(?)) > 0`, où `fold` est une fonction SQL Swift (`DatabaseFunction`, pure, déterministe, `folding(.caseInsensitive, .diacriticInsensitive)`) enregistrée aux deux ouvertures du store. `docs_fts` n'indexe que le nom du fichier et celui de son dossier PARENT (lot QP1) : `nom:Offres` rendait 6 documents là où 178 sont rangés sous `Stage/Offres/…` (mesuré). La clause porte sur les 1 883 lignes de `docs`, pas sur les 434 372 pages — `energie` 268,8 → 271,0 ms (médiane de trois passes, copie de la base réelle), `energie chemin:Livres` 293,1 ms pour 28 659 pages. Plusieurs `chemin:` sont tous exigés ; `chemin:` SEUL rend les documents, par le même chemin de code que `nom:` seul (`documentsByName` généralisé : sans `nom:`, il n'y a pas de `bm25(docs_fts)` à lire, l'ordre se joue sur `mtime`). (c) **FORME NFC.** `QueryParser.tokenize` recompose l'entrée (`precomposedStringWithCanonicalMapping`) et `GRDBStore.documentClause` recompose `DocumentFilter.pathContains` — donc la CLI et le serveur MCP sans y toucher. La base est en NFC (`migration_v7_nfc`), le Finder rend du NFD : `fouine list --path-contains "Polymères"` rendait **225** documents à l'accent tapé et **0** au même accent collé depuis `ls` (mesuré le 13/09/2026, les deux formes rendent 225 désormais). (d) Le refus d'un faux préfixe énumère six paires (`… , chemin:/path:`). Sans les nouveaux champs, le SQL est celui d'avant au caractère près (test dédié).

> **Amendement du 14/09/2026 (lot MN1) — ce qui s'exclut, et ce qui se refuse.**
> DÉCISION : les filtres de la grammaire qui désignent un ensemble de DOCUMENTS
> s'excluent TOUS — ce sont les quatre de l'amendement MC1 (`dossier:`/`folder:`,
> `ext:`, `nom:`/`name:`, `chemin:`/`path:`), et ce sont les seuls, la langue et
> la date se demandant par option (`--lang`, `--since`) et non par préfixe.
> **Tout autre `-préfixe:valeur` est REFUSÉ** (`QueryParser.checkExclusion`,
> appelée juste avant que `-mot` ne devienne une négation), avec la règle de sa
> forme positive : `-type:pdf` par `unknownPrefix` (la même phrase que
> `type:pdf`, le tiret ne change pas ce qu'est le mot), `-texte:azote` et
> `-pres:5` par la même erreur nommant les QUATRE qui s'excluent — la proximité
> n'est pas un ensemble de documents et le négatif de `texte:mot` s'écrit
> `-mot`. Motif mesuré : `-type:pdf` était ACCEPTÉ et devenait
> `negativeFTS = "type:pdf"`, c'est-à-dire, après échappement, la PHRASE « type
> pdf » — elle n'exclut pas les PDF demandés et peut exclure un document qui
> porte ces deux mots à la suite. Le dernier silence de la famille de MC1.
> Restent des exclusions de MOT, inchangées : `-biologie`, `-10:30` (des
> chiffres avant le deux-points), `-https://exemple.org` (la valeur commence par
> une barre), `-t:x` (une seule lettre), et tout ce qui est entre guillemets.
> Sans exclusion écrite, le SQL est celui d'avant au caractère près (test
> dédié). **Réserve assumée** : les deux refus portent la même erreur
> `QueryError.unknownPrefix` — avec le jeton tiret compris et la liste des
> quatre excluables — parce qu'un cas d'énumération de plus casse le `switch`
> exhaustif qui traduit `QueryError` dans l'application, fermée à ce lot ; un
> cas dédié reste le geste propre.

> **Amendement du 14/09/2026 (lot MN2) — la réserve de MN1 est levée.** Un
> préfixe CONNU qui ne s'exclut pas (`-texte:`/`-body:`, `-pres:`/`-near:`) lève
> désormais son propre cas, `QueryError.notExcludable(préfixe, excludable:)` :
> le préfixe est cité SANS tiret et en minuscules — c'est lui qui ne se prête
> pas à l'exclusion —, et la phrase anglaise du cœur, que la CLI et le serveur
> MCP rendent telle quelle, dit « “texte:” cannot be excluded. The filters that
> can are dossier:/folder:, ext:, nom:/name:, chemin:/path:. To leave out a
> word, write -word. ». L'application la traduit et nomme les quatre filtres
> sans leurs alias, comme pour le faux filtre. `-type:pdf`, préfixe INCONNU,
> garde `unknownPrefix` et sa liste complète : « “type:” is not a filter » y
> reste vrai. La règle de l'amendement MN1 (ce qui s'exclut, ce qui se refuse,
> ce qui reste une exclusion de mot) ne change pas.

Les caractères spéciaux FTS5 (`" * ( ) : ^ -`) présents dans un terme nu sont échappés en encadrant le terme de guillemets doubles. `--raw-fts` court-circuite la traduction. L'insensibilité aux accents est acquise par le tokenizer : `polymere` doit trouver « polymère » (test T3 — mesuré au niveau moteur : les deux formes retournent **exactement les 81 mêmes pages**).

**Préfixes de moins de 4 caractères : refusés**, avec un message clair (« préfixe trop court, donnez au moins 4 lettres » dans l'application ; `prefix too short, give at least 4 letters` et sortie **64** dans la CLI — amendement du §4.3). C'est la contrepartie de la suppression de `prefix='2 3'` (D3) : sans index préfixe, `ch*` coûte 12,65 ms sur 20 968 pages (mesuré) et ramène 17 340 pages — c'est-à-dire rien d'utile, cher. Une ligne de code contre 480 Mo d'index.

> **Amendement du 04/09/2026 (idée 5 de l'audit A1, lot K5).** `dossier:Xyz` est confronté aux étiquettes de racine qui EXISTENT, et une étiquette inconnue lève `QueryError.unknownFolder(_, known:)` — sortie **64** dans la CLI, résultat d'outil `isError` dans le serveur MCP, message sous le champ dans l'application, chacun NOMMANT les étiquettes réelles. Jusque-là, le filtre partait tel quel : `top_folder` se compare exactement en SQL, la requête rendait **zéro résultat sans un mot**, et rien ne la distinguait d'un corpus qui ne contient pas le terme. C'est le pendant d'A1m-04 côté ergonomie — là, la syntaxe échouait ; ici, elle réussit et ment. Une différence de CASSE est canonisée au passage (`dossier:livres` filtre sur « Livres ») ; un accent manquant, non — filtrer sur un dossier que l'utilisateur n'a pas nommé vaudrait moins qu'un refus qui dit quoi taper. Enfin, **on ne refuse que ce qu'on peut contredire** : sans liste d'étiquettes (base neuve, racines pas encore relues), le filtre part tel quel.

> **Amendement du 04/09/2026 (A1m-07, lot K5).** Un **mot-clé de FTS5 tapé nu** est refusé à l'analyse, comme un préfixe trop court : `AND`, `OR`, `NOT` en majuscules, et `NEAR` suivi d'une parenthèse, lèvent `QueryError.ftsOperator`. Jusque-là, `polymere OR catalyse` partait tel quel au moteur, qui répondait par un vidage de SQL (`fts5: syntax error near "OR"`, requête interne comprise) et une **sortie 3** — le code de « base verrouillée ou corrompue » — pour une faute de frappe ; le serveur MCP, dont la documentation renvoie à cette syntaxe, rendait le même diagnostic de base de données à un modèle qui n'avait qu'à réécrire sa requête. **La casse compte** : « or » et « ou » sont du français courant, « and » et « not » de l'anglais, FTS5 ne les lit comme opérateurs qu'en majuscules, et ils restent donc cherchables ; `"OR"` entre guillemets cherche le mot lui-même. `NEAR` seul reste un mot ordinaire, la grammaire FTS5 ne le lisant comme opérateur que devant `(`. Le refus sort en **64** dans la CLI (§4.3), en résultat d'outil `isError: true` dans le serveur MCP — l'argument est une chaîne valide, c'est son contenu que l'appelant doit corriger —, et s'affiche sous le champ de recherche dans l'application, où la phrase ne nomme aucun opérateur : « “OR” en majuscules est une instruction, pas un mot : Fouine cherche déjà tous les mots que vous tapez ; pour exclure un mot, écrivez -mot. »

> **Amendement du 10/09/2026 (PR-03, PR-04, C2-12, lot MP1) — la table de traduction accepte l'anglais, refuse un faux filtre, et connaît les montants.** (a) **Alias anglais** : `folder:` vaut `dossier:` et `near:` vaut `pres:`, partout où l'un est reconnu — `valuePrefixes` (valeur entre guillemets), absorption des membres d'un `NEAR`, retrait des filtres avant l'envoi au modèle sémantique. La forme CANONIQUE des structures ne change pas (`ParsedQuery.folders`, `.near`) : aucun appelant n'est touché. Deux des trois filtres étaient des mots FRANÇAIS au milieu d'une application, d'une aide et d'une CLI anglaises, et l'invite du champ annonçait `near:` que le moteur refusait — mesuré le 09/09/2026 sur la base de production : `near:5 azote reduction` 0 page contre 7, `folder:Livres energie` 0 contre 28 658. (b) **Un préfixe inconnu est REFUSÉ, pas cherché** : `QueryError.unknownPrefix(_, known:)` — sortie **64** en CLI, `isError` côté MCP, phrase sous le champ dans l'application — pour tout mot de la forme `<lettres>:<valeur>` dont le préfixe n'est pas un filtre (`type:pdf`, `dans:Livres`). Jusque-là c'était un TERME, donc zéro résultat en silence. La règle est étroite pour ne rien casser : au moins **deux lettres** avant le deux-points, valeur non vide qui ne commence pas par `/` — une URL (`https://…`), une heure (`10:30`), une notation à une lettre (`a:b`) et tout mot entre guillemets (`"Chapitre:3"`) restent des termes. (c) **Montants** : un terme numérique à décimale (`,` ou `.`) et à au moins quatre chiffres avant elle part sous ses DEUX écritures — `1512,50` → `("1512,50" OR "1 512,50")` —, et deux jetons `1` + `512,50` se recollent en un terme dont la traduction est l'inverse. Les deux membres sont entre guillemets : `1512,50` nu est une erreur de syntaxe FTS5 (vérifié). Les documents français portent l'espace fine insécable des montants, dont `unicode61` fait un séparateur comme de l'insécable et de l'ordinaire (vérifié le 10/09/2026) : une seule forme groupée apparie les trois. **Aucune variante** sur un nombre de trois chiffres ni sur une année (quatre chiffres sans décimale) : `"2 003"` polluerait le nombre le plus tapé de tous.

> **Amendement du 13/09/2026 (QP1, lot QP1) — guillemets typographiques, préfixes `nom:` et `texte:`.** (a) **Guillemets** : `QueryParser.tokenize` ne reconnaissait que le guillemet ASCII, alors que macOS remplace par défaut les guillemets tapés dans un champ de texte — `“gaz parfait”` et `« catalyse »` n'étaient pas des phrases mais deux mots flanqués de caractères parasites, et `asksForExactPhrase` (RK-01) laissait le canal sémantique allumé. Au début de `tokenize`, une seule fois pour `parse`, `asksForExactPhrase`, `semanticText` et les valeurs de filtres, `“ ” „ ‟ « » ″` deviennent `"` et `’` devient `'` (le tokenizer FTS5 coupe aux deux ; c'est l'égalité de traitement qui compte). Les espaces intérieures de la typographie française sont rognées, pour une phrase comme pour une valeur de filtre. Rien d'autre n'est normalisé. (b) **`nom:`/`name:`** : la valeur se cherche dans `docs_fts` SEULEMENT (nom du fichier et du dossier parent), chaque mot avec ses formes morphologiques (§5.5.3), une valeur à espace comme une phrase ; plusieurs `nom:` sont tous exigés (`ParsedQuery.nameTerms`, `SearchQuery.nameTerms`). Avec des termes de page, c'est un filtre de document de plus dans la sous-requête FTS (`doc_id IN (SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?)`), et le canal vectoriel de l'hybride est restreint aux mêmes documents. Seul, la recherche rend les documents eux-mêmes : une ligne par document, sa première page porteuse de texte (sonde de plage de rowid sur `page_fts`, sans MATCH ; 1 à défaut), extrait = nom du fichier, totaux = documents, ordre = `bm25(docs_fts)` puis `mtime` décroissant ; ni quorum, ni flou, ni bandeau des noms, et le sens n'a rien à encoder — la recherche reste lexicale. (c) **`texte:`/`body:`** : la valeur est un terme de page ordinaire (une phrase si elle porte une espace) ; la présence d'au moins un `texte:` pose `SearchQuery.nameBoost = false`, qui retire la sonde `dn` (ni CTE, ni argument) et le canal des noms. Le texte envoyé au modèle garde la valeur (`texte:rapport` → « rapport »), contrairement à `nom:` et aux filtres ; `QueryParser.semanticText` est désormais l'unique fonction des trois surfaces. (d) Le refus d'un faux préfixe énumère les cinq paires (`dossier:/folder:, ext:, pres:/near:, nom:/name:, texte:/body:`). Sans `nom:` ni `texte:`, le SQL est celui d'avant au caractère près.

#### 5.5.2 Recherche floue

> **Amendement du 13/09/2026 (PM-11, PM-13, PM-14, lot MC1) — le quorum sous filtre, les mots vides, les six plus longs, le plafond de flou par portée, et ce que l'enveloppe dit.** (a) **UN FILTRE NE DÉSARME PLUS LE QUORUM.** `quorumExpression` exigeait `folders`, `exts`, `langs`, `inDocIDs`, `modifiedAfter`, `nameTerms` et la provenance vides ; mesuré le 13/09/2026 sur la base de production, `distribution des temps de séjour dans un réacteur réel` rend **28 pages** nue (quorum armé) et rendait **0** sous `dossier:Livres` — c'est-à-dire précisément la forme qu'un assistant emploie, et la question du propriétaire. Un filtre RESTREINT le corpus ; il ne dit rien de l'exigence sur les mots, et le quorum joue alors sur un jeu plus petit. Restent stricts : `nom:` (une question sur les documents) et un filtre de PROVENANCE (il change le sens de la demande), en plus de la phrase, du `NEAR`, du préfixe et de l'exclusion. Après : la même question filtrée rend **9 pages dans 6 documents**, `quorum: true`, 200,7 ms. (b) **MOTS VIDES** : `QueryParser.quorumStopwords` (quatre-vingts mots français et anglais, comparés sur la forme repliée) ne sont JAMAIS exigés par le quorum, quelle que soit leur longueur — « dans », « avec », « pour », « cette », « comment », « with », « that », « which »… Ils restent dans la passe STRICTE, qui garde la tête de liste. Effet mesuré sur la question nue : 28 → **32 pages**. (c) **LES SIX PLUS LONGS** : au-delà de `quorumMaximumWords` mots porteurs, le quorum garde les six plus longs (à longueur égale, l'ordre tapé) au lieu de se désarmer — une question en langage naturel en compte souvent sept ou huit, et c'est là que le ET strict échoue. L'énumération reste bornée à C(6,4) = 15 groupes. (d) **`why` NE DIT PLUS `exact` SUR UN HIT DE QUORUM** (PM-14) : le raisonnement « un hit lexical porte tous les mots » est faux dès que l'expression est un OR de sous-ensembles — mesuré, une page portant trois mots sur neuf rendait `kind: "exact"` avec les neuf. `HitExplanation.init` reçoit `quorum:` et rend `partial` avec les mots que l'extrait montre, SANS `terms_missing` (un extrait ne prouve pas une absence). (e) **PLAFOND DE FLOU PAR PORTÉE** : sur les pages SCANNÉES (portée `ocr`, défaut), rien ne change — « rn » lu « m » coûte deux éditions sur un mot court, ce sont les fautes de la MACHINE. Sur tout l'index (repli C2-08 et `--fuzzy-scope all`), le plafond devient **1 de 6 à 8 lettres, 2 à partir de 9** (`TrigramExpander.maxDistance(for:scope:)`, consulté par `fuzzyVariants`) : `Kenvue --fuzzy-scope all` rendait **125 pages** portant « kenne », « kene », « cevue » et en rend **0** ; `Villeurbane` (11 lettres, d = 1) rend toujours ses 29 pages. En portée `ocr`, `Kenvue` rend toujours ses 11 pages, toutes `ocr_accurate` (mesuré). (f) **`SearchResults.fuzzyExpanded`** (calculé : un hit rendu à distance > 0) et la clé `fuzzy_expanded` du JSON : en mode `auto`, l'élargissement a lieu dans la passe ORDINAIRE dès que l'exact rend moins de vingt pages, et `fuzzy_fallback`, qui ne couvre que le repli, laissait lire « Kenvue » dans onze pages qui portent « kene ». `SearchAdvice.fuzzyExpanded` le dit sur stderr.

**Pourquoi elle n'est pas optionnelle.** Environ **10 % des pages** du corpus (38 000 à 50 000 sur ~410 000, §2.5) n'entrent dans l'index que par l'OCR, et le texte reconnu sur une page manuscrite reste bruité même en `.accurate` (37 à 72 % de mots réels sur les manuscrits, mesuré §2.7). Mesuré en v1.0 sur une page de cours manuscrite, en interrogeant avec des termes corrects — la fixture d'origine vit sur le volume externe (annexe A), mais l'ordre de grandeur se transpose :

| Rappel | Score |
|---|---:|
| Correspondance exacte seule | **8 / 18** (44 %) |
| Avec expansion floue | **12 / 18** (67 %) |

Ce que le flou récupère, et à quelle distance : `application` ← `applicabian` (d2) · `volume` ← `volute` (d1) · `enthalpie` ← `estholpie` (d2) · `équilibre` ← `lequilibre` (d1). Ce qu'il ne récupère pas : `Joule` ← `Jarla` (d3), `relation` ← `Retorion` (d3). Au-delà de d2 le bruit l'emporte sur le gain ; ne pas chercher à rattraper ces cas.

**Mécanisme.** SQLite système n'a **pas** `spellfix1`, pas `editdist3`, et n'autorise **aucun** chargement d'extension : `OMIT_LOAD_EXTENSION` est compilé dans le binaire d'Apple, le symbole `sqlite3_enable_load_extension` n'existe même pas (vérifié à l'API C **et** au CLI). Aucun contournement. En revanche le tokenizer **`trigram` est présent et fonctionne** en 3.43.2 — c'est le point que la v1.0 avait manqué. L'expansion se fait donc en trois temps, dont deux en SQL :

1. Le vocabulaire de l'index est lu via `fts5vocab` :
   `CREATE VIRTUAL TABLE vocab USING fts5vocab(page_fts, 'row');`
   Mesuré : **145 605 termes distincts pour 20 968 pages** — identique avec et sans index préfixe, donc D3 n'a strictement aucun effet sur le flou. Extrapolé au corpus complet (loi de Heaps) : **~800 000 à 1 000 000 de termes**.
2. Ces termes sont insérés incrémentalement dans la table **`vocab_tri`** (`tokenize='trigram'`, **detail par défaut**, §4.1), **sur disque, dans la même transaction que l'index**. Vérifié sur la machine : `SELECT term FROM vocab_tri WHERE vocab_tri MATCH 'plica'` rend `applicabian, application` — le cas d'école exact du paragraphe précédent, en SQL pur. Mesuré ici : **145 605 termes → 8,21 Mo en 0,5 s** ; **1 000 000 de termes → 55,5 Mo en 4,2 s**, candidats ramenés en **0,73 ms de médiane** (287 candidats pour `plica` sur le vocabulaire d'un million).

   **Ne pas mettre `detail='none'`**, contrairement à ce que recommandait la contre-expertise : vérifié sur la machine, un `MATCH` trigramme est une requête de **phrase** sur trigrammes et échoue en `fts5: phrase queries are not supported (detail!=full)`. Les 55 Mo sont le prix à payer, et ils sont payables.
3. Les candidats ainsi obtenus passent par une **distance de Levenshtein exacte avec abandon anticipé**, en Swift. C'est ce filtre qui applique le plafond de distance ; le `MATCH` trigramme ne rend que des sous-chaînes, sans classement ni distance.

Ce que ce choix supprime, par rapport à l'index trigramme en mémoire de la v1.0 : **185 Mo de RSS** (mesuré en Swift à 1 M de termes, 260 Mo en Python — et non « quelques dizaines de Mo » comme l'annonçait la v1.0), la reconstruction au démarrage (critère **P9 supprimé**), et l'incohérence entre deux mondes qui s'écrivaient séparément. Ce que cela coûte : **≤ 55 Mo de disque** (mesuré), à compter dans le budget P5 — sans commune mesure avec les ~1,6 Go de `page_fts`.

Deux précautions d'implémentation, mesurées : n'indexer **que le vocabulaire, jamais le corpus** (c'est ce qui garde le coût borné) ; et **ne jamais interroger `vocab_tri` avec le terme entier** — un `MATCH` trigramme étant une recherche de sous-chaîne, le terme entier ne trouverait jamais de voisin à distance ≥ 1 (`TrigramExpander.swift`). La stratégie de sondes utilise deux sondes par morceaux sur le chemin le plus économique : (1) la **moitié-préfixe** (⌈n/2⌉ car.) en balayage de plage sur le B-tree `vocab_seen` (« commence par », ~0,5 ms), et (2) la **moitié-suffixe** (n-⌈n/2⌉ car., ≥ 3) en `MATCH` trigramme sur `vocab_tri` (rowids seuls puis lecture dans `vocab_tri_content`). Comme les deux moitiés sont disjointes, toute édition unique à d = 1 est couverte à 100 %, et d = 2 est couvert dès que les deux éditions tombent dans la même moitié (`volume` ← `volute`, `enthalpie` ← `estholpie`, `équilibre` ← `lequilibre`, `catalyseur` ← `calalyseur`).

**Distance plafonnée selon la longueur du terme.** Règle imposée, **corrigée en v1.1** :

```
longueur ≤ 5  ->  d = 0   (pas d'expansion)
longueur ≥ 6  ->  d = 2
```

Deux raisons, toutes deux mesurées. D'abord, la règle « 4-5 → d = 1 » de la v1.0 ne faisait pas ce qu'elle prétendait : `bayer` et `layer` sont **à distance 1** de `mayer` (une substitution), donc le plafond d = 1 **les inclut par construction** — le test T15 de la v1.0 était insatisfiable. Ensuite, c'est sur les termes courts que le budget P8 se fait manger : à 1 M de termes, `mayer` coûte **10,14 ms** et `polymere` 14,72 ms (Swift `-O`, vocabulaire dense simulé — majorant pessimiste), les deux seuls dépassements de la série. Aux longueurs ≥ 6 sur le vocabulaire réel, l'expansion coûte **0,10 à 1,65 ms** et ramène 4 à 23 voisins pertinents.

Bénéfice collatéral : le tokenizer `trigram` est aveugle sous 3 caractères, et la règle de conception l'est sous 6. La limite technique et la règle produit ne se contredisent jamais.

**Le flou n'est pas activé par défaut sur tout l'index.** Mesuré en v1.0 sur un index de 19 061 pages, l'expansion aveugle multiplie le nombre de pages retournées :

| Terme | Exact | Étendu | Inflation |
|---|---:|---:|---:|
| `catalyseur` | 40 | 78 | +95 % |
| `enthalpie` | 66 | 439 | +565 % |
| `chromatographie` | 10 | 186 | +1 760 % |
| `polymere` | 37 | 1 430 | +3 765 % |

D'où trois règles de conception, non négociables :

- **Portée par défaut : `--fuzzy-scope ocr`.** Le flou ne s'applique qu'aux pages dont `page_src.src != 0`. C'est exactement là où il a été mesuré utile, et cela laisse intacte la précision sur les ~90 % de pages à couche texte propre. Cette jointure est gratuite parce que `page_src` et `page_fts` vivent dans la même base — voir §5.5.3.
- **Mode par défaut : `auto`.** L'expansion n'est déclenchée que si la requête exacte ramène moins de 20 pages. `on` force, `off` désactive.
- **Les correspondances exactes passent toujours devant.** Un résultat obtenu par variante à la distance *d* voit son score BM25 pénalisé d'un facteur `1/(1+d)`, et `Hit.fuzzyDistance` est exposé pour que l'interface puisse le signaler.

> **Amendement du 10/09/2026 (C2-08, lot MP1) — le repli en flou quand la recherche ne rend rien.** La portée `ocr` ci-dessus ne couvre que les fautes de la MACHINE ; les plus fréquentes sont celles de la REQUÊTE, et elles ne dépendent pas de l'origine de la page. Mesuré le 09/09/2026 sur la base de production : `Villeurbane` rendait ZÉRO page alors que trois documents NATIFS portent « Villeurbanne ». `GRDBStore.search(_:excludingDocsMatching:)` — le point unique par lequel passent la CLI, l'application, le serveur MCP et le canal lexical de l'hybride — rejoue donc la requête **une fois** en `fuzzy: .on, fuzzyScope: .all` quand quatre conditions sont réunies : la première passe n'apparie AUCUNE page (`totalPages == 0`, et non « la tranche est vide » — un offset au-delà du dernier résultat n'est pas un échec de recherche) ; la requête porte au moins un mot analysé (`--raw-fts` n'en a aucun) ; `fuzzy != .off` ; et elle n'était pas déjà ce repli. Le résultat porte `SearchResults.fuzzyFallback` (clé ADDITIVE) et les hits gardent leur `fuzzyDistance`. **Le repli est annoncé, jamais muet** : `SearchAdvice.fuzzyFallback` (« No exact match — showing close spellings from every document. ») sur stderr en CLI dans les deux modes et dans `fuzzy_fallback` du JSON, dans `note` côté MCP, et traduit sous le champ de l'application — une recherche qui change de règle sans le dire est pire qu'une recherche qui ne trouve rien. Coût nul sur le chemin normal (aucune requête de plus dès qu'il y a un résultat) ; mesuré sur une copie de la base de production, la seconde passe coûte ~4 ms (`Villeurbanx` : 4,9 ms pour 0 page, 8,7 ms pour 29 pages dans 23 documents). En mode hybride, `HybridResults` ne transporte pas le drapeau : le repli agit sur le canal lexical mais n'est pas annoncé. Corollaire d'interface : le geste « Tolérer les fautes de frappe » de l'état vide ne s'affiche plus que si le réglage est sur « jamais ».

> **Amendement du 03/09/2026 (C2-08, D-R1, lot H1).** Le tri n'impose plus que toutes les correspondances exactes précèdent aveuglément les variantes floues (« exacts devant »). L'ordonnancement s'effectue sur le score scalaire unique `r_final = bm25 / (1 + d)` : à pertinence égale, les correspondances exactes restent favorisées (`ORDER BY r ASC, fz ASC`), mais une page trouvée par flou (d = 1) hautement pertinente bat désormais une page exacte faible ou marginale. `Hit.fuzzyDistance` reste exposé.

**Budget** : expansion ≤ **10 ms** par terme sur un vocabulaire d'un million d'entrées (test P8). Mesuré en Swift `-O` : **0,10 à 1,65 ms** sur le vocabulaire réel de 145 605 termes, 0,99 à 14,72 ms sur un vocabulaire d'un million **dense** — obtenu en synthétisant du bruit OCR autour de chaque terme réel, donc un majorant pessimiste que la règle d = 0 sous 6 lettres ramène sous le plafond. Les chiffres Python de la v1.0 (« 58 ms », « 64 ms ») mesuraient un interpréteur, pas l'algorithme : ne pas s'y référer.

#### 5.5.3 Variantes morphologiques

Trois familles de « termes voisins » existent. La v1 en couvre deux, et il faut le dire clairement à l'utilisateur plutôt que de le laisser croire le contraire.

| Famille | Exemple | Couvert en v1 |
|---|---|---|
| Accents et casse | `polymere` → « polymère » | **oui**, nativement (`remove_diacritics 2`) |
| Morphologie : pluriels, dérivés | `catalyseur` → catalyseurs, catalyser, catalysées | **oui**, par le préfixe `catalys*` et, gratuitement, par l'expansion floue |
| Synonymes et sens proche | « sélectivité des catalyseurs » → « régiosélectivité » | **non** — voir §12 |

L'expansion floue joue le rôle d'un désuffixeur approximatif, ce qui compense l'absence de racinisation française dans FTS5 (le tokenizer `porter` existe bien dans le SQLite système, mais il est anglais). Re-mesuré en contre-expertise, mot pour mot : `catalyseur` ramène `calalyseur(d1), catalyser(d1), catalyseurs(d1), analyseur(d2), catalyse(d2), catalysed(d2), catalysee(d2), catalysees(d2), catalyses(d2)` ; `polymere` ramène `polymer(d1), polymeres(d1), polymers(d1), copolymere(d2), polymerase(d2), polymeric(d2), polymerise(d2)` — plus `polyedre` et `polyene`, qui sont du bruit. Ce n'est pas un vrai racineur Snowball, mais l'écart pratique est faible sur ce corpus, et la porte vers un vrai racineur reste ouverte sans changer de moteur (§12).

> **Amendement du 05/09/2026 (lot R1) — le pluriel se cherche avec le singulier, à la requête.** Le paragraphe ci-dessus se trompait sur l'écart pratique. Mesuré sur la base réelle : `polymere` apparie 1 045 pages dans 108 documents, `polymeres` 1 219 pages dans 161 documents, les deux ensemble 1 694 pages dans 192 documents — le singulier ratait 84 documents, parce que le flou (§5.5.2) ne s'applique par défaut qu'aux pages OCR et seulement sous vingt pages exactes, donc jamais sur une requête qui trouve déjà. `liaison` → +37 % de pages, `cristal` → +33 %, `catalyseur` → +29 %, `enthalpie` 756 → 2 933 pages, `entropie` 435 → 1 333, `spectroscopie` 290 → 1 076. La réponse est à la REQUÊTE, pas à l'index : `Morphology` (Swift, sans base ni dictionnaire) rend les formes d'un mot par règles — +s / −s, al ↔ aux, eau/au/eu → x, y ↔ ies, radical en -ss/-x/-z/-ch/-sh + es — et `GRDBStore.effectiveFTS` réécrit chaque mot nu de la chaîne FTS en `(mot OR forme …)` via `substitute`, hors guillemets, hors `NEAR`, jamais une racine de préfixe. Comptages, facettes, `matchedPageCounts`, extraits, exclusion (`-biologie` écarte aussi « biologies ») et sondes de bonus (la phrase `"polymeres reticules"` vaut `"polymere reticule"`, produit des formes borné à 8 combinaisons ; le nom `docs_fts` reçoit toutes les formes) lisent la même chaîne. Deux garde-fous de longueur : on n'ajoute un s qu'à partir de 4 lettres, on n'en retire un qu'à partir de 6 — `temps`, `corps`, `cours`, `mois`, `fois`, `pays`, `sens` restent intacts ; un radical en -ss (`process`) ne perd pas son s ; « acides » ne devient jamais « acid ». Une forme morphologique vaut d = 0 : dans le plan flou elle entre dans TOUTES les branches (ex et fz), et une variante floue qui coïncide avec elle est dédupliquée par le `GROUP BY … min(fz)`. `QueryWord.variants` porte les formes pour `HitExplanation` (une page qui dit « polymères » porte le mot « polymere » de la requête, et c'est le mot tapé qui est cité) et pour le surlignage de l'application (même couleur que le mot tapé). Un membre de `pres:` n'est pas décliné : FTS5 n'accepte pas de `OR` dans un `NEAR`. `SearchQuery.morphology` (vrai par défaut), `fouine search --no-morphology`. **Effet connu et assumé** : un mot français dont le pluriel est un mot anglais courant voit son total grimper — `energie` 3 498 → 29 005 pages à cause de « energies », `serie` 801 → 28 209 à cause de « series » — mais l'ordre des dix premières reste celui des pages françaises (mesuré : dix pages sur dix portent « energie ») et la facette Langue sépare. Coût : le prix d'une phrase de plus par mot dans le MATCH, +2 à +25 ms selon le nombre de pages appariées.

> **Amendement du 05/09/2026 (lot X1, audit AUDIT-R1) — ce que l'audit du même jour a corrigé et recalé.** ① **Deux mots tapés qui se déclinent l'un vers l'autre ne partagent pas leur forme** (B1) : `entropy entropie` devenait `(entropy OR entropies) AND (entropie OR entropies)`, satisfait par toute page ne portant que « entropies » — 77 pages devenaient 943, `energy energie` 95 → 26 081, et six des dix premières ne portaient aucun des deux mots. `Morphology.variants(of:among:)` retire d'un mot toute forme qui est un autre mot tapé ou une forme d'un autre mot tapé ; les trois surfaces (chaîne FTS, sondes, explication et surlignage) la partagent, et `polymere polymeres` est un vrai ET. ② **Une chaîne FTS5 brute n'est jamais réécrite** (I1) : `--raw-fts` passait par la morphologie, `body:polymere` et `^polymere` sortaient en erreur FTS5 ; `GRDBStore.morphologyApplies` exige des termes analysés. ③ **Le singulier se retire dès cinq lettres** (I3), avec une liste fermée (`temps`, `corps`, `cours`, `fonds`) ; à quatre (`lois`, `ions`), la longueur seule protège `mois`, `fois`, `pays`, `sens`, et le singulier se tape. Les pluriels français en -x ne prennent plus « es » (`metauxes`), seuls `-eux`/`-oux` perdent leur x (M2). ④ **Le plafond de combinaisons des sondes passe de 8 à 27** (M3) : à 8, `metal reseau` (3 × 3) n'avait sa sonde de phrase que sur les formes tapées. ⑤ **Le coût ci-dessus était sous-estimé** (I2). Mesuré par l'audit sur la base réelle, médianes de trois, 50 hits : `complexe` 13 → 203 ms (1 175 → 22 843 pages), `energie` 28 → 254 ms (3 498 → 29 005), `serie` 107 → 293 ms, `theorie` 19 → 68 ms, `analyse` 31 → 86 ms, `hypothese` 15 → 50 ms ; depuis l'application (200 hits et cinq facettes), `energie` 177 → 605 ms, `complexe` 148 → 494 ms. Les dix premières pages restent celles du mot tapé (vérifié sur six mots) ; entre les rangs 11 et 50, 22 pages sur 50 de `entropie` et 24 de `hypothese` ne portent que l'autre forme. La règle reste par défaut **en attendant le banc jugé** (`lexical` contre `lexical-nomorph`, pool `ranking-r1`) ; une sonde « forme tapée présente » est la piste si elle reste. ⑥ Les garde-fous de coût (sondes, diversité, seuil de 50 000 pages) lisent le compte APRÈS expansion (M4) : `metal` en est à 46 051.

> **Amendement du 05/09/2026 (PERSP-Q1, lot P1) — la forme TAPÉE passe devant la déclinaison.** L'amendement ci-dessus laissait un défaut ouvert : entre les rangs 11 et 50, jusqu'à la moitié des pages ne portaient que l'autre forme du mot, et rien ne les distinguait de celles qui portaient le mot tel qu'il avait été tapé. Une **quatrième sonde de classement** le corrige, sur la mécanique exacte des trois du lot M1 : une CTE `tf AS (SELECT rowid AS rid FROM page_fts WHERE page_fts MATCH ?)` dont l'argument est le ET des mots nus **tels que tapés**, repliés et cités (`"entropie"`), sans aucune de leurs formes ; le score des pages qu'elle contient est multiplié par `1 + Schema.typedFormBoost` (0,5). Elle n'est **émise que si la morphologie a effectivement ajouté une forme** à au moins un mot — sinon elle serait vraie pour tout le jeu, c'est-à-dire un facteur constant payé d'une exécution FTS. Elle agit **dès un mot**, contrairement au bonus de nom : c'est un bonus par PAGE, et le débordement de la règle des deux mots venait de ce que le nom vaut pour toutes les pages d'un document à la fois. Elle partage tous les autres garde-fous (aucune sonde sur une requête qui porte déjà une phrase, un `NEAR`, un préfixe ou un `OR` ; désarmée au-delà du seuil de comptage approché, lu APRÈS expansion) ; une page trouvée par variante FLOUE ne la reçoit pas, comme pour `ph`. Elle ne change QUE l'ordre : totaux, facettes et `matchedPageCounts` l'ignorent. **Mesuré le 05/09/2026 sur la base réelle, 50 pages rendues** : sur `polymere`, `entropie`, `hypothese`, `energie`, `complexe` et `enthalpie`, les cinquante premières pages portent désormais **toutes** la forme tapée — contre 35 sur 50 pour `entropie` et 38 sur 50 pour `hypothese` sans la sonde — et **aucune des dix premières ne change de rang** sur aucun des six mots. Coût : médianes de trois, **+2 ms** sur cinq mots, **+29 ms** au pire (`energie`, 29 005 pages appariées). Effet de bord assumé et testé : le facteur 1,5 est du même ordre que la pénalité floue `1/(1+d)`, si bien qu'une page portant le mot tapé repasse devant une page trouvée par coquille d'OCR dont le bm25 n'est pas plus de trois fois meilleur (D-R1 tient — il n'y a pas de barrière, seulement un facteur — mais sa calibration bouge). `SearchQuery.typedFormBoost` (vrai par défaut), `fouine search --no-typed-form`, système `lexical-notypedform` du banc : c'est à lui de dire si la sonde reste.

**Forme de requête imposée** — exact partout, flou restreint aux pages OCRisées, fusionné, **dédupliqué** et classé en une seule interrogation :

```sql
WITH ex AS (
  SELECT doc_id, page, bm25(page_fts) AS r, 0 AS fz
  FROM page_fts WHERE page_fts MATCH :exact
),
fz AS (
  SELECT f.doc_id, f.page, bm25(page_fts) / (1.0 + :d) AS r, :d AS fz
  FROM page_fts f
  JOIN page_src s ON s.doc_id = f.doc_id AND s.page = f.page
  WHERE page_fts MATCH :expanded AND s.src != 0
),
u AS (SELECT * FROM ex UNION ALL SELECT * FROM fz)
SELECT doc_id, page, min(fz) AS fz, min(r) AS r
FROM u
GROUP BY doc_id, page          -- SANS ce GROUP BY, une page OCRisée qui matche
ORDER BY fz ASC, r ASC          -- exactement sort DEUX FOIS : une par branche.
LIMIT :limit;
```

> **Amendement du 03/09/2026 (C2-08, D-R1, lot H1).** La clause de tri imposée devient `ORDER BY r ASC, fz ASC` : le tri est commandé par le score scalaire unique `r_final`, et `fz ASC` ne sert que de départage à score égal en faveur de la variante exacte. Le `GROUP BY doc_id, page` avec `min(fz)` et `min(r)` reste impératif pour la déduplication.

> **Amendement du 05/09/2026 (R-01, D-R2, lot M1) — les sondes de proximité.** Pour une requête d'au moins deux **mots nus substituables** (`isSubstitutable`), sans `"…"`, sans `NEAR`/`pres:`, sans préfixe `*` et sans `OR`, deux CTE de plus, qui ne rendent qu'un rowid :
>
> ```sql
> ph AS (SELECT rowid AS rid FROM page_fts WHERE page_fts MATCH '"t1 t2 … tn"'),
> nr AS (SELECT rowid AS rid FROM page_fts WHERE page_fts MATCH 'NEAR(t1 t2 … tn, 12)'),
> dn AS (SELECT rowid AS did FROM docs_fts WHERE docs_fts MATCH '"t1" OR … OR "tn"')
> ```
>
> `dn` (le nom, D-R3) vaut dès **un** mot ; `ph` et `nr` n'ont de sens qu'à partir de deux. Les trois s'appliquent **après** le regroupement `g`, sur le rowid structuré reconstruit (`doc_id * 100000 + page`) — les branches `ex` et `fz` ne changent pas d'un caractère. L'appartenance se teste par `x IN (SELECT … FROM ph)` et non par un `LEFT JOIN` : SQLite construit alors l'opérande **une seule fois** dans une table éphémère indexée, là où un `LEFT JOIN` sur une CTE laisse le planificateur libre de reparcourir la sonde page par page. Aucun filtre de portée sur les sondes : elles ne répondent que « oui / non » sur des pages que le jeu de résultats a déjà retenues, et les filtrer coûterait une seconde exécution du même MATCH.
>
> **Garde-fou de coût.** Les sondes sont désarmées quand la requête EXACTE apparie au moins `SearchQuery.approximateThreshold` pages (50 000 par défaut) — c'est-à-dire quand `counts()` a déjà cessé de compter. Une sonde de phrase sur deux mots-outils (`the of`, 176 000 pages) parcourt des listes de positions gigantesques : mesuré le 05/09/2026, 1,3 s de recherche devenaient 2,9 s. À ce nombre de pages appariées, l'ordre des dix premières n'est de toute façon plus un choix qu'un humain saurait départager. Sous le seuil, surcoût mesuré sur la base réelle (404 103 pages), trois passes, la plus rapide retenue, sur les 17 requêtes Q1-Q17 : **médiane +0,3 ms**, pire cas **+20,4 ms** sur `phase transition` (6 731 pages appariées, 50 → 70 ms).

Le `GROUP BY doc_id, page` avec `min(fz)` n'est pas une optimisation : c'est ce qui garantit qu'une page trouvée à la fois exactement et par variante est comptée **une fois**, et classée sur son meilleur score. Sans lui, `total_pages` est faux et l'interface affiche des doublons.

Que cette requête tienne en une seule instruction, transactionnellement cohérente avec la file OCR et les métadonnées, est l'argument central en faveur de FTS5 exposé au §3.

### 5.6 Fouine.app — interface

Propriétaire : **A-App**. Tranche C.

Trois panneaux : sources et facettes | résultats | aperçu.

- Résultats groupés par document, dépliables vers les pages ; chaque ligne affiche le chemin relatif, la page, l'extrait avec les termes marqués, et un pictogramme de provenance (natif / OCR / OCR importé). **Pas de `List` au-delà de ~2 000 lignes** : au-delà, passer par `LazyVStack` dans un `ScrollView`, ou pagination.
- Aperçu PDF via `PDFView`. Sur une page à couche texte native : `PDFPage.selection(for:)` ou `findString`, puis `PDFSelection.setColor(_:)` — une couleur distincte par terme de la requête, comme FoxTrot.
- **Sur une page OCRisée**, la couche texte n'existe pas dans le fichier : lire `ocr_layout`, dénormaliser les boîtes vers le `mediaBox` de la `PDFPage`, et poser des `PDFAnnotation(bounds:forType:.highlight)`. C'est ce qui rend l'aperçu utile sur la moitié scannée du corpus.
- Champ de recherche secondaire dans le document ouvert → `SearchQuery.inDocIDs` ; et « rechercher dans les résultats », qui repasse les `doc_id` du jeu courant dans le même champ.
- Historique des requêtes, et autocomplétion depuis `fts5vocab` — gratuite, la table `vocab_tri` étant déjà là.
- Raccourci global ⌥⌘F ouvrant la fenêtre de recherche.
- **Racine indisponible** (dossier déplacé, supprimé, volume externe absent, autorisation TCC révoquée) : les résultats restent consultables — l'index est sur le SSD interne —, l'aperçu affiche un état explicite nommant la racine et l'action à faire. Ne jamais planter, ne jamais vider l'affichage.
- **Premier lancement : demander l'accès à `~/Documents` avant tout.** C'est l'app, et elle seule, qui peut faire apparaître l'invite TCC ; l'agent du §5.7 en est incapable (§7.1). Un premier lancement qui n'a pas déclenché l'invite condamne l'agent au refus silencieux.

> **Amendement du 04/09/2026 (A2-07, A2-11, A2-14, lot K2).** Trois précisions au §5.6. **(1) L'invite TCC ne part plus au premier lancement, mais à l'ajout du premier dossier.** La décision D1 (§1) a supprimé toute racine implicite : une base neuve reste vide, `ContentView` montre l'écran d'accueil, et il n'y a rien à sonder au lancement. L'invite tombe donc sur un geste que l'utilisateur vient de faire — « Ajouter un dossier… », ou le dépôt d'un dossier sur la fenêtre —, ce qui est meilleur ; `WelcomeView` la prépare en toutes lettres. Le paragraphe « Premier lancement : demander l'accès à `~/Documents` avant tout » vaut désormais pour ce moment-là, pas pour le lancement. **(2) Les feuilles d'indexation et d'OCR ne sont plus des huis clos.** Une feuille SwiftUI est modale à la fenêtre : elles portent un bouton « Continuer en arrière-plan » qui les ferme sans arrêter la passe, la progression basculant dans le bloc de la barre latérale, avec « Arrêter ». Le budget d'un lot d'OCR lancé depuis l'application vaut **30 minutes par défaut**, non « sans limite ». La fin d'une passe ne rouvre aucune feuille. **(3) L'état explicite d'un aperçu indisponible porte SON geste, pas un geste générique.** « Nomme la racine et l'action à faire » se lit maintenant à la lettre : un fichier déplacé propose « Afficher l'emplacement attendu » et « Indexer maintenant », un disque débranché « Retester les dossiers », une autorisation refusée « Ouvrir les Réglages Système » — et jamais l'inverse. Un état sans geste utile n'affiche aucun bouton.

> **Amendement du 03/09/2026 (B1-14, B1-26, lot I1 — registre du bandeau de santé).** Le bandeau d'état de la barre latérale (quatre lignes : indexation en arrière-plan, index, recherche sémantique, dossiers) obéit à une règle de sévérité : **orange** seulement si l'utilisateur doit faire un geste pour retrouver une fonction promise (agent enregistré qui ne démarre pas, accord à donner dans Réglages Système, service introuvable, disque débranché, dossier dont la lecture est refusée) ; **rouge** seulement si des données sont en danger ou une fonction est cassée ; **vert** pour tout le reste, et une ligne verte ne porte pas de bouton (seule exception : « Aucun dossier à indexer » propose « Ajouter un dossier… »). Le bandeau détaillé ne s'affiche que si une ligne n'est pas verte ; sinon une pastille « Tout fonctionne ». Un verrou d'écriture **tenu** est une activité normale, dite comme telle avec l'heure de début (« L'index se met à jour (indexation en arrière-plan, depuis 10:32) ») ; un verrou **périmé** se répare seul à l'écriture suivante (`ExclusiveLock.stamp`) et se dit « Index disponible ». Une option absente (modèle sémantique non installé) ou en préparation (installé, aucune page vectorisée) est verte. Aucun texte du bandeau, de l'écran d'échec d'ouverture ni des feuilles ne dit « verrou », « pid », « vecteur », « schéma » ou un UUID : ce vocabulaire reste dans la CLI (`fouine doctor`, `--json`) et les journaux. L'écran d'échec d'ouverture lance son diagnostic par le `fouine` embarqué (`Contents/Helpers/fouine doctor`, 30 s, hors du fil principal) et en montre la sortie dans une feuille avec « Copier » ; l'app ne pilote pas le Terminal (pas de droit `automation.apple-events`, §11.2).

> **Amendement du 05/09/2026 (R-06, R-04, A1-08, lot U1) — « pourquoi ce résultat ».** Sous l'extrait du résultat **sélectionné**, et sous lui seul, une ligne discrète dit pourquoi cette page est là : tous vos mots y sont, une partie seulement (en nommant ce qui manque), une orthographe proche (les deux graphies côte à côte), aucun de vos mots mais le même sujet, ou les deux canaux. La phrase ne porte **aucun nombre** — ni la distance de la variante, ni la marge en écarts-types, ni le pourcentage de pertinence : ces chiffres restent dans les infobulles existantes. Les mots cités sont ceux de l'utilisateur, entre les guillemets de sa langue ; un terme exclu (`-mot`) n'est jamais nommé. Elle se calcule à la sélection, sur le texte indexé de la page, hors du fil principal, et s'efface avant la lecture suivante — jamais de phrase périmée. VoiceOver la lit dans la **valeur** de la ligne, avec l'extrait. Le noyau est une fonction PURE de FouineCore (`HitExplanation`) qui ne lit pas la base : l'appelant apporte le texte, et un paramètre dit s'il s'agit de la page entière ou d'un extrait — depuis un extrait, on ne conclut jamais qu'un mot manque, un hit lexical les portant tous par construction. **Deuxièmement**, en recherche par le sens, quand le canal plein texte n'a trouvé **aucune** page et que des résultats sortent quand même, la ligne d'état le dit (« Aucun de vos mots n'apparaît dans vos documents : ces résultats sont proposés par le sens seulement »), et `SearchAdvice.noLexicalMatch` porte la même phrase en anglais pour `fouine search --hybrid` et le `note` de `fouine_search`. Ce n'est **pas** un filtre : `docs/recherche.md` § 3 donne la mesure qui l'interdit. **Troisièmement**, chaque hit de `fouine search --json` et de `fouine_search` gagne un objet `why` (`kind`, `terms_found`, `terms_missing`, `typed`, `found`, `distance`), calculé sur l'extrait.

> **Amendement du 08/09/2026 (INT-L1, lot L1) — lien profond `fouine://` et citation à la page.** Le §5.6 se complète de deux gestes symétriques : **citer** une page trouvée, et **rouvrir** Fouine dessus. **(1) Citer.** Le panneau d'aperçu, le menu contextuel d'une ligne de résultat et le menu Édition (⇧⌘C, sur la sélection) proposent « Copier une référence vers cette page », avec deux issues : la **référence** — deux lignes, « <nom du fichier>, page N » puis le lien SEUL sur la seconde, parce qu'une adresse suivie de texte cesse d'être cliquable dans Mail, Notes et les traitements de texte — ou le **lien** seul. Le même lien part dans la colonne `link` de l'export des résultats, dans chaque hit de `fouine search --json` et dans les quatre outils du serveur MCP qui rendent une page (`fouine_list_documents` le rend sans page : un listage désigne des documents). **(2) Rouvrir.** L'application déclare le schéma d'URL `fouine` (`CFBundleURLTypes`) et accepte deux hôtes : `fouine://open?path=<chemin absolu>&page=<n>[&q=…]`, forme **canonique** qui survit à une réindexation, `fouine://open?doc=<id>&page=<n>[&q=…]`, forme de **repli** émise seulement quand le chemin absolu est inconnaissable (volume démonté) et qui ne vaut que sur cette machine et cet index, et `fouine://search?q=…`. Un lien ouvre la page dans la fenêtre d'aperçu détachée existante — le chemin du double-clic, pas un chemin à lui — et, s'il porte `q`, rejoue la recherche dans ce document. Un lien malformé, une page nulle, un `doc` non entier ou un chemin relatif sont REFUSÉS plutôt que réparés : un lien à moitié compris ouvrirait une autre page que celle citée. Un document que Fouine ne connaît plus donne une feuille qui le DIT, avec le nom du fichier et « Ouvrir le fichier » quand celui-ci existe encore — jamais un aperçu vide et muet. Aucune migration de schéma : la résolution d'un chemin absolu passe par `VolumeResolver` puis une sonde sur `(vol_uuid, rel_path)`.

> **Amendement du 10/09/2026 (BU-02, BU-03, AP-01, lot UX1) — l'index s'ouvre au lancement, et un refus a une issue.** Trois précisions au §5.6. **(1) L'ouverture de l'index ne dépend plus d'une fenêtre.** Elle était portée par le `.task` de la fenêtre principale : un lancement qui n'en ouvre aucune — élément d'ouverture de session, restauration d'état — laissait l'application vivante et l'index fermé, le panneau de la barre des menus sur « Vérification… », l'interrupteur de mise à jour automatique grisé et la recherche répondant par un message de développeur non traduit (reproduit 3 fois sur 3 le 09/09/2026). L'ouverture part désormais d'`applicationDidFinishLaunching`, quel que soit le chemin de lancement ; elle reste jouable une seule fois par processus, et le `.task` de la fenêtre l'ATTEND au lieu de la refaire, pour ne rejouer ensuite que ce qui a besoin d'une fenêtre. « Ouvrir Fouine » (menu Fenêtre, icône du Dock, panneau de la barre des menus) doit faire NAÎTRE la fenêtre qui n'a jamais existé : l'action d'ouverture de scène est retenue par le panneau de la barre des menus, qui vit dès le lancement. Un index non ouvert se dit en une phrase du produit, jamais par l'erreur du moteur. **(2) Aucune lecture d'état d'enregistrement de l'agent ne se fait sur le fil principal.** `SMAppService.status` est un aller-retour XPC synchrone vers `smd` ; la sonde de l'application le jouait toutes les deux secondes sur le fil principal, et sur une machine où `smd` traîne (enregistrement `launchd` orphelin) l'application se fige — 162 échantillons sur 162 le 09/09/2026. Le statut se lit hors du fil principal et se donne aux rendus, qui ne l'interrogent plus. **(3) Un refus d'ajout de dossier porte le geste qui le répare.** L'alerte « Dossier non ajouté » n'avait qu'« OK » : quand le refus vient d'une lecture interdite (autorisation, droits du fichier), elle porte « Ouvrir les Réglages Système » et « Réessayer » ; quand il vient d'un dossier disparu, vide ou refusé par la politique des racines, elle n'en porte pas — il n'y a rien à autoriser. La nature du refus voyage comme une DONNÉE depuis l'endroit qui le fabrique, jamais par relecture du texte affiché.

> **Amendement du 10/09/2026 (BU-01, lot SI1) — ce que le lien `fouine://` ouvre, et ce qu'il n'ouvre plus.** La feuille « Fouine ne connaît pas ce document » proposait « Ouvrir le fichier » dès que `fileExists` était vrai, et le bouton faisait `NSWorkspace.shared.open` sur le chemin PORTÉ PAR LE LIEN : `fouine://open?path=/System/Applications/Calculator.app` donnait une fenêtre à l'aspect de Fouine, passée au premier plan par une page web, annonçant « Calculator.app » avec un bouton bleu qui aurait lancé la Calculette (reproduit à l'écran le 09/09/2026). Le geste n'est désormais offert que pour un **document que Fouine aurait pu indexer** : un fichier ORDINAIRE, SOUS une racine suivie (comparaison sur chemins standardisés avec le `/` final — `/Users/x/Docs2/a.pdf` n'est pas sous `/Users/x/Docs`), et NON EXÉCUTABLE. Un dossier, un exécutable, un fichier hors racines : pas de bouton. Un paquet est refusé sauf si son extension est un format indexé par Fouine — un `.rtfd` est un dossier et reste un document, un `.app` n'en est pas un. Sans racine connue (l'index pas encore ouvert), rien n'est ouvrable. La décision reste PURE (`DeepLinkRouter.action(for:resolve:probe:roots:)`) et la feuille dit, quand le fichier existe sans être ouvrable, « Il est en dehors des dossiers que Fouine surveille : Fouine ne l'ouvrira pas. »

> **Amendement du 08/09/2026 (INT-S1, lot S1) — Fouine dans Spotlight.** Le §5.6 se complète d'une remise à l'index de Spotlight (`CSSearchableIndex`) : Fouine DONNE ses documents à la loupe de macOS, un résultat donné s'affiche sous son nom, et le clic la rouvre sur la page par le `DeepLink` de l'amendement INT-L1 (`CSSearchableItemActionType`, identifiant `doc:<id>`, requête `CSSearchQueryString` quand Spotlight la transmet). **La portée est une soustraction, et c'est le point** : par défaut Fouine ne donne que ce que Spotlight ne sait PAS lire — les documents dont au moins une page vient de l'OCR, et les formats mesurés muets le 08/09/2026 par `mdimport -t -d2` sur de VRAIS fichiers (`djvu`, `cbz`, `cbr`, `epub`, `ai`, `sketch`, `fig`, `indd`) —, parce que donner un `.docx` ou un PDF natif, que macOS lit déjà, produirait deux résultats pour un seul fichier. Trois réglages : `spotlight.enabled` (vrai), `spotlight.all_documents` (faux), `spotlight.text_kb` (1024, coupé sur une frontière de page, jamais au milieu), plus un marqueur interne `spotlight.synced_at` hors catalogue. La remise se fait en fin d'`IndexPass` et d'`OCRPass`, jamais dans un adaptateur, et **une erreur de Spotlight n'est jamais une erreur d'indexation** : elle devient une note de journal, le marqueur n'avance pas, la passe suivante refait la remise. Seule l'APPLICATION donne : la commande `fouine` n'a pas de bundle, et l'agent d'arrière-plan emprunte l'identité de l'app sans en être l'exécutable — la même configuration qui TERMINE le processus dans `UNUserNotificationCenter` (§5.7, notifications) ; ce qu'ils indexent part au rattrapage du lancement suivant. La désinstallation (§5.6, D13) retire les documents donnés avant d'effacer l'index. AUCUNE migration de schéma : `docs.indexed_at` existait, et `completeOCR` la touche désormais aussi, sans quoi le texte d'un scan n'aurait jamais été « changé ».

> **Amendement du 08/09/2026 (INT-R1, lot R1) — Fouine dans Raccourcis (App Intents).** Le §5.6 se complète de trois actions offertes à l'application **Raccourcis** de macOS, et — sur macOS 26 — proposées dans Spotlight : **« Chercher dans Fouine »** (paramètres `query` et `limit`, 1 à 50, 10 par défaut ; rend une liste de pages ; ne met PAS l'application au premier plan), **« Ouvrir dans Fouine »** (prend une page, met l'application au premier plan) et **« Obtenir le texte d'une page »** (rend le texte de l'index, plafonné à 20 000 caractères avec une note de troncature visible ; jamais le fichier d'origine). Une page trouvée est une entité `FouineHitEntity` d'identifiant `<docID>:<page>`, portant nom de fichier, page, extrait (240 caractères, coupé sur une frontière de mot), dossier, chemin et lien `fouine://`. **Rien n'est réinventé** : la requête passe par `QueryParser.searchPlan`, exactement comme `fouine search` (lexical, flou `auto`) ; l'ouverture se fait en ouvrant le lien `fouine://` de l'amendement INT-L1, que le routeur existant reçoit ; le lien vient de `DeepLink.link(absolutePath:docID:page:)`. Le canal sémantique est EXCLU : il charge un modèle CoreML, et une action de Raccourcis doit répondre tout de suite. Chaque action ouvre sa PROPRE lecture seule (`GRDBStore.openReadOnly`, aucun `fouine.lock`) : Raccourcis lance l'application en arrière-plan, sans que `AppModel.start()` ait tourné. Une base absente est DITE (« Fouine n'a encore rien lu — ouvrez Fouine et ajoutez un dossier ») et non rendue comme une liste vide. Côté empaquetage, le §11.2 se complète d'une étape obligatoire : `Packaging/bundle.sh` fabrique `Contents/Resources/Metadata.appintents` avec `appintentsmetadataprocessor`, à partir des `.swiftconstvalues` que `make release-build` fait émettre — sans ce dossier, l'application n'a AUCUNE action dans Raccourcis, et l'étape échoue net plutôt que de livrer un bundle muet. Les titres, descriptions et paramètres des actions sont traduits (catalogue de l'app) ; les phrases dictées à Siri restent en anglais seulement — les localiser exigerait un catalogue `AppShortcuts.strings` hors du chemin d'`add-strings.py`. AUCUNE migration de schéma, aucune écriture.

> **Amendement du 08/09/2026 (INT-M1, lot M1) — mini-recherche dans la barre des menus.** L'icône de la barre des menus (amendement UX-07) cesse d'être un simple menu d'état : sa scène `MenuBarExtra` passe en style **`.window`** et porte un panneau de 360 points — un champ de recherche qui prend le focus à l'ouverture, les **huit** premières pages trouvées, puis, sous elles, les MÊMES lignes d'état et les MÊMES gestes qu'avant (`MenuBarModel.items` inchangé, seul le rendu suit le passage du menu au panneau). Une ligne de résultat porte le nom du fichier, le numéro de page et l'extrait sur une ligne ; les pages d'un même document se suivent, sans que l'ordre du moteur soit modifié. Le panneau interroge le canal **lexical seul**, avec les options par défaut de la fenêtre (flou `auto`, aucun filtre) : il doit répondre tout de suite, et le canal vectoriel charge un modèle. Il n'a **aucun état commun** avec la fenêtre — `MenuBarSearchModel` est distinct de `SearchModel`, et taper ici ne touche ni les filtres, ni la sélection, ni la requête posée là-bas. Gestes : ⏎ passe la requête à la grande fenêtre (qui s'ouvre et l'exécute), un clic — ou ⏎ sur une ligne désignée par ↑↓ — ouvre la page dans la fenêtre d'aperçu détachée (le chemin du double-clic, `HitKey`), ⌘-clic ouvre le fichier dans son application, Échap ferme le panneau, ⌘Q quitte ; « Voir tous les résultats dans Fouine » paraît dès qu'il y a plus de huit pages. Le raccourci global ⌥⌘F garde son rôle : il ouvre la GRANDE fenêtre. VoiceOver annonce chaque ligne « <nom du fichier>, page N, <extrait> ». La liaison `isInserted` reste celle qui n'écrit que si la valeur change (pièges connus) : le style `.window` ne change rien à ce piège.

> **Amendement du 04/09/2026 (UX-01 à UX-11, session accessibilité).** Cadrage : `PLAN.md`. La barre latérale porte une carte « Index » unique qui remplace le bandeau de santé (dont l'évaluateur reste en entrée), la section Indexation et les blocs de progression disjoints. Elle reflète un état unique (`IndexStatus`) calculé selon une règle de priorité stricte : vérification (`checking`) › aucun dossier (`noFolders`) › passe manuelle de l'application › attention (`needsAttention`) › écriture par un autre programme › mise à jour automatique › au repos (`idle`). La carte n'offre qu'un seul bouton principal d'action, assorti d'un éventuel geste secondaire discret. L'application ne montre rien de décidé au démarrage avant d'avoir lu les racines et le statut de mise à jour (suppression de l'écran d'accueil et du bouton « Ré-enregistrer » furtifs). Une scène `MenuBarExtra` dans la barre des menus reflète en permanence ce même état. Fermer la dernière fenêtre ne quitte plus l'application quand la barre des menus est active (passage en mode accessoire) ; l'ouverture de Fouine à l'ouverture de session est proposée (`SMAppService.mainApp`). Le vocabulaire visible sans jargon (tableau de `PLAN.md` § 2 : plus d'« agent », ni d'« OCR » seul, « verrou », « vecteur », « racine », etc.) s'impose à tout texte de l'interface. Les réglages sont réagencés en six onglets : Général, Dossiers, Indexation, Recherche par le sens, Mises à jour, Avancé.

> **Amendement du 10/09/2026 (PR-06, PR-24, lot BR1) — on peut parcourir, et redemander une lecture.** ① **Une scène s'ajoute : « Tous vos documents » (⌘⇧L, menu Fenêtre).** Le §5.6 décrivait trois panneaux qui supposent tous une requête ; l'application ouvrait donc sur un champ vide, sans qu'aucun geste ne réponde à « qu'est-ce que Fouine connaît ? » — alors que le cœur le sait (`listDocuments`, palier 4) et que le serveur MCP le rend. La fenêtre est unique (une `Window`, comme « Documents que Fouine n'a pas pu lire »), lue **hors du fil principal** par `StoreService`, paginée par tranches de 200 sur l'ordre TOTAL du cœur (`limit`/`offset`, jamais un tri en mémoire), et porte quatre commandes : filtrer par nom (relance 300 ms après la frappe), dossier, type (les extensions présentes), ordre `Récents | Nom | Pages`. Une ligne ouvre l'aperçu du document à sa page 1 par la table des fenêtres d'aperçu (BU-19 : une par document, trois au plus) ; son menu contextuel reprend les trois gestes de la liste de résultats. Les documents en échec y figurent **avec** leur motif : les cacher recréerait le trou. Le compte du pied de la carte « Index » devient le geste qui l'ouvre (patron `PageCountAffordance` : la décision vit dans un type pur, `DocumentCountAffordance`), sans casser le rôle de texte statique de la ligne pour VoiceOver (BU-15). ② **« Relire cette page »** paraît dans le menu contextuel de l'aperçu **seulement** quand la page affichée vient de l'OCR (`page_src.src`), et remet cette page en file (`requeueOCRPage`, priorité de fond 3, `writeLocked`) ; la carte « Index » annonce de son côté les pages douteuses et sans ligne (`pages_ocr_low_conf + pages_ocr_no_lines`) avec le geste qui remet les deux populations en file. **Rien ne démarre** : la file est consommée par la mise à jour automatique ou par « Lire les pages scannées » — c'est la règle du §5.7, et un clic ne doit pas lancer une heure de reconnaissance. Un verrou d'écriture tenu donne la phrase d'attente de l'application, jamais un message du cœur.

> **Amendement du 12/09/2026 (IX2, demande du propriétaire, lot IX2) — la carte dit l'essentiel, le détail a sa fenêtre, la barre des menus ne parle plus d'indexation.** ① **La carte « Index »** ne peint plus que la phrase d'état et sa précision, la barre d'un travail en cours, AU PLUS UN bouton — l'action principale de l'état, sauf « Lire les pages scannées… » —, la phrase de place disque seulement quand la place manque pour finir (`DiskSpaceNotice.tight`) et un lien « Détails… ». Pendant un travail, la précision n'est plus le nom du document ni « n / total pages » (ils changent toutes les deux secondes dans 230 points) : c'est le temps restant quand il est connu, la phrase de l'écriture par un autre programme dans ce cas, sinon rien. Quittent la carte les comptes, les documents illisibles, les pages mal lues et leur geste, le premier seuil de place disque, l'action secondaire et « Depuis votre dernière visite ». Le tri est un type pur (`IndexCardSummary`). Sous l'interrupteur, plus aucune confirmation (« … est activée », « … a été relancée ») : la carte dit déjà l'état, et l'attente d'accord de macOS a son propre état d'attention ; seul un refus ou un échec s'y affiche (`AutomaticUpdatesMessage`), parce qu'un interrupteur revenu en arrière sans dire pourquoi est le pire des cas. ② **Une scène s'ajoute, « Votre index »** — une `Window`, élément du menu Fenêtre sans raccourci, sur le patron de « Tous vos documents » ; ni l'onglet Réglages ▸ Indexation (des réglages, pas un état), ni un menu système (pas d'explication possible). Quatre parties : ce que fait Fouine (précision complète, « n / total pages », actions principale et secondaire ; un geste qui s'accroche à la fenêtre principale la ramène d'abord, `IndexAction.needsMainWindow`) ; la mise à jour automatique (le même interrupteur, sa phrase d'aide, la réponse du dernier geste confirmations comprises, le renvoi à Réglages ▸ Indexation) ; ce que l'index contient (comptes et geste « Tous vos documents », documents illisibles, « Depuis votre dernière visite » sans croix, place disque aux deux seuils) ; les pages scannées sans texte lisible, s'il y en a. ③ **Plus de relecture en masse.** L'amendement précédent (PR-24) donnait à la carte un geste qui remettait en file `pages_ocr_low_conf + pages_ocr_no_lines` et annonçait « … seront relues à la prochaine lecture des scans ». Mesuré sur la production le 12/09/2026, file d'OCR vide : 3 157 pages sans ligne et 1 053 douteuses toujours là. La relecture passe par le même moteur avec les mêmes réglages (Vision `.accurate` rév. 3, mêmes langues, rendu 150 dpi) et rend le même résultat : la phrase promettait un mieux qui ne vient jamais, et l'état « en file », tenu en mémoire, la montrait encore file vidée. Le geste, son accusé et `StoreService.requeueOCRPages` sont retirés de l'application ; la fenêtre dit les deux populations séparément (`ScannedPagesWithoutText` : une page sans texte reconnu est le plus souvent blanche ou dessinée, une page aux lettres incertaines peut faire manquer un mot), sans bouton, et renvoie au seul cas où relire change quelque chose — une langue qu'on vient de cocher, puis « Relire cette page » dans l'aperçu. Ce geste par page est maintenu ; sa confirmation dit désormais que le texte ne change que dans ce cas. `fouine ocr requeue` reste en ligne de commande. ④ **La barre des menus ne montre plus l'état de l'index.** L'amendement UX-07 (« une scène `MenuBarExtra` reflète en permanence ce même état ») et, dans l'amendement INT-M1, « les MÊMES lignes d'état et les MÊMES gestes qu'avant » cessent de valoir. Le panneau porte le champ, les résultats et « Tout voir dans Fouine », puis « Ouvrir Fouine » (⌘0) et « Quitter Fouine » (⌘Q), dont l'aide — l'index continue de se mettre à jour après la fermeture — n'est posée que si la mise à jour automatique est allumée. L'icône est fixe (`text.magnifyingglass`) : un pictogramme d'attention ouvrirait un panneau qui n'en dit plus rien. La liaison `isInserted` et le focus du champ ne changent pas.

> **Amendement du 13/09/2026 (PV1, demande du propriétaire, lot PV1) — un aperçu pour chaque format, et les horodatages des sons et des vidéos.** Le §5.6 ne décrivait que deux aperçus : le PDF et, depuis l'audit U4, le texte indexé. ① **Quatre voies, décidées par l'extension** (fonction PURE, `PreviewRouting.route(ext:)`) : le lecteur PDF ; une page rendue en image (archives de bandes dessinées, OOXML, images, maquettes) ; un **lecteur de média** ; et, pour tout le reste, le **Coup d'œil du système** (`QLPreviewView`, DANS le panneau) ou le texte indexé. L'en-tête porte alors un sélecteur **« Document | Texte »** ; le mode choisi vaut pour la SESSION et n'entre pas dans les préférences — un réglage d'affichage qui survit à l'extinction sans figurer nulle part est une surprise. Le mode proposé d'emblée est « Document » pour les formats que macOS DESSINE (`.rtf`, `.rtfd`, `.doc`, `.odt`, `.xls`, `.ppt`, iWork, `.html`, `.htm`, `.webarchive`, `.svg`, `.ai`, `.csv`, `.tsv` — liste établie le 13/09/2026 par `qlmanage -p`, `QLThumbnailGenerator` et `qlmanage -m plugins`), « Texte » pour les autres, dont `epub` (aucun générateur, Livres n'en fournit pas) et les formats texte, dont le Coup d'œil ne montrerait que les mêmes caractères sans la mise en évidence des mots cherchés. Le surlignage n'existe QUE dans « Texte » : macOS dessine la page, Fouine n'y a pas la main, et l'infobulle du sélecteur le dit. Le Coup d'œil sur Espace (`QLPreviewPanel`) ne change pas. ② **Un son ou une vidéo** montre un `AVPlayerView` et, en dessous, la page transcrite, dont chaque repère `[mm:ss]` ou `[h:mm:ss]` devient un bouton qui déplace la tête de lecture. Les repères sont ABSOLUS depuis le début de l'enregistrement (`SpeechTranscriber`), et leur lecture est un modèle pur (`TranscriptMarkers`) : `[12]` et `[1990]` n'en sont pas. À l'ouverture d'un résultat, **rien ne démarre** et la tête se pose sur le repère qui ouvre le paragraphe de la première occurrence trouvée. Une ligne de résultat dont la page vient d'une transcription porte une pastille « ▶ 12:40 » — le repère de son extrait, sinon le début de sa page — et le libellé parlé dit « à 12:40 ». ③ **Le lien profond gagne `t=<secondes>`** (amendement INT-L1) : « Copier la référence » d'une page de média cite le MOMENT (« cours.m4a, 12:40 ») et non le numéro de page, et le lien rouvre Fouine avec la tête de lecture posée. Un `t` illisible est ignoré — là où une page illisible refuse le lien entier — et il ne suit pas une page hors bornes (BU-18). `fouine search --json` et le serveur MCP ne l'émettent pas. ④ **Volume débranché** : l'aperçu texte du §5.6 (audit U4) porte désormais une phrase — « Le disque qui contient « X » n'est pas branché — voici le texte que Fouine avait gardé » — et un bouton « Copier ce texte ». Aucune migration de schéma, aucune écriture, aucune lecture nouvelle de la base.

### 5.7 FouineAgent — indexation en arrière-plan

Propriétaire : **A-Pack**. Tranche D.

Enregistrement par `SMAppService.agent(plistName:)` depuis un interrupteur de l'app — pas de plist déposé à la main. L'agent surveille FSEvents sur les racines enregistrées, lance crawl delta + extraction à chaque salve, et n'entame l'OCR que si **toutes** ces conditions sont vraies :

```
alimentation secteur  ·  isLowPowerModeEnabled == false
CPU_Speed_Limit ≥ 70 %  ·  thermalState ∈ {.nominal, .fair}
verrou fouine.lock disponible  ·  chaque racine active lisible
```

`thermalState` seul ne suffit pas : mesuré, il reste à `.fair` pendant que le CPU est bridé à 46 % (§7.4). C'est `CPU_Speed_Limit` qui pilote, et il descend la concurrence de 4 à 2 avant de suspendre.

Il s'interrompt proprement dès qu'une condition tombe, en laissant la file cohérente.

> **Amendement du 11/09/2026 (PR-21, MO-07, lot AG1) — l'agent prépare aussi la recherche par le sens.** Le §5.7 ne connaissait que l'OCR, et la campagne de vecteurs (§12) restait `fouine embed` : une commande de terminal, une campagne de trente heures d'un bloc, sur un public qui n'ouvre pas de terminal. La carte « Index » disait honnêtement « 274 244 sur 408 951 pages sont prêtes · environ 8 h » et c'était le SEUL chemin. L'agent entame désormais, **après l'OCR et sous les six mêmes conditions**, un lot de vecteurs de `agent.embedBudgetMinutes` minutes (10 par défaut, plage 1–120), commandé par `agent.prepareMeaning` (**vrai** par défaut). Quatre garde-fous s'ajoutent aux six conditions, dans cet ordre : ① la file d'OCR doit être **vide** — `completeOCR` invalide les vecteurs de la page qu'il réécrit, une page vectorisée avant sa reconnaissance le serait deux fois ; ② le modèle CoreML doit être installé ; ③ il doit rester des pages incomplètes (`indexedPageCount − completeVectorPageCount`, deux comptes déjà existants, payés une fois par tour d'horloge et seulement quand le réglage est armé) ; ④ le verrou de campagne `fouine-embed.lock` (C2-11) doit être libre — pris pour la durée du lot et rendu à la fin, si bien qu'une campagne lancée à la main peut passer entre deux lots. La décision reste **pure** (`Agent.tick` prend une `AgentEmbedSituation`, `Agent.meaningVerdict`, `Agent.postEmbedBatchTick`) ; une condition qui tombe **pendant** un lot l'interrompt entre deux lots d'inférence (`EmbedRun.shouldStop`, conditions relues au plus toutes les 30 s pour ne pas lancer `pmset` toutes les cinq secondes) ; le moteur (~90 Mio) est gardé entre deux lots consécutifs et **libéré** dès le repos. `agent_status` gagne la phase `preparing_meaning` avec `done`/`total` en pages, que l'application rend par l'activité qu'elle affiche déjà pour sa propre campagne ; `fouine status` et `fouine doctor` portent une ligne `meaning`, et un marqueur interne hors catalogue (`agent.lastEmbedBatchAt`) dit la date du dernier lot. Ce qui reste **hors** de cet amendement, faute de pouvoir le mesurer honnêtement : toute estimation d'électricité ou de chaleur, et tout ordre de préparation « ce dossier d'abord ».

> **Amendement du 15/09/2026 (DF1, version 1.0.1) — la préparation en arrière-plan redevient un choix.** `agent.prepareMeaning` passe à **faux** par défaut (décision du propriétaire, 15/09/2026). L'amendement AG1 ci-dessus reste entier — les quatre garde-fous, la décision pure, `agent_status`, la ligne `meaning` — mais l'agent ne l'exerce que si la case « Préparer aussi la recherche par le sens en arrière-plan » est cochée, ou si le bouton « Préparer la recherche par le sens… » de la barre latérale (qui s'affiche tant que la case est décochée) a lancé une campagne. `fouine doctor` ne signale donc plus, sur une installation neuve, un réglage armé sans modèle.

> **Amendement du 13/09/2026 (PM-05, PM-09, lot MC3) — l'ordre de la campagne de
> vecteurs, et ce qu'elle n'infère plus.** ① **`roots.pinned` gouverne aussi la
> préparation du sens.** Le réglage n'était consommé que par la file d'OCR
> (`OCRPriority`, `IndexPass`) : mesuré sur la production, les deux racines
> épinglées portaient EXACTEMENT zéro vecteur pendant que la troisième, non
> épinglée, en était à 73 % — la sélection de lot balaie par `rowid`,
> c'est-à-dire par ordre de découverte des documents, et les racines ajoutées en
> dernier portent les identifiants les plus hauts. La priorité se joue en
> **phases** et non par un `ORDER BY` : le curseur de reprise (audit V2) suppose
> un balayage de rowid croissant, et trier par priorité avant le rowid le
> rendrait faux dès le second lot. Une phase restreinte aux racines épinglées,
> curseur reparti de zéro, puis une phase sans restriction. La restriction est
> une sous-requête de liste sur `docs.top_folder` qui laisse INCHANGÉS la sonde
> de clé primaire sur `page_vec` et la poussée de `rowid >` dans fts5 (test de
> plan dédié). `fouine embed --folder <étiquette>` (répétable) restreint toute
> la campagne ; l'agent applique le même ordre. ② **Les tableurs et les fenêtres
> de nombres reçoivent le vecteur nul.** Réglage `embed.skip_spreadsheets`
> (booléen, **vrai** par défaut ; `fouine embed --include-tables` le désarme) :
> toutes les fenêtres d'un document `csv, tsv, xls, xlsx, xlsm, ods, numbers`
> sont nulles sans inférence, et une fenêtre dont au moins 80 % des caractères
> non blancs sont des chiffres ou des séparateurs suit le chemin des fenêtres
> dégénérées (`TextDegeneracy.isMostlyNumeric`, règle PURE). C'est une décision
> de **qualité**, pas de budget disque : le vecteur d'une colonne de nombres est
> proche de tous les autres tableaux du corpus et de rien d'utile, et il occupe
> une place dans chaque top-k ; le disque, lui, n'y gagne que ~21 Mo (874 octets
> par page restante, 24 311 pages de tableur mesurées) sur un dépassement de
> 110 Mo déjà acquis avant toute vectorisation. Ces pages sont comptées comme
> **faites** — la sentinelle de complétude est écrite, sans quoi la pompe les
> resélectionnerait sans fin — et restent trouvables au mot près par le canal
> lexical.

> **Amendement du 03/09/2026 — Dette de tests et robustesse (C2-10, C2-11).**
> 1. **Invariants de `FSEventsWatcher` (C2-10).** Le cycle de vie du flux FSEvents est sécurisé contre les courses multi-fils et les fuites de pointeurs : le `FSEventStreamContext` utilise des callbacks explicites `retain`/`release` via `Unmanaged.passRetained` ; l'arrêt `stop()` est rendu idempotent et synchronisé (invalidation, arrêt, et libération du flux sous verrou sans réentrance sur la file d'événements) ; les événements résiduels en vol sont purgés. Résistance validée par un banc de stress de 50 cycles consécutifs de réallocation sous flux continu d'événements disque.
> 2. **Découpe testable d'`Agent.swift` (C2-11).** Le cœur décisionnel de l'agent launchd est découplé sous forme d'une machine d'états pure (`AgentState`, `AgentAction`, fonctions pures `Agent.tick`, `Agent.postBatchTick`, `Agent.timerTick`), découplée de l'horloge et des sondes système. Les propriétés critiques (`pipeline`, `settings`, `status`) sont figées en `let` immutables dès `init`, et le gestionnaire de sortie `onExit` est injectable. La suite `FouineAgentTests` couvre 82,5 % des lignes d'`Agent.swift` (20 tests automatisés) sans nécessiter de LaunchAgent installé.
> 3. **Retrait de l'autotest semé du binaire distribué (C2-11).** Les parcours semés `runSeededOCRCheck` et `runSeededSemanticCheck` (~240 lignes manipulant des bases jetables) sont extraits de `SelfTest.swift` et transférés dans la suite XCTest `FouineAppTests/SeedTests.swift` (couvrant l'aller-retour zlib, la recherche FTS5 OCR, la dénormalisation aux 4 rotations, l'annotation en mémoire et la fusion RRF hybride). Le mode headless en lecture seule (`FOUINE_SELFTEST=1`) est maintenu dans le binaire d'application pour les besoins de recette manuelle et de diagnostic sans serveur de fenêtres.
> 4. **Suppression des `try?` silencieux (C2-11).** Le protocole `SettingsReadableStore` et la méthode `SettingsSnapshot.load(from:environment:)` centralisent la lecture des réglages en garantissant la publication d'un avertissement explicite en anglais en cas de panne de base (branchés sur les 5 sites d'appel). `AgentLog.swift` remonte désormais les échecs de création de dossier sur `stderr` et poursuit résilient sans journal. `PreviewModel.swift` distingue les erreurs de lecture de base de données d'une absence légitime de disposition OCR via l'état `.unavailable(title:detail:)` bilingue en/fr.

---

## 6 · Pipeline OCR

C'est le cœur du projet et la partie la plus facile à rater. Les seuils ci-dessous sont dérivés de mesures, pas choisis au jugé.

### 6.1 Détection des pages à OCRiser

À l'extraction, une page dont le texte natif fait **moins de 100 caractères** est mise en file.

Justification : les pages à couche texte rendent **2 156 caractères en moyenne** (mesuré sur 21 133 pages ; la v1.0 annonçait 1 976, cohérent) ; les pages scannées rendent **1 caractère** avec `pdftotext`, **0** avec `PDFPage.string`. Le seuil est à deux ordres de grandeur de chaque population, il n'est pas critique à ajuster.

**Ne JAMAIS mettre en file une page qui a déjà du texte natif.** Vérifié sur sept pages natives riches en formules : l'OCR perd sur toutes, en volume comme en contenu. Sur Zangwill p. 250, `ϕ` disparaît, `ψ` devient `V`, `δ` devient `S`, `∇` devient `7`, et **trois équations hors-texte sur quatre sont réduites à leur numéro**, quand la couche native les conserve exactement. Sur les figures, Vision ne voit rien qui ne soit déjà du texte : un schéma de molécule en boules et bâtons est **muet** pour lui, et les étiquettes d'atomes des formules développées (`R`, `OH`, `COOH`) sont du texte vectoriel que l'extraction native sort déjà. Les pages « pauvres » entre 100 et 800 caractères sont donc **exclues** : sur un seul livre, 61 pages sur 698 sont dans ce cas ; les OCRiser toutes coûterait ~10 h à 4 jobs (estimé) pour une perte nette d'information.

Nuance à consigner, sans action en v1 : sur les pages à formules, la couche native a un **ordre de lecture éclaté** (une étiquette par ligne), ce qui casse localement `NEAR` et `snippet()`. C'est un problème de normalisation, pas d'OCR — noté pour le §12.

Priorités de file (`OCRPriority.swift`, `0` = le plus urgent, tri ascendant `ORDER BY q.prio, q.attempts, q.doc_id, q.page`) :
Les priorités reposent exclusivement sur des critères intrinsèques au document et le choix utilisateur, sans dépendre du nom d'un dossier :

```
prio 0  Racine épinglée par l'utilisateur  (réglages, palier 2.3 — priorité absolue)
prio 1  Documents de moins de 100 pages    (petits documents, gains visibles tôt)
        + médias embarqués OOXML (word/media, ppt/media — 722 images mesurées)
prio 2  Documents de 100 pages et plus     (gros volumes : Clayden 1 570 p., Baudin 1 053 p.…)
prio 3  Archives BD cbz/cbr                (5 291 images mesurées, ~2 h à elles seules)
```

À priorité égale, traiter les documents les plus petits d'abord : les gains visibles arrivent tôt.

### 6.2 Une passe, `.accurate`

```
page en file
   │
   ├─▶ rendu PDFKit 150 dpi, niveaux de gris, PLAFONNÉ À ~4 Mpx   (méd. 0,140 s)
   │      · appliquer PDFPage.rotation : mesuré, un CamScanner sort pivoté de 90°
   │
   ├─▶ Vision .accurate, ["fr-FR","en-US"], customWords            (méd. 2,98 s)
   │
   ├─▶ filtrer les lignes sous le seuil de confiance
   │      · TOUTES les lignes vont dans ocr_layout (surlignage)
   │      · seules les lignes retenues vont dans page_fts (vocabulaire)
   │
   └─▶ enregistrer : source = ocrAccurate, engine = vision,
          engine_rev = "vision-rev3", conf = moyenne des lignes retenues
          · ≥ 20 caractères ──▶ page utile                                  ✔
          · sinon           ──▶ page vide, nchars = 0, la page reste marquée
                                traitée : on ne la repasse pas indéfiniment
```

Il n'y a **pas** de passe `.fast`, pas de bascule conditionnelle, pas de seuil de 100 caractères sur la sortie OCR. Voir §2.7 : le dispositif à deux passes de la v1.0 reposait sur une mesure en nombre de caractères qui ne mesure pas la qualité, et son garde-fou ne rattrapait qu'un cas sur sept.

Configuration Vision, imposée :

```swift
let req = VNRecognizeTextRequest()
req.recognitionLevel       = .accurate
req.recognitionLanguages   = ["fr-FR", "en-US"]   // fr-FR vérifié présent en rev3
req.usesLanguageCorrection = true
req.revision               = VNRecognizeTextRequestRevision3
req.customWords            = customWords          // voir ci-dessous
// NE PAS activer automaticallyDetectsLanguage : il annulerait recognitionLanguages.
```

Trois durcissements, à coût nul, qui sont la réponse concrète à l'exigence « privilégier la qualité » :

1. **Préchauffage par processus.** Mesuré : le premier `.accurate` d'un processus paie **8,5 s** de chargement de modèle (3,2 s en `.fast`). À 4 jobs et des lots courts, c'est 34 s de démarrage pur, répétées à chaque relance. `OCREngine.prewarm()` est appelé une fois par processus, sur une image minuscule, avant d'ouvrir la file ; et `--budget-minutes` doit être généreux plutôt que haché.
2. **`customWords` alimenté par `fts5vocab`.** Les manuels à couche texte propre apprennent à Vision comment s'écrit le lexique du corpus — c'est le levier de qualité le plus rentable du projet : une requête SQL (`IndexStore.topVocabulary`) et un tableau de `String`. Prendre les termes de ≥ 6 lettres les plus fréquents, plafonner la liste (ordre de grandeur : quelques milliers d'entrées, **à calibrer** — au-delà, Vision ralentit).
3. **Filtrage par confiance avant insertion.** Seuil **provisoire : `confidence < 0,30` ⇒ la ligne n'entre pas dans `page_fts`** — mais entre dans `ocr_layout`, pour que le surlignage reste complet. **À calibrer** par A-Recette sur les fixtures manuscrites : c'est un réglage, pas une constante physique. La v1.0 stockait `OCRLine.confidence` sans jamais s'en servir, ce qui est exactement le défaut reproché à Tesseract au §2.8. La moyenne des confiances retenues est enregistrée dans `page_src.conf`, ce qui rend « re-OCRiser les pages douteuses » interrogeable en une requête (annexe B).

### 6.3 Ressources et interruption

- **Concurrence plafonnée à 4** — et le plafond est bon pour la raison inverse de celle qu'annonçait la v1.0. Mesuré : **+74 % à 4 processus** (et non +12 %), et **8 processus est une régression** (0,576 p/s contre 0,699). Ce n'est pas « le parallélisme ne paie pas » : il paie six fois plus qu'annoncé, et il s'effondre au-delà de 4. Ne pas monter à 8, ne pas descendre à 1 « pour ménager la machine ».
- **Garde-fou thermique sur `CPU_Speed_Limit`, pas sur `thermalState`.** Mesuré : à 4 jobs, `CPU_Speed_Limit` tombe à **46 % en moins de 90 s** pendant que `thermalState` reste bloqué à `.fair`. Une pause conditionnée à `.serious` **ne se déclencherait jamais**. Règle : lire `pmset -g therm` (ou `IOPMCopyCPUPowerStatus`) toutes les 30 s ; sous 70 %, descendre la concurrence de 4 à 2 ; sous 50 % durablement, suspendre. QoS `.utility`.
- **Rendu plafonné à ~4 Mpx.** « 150 dpi » n'est pas une résolution, c'est un facteur d'échelle sur le `mediaBox` : mesuré, une page dont le `mediaBox` fait 34 × 48 cm pour une image incorporée à 72 ppi produit **5,7 Mo** en niveaux de gris sans un pixel utile — 2,6× l'empreinte annoncée par la v1.0 — et 22,8 Mo si l'on rendait à 300 dpi. Borner l'image de sortie à ~4 Mpx, ou à la résolution native de l'image incorporée quand elle est connue.
- **Empreinte mémoire** d'une page A4 à 150 dpi en niveaux de gris : 1 240 × 1 754 ≈ **2,2 Mo** (mesuré) ; c'est le cas nominal, le plafond ci-dessus borne le cas dégénéré. Libérer le `CGImage` avant de passer à la suivante. Vision elle-même tient **344 Mo par processus, 1,38 Go à 4 jobs** (mesuré) : c'est le poste dominant, sur une machine à 8 Gio dont 1 Gio de swap est déjà consommé.
- **Une page = une transaction.** Un `Ctrl-C`, une mise en veille ou une racine qui disparaît ne doit jamais laisser la base incohérente. Corollaire non négociable : cette transaction supprime **par rowid** (§4.1, §5.1) — sinon elle coûte à elle seule ~2 h sur la passe complète.
- `--budget-minutes M` : arrêt propre à l'échéance, sortie **4**, file intacte, `docs.ocr_state = .partial`.
- `ocr_queue.attempts` s'incrémente à chaque échec ; au troisième, la page est abandonnée et `docs.err` renseigné.

### 6.4 Budget attendu

Débit de référence : **0,675 page/s à 4 jobs, rendu compris et sous throttling** (mesuré — donc un budget réaliste, pas optimiste).

| Lot | Pages | Durée |
|---|---:|---:|
| Livres scannés imprimés | 32 000 – 44 000 | 13,2 – 18,1 h |
| Archives BD (`cbz`/`cbr`) | 5 291 | ~2,2 h |
| Médias embarqués OOXML | 722 | ~18 min |
| Cours scannés et manuscrits | ~350 | ~9 min |
| **Total, une fois, en arrière-plan, sur secteur** | **38 000 – 50 000** | **≈ 16 – 21 h** |

**~20 h, assumées** (décision D1). C'est le prix de 90,5 % de rappel au lieu de 19,9 %. L'OCR ne doit **jamais** bloquer la mise à disposition de la recherche : les ~90 % de pages à couche texte sont interrogeables dès la fin de la tranche A, c'est-à-dire après 30 minutes d'extraction.

### 6.5 Non-destructivité

Fouine n'écrit jamais dans un PDF. Le texte reconnu vit dans `page_fts` et `ocr_layout`. C'est la différence délibérée avec FoxTrot, dont la commande OCR réécrit le fichier source (en archivant l'original dans un `.zip`). Conséquences : les originaux restent intacts, aucun espace consommé dans le corpus, et changer de moteur OCR plus tard ne demande qu'une réindexation — ou un simple `ocr import` (annexe B), puisque `page_src.engine` et `page_src.engine_rev` disent qui a produit quoi.

### 6.6 Ce que l'OCR ne fera pas

**L'OCR mathématique et chimique est hors périmètre, et c'est un choix, pas un oubli.** Reconnaître les formules en LaTeX et les structures en SMILES coûterait 21 à 140 h de CPU supplémentaires (*estimé*), trois à quatre modèles à embarquer, plusieurs centaines de Mo de RSS par worker, et deux licences incompatibles (Surya en GPL-3, OSRA en GPL-2, qui compliqueraient la distribution publique sous licence AGPL). Surtout : **du LaTeX et des SMILES tokenisés sont du bruit dans le vocabulaire, pas des mots cherchables.** On ne cherche pas une formule ; on cherche les mots autour de la formule. Le durcissement `customWords` du §6.2 sert bien mieux ce besoin, pour zéro heure de calcul.

---

## 7 · Pièges connus

Chacun a été rencontré et mesuré. Ils sont non négociables. L'ordre est celui de la gravité : le n°1 est celui qui produit un index à moitié vide **sans le moindre message d'erreur**.

### 7.1 TCC — le piège n°1

`~/Documents` est un emplacement **protégé par TCC** sur macOS 15. `~/Livres` ne l'est pas — c'est un dossier maison quelconque. Vérifié sur la machine : le shell courant lit `~/Documents` et `~/Livres`, mais pas `~/Library/Mail` ni `TCC.db` (`authorization denied`) — c'est-à-dire l'état exact d'une app qui a l'autorisation « Dossier Documents » sans Accès complet au disque.

Trois conséquences, toutes à traiter :

1. **Le comportement est asymétrique entre les deux racines.** Une racine s'indexe, l'autre reste vide, et rien ne le dit. C'est le pire diagnostic possible.
2. **`FouineAgent`, enregistré par `SMAppService`, ne peut PAS afficher d'invite TCC.** Un agent sans interface qui touche `~/Documents` est refusé en silence. L'autorisation doit être obtenue **par l'app, au premier lancement, avant** l'enregistrement de l'agent — ou l'utilisateur accorde l'Accès complet au disque à la main. FSEvents sur `~/Documents` est soumis à la même autorisation : un flux muet est un symptôme d'autorisation, pas d'inactivité.
3. **`Info.plist` doit porter `NSDocumentsFolderUsageDescription`** (§11.2). `NSRemovableVolumesUsageDescription` ne couvre rien de tout cela.

**`fouine doctor` doit tester la lecture effective de chaque racine** — ouvrir un fichier, pas `stat` — et, en cas d'échec, nommer TCC et donner le geste exact : « Réglages Système ▸ Confidentialité et sécurité ▸ Fichiers et dossiers ▸ Fouine ▸ Dossier Documents », ou « Accès complet au disque » si l'agent doit tourner sans l'app. Sortie **5**, `FouineError.rootUnreadable`. *(Depuis le palier 3 : la CLI écrit ce geste en anglais — `System Settings ▸ Privacy & Security ▸ …` —, l'application en français depuis le catalogue ; voir l'amendement du §4.3.)*

### 7.2 Les autres

1. **`PDFPage.string` fait fuir la mémoire dans le document.** Mesuré : **1 515 Mo de RSS pour UN SEUL fil** sur un livre de 1 315 pages ; `PDFDocument` conserve chaque page analysée et un `autoreleasepool` par page n'y change rien. Un seul fil suffit à violer P6 avant même d'ouvrir le second job. Correctif obligatoire (D2) : **rouvrir le `PDFDocument` toutes les 100 pages** → 279 Mo/fil, 1,12 Go à 4 jobs, texte **identique au caractère près**, débit inchangé. À 400 pages de fenêtre le RSS remonte à 610 Mo : 100 est le bon réglage, ce n'est pas un ordre de grandeur.
2. **`PDFDocument(url:)` rend `nil` en silence** sur un PDF corrompu, sans lever d'erreur (vérifié sur un fascicule réel dont `pdftotext` dit `Internal Error: xref num 3`). Ce `nil` **doit** devenir `FouineError.extraction` + `state = .failed` + `err`. Un `nil` avalé est un document qui disparaît de l'index sans trace.
3. **`NSAttributedString` échoue en silence, avec du bruit.** Sur un `.ppt` binaire : pas d'erreur, `type = NSPlainText`, et **316 411 caractères de mojibake** (`–œ‡°±· ˛ˇ ˛ˇˇˇ ^ _ a`). Sur `.xlsx` et `.pptx` : **0 caractère**, toujours sans erreur. Le §5.3 prévoyait « `.skipped` si échec » — mais il n'y a pas d'échec à détecter, il y a un faux succès. D'où le contrôle de plausibilité du §5.3, et `.xls`/`.ppt` en `.skipped` d'office.
4. **Le throttling est invisible à `thermalState`.** Mesuré, machine sur secteur et au repos : à 4 processus Vision, `CPU_Speed_Limit` tombe à **46 % en moins de 90 s**, et `thermalState` monte de `.nominal` à `.fair`… et s'y arrête. Une pause conditionnée à `.serious` ne se déclenche **jamais**. Surveiller `CPU_Speed_Limit` (§6.3). Note collatérale : l'extraction de texte, elle, ne chauffe pas (100 % après 5 min de PDFKit mono-fil) — le problème est spécifique à Vision, qui sature les 8 fils.
5. **`DELETE FROM page_fts WHERE doc_id = ?` est un balayage complet.** `doc_id` est `UNINDEXED` : `EXPLAIN QUERY PLAN` donne `SCAN page_fts VIRTUAL TABLE INDEX 0:`, coût **linéaire en taille d'index et indépendant de la position du document**. Mesuré : 143 ms sur 600 000 lignes contre **3 ms** par rowid. Avec « une page = une transaction », c'est ~2 h de balayage pur sur la passe OCR, soit 10 à 15 % du budget total. Rowid structuré imposé (§4.1).
6. **La sonde « pages 1 à 3 » ment de 30 points.** Sur le même échantillon de 40 livres : 38 % de « scannés » en sondant le début, **8 %** en sondant le milieu. Couvertures et pages de garde sont des images. Toute sonde de couche texte échantillonne des pages **réparties**.
7. **« 150 dpi » n'est pas une résolution.** C'est un facteur d'échelle sur le `mediaBox` : une page à `mediaBox` 34 × 48 cm portant une image à 72 ppi produit 5,7 Mo de niveaux de gris sans un pixel utile ; une autre à 301 ppi est sous-échantillonnée ×2. Plafonner à ~4 Mpx (§6.3).
8. **Une page peut sortir pivotée du rendu.** Mesuré : la page 1 d'un CamScanner rend une image tournée de 90°. `.accurate` s'en sort (584 caractères, 43 % de rappel ; 629 après redressement) mais `.fast` rendait 0. Appliquer `PDFPage.rotation` au rendu, et ne jamais interpréter « 0 caractère » comme « page vide » sans avoir vérifié l'orientation.
9. **`ambiguous column name: pages`.** Une table FTS nommée `pages` à côté d'une colonne nommée `pages` casse tout JOIN, et `MATCH` n'accepte pas d'alias de table à sa gauche. D'où `page_fts` et la forme en sous-requête du §4.1. Précision de la v1.1 : c'est bien une collision de noms **identiques** — `docs.n_pages` ne pose aucun problème, contrairement à ce qu'affirmait le commentaire du schéma v1.0.
10. **Chemins instables, clé = UUID.** La règle reste juste ; l'anecdote qui la justifiait en v1.0 (« 815 Mo d'index FoxTrot morts pointant vers un dossier déplacé ») **ne l'illustre plus** : l'index FoxTrot pèse aujourd'hui 308 Ko, `IndexedLocations` est vide, il a été réinitialisé. Ne pas la citer comme un fait présent. Et lire l'UUID par `URLResourceKey.volumeUUIDStringKey`, pas par `diskutil` (§2.3).
11. **`pdftoppm` à 300 dpi.** 5,6 à 21,6 s par page. PDFKit fait la même chose 20 à 80× plus vite. Ne pas rendre plus grand, ne pas sortir du processus.
12. **Le parallélisme OCR paie six fois plus qu'annoncé — et s'effondre à 8.** +74 % à 4 processus, régression à 8 (§6.3). La v1.0 disait l'inverse dans les deux sens.
13. **PDF illisibles.** Ils existent dans le corpus. Toute erreur de lecture se solde par `state = .failed` + `err`, jamais par un arrêt du lot.
14. **Racine déplacée, supprimée ou renommée** en cours de route. À détecter **à chaque lot**, pas seulement au démarrage : sortie 5, file intacte, recherche toujours répondante. (Pour un volume entier qui disparaît : sortie 2 — voir annexe A.)
15. **Ne pas hacher les fichiers.** `size + mtime` suffit. L'argument de coût de la v1.0 (24 Go à 33 Mo/s) est **caduc** — le SSD hacherait 19 Go en ~20 s — mais la règle reste : APFS donne un `mtime` à la nanoseconde, et un hachage n'apporterait rien de plus.
16. **`python3` n'est pas le SQLite du système.** `python3` embarque SQLite 3.50.4, le système est en 3.43.2. Toute mesure FTS5 prise en Python porte sur un autre moteur : la refaire en Swift avant d'en tirer un seuil.

---

## 8 · Critères d'acceptation

Exécutables tels quels sur le corpus privé du mainteneur via `Tests/Fixtures/paths.json` (gitignoré, selon le gabarit `Tests/Fixtures/paths.example.json` avec la variable d'environnement `FOUINE_TEST_DB`). La recette automatisée et portable du produit vit quant à elle dans `Tests/Fixtures/corpus/` + `manifest.json` (palier 3.3) et tourne directement via `make test`. Un critère qui échoue bloque la livraison de sa tranche. Les chemins ci-dessous sont absolus ; `--only` accepte indifféremment un chemin absolu ou un `rel_path`.

**Toutes les fixtures de T1, T2, T6 et T7 ont été vérifiées présentes et conformes le 2026-08-31**, avec les commandes de contrôle indiquées. Une fixture qui aurait bougé se re-vérifie avec la même commande avant d'accuser le code.

### 8.1 Fonctionnels

| # | Commande | Attendu |
|---|---|---|
| T1 | `fouine search '"règle de Markovnikov"'` | `/Users/<vous>/Livres/Chimie/Chimie organique/Arnaud - Chimie organique (Les Cours de Paul Arnaud) 20e.pdf`, **pages 247 et 265**, `source = native`, **et aucune autre page**. Livre **nativement textuel** vérifié sur pages réparties (50/100/200/300/400/500/600/690 : 1 055 à 3 651 car.). Contrôle : `pdftotext -f 247 -l 247 "<f>" -` contient « règle de Markovnikov » (1 904 car. sur la page) ; contrôle croisé PDFKit : `PDFPage.string` des pages 247 et 265 contient la même chaîne, et **ces deux pages seulement** sur 697 |
| T2 | `fouine search 'pres:10 energie libre gibbs'` | `/Users/<vous>/Livres/Chimie/CAPES Tome 2 - Chimie.pdf`, **page 93** (800 p. ; la page porte « Énergie libre F et enthalpie libre G » et « l'enthalpie libre (ou énergie de Gibbs) », 1 440 car. rendus par `PDFPage.string`) |
| T3 | `fouine search 'polymere'` | ≥ 1 résultat contenant « polymère ». Contrôle moteur déjà mesuré : `polymere` et `polymère` retournent **exactement les mêmes pages** |
| T4 | `fouine search 'chromatographie' --facet folder` | facettes non vides, au moins `Livres` et `Cours`. Contrôle implicite : les étiquettes de facette sont les `roots.label`, **jamais** `Users` (§5.2) |
| T5 | `fouine search 'enthalpie -biologie'` | ≥ 1 résultat, aucun dans un document où « biologie » apparaît |
| T6 | `fouine ocr --only '/Users/<vous>/Documents/Cours/CamScanner 15-09-2024 17.51.pdf'` puis `fouine search 'RCPA'` | ce fichier, **page 1**, `source = ocr_accurate`, `engine = vision`. Contrôles secondaires sur la même page : `taux`, `conversion`, `volume`, `passage`. Contrôle préalable vérifié : les 4 pages rendent **1 caractère** en natif (`PDFPage.string` : 0). Transcription `.accurate` de référence, mesurée : `RCPA :`, `2) le volume du readem:`, `Connaissant-le taux de Conversion`, `3) le temps de passage`. **C'est le test décisif du projet** : une page manuscrite scannée, illisible en lecture, parfaitement cherchable |
| T7 | `fouine ocr --only '/Users/<vous>/Livres/Biologie & Chimie/Practical Inorganic Chemistry - Spitsyn.pdf'` puis `fouine search 'tellurium'` | ce fichier, **page 120**, `source = ocr_accurate`. Scan dactylographié **très propre** (304 p., 0 car. natif partout, image incorporée à 301 ppi). Transcription `.accurate` de référence : `Sulphur, Selenium, Tellurium` en en-tête et `Fig. 68. Apparatus for preparing sulphur chlorides`, rendus **exacts**. Durée attendue : ~8 min à 4 jobs. Le test `ocr_fast` de la v1.0 est supprimé : `ocr_fast` n'est plus jamais émis (D1) |
| T8 | après `fouine crawl --full` : `fouine status --json` | aucun `rel_path` ne contient `/._`, `/.DS_Store`, `/.Spotlight-V100`, `/.Trashes` ; aucun composant `*.pages` parcouru comme un dossier. **Le volet AppleDouble n'est plus discriminant sur APFS** (0 fichier `._*` mesuré) : il reste exercé par le test unitaire du filtre, sur des chemins synthétiques. Second volet, lui, discriminant : révoquer l'accès « Dossier Documents » à Fouine, relancer `fouine doctor` → sortie **5**, message nommant le refus de lecture — Confidentialité et sécurité, ou droits du fichier (en anglais dans la CLI : `effective read of a file: FAILED — read denied...`), la racine `Cours` et le geste à faire ; `Livres` continue de fonctionner |
| T9 | racine renommée ou déplacée puis `fouine doctor` | sortie **5**, message nommant la racine et son chemin attendu (en anglais dans la CLI : `folder not found...`) ; `fouine search` continue de répondre sur l'index existant, et l'aperçu affiche un état explicite. (Le cas « volume entier démonté → sortie 2 » est en annexe A) |
| T10 | deux `fouine index` consécutifs | le second n'extrait **aucun** document (delta vide, idempotence) |
| T11 | `fouine ocr --budget-minutes 1` sur une file non vide | sortie **4**, file cohérente, `ocr_state = partial`, la reprise repart où elle s'était arrêtée. Tolérance : le préchauffage Vision consomme 8,5 s du budget par processus (§6.2) |
| T12 | `fouine search 'chimie' --in <doc_id>` puis `--in <a> --in <b>` | résultats limités à ce document, puis à ces deux documents |
| T13 | après OCR de la fixture T6 : prendre un terme de ≥ 6 lettres présent dans le texte OCR de la page (ex. `conversion`), y introduire **une** substitution (`converslon`), puis `fouine search 'converslon' --fuzzy off` et `--fuzzy on --fuzzy-scope ocr` | `off` → **0 résultat** ; `on` → cette page, avec `fuzzy_distance = 1` et un score pénalisé de `1/(1+d)`. Test formulé comme une **procédure** et non sur une variante figée : l'OCR n'est pas reproductible au caractère près d'une version de macOS à l'autre. Variantes réellement observées au banc d'essai sur cette page, à titre d'illustration : `Concervation` (d = 1 de `conservation`), `Concentiation` (d = 1 de `concentration`, sur le rendu redressé), `Connalssant` (d = 1 de `connaissant`) |
| T14 | `fouine search 'polymere'` (mode `auto` par défaut) | le nombre de pages ne dépasse pas 2× celui de la requête exacte ; en `--fuzzy on`, les scores sont croissants (tri par score scalaire unique D-R1 — amendement du 03/09/2026 : la clause « fuzzy_distance = 0 d'abord » saute), et **aucune page n'apparaît deux fois** (déduplication du §5.5.3) |
| T15 | `fouine search 'mayer' --fuzzy on` et `fouine search 'gibbs' --fuzzy on` | **aucune expansion** : termes de 5 lettres, d = 0 (§5.5.2). Le résultat est identique à `--fuzzy off`. Contre-épreuve obligatoire dans le même test : `fouine search 'enthalpie' --fuzzy on` **étend bien** (d = 2, voisins attendus `enthalpic`, `enthalpies`, `enthalpique`, `enthalpy`). Le T15 de la v1.0 (« `bayer`/`layer` n'apparaissent pas à d = 1 ») était **insatisfiable** : ces deux mots sont à distance 1 de `mayer` |

### 8.2 Performance

| # | Seuil | Mesuré à |
|---|---|---|
| P1a | extraction `pdftotext` ≥ **100 pages/s**, 1 fil | **105,1 p/s** à chaud, 94,7 à froid — pour mémoire, ce n'est pas le moteur retenu |
| P1b | extraction **PDFKit** ≥ **70 pages/s**, 1 fil, PDF à couche texte | **75,6 p/s** (72,1 avec réouverture /100 p). Le seuil de 100 p/s de la v1.0 était calibré sur `pdftotext` ; PDFKit est à ×1,39, en dessous du critère de repli de ×2 (D2) |
| P2 | rendu PDFKit ≤ **0,6 s/page** à 150 dpi | médiane **0,140 s**, p95 0,209, max 0,290 — 4× de marge |
| P3 | Vision `.accurate` : médiane ≤ **3,0 s/page**, **p95 ≤ 5,0 s** | médiane **2,980 s**, p95 4,869, max 4,937 (sous throttling). Le p95 est une **nouvelle** borne : la médiane seule masquait les pages denses (Clayden 4,87 s). Hors budget : le chargement de modèle, 8,5 s au 1ᵉʳ appel de chaque processus |
| P4 | `fouine search` p95 < **50 ms** sur l'index complet | p95 max **6,4 ms** sur 20 968 pages (forme imposée du §4.1, `snippet()` compris) ; pire cas sans index préfixe : `ch*` à 12,65 ms — d'où le refus des préfixes < 4 caractères (§5.5.1) |
| P5 | base ≤ **2,0 Go** pour le corpus complet | **1,903×** le texte × 0,86 Go = **1,64 Go** ✅, **tenu par D3 uniquement** : avec `prefix='2 3'` le ratio est 2,466× → 2,12 Go, seuil dépassé. Ajouter **≤ 55 Mo** pour `vocab_tri` (mesuré à 1 M de termes) : total **~1,70 Go** |
| P6 | RSS ≤ **1,5 Go** en indexation à 4 jobs, **avec réouverture du `PDFDocument` toutes les 100 pages** | **1,12 Go** (279 Mo/fil). Sans le correctif : 1,52 Go **pour un seul fil**. OCR à 4 jobs : 1,38 Go (344 Mo/processus Vision) |
| P7 | passe texte complète (racines actives) ≤ **90 min** à 4 jobs | **32 min** en PDFKit (215 p/s), 27 min en `pdftotext` (260 p/s), pour ~415 000 pages. Le plancher d'E/S est passé de 12 min à ~15 s |
| P8 | expansion floue ≤ **10 ms** par terme, vocabulaire 1 M | Swift `-O` : **0,10–1,65 ms** à 145 605 termes réels ; 0,99–2,82 ms à 1 M pour les termes de ≥ 6 lettres. Les deux seuls dépassements mesurés (`mayer` 10,1 ms, `polymere` 14,7 ms) disparaissent avec **d = 0 sous 6 lettres** |
| ~~P9~~ | ~~construction de l'index trigramme ≤ 8 s au démarrage~~ | **SUPPRIMÉ** : l'index trigramme est désormais une table SQL persistée (§5.5.2). Il n'y a plus de construction au démarrage, ni les 185 Mo de RSS qui allaient avec |

> **Amendement du 05/09/2026 (PERSP-Q8, lot GA).** Le chiffre de 2,0 Go était un ordre de grandeur, pas un mur. Mesuré le 05/09/2026 sur la base de production : 1,93 Go pour 408 758 pages (texte FTS 1,2 Go, index FTS 0,4 Go, 64 872 vecteurs = 28 Mo ; +180 Mo attendus à couverture sémantique pleine). Le budget P5 est relevé à **2,5 Go** pour le fonds de référence.

> **Amendement du 10/09/2026 (MO-03, C2-18, MO-04, lot MB1) — ce que « budget » veut dire.** Le budget P5 vaut **2,5 × 10⁹ octets** (des Go décimaux, comme le Finder les compte, et non 2,5 Gio) : c'est la lecture sous laquelle les mesures de l'audit se tiennent (2,151 Go pour 408 951 pages = 5,14 Kio/page). **Le budget est un AVERTISSEMENT, pas une limite** (décision du propriétaire du 09/09/2026, n° 3) : à 80 % de la taille prévue, Fouine le dit — carte « Index », `fouine status`, `fouine doctor` — et **rien ne s'arrête à 100 %**, ni l'indexation, ni l'OCR, ni la campagne sémantique ; le geste proposé est `fouine maintain --vacuum` ou le retrait d'un dossier. **La projection compte l'achèvement de la campagne sémantique** (`DiskForecast`, pur et testé) : la règle de trois linéaire que `status` affichait (« projection : 4,9 GiB at 1 M ») partait d'une base à vecteurs partiels, donc optimiste à court terme. Mesuré le 09-10/09/2026 : à couverture pleine du corpus ACTUEL la base atteint **~2,27 Go, soit 91 % du budget**, et le budget est franchi vers **451 000 pages** (~42 000 de marge) — une fenêtre coûte 384 octets de vecteur plus ~26 octets de ligne SQLite, mesuré par `dbstat`. **Le budget dépend du FONDS, et le critère P5 ne vaut que pour le fonds de référence** : un fonds de courriers et de factures coûte 8,3 Kio/page (C2-18) mais 3 pages par document, donc ~240 Mio pour 10 000 courriers — le plafond n'y est un sujet qu'à ~100 000 documents. Enfin, `doctor --deep` est une opération de **plusieurs minutes** sur un gros index (86 s sur 2,2 Go machine libre, MO-04 ; **177 s** mesurées ici sous une autre compilation) : elle annonce sa durée attendue, puis chaque étape en commençant, et publie la durée de chacune (`database.steps`). Ce que la mesure corrige : les deux gros postes sont `PRAGMA quick_check` (**79,6 s**) et l'`integrity-check` FTS5 (**92,0 s**), à peu près à égalité — le verrou d'écriture n'est donc tenu que pendant un peu plus de la moitié de l'attente.


> **Amendement du 11/09/2026 (MO-03, décision du propriétaire, orchestrateur).** Le critère P5 **ne s'affiche plus dans l'application.** Le lot MB1 y montrait « Votre index occupe 2,15 Go sur les 2,5 Go prévus » dès 80 % ; le propriétaire l'a lu comme le maximum de ce que Fouine peut indexer — pour le public visé, un chiffre « prévu » est un plafond, quoi qu'on écrive à côté. P5 reste une promesse de conception pour le fonds de référence, mesurée et annoncée par `fouine status` (`disk_budget`, projection à couverture pleine) et `fouine doctor`. La carte « Index » ne parle que de **la place qui reste sur le disque** de l'index (`volumeAvailableCapacityForImportantUsage`, le chiffre du Finder), et seulement quand elle manque : sous 5 Go, le reste et le poids de l'index ; sous 1 Go ou sous ce que la préparation sémantique doit encore écrire (`DiskForecast.bytesAtFullVectors − bytes`), la même phrase avec le geste (libérer de l'espace, retirer un dossier). Rien ne s'arrête, comme avant.

### 8.3 Distribution

Renommés **S1–S3** en v1.1 : les étiquettes `D1`/`D2`/`D3` désignent désormais les trois **décisions** produit du §2.7, §5.3 et §4.1, et les confondre coûterait un malentendu de livraison.

| # | Commande | Attendu |
|---|---|---|
| S1 | `codesign -dv --verbose=4 Fouine.app` | `flags=0x10000(runtime)`, `TeamIdentifier=<TEAMID>` |
| S2 | `spctl -a -vv Fouine.app` | `accepted`, `source=Notarized Developer ID` |
| S3 | `xcrun stapler validate Fouine.app` | `The validate action worked!` |
| S4 | `fouine doctor` depuis l'app installée, chaque racine active | `readable = true` partout ; sinon message TCC et sortie 5 (§7.1) |

---

## 9 · Plan d'exécution multi-agents

### 9.1 Tranches

| Tranche | Vague | Contenu | Livre quoi | Tests |
|---|:--:|---|---|---|
| **A** | 1 | Core, Crawl, Extract, CLI | recherche utilisable sur ~90 % du corpus | T1–T5, T8–T10, T12, T14, T15, P1b, P4, P5, P6, P7, P8 |
| **B** | 2 | OCR + recette | le corpus scanné devient cherchable | T6, T7, T11, T13, P2, P3 |
| **C** | 3 | App SwiftUI | usage quotidien | — |
| **D** | 3 | Agent d'arrière-plan, empaquetage, signature | app installable | S1–S4 |

**La tranche A est la ligne de « terminé » minimale.** Si le budget de session se resserre, arrête à la fin d'une **vague**, jamais au milieu. C et D sont les premières à sacrifier ; la CLI seule reste un outil complet.

### 9.2 Vagues et carte de propriété

**Contrainte d'exécution : au plus DEUX sous-agents en parallèle.** Quatre vagues, deux agents chacune (sauf la vague 0), enchaînées. Aucun fichier n'est partagé entre les deux agents d'une même vague — c'est la seule protection contre les conflits d'édition.

**Vague 0 — orchestrateur seul.** Initialise le dépôt sous licence **AGPL-3.0-or-later**, `Package.swift` avec les dépendances du §2.2 et un `swift package resolve` **déjà fait** (les agents ne doivent pas dépendre du réseau), l'arborescence, `Sources/FouineCore/Contracts.swift` (§4.2), `Sources/FouineCore/Schema.swift` (§4.1), `Tests/Fixtures/paths.example.json` (modèle du §8.1), `Makefile`, `.gitignore`. Commit `freeze: contracts`. **Aucun sous-agent ne démarre avant ce commit.**

**Vague 1 — 2 agents.**

| Agent | Périmètre | Possède |
|---|---|---|
| **A-Core** | Store GRDB, DAO, FTS5, facettes, analyse de requête, expansion floue, **et la CLI** (§5.1, §5.5, §4.3) | `Sources/FouineCore/Store/**`, `Sources/FouineCore/Query/**`, `Sources/FouineCore/Fuzzy/**`, `Sources/fouine/**` |
| **A-Ingest** | Volumes, racines, FSEvents, delta, exclusions, **et les formats d'extraction** (23 extensions, §5.2, §5.3) | `Sources/FouineCrawl/**`, `Sources/FouineExtract/**` |

A-Core code la CLI contre les protocoles `Crawler` et `ExtractorRegistry` (§4.2, gelés en vague 0) avec des bouchons `Stub*`, et A-Ingest livre les implémentations sous ces mêmes noms : le câblage se fait sans que l'un ait à relire l'autre. Chaque agent écrit ses tests dans `Tests/<SonModule>Tests/**`.

**Vague 2 — 2 agents, après intégration de la vague 1.**

| Agent | Périmètre | Possède |
|---|---|---|
| **A-OCR** | Rendu plafonné, Vision passe unique, file, budget, garde-fous (§5.4, §6) | `Sources/FouineOCR/**` |
| **A-Recette** | Recette et bancs d'essai sur le corpus réel (§8), calibrage du seuil de confiance et de `customWords` | `Tests/Integration/**`, `Tests/Fixtures/**` |

A-Recette commence par exécuter la tranche A (T1–T5, T8–T10, T12, T14, T15 et les P) sur le livrable de la vague 1 : c'est ce qui rend la vague 2 utile même si A-OCR dérape. Ses tests OCR (T6, T7, T11, T13) attendent l'intégration d'A-OCR.

**Vague 3 — 2 agents.**

| Agent | Périmètre | Possède |
|---|---|---|
| **A-App** | Interface SwiftUI + PDFKit, surlignage, invite TCC au premier lancement (§5.6) | `Sources/FouineApp/**` |
| **A-Pack** | Agent `SMAppService` (§5.7), empaquetage, signature, notarisation (§11) | `Sources/FouineAgent/**`, `Packaging/**`, `Makefile` (l'orchestrateur lui cède la propriété en début de vague) |

Ces deux-là se touchent en un point et un seul : `Packaging/Info.plist` et les entitlements, que **A-Pack possède seul**. A-App qui a besoin d'une clé `Info.plist` la demande à l'orchestrateur ; il ne l'écrit pas.

### 9.3 Protocole d'intégration

Chaque agent rend trois choses, et rien de moins :

1. du code qui compile isolément — `swift build --target <Module>` ;
2. ses tests unitaires au vert — `swift test --filter <Module>Tests` ;
3. une note de dix lignes maximum listant ce qui **dévie** de la spec et pourquoi.

Entre deux vagues, l'orchestrateur intègre, lance `swift build && swift test` sur l'ensemble, résout les déviations signalées, **puis seulement** lance la vague suivante. Deux agents en vol au maximum, jamais trois, jamais un troisième « juste pour la doc ». Une déviation d'interface non signalée est un échec de livraison, pas un détail.

**Ce qui reste hors du dépôt public** : `Tests/Fixtures/paths.json` (chemins personnels réels du mainteneur, voir modèle `paths.example.json`) est **gitignoré** ; la recette sur le corpus complet qui en dépend est marquée locale et sautée proprement (`XCTSkip`) si le fichier ou `FOUINE_TEST_DB` est absent. La recette portable s'appuie quant à elle sur `Tests/Fixtures/corpus/` et `manifest.json` (palier 3.3).

### 9.4 Arborescence

```
~/fouine/
├── SPEC.md            ← ce document
├── Package.swift      ← GRDB.swift, swift-argument-parser, Sparkle
├── Package.resolved   ← versé au dépôt, résolu en vague 0
├── Makefile
├── Sources/
│   ├── FouineCore/    Contracts.swift  Schema.swift  Store/  Query/  Fuzzy/
│   ├── FouineCrawl/
│   ├── FouineExtract/
│   ├── FouineOCR/
│   ├── fouine/        (CLI)
│   ├── FouineApp/     (SwiftUI)
│   └── FouineAgent/
├── Tests/
│   ├── FouineCoreTests/ …
│   ├── Integration/
│   └── Fixtures/paths.json      ← GITIGNORÉ (chemins réels, voir paths.example.json)
└── Packaging/
    ├── Info.plist  Fouine.entitlements  notarize.sh
```

---

## 10 · Emplacements d'exécution

```
Base et verrou   ~/Library/Application Support/Fouine/fouine.db  (+ .lock, -wal, -shm)
Journaux         ~/Library/Logs/Fouine/fouine.log        (rotation à 10 Mo)
Préférences      ~/Library/Preferences/io.github.basedpolymer.fouine.plist
Agent            enregistré par SMAppService, pas de plist déposé à la main
Échanges OCR     ~/Library/Application Support/Fouine/exchange/  (annexe B, jetable)
```

Rien n'est jamais écrit dans `~/Livres`, `~/Documents/Cours`, ni dans aucune racine indexée.

---

## 11 · Empaquetage, signature, notarisation

### 11.1 Ce que chaque étape apporte réellement

Les trois étapes n'ont pas la même valeur, et il faut les traiter selon ce qu'elles rapportent, pas comme un rituel.

| Étape | Ce qu'elle apporte ici | Verdict |
|---|---|---|
| Signature de la **CLI** | l'exécutable embarqué dans `Contents/Helpers/` est signé avec son identifiant (`-i …fouine.cli`) pour préserver l'intégrité scellée du bundle | **requise à la release** |
| Signature de l'**app** avec une identité **stable** | 1. les autorisations de confidentialité (**Dossier Documents**, accès complet au disque, raccourci global) sont indexées par la signature du code : sans identité stable, macOS les révoque ou les redemande **à chaque recompilation** — et sur ce projet, une autorisation TCC perdue vaut un index à moitié vide (§7.1). 2. `SMAppService` valide la signature de l'app : non signée, l'enregistrement de l'agent d'arrière-plan échoue. | **indispensable, dès le premier build** |
| Runtime durci | un drapeau (`--options runtime`) ; prérequis absolu de la notarisation | gratuit |
| **Notarisation** | uniquement ceci : l'app s'ouvre sur **une autre machine**, ou après un transfert qui pose la quarantaine (téléchargement, AirDrop, clé USB) | **seulement si l'app quitte ce Mac** |

Autrement dit : signer tout de suite, pour la stabilité des autorisations et l'agent d'arrière-plan. Notariser seulement au moment de distribuer. La chaîne étant scriptée ci-dessous via le `Makefile`, la garder coûte deux minutes par version — mais son absence ne bloque **pas** l'usage personnel, et A-Pack ne doit pas s'arrêter là-dessus.

### 11.2 Chaîne

Cible de déploiement **macOS 13.0** (`SMAppService` et `VNRecognizeTextRequestRevision3` l'exigent), binaire **universel** x86_64 + arm64.

**Runtime durci, pas de bac à sable.** C'est le modèle éprouvé sur macOS : `flags=0x10000(runtime)`, aucun `com.apple.security.app-sandbox`. `Packaging/Fouine.entitlements` est un **dictionnaire vide** (`<dict/>`) : Fouine ne pilote aucune autre app (pas d'`apple-events`), n'exécute pas de JIT (pas d'`allow-jit`), et l'inférence Vision ou Core ML est purement locale. Sandboxer imposerait des signets à portée de sécurité pour retrouver chaque racine à chaque lancement, sans bénéfice ici.

Le projet étant sous licence **AGPL-3.0-or-later**, les trois dépendances externes retenues (GRDB, swift-argument-parser, Sparkle) sont rigoureusement permissives (MIT, Apache-2.0) afin de garantir une redistribution libre et sans conflit de licence. Le Team ID éventuel est de toute façon public dans n'importe quelle app signée.

`Packaging/Info.plist` doit contenir au minimum :

```
CFBundleIdentifier            io.github.basedpolymer.fouine
LSMinimumSystemVersion        13.0
LSApplicationCategoryType     public.app-category.productivity
NSDocumentsFolderUsageDescription
    "Fouine lit les documents de votre dossier Documents pour les indexer
     et les rendre cherchables. Elle n'y écrit jamais."
NSDesktopFolderUsageDescription        (si une racine y est ajoutée un jour)
    "Fouine lit les documents que vous lui indiquez sur le Bureau pour les indexer."
NSRemovableVolumesUsageDescription     (annexe A, volume externe)
    "Fouine lit les documents du volume que vous lui indiquez pour les indexer.
     Elle n'y écrit jamais."
```

**`NSDocumentsFolderUsageDescription` est obligatoire, pas optionnel.** Sans lui, la lecture de `~/Documents/Cours` (ou de tout sous-dossier de Documents) échoue en `EPERM` silencieux et la moitié du corpus n'entre jamais dans l'index (§7.1). La v1.0 ne prévoyait que `NSRemovableVolumesUsageDescription`, qui ne couvre rien de tout cela.

> **Amendement du 03/09/2026 (D2 § 5.10, palier 4 PR 3 — un second artefact publié : l'extension `.mcpb`).** La chaîne ne produit plus seulement le DMG. `make mcpb` fabrique `dist/Fouine-<version>.mcpb`, l'archive zip que Claude Desktop installe d'un double-clic : `manifest.json` (schéma `"0.3"`, `server.type = "binary"`, `entry_point = bin/fouine`, `env.FOUINE_DB = ${user_config.database}`, réglage utilisateur **facultatif** — vide, le serveur retombe sur l'emplacement standard), le binaire `fouine`, `LICENSE` et `THIRD_PARTY_LICENSES.md` (B1-10 : le `.mcpb` est une copie redistribuée, il porte ses notices). **`Packaging/mcpb.sh` ne compile rien** : il recopie `Fouine.app/Contents/Helpers/fouine`, d'où l'ordre imposé `make release` → `make notarize` → `make mcpb`. Motif, et c'est le seul qui compte : extrait d'une archive téléchargée, ce binaire portera l'attribut de quarantaine ; signé Developer ID **sans notarisation**, Gatekeeper le refuse et l'extension ne démarre jamais — sans message, puisque le processus n'a pas commencé. Le binaire universel du premier paragraphe reste exigé, ici par `lipo -archs` dans le script. Le doublon d'exécutable avec `Fouine.app` est **assumé** (D2 § 5.10 point 3) : le `.mcpb` doit s'installer sans que la ligne de commande le soit ; pour Claude Code, qui lance une commande arbitraire, la voie documentée reste `/usr/local/bin/fouine`. `Packaging/mcpb/manifest.json` est versionné et confronté à `tools/list` par `FouineMCPTests.ManifestTests` — noms, ordre et descriptions —, et son champ `version` devient la **troisième** copie de `VERSION` (voir `RELEASING.md` § 1).

> **Amendement du 02/09/2026 (palier 3.2, audit U1).** Les textes ci-dessus sont ceux que l'utilisateur **français** lit ; ils vivent désormais dans `Packaging/InfoPlist.xcstrings` (traduction `fr`), et `Packaging/Info.plist` porte les textes **anglais**, langue de base de l'application (`CFBundleDevelopmentRegion = en`). `Packaging/bundle.sh` compile les deux catalogues (`xcstringstool compile`) en `Contents/Resources/{en,fr}.lproj/` avant la signature ; macOS choisit la langue de l'invite TCC d'après celle du système. Deux clés se sont ajoutées au palier 1.3 : `NSDownloadsFolderUsageDescription` et `NSNetworkVolumesUsageDescription`. Voir `docs/i18n.md`.

**Flux TCC app → agent, à implémenter dans cet ordre :**

```
1. Premier lancement de Fouine.app
      -> l'app lit un fichier de CHAQUE racine active
      -> macOS affiche l'invite « Fouine voudrait accéder à votre dossier Documents »
      -> l'utilisateur accepte : l'autorisation est attachée à la SIGNATURE de l'app
2. Seulement ensuite : interrupteur « indexer en arrière-plan »
      -> SMAppService.agent(plistName:).register()
      -> l'agent hérite du contexte d'autorisation de l'app signée
3. `fouine doctor` re-vérifie la lisibilité de chaque racine à chaque exécution
      -> échec = sortie 5 + le geste exact à faire (§7.1)
```

Ne **jamais** enregistrer l'agent avant l'étape 1 : un agent `SMAppService` **ne peut pas afficher d'invite TCC** et sera refusé en silence. La CLI, elle, hérite des autorisations du terminal qui la lance — ce qui explique qu'elle puisse marcher là où l'agent échoue, et inversement. `fouine doctor` doit dire lequel des deux contextes il teste.

Chaîne `make release` réelle du `Makefile` (compilation via SwiftPM, signature de l'intérieur vers l'extérieur) :

```bash
# 1. Compilation universelle SwiftPM
swift build -c release --arch x86_64 --arch arm64

# 2. Assemblage du bundle d'application
Packaging/bundle.sh .build/apple/Products/Release Fouine.app

# 3. Estampillage des numéros de version dans Info.plist
make stamp

# 4. Signature codesign de l'intérieur vers l'extérieur (runtime durci)
#    a. Sparkle.framework (Autoupdate, Updater.app, Versions/B)
#    b. FouineAgent (-i <identifiant>.agent)
#    c. CLI embarquée Contents/Helpers/fouine (-i <identifiant>.cli)
#    d. Fouine.app/Contents/MacOS/Fouine
#    e. Le bundle complet avec Packaging/Fouine.entitlements (<dict/>)

# 5. Vérification (make verify)
codesign -dv --verbose=4 Fouine.app

# 6. Notarisation séparée (make notarize / Packaging/notarize.sh)
ditto -c -k --keepParent Fouine.app Fouine.zip
xcrun notarytool submit Fouine.zip --keychain-profile fouine --wait
xcrun stapler staple Fouine.app
spctl -a -vv Fouine.app            # doit dire : accepted / Notarized Developer ID
```

**Point bloquant à signaler à l'humain, pas à contourner :** `notarytool` a besoin d'un profil de trousseau. La clé `AuthKey_<KEYID>.p8` est présente, mais **l'Issuer ID d'App Store Connect n'est pas récupérable depuis la machine**. L'humain doit exécuter une fois, à la main :

```bash
xcrun notarytool store-credentials fouine \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> --issuer <UUID lisible sur appstoreconnect.com>
```

Tant que ce n'est pas fait, A-Pack livre tout jusqu'à la signature incluse, et s'arrête au `submit` en le documentant. Ne pas inventer d'identifiant, ne pas tenter d'autre voie.

*Amendement 02/09/2026 (audit produit D3/D4) : identité et clé sortent du dépôt, voir `Makefile.local` et `RELEASING.md`.*

---

## 12 · Après la v1

Par ordre de valeur décroissante, hors périmètre de cette session :

1. **Recherche sémantique.** C'est la seule des trois familles de « termes voisins » du §5.5.3 que la v1 ne couvre pas : trouver une page qui parle de régiosélectivité quand on interroge « sélectivité des catalyseurs ». Aucune expansion lexicale n'y parvient — il faut des embeddings par page, un index vectoriel local, et une fusion des scores lexical et vectoriel.

   > **Amendement du 01/09/2026 — IMPLÉMENTÉE** (cible `FouineEmbed`, `fouine embed`, `fouine search --hybrid`, interrupteur « Sémantique » dans l'app ; conception et mesures issues de la contre-expertise interne). Les décisions ci-dessous se sont presque toutes vérifiées : modèle **multilingual-e5-small** (MIT), **balayage exhaustif SIMD sans index approché** (6,4 ms mesurées sur 379 k vecteurs int8), vecteurs en table ordinaire + similarité en Swift (`sqlite-vec` bien inutilisable), texte de `page_fts` réencodé sans ré-extraction. **Une décision est amendée : le moteur d'exécution est Core ML, pas ONNX Runtime.** Motifs : ONNX Runtime ajouterait une dépendance lourde que le §2.2 (« deux dépendances, pas une de plus ») interdit par ailleurs, tandis que Core ML est un cadriciel système ; et l'argument « sans Neural Engine, sans intérêt » est réfuté par la mesure — mlprogram fp16 par lots de 24 tient **66 ms/page** en CPU pur sur cette machine, sous le bas de la fourchette estimée (100-500 ms). La fusion des scores est un **RRF** (fusion de rangs, k = 60), pas une combinaison de scores : bm25 et cosinus ne sont pas commensurables. Détail d'implémentation notable : tokenizer SentencePiece Unigram réimplémenté en Swift (parité vérifiée contre Hugging Face), conversion du modèle par `Tools/convert_e5.py`.
   > **Amendement du 04/09/2026 (A1m-15, A1m-16, lot K1) — l'échelle se compte en FENÊTRES, et le poste de coût n'est pas le balayage.** ① Le « 379 k vecteurs » de l'amendement ci-dessus est le chiffre du schéma v3, où une page valait un vecteur. Mesuré le 04/09/2026 sur la base de production : **2,126 fenêtres réelles par page complète** (8 971 fenêtres pour 4 220 pages, soit le 2,13 de C2-05) ; à couverture pleine, 389 862 pages donnent ~829 000 fenêtres, soit **~318 Mio** de tampon int8 — deux fois et demie l'estimation d'origine, et le second poste de la base après le texte. Le rapport naïf « lignes de `page_vec` / pages vues » (1,371 avant réparation, 1,12 après) ne mesure PAS cela : il mélange les pages incomplètes de la campagne en cours, les sentinelles vides et les lignes d'un autre schéma. ② **Le balayage n'a jamais été le poste de coût.** Décomposition d'une recherche hybride en ligne de commande, mesurée le 04/09 : chargement du vocabulaire **4,9 à 7,0 s**, chargement CoreML 0,9 s, chargement de l'index vectoriel 0,12 s, recherche elle-même 0,3 s. Le vocabulaire — 9,3 Mo de JSON matérialisés en 250 000 `NSString` et 250 000 `NSNumber` par `JSONSerialization` — pesait donc à lui seul **plus de 80 %** du temps d'une recherche sémantique. Un cache binaire posé à côté du modèle (`vocab.bin`, invalidé par la révision du modèle et la taille de `vocab.json`) le ramène à **0,18-0,24 s**, et la recherche hybride complète de 11,7 s à **1,1 s**. Optimiser le balayage SIMD, passer en float16 ou poser des centroïdes aurait porté sur 1 % du temps. ③ `FOUINE_EMBED_COMPUTE=cpu` divise la mémoire résidente par **5,8** (86 Mio contre 498) et, sur le chemin RECHERCHE — une seule inférence —, va **plus vite** (0,67 s contre 1,14 s de mur, l'initialisation GPU/ANE n'étant pas amortie) ; sur le chemin CAMPAGNE il reste **1,7× plus lent** (3,8-4,3 fenêtres/s contre 6,6-7,2). Le défaut reste `.all`, arbitré par D2 sur la campagne : c'est elle qui dure vingt heures.

   > **Amendement du 03/09/2026 — le cosinus n'est pas une pertinence, et aucun seuil ne le rend tel.** Le protocole de vérification demandé par l'audit C2-01 a été exécuté sur la base de production (64 872 vecteurs, 390 114 pages, douze requêtes témoins dont six hors domaine). `VectorIndex.topK` accumule désormais, pendant le balayage qu'il fait de toute façon, la somme et la somme des carrés des produits scalaires sur les vecteurs **non nuls** — les pages de moins de `EmbedRun.minChars` caractères portent un vecteur nul qui, mélangé à la population, multiplie σ par trois — et rend `(μ, σ, scanned, zeros)` avec le top-k. Ces moments sont publiés dans le JSON (`semantic_stats`) : c'est un instrument de calibration permanent, pas un échafaudage. **Le résultat infirme l'hypothèse** : la marge `z = (cos − μ)/σ` ne sépare pas les requêtes hors domaine des requêtes pertinentes, elle les classe **à l'envers** (hors domaine +4,5 à +7,7 σ ; pertinentes +3,9 à +4,7 σ), parce qu'une requête pertinente est proche de *tout* le corpus et voit donc sa moyenne monter. Le **centrage** du corpus, essayé ensuite (`--vec-center`), corrige bien l'anisotropie (μ → 0,000, cosinus étalés de 0,29 à 0,56) sans renverser ce classement, et **aggrave la concentration** : la part des résultats sémantiques purs venant d'un seul document passe de 31 % à 65 %. Le banc de 42 requêtes livré le même jour (`Tools/ranking/`) confirme en grand : à `--vec-floor 4`, les quatre requêtes de paraphrase sémantique perdent 25 de leurs 34 résultats sémantiques purs — dont la totalité de « comment mesurer la chaleur dégagée par une réaction », qui ne rend AUCUNE page en lexical et neuf en hybride — tandis que les cinq requêtes hors domaine en gardent 44 sur 50. **Aucun plancher n'est donc armé** : `HybridSearch.defaultVectorFloor` vaut 0, le mécanisme et son option `--vec-floor` restent en place pour le jour où une statistique séparante sera trouvée — sur un jeu de requêtes **jugées** (`Tools/ranking/`), pas sur une intuition. Trois changements visibles accompagnent ce constat : la sortie affiche la **marge** (`sem#1 z+4.7`) et non plus `cos 0.85`, que tout le monde lisait « 85 % de pertinence » ; la **couverture** du canal sémantique est dite à chaque recherche (« 64872 vectors, 16.6 % of pages », plus un avertissement sur `stderr` sous 50 %) ; les **poids** du RRF sont exposés (`--lex-weight`, `--vec-weight`) pour la calibration — sans réglage persistant, et **sans** la formule `vecWeight = couverture` proposée par C2-02, que la contre-expertise D2 a infirmée (à 16 % de couverture elle n'atténuerait pas le canal, elle l'éteindrait).

   > **Amendement du 05/09/2026 (lot R1) — les rangs sémantiques sont replacés à l'échelle du corpus entier.** Le RRF suppose que les deux listes classent le MÊME univers. Or le canal vectoriel ne voit que les pages qui portent un vecteur — 15,9 % du corpus ce jour-là (64 872 / 408 758) — et une page première parmi un sixième des pages serait, en espérance, sixième ou septième parmi toutes. Sans correction, `energie libre` rendait cinq pages sémantiques sur les dix premières alors que 569 pages portent l'expression : le canal qui avait comparé une page sur six obtenait une place sur deux. La fusion reçoit donc une **échelle de rang** par liste (`RRF.fuse(rankScales:)`, `score += w / (k + rang × échelle)`), et l'échelle du canal sémantique vaut `pages_indexées / vecteurs` (`HybridSearch.semanticRankScale`, 6,3 ce jour-là ; 1 dès que tout est vectorisé). Mesuré : le premier hit sémantique passe de la première à la septième place, un seul sur dix au lieu de cinq ; sur une paraphrase sans aucune page lexicale (« comment mesurer la chaleur dégagée par une réaction »), rien ne change — la liste lexicale est vide, le canal sémantique remplit seul les dix places. Ce n'est PAS le `vecWeight = couverture` que C2-02 proposait et que D2 a écarté : un poids atténue toute la liste uniformément et l'éteint à 16 % ; l'échelle déplace chaque rang vers celui qu'il aurait eu sur le corpus entier, et s'efface d'elle-même quand la campagne se termine. La liste vectorielle reçoit aussi la diversité par document en rangs (au plus trois pages d'un même document avant les autres, `HybridSearch.diversified` — 31 % des hits sémantiques purs venaient d'un seul document le 03/09). `fouine search --raw-semantic-ranks` désarme l'échelle (calibration) ; le JSON hybride publie `semantic_rank_scale`.

   > **Amendement du 05/09/2026 (lot X1, audit AUDIT-R1 I4) — la diversité vectorielle est un palier, pas une queue ; l'échelle se juge.** `HybridSearch.diversified` envoyait la quatrième page d'un document APRÈS toutes les autres : sur une paraphrase sans page lexicale dont un seul cours est la source, l'utilisateur voyait trois pages du cours puis 197 autres documents, l'inverse du palier doux (× 0,5) du lexical. Désormais, au-delà de trois pages d'un document, le **rang est multiplié par 2** (`HybridSearch.diversityRankFactor`) et la liste retriée : la 4ᵉ page compte comme une 8ᵉ, la 10ᵉ comme une 20ᵉ, quelle que soit l'échelle du canal. Le serveur MCP **publie** l'échelle qu'il appliquait sans la dire (`semantic_rank_scale`, `null` en lexical) ; sans elle, `rrf` ne se relisait plus (`docs/mcp.md`). Ce qui n'est PAS tranché : l'échelle elle-même est un remède livré sans jugement, qui s'efface à couverture pleine (`semanticRankScale` → 1) en laissant intact le symptôme que C2-02 décrivait ; la dérivation « première parmi un sixième = sixième parmi toutes » suppose un échantillon uniforme, et la campagne va par `doc_id`. `systems.json` gagne `hybrid-raw` (`--raw-semantic-ranks`) et `hybrid-old` (l'hybride du 03/09) : c'est la comparaison `hybrid` / `hybrid-raw` sur le pool jugé qui décidera.

   > **Amendement du 10/09/2026 (RK-01, RK-03, RK-05, RK-08, lot RK1) — le banc a été jugé : ce que les 790 notes disent du classement hybride.** Le jeu de 42 requêtes de `Tools/ranking/` a été annoté page par page le 09/09/2026 (790 jugements 0/1/2, un agent, sondage du propriétaire 30/30 conformes) : les décisions ci-dessous ne reposent plus sur des comptages. **(a) Les guillemets désarment le canal sémantique.** Sur les quatre requêtes à phrase exacte, le canal vectoriel versait au RRF des pages qui ne portent PAS l'expression demandée — **4 résultats sur 10**, contre 0 en plein texte — et le coût est mesuré : nDCG@10 0,713 contre 0,946 sur `"energie libre"`, 0,637 contre 0,849 sur `"gaz parfait"`, 0,373 contre 0,601 sur `"transition de phase"`. Les autres contrats de requête étaient, eux, tenus par les deux canaux (`-mot`, `ext:`, `dossier:` : aucune violation sur cinq systèmes). Décision : **une requête qui porte au moins une phrase entre guillemets n'interroge pas le canal sémantique** (`ParsedQuery.hasPhrase`, `QueryParser.asksForExactPhrase`, `HybridSearch.run(typedQuery:)` — paramètre SANS valeur par défaut, pour qu'aucune surface ne puisse l'oublier). Le remède écarté est le tamis des candidats sémantiques sur la phrase : plus cher (une relecture par page) et plus opaque (un résultat disparaîtrait sans explication). Le refus est ANNONCÉ : `HybridResults.semanticDisarmed` (`SemanticDisarmReason.exactPhrase`), `hybrid_disarmed: "exact_phrase"` en JSON de la CLI à côté du `hybrid: false` du repli faute de modèle, la même clé et une phrase dans `note` côté MCP (`mode_used: "lexical"`, `semantic_available: true`), et une ligne sous le champ de l'application — l'interrupteur « Chercher aussi par le sens » ne bouge pas. Les trois surfaces tranchent AVANT d'appeler la fusion, ce qui rend la sortie lexicale entière (facettes, pagination, canal des noms) et évite le chargement du modèle. **(b) Le plancher de marge +4 σ : jugé, et il ne sert à rien.** `systems.json` le désignait comme « le réglage qu'il faut faire juger » depuis le 03/09/2026, et l'amendement du 03/09 réclamait explicitement un jeu de requêtes jugées plutôt qu'une intuition. Voici la réponse : sur 42 requêtes, `hybrid-floor4` ne change le classement que de **six** d'entre elles, pour un solde de **−0,008** de nDCG@10 (0,579 contre 0,587) ; il tronque une liste à 4 résultats sur 10 sur « comment mesurer la chaleur dégagée par une réaction » et **coupe les deux seules pages de calorimétrie qui répondent**, faisant passer son nDCG de **0,423 à 0,000** — la seule requête où le canal sémantique servait vraiment. `HybridSearch.defaultVectorFloor = 0` reste donc le défaut, et c'est désormais une mesure de pertinence, non plus un comptage ; `--vec-floor <z>` reste exposé pour la calibration. **(c) Ce que le canal sémantique apporte, et ce que la doc affirmait de travers.** Sur les 420 résultats de l'hybride, les **72** qui ne portent aucun mot de la requête sont notés **0 à 93 %** et **aucun n'est noté 2** ; les 348 autres sont notés 2 à 41 %. Le gain global de l'hybride (+0,078) est porté par **cinq requêtes** (les quatre paraphrases et « chromatographie liquide haute performance »), et il DÉGRADE de 0,037 les 32 requêtes où le plein texte répondait déjà : le réglage livré — sémantique décoché par défaut, `--hybrid` explicite — est appuyé pour la première fois par des jugements. `docs/recherche.md` comptait les résultats sémantiques purs (34 sur les paraphrases, 50 sur les absurdes) pour en déduire leur utilité : le comptage est remplacé par le tableau des notes. **(d) La sonde « forme tapée » (lot P1) n'est ni soutenue ni condamnée** : 0,744 contre 0,746 sur les pages, 0,791 contre 0,803 sur les documents — elle est derrière son témoin dans le bruit. Elle reste livrée pour son comportement défendable, et la documentation ne dit plus qu'une mesure la soutient. **(e) Outillage du banc** : la provenance de `queries.json` porte `docs_total`, `pages_indexed` et `pages_vec` (RK-14 : deux pools de corpus différents ne se comparent pas ligne à ligne), et deux requêtes « absurdes » qui touchaient la notice d'un four à micro-ondes et ses recettes sont remplacées (RK-13). 

   > **Amendement du 10/09/2026 (C2-08, lots MP1 puis RK1) — le repli en flou est aussi annoncé en mode hybride.** L'amendement du repli (§ 5.5.2) notait que `HybridResults` ne transportait pas le drapeau : le repli agissait sur le canal lexical de la fusion — `HybridSearch.run` appelle `GRDBStore.search` — sans qu'aucune surface le dise dans ce mode. `HybridResults.fuzzyFallback` recopie désormais celui du `SearchResults` lexical, et les trois surfaces l'annoncent par les MÊMES textes qu'en plein texte (`SearchAdvice.fuzzyFallback` sur stderr et `fuzzy_fallback` en JSON, la note du serveur MCP cumulée aux autres, la ligne sous le champ de l'application). Corollaire pour la mesure : une requête dont le canal lexical ne rendait rien lui rend maintenant des pages approchantes, qui entrent dans la fusion et éteignent la phrase `noLexicalMatch` — les requêtes « paraphrase sémantique » du banc sont exactement ce cas, et les chiffres de l'hybride ci-dessus datent d'un binaire d'avant ce repli.

   Ce qui est **décidé** : le moteur d'exécution est **ONNX Runtime** (binding Swift/Obj-C natif, CPU pur, fusion de graphe, quantisation INT8, 1,5× à 3× sur PyTorch en eager). MLX est exclu définitivement — il est conçu pour la mémoire unifiée d'Apple Silicon et ne tourne pas sur Intel ; Core ML fonctionne mais sans Neural Engine sur ce Mac, donc sans son intérêt. Le modèle est un *small* multilingue sous licence permissive : **multilingual-e5-small** (118 M paramètres, dim. 384, MIT) ou **Solon-embeddings** (MIT/Apache-2.0, entraîné et évalué sur le français). BGE-M3 est trop lourd ; **Jina v3/v4 sont disqualifiés par leur licence** (CC BY-NC-SA, Qwen Research) alors qu'ils sortent en tête des comparatifs — le piège est facile.

   Ordres de grandeur, **estimés, non mesurés** : 100 à 500 ms par page sur cette machine, soit **11 à 57 h** pour les ~410 000 pages du corpus ; ~0,63 Go de vecteurs en float32 (dim. 384), **~0,16 Go en INT8**, ~20 Mo en binaire 1 bit. À cette taille, un **balayage exhaustif SIMD suffit** : aucun index approximatif (HNSW, Faiss) n'est nécessaire — simplification majeure. `sqlite-vec` serait l'outil idéal mais c'est une **extension chargeable**, donc inutilisable ici (§5.5.2) : lire les `BLOB` d'une table ordinaire et calculer la similarité en Swift. Le poste GPU de l'**annexe B** peut absorber l'encodage initial et livrer les vecteurs par le même canal JSONL.

   Deux conséquences déjà actées en v1 : le texte reste stocké dans `page_fts` (§3) — c'est l'actif qui permettra d'encoder sans ré-extraction ni ré-OCR ; et la place de `page_vec(doc_id, page, vec BLOB)` est réservée au §4.1, sans créer la table.

2. **Racinisation française** (Snowball). **La v1.0 se trompait** en écrivant que cela « implique un tokenizer FTS5 personnalisé, ou un changement de moteur » : le changement de moteur **n'est pas nécessaire**. `SQLITE_OMIT_LOAD_EXTENSION` ne ferme que le `dlopen` de `.dylib` externes ; il ne touche pas à l'enregistrement en mémoire d'un tokenizer compilé statiquement, qui passe par l'API C `fts5_api` / `xCreateTokenizer`. Vérifié sur la machine : la fonction SQL `fts5` — le point d'entrée documenté de `fts5_api` — **est exposée** par le SQLite d'Apple. Et GRDB implémente déjà exactement ce mécanisme (`FTS5CustomTokenizer.swift`, `Database.add(tokenizer:)`) contre le SQLite **système**, sans un seul `enable_load_extension`.

   Recette v2 : compiler **`libstemmer_c`** (Snowball officiel, C portable, BSD-3) en cible statique SwiftPM, et écrire un **`FTS5WrapperTokenizer`** GRDB qui enveloppe `unicode61 remove_diacritics 2` et fait passer chaque jeton par le stemmer `french` — post-traitement en Swift pur, sans manipulation de pointeurs. Trois réserves honnêtes : `fts5.h` **n'est pas dans le SDK macOS** (la structure `fts5_api` doit être redéclarée dans un shim conforme à l'ABI d'Apple — ce que GRDB fait déjà) ; le tokenizer est **fixé à la création de la table**, donc y passer impose un **réindex complet** ; et cette combinaison précise (français + FTS5 + SQLite d'Apple) n'est publiée nulle part comme recette éprouvée. C'est un chantier, pas un correctif. Piste plus simple à évaluer d'abord : `NLTagger` avec le schéma `.lemma`, gratuit et déjà dans le système — lemmatisation ≠ racinisation, couverture française à vérifier empiriquement.

   **C'est le second argument d'adoption de GRDB dès la v1** : il rend cette porte franchissable sans changer de moteur.
3. **Normalisation de l'ordre de lecture** sur les pages à formules : la couche native y sort une étiquette par ligne, ce qui casse localement `NEAR` et `snippet()` (§6.1). Problème d'ordonnancement, pas d'OCR.
4. Réponses citées : un modèle local ou distant qui répond en citant page et document.
5. Sources applicatives (Mail, Notes, Messages) — exige l'Accès complet au disque, à traiter comme un choix explicite de l'utilisateur.
6. Racines supplémentaires : le reste de `~/Documents`, et le volume externe de l'annexe A s'il revient.
7. FTS5 `content=''` + magasin zstd séparé, si la base dépassait un jour le budget de 2 Go. **À ne pas faire tant que le §12.1 est au programme** : le texte stocké est ce qui rend les embeddings possibles sans tout relire.

   > **Amendement du 05/09/2026 (PERSP-Q8, lot GA).** La compression (`content=''` + zstd) n'est envisagée que sur un besoin réel (disque contraint), jamais pour tenir artificiellement un chiffre de budget. Avec le relèvement du budget P5 à 2,5 Go et le texte FTS stocké nécessaire aux embeddings sans ré-extraction, ce chantier reste différé tant que l'espace disque ne l'exige pas.

8. Format `.pages` (22 fichiers) : pris en charge à l'amendement du 03/09/2026 via `QuickLook/Preview.pdf`.

> **Amendement du 03/09/2026 — palier 4, serveur MCP : DÉCIDÉ ET COMMENCÉ.** Le § 12 n'annonçait rien de tel ; le palier 4 est arbitré par l'audit du 02/09 (§ 4.5) sur la contre-expertise D2 § 5, et sa première livraison est sur `main`. Ce qui est acté :
>
> **Ce que c'est.** `fouine mcp --stdio` sert l'index à un client MCP (Claude Code, Claude Desktop) en JSON-RPC sur l'entrée et la sortie standard. **AJOUT au contrat gelé du § 4.3** — une sous-commande de plus, aucune sortie existante ne change. Documentation : `docs/mcp.md`.
>
> **Écrit à la main, zéro dépendance.** Pas le SDK Swift officiel : il implémente la révision 2025-11-25, exige `swift-tools-version 6.1` et tire cinq dépendances dont une épinglée sur `branch: "main"` — ce que le § 2.2 interdit. Le cadrage stdio étant identique dans toutes les révisions, `Foundation.JSONSerialization` suffit.
>
> **Deux cibles, et le découpage est la licence.** `FouineMCPKit` (MIT, aucune dépendance : transport, routeur, enveloppes, budget, curseurs) et `FouineMCP` (AGPL : magasin en lecture seule, cycle de vie, outils). **Le binaire livré reste AGPL** — voir `LICENSING.md`.
>
> **Bi-époque.** La première requête décide : `initialize` ouvre le régime *legacy* (2024-11-05 à 2025-11-25, plus `ping`) ; `server/discover` ou un `_meta` portant `io.modelcontextprotocol/protocolVersion` ouvre le régime 2026-07-28 (sans état, `resultType`, `ttlMs`, `cacheScope: "private"`). Motif : la révision courante est 2026-07-28, mais **aucun des deux clients cibles ne la négocie par défaut aujourd'hui**. La spécification autorise explicitement de servir les deux époques dans le même processus.
>
> **Lecture seule, garantie par trois barrières indépendantes.** `Configuration.readonly` de GRDB (SQLite refuse), `ReadOnlyStore` qui n'expose aucune écriture (le compilateur refuse), aucun outil d'écriture déclaré (le modèle ne peut pas demander). Aucun migrateur, aucun `fouine.lock`. Cela demande une ouverture nouvelle dans le § 5.1 — `GRDBStore.openReadOnly(at:)` —, et `state.pool` devient `any DatabaseWriter` pour la porter ; les sites d'appel ne parlaient déjà que le protocole. **Correction au cadrage D2 § 5.2**, établie par la mise à l'épreuve : le montage recommandé (`DatabasePool` + `PRAGMA query_only`) ne tient pas — `DatabasePool.init` écrit un savepoint quand le `-wal` est vide, et GRDB remet `query_only` à 0 à la sortie de chaque bloc de lecture.
>
> **Cinq outils au total, un seul livré.** `fouine_status` d'abord (schéma D2 § 5.5 n° 5), parce qu'il ne dépend ni du modèle sémantique ni de la pagination. Suivent `fouine_search`, `fouine_read_page`, `fouine_similar_pages` et `fouine_list_documents`. Le serveur n'écrit jamais, n'indexe pas, et ne rend pas les fichiers d'origine : ce sont des choix, défendus dans D2 § 5.2.
>
> **Neuvième suite de tests** : `FouineMCPTests`, dont six transcriptions « golden » (`Tests/FouineMCPTests/Transcripts/*.jsonl`) qui figent le contrat de sortie.

> **Amendement du 03/09/2026 — palier 4, PR 2 : les quatre outils restants.** Le serveur expose désormais les cinq outils de D2 § 5.5. Ce qui est acté en plus de l'amendement ci-dessus :
>
> **Une seule forme de sortie pour deux moteurs.** `fouine_search` rend le même objet en lexical et en hybride, champs sémantiques (`cosine`, `z`, `lex_rank`, `vec_rank`, `rrf`, `semantic_only`, `semantic_stats`) à `null` quand le canal vectoriel n'a pas répondu. La CLI, elle, rend deux JSON différents (§ 4.3, contrat gelé, inchangé) : c'est acceptable pour un script, pas pour un modèle, qui ne saurait pas que les deux objets décrivent la même chose. Le score BM25 sort sous le nom `bm25`, à quatre décimales, documenté « négatif, non comparable entre requêtes » ; le cosinus sort documenté « pas une pertinence », la marge `z` à côté.
>
> **Le repli sémantique est annoncé, jamais muet, et jamais une erreur.** `mode: "auto" | "lexical" | "hybrid"` ; `auto` prend l'hybride si le modèle est installé **et** qu'il y a des vecteurs. Un `mode: "hybrid"` sans modèle rend un **succès** avec `mode_used: "lexical"`, `semantic_available: false` et un `note` qui nomme la commande manquante. Transposition exacte de `runHybrid` (§ 12, `CommandsSearch`).
>
> **Chargement paresseux et rechargement sur dérive.** Le modèle CoreML n'est chargé qu'au premier appel qui en a besoin — jamais par `fouine_status` ni par `fouine_similar_pages`, dont les voisins se lisent sur les vecteurs déjà en base. L'index vectoriel est rechargé quand `count(*) FROM page_vec` s'écarte de `VectorIndex.count` de plus de **10 %** (le `staleRatio` de `SemanticService` : une seule référence dans le produit, et non les 5 % de D2 § 5.2) ou toutes les **10 minutes**, le premier des deux, sur une file de fond et par échange atomique de la référence ; le comptage est demandé au plus une fois par minute. `fouine_status` publie `semantic.model_loaded` et `index_freshness{vector_index_loaded_at, vector_index_count}` — trois champs qui décrivent le **serveur** et sortent donc hors de son cache de 60 s, comme `write_lock`.
>
> **Pagination par curseur opaque, `has_more` observé.** Le curseur porte le décalage et une empreinte SHA-256 tronquée des arguments hors `cursor` ; un curseur repris d'une autre requête est refusé en `-32602` (« cursor does not match these arguments »). `has_more` s'obtient en demandant **un résultat de plus**, jamais en comparant à un total — les totaux sont approchés au-delà de 50 000 pages (C2-09b), et `totals_approximate` est exposé.
>
> **Plafond de réponse.** 60 000 caractères par réponse d'outil (`Budget.responseCharacters`). Au-delà, les **extraits** sont raccourcis d'abord, les **éléments** ensuite ; la réponse porte `truncated: true` et reste un JSON complet — on refabrique une charge utile plus petite, on ne tronçonne pas une chaîne sérialisée.
>
> **`min_cosine` de `fouine_similar_pages` a pour défaut 0**, et non les 0,80 de D2 § 5.5 : voir l'amendement du même jour sur le plancher de marge. Le paramètre reste exposé. L'outil rend un cosinus **par page**, jamais par fragment de page.
>
> **Deux lectures nouvelles dans le cœur** (§ 5.1, toutes en lecture seule) : `pagePreviews(for:maxChars:offset:)` gagne un décalage en caractères et rend `total_chars` ; `listDocuments` / `countDocuments` / `ocrPageCounts` / `vectorisedPageCounts` servent `fouine_list_documents`, avec `LIMIT`/`OFFSET` côté SQL sur un ordre **total**.
>
> **`FouineMCPTests` passe à 63 tests**, dont treize transcriptions « golden » et six suites nouvelles : pagination (137 résultats parcourus par pages de 10 rendent 137 hits distincts), budget de réponse, repli sémantique, silence réseau (écouteur local pendant une séance des cinq outils, zéro connexion), fraîcheur de l'index vectoriel, et un jeu sous modèle réel qui se saute sans lui.

> **Amendement du 10/09/2026 (CM-07, CM-09, CM-10, CM-11, CM-17, CM-18, PR-11, lot MC1) — le serveur tient sa parole, et compte juste.** ① **L'index est ouvert à la DEMANDE.** `MCPServer.init` ne lève plus rien : `ReadOnlyStore` ouvre à la première lecture et réessaie tant qu'il échoue (au plus une fois par `schemaCacheTTL`). Un index absent, d'un schéma plus récent, illisible ou dont le journal d'écriture attend un écrivain se refuse donc par le veto d'avant-appel — `isError: true` portant la phrase de l'ouverture — sur une connexion qui répond à `initialize` et à `tools/list`. Jusqu'ici le processus sortait en **3 avant la première réponse** : la promesse « la connexion tient, les outils rendent une erreur lisible » de `docs/mcp.md` ne valait que pour un schéma changé *pendant* que le serveur tournait, et le client n'affichait que « serveur déconnecté ». Mesuré le 10/09 sur une base au schéma 99 : avant, `exit 3`, aucune réponse ; après, `initialize` en 435 caractères puis `isError` de 163. Une base qui apparaît est servie sans relancer le serveur ; le journal de démarrage dit `schema=?` et la cause. ② **Le plafond de 60 000 caractères porte sur le MESSAGE**, donc sur les **deux** copies de la charge utile qu'un `CallToolResult` transporte (`content` texte et `structuredContent`) — ce que le commentaire de `Budget` affirmait et que le code ne faisait pas. `fouine_list_documents` à 200 rendait **115 484** caractères sur le fil (≈ 29 000 jetons) sans poser `truncated` ; il en rend **57 720**, `truncated: true`. Le bloc `content` reste émis : il partira quand un client réel aura montré qu'il s'en passe. ③ Les **cinq outils portent des `annotations`** (`title`, `readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`, `openWorldHint: false`) : sans elles un client demande confirmation à chaque appel d'un serveur qui ne peut rien casser, et l'annuaire d'extensions rejette. `privacy_policies` reste **absente du manifeste**, faute d'adresse publique de politique de confidentialité : la soumission à l'annuaire attend le site (RELEASING.md § 4 quinquies). ④ **Une valeur de filtre qui n'existe pas se refuse en nommant celles qui existent** — `lang` et `doc_ids` rejoignent `folder`. Deux lectures nouvelles dans le cœur (§ 5.1) : `knownLanguages()` et `unknownDocIDs(_:)`. La règle de `FolderCheck` tient : on ne refuse que ce qu'on peut contredire, une liste vide ne fonde aucun refus. ⑤ **Dit et non changé** : `snippet_chars` est un plafond sur l'extrait de FTS5, qui n'élargit pas le contexte (le schéma renvoie vers `fouine_read_page`) ; le serveur traite les messages **un par un**, et un `ping` reçu pendant une recherche hybride à froid attend jusqu'à ~2 s.

> **Amendement du 13/09/2026 (PM-06, PM-08, PM-13, PM-14, PM-16d, PM-19, PM-22 à PM-26, PM-28 à PM-31, lot MC2) — `fouine_search` complet, et honnête sur ce qu'il rend.** ① **Cinq paramètres rejoignent l'outil** : `since` (`YYYY-MM-DD`, `SearchQuery.modifiedAfter` ; une date illisible est une erreur d'OUTIL qui dit le format, jamais un filtre silencieusement ignoré), `fuzzy` (`off|auto|on`), `facet` (`doc_year|modified_year|folder|ext|source|lang` → clé `facets`, **page 0 seulement** : un curseur ne recalcule pas ce qui ne dépend pas de la tranche ; `doc_year` vient en tête — l'année que le document PORTE, contre `modified_year`, celle de son fichier, que le cœur appelle encore `FacetKey.year`), `compact` (les hits perdent `abs_path`, `path`, `link`, `folder`, `ext`, et la clé `documents`, indexée par `doc_id`, les porte une fois avec `n_pages` et le nombre de `hits` du document) et `marks` (`guillemets|brackets|asterisks|none`, par `SearchQuery.snippetMarkers` — à valeur par défaut, le SQL de `snippet()` est celui d'avant au caractère près, et l'application ne change pas). Le curseur couvre les cinq, son empreinte portant tous les arguments. Mesuré sur la base de production : `réacteur piston` à 10 hits, **21 752** octets pleins contre **18 408** compacts (−15 % quand les hits se répartissent sur huit documents), et **13 346 → 7 224** (−46 %) quand ils viennent d'un seul.
>
> ② **La couverture sémantique est celle du PÉRIMÈTRE.** `HybridResults` gagne `scope` (`SemanticScope` : pages indexées, pages vectorisées, `filtered`), calculé par `HybridSearch.scopeDocIDs` — le point unique des filtres de document — croisé avec `vectorisedPageCounts` et `indexedPageCounts` (lecture nouvelle, § 5.1). `fouine_search` publie `semantic_scope` et rend `semantic_coverage_pct` **du périmètre**. Un périmètre sans un seul vecteur **ne charge plus le modèle** : réponse lexicale, `hybrid_disarmed: "no_vectors_in_scope"` (nouveau cas de `SemanticDisarmReason`) et la note qui nomme le geste. Mesuré : `dossier:M2SU` en hybride, **4 587 ms → 1 473 ms** (médiane de trois passes) et `semantic_coverage_pct` **67,85 → 0**, `semantic_scope {pages: 31986, vectorised: 0, filtered: true}` ; le surcoût du calcul sur une requête filtrée ordinaire est de **15 ms** (404 → 419 ms).
>
> ③ **Ce que la réponse portait sans le dire.** `why` reçoit le drapeau de quorum dans les deux canaux (il annonçait `exact` avec neuf mots sur une page qui en porte trois) ; `fuzzy_expanded` est publié et noté ; `relevance_pct` rend par hit la pertinence RELATIVE que la sortie texte de la CLI imprime depuis toujours (`HitRelevance`, cœur pur : part du meilleur score de la réponse, sur le RRF en hybride) ; `time_seconds` donne le MOMENT d'un extrait de transcription (`TranscriptTime`, cœur pur : dernier marqueur `[MM:SS]` avant le mot trouvé, sinon le premier de la page) et le lien porte `&t=` — `DeepLink` le savait depuis PV1 et aucune surface ne lui en donnait ; `slide` et `embedded_image` disent ce qu'une page DÉSIGNE dans un conteneur OOXML (`PageLayout` + `textPageCounts`, `max(page)` de `page_src` à `src = 0` : **aucune** migration). Mesuré : doc 1259 page 164 = image incorporée **111** (53 diapositives), doc 1714 page 277 = image **198** (79 diapositives) ; `Outil Solveur Excel.mp4` page 2 → `t=601`.
>
> ④ **Le canal des noms obéit aux filtres** (`lang`, `since`, `doc_ids`, et la provenance par un `EXISTS` sur `page_src`) : `source: "transcript"` rendait cinq `.pdf` dans `name_matches`. ⑤ **Le message d'une erreur `-32602` recopie `data.reason`** (`FouineMCPKit`) : beaucoup de clients ne donnent au modèle que `message`, où « Invalid params » n'apprend rien ; toute énumération de schéma porte de plus `"type": "string"`. ⑥ **La description de l'outil dit toute la syntaxe** — `nom:`, `texte:`, `chemin:` et les quatre exclusions y manquaient alors que `docs/mcp.md` les documentait — et pose la réserve de citation : diapositive pour un diaporama, moment pour un enregistrement, page sinon.

> **Amendement du 14/09/2026 (PM-01, lot IG1) — un serveur peut ne servir qu'une partie de l'index.** `fouine mcp` n'acceptait que `--stdio` et `--db` : tout assistant branché sur le serveur voyait les trois racines, `Personnel/Santé` compris, et le seul contournement était un second index servi par `--db`. `fouine mcp --stdio --folders Livres,M2SU` (option répétable, valeurs séparées par des virgules) RESTREINT le serveur aux racines nommées. Le périmètre s'applique dans `ReadOnlyStore` — point unique des lectures — et **nulle part ailleurs** : aucun outil ne sait qu'il existe, et un outil ajouté demain en hérite. `roots()` ne rend que les racines servies, donc le `FolderCheck` de `fouine_search` refuse un `folder` hors périmètre en ne nommant QUE ces racines ; `docRow(id:)` rend `nil` hors périmètre, donc `fouine_read_page` et `fouine_similar_pages` opposent MOT POUR MOT le refus d'un `doc_id` inexistant — le refus ne doit pas apprendre que le document existe. `DocumentFilter.folder` n'en portant qu'une, un périmètre de plusieurs racines se liste par une requête paginée PAR racine, fusionnées dans l'ordre total de `DocumentOrder` (fusion d'ordres totaux : exacte, aucune ligne sautée ni doublée). `fouine_status` gagne `scope` — clé TOUJOURS présente, `null` sans périmètre —, et `documents` compte DANS le périmètre ; `pages_indexed`, `vectors` et `vector_coverage_pct` restent ceux de tout l'index (aucune lecture ne compte les pages d'un dossier sans les parcourir) et `scope.note` le dit. Étiquette inconnue : le serveur DÉMARRE (ouverture paresseuse, CM-07) et chaque outil refuse en nommant les racines existantes, mais `fouine mcp` sur une base lisible au lancement refuse en **64** avant de parler. `fouine mcp install --folders …` écrit l'option dans les configurations des clients, et une réinstallation sans `--folders` CONSERVE le périmètre déjà écrit. C'est un périmètre de LECTURE : les documents restent indexés, cherchés par l'application et comptés par `fouine status` — ce qui ne doit pas être indexé du tout relève du `.fouineignore` du § 5.2.

> **Amendement du 14/09/2026 (PM-05, PM-07, PM-16a, PM-17, PM-18, PM-19, PM-20, PM-22, PM-32, lot MC4) — les trois autres outils.** ① **`fouine_status` ne ment plus sur l'agent.** `LaunchdProbe.evaluate`, branche `.notRegistered`, rendait `isHealthy: true` alors que `agent_status` portait la preuve du contraire — reproduit le 13/09/2026 : launchd « Could not find service », `report_detail: "SIGTERM received"`, pendant que `fouine status --json` disait `alive: false, stale: true`. La règle est désormais « pas d'enregistrement ET un rapport = l'agent est TOMBÉ ; aucun rapport = jamais armé, ce qui n'est pas une panne » ; `populateLaunchdFields` est appelée dans cette branche, et l'objet `agent` du serveur publie `alive` et `stale`, **les propriétés mêmes** d'`AgentStatusRecord` que publie la ligne de commande. ② **`disk_budget` et `meaning_background` passent dans le cœur** (`StatusJSON`, FouineCore) : ils étaient calculés dans l'exécutable de la CLI, donc hors de portée du serveur, qui taisait `level: "over"` et `pages_left: 139 638` — exactement ce qu'un assistant doit savoir avant de conseiller `fouine embed`. `status --json` et `doctor --json` sont inchangés au caractère près. ③ **La couverture sémantique par RACINE** rejoint `roots[]` (`pages`, `vectorised_pages`, `coverage_pct`, par `HybridSearch.scope` avec `folders: [label]`) : c'est le chiffre qui explique « M2SU 0 % » (PM-05) là où la couverture globale annonce 67,85 % — mesuré : `Livres` 73,34 %, `M2SU` **0**, `Personnel` **0**. Coût mesuré sur 434 372 pages : `fouine_status` à froid passe de 1 959 à 2 907 ms (médiane de trois, interleavée), `include_roots: false` le ramène à 1 939 ms, et le calcul a son propre cache de 60 s.
>
> ④ **`fouine_similar_pages` peut encoder la page source, sur demande.** `encode_if_missing`, **défaut `false`** : le contrat « never loads the model » reste celui de l'appel ordinaire, et c'est un acquis mesuré (~10-220 ms, ~16 Mio). À vrai, le texte de la page est découpé par les fenêtres de la campagne, encodé et quantifié par le MÊME chemin (`PageEmbedding`, FouineEmbed, que `EmbedRun` appelle aussi — deux découpes du même texte finiraient par diverger sans que rien ne le montre), puis comparé par `VectorIndex.neighbours(ofVectors:k:excludingDoc:)`, variante nouvelle à l'agrégation identique (maximum du cosinus par page cible). `source_vector` dit d'où vient le vecteur (`stored`, `computed`, `null`) ; `source_has_vector` continue de décrire **l'index**, donc reste faux sur une page encodée à la volée. Une page sans texte indexé ou sous `minChars` est refusée **avec sa raison**, pas comparée. Mesuré sur une page de `M2SU` : sans, 2 476 ms et zéro voisin ; avec, 4 237 ms et trois voisins (0,884 / 0,882 / 0,875) ; 650 ms pour la page suivante, modèle résident. L'outil gagne aussi `time_seconds` par voisin transcrit et `compact`, du même patron que `fouine_search`.
>
> ⑤ **`fouine_read_page` bascule sur `PageReading`** (FouineCore, lot MC3) : une seule implémentation avec `fouine read`, mêmes clés au caractère près. Il gagne `slide`, `embedded_image` et `time_seconds` — les trois réserves de citation, là où le modèle LIT la page qu'il va citer — et `page_label`, le numéro IMPRIMÉ sur la page quand il diffère du rang (`PDFPage.label`, document rouvert et relâché comme le renderer). Lu à la LECTURE et jamais stocké : mesuré, 12 → 142 ms sur un livre de 428 pages et 11 → 238 ms sur un de 1 173 (médianes de trois, interleavées) — tenable pour UNE page, exclu par hit, d'où son absence de `fouine_search`. Il corrige 44 % des livres (préliminaires en chiffres romains : rang 12 → `xi`, `3`) et **pas** le livre dont le numéro n'est imprimé que dans l'en-tête courant, sans `/PageLabels` : `page_label` y vaut `null` plutôt que le rang déguisé. `PageReading` porte le champ, donc `fouine read --json` l'a aussi.
>
> ⑥ **`fouine_list_documents` rend `modified`** (PM-16a), que `fouine list --json` portait et que le serveur taisait — un agent triait par `order: "recent"` sur une date invisible. En **UTC**, seul écart assumé avec la CLI : tout ce que ce serveur horodate l'est déjà, et un fuseau local rendrait les transcriptions « golden » dépendantes de la machine qui les rejoue. `"type": "string"` rejoint les énumérations `state` et `order`.

> **Amendement du 05/09/2026 (R-18, lot G2).** La sous-commande `fouine mcp install [--client all|claude-desktop|claude-code|cursor] [--dry-run] [--json]` automatise la configuration des clients MCP locaux. Elle met à jour les fichiers de configuration JSON (`claude_desktop_config.json`, `~/.cursor/mcp.json`) en préservant les autres serveurs et réglages, effectue une sauvegarde `.fouine-bak` avant écriture atomique, et invoque `claude mcp add` pour Claude Code lorsque l'outil est sur le PATH. Elle privilégie le chemin `/usr/local/bin/fouine` lorsqu'il pointe vers le binaire actif afin de survivre aux mises à jour de l'application.
>
> **Amendement du 15/09/2026 (MI1).** `--client` accepte aussi `codex` et `antigravity`, et `all` les inclut, dans l'ordre Claude Desktop, Claude Code, Cursor, Codex, Antigravity. **Codex** lit `~/.codex/config.toml` : la commande y ajoute la table `[mcp_servers.fouine]` (`command`, `args`) ou la remplace ligne à ligne si elle existe — de son en-tête à l'en-tête suivant, quel qu'il soit, de sorte qu'une sous-table `[mcp_servers.fouine.env]` posée à la main survit ; tout le reste du fichier est conservé au caractère près, sauvegarde `.fouine-bak` et écriture atomique comme en JSON ; un `mcp_servers` écrit en table en ligne est refusé (`failed`, motif explicite), TOML interdisant de l'étendre. **Antigravity** lit `~/.gemini/config/mcp_config.json` (partagé par Antigravity 2.0, l'IDE et la CLI ; `~/.gemini/antigravity/mcp_config.json` quand seul ce dossier plus ancien existe), forme `mcpServers` de Claude Desktop. Dans les clients JSON, une entrée `fouine` déjà écrite garde ses autres clés (`env`, `disabled`) : seuls `command` et `args` sont remplacés. Un client dont le dossier manque est `skipped` (« Codex is not installed »). La commande, son `--help` et `docs/mcp.md` disent où vit la ligne de commande quand `fouine` n'est pas sur le `PATH` (`Fouine.app/Contents/Helpers/fouine`), et l'écran d'accueil de l'app copie la demande complète à coller dans un assistant (`AssistantRequest`), chemin réel du binaire compris — seule chaîne de l'app qui montre un chemin sans qu'on le demande, parce qu'elle s'adresse à l'assistant et ne s'affiche jamais. `fouine mcp install --print` imprime l'entrée générique (binaire résolu, ligne de commande, forme `mcpServers`, table TOML ; `--json` : `{"command", "args"}` seul) sans rien écrire et sans qu'aucun client soit installé — `--dry-run` ne rend pas ce service, puisqu'il saute un client dont le dossier manque. La page `basedpolymer.eu/fouine/mcp`, écrite pour un assistant, couvre l'installation de l'app, du serveur et d'un client non listé ; la demande copiée y renvoie. **Correction** : `mcp install --folders …` n'écrivait AUCUN périmètre depuis IG1 — la commande parente `mcp` déclare la même option et ArgumentParser la lui attribue, où qu'elle apparaisse ; `install` relit désormais la ligne de commande après son nom (`--folders A,B`, `--folders A B`, `--folders=A,B`), et la recette le prouve par le binaire.

---

## Annexe A · Si un volume externe revient un jour

**Hors périmètre v1** (§1). Cette annexe existe parce que le modèle de données le permet sans un caractère de changement — `volumes(uuid, label, last_seen, fsevent_id)` et `roots(vol_uuid, rel_path, label, enabled)` sont génériques — et parce que les pièges ci-dessous sont réels, mesurés sur le volume `/Volumes/0768209870` (ExFAT, USB, 931 Gio, UUID `4BF10F0B-B13A-3FA9-A526-BCD8F7E5F0D6`, **33 Mo/s** en lecture séquentielle). Ce volume n'était pas monté au moment de la révision v1.1.

Ce qui existe **uniquement** là-bas et justifierait le rebranchement : les dossiers `Banque`, `Nutrition`, `Personnel` complet, et les cours L1 à M1 (~2 544 documents dans `Cours`, 9,4 Go).

**Les cinq pièges spécifiques, à réactiver tels quels le jour venu :**

1. **AppleDouble.** ExFAT n'a pas de fork de ressource : macOS sème des `._nom.pdf` partout. Sur un échantillon de 150 « PDF », **13 en étaient** ; ~280 sur l'ensemble du volume. Le filtre par préfixe `._` sur chaque composant du chemin est **déjà dans le §5.2** et coûte zéro sur APFS (0 occurrence mesurée). Il redevient discriminant sur ExFAT — et T8 avec lui.
2. **`mtime` ExFAT** : granularité **10 ms**, pas de fuseau normalisé. Comparer avec une tolérance de 20 ms. Sur APFS (nanoseconde), cette tolérance est inoffensive mais inutile.
3. **Pas d'inode stable, pas de permissions POSIX fiables.** Ne s'appuyer que sur `(rel_path, size, mtime)`.
4. **Volume démonté en cours de route.** À détecter **à chaque lot**, pas seulement au démarrage : `FouineError.volumeNotMounted`, sortie **2**, file intacte, message nommant le label et l'UUID attendus. L'interface reste consultable — l'index vit sur le SSD interne (§5.6). C'est le T9 de la v1.0, à réactiver.
5. **L'E/S redevient le facteur limitant.** 33 Mo/s contre 1,31 Go/s : le plancher d'E/S de P7 remonte de ~15 s à ~12 min pour 24 Go, et l'argument « ne jamais hacher le contenu » (§7.2 n°15) retrouve sa justification chiffrée.

`fouine volume add --path <chemin monté> [--roots A,B,C]` (§4.3) reste dans la CLI pour ce cas, et pour lui seul : sur le corpus interne, `fouine root add` est la bonne commande.

---

## Annexe B · OCR externe (poste GPU)

**L'app reste 100 % autonome** : Vision `.accurate` suffit et ne dépend de rien. Cette annexe décrit un **canal d'échange optionnel** permettant à un poste Windows/nvidia de servir de moteur par lots, **hors ligne**, par fichiers. Aucun réseau, aucun service, aucune dépendance ajoutée à Fouine.

**Format d'échange : JSONL, une ligne par page.**

```json
{ "rel_path": "Users/<vous>/Livres/Chimie/Clayden.pdf",
  "vol_uuid": "75F6E680-A01E-49E2-A130-1800826B45AA",
  "page": 400,
  "engine": "paddleocr", "engine_rev": "2.9-fr",
  "text": "Le premier est la phéromone sexuelle…",
  "lines": [ {"t": "Le premier est la phéromone", "x": 0.12, "y": 0.83,
              "w": 0.61, "h": 0.021, "c": 0.94} ] }
```

`x, y, w, h` sont **normalisés 0..1, origine en bas à gauche — convention Vision**, identique à celle de `ocr_layout` (§4.1). Un producteur qui travaille en origine haut-gauche doit convertir : `y_fouine = 1 − y_haut − h`.

**Les deux commandes** (§4.3) :

- `fouine ocr export [--pending] [--limit N] [--render-png <dossier>] --out f.jsonl`
  produit la liste des pages en file (`ocr_queue`), avec `rel_path`, `vol_uuid`, `page`, et — si `--render-png` est donné — les rendus PNG 150 dpi plafonnés à 4 Mpx, nommés `<doc_id>_<page>.png`. Sans `--pending`, un ensemble de pages désigné par une requête SQL sur `page_src` (voir cas d'usage).
- `fouine ocr import f.jsonl`
  remplit `page_fts`, `page_src` et `ocr_layout` **dans les mêmes transactions que Vision** (une page = une transaction, suppression par rowid), avec `page_src.engine = external` et `engine_rev` recopié depuis le fichier. Les lignes sous le seuil de confiance sont filtrées comme au §6.2 : le canal externe n'a aucun privilège.

**Cas d'usage, par valeur décroissante — révisés après banc d'essai sur un poste Windows avec GPU dédié** (RTX 2060 6 Go, 2026-08-31, protocole de qualité identique au §2.7 ; contre-expertise interne, non publiée) :

| Cas | Requête de sélection | Verdict mesuré |
|---|---|---|
| Encodage des embeddings v2 | toutes les pages | §12.1 — le même canal transporte des vecteurs ; seul usage où le GPU est clairement gagnant |
| Accélérer le premier passage des livres imprimés | `ocr_queue WHERE prio >= 1` | **optionnel, vitesse seule** : docTR 1.1 égale Vision au point près (93,8 % contre 93,6 % de mots réels, 100 % de rappel tous deux) à 0,48–0,69 s/page contre 3,10 — ≈ 11,5 h gagnées une fois, transfert des ~17 Go compris (8,1 Mo/s mesuré). Aucun gain de qualité à prendre. |
| Re-OCR des pages douteuses | `page_src WHERE src != 0 AND conf < <seuil>` | possible par construction (index sur `conf`) ; aucun moteur mesuré ne le justifie aujourd'hui |
| Re-OCR des manuscrits | — | **déconseillé, mesuré** : sur les pages telles qu'elles sortent du corpus (CamScanner pivotées 90°), Vision fait 76,1 % de rappel contre 68,0 % pour Surya, qui n'a pas de détecteur d'orientation ; Surya ne passe devant (82,0 %) qu'après redressement préalable, et paie ce gain en versant ~4× plus de faux jetons dans le vocabulaire (43,3 % de mots réels contre 54,6 %) — le mal exact du §5.5.2. TrOCR-fr : 31,7 %, hors domaine. |

**Contrainte dure : le surlignage exige des boîtes par ligne.** Les moteurs à boîtes (**PaddleOCR**, **Surya**, **kraken**) conviennent. Un **VLM sans boîtes** (donner la page à un modèle de vision-langage et récupérer du texte) produit un texte cherchable mais **pas de `ocr_layout`** : la page devient trouvable, le surlignage sur l'aperçu est dégradé — et l'aperçu **doit l'indiquer** à l'utilisateur (« texte importé sans boîtes : surlignage indisponible ») plutôt que de laisser croire à un bug.

**Débits GPU : MESURÉS le 2026-08-31 sur un poste Windows avec une RTX 2060 (6 Go)** : docTR 1.1 **0,48–0,69 s/page**, Surya 0.17 **7–12 s/page** — loin des 10–50 p/s de la littérature sur ce matériel. **Aucune décision de la v1 n'en dépend, aucun seuil d'acceptation n'en est tiré.** Deux mises en garde d'outillage pour qui rejouerait le banc : **Surya ≥ 0.20 a supprimé l'inférence PyTorch locale** (vLLM/Docker ou API obligatoires) — la voie mesurée est `surya-ocr==0.17.1` épinglé avec `transformers<5`, en fin de vie ; et les roues torch doivent être **cu126** pour la compute capability 7.5 de cette carte. Cet environnement de banc d'essai (11,9 Go, autonome) est réutilisable tel quel pour les embeddings v2.
