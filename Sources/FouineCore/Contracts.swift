// Contracts.swift — INTERFACES GELÉES (SPEC §4.2), commit « freeze: contracts ».
// Fichier en LECTURE SEULE pour tous les sous-agents. Un agent qui a besoin d'une
// modification d'interface s'arrête et remonte à l'orchestrateur (SPEC §0).
//
// Décisions de vague 0 consignées ici :
//   · FacetKey.year est CONSERVÉ et se dérive de docs.mtime (année civile
//     locale) ; sa clé PUBLIÉE est `modified_year` depuis le lot MC3.
//   · Le seuil de confiance OCR provisoire est 0,30 (SPEC §6.2) ; A-Recette le calibre.

import Foundation
import CoreGraphics

public enum PageSource: Int, Sendable, Codable, CaseIterable {
    case native = 0
    // La valeur 1 (ancienne reconnaissance « rapide ») n'a jamais été écrite
    // depuis la décision D1 (§2.7), et aucune base distribuée n'en porte :
    // elle ne se réattribue pas pour autant (lot RC2).
    case ocrAccurate = 2

    /// Parole mise par écrit SUR CETTE MACHINE depuis un fichier audio ou
    /// vidéo (lot INT-F3, §5.3). Troisième provenance, et non un cas d'OCR :
    /// une page transcrite n'a pas d'image, ses erreurs ne sont pas celles
    /// d'une reconnaissance de caractères, et « Pages scannées seulement » ne
    /// doit pas la rendre.
    ///
    /// La valeur 3 s'écrit telle quelle dans `page_src.src`, colonne `INTEGER`
    /// sans contrainte : la provenance d'une page est une donnée, pas une
    /// forme de table.
    case transcript = 3

    /// Les provenances SCANNÉES, celles que « Pages scannées seulement »
    /// désigne. Un ensemble plutôt qu'un cas : le filtre de provenance
    /// raisonne par partition de l'énumération.
    public static let scanned: Set<PageSource> = [.ocrAccurate]
    /// Le texte que le document portait déjà, par opposition au scan.
    public static let typed: Set<PageSource> = [.native]
    /// La parole mise par écrit. Les trois ensembles PARTITIONNENT
    /// l'énumération : c'est ce qui permet au filtre de provenance de rester
    /// un choix exclusif dans la CLI comme dans le MCP.
    public static let transcribed: Set<PageSource> = [.transcript]
}

/// CE QU'UN NUMÉRO DE PAGE DÉSIGNE VRAIMENT, par famille de format (lot MC2,
/// constat PM-19).
///
/// LE FAIT MESURÉ. `OOXMLExtractor` numérote les pages de TEXTE d'abord, puis
/// AJOUTE une page par image incorporée (`pageCount: slots.count + media.count`).
/// Un cours mesuré le 13/09/2026 : 53 diapositives et 202 pages — « page 170 »
/// y désigne une figure OCRisée que personne ne retrouvera en feuilletant ses
/// diapositives, et une citation qui l'annonce comme une page est FAUSSE.
///
/// LA FRONTIÈRE EST DÉJÀ EN BASE, il n'y a rien à migrer : les pages de texte
/// sont celles que `page_src` marque `src = 0`, et leur maximum donne le
/// nombre de diapositives (`GRDBStore.textPageCounts(forDocIDs:)`).
public enum PageLayout {

    /// Les extensions dont l'extracteur range les pages de TEXTE avant les
    /// pages d'IMAGE incorporée — les six conteneurs d'`OOXMLExtractor`. Un
    /// PDF, un DjVu ou un iWork (rendu par sa prévisualisation) n'en sont pas :
    /// leurs pages sont les pages du document.
    public static let textThenMedia: Set<String> =
        ["docx", "odt", "ods", "odp", "xlsx", "pptx"]

    /// Celles dont une page de texte est une DIAPOSITIVE. `xlsx` et `ods` ont
    /// des feuilles, `docx` et `odt` un flux : dire « diapositive 3 » d'un
    /// tableur n'apprendrait rien à personne.
    public static let slideshows: Set<String> = ["odp", "pptx"]

