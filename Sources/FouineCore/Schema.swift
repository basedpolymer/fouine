// Schema.swift — SCHÉMA SQLITE GELÉ (SPEC §4.1), commit « freeze: contracts ».
// Fichier en LECTURE SEULE pour tous les sous-agents.
//
// AMENDEMENT du 01/09/2026 (audit A4, TOP 5 n°3), seule dérogation au gel :
// `ocr_layout` perd son `WITHOUT ROWID` au profit du rowid structuré déjà imposé
// partout ailleurs (§4.1). Motif chiffré dans le commentaire de la table ;
// (le schéma est créé directement sous cette forme depuis le lot J1).
//
// Les PRAGMA de connexion (journal_mode=WAL, synchronous=NORMAL, foreign_keys=ON,
// busy_timeout=5000) sont configurés par le Store via GRDB, pas par ce script.
//
// AMENDEMENT du 01/09/2026 (hybride sémantique, v3) : la place réservée
// « v2-page-vec » du SPEC prévoyait `(doc_id, page) … WITHOUT ROWID` ; elle est
// créée en rowid structuré, pour les mêmes raisons chiffrées que l'amendement A4
// ci-dessus (convention §4.1, accès direct par clé entière, zéro index
// secondaire).
//
// AMENDEMENT du 03/09/2026 (fenêtrage sémantique, v5 — constat C2-05) : le
// rowid de `page_vec` cesse d'identifier une PAGE pour identifier une FENÊTRE
// de page. Une page de 1 400 caractères au plus tient dans un vecteur ; le
// corpus, lui, a une page moyenne de 2 282 caractères et 77,3 % de ses pages
// dépassent 1 400 — le vecteur ne voyait donc que 56,2 % du texte indexé.
// Le rowid structuré du §4.1 est prolongé d'un chiffre de fenêtre :
// `vrowid = (doc_id * 100000 + page) * 8 + chunk`, `chunk ∈ [0, 7]`. La
// fenêtre 0 est EXACTEMENT `prefix(1400)`, c'est-à-dire ce que la campagne
// produisait déjà.
//
// AMENDEMENT du 11/09/2026 (constat PR-07) : `docs` porte `doc_date`, la date
// INSCRITE DANS LE DOCUMENT (PDF, EPUB, bureautique, courriel, photo), par
// opposition à `mtime` qui est celle du fichier. Colonne nullable, index dédié,
// écrite à l'extraction et seulement là.
//
// IL N'Y A PAS DE CHAÎNE DE MIGRATIONS (13/09/2026, lot RC1). Ce fichier décrit
// UN état : celui que `ddl` crée. Une base d'une autre version est refusée à
// l'ouverture — plus ancienne, on refait l'index ; plus récente, on met Fouine
// à jour — et c'est le Store qui porte ce refus (`GRDBStore.schemaMismatch`).

import Foundation

public enum Schema {
    /// Version inscrite dans `meta.schema_version` à la CRÉATION, et SEULE
    /// version que ce binaire ouvre : toute autre valeur est refusée, aucune
    /// n'est rattrapée (lot RC1). L'histoire des versions est dans le
    /// CHANGELOG, pas dans le code.
    ///
    /// Ce que porte le schéma courant :
    ///
    ///   · `docs`, `roots`, `page_src`, `page_fts` — les documents, leurs
    ///     racines, le texte de leurs pages et son index plein texte ;
    ///   · `docs.inode`, pour qu'un renommage soit un renommage et non une
    ///     suppression suivie d'une redécouverte (A3-02) ; `docs.rel_path` et
    ///     `roots.rel_path` en forme Unicode NFC, une seule forme comparable
    ///     octet à octet (A3-10) ; `docs.doc_date`, la date que le document
    ///     PORTE (PR-07), nullable parce que la plupart des formats n'en ont
    ///     aucune ;
    ///   · `docs_fts` — le NOM du document et celui de son dossier, indexés à
    ///     part, pour le bonus de classement D-R3 (idée R-02). Une table de
    ///     quelques milliers de lignes ; surtout PAS une colonne de plus dans
    ///     `page_fts` (voir le commentaire de la table) ;
    ///   · `ocr_layout` et `page_vec` au rowid structuré (audits A4, C2-05),
    ///     `vec_meta` (identité du modèle et géométrie du fenêtrage) ;
    ///   · `settings` et `agent_status` (audits U2, F7), `vocab_tri`, `meta`.
    public static let version = 9

    /// Tokenizer de `page_fts`. PARTAGÉ avec la table d'appoint de la récolte
    /// OCR (`ocrHarvestDDL`) : les deux DOIVENT rester identiques, faute de quoi
    /// un terme normalisé autrement entrerait dans `vocab_tri` et polluerait
    /// l'expansion floue (§5.5.2).
    public static let pageTokenizer = "unicode61 remove_diacritics 2"

