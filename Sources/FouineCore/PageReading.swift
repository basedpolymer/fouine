// PageReading.swift — lire le TEXTE d'une page indexée, une fois pour toutes
// les surfaces (constat PM-18). Propriété : A-Core.
//
// POURQUOI CE FICHIER EXISTE. `fouine_read_page` savait rendre le texte d'une
// page depuis le palier 4 ; la ligne de commande, non. Un agent qui n'a que le
// shell — un autre modèle par sa CLI, un script — pouvait donc chercher sans
// jamais lire ce qu'il avait trouvé. La commande manquante est `fouine read`,
// et l'audit a posé sa condition : elle doit PARTAGER son implémentation avec
// l'outil MCP, sinon les deux dériveront comme `score` et `bm25`, qui sont le
// même nombre sous deux noms dans le même produit (PM-16b).
//
// CE QUE ÇA NE REND PAS : le fichier d'origine. Comme l'outil, on rend le texte
// que Fouine a extrait ou reconnu, c'est-à-dire ce qui est déjà en base.
// `absPath` est fourni ; ouvrir le PDF est l'affaire de l'utilisateur.
//
// LA PAGE VIDE N'EST PAS UNE ERREUR. Une page qui existe (`page ≤ pageCount`)
// mais dont `page_fts` ne porte rien est une page image en attente de
// reconnaissance : elle est rendue en SUCCÈS, texte vide, avec une note qui
// l'explique. Ce qui est une erreur, c'est de demander une page que le document
// n'a PAS — et le message le dit avec le nombre de pages qu'il a vraiment.
//
// LA NOTE DIFFÈRE D'UNE SURFACE À L'AUTRE, et c'est le seul écart : le geste
// d'un assistant est `fouine_status.ocr_queue`, celui d'un humain au terminal
// est `fouine status`. Tout le reste — lecture, découpe, contexte, clés — est
// un seul chemin.

import Foundation
import PDFKit

/// Le texte d'une page indexée, son contexte et de quoi le citer.
public struct PageReading {

    /// Une page lue : la page demandée, ou l'une de ses voisines.
    public struct Page {
        public let docID: Int64
        public let number: Int
        public let relPath: String
        public let absPath: String?
        public let folder: String
        public let ext: String
        /// Tranche lue, déjà bornée par `maxChars`.
        public let text: String
        /// Décalage de cette tranche dans la page.
        public let offset: Int
        /// Longueur de la page ENTIÈRE.
        public let totalChars: Int
        public let source: PageSource
        public let engine: OCREngineID
        public let ocrConfidence: Double?
        /// Ce que la page a de particulier — aucun texte indexé, pour l'instant.
        public let note: String?
        /// Le numéro IMPRIMÉ sur la page, quand il diffère de son rang
        /// (`PDFPage.label`, lot MC4, constat PM-20). `nil` partout ailleurs :
        /// voir `PDFPageLabels`.
        public let pageLabel: String?

        public var chars: Int { text.count }
        public var truncated: Bool { offset + text.count < totalChars }
        public var nextOffset: Int? { truncated ? offset + text.count : nil }

        /// Le lien `fouine://` qui rouvre Fouine sur cette page. Passe par
        /// `DeepLink`, point unique du dépôt : les surfaces qui émettent un
        /// lien doivent en émettre le même.
        public var link: String {
            DeepLink.link(absolutePath: absPath, docID: docID,
                          page: number).absoluteString
        }

        /// Les clés de `fouine_read_page`, pour les deux surfaces.
        ///
        /// `textLimit` raccourcit la tranche SANS rien recalculer d'autre :
        /// c'est ce dont le plafond de réponse du serveur MCP a besoin
        /// (`ToolBudget.fit` refabrique une charge utile plus petite), et
        /// `truncated` / `next_offset` suivent la tranche réellement rendue.
        public func json(textLimit: Int? = nil) -> [String: Any] {
            let body = textLimit.map { String(text.prefix(max(0, $0))) } ?? text
            let read = offset + body.count
            return [
                "doc_id": docID,
                "page": number,
                // Toujours présente, `null` la plupart du temps : un modèle ne
                // peut pas deviner ce qu'une clé absente voudrait dire, et
                // « null » dit exactement « le numéro imprimé est le rang ».
                "page_label": pageLabel.map { $0 as Any } ?? NSNull(),
                "path": relPath,
                "abs_path": absPath.map { $0 as Any } ?? NSNull(),
                "folder": folder,
                "ext": ext,
                "link": link,
                "text": body,
                "chars": body.count,
                "total_chars": totalChars,
                "truncated": read < totalChars,
                "next_offset": read < totalChars ? read as Any : NSNull(),
                "source": GRDBStore.sourceLabel(source.rawValue),
                "engine": GRDBStore.engineLabel(engine),
                "ocr_confidence": ocrConfidence
                    .map { JSONNumber.rounded($0, places: 3) as Any } ?? NSNull(),
                "note": note.map { $0 as Any } ?? NSNull(),
            ]
        }
    }