    /// Ce que la page `page` d'un document d'extension `ext` désigne.
    ///
    /// - Parameter textPages: le nombre de pages de texte du document
    ///   (`max(page)` de `page_src` à `src = 0`), ou `nil` quand on ne l'a pas
    ///   lu — les deux valeurs sont alors nulles, comme pour un PDF.
    /// - Returns: le numéro de diapositive (diaporamas seulement) et le rang de
    ///   l'image incorporée, l'un et l'autre `nil` quand la question ne se pose
    ///   pas.
    public static func page(_ page: Int, ext: String, textPages: Int?)
        -> (slide: Int?, embeddedImage: Int?) {
        let ext = ext.lowercased()
        guard textThenMedia.contains(ext), let textPages, page >= 1 else {
            return (nil, nil)
        }
        if page <= textPages {
            return (slideshows.contains(ext) ? page : nil, nil)
        }
        return (nil, page - textPages)
    }
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
    public init(page: Int, text: String, source: PageSource) {
        self.page = page
        self.text = text
        self.source = source
    }
}

public struct ExtractionResult: Sendable {
    public let pages: [PageText]      // uniquement les pages porteuses de texte
    public let pageCount: Int         // total du document (≥ pages.count)
    public let ocrCandidates: [Int]   // n° des pages sous le seuil, à mettre en file
    public let meta: [String: String] // title, author, lang… si disponibles
    public init(pages: [PageText], pageCount: Int,
                ocrCandidates: [Int], meta: [String: String]) {
        self.pages = pages
        self.pageCount = pageCount
        self.ocrCandidates = ocrCandidates
        self.meta = meta
    }
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
    /// Plafond du NOMBRE de pages d'un format re-paginé (constat MO-01). Le
    /// plafond de texte (50 Mio) laissait un `.docx` de 80 Kio — 80 Mio de « A »
    /// compressés — produire 13 108 pages de bruit, soit ~26 000 fenêtres
    /// vectorielles identiques. Les formats NATIVEMENT paginés (pdf, djvu, cbz,
    /// images, médias) ont déjà le leur, `Schema.maxPage` ; c'est ici le leur
    /// pour les autres. 5 000 pages valent 20 Mio de texte : au-delà, ce n'est
    /// plus un document, et les pages 1…5 000 restent indexées.
    public var maxSplitPages: Int = 5_000
    public var ocrThresholdChars: Int = 100     // §6.1
    /// « Arrêtez-vous » — consultée par les extracteurs qui bouclent (ST1).
    ///
    /// L'annulation ne se voyait qu'ENTRE deux documents : un clic sur
    /// « Stop » attendait la fin des extractions en vol, c'est-à-dire jusqu'à
    /// `extract.jobs` documents, et une vidéo transcrite se compte en minutes.
    /// Un extracteur qui la voit vraie abandonne en levant `.cancelled` ; son
    /// document n'est alors NI extrait NI en échec, il reste à faire.
    ///
    /// Coût quand personne n'annule : un appel de fermeture par page.
    public var shouldStop: @Sendable () -> Bool = { false }
    public init() {}
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
    public init(text: String, x: Double, y: Double, w: Double, h: Double,
                confidence: Double) {
        self.text = text
        self.x = x; self.y = y; self.w = w; self.h = h
        self.confidence = confidence
    }
}