    /// ROWID STRUCTURÉ, IMPOSÉ : rowid = doc_id * 100000 + page (page 1-indexée).
    /// Limite assumée : 99 999 pages par document (maximum du corpus : 1 570).
    public static let pagesPerDocLimit: Int64 = 100_000

    /// Plus haut numéro de page qu'un document puisse porter (audit S2).
    ///
    /// La limite était ASSUMÉE mais jamais VÉRIFIÉE : la page 100 000 d'un
    /// document porte exactement le rowid de la page 0 du document SUIVANT et
    /// écrasait en silence ses `page_fts`, `ocr_layout` et `page_vec` — puis la
    /// purge du premier document (`ftsRowIDRange`) emportait les pages du second.
    /// Trois barrières désormais, de la plus douce à la plus dure : les
    /// extracteurs qui connaissent le nombre de pages d'avance refusent avant de
    /// travailler (`PDFExtractor`, `DjvuExtractor`), le store refuse à l'écriture
    /// pour tous les autres chemins (`replacePages`, `completeOCR`), et
    /// `ftsRowID` casse le programme plutôt que de rendre un rowid qui
    /// appartient à un autre document.
    public static let maxPage = Int(pagesPerDocLimit) - 1

    // MARK: - Bonus de classement (lot M1, D-R2 et D-R3)

    /// LE SIGNE, une fois pour toutes. `bm25()` rend une valeur NÉGATIVE, et le
    /// tri est `ORDER BY r ASC` : plus le score est négatif, meilleure est la
    /// page. Un bonus est donc un facteur `> 1` appliqué à `r` — il éloigne le
    /// score de zéro, c'est-à-dire qu'il fait MONTER la page. Ajouter une
    /// constante, lui, n'aurait aucun sens : bm25 n'a pas d'échelle absolue.

    /// Bonus quand la page porte les mots de la requête EN PHRASE, dans l'ordre
    /// et sans rien entre eux. Le palier le plus fort : c'est exactement ce que
    /// l'utilisateur aurait tapé entre guillemets s'il avait su qu'il pouvait.
    public static let phraseBoost = 0.8

    /// Bonus quand les mots sont simplement PROCHES (`proximityWindow` jetons).
    /// La moitié du précédent : « énergie » à trois mots de « libre » est un
    /// bon signe, pas une certitude. Les deux se cumulent (une phrase est aussi
    /// un voisinage) : une page en phrase pèse donc × 2,2.
    public static let nearBoost = 0.4

    /// Fenêtre du `NEAR`, en jetons. 12 ≈ une ligne et demie de texte courant :
    /// assez large pour « l'énergie libre de Gibbs », assez étroite pour ne pas
    /// apparier deux mots de deux phrases voisines.
    public static let proximityWindow = 12

    /// Bonus quand le NOM du document — ou celui de son dossier — porte un des
    /// mots (table `docs_fts`, schéma v8). Le plus petit des trois : un nom de
    /// fichier est un signal fort mais grossier, et il vaut pour TOUTES les
    /// pages du document. C'est pourquoi il n'agit, comme les deux autres,
    /// qu'à partir de DEUX mots : sur un mot seul, il faisait occuper l'écran
    /// entier par le seul livre dont le titre portait le mot (mesuré le
    /// 05/09/2026, voir `GRDBStore.rankingProbes`).
    public static let documentNameBoost = 0.3

    /// Bonus quand la page porte les mots TELS QU'ILS ONT ÉTÉ TAPÉS, et pas
    /// seulement une de leurs formes morphologiques (lot P1, `SearchQuery
    /// .typedFormBoost`). Il ne s'arme que lorsque la morphologie a
    /// effectivement ajouté une forme : sans elle, toutes les pages le
    /// recevraient, et un facteur constant ne classe rien.
    ///
    /// LE CONSTAT (audit AUDIT-R1 I2, base réelle) : les dix premières pages de
    /// `entropie` portaient bien le mot tapé, mais entre les rangs 11 et 50,
    /// 22 pages sur 50 ne portaient QUE « entropies » — 24 sur 50 pour
    /// `hypothese`. La déclinaison doit rester trouvable, pas passer devant.
    ///
    /// 0,5 : plus fort que le nom du document (0,3), plus faible que la phrase
    /// (0,8). Mesuré le 05/09/2026 sur la base réelle, 50 pages rendues, six
    /// mots (`polymere`, `entropie`, `hypothese`, `energie`, `complexe`,
    /// `enthalpie`) : les cinquante premières pages portent TOUTES la forme
    /// tapée, contre 35 sur 50 pour `entropie` et 38 sur 50 pour `hypothese`
    /// sans la sonde — et les dix premières ne bougent d'aucun rang sur aucun
    /// des six mots. C'est exactement le réglage cherché : corriger les rangs
    /// 11 à 50 sans toucher au haut de la liste. Le prix est d'une exécution
    /// FTS de plus sur les mots tapés : médianes de trois, +2 ms sur cinq mots,
    /// +29 ms au pire (`energie`, 29 005 pages appariées).
    /// Voir `GRDBStore.rankingProbes`.
    public static let typedFormBoost = 0.5