    public let page: Page
    /// Nombre de pages du document (`docs.n_pages`).
    public let pageCount: Int
    /// Les voisines, LES PLUS PROCHES D'ABORD : p−1, p+1, p−2, p+2.
    public let context: [Page]

    /// L'objet complet, clés de `fouine_read_page`. `keptContext` sert au même
    /// plafond de réponse que `textLimit`.
    public func json(textLimit: Int? = nil, keptContext: Int? = nil) -> [String: Any] {
        var out = page.json(textLimit: textLimit)
        out["page_count"] = pageCount
        let kept = context.prefix(keptContext ?? context.count)
        if !kept.isEmpty {
            out["context"] = kept.map { $0.json(textLimit: textLimit) }
        }
        return out
    }

    // MARK: - Refus

    /// Ce qui n'est pas une page vide mais une demande impossible. Les phrases
    /// sont celles de l'outil MCP : un même refus, un même texte.
    public enum Failure: Error, CustomStringConvertible {
        case unknownDocument(Int64)
        case pageOutOfRange(page: Int, docID: Int64, pageCount: Int)
        case unaddressablePage(Int)

        public var description: String {
            switch self {
            case .unknownDocument(let id):
                return "no document \(id) in this index"
            case .pageOutOfRange(let page, let docID, let count):
                return "no page \(page) in document \(docID) "
                     + "(it has \(count) pages)"
            case .unaddressablePage(let page):
                return "page \(page) is outside the range this index can "
                     + "address (1…\(Schema.maxPage))"
            }
        }
    }

    // MARK: - Notes

    /// La page existe, mais rien n'en a été indexé : image en attente de
    /// reconnaissance, page blanche, ou texte sous le seuil d'indexation.
    public static let assistantMissingTextNote =
        "this page carries no indexed text — it may be an image waiting for OCR "
        + "(see fouine_status.ocr_queue)"

    /// La même chose, avec le geste d'un humain au terminal.
    public static let commandMissingTextNote =
        "this page carries no indexed text — it may be an image waiting for OCR "
        + "(see `fouine status`)"

    // MARK: - Chargement

    /// Voisines d'une page, les plus proches d'abord. L'ordre compte quand un
    /// budget en retire : on garde ce qui éclaire le plus la page demandée.
    public static func contextPages(around page: Int, count: Int,
                                    pageCount: Int) -> [Int] {
        guard count > 0 else { return [] }
        var out: [Int] = []
        for delta in 1...count {
            if page - delta >= 1 { out.append(page - delta) }
            if pageCount == 0 || page + delta <= pageCount { out.append(page + delta) }
        }
        return out
    }