public struct OCRPage: Sendable {
    public let text: String          // lignes retenues uniquement (§6.2, seuil de confiance)
    public let lines: [OCRLine]      // TOUTES les lignes, y compris rejetées, pour ocr_layout
    public let level: OCRLevel
    public let seconds: Double
    public let engine: OCREngineID   // -> page_src.engine
    public let engineRev: String     // -> page_src.engine_rev, ex. "vision-rev3"
    public let meanConfidence: Double // -> page_src.conf, moyenne des lignes retenues
    public init(text: String, lines: [OCRLine], level: OCRLevel, seconds: Double,
                engine: OCREngineID, engineRev: String, meanConfidence: Double) {
        self.text = text
        self.lines = lines
        self.level = level
        self.seconds = seconds
        self.engine = engine
        self.engineRev = engineRev
        self.meanConfidence = meanConfidence
    }
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
    /// Identifiant de fichier du volume (`st_ino`), schéma v6 — constat A3-02.
    /// 0 = inconnu : ligne écrite avant la v6, ou système de fichiers qui ne
    /// garantit pas la stabilité de l'inode (FAT, SMB). Le rapprochement d'un
    /// déplacement n'est TENTÉ qu'au-dessus de zéro.
    public var inode: Int64
    /// Date INSCRITE DANS LE DOCUMENT (schéma v9, constat PR-07), en secondes
    /// epoch, jour civil à midi UTC — voir `DocumentDate`. `nil` = le document
    /// n'en porte pas, ou son format n'en donne pas. À ne pas confondre avec
    /// `mtime`, qui date le fichier.
    public var docDate: Double?
    public init(volUUID: String, relPath: String, ext: String, topFolder: String,
                size: Int64, mtime: Double, nPages: Int = 0,
                state: DocState = .discovered, ocrState: OCRState = .notNeeded,
                lang: String? = nil, err: String? = nil, inode: Int64 = 0,
                docDate: Double? = nil) {
        self.volUUID = volUUID
        self.relPath = relPath
        self.ext = ext
        self.topFolder = topFolder
        self.size = size
        self.mtime = mtime
        self.nPages = nPages
        self.state = state
        self.ocrState = ocrState
        self.lang = lang
        self.err = err
        self.inode = inode
        self.docDate = docDate
    }
}