    // MARK: - Un document ne prend pas tout l'écran (lot R1)

    /// Nombre de pages d'un MÊME document qui concourent à pleine force. Les
    /// suivantes sont rétrogradées par `diversityDemotion`.
    ///
    /// LE CONSTAT (05/09/2026, base réelle, 50 premières pages) : `loi de hess`
    /// → 28 pages sur 50 d'un seul livre, 4 documents à l'écran ; `gaz parfait`
    /// et `catalyse` → 24/50 ; `potentiel chimique` → 23/50, 7 documents. Des
    /// scores bm25 presque plats à l'intérieur d'un gros ouvrage (−12,15 à
    /// −11,06 sur les 50 premières pages de `polymere`) font sortir ses pages
    /// en bloc, et l'application — qui regroupe par document — ne montre plus
    /// que quatre ou cinq titres. Trois pages suffisent à dire qu'un livre
    /// traite le sujet ; le compte de pages touchées et « Rechercher dans ce
    /// document » donnent le reste.
    public static let diversityFullStrengthPages = 3

    /// Facteur appliqué au score des pages au-delà de `diversityFullStrengthPages`.
    /// Le score bm25 est NÉGATIF : le multiplier par 0,5 le rapproche de zéro,
    /// donc fait DESCENDRE la page — sans la retirer. C'est un palier DOUX :
    /// sur une requête à plusieurs mots où les scores s'étalent (`loi de hess`,
    /// −54,9 à −22,9), la quatrième page d'un livre très pertinent reste devant
    /// la première page d'un document qui n'effleure le sujet.
    public static let diversityDemotion = 0.5

    /// Le texte indexé dans `docs_fts` pour un document : le dernier composant
    /// du chemin SANS son extension, puis le nom du dossier qui le contient.
    ///
    /// Le dossier parent compte autant que le fichier : « Thermodynamique/
    /// chap3.pdf » ne dit rien par son nom de fichier, et tout par son dossier.
    /// L'extension est retirée : « pdf » et « docx » seraient des termes
    /// portés par des milliers de documents, sans le moindre pouvoir
    /// discriminant — et `ext:` les filtre déjà.
    public static func documentIndexName(relPath: String) -> String {
        let components = relPath.split(separator: "/").map(String.init)
        guard let last = components.last else { return "" }
        let base = (last as NSString).deletingPathExtension
        let parent = components.count >= 2 ? components[components.count - 2] : ""
        return parent.isEmpty ? base : base + " " + parent
    }

    // MARK: - Quorum des mots et malus des sommaires (lot RK2, RK-04 et RK-07)

    /// En dessous de ce nombre de pages appariées, une recherche ARMÉE en
    /// quorum (`SearchQuery.quorum`) relâche le ET strict et demande la
    /// plupart des mots au lieu de tous (§5.3).
    ///
    /// DIX, c'est-à-dire un écran. Le constat RK-04 (09/09/2026, base de
    /// production) : `comment mesurer la chaleur degagee par une reaction` rend
    /// 0 page, `la chaleur degagee par une reaction` en rend 10, et les deux
    /// bonnes réponses que l'hybride finit par trouver (472 p.258, 158 p.583)
    /// portent toutes deux « reaction » — ce sont des pages que le ET strict
    /// avait exclues. Au-dessus de dix pages strictes, l'utilisateur a déjà de
    /// quoi lire et rien ne se relâche : le quorum ne coûte alors RIEN, pas
    /// même une requête de plus.
    public static let quorumTrigger = 10

    /// Nombre de candidats LEXICAUX dont le texte est relu pour décider s'ils
    /// sont des tables des matières (`SearchQuery.demoteTableOfContents`).
    ///
    /// Cinquante, c'est la tranche que `fouine search` rend par défaut et cinq
    /// écrans de l'application. Au-delà, le malus déplacerait des pages que
    /// personne ne regarde, en payant une lecture de texte par page : mesuré
    /// le 11/09/2026 sur une copie de la base de production, lire le corps de
    /// 50 pages par leur rowid coûte **0,2 ms** à chaud et **13 ms** à la
    /// première lecture (139 000 caractères ; voir `docs/search.md`).
    public static let tocProbeDepth = 50

