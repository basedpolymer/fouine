// GRDBStore+Language.swift — rattrapage de `docs.lang` (lot U3, R-10).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// POURQUOI CE FICHIER EXISTE. `docs.lang` n'est écrite qu'à l'extraction
// (`IndexPass.extractOne`, audit X2) : c'est le seul endroit où l'on tient le
// texte du document sans le relire. Conséquence mesurée le 05/09/2026 sur la
// base réelle (lot U2) : 1 392 documents sur 1 499 avaient `lang` à NULL,
// parce qu'ils avaient été indexés AVANT que la détection existe. La facette
// « Langue » livrée par U2 ne disait donc presque rien.
//
// Il n'y a pourtant RIEN à ré-extraire : le texte est déjà en base, dans
// `page_fts`. Ce fichier le relit — quelques milliers de caractères par
// document, pas plus que ce que `LanguageDetector` regarde — et remplit la
// colonne.
//
// TROIS DÉCISIONS :
//
//   1. LA DÉTECTION EST INJECTÉE. `LanguageDetector` vit dans FouineIndex, qui
//      dépend de FouineCore : le cœur ne peut pas l'appeler sans un cycle. Elle
//      arrive donc en paramètre, sous la forme exacte qu'elle a là-bas
//      (`[PageText] -> String?`). Bénéfice second : `FouineCoreTests` teste le
//      rattrapage avec un détecteur de contrôle, sans NaturalLanguage.
//
//   2. « und » PLUTÔT QUE NULL quand la détection ne conclut pas. Sans jeton,
//      le document serait recandidat à CHAQUE passe, indéfiniment, pour rendre
//      le même « je ne sais pas ». `FacetKey.undeterminedLanguage` est déjà ce
//      que l'interface et `--lang` manipulent ; la facette et le filtre
//      traitent NULL, '' et « und » comme une seule valeur
//      (`GRDBStore+Search.languageSQL`).
//
//   3. TROIS TEMPS PAR LOT : lecture des échantillons (transaction de
//      lecture), détection HORS transaction, puis UNE écriture pour tout le
//      lot. NLLanguageRecognizer coûte environ une milliseconde par document ;
//      le verrou d'écriture n'a aucune raison de l'attendre, et l'agent tient
//      ce verrou pendant ses passes.

import Foundation
import GRDB

/// Bilan d'un rattrapage de langue (lot U3, R-10).
public struct LanguageBackfillReport: Sendable, Equatable {
    /// Documents relus et écrits pendant cette exécution.
    public let scanned: Int
    /// Répartition des codes écrits, `FacetKey.undeterminedLanguage` compris.
    public let counts: [String: Int]
    /// Documents qu'il reste à rattraper APRÈS cette exécution.
    public let remaining: Int
    public let elapsedMS: Double

    public init(scanned: Int, counts: [String: Int], remaining: Int,
                elapsedMS: Double) {
        self.scanned = scanned
        self.counts = counts
        self.remaining = remaining
        self.elapsedMS = elapsedMS
    }

    public static let empty = LanguageBackfillReport(
        scanned: 0, counts: [:], remaining: 0, elapsedMS: 0)

    /// Documents pour lesquels une langue a réellement été reconnue.
    public var determined: Int {
        scanned - (counts[FacetKey.undeterminedLanguage] ?? 0)
    }

    /// « fr 812 · en 431 · und 149 », du plus fréquent au moins fréquent.
    public var distribution: String {
        counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
    }

    public var json: [String: Any] {
        [
            "scanned": scanned,
            "determined": determined,
            "remaining": remaining,
            "languages": counts,
            "elapsed_ms": Int(round(elapsedMS)),
        ]
    }
}

extension GRDBStore {

    /// Documents relus par écriture. Cent, et non le lot entier : c'est la
    /// taille qui garde une transaction courte (l'agent peut vouloir le verrou)
    /// sans payer une transaction par document.
    public static let languageBackfillChunk = 100