/// Un document qui CHANGE DE CHEMIN sans changer de contenu (schéma v6, constat
/// A3-02). Le fichier est le même — même volume, même inode, même taille, même
/// mtime —, il a seulement été renommé ou déplacé.
///
/// Tout ce qui dérive du chemin est porté ici, et rien d'autre : le texte, les
/// pages, la couche OCR, la file d'attente et les vecteurs ne sont pas touchés.
/// C'est toute la raison d'être de ce type — un `removeDoc` + `upsertDoc` les
/// détruirait, et c'est ce que Fouine faisait jusqu'au 04/09/2026.
public struct DocRelocation: Sendable {
    public let id: Int64
    public let relPath: String
    /// Étiquette de facette de la racine d'ARRIVÉE : un fichier déplacé d'une
    /// racine à l'autre change de facette.
    public let topFolder: String
    /// L'extension peut changer avec le nom (« notes.txt » -> « notes.md »).
    public let ext: String
    /// L'inode, réinscrit au passage : c'est aussi par ce chemin que les lignes
    /// d'avant la v6 (inode 0) se renseignent, sans rien ré-extraire.
    public let inode: Int64
    public init(id: Int64, relPath: String, topFolder: String, ext: String,
                inode: Int64) {
        self.id = id
        self.relPath = relPath
        self.topFolder = topFolder
        self.ext = ext
        self.inode = inode
    }
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
    /// Seuil de comptage exact pour CETTE requête (C2-09b). Au-delà, les
    /// totaux sont bornés au seuil et `totalsApproximate` passe à vrai.
    ///
    /// PAR REQUÊTE, et non plus par un réglage global que les tests
    /// remplaçaient le temps d'un cas (lot J1) : `Schema.approximateCountThreshold`
    /// est une constante, et c'est ce paramètre qui se règle.
    public var approximateThreshold: Int = Schema.approximateCountThreshold
    /// Bonus de classement du lot M1 (D-R2 phrase et voisinage, D-R3 nom du
    /// document). ARMÉS PAR DÉFAUT : aucun appelant existant ne change, et
    /// `fouine search --no-proximity` les désarme pour comparer deux
    /// classements sur la même base (option de calibration, comme
    /// `--vec-floor`).
    ///
    /// Ils ne changent QUE L'ORDRE : ni les comptages, ni les facettes, ni
    /// `matchedPageCounts` ne les voient.
    public var rankingBoosts: Bool = true
    /// Singulier et pluriel d'un mot nu cherchés ensemble (lot R1,
    /// `Morphology`) : `polymere` apparie aussi « polymères ». ARMÉ PAR DÉFAUT ;
    /// `fouine search --no-morphology` le désarme (calibration). Contrairement
    /// aux bonus, il change ce qui est TROUVÉ : comptages et facettes suivent.
    public var morphology: Bool = true
    /// La page qui porte le mot TEL QU'IL A ÉTÉ TAPÉ passe devant celle qui ne
    /// porte que sa déclinaison (lot P1, `Schema.typedFormBoost`). Sans effet
    /// quand la morphologie est désarmée ou n'a rien ajouté : il n'y a alors
    /// rien à départager. ARMÉ PAR DÉFAUT ; `fouine search --no-typed-form` le
    /// désarme (calibration). Ne change que l'ORDRE, comme les bonus du lot M1
    /// — et il est indépendant de `rankingBoosts` : c'est la morphologie qu'il
    /// corrige, pas la proximité.
    public var typedFormBoost: Bool = true
    /// Un document ne prend pas tout l'écran (lot R1) : au-delà de
    /// `Schema.diversityFullStrengthPages` pages d'un même document, les
    /// suivantes sont rétrogradées (`Schema.diversityDemotion`) pour que les
    /// autres documents apparaissent dans la première tranche. ARMÉ PAR
    /// DÉFAUT ; `fouine search --no-diversity` le désarme. Ne change que
    /// l'ORDRE, comme les bonus.
    public var diversifyDocuments: Bool = true
    /// LE QUORUM DES MOTS (lot RK2, RK-04). Quand la recherche STRICTE — tous
    /// les mots sur la même page — rend moins de `Schema.quorumTrigger` pages,
    /// la requête est rejouée en n'exigeant que la PLUPART des mots de plus de
    /// trois lettres (`QueryParser.quorumFTS`). Les pages strictes gardent la
    /// tête ; les autres suivent.
    ///
    /// ARMÉ PAR DÉFAUT depuis le 11/09/2026 (AUDIT-RK2) : livré désarmé par
    /// RK2 parce qu'il change ce qui est TROUVÉ, il a été jugé sur le pool
    /// `rk2-2026-09-11` (149 candidats lus) — nDCG@10 +0,031 pages / +0,032
    /// documents contre le lexical strict, 6 victoires / 43 égalités / 0
    /// défaite, p = 0,040. Ce qu'il remonte est surtout du « utile » (rappel),
    /// rarement la réponse ; mais il ne fait jamais reculer une page déjà
    /// trouvée. `fouine search --no-quorum` le désarme (calibration) ; il n'y
    /// a pas de réglage d'interface.
    public var quorum: Bool = true
    /// LE MALUS DES SOMMAIRES (lot RK2, RK-07). Les pages qui sont des tables
    /// des matières, des index ou des listes de mots-clés (`TableOfContentsProbe`)
    /// passent DERRIÈRE les autres, parmi les `Schema.tocProbeDepth` premiers
    /// candidats lexicaux. Aucune page n'est retirée : les totaux, les facettes
    /// et les comptes ne bougent pas, seul l'ORDRE change.
    ///
    /// ARMÉ PAR DÉFAUT depuis le 11/09/2026 (AUDIT-RK2) : +0,021 pages /
    /// +0,014 documents, 13 / 33 / 3, p = 0,019 ; +0,101 sur les préfixes
    /// (`polymer*` 0,312 → 0,806). Une vraie perte connue : `chromato*`, où
    /// le glossaire IUPAC (entrées courtes, renvois, numéros de page) passe
    /// pour un sommaire. `fouine search --no-demote-toc` le désarme.
    public var demoteTableOfContents: Bool = true
    /// Filtre de LANGUE du document (lot U2, R-10) : codes ISO 639-1 tels que
    /// `LanguageDetector` les écrit dans `docs.lang` ; vide = toutes.
    ///
    /// `FacetKey.undeterminedLanguage` (« und ») y désigne les documents dont
    /// la langue n'a pas été déterminée (`docs.lang` NULL ou vide). Il fallait
    /// un jeton : la chaîne vide ne se distingue pas d'« aucun filtre » côté
    /// interface, et « und » ne peut pas entrer en collision avec un code
    /// ISO 639-1, qui fait deux lettres.
    public var langs: [String] = []
    /// Date de modification MINIMALE du document, en secondes UNIX ; `nil` =
    /// aucune borne. C'est ce que servent les puces « Cette année » et
    /// « 5 dernières années » de l'application, et `fouine search --since`.
    ///
    /// Sur `docs.mtime`, donc VRAI filtre : contrairement à la facette
    /// « Années », il porte sur tout l'index et non sur la tranche chargée.
    public var modifiedAfter: Double?
    /// Provenance des PAGES retenues (lot P3, PERSP-5) : `nil`, l'ensemble vide
    /// ou les trois valeurs = toutes, et le SQL est alors EXACTEMENT celui
    /// d'avant ce filtre — on ne paie pas ce qu'on ne demande pas.
    ///
    /// C'est le premier filtre qui porte sur la PAGE et non sur le document :
    /// la provenance vit dans `page_src`, une ligne par page. « Pages scannées
    /// seulement » (`PageSource.scanned`) était pour cette raison un filtre
    /// d'AFFICHAGE jusqu'au 05/09/2026 — il cachait des pages déjà chargées
    /// sans que les totaux, les facettes ni « Charger plus » le sachent.
    ///
    /// Une page ABSENTE de `page_src` compte pour du texte natif : c'est déjà
    /// la convention de `pageMeta` et de la facette « Origine du texte ».
    public var sources: Set<PageSource>?
    /// `nom:rapport` (lot QP1) : les documents candidats sont ceux dont le NOM
    /// — fichier et dossier parent, `docs_fts` — répond à TOUS ces termes.
    /// Avec des termes de page, c'est un filtre de document ; SEULS, la
    /// recherche rend les documents eux-mêmes (une ligne par document). Vide =
    /// aucun effet, et le SQL est celui d'avant.
    public var nameTerms: [String] = []
    /// Le nom du fichier compte-t-il ? Faux dès qu'un `texte:` est tapé (lot
    /// QP1) : ni bonus de classement `dn`, ni bandeau des noms — on cherche un
    /// mot dans le corps sans que les fichiers qui le portent dans leur nom
    /// passent devant.
    public var nameBoost: Bool = true
    /// `chemin:Offres` (lot MC1) : le chemin COMPLET du document, répertoires
    /// compris, contient chacune de ces valeurs — casse et accents ignorés
    /// (fonction SQL `fold`). `nom:` ne voit que le nom du fichier et celui de
    /// son dossier PARENT (`docs_fts`), et `nom:Offres` ne rendait donc que 6
    /// des ~160 documents rangés sous `Stage/Offres/…`. Seul, ce filtre rend
    /// les documents eux-mêmes, comme `nom:` seul.
    public var pathContains: [String] = []
    /// LES QUATRE EXCLUSIONS DE FILTRES (lot MC1). `-dossier:X` et `-ext:X`
    /// sont deux clauses `NOT IN` sur `docs` ; `-nom:X` écarte les documents
    /// dont `docs_fts` répond à X ; `-chemin:X` ceux dont le chemin contient X.
    /// Vides = aucun effet, et le SQL est alors celui d'avant, au caractère
    /// près. Le canal vectoriel de l'hybride les applique aussi.
    public var folderExcludes: [String] = []
    public var extExcludes: [String] = []
    public var nameExcludes: [String] = []
    public var pathExcludes: [String] = []
    /// Les marqueurs qui encadrent les mots trouvés dans un extrait (lot MC2,
    /// constat PM-23). `«` et `»` par défaut : c'est le littéral que
    /// `snippet()` recevait en dur, et l'application les relit tels quels
    /// (`Highlighting.segments`) — à valeur par défaut, le SQL est donc celui
    /// d'avant au caractère près (test dédié).
    ///
    /// POURQUOI LES RENDRE RÉGLABLES. Un modèle qui reçoit
    /// « … «mot» … » ne peut pas distinguer un surlignage d'une citation
    /// française d'un seul mot présente dans le texte source. Le serveur MCP
    /// laisse donc choisir (`marks: brackets | asterisks | none`) ; les deux
    /// autres surfaces ne passent rien et ne changent pas.
    public var snippetMarkers: (open: String, close: String) = ("«", "»")