    /// Seuil au-delà duquel les comptages de pages sont bornés (C2-09b) :
    /// au lieu de balayer l'index FTS pour un count(DISTINCT) coûteux, la
    /// recherche retourne N et active `totalsApproximate`.
    ///
    /// CONSTANTE depuis le lot J1. C'était une `static var` que les tests
    /// remplaçaient le temps d'un cas : un état global partagé par tout le
    /// processus, donc par tous les tests que `swift test --parallel` fait
    /// tourner dans le même. Le seuil se règle désormais PAR REQUÊTE
    /// (`SearchQuery.approximateThreshold`), qui vaut cette valeur par défaut.
    public static let approximateCountThreshold = 50_000

    /// Rowid de page_fts pour une page donnée. Toute insertion fixe ce rowid ;
    /// toute suppression se fait par ce rowid ou par la plage ci-dessous,
    /// JAMAIS par doc_id (mesuré : SCAN complet, 143 ms contre 3 ms — §4.1).
    ///
    /// `precondition` et non `assert` : hors de la plage, la valeur rendue
    /// DÉSIGNE UN AUTRE DOCUMENT. Corrompre la base en silence en production est
    /// pire que s'arrêter, et les deux barrières en amont rendent ce cas
    /// inatteignable par une entrée ordinaire.
    public static func ftsRowID(docID: Int64, page: Int) -> Int64 {
        precondition(page >= 0 && page <= maxPage,
                     "page \(page) outside the structured rowid range (0…\(maxPage)): "
                     + "the rowid would belong to document \(docID + 1)")
        return docID * pagesPerDocLimit + Int64(page)
    }

    /// Plage de rowid couvrant toutes les pages d'un document.
    public static func ftsRowIDRange(docID: Int64) -> ClosedRange<Int64> {
        (docID * pagesPerDocLimit)...(docID * pagesPerDocLimit + pagesPerDocLimit - 1)
    }

    // MARK: - Fenêtrage sémantique (schéma v5, constat C2-05)

    /// Créneaux de fenêtre réservés dans le rowid d'un vecteur.
    ///
    /// HUIT, et non trois : le facteur est gelé dans les rowids déjà écrits, et
    /// une puissance de deux laisse `vecWindowMax` évoluer (3 → 4, 5…) sans
    /// jamais réécrire `page_vec`. Le rowid maximal reste très en deçà d'Int64 :
    /// doc_id 1 329 × 100 000 × 8 ≈ 1,06 × 10⁹.
    public static let vecChunksPerPage: Int64 = 8

    /// Largeur d'une fenêtre, en caractères. 1 400 ≈ 256 jetons de français,
    /// c'est-à-dire la longueur de séquence du modèle (`meta.json`, `seq`) :
    /// au-delà, le modèle tronque de toute façon.
    public static let vecWindowChars = 1_400

    /// Pas entre deux fenêtres : 1 300, donc 100 caractères de recouvrement —
    /// un peu plus d'un mot moyen, de quoi qu'aucune phrase ne soit coupée dans
    /// les deux fenêtres à la fois sans être entière dans l'une.
    public static let vecWindowStride = 1_300

    /// Nombre maximal de fenêtres par page. 3 couvre 4 000 caractères, soit
    /// 97,4 % du texte du corpus (C2-05) ; au-delà, 4,9 % des pages seulement
    /// gagneraient quelque chose et le coût d'inférence croît linéairement.
    ///
    /// Le DERNIER créneau (`vecWindowMax - 1`) est la SENTINELLE DE COMPLÉTUDE :
    /// la pompe l'écrit toujours, avec le vrai vecteur si la fenêtre existe, et
    /// sinon avec un blob VIDE que `allVectors` ignore (dimension inattendue).
    /// C'est ce qui rend la sélection de lot une anti-jointure d'un seul créneau
    /// — le point que la conception C2 avait faux, et qui l'aurait empêchée de
    /// produire jamais les fenêtres 1 et 2 (contre-expertise D2, § 6, C2-05).
    public static let vecWindowMax = 3

    /// Longueur utile minimale d'une fenêtre de queue : sous 100 caractères
    /// au-delà du recouvrement, la fenêtre n'est pas créée du tout.
    public static let vecWindowMinTail = 100

    /// Rowid de `page_vec` pour une fenêtre d'une page.
    public static func vecRowID(pageRowID: Int64, chunk: Int) -> Int64 {
        precondition(chunk >= 0 && chunk < Int(vecChunksPerPage),
                     "window \(chunk) outside the vector rowid range "
                     + "(0…\(vecChunksPerPage - 1))")
        return pageRowID * vecChunksPerPage + Int64(chunk)
    }

    /// Page à laquelle appartient un rowid de `page_vec`.
    public static func pageRowID(vecRowID: Int64) -> Int64 {
        vecRowID / vecChunksPerPage
    }

