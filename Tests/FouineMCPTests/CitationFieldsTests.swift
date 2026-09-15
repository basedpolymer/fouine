// CitationFieldsTests.swift — ce qu'une citation doit dire (lot MC2) :
// `time_seconds`, `slide`, `embedded_image`, `relevance_pct`, `semantic_scope`,
// et la description qui pose la réserve.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// TROIS CORPUS RENDAIENT LA PHRASE DE CITATION FAUSSE (PM-30) : « page 170 »
// d'un `.pptx` désigne une image incorporée, « page 1 » d'une vidéo désigne dix
// minutes de parole, et un livre à préliminaires décale ses numéros. Les deux
// premiers se corrigent ici ; le troisième est écarté explicitement (PM-20).

import Foundation
import XCTest
import GRDB
import FouineCore
import FouineEmbed
import FouineMCPKit
@testable import FouineMCP

final class CitationFieldsTests: XCTestCase {

    /// Un diaporama (deux diapositives puis deux images incorporées) et une
    /// vidéo transcrite, ajoutés à la base jetable par les API d'écriture.
    private func mixedIndex() throws -> (index: TempIndex, deck: Int64,
                                         video: Int64) {
        let index = try TempIndex(documents: 1, pagesPerDocument: 1)
        let store = GRDBStore()
        try store.open(at: index.databaseURL)
        defer { store.releaseWriteLock() }
        let deck = try store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Users/essai/M2SU/cours.pptx",
            ext: "pptx", topFolder: "M2SU", size: 9_000, mtime: 1_700_000_000))
        try store.setPageCount(deck, 4)
        try store.replacePages(docID: deck, pages: [
            PageText(page: 1, text: "titre du cours de genie", source: .native),
            PageText(page: 2, text: "bilan de matiere du reacteur", source: .native),
            PageText(page: 3, text: "figure du reacteur scannee", source: .ocrAccurate),
            PageText(page: 4, text: "schema du reacteur scanne", source: .ocrAccurate),
        ])
        try store.setDocState(deck, .extracted, err: nil)

        let video = try store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Users/essai/M2SU/solveur.mp4",
            ext: "mp4", topFolder: "M2SU", size: 500_000, mtime: 1_700_000_000))
        try store.setPageCount(video, 1)
        try store.replacePages(docID: video, pages: [
            PageText(page: 1,
                     text: "[00:01] Dans cette video je vais vous expliquer.\n\n"
                         + "[12:40] charger la commande soldeur dans le tableur.",
                     source: .transcript),
        ])
        try store.setDocState(video, .extracted, err: nil)
        return (index, deck, video)
    }

    private func payload(_ index: TempIndex, _ arguments: String) throws
        -> [String: Any] {
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_search","arguments":\#(arguments)}}"#.utf8)))
        let object = try JSONMatch.object(response)
        XCTAssertNil(object["error"], "\(object)")
        return try XCTUnwrap((object["result"] as? [String: Any])?["structuredContent"]
            as? [String: Any])
    }

    private func hits(_ payload: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(payload["hits"] as? [[String: Any]])
    }

    // MARK: - Le moment d'une transcription (PM-22)

    func testUneTranscriptionCiteSonMomentEtSonLienLePorte() throws {
        let fixture = try mixedIndex()
        let hits = try hits(try payload(fixture.index,
            #"{"query":"soldeur","limit":5}"#))
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit["doc_id"] as? Int64, fixture.video)
        XCTAssertEqual(hit["time_seconds"] as? Int, 12 * 60 + 40,
                       "le marqueur qui PRÉCÈDE le mot trouvé, pas celui de la page")
        XCTAssertTrue((hit["link"] as? String ?? "").contains("&t=760"),
                      hit["link"] as? String ?? "")
    }

    /// L'extrait ne porte pas toujours un marqueur : le début de la page prend
    /// alors le relais — c'est mieux que rien, et jamais faux.
    func testSansMarqueurDansLExtraitLeDebutDeLaPagePrendLeRelais() throws {
        let fixture = try mixedIndex()
        let hits = try hits(try payload(fixture.index,
            #"{"query":"video","limit":5,"snippet_chars":80}"#))
        XCTAssertEqual(hits.first?["time_seconds"] as? Int, 1)
    }

    /// Une page qui n'est pas transcrite porte la clé à `null` : un champ
    /// absent n'apprend rien à un modèle.
    func testUnePageNonTranscriteALaCleANull() throws {
        let fixture = try mixedIndex()
        let hits = try hits(try payload(fixture.index,
            #"{"query":"electrolyse","limit":5}"#))
        XCTAssertTrue(hits.allSatisfy { $0["time_seconds"] is NSNull })
        XCTAssertFalse((hits.first?["link"] as? String ?? "").contains("&t="))
    }

    // MARK: - Diapositive et image incorporée (PM-19)

    func testUnDiaporamaDistingueSesDiapositivesDeSesImages() throws {
        let fixture = try mixedIndex()
        let hits = try hits(try payload(fixture.index,
            #"{"query":"reacteur","limit":10,"mode":"lexical"}"#))
        var byPage: [Int: [String: Any]] = [:]
        for hit in hits where (hit["doc_id"] as? Int64) == fixture.deck {
            byPage[hit["page"] as? Int ?? -1] = hit
        }
        XCTAssertEqual(byPage[2]?["slide"] as? Int, 2)
        XCTAssertTrue(byPage[2]?["embedded_image"] is NSNull)
        XCTAssertEqual(byPage[3]?["embedded_image"] as? Int, 1,
                       "la première image incorporée, et non « page 3 »")
        XCTAssertTrue(byPage[3]?["slide"] is NSNull)
    }

    func testUnPDFNaNiDiapositiveNiImageIncorporee() throws {
        let fixture = try mixedIndex()
        let hits = try hits(try payload(fixture.index, #"{"query":"electrolyse"}"#))
        XCTAssertTrue(hits.allSatisfy { $0["slide"] is NSNull })
        XCTAssertTrue(hits.allSatisfy { $0["embedded_image"] is NSNull })
    }

    // MARK: - Pertinence relative (PM-16d)

    func testChaqueHitPorteSaPertinenceRelative() throws {
        let fixture = try mixedIndex()
        let hits = try hits(try payload(fixture.index,
            #"{"query":"reacteur","limit":10,"mode":"lexical"}"#))
        XCTAssertEqual(hits.compactMap { $0["relevance_pct"] as? Int }.max(), 100,
                       "le mieux classé de la réponse est la référence")
        XCTAssertTrue(hits.allSatisfy {
            let pct = $0["relevance_pct"] as? Int ?? -1
            return pct >= 0 && pct <= 100
        })
    }

    // MARK: - Périmètre du sens (PM-06)

    /// Sans vecteur ni filtre, le périmètre est l'index entier — et la clé est
    /// là quand même : c'est ce qui permet à un modèle de savoir que la
    /// couverture qu'il lit décrit bien ce qu'il a cherché.
    func testLePerimetreEstToujoursPublie() throws {
        let payload = try payload(try TempIndex(vectorisedPages: 2),
                                  #"{"query":"electrolyse","limit":1}"#)
        let scope = try XCTUnwrap(payload["semantic_scope"] as? [String: Any])
        XCTAssertEqual(scope["pages"] as? Int, 6)
        XCTAssertEqual(scope["vectorised"] as? Int, 2)
        XCTAssertEqual(scope["filtered"] as? Bool, false)
        XCTAssertEqual((payload["semantic_coverage_pct"] as? NSNumber)?.doubleValue,
                       33.33)
    }

    /// LE CAS DU CONSTAT : le dossier demandé n'a aucun vecteur. La couverture
    /// rendue est la SIENNE (0 %), pas la globale, et `filtered` le dit.
    func testUnPerimetreSansVecteurRendSaProprePart() throws {
        let index = try TempIndex(vectorisedPages: 2, roots: ["Livres", "M2SU"])
        let store = GRDBStore()
        try store.open(at: index.databaseURL)
        let cours = try store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Users/essai/M2SU/cours.pdf",
            ext: "pdf", topFolder: "M2SU", size: 1_000, mtime: 1_700_000_000))
        try store.setPageCount(cours, 1)
        try store.replacePages(docID: cours, pages: [
            PageText(page: 1, text: "electrolyse et enthalpie du cours",
                     source: .native),
        ])
        try store.setDocState(cours, .extracted, err: nil)
        store.releaseWriteLock()

        let payload = try payload(index,
            #"{"query":"electrolyse","folder":"M2SU","limit":5}"#)
        let scope = try XCTUnwrap(payload["semantic_scope"] as? [String: Any])
        XCTAssertEqual(scope["filtered"] as? Bool, true)
        XCTAssertEqual(scope["vectorised"] as? Int, 0)
        XCTAssertEqual(scope["pages"] as? Int, 1)
        XCTAssertEqual((payload["semantic_coverage_pct"] as? NSNumber)?.doubleValue, 0,
                       "et non 33,33 % : la couverture globale ne décrit pas "
                       + "ce dossier")
    }

    /// La phrase et la raison publiée quand le périmètre n'a pas un vecteur.
    /// Le modèle n'est PAS chargé — c'est tout l'intérêt — donc la base de ce
    /// test n'en a pas besoin pour éprouver le texte.
    func testLaPhraseDuPerimetreSansVecteurNommeLeGeste() throws {
        let scope = SemanticScope(vectors: 0, pagesIndexed: 31_986, filtered: true)
        let note = try XCTUnwrap(SearchTool.noVectorsInScopeNote(
            scope, disarmed: .noVectorsInScope, folders: ["M2SU"]))
        XCTAssertEqual(note, "no vectorised page in this scope (folder M2SU: 0 of "
                       + "31986) — `fouine embed --folder M2SU` prepares it")
        XCTAssertNil(SearchTool.noVectorsInScopeNote(scope, disarmed: nil,
                                                     folders: ["M2SU"]),
                     "aucune phrase quand le sens a bien servi")
        // MÊME TEXTE QUE LA LIGNE DE COMMANDE, et c'est la même fonction depuis
        // le lot MN1 : le serveur n'en garde que la garde.
        XCTAssertEqual(note, SemanticDisarmReason.noVectorsInScopeNote(
            scope, folders: ["M2SU"]))
        XCTAssertEqual(SemanticDisarmReason.noVectorsInScope.rawValue,
                       "no_vectors_in_scope")
    }

    // MARK: - La description (PM-29, PM-30)

    func testLaDescriptionDitToutTeLaSyntaxeEtLaReserveDeCitation() throws {
        let tool = SearchTool(store: ReadOnlyStore(path: URL(fileURLWithPath: "/x")),
                              semantic: SemanticEngine(
                                store: ReadOnlyStore(path: URL(fileURLWithPath: "/x")),
                                modelDirectory: URL(fileURLWithPath: "/x")))
        for fragment in ["nom:X", "texte:X", "chemin:X", "-dossier:", "-ext:",
                         "-nom:", "-chemin:", "pres:5", "slide", "time_seconds"] {
            XCTAssertTrue(tool.description.contains(fragment),
                          "la description tait \(fragment) — un modèle ne lit "
                          + "que `tools/list`")
        }
    }

    // MARK: - La page qu'on LIT avant de la citer (lot MC4)

    /// `fouine_read_page` porte les mêmes réserves que la recherche, et c'est
    /// là qu'elles comptent le plus : c'est la page que le modèle a sous les
    /// yeux au moment d'écrire sa phrase.
    private func readPage(_ index: TempIndex, _ arguments: String) throws
        -> [String: Any] {
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_read_page","arguments":\#(arguments)}}"#.utf8)))
        let object = try JSONMatch.object(response)
        XCTAssertNil(object["error"], "\(object)")
        return try XCTUnwrap((object["result"] as? [String: Any])?["structuredContent"]
            as? [String: Any])
    }

    func testLireUneDiapositiveDitQueCEnEstUne() throws {
        let fixture = try mixedIndex()
        let slide = try readPage(fixture.index,
                                 #"{"doc_id":\#(fixture.deck),"page":2}"#)
        XCTAssertEqual(slide["slide"] as? Int, 2)
        XCTAssertTrue(slide["embedded_image"] is NSNull)
        // La clé est là même quand elle n'a rien à dire.
        XCTAssertTrue(slide["time_seconds"] is NSNull)
        XCTAssertTrue(slide["page_label"] is NSNull)

        // Page 3 : au-delà des deux diapositives, c'est une image incorporée —
        // « page 3 » désignerait quelque chose que personne ne retrouvera en
        // feuilletant le diaporama.
        let picture = try readPage(fixture.index,
                                   #"{"doc_id":\#(fixture.deck),"page":3}"#)
        XCTAssertTrue(picture["slide"] is NSNull)
        XCTAssertEqual(picture["embedded_image"] as? Int, 1)
    }

    func testLireUneTranscriptionDonneSonMomentEtUnLienHorodate() throws {
        let fixture = try mixedIndex()
        let page = try readPage(fixture.index,
                                #"{"doc_id":\#(fixture.video),"page":1}"#)
        // Le PREMIER marqueur du texte rendu : il n'y a pas d'extrait ici qui
        // désignerait un paragraphe plus loin, la page commence à son début.
        XCTAssertEqual(page["time_seconds"] as? Int, 1)
        XCTAssertTrue((page["link"] as? String ?? "").contains("&t=1"),
                      "le lien doit porter le moment : \(page["link"] ?? "")")
    }

    /// Les clés d'avant ne bougent pas d'un caractère : la bascule sur
    /// `PageReading` (lot MC4) est un partage d'implémentation, pas un nouveau
    /// contrat.
    func testLesClesDeLaLectureRestentCellesDAvant() throws {
        let fixture = try mixedIndex()
        let page = try readPage(fixture.index,
                                #"{"doc_id":\#(fixture.deck),"page":2}"#)
        for key in ["doc_id", "page", "path", "abs_path", "folder", "ext", "link",
                    "page_count", "text", "chars", "total_chars", "truncated",
                    "next_offset", "source", "engine", "ocr_confidence", "note"] {
            XCTAssertTrue(page.keys.contains(key), "clé perdue : \(key)")
        }
        XCTAssertEqual(page["page_count"] as? Int, 4)
        XCTAssertEqual(page["source"] as? String, "native")
    }
}
