// SelfTest.swift — vérification SANS interface (FOUINE_SELFTEST=1).
// Propriété : A-App.
//
// Un agent d'exécution n'a pas toujours de serveur de fenêtres ; ce mode rejoue
// en tête-à-tête avec la base réelle exactement ce que les panneaux font :
// recherche (« polymere » par défaut), facettes, extraction des termes marqués,
// résolution du fichier d'un hit natif + occurrences dans PDFPage.string,
// projection des boîtes ocr_layout d'un hit OCR, autocomplétion. AUCUNE ÉCRITURE.
//
// Sortie : lignes « ok — » / « FAIL — », code 0 si tout passe, 1 sinon. Comme
// la CLI, cet outil de diagnostic parle ANGLAIS (palier 3.5) : il n'a pas
// d'interface, donc pas de catalogue.

import Foundation
import PDFKit
import FouineCore

enum SelfTest {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["FOUINE_SELFTEST"] == "1"
    }

    private static var failures = 0

    private static func check(_ condition: Bool, _ label: String,
                              detail: String = "") {
        if condition {
            print("ok    — \(label)\(detail.isEmpty ? "" : " (\(detail))")")
        } else {
            failures += 1
            print("FAIL  — \(label)\(detail.isEmpty ? "" : " (\(detail))")")
        }
    }

    static func run() {
        let queryText = ProcessInfo.processInfo
            .environment["FOUINE_SELFTEST_QUERY"] ?? "polymere"
        let dbURL = AppPaths.databaseURL()
        print("Fouine.app — headless self-test · database: \(dbURL.path)")

        // 1 · Ouverture (lecture seule de fait : aucune écriture ne suit).
        let store = GRDBStore()
        do { try store.open(at: dbURL) } catch {
            print("FAIL  — opening the database: \(ErrorText.describe(error))")
            exit(1)
        }
        let stats = (try? store.stats()) ?? [:]
        check((stats["pages_indexed"] ?? 0) > 0, "index is not empty",
              detail: "\(Format.integer(stats["docs_total"] ?? 0)) docs, "
                      + "\(Format.integer(stats["pages_indexed"] ?? 0)) pages")

        // 2 · Recherche principale.
        let results: SearchResults
        do {
            let query = try QueryParser.searchQuery(queryText, limit: 50)
            results = try store.search(query)
        } catch {
            print("FAIL  — search “\(queryText)”: \(ErrorText.describe(error))")
            exit(1)
        }
        check(!results.hits.isEmpty, "search “\(queryText)”",
              detail: "\(Format.integer(results.totalPages)) pages / "
                      + "\(Format.integer(results.totalDocs)) docs in "
                      + Format.milliseconds(results.elapsedMS))
        for hit in results.hits.prefix(3) {
            let name = (hit.path as NSString).lastPathComponent
            print("        · \(name) p.\(hit.page) [\(hit.source)] "
                  + hit.snippet.replacingOccurrences(of: "\n", with: " ")
                               .prefix(80))
        }

        // 3 · Facettes.
        if let base = try? QueryParser.searchQuery(queryText) {
            for key in [FacetKey.folder, .ext, .year, .source] {
                let values = (try? store.facets(base, by: key)) ?? []
                let sample = values.prefix(3)
                    .map { "\($0.0)=\($0.1)" }.joined(separator: " ")
                check(!values.isEmpty, "facet \(key.rawValue)", detail: sample)
            }
        }

        // 4 · Termes marqués + segments de snippet.
        let terms = QueryTerms.extract(from: queryText)
        check(!terms.isEmpty, "extraction of the terms to highlight",
              detail: terms.map(\.folded).joined(separator: ", "))
        if let snippet = results.hits.first?.snippet {
            let marked = SnippetParser.segments(snippet).filter(\.marked)
            check(!marked.isEmpty, "marked segments in the snippet",
                  detail: "\(marked.count) segment(s)")
        }

        // 5 · Aperçu d'un hit NATIF : fichier résolu, PDF ouvert, occurrences.
        if let native = results.hits.first(where: {
            $0.source == .native && $0.path.lowercased().hasSuffix(".pdf")
        }) {
            verifyNativePreview(store: store, hit: native, terms: terms)
        } else {
            print("note  — no native .pdf hit in the first 50; native preview not tested")
        }

        // 6 · Boîtes OCR d'un hit OCRisé : projection vers le mediaBox.
        if let ocrHit = results.hits.first(where: {
            $0.source != .native && $0.path.lowercased().hasSuffix(".pdf")
        }) {
            verifyOCRBoxes(store: store, hit: ocrHit, terms: terms)
        } else {
            print("note  — no OCR .pdf hit in the first 50; boxes not tested")
        }

        // 7 · Autocomplétion (< 20 ms demandé sur la complétion elle-même).
        let vocabulary = (try? store.topVocabulary(limit: 2_000, minLength: 3)) ?? []
        check(!vocabulary.isEmpty, "fts5vocab vocabulary is readable",
              detail: "\(vocabulary.count) terms, e.g. "
                      + vocabulary.prefix(3).joined(separator: ", "))

        print(failures == 0 ? "SELF-TEST: everything passes."
                            : "SELF-TEST: \(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Aperçu natif

    private static func verifyNativePreview(store: GRDBStore, hit: Hit,
                                            terms: [HighlightTerm]) {
        guard let row = try? store.docRow(id: hit.docID),
              let url = try? VolumeResolver.absolutePath(volUUID: row.record.volUUID,
                                                         relPath: row.record.relPath)
        else {
            check(false, "resolving the path of the native hit")
            return
        }
        check(FileManager.default.isReadableFile(atPath: url.path),
              "file of the native hit is readable", detail: url.lastPathComponent)
        guard let document = PDFDocument(url: url) else {
            check(false, "PDFDocument(url:) on the native hit",
                  detail: url.lastPathComponent)
            return
        }
        guard let page = document.page(at: hit.page - 1),
              let text = page.string else {
            check(false, "page \(hit.page) and text layer of the native hit")
            return
        }
        var occurrences = 0
        for term in terms {
            var range = text.startIndex..<text.endIndex
            while let found = text.range(of: term.text,
                                         options: [.caseInsensitive,
                                                   .diacriticInsensitive],
                                         range: range) {
                if page.selection(for: NSRange(found, in: text)) != nil {
                    occurrences += 1
                }
                guard found.upperBound < text.endIndex else { break }
                range = found.upperBound..<text.endIndex
            }
        }
        check(occurrences > 0,
              "native selections on \(url.lastPathComponent) p.\(hit.page)",
              detail: "\(occurrences) selectable occurrence(s)")
    }

    // MARK: - Boîtes OCR

    private static func verifyOCRBoxes(store: GRDBStore, hit: Hit,
                                       terms: [HighlightTerm]) {
        guard let lines = try? store.ocrLayout(docID: hit.docID, page: hit.page),
              !lines.isEmpty else {
            check(false, "ocr_layout of the OCR hit",
                  detail: "doc \(hit.docID) p.\(hit.page)")
            return
        }
        let matching = lines.filter {
            QueryTerms.matchInText($0.text, terms: terms) != nil
        }
        check(!matching.isEmpty, "OCR lines that hold a term",
              detail: "\(matching.count) / \(lines.count) lines")

        // Projection réelle sur la page si le fichier est là ; sinon sur un
        // mediaBox A4 (la géométrie est la même, c'est elle qu'on teste).
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        var rotation = 0
        if let row = try? store.docRow(id: hit.docID),
           let url = try? VolumeResolver.absolutePath(volUUID: row.record.volUUID,
                                                      relPath: row.record.relPath),
           let document = PDFDocument(url: url),
           let page = document.page(at: hit.page - 1) {
            mediaBox = page.bounds(for: .mediaBox)
            rotation = page.rotation
        }
        let inside = matching.allSatisfy { line in
            let r = OCRGeometry.denormalize(line, mediaBox: mediaBox,
                                            rotation: rotation)
            return mediaBox.insetBy(dx: -1, dy: -1).contains(r) && r.width > 0
        }
        check(inside, "boxes projected inside the mediaBox",
              detail: String(format: "mediaBox %.0f×%.0f rot %d",
                             mediaBox.width, mediaBox.height, rotation))
    }
}
