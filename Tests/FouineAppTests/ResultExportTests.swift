// ResultExportTests.swift — l'export Markdown et « Copier toutes les
// références » (PR-19). Propriété : A-App.
//
// Les lignes Markdown sont comparées OCTET POUR OCTET : c'est un format que
// d'autres logiciels relisent, et une espace de plus autour du tiret casse la
// liste à puces d'un carnet sans que rien ne le dise.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class ResultExportTests: XCTestCase {

    private var live: [TempAppDB] = []

    override func setUp() {
        super.setUp()
        _ = TestPrefs.isolate
        Prefs.defaults.removeObject(forKey: Prefs.sortOrder)
    }

    override func tearDown() {
        live.removeAll()
        super.tearDown()
    }

    private func makeAppDB() throws -> TempAppDB {
        let db = try TempAppDB()
        live.append(db)
        return db
    }

    /// Une ligne d'export fabriquée à la main : la mise en forme Markdown se
    /// vérifie sans base ni requête, et c'est elle qu'on veut voir.
    private func row(path: String, page: Int, snippet: String,
                     link: String) -> ResultExport.Row {
        ResultExport.Row(path: path, page: page, score: -1, snippet: snippet,
                         rootLabel: "Essai", modified: nil, link: link)
    }

    private func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    // MARK: - Markdown (PR-19)

    func testMarkdownEstUnTitrePuisUneLigneParPage() throws {
        let rows = [
            row(path: "Users/essai/a.txt", page: 1, snippet: "premier extrait",
                link: "fouine://open?doc=1&page=1"),
            row(path: "Users/essai/b.txt", page: 7, snippet: "deuxième extrait",
                link: "fouine://open?doc=2&page=7"),
            row(path: "Users/essai/b.txt", page: 9, snippet: "",
                link: "fouine://open?doc=2&page=9"),
        ]
        let sortie = lines(try ResultExport.data(rows, format: .markdown,
                                                query: "alpha"))
        // Langue de BASE dans les tests : hors de Fouine.app, le catalogue rend
        // la clé anglaise (même raison que `testResumeDExportDitLeJeuCharge`).
        XCTAssertEqual(sortie[0], "# Fouine — alpha (3 results)")
        XCTAssertEqual(sortie[1], "", "une ligne vide, puis la liste")
        XCTAssertEqual(sortie[2],
                       "- [a.txt, page 1](fouine://open?doc=1&page=1) — premier extrait")
        XCTAssertEqual(sortie[3],
                       "- [b.txt, page 7](fouine://open?doc=2&page=7) — deuxième extrait")
        // Sans extrait, pas de tiret qui pende : une page trouvée par le sens
        // seul n'a pas de `snippet()`.
        XCTAssertEqual(sortie[4], "- [b.txt, page 9](fouine://open?doc=2&page=9)")
        XCTAssertEqual(sortie.last, "", "le fichier se termine par un saut de ligne")
    }

    /// Un extrait long ferait un mur de texte où les références se perdent.
    func testMarkdownTronqueLExtraitA200Caracteres() throws {
        let long = String(repeating: "a", count: 500)
        let sortie = lines(try ResultExport.data(
            [row(path: "Users/essai/a.txt", page: 1, snippet: long,
                 link: "fouine://open?doc=1&page=1")],
            format: .markdown, query: "a"))
        let extrait = try XCTUnwrap(sortie[2].components(separatedBy: " — ").last)
        XCTAssertEqual(extrait.count, ResultExport.snippetLimit + 1)
        XCTAssertTrue(extrait.hasSuffix("…"))
    }

    /// Les parenthèses d'un nom de fichier cassent DEUX fois un lien Markdown :
    /// le détecteur d'adresses, puis la syntaxe `[…](…)` elle-même (AP-26).
    func testMarkdownEchappeLesParenthesesDuLien() throws {
        let sortie = lines(try ResultExport.data(
            [row(path: "Users/essai/cristallographie (2003).pdf", page: 12,
                 snippet: "extrait",
                 link: "fouine://open?path=/Users/essai/cristallographie (2003).pdf&page=12")],
            format: .markdown, query: "cristal"))
        // Le LIEN, c'est-à-dire ce qui est entre « ]( » et la parenthèse
        // fermante — la seule qui reste, justement parce que les autres sont
        // échappées.
        let apres = try XCTUnwrap(sortie[2].components(separatedBy: "](").last)
        let lien = try XCTUnwrap(apres.components(separatedBy: ")").first)
        XCTAssertTrue(lien.contains("%282003%29"), lien)
        XCTAssertFalse(lien.contains("(2003)"), "les parenthèses du LIEN")
        XCTAssertTrue(sortie[2].hasPrefix("- [cristallographie (2003).pdf, page 12]("),
                      "celles du NOM affiché restent : elles ne cassent rien")
    }

    func testMarkdownSEcritEnPointMD() {
        XCTAssertEqual(ResultExport.Format.markdown.fileExtension, "md")
        XCTAssertEqual(ResultExport.suggestedName(query: "alpha beta",
                                                  format: .markdown),
                       "fouine-alpha-beta.md")
    }

    /// L'export suit l'ORDRE AFFICHÉ, tri compris — comme le CSV et le JSON.
    func testMarkdownSuitLOrdreAffiche() async throws {
        let db = try makeAppDB()
        let zebre = try db.addDoc(relPath: "Users/essai/zebre.txt",
                                  pages: ["alpha chez le zèbre"])
        let abeille = try db.addDoc(relPath: "Users/essai/abeille.txt",
                                    pages: ["alpha chez l'abeille"])
        let model = SearchModel(service: db.service)
        await run(model, "alpha")
        model.sortOrder = .title
        let sortie = lines(try ResultExport.data(model.exportRows,
                                                 format: .markdown,
                                                 query: "alpha"))
        XCTAssertTrue(sortie[2].hasPrefix("- [abeille.txt, page 1](fouine://open?doc=\(abeille)&page=1)"),
                      sortie[2])
        XCTAssertTrue(sortie[3].hasPrefix("- [zebre.txt, page 1](fouine://open?doc=\(zebre)&page=1)"),
                      sortie[3])
    }

    // MARK: - Copier toutes les références (PR-19)

    /// La même chaîne que « Copier la référence », une par résultat : un carnet
    /// et un presse-papiers qui nommeraient la page autrement obligeraient à
    /// vérifier lequel a raison.
    func testCopierToutesLesReferences() async throws {
        let db = try makeAppDB()
        let a = try db.addDoc(relPath: "Users/essai/a.txt",
                              pages: ["alpha un", "alpha deux"])
        let model = SearchModel(service: db.service)
        await run(model, "alpha")
        XCTAssertTrue(model.canExport)
        XCTAssertEqual(model.allReferences, """
        a.txt, page 1
        fouine://open?doc=\(a)&page=1
        a.txt, page 2
        fouine://open?doc=\(a)&page=2
        """)
        // Une référence isolée reste identique : c'est la même fabrique.
        XCTAssertEqual(model.pageReference(docID: a, page: 1,
                                           path: "Users/essai/a.txt"),
                       "a.txt, page 1\nfouine://open?doc=\(a)&page=1")
    }

    /// Sans résultat, il n'y a rien à copier — et l'élément de menu est
    /// désactivé par la même propriété que l'export.
    func testSansResultatIlNyARienACopier() async throws {
        let db = try makeAppDB()
        try db.addDoc(relPath: "Users/essai/a.txt", pages: ["alpha"])
        let model = SearchModel(service: db.service)
        await run(model, "introuvable")
        XCTAssertFalse(model.canExport)
        XCTAssertEqual(model.allReferences, "")
    }
}