    /// Plage de rowid couvrant toutes les fenêtres d'une page. L'invalidation
    /// d'un vecteur se fait TOUJOURS par cette plage : le texte d'une page
    /// change en bloc, ses fenêtres aussi.
    public static func vecRowIDRange(pageRowID: Int64) -> ClosedRange<Int64> {
        (pageRowID * vecChunksPerPage)...(pageRowID * vecChunksPerPage
                                          + vecChunksPerPage - 1)
    }

    /// Plage de rowid couvrant toutes les fenêtres de toutes les pages d'un
    /// document — la transposition de `ftsRowIDRange` au facteur de fenêtre.
    /// JAMAIS de suppression par doc_id (§4.1 : SCAN complet, 143 ms contre 3).
    public static func vecRowIDRange(docID: Int64) -> ClosedRange<Int64> {
        let pages = ftsRowIDRange(docID: docID)
        let lo = pages.lowerBound * vecChunksPerPage
        let hi = pages.upperBound * vecChunksPerPage + vecChunksPerPage - 1
        return lo...hi
    }

    /// Nombre de fenêtres d'une page de `length` caractères.
    ///
    /// Toujours au moins une (une page vide reçoit un vecteur nul, comme
    /// avant) ; une fenêtre k ≥ 1 n'existe que si la page porte au moins
    /// `vecWindowMinTail` caractères au-delà du recouvrement. Table de
    /// référence : 0-1 400 → 1 ; 1 401-2 700 → 2 ; 2 701 et plus → 3.
    public static func vecWindowCount(forLength length: Int) -> Int {
        var count = 1
        while count < vecWindowMax,
              length > count * vecWindowStride + vecWindowMinTail {
            count += 1
        }
        return count
    }