    /// Lit une page et ses voisines. TROIS requêtes au plus, quel que soit le
    /// contexte demandé : le document, les tranches de texte (la page et ses
    /// voisines ensemble), les métadonnées de page.
    ///
    /// Les voisines sont lues depuis leur DÉBUT (décalage 0) : la même tranche
    /// que la page demandée n'aurait aucun sens ailleurs.
    /// - Parameter pageLabels: lire le numéro IMPRIMÉ des pages d'un PDF
    ///   (`PDFPage.label`). Ouvre le fichier, ce qu'aucune autre lecture de
    ///   page ne fait : ~1,3 s pour un livre de 428 pages, acceptable pour UNE
    ///   lecture et inacceptable par hit — d'où l'absence de ce champ dans
    ///   `fouine_search`. Faux dans les tests qui n'ont pas de fichier.
    public static func load(store: GRDBStore, docID: Int64, page: Int,
                            maxChars: Int, offset: Int = 0,
                            contextPages context: Int = 0,
                            missingTextNote: String = assistantMissingTextNote,
                            pageLabels: Bool = true)
        throws -> PageReading {

        guard let row = try store.docRow(id: docID) else {
            throw Failure.unknownDocument(docID)
        }
        let pageCount = row.record.nPages
        guard page <= pageCount || pageCount == 0 else {
            throw Failure.pageOutOfRange(page: page, docID: docID,
                                         pageCount: pageCount)
        }
        guard page >= 1, page <= Schema.maxPage else {
            throw Failure.unaddressablePage(page)
        }

        let neighbours = contextPages(around: page, count: context,
                                      pageCount: pageCount)
        let rowid = Schema.ftsRowID(docID: docID, page: page)
        let chars = max(1, maxChars)
        let start = max(0, offset)
        let mainSlice = try store.pagePreviews(for: [rowid], maxChars: chars,
                                               offset: start)[rowid]
        let neighbourRowids = neighbours.map {
            Schema.ftsRowID(docID: docID, page: $0)
        }
        let neighbourSlices = try store.pagePreviews(for: neighbourRowids,
                                                     maxChars: chars)
        let meta = try store.pageMeta(
            for: ([page] + neighbours).map { (docID: docID, page: $0) })

        let absPath = (try? VolumeResolver.absolutePath(
            volUUID: row.record.volUUID, relPath: row.record.relPath))?.path

        // UNE seule ouverture du PDF pour la page ET son contexte : le coût est
        // celui du document, pas celui de la page (piège n°1 du renderer).
        let labels = pageLabels
            ? PDFPageLabels.read(path: absPath, ext: row.record.ext,
                                 pages: [page] + neighbours)
            : [:]

        func make(_ number: Int,
                  _ slice: (relPath: String, preview: String, totalChars: Int)?,
                  offset: Int) -> Page {
            let pageMeta = meta[Schema.ftsRowID(docID: docID, page: number)]
            return Page(
                docID: docID, number: number, relPath: row.record.relPath,
                absPath: absPath, folder: row.record.topFolder,
                ext: row.record.ext,
                text: slice?.preview ?? "", offset: offset,
                totalChars: slice?.totalChars ?? 0,
                source: pageMeta?.source ?? .native,
                engine: pageMeta?.engine ?? .none,
                ocrConfidence: pageMeta?.conf,
                note: slice == nil ? missingTextNote : nil,
                pageLabel: labels[number])
        }

        return PageReading(
            page: make(page, mainSlice, offset: start),
            pageCount: pageCount,
            context: zip(neighbours, neighbourRowids).map { number, id in
                make(number, neighbourSlices[id], offset: 0)
            })
    }
}

// MARK: - Le numéro IMPRIMÉ sur la page (lot MC4, constat PM-20)

/// `PDFPage.label`, lu à la LECTURE et jamais stocké.
///
/// CE QUE ÇA RÉSOUT, ET CE QUE ÇA NE RÉSOUT PAS. Mesuré le 13/09/2026 sur 25
/// PDF de plus de douze pages : **11 (44 %)** rendent pour le rang 12 une
/// étiquette différente — `XII`, `xiii`, `4`, `2`… c'est-à-dire un vrai
/// décalage de préliminaires, et citer « page 12 » y désigne autre chose que ce
/// que le lecteur trouvera. Le champ le dit.
///
/// LE CAS QUI RESTE OUVERT : un livre dont le numéro n'est imprimé que dans
/// l'en-tête courant, sans dictionnaire `/PageLabels` dans le PDF. PDFKit rend
/// alors le RANG (mesuré : document 811, rang 233 → étiquette « 233 », alors
/// que le texte de la page commence par « 234 »). Aucune lecture de métadonnée
/// ne peut le corriger ; le lien, lui, reste juste dans tous les cas.
///
/// COÛT : l'ouverture du document. C'est tenable pour UNE lecture de page et
/// pas pour dix hits — d'où l'absence de ce champ dans `fouine_search`.
public enum PDFPageLabels {

    /// Les étiquettes des pages demandées, par numéro de page, **sans** celles
    /// qui répètent le rang : une étiquette « 12 » pour la page 12 n'apprend
    /// rien et un modèle la recopierait comme une précision.
    public static func read(path: String?, ext: String,
                            pages: [Int]) -> [Int: String] {
        guard ext.lowercased() == "pdf", let path, !pages.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return [:] }
        // Rouvert ET relâché, comme `FouinePageRenderer` : `PDFDocument` retient
        // tout ce qu'il analyse (piège n°1, mesuré à 1 515 Mo sur un fil).
        return autoreleasepool { () -> [Int: String] in
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
                return [:]
            }
            var out: [Int: String] = [:]
            for page in Set(pages) where page >= 1 && page <= document.pageCount {
                guard let label = document.page(at: page - 1)?.label,
                      !label.isEmpty, label != String(page) else { continue }
                out[page] = label
            }
            return out
        }
    }
}