    /// Vrai quand le filtre de provenance ne retire rien. La garde de tout le
    /// chemin : ni jointure, ni clause, ni tamis vectoriel.
    public var keepsAllSources: Bool {
        guard let sources, !sources.isEmpty else { return true }
        return sources.count >= PageSource.allCases.count
    }

    /// Cette provenance passe-t-elle le filtre ? Sert au canal vectoriel, qui
    /// tamise des rowids au lieu d'écrire une clause SQL.
    public func keeps(_ source: PageSource) -> Bool {
        keepsAllSources || (sources?.contains(source) ?? true)
    }

    /// Cette requête restreint-elle l'ensemble des DOCUMENTS ?
    ///
    /// La garde du périmètre du sens (PM-06) : sans filtre de document, le
    /// périmètre EST l'index, la fusion en connaît déjà les chiffres, et les
    /// deux comptes coûtaient **240 ms** mesurés sur la base de production pour
    /// réapprendre ce que l'on savait (lot CL2).
    ///
    /// LE FILTRE DE PROVENANCE N'Y EST PAS : il porte sur la page (`page_src`),
    /// et ne retire aucun document du périmètre.
    ///
    /// ELLE VIT ICI depuis le lot MN1 : la ligne de commande et le serveur MCP
    /// en portaient chacun une copie (`filtersDocuments`), et onze conditions
    /// recopiées à deux endroits finissent par diverger au premier filtre
    /// ajouté — c'est-à-dire par annoncer deux périmètres différents pour la
    /// même requête.
    public var filtersDocuments: Bool {
        !(folders.isEmpty && exts.isEmpty && langs.isEmpty
          && inDocIDs.isEmpty && nameTerms.isEmpty && pathContains.isEmpty
          && folderExcludes.isEmpty && extExcludes.isEmpty
          && nameExcludes.isEmpty && pathExcludes.isEmpty
          && modifiedAfter == nil)
    }