    /// Script DDL complet, idempotent (CREATE IF NOT EXISTS partout).
    public static let ddl = """
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
      ignore_rules TEXT,                    -- JSON ["Santé/","*.md"] ou NULL (lot IG2) ;
                                            -- AJOUTÉE par la première écriture sur une v9 d'avant
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
      -- IDENTIFIANT DE FICHIER (schéma v6, constat A3-02). st_ino du volume,
      -- 0 quand il est inconnu ou que le système de fichiers ne le garantit pas
      -- (FAT, SMB) : le rapprochement d'un déplacement N'EST TENTÉ QU'AU-DESSUS
      -- DE ZÉRO. C'est ce qui distingue « le même fichier, ailleurs » — on
      -- déplace la ligne — de « un autre fichier » — on ré-extrait.
      inode      INTEGER NOT NULL DEFAULT 0,
      -- DATE DU DOCUMENT (schéma v9, constat PR-07) : secondes epoch du JOUR
      -- civil inscrit dans les métadonnées du fichier (PDF CreationDate, EPUB
      -- dc:date, OOXML dcterms:created, EXIF DateTimeOriginal, en-tête Date:
      -- d'un courriel), ramené à MIDI UTC par `DocumentDate`. NULL — le cas le
      -- plus fréquent — signifie « le document ne porte pas de date » : elle
      -- est lue à l'extraction, et les formats qui n'en gardent aucune (`.txt`,
      -- `.md`, `.djvu`…) n'en auront jamais.
      -- Rien à voir avec `mtime`, qui date le FICHIER.
      doc_date   REAL,
      UNIQUE(vol_uuid, rel_path)
    );
    CREATE INDEX IF NOT EXISTS idx_docs_state  ON docs(state, ocr_state);
    CREATE INDEX IF NOT EXISTS idx_docs_folder ON docs(top_folder, ext);
    -- Le couple qui identifie un fichier : un inode n'est unique QUE sur son
    -- volume. Index et non contrainte : deux liens durs partagent un inode.
    CREATE INDEX IF NOT EXISTS idx_docs_inode  ON docs(vol_uuid, inode);
    -- Facette « Daté de » et rattrapage (`doc_date IS NULL`) : les deux
    -- parcourent cette colonne seule, jamais la table.
    CREATE INDEX IF NOT EXISTS idx_docs_doc_date ON docs(doc_date);

    -- ATTENTION : le nom "page_fts" est imposé. Ne PAS nommer cette table "pages" :
    -- une table FTS nommée "pages" à côté d'une colonne nommée "pages" rend le MATCH
    -- ambigu en JOIN (reproduit).
    --
    -- PAS de prefix='2 3' : mesuré, +29,6 % d'index et x2,0 sur l'insertion,
    -- pour n'accélérer QUE les préfixes de 2-3 lettres (décision D3).
    -- Contrepartie imposée à l'analyse de requête : refuser les préfixes < 4 car.
    CREATE VIRTUAL TABLE IF NOT EXISTS page_fts USING fts5(
      body,
      doc_id UNINDEXED,
      page   UNINDEXED,
      tokenize = '\(pageTokenizer)'
    );

    \(docsFTSDDL)

    CREATE TABLE IF NOT EXISTS page_src(
      doc_id    INTEGER NOT NULL,
      page      INTEGER NOT NULL,
      src       INTEGER NOT NULL,   -- PageSource : 0 natif, 2 ocr_accurate, 3 transcription
      nchars    INTEGER NOT NULL,
      engine    INTEGER NOT NULL DEFAULT 0,  -- OCREngineID : 0 aucun/natif, 1 Vision, 2 externe
      engine_rev TEXT,                       -- ex. "vision-rev3", "paddleocr-2.9"
      conf      REAL,                        -- confiance moyenne des lignes retenues, 0..1
      PRIMARY KEY(doc_id, page)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS idx_page_src_conf ON page_src(src, conf);
    -- L'index ci-dessus rend « re-OCRiser les pages douteuses » interrogeable en
    -- une requête (annexe B) : SELECT ... FROM page_src WHERE src != 0 AND conf < 0.5.

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
    -- ROWID STRUCTURÉ, et surtout PAS `WITHOUT ROWID` (audit A4 du 01/09/2026).
    -- Une table `WITHOUT ROWID` est un B-tree d'INDEX : son seuil de stockage
    -- local vaut ((4096-12)*64/255)-23 = 1 002 o, contre 4096-35 = 4 061 o pour
    -- une table à rowid. Avec un blob moyen de 2 458 o (mesuré), CHAQUE ligne
    -- débordait donc sur une page de 4 Kio dont elle n'occupait qu'un tiers :
    -- 9 409 pages de débordement, 38,3 % d'espace perdu, ~80 MiB à 46 035 pages.
    -- Le rowid est celui de page_fts (Schema.ftsRowID) : la lecture par
    -- (doc_id, page) devient un accès direct par clé primaire entière, plus
    -- rapide que l'ancienne sonde d'index, et il n'y a plus aucun index
    -- secondaire à tenir.
    CREATE TABLE IF NOT EXISTS ocr_layout(
      rowid INTEGER PRIMARY KEY,            -- doc_id * 100000 + page
      blob  BLOB    NOT NULL
    );

    -- Vocabulaire trigramme, pour l'expansion floue (§5.5.2).
    -- N'indexer QUE le vocabulaire (fts5vocab), JAMAIS le corpus.
    -- NE PAS mettre detail='none' NI detail='column' : un MATCH trigramme est une
    -- requête de PHRASE sur trigrammes et échoue en
    -- « fts5: phrase queries are not supported (detail!=full) » (mesuré, §4.1).
    -- 'trigram remove_diacritics 1' n'existe qu'à partir de SQLite 3.45 et ÉCHOUE
    -- ici — sans conséquence : les termes arrivent déjà désaccentués.
    CREATE VIRTUAL TABLE IF NOT EXISTS vocab_tri USING fts5(
      term,
      tokenize = 'trigram'
    );

    -- Lecture du vocabulaire de l'index, pour alimenter vocab_tri et customWords.
    CREATE VIRTUAL TABLE IF NOT EXISTS vocab USING fts5vocab(page_fts, 'row');

    -- Termes déjà versés dans vocab_tri : le NOT IN de l'alimentation s'appuie sur
    -- ce B-tree, pas sur un balayage de la table trigramme (§4.1).
    CREATE TABLE IF NOT EXISTS vocab_seen(
      term TEXT PRIMARY KEY
    ) WITHOUT ROWID;

    -- Vecteurs sémantiques par FENÊTRE de page (recherche hybride, §12 ;
    -- schéma v5, constat C2-05). `vec` est le vecteur UNITAIRE quantifié int8
    -- (round(v*127)) : 384 o par fenêtre avec e5-small, sous le seuil de
    -- débordement — le produit scalaire int8 approxime le cosinus à 1/127 près.
    -- Produit par `fouine embed`, invalidé PAR PLAGE à chaque réécriture du
    -- texte de la page (replacePages, completeOCR, purgeDoc).
    --
    -- Le rowid prolonge celui de page_fts d'un chiffre de fenêtre :
    -- vrowid = (doc_id * 100000 + page) * 8 + chunk, chunk ∈ [0, 7]. La
    -- fenêtre k couvre les caractères [k*1300, k*1300+1400) du texte de la
    -- page ; la fenêtre 0 est exactement le `prefix(1400)` du schéma v3.
    -- Le dernier créneau (chunk = win_max - 1) existe TOUJOURS pour une page
    -- traitée : vrai vecteur si la fenêtre existe, blob VIDE sinon. C'est la
    -- sentinelle de complétude sur laquelle la pompe fait son anti-jointure —
    -- et `allVectors` l'ignore, comme tout blob de dimension inattendue.
    -- Aucun index secondaire (amendement A4) : le rowid seul.
    CREATE TABLE IF NOT EXISTS page_vec(
      rowid INTEGER PRIMARY KEY,   -- (doc_id * 100000 + page) * 8 + fenêtre
      vec   BLOB    NOT NULL
    );

    -- Identité du modèle producteur des vecteurs (model_id, dim, revision…)
    -- et géométrie du fenêtrage (win_chars, win_stride, win_max — posées à la
    -- création : un lecteur SQL doit pouvoir retrouver ce que couvre un rowid
    -- sans lire le code Swift).
    -- Changer de modèle invalide TOUS les vecteurs : deux espaces d'embedding
    -- ne se comparent pas. `EmbedRun` purge page_vec si l'identité change.
    CREATE TABLE IF NOT EXISTS vec_meta(
      k TEXT PRIMARY KEY,
      v TEXT NOT NULL
    ) WITHOUT ROWID;

    \(settingsDDL)
    """