    /// Documents dont la langue reste à déterminer : extraits, porteurs de
    /// pages, et `lang` vide.
    ///
    /// Ordre par `id` — donc stable d'une passe à l'autre : le rattrapage
    /// avance dans le fonds au lieu de repiocher les mêmes.
    public func documentsWithoutLanguage(limit: Int) throws -> [Int64] {
        guard limit > 0 else { return [] }
        return try read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM docs
                WHERE (lang IS NULL OR lang = '') AND state = ? AND n_pages > 0
                ORDER BY id LIMIT ?
                """, arguments: [DocState.extracted.rawValue, limit])
        }
    }

    /// Remet `docs.lang` à NULL pour TOUS les documents extraits porteurs de
    /// pages, et rend leur nombre : c'est ce qui rend un fonds entier candidat
    /// au rattrapage (`fouine maintain --redetect-languages`).
    ///
    /// POURQUOI IL LE FAUT (C2-01). Le rattrapage ne prend que les documents
    /// SANS langue : après un correctif de la détection, les 62 documents que
    /// la base de production range en hongrois ou en danois ne seraient jamais
    /// relus, et le filtre « Français » resterait un piège. Une seule
    /// transaction, sous le verrou d'écriture : un fonds à moitié réinitialisé
    /// par un `Ctrl-C` serait pire que rien.
    @discardableResult
    public func resetAllLanguages() throws -> Int {
        try writeLocked { db in
            try db.execute(sql: """
                UPDATE docs SET lang = NULL WHERE state = ? AND n_pages > 0
                """, arguments: [DocState.extracted.rawValue])
            return db.changesCount
        }
    }

    /// Combien il en reste (`fouine status`).
    public func documentsWithoutLanguageCount() throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM docs
                WHERE (lang IS NULL OR lang = '') AND state = ? AND n_pages > 0
                """, arguments: [DocState.extracted.rawValue]) ?? 0
        }
    }

    /// Rattrape `docs.lang` pour au plus `limit` documents, depuis le texte
    /// déjà indexé.
    ///
    /// - Parameters:
    ///   - limit: nombre maximal de documents relus. `Int.max` = tout.
    ///   - sampleCharacters: borne de l'échantillon, à passer telle que le
    ///     détecteur la connaît (`LanguageDetector.sampleCharacters`) : c'est
    ///     elle qui décide combien de pages sont lues par document.
    ///   - detect: la détection elle-même. Reçoit les pages dans l'ordre, comme
    ///     `LanguageDetector.sample(pages:)` les attend ; rend un code ISO
    ///     639-1, ou `nil` quand elle ne conclut pas.
    @discardableResult
    public func backfillLanguages(
        limit: Int,
        sampleCharacters: Int,
        chunk: Int = GRDBStore.languageBackfillChunk,
        detect: ([PageText]) -> String?
    ) throws -> LanguageBackfillReport {
        let start = Date()
        var counts: [String: Int] = [:]
        var scanned = 0

        while scanned < limit {
            let ids = try documentsWithoutLanguage(limit: min(chunk, limit - scanned))
            if ids.isEmpty { break }

            // 1. Lecture : une transaction, tout le lot.
            let samples: [(id: Int64, pages: [PageText])] = try read { db in
                try ids.map { (id: $0,
                               pages: try Self.languageSample(
                                db, docID: $0, sampleCharacters: sampleCharacters)) }
            }

            // 2. Détection, hors de toute transaction (décision n°3).
            let decided: [(id: Int64, lang: String)] = samples.map { sample in
                let raw = detect(sample.pages)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let lang = (raw?.isEmpty == false) ? raw! : FacetKey.undeterminedLanguage
                return (id: sample.id, lang: lang)
            }

            // 3. Écriture : une transaction, tout le lot.
            try writeLocked { db in
                for row in decided {
                    try db.execute(sql: "UPDATE docs SET lang = ? WHERE id = ?",
                                   arguments: [row.lang, row.id])
                }
            }

            for row in decided { counts[row.lang, default: 0] += 1 }
            scanned += decided.count
        }

        return LanguageBackfillReport(
            scanned: scanned, counts: counts,
            remaining: try documentsWithoutLanguageCount(),
            elapsedMS: Date().timeIntervalSince(start) * 1000.0)
    }

    /// Les pages à soumettre à la détection : TROIS RÉGIONS réparties sur le
    /// document, jamais sa seule tête.
    ///
    /// POURQUOI PAS LES PREMIÈRES PAGES (constat C2-01, 09/09/2026). Cette
    /// méthode lisait les pages dans l'ordre et s'arrêtait dès qu'elle en avait
    /// assez — c'est-à-dire à la page de garde, au préambule Gutenberg ou aux
    /// en-têtes d'un courriel. Sur la base de production, 62 documents
    /// franco-anglais portaient une langue improbable et 269 aucune. Les
    /// régions sont donc prises à 10 %, 50 % et 90 % des pages : leurs numéros
    /// ne se suivent pas, et c'est ce trou qui dit à
    /// `LanguageDetector.sample(pages:)` qu'il tient trois tranches à faire
    /// voter plutôt qu'un bloc à redécouper.
    ///
    /// Le coût de lecture ne bouge pas : trois régions d'un tiers d'échantillon
    /// valent l'échantillon d'avant. Un document de trois pages ou moins est lu
    /// d'un bloc — il n'y a rien à répartir, et une page tronquée au tiers
    /// donnerait MOINS de matière qu'avant à la moitié du corpus (lettres,
    /// factures, courriels : un seul feuillet).
    ///
    /// Lecture par PLAGE DE ROWID (§4.1) : parcours d'index borné, jamais un
    /// MATCH ni un balayage de `page_fts`.
    static func languageSample(_ db: Database, docID: Int64,
                               sampleCharacters: Int) throws -> [PageText] {
        let range = Schema.ftsRowIDRange(docID: docID)
        // Les rowid seuls : un parcours d'index, sans lire le texte.
        let rowIDs = try Int64.fetchAll(db, sql: """
            SELECT rowid FROM page_fts WHERE rowid BETWEEN ? AND ? ORDER BY rowid
            """, arguments: [range.lowerBound, range.upperBound])
        guard !rowIDs.isEmpty else { return [] }

        let regions = languageSampleRegions(count: rowIDs.count)
        // Un document COURT est lu d'un bloc, et large : c'est le détecteur qui
        // y découpe ses tranches, sur les décalages. Le lire au tiers
        // d'échantillon donnerait moins de matière qu'avant le correctif à la
        // moitié d'un fonds ordinaire — lettres, factures, courriels tiennent
        // sur un feuillet.
        let perRegion = regions.count > 1
            ? max(1, sampleCharacters / regions.count)
            : sampleCharacters * languageSampleSlices

        var pages: [PageText] = []
        for region in regions {
            var taken = 0
            for index in region {
                guard taken < perRegion, index < rowIDs.count else { break }
                let row = try Row.fetchOne(db, sql: """
                    SELECT (rowid % \(Schema.pagesPerDocLimit)) AS page,
                           substr(body, 1, ?) AS body
                    FROM page_fts WHERE rowid = ?
                    """, arguments: [perRegion - taken, rowIDs[index]])
                guard let row else { continue }
                let text: String = row["body"] ?? ""
                pages.append(PageText(page: row["page"], text: text,
                                      source: .native))
                taken += text.count
            }
        }
        return pages
    }

    /// Nombre de tranches que le détecteur fait voter — donc de régions ici, et
    /// du facteur de lecture d'un document court. Miroir de
    /// `LanguageDetector.sliceCount`, que le cœur ne peut pas importer (il
    /// vit dans FouineIndex, qui dépend de lui).
    public static let languageSampleSlices = 3

    /// Les index de pages lus, par région.
    ///
    /// Un document d'au plus deux régions pleines (six pages) est lu D'UN BLOC :
    /// il n'y a rien à répartir, et c'est le détecteur qui y découpe ses
    /// tranches sur les décalages, ce qu'il fait mieux que nous — il connaît la
    /// longueur des textes, nous ne connaissons que le nombre de pages.
    ///
    /// Au-delà, trois régions vers 10 %, 50 % et 90 %, larges de deux pages, et
    /// SÉPARÉES PAR AU MOINS UNE PAGE. La séparation n'est pas un détail : c'est
    /// le trou dans la numérotation qui dit au détecteur qu'il tient trois
    /// tranches à faire voter. Deux régions collées n'en formeraient qu'une, et
    /// un vote à deux voix qui se contredisent ne tranche rien.
    static func languageSampleRegions(count: Int) -> [[Int]] {
        guard count > 2 * languageSampleSlices else { return [Array(0..<count)] }
        var regions: [[Int]] = []
        var lastUsed = -2
        for ratio in [0.10, 0.50, 0.90] {
            let anchor = min(count - 1, max(0, Int(Double(count - 1) * ratio)))
            let start = max(anchor, lastUsed + 2)
            guard start < count else { continue }
            let region = start + 1 < count ? [start, start + 1] : [start]
            lastUsed = region[region.count - 1]
            regions.append(region)
        }
        return regions.isEmpty ? [[0]] : regions
    }

    // MARK: - Réinitialisation après OCR (PERSP-5)

    /// Remet `docs.lang` à NULL pour un document dont la langue vaut « und »
    /// (ou est vide), afin qu'il redevienne candidat au rattrapage de langue
    /// maintenant que du texte OCR a été écrit.
    ///
    /// Un document dont la langue a déjà été reconnue (ex. « fr ») n'est
    /// JAMAIS touché : une page OCRisée n'a pas à remettre en cause une langue
    /// déjà établie.
    ///
    /// Un document dont le texte OCR reste trop court ou indéterminable
    /// redeviendra « und » au rattrapage et ne sera plus relu aux passes
    /// suivantes — c'est le comportement voulu pour ne pas tourner en boucle
    /// sur du bruit ou du charabia.
    ///
    /// Cette méthode est appelée dans la transaction de `completeOCR`
    /// (`resetLanguageIfUndetermined(_:docID:)`), ou isolément sous le verrou.
    @discardableResult
    public func resetLanguageIfUndetermined(docID: Int64) throws -> Bool {
        try writeLocked { db in
            try Self.resetLanguageIfUndetermined(db, docID: docID)
        }
    }

    /// Variante sous transaction déjà ouverte (`completeOCR`).
    @discardableResult
    public static func resetLanguageIfUndetermined(_ db: Database, docID: Int64) throws -> Bool {
        try db.execute(sql: """
            UPDATE docs SET lang = NULL
            WHERE id = ? AND (lang = ? OR lang = '')
            """, arguments: [docID, FacetKey.undeterminedLanguage])
        return db.changesCount > 0
    }
}