    /// UN SEUL init (lot J1) : les deux qui existaient ne différaient que par
    /// `approximateThreshold`, présent dans l'un et absent de l'autre — un
    /// doublon de onze affectations qu'une valeur par défaut suffit à éviter.
    public init(terms: [String] = [], fts: String, limit: Int = 50, offset: Int = 0,
                folders: [String] = [], exts: [String] = [], inDocIDs: [Int64] = [],
                groupByDoc: Bool = true, fuzzy: FuzzyMode = .auto,
                fuzzyScope: FuzzyScope = .ocrOnly,
                approximateThreshold: Int = Schema.approximateCountThreshold,
                rankingBoosts: Bool = true,
                morphology: Bool = true, typedFormBoost: Bool = true,
                diversifyDocuments: Bool = true,
                langs: [String] = [], modifiedAfter: Double? = nil,
                sources: Set<PageSource>? = nil) {
        self.langs = langs
        self.modifiedAfter = modifiedAfter
        self.sources = sources
        self.terms = terms
        self.fts = fts
        self.limit = limit
        self.offset = offset
        self.folders = folders
        self.exts = exts
        self.inDocIDs = inDocIDs
        self.groupByDoc = groupByDoc
        self.fuzzy = fuzzy
        self.fuzzyScope = fuzzyScope
        self.approximateThreshold = approximateThreshold
        self.rankingBoosts = rankingBoosts
        self.morphology = morphology
        self.typedFormBoost = typedFormBoost
        self.diversifyDocuments = diversifyDocuments
    }
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
    /// Cette page est une TABLE DES MATIÈRES (ou un index) et le malus du lot
    /// RK2 l'a reculée. Additif, faux partout ailleurs : les surfaces qui
    /// expliquent « pourquoi ce résultat » le disent, les autres l'ignorent.
    public let tableOfContents: Bool
    public init(docID: Int64, path: String, page: Int, score: Double,
                snippet: String, source: PageSource, fuzzyDistance: Int,
                tableOfContents: Bool = false) {
        self.docID = docID
        self.path = path
        self.page = page
        self.score = score
        self.snippet = snippet
        self.source = source
        self.fuzzyDistance = fuzzyDistance
        self.tableOfContents = tableOfContents
    }
}