    // MARK: - Nom du document (schéma v8, D-R3)

    /// `docs_fts` : le nom du document et celui de son dossier, indexés à part.
    ///
    /// POURQUOI UNE TABLE À PART, et surtout pas une colonne `name` dans
    /// `page_fts` (mesuré le 01/09/2026) : le nom serait recopié sur les 378 000
    /// pages de l'index — ×285 de duplication —, il faudrait réindexer 1,4 Go,
    /// et surtout il polluerait l'IDF de `bm25` : un mot du nom deviendrait
    /// aussi fréquent que le nombre de pages du document, donc presque sans
    /// poids. Ici, une ligne par DOCUMENT — quelques milliers — que la sonde
    /// de recherche lit en microsecondes pour en tirer un ensemble de `doc_id`.
    ///
    /// `rowid = docs.id` : c'est la seule clé, il n'y a aucun index secondaire
    /// à tenir et la jointure avec les pages est une comparaison d'entiers.
    /// FTS5 n'ayant pas d'`UPSERT`, la tenue à jour est un `DELETE` suivi d'un
    /// `INSERT`, dans la MÊME transaction que l'écriture de `docs`.
    ///
    /// Le tokenizer est celui de `page_fts` : « Thermodynamique » cherché sans
    /// accent doit trouver « Thermodynamique.pdf » comme il trouve le mot dans
    /// une page.
    public static let docsFTSDDL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts USING fts5(
      name,
      tokenize = '\(pageTokenizer)'
    );
    """

    // MARK: - Réglages et état de l'agent (schéma v4, audit U2 / F7)

    /// `settings` et `agent_status` : les deux tables du palier 2.3/2.4.
    ///
    /// POURQUOI EN BASE, et pas dans `UserDefaults`. Les réglages doivent être
    /// lus par les TROIS exécutables (§10) — l'app, la CLI et un agent launchd
    /// qui n'a ni fenêtre ni domaine de préférences propre. `UserDefaults` est
    /// écrit par l'app dans `io.github.basedpolymer.fouine`, que l'agent ne partage pas ;
    /// la base, elle, est déjà le seul objet que les trois ouvrent. Jusqu'ici
    /// les réglages de l'agent n'existaient que sous forme de variables
    /// d'environnement dans le plist du LaunchAgent — « que personne ne peut
    /// poser » (audit U2).
    ///
    /// FORME DES DEUX TABLES. Clé/valeur textuelle, une ligne par réglage. La
    /// valeur est TOUJOURS du texte, même pour un entier ou un booléen : c'est
    /// `Settings` qui analyse et valide, en un seul endroit, et un
    /// `sqlite3 "SELECT * FROM settings"` reste lisible par un humain — ce qui
    /// est tout l'intérêt d'un réglage qu'on ne pouvait plus poser autrement.
    ///
    /// `agent_status` : UNE LIGNE PAR CHAMP, et non une seule ligne JSON.
    /// Les deux formes sont atomiques (l'écriture tient dans une transaction,
    /// la lecture aussi) ; ce qui les départage est le diagnostic. Un
    /// `sqlite3 "SELECT * FROM agent_status"` doit répondre « phase=ocr,
    /// done=1204, total=34000 » sans que personne n'ait à décoder du JSON à
    /// l'œil, et c'est exactement la situation où l'on regarde cette table :
    /// l'agent ne répond pas, on cherche pourquoi. Le surcoût est de sept
    /// `INSERT … ON CONFLICT` au lieu d'un, dans la MÊME transaction — un seul
    /// fsync, quelques microsecondes.
    ///
    /// Pas de `WITHOUT ROWID` ici, contrairement à `vec_meta` : ces tables font
    /// une dizaine de lignes de quelques octets, le gain de stockage serait nul.
    public static let settingsDDL = """
    CREATE TABLE IF NOT EXISTS settings(
      key        TEXT PRIMARY KEY,
      value      TEXT NOT NULL,
      updated_at TEXT NOT NULL      -- ISO-8601, pour dater un réglage douteux
    );