public struct SearchResults: Sendable {
    public let hits: [Hit]
    public let totalPages: Int, totalDocs: Int, elapsedMS: Double
    /// Vrai si les totaux ont été approchés au-delà du seuil (C2-09b).
    public let totalsApproximate: Bool
    /// La recherche exacte n'a RIEN rendu et Fouine a rejoué la requête en
    /// tolérant les fautes, sur tout l'index (lot MP1, C2-08). Ce qui est
    /// affiché vient donc de ce second passage, et chaque hit porte sa distance.
    /// Les trois surfaces l'ANNONCENT : une recherche qui change de règle sans
    /// le dire est pire qu'une recherche qui ne trouve rien.
    public let fuzzyFallback: Bool
    /// Documents dont le NOM DE FICHIER répond à la requête (lot MP1, PR-02),
    /// au plus cinq, seulement sur la première tranche.
    ///
    /// UN CANAL À PART, pas un classement : ils ne modifient ni l'ordre des
    /// pages, ni `totalPages`, ni `totalDocs`. Un nom ne désigne AUCUNE page —
    /// le résultat de Fouine est une page — d'où une liste de documents, que
    /// chaque surface présente au-dessus des résultats.
    public let nameMatches: [DocumentListing]
    /// AU MOINS UN RÉSULTAT RENDU porte une orthographe PROCHE du mot tapé, et
    /// non le mot lui-même (constat PM-13).
    ///
    /// `fuzzyFallback` ne dit que le REPLI — la passe rejouée quand l'exact n'a
    /// rien rendu. Or en mode `auto`, l'expansion floue a lieu dans la passe
    /// ORDINAIRE dès que l'exact rend moins de vingt pages : mesuré le
    /// 13/09/2026, `Kenvue` rendait onze pages toutes floues (« cevue »,
    /// « kengee », « kene ») avec `fuzzy_fallback: false` et aucune note. Il
    /// fallait lire le `why` de chaque résultat pour le découvrir.
    ///
    /// CALCULÉ, et non porté : la valeur est déjà dans chaque hit, et un champ
    /// stocké se serait perdu à la première recomposition de résultats.
    public var fuzzyExpanded: Bool { hits.contains { $0.fuzzyDistance > 0 } }

    /// La recherche STRICTE rendait moins de dix pages et le QUORUM a pris le
    /// relais (lot RK2, RK-04) : ce qui est affiché après les pages strictes ne
    /// porte pas tous les mots demandés. Les trois surfaces l'ANNONCENT, pour
    /// la même raison que `fuzzyFallback` : une recherche qui change de règle
    /// sans le dire est pire qu'une recherche qui ne trouve rien.
    public let quorum: Bool
    public init(hits: [Hit], totalPages: Int, totalDocs: Int, elapsedMS: Double,
                totalsApproximate: Bool = false, fuzzyFallback: Bool = false,
                nameMatches: [DocumentListing] = [], quorum: Bool = false) {
        self.hits = hits
        self.totalPages = totalPages
        self.totalDocs = totalDocs
        self.elapsedMS = elapsedMS
        self.totalsApproximate = totalsApproximate
        self.fuzzyFallback = fuzzyFallback
        self.nameMatches = nameMatches
        self.quorum = quorum
    }

    /// Le même résultat, plus les documents trouvés par leur NOM. Les deux
    /// canaux sont lus séparément (voir `GRDBStore.documentsMatchingName`) et
    /// se rejoignent ici, jamais dans le classement des pages.
    func withNameMatches(_ names: [DocumentListing]) -> SearchResults {
        names.isEmpty ? self
            : SearchResults(hits: hits, totalPages: totalPages,
                            totalDocs: totalDocs, elapsedMS: elapsedMS,
                            totalsApproximate: totalsApproximate,
                            fuzzyFallback: fuzzyFallback, nameMatches: names,
                            quorum: quorum)
    }
}

/// `year` se dérive de docs.mtime (année civile locale) — décision de vague 0.
/// `lang` se lit dans `docs.lang`, rempli par `LanguageDetector` (lot U2, R-10).
/// Les dimensions de facettage. `year` porte sur `docs.mtime` — la date du
/// FICHIER —, `docYear` sur `docs.doc_date`, la date que le DOCUMENT porte
/// lui-même (schéma v9, constat PR-07) : deux questions différentes, et
/// l'audit a montré qu'on posait la seconde en lisant la première.
public enum FacetKey: String, Sendable {
    case folder, ext, source, lang
    /// La date du FICHIER, et le nom le dit désormais (lot MC3, constat PM-25).
    /// La facette s'appelait `year` : sur une requête témoin, 193 pages sur 409
    /// tombaient en 2026 parce que les fichiers avaient été copiés sur le Mac
    /// cette année-là — et rien dans le nom ne l'annonçait. Le CAS Swift reste
    /// `year` pour que le code appelant ne bouge pas ; seule la clé publiée
    /// change, et `--facet year` reste accepté en entrée comme alias.
    case year = "modified_year"
    /// `doc_year` et non `docYear` : c'est la valeur de `--facet` en ligne de
    /// commande et la clé du JSON, qui s'écrivent en serpent comme le reste du
    /// contrat.
    case docYear = "doc_year"
}

extension FacetKey {
    /// Valeur de la facette « Langue » pour un document dont la langue n'a pas
    /// été déterminée — `docs.lang` NULL ou vide.
    ///
    /// Un JETON et non la chaîne vide : la facette la remonterait alors sous une
    /// clé que l'interface filtre (elle écarte les valeurs vides de toutes les
    /// facettes), et `--lang ''` n'aurait aucun sens en ligne de commande.
    /// « und » est le code ISO 639-2 de l'indéterminé et ne peut pas heurter un
    /// code ISO 639-1, qui fait deux lettres.
    public static let undeterminedLanguage = "und"
}

/// Ligne de docs telle que lue en base (ajout de vague 0 : le crawl delta et les
/// suppressions du §5.2 exigent de lister les documents connus d'une racine).
public struct DocRow: Sendable {
    public let id: Int64
    public let record: DocRecord
    public init(id: Int64, record: DocRecord) {
        self.id = id
        self.record = record
    }
}

public protocol IndexStore: AnyObject, Sendable {
    func open(at url: URL) throws
    func addRoot(path: URL, label: String?) throws -> Int64   // résout volume + rel_path
    func roots() throws -> [RootRecord]
    func removeRoot(id: Int64) throws                         // purge docs + pages
    func volumes() throws -> [(uuid: String, label: String, lastSeen: Double?)]
    /// Documents connus sous une racine (crawl delta et suppressions, §5.2).
    func docs(underRoot rootID: Int64) throws -> [DocRow]
    /// Purge complète d'un document : docs, page_fts (PAR PLAGE DE ROWID),
    /// page_src, ocr_layout, ocr_queue (§5.2).
    func removeDoc(id: Int64) throws
    /// Persistance du curseur FSEvents (volumes.fsevent_id, §5.2).
    func fseventID(volUUID: String) throws -> UInt64
    func setFSEventID(volUUID: String, _ id: UInt64) throws
    func upsertDoc(_ d: DocRecord) throws -> Int64
    /// Renommages et déplacements détectés au crawl (§5.2, schéma v6) : seul le
    /// chemin change, EN UNE TRANSACTION pour tout le lot — un dossier de mille
    /// documents se déplace d'un coup ou pas du tout.
    func relocateDocs(_ moves: [DocRelocation]) throws
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
    public init(id: Int64, volUUID: String, relPath: String, label: String,
                enabled: Bool) {
        self.id = id
        self.volUUID = volUUID
        self.relPath = relPath
        self.label = label
        self.enabled = enabled
    }
}

// Points d'entrée figés en vague 0 pour que les deux agents de la vague 1
// puissent se câbler sans se relire (§9.2). Aucune implémentation ici.
public enum CrawlMode: Sendable { case full, delta }

public struct CrawlSummary: Sendable {
    public let seen: Int, added: Int, updated: Int, removed: Int, skipped: Int
    /// Documents RETROUVÉS AILLEURS (schéma v6, constat A3-02) : ni ajoutés ni
    /// retirés, seulement renommés ou déplacés. Compté à part parce que c'est
    /// exactement ce qui, avant le lot K6, apparaissait comme `removed` + `added`
    /// et coûtait la reprise complète de l'OCR et des vecteurs.
    public let moved: Int
    public init(seen: Int, added: Int, updated: Int, removed: Int, skipped: Int,
                moved: Int = 0) {
        self.seen = seen
        self.added = added
        self.updated = updated
        self.removed = removed
        self.skipped = skipped
        self.moved = moved
    }
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

/// Toute erreur remonte en FouineError (SPEC §4.2).
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
    /// L'utilisateur a demandé l'arrêt PENDANT cette extraction (ST1).
    ///
    /// Ni un échec ni un refus : le document n'a pas été lu, il reste
    /// `.discovered` et la passe suivante le reprend. Rien ne s'écrit dans
    /// `docs.err` — c'est la seule erreur qui ne marque pas son document.
    case cancelled
}