    CREATE TABLE IF NOT EXISTS agent_status(
      key   TEXT PRIMARY KEY,       -- phase, detail, done, total, started_at,
      value TEXT NOT NULL           -- updated_at, pid
    );
    """

    /// Alimentation incrémentale de vocab_tri, idempotente, à exécuter dans la
    /// même transaction que l'écriture d'index (§4.1, §5.5.2).
    ///
    /// BALAYAGE GLOBAL : ~18-25 s sur 1,5 M de termes (mesuré, audit B2). Réservé
    /// aux fins de passe d'indexation (`fouine index`, l'app, l'agent) ; la pompe
    /// OCR, elle, passe par la récolte ciblée ci-dessous (audit A2).
    public static let vocabTriRefill = """
    INSERT INTO vocab_tri(term)
      SELECT term FROM vocab
      WHERE term NOT IN (SELECT term FROM vocab_seen);
    INSERT OR IGNORE INTO vocab_seen(term)
      SELECT term FROM vocab;
    """

    // MARK: - Récolte ciblée du vocabulaire OCR (audit A2)

    /// Table d'appoint TEMPORAIRE dans laquelle le texte fraîchement reconnu est
    /// versé pour être tokenisé PAR SQLITE, avec le tokenizer de `page_fts`.
    ///
    /// Pourquoi passer par une table FTS5 plutôt que découper le texte en Swift :
    /// `unicode61 remove_diacritics 2` a ses propres règles de séparation et de
    /// repli d'accents ; les réécrire à la main ferait entrer dans `vocab_tri`
    /// des termes que `fts5vocab(page_fts)` n'aurait jamais produits — donc une
    /// expansion floue qui propose des voisins introuvables dans l'index.
    /// Ici, c'est le MÊME tokenizer qui travaille, par construction.
    ///
    /// Temporaire : la table ne vit que dans la connexion d'écriture du pool et
    /// disparaît avec le processus. Rien n'est ajouté au fichier de base.
    public static let ocrHarvestDDL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS temp.ocr_harvest USING fts5(
      body,
      tokenize = '\(pageTokenizer)'
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS temp.ocr_harvest_vocab
      USING fts5vocab(ocr_harvest, 'row');
    DELETE FROM temp.ocr_harvest;
    """

    /// Termes récoltés absents de `vocab_seen` -> `vocab_tri`. Une sonde de clé
    /// primaire par terme (`SEARCH vocab_seen USING PRIMARY KEY`, vérifié à
    /// l'`EXPLAIN QUERY PLAN`) sur quelques milliers de termes : des
    /// millisecondes, contre 10 s pour le `NOT IN` global du balayage complet.
    public static let ocrHarvestRefillTri = """
    INSERT INTO vocab_tri(term)
      SELECT v.term FROM temp.ocr_harvest_vocab v
      WHERE NOT EXISTS (SELECT 1 FROM vocab_seen s WHERE s.term = v.term)
    """

    /// Second temps, une fois `vocab_tri` à jour : mémoriser les termes vus.
    public static let ocrHarvestRefillSeen = """
    INSERT OR IGNORE INTO vocab_seen(term)
      SELECT term FROM temp.ocr_harvest_vocab
    """

    // MARK: - Amorçage de la création (lot J1)

    /// Géométrie du fenêtrage, posée dans `vec_meta` à la CRÉATION de la base.
    ///
    /// Ces trois clés ne servent à aucun code : elles servent à l'humain qui
    /// ouvre la base au `sqlite3` et veut savoir ce que couvre un rowid de
    /// `page_vec` sans lire le Swift. `INSERT OR REPLACE` parce que la
    /// création est le seul écrivain de ces clés.
    public static let vecWindowMetaSQL = """
    INSERT OR REPLACE INTO vec_meta(k, v) VALUES
      ('win_chars',  '\(vecWindowChars)'),
      ('win_stride', '\(vecWindowStride)'),
      ('win_max',    '\(vecWindowMax)');
    """

    /// FORME IMPOSÉE d'une requête de recherche (§4.1) : sous-requête sur
    /// page_fts, puis jointure. Toute autre forme déclenche
    /// « ambiguous column name ». Documentation ; le Store construit ses
    /// variantes (filtres, flou §5.5.3) sur ce squelette.
    public static let searchQueryForm = """
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
    """
}
