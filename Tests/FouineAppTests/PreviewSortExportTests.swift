// PreviewSortExportTests.swift — aperçu texte, tri, export, comptes honnêtes.
// Propriété : A-App. Audit U4 et A12.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class PreviewSortExportTests: XCTestCase {

    /// Les bases jetables sont RETENUES jusqu'à la fin du test : leur `deinit`
    /// efface le dossier, et un `let (_, model) = fixture()` la libérerait
    /// aussitôt — le modèle interrogerait alors une base effacée sous ses pieds.
    private var live: [TempAppDB] = []

    private func makeAppDB() throws -> TempAppDB {
        let db = try TempAppDB()
        live.append(db)
        return db
    }

    /// Domaine de préférences jetable par processus (`TestPrefs`) : chaque test
    /// part d'une préférence de tri absente — sans quoi le tri posé par le test
    /// précédent serait relu par le `SearchModel` du suivant — et rien n'est
    /// écrit dans les préférences de l'utilisateur.
    override func setUp() {
        super.setUp()
        _ = TestPrefs.isolate
        Prefs.defaults.removeObject(forKey: Prefs.sortOrder)
    }

    override func tearDown() {
        live.removeAll()
        super.tearDown()
    }

    // MARK: - Aperçu texte depuis la base (U4)

    /// Le texte d'une page doit sortir de `page_fts`, sans toucher au fichier :
    /// c'est ce qui rend l'aperçu possible pour txt/md/html/epub/docx/rtf/djvu,
    /// et ce qui le rend possible même sans le fichier.
    func testTexteDePageLuEnBase() throws {
        let db = try makeAppDB()
        let id = try db.addDoc(relPath: "Users/essai/notes.md", ext: "md",
                               pages: ["Première page : alpha.",
                                       "Deuxième page : beta.",
                                       "Troisième page : gamma."])
        XCTAssertEqual(try db.store.pageText(docID: id, page: 2),
                       "Deuxième page : beta.")
        XCTAssertEqual(try db.store.textPages(docID: id), [1, 2, 3])
        XCTAssertNil(try db.store.pageText(docID: id, page: 9),
                     "une page absente ne rend rien, elle n'invente pas")
        XCTAssertEqual(try db.store.textPages(docID: 999), [],
                       "document inconnu : aucune page, pas d'erreur")
    }

    /// Les pages VIDES ne sont pas proposées à la navigation : y aller
    /// n'afficherait rien.
    func testNavigationSauteLesPagesSansTexte() throws {
        let db = try makeAppDB()
        let id = try db.store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Users/essai/scan.djvu", ext: "djvu",
            topFolder: "Essai", size: 10, mtime: 1_700_000_000, nPages: 5,
            state: .extracted))
        // Pages 2 et 4 seulement : 1, 3 et 5 attendent encore l'OCR.
        try db.store.replacePages(docID: id, pages: [
            PageText(page: 2, text: "texte de la page deux", source: .ocrAccurate),
            PageText(page: 4, text: "texte de la page quatre", source: .ocrAccurate),
        ])
        XCTAssertEqual(try db.store.textPages(docID: id), [2, 4])
    }

    // MARK: - Surlignage du texte complet (U4)

    func testSurlignageDuTexteComplet() {
        let terms = QueryTerms.extract(from: "alpha beta")
        let out = TextHighlighter.attributed(
            "un alpha, deux BETA, trois Alpha, quatre gamma",
            terms: terms, monospaced: false)
        XCTAssertFalse(out.truncated)
        XCTAssertFalse(out.capped)
        XCTAssertEqual(out.occurrences, 3, "casse ignorée, comme le tokenizer")
        XCTAssertEqual(String(out.text.characters),
                       "un alpha, deux BETA, trois Alpha, quatre gamma",
                       "le texte rendu est le texte d'origine, à l'attribut près")
    }

    func testSurlignageIgnoreLesAccentsCommeLeTokenizer() {
        let terms = QueryTerms.extract(from: "polymere")
        let out = TextHighlighter.attributed("Le polymère est une macromolécule.",
                                             terms: terms, monospaced: false)
        XCTAssertEqual(out.occurrences, 1)
    }

    /// Un préfixe surligne le MOT entier, pas sa seule racine.
    func testSurlignageDunPrefixeCouvreLeMot() {
        let terms = QueryTerms.extract(from: "spectro*")
        let out = TextHighlighter.attributed("la spectroscopie et le spectrographe",
                                             terms: terms, monospaced: false)
        XCTAssertEqual(out.occurrences, 2)
        // Les plages couvrent bien les mots complets : le texte rendu est
        // intact et deux passages sont marqués.
        let marked = out.text.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(marked.count, 2)
        XCTAssertEqual(marked.map { String(out.text[$0.range].characters) },
                       ["spectroscopie", "spectrographe"])
    }

    /// Deux termes qui se recouvrent ne produisent pas de plages imbriquées.
    func testSurlignageSansChevauchement() {
        let terms = QueryTerms.extract(from: "poly polymere")
        let out = TextHighlighter.attributed("le polymere", terms: terms,
                                             monospaced: false)
        XCTAssertEqual(String(out.text.characters), "le polymere")
        XCTAssertEqual(out.occurrences, 1)
    }

    // MARK: - A2-17 : le surlignage compte des JETONS, pas des sous-chaînes

    /// « or » ne se surligne pas dans « sort », « pour » ni « corps ».
    ///
    /// La recherche compte des jetons FTS5 ; le surlignage cherchait des
    /// sous-chaînes (`text.range(of:)`). Un terme de trois lettres marquait donc
    /// l'intérieur des mots, en couleur, là où le moteur n'avait rien trouvé —
    /// et c'est ce que le plafond de 400 occurrences par terme essayait de
    /// contenir.
    func testSurlignageNeMordPasDansLesMots() {
        let terms = QueryTerms.extract(from: "or")
        let out = TextHighlighter.attributed(
            "il sort pour le corps d'or, or il l'a dit",
            terms: terms, monospaced: false)
        XCTAssertEqual(out.occurrences, 2,
                       "seuls le « or » de « d'or » — l'apostrophe est une "
                       + "frontière pour le tokenizer — et le « or » isolé")
        let marked = out.text.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(marked.map { String(out.text[$0.range].characters) },
                       ["or", "or"])
    }

    /// La règle vaut aussi pour une phrase, et un PRÉFIXE garde le droit de
    /// mordre sur la suite du mot — c'est sa raison d'être.
    func testSurlignagePhraseEtPrefixe() {
        let phrase = TextHighlighter.attributed(
            "un gaz parfaitement sec, et un gaz parfait",
            terms: QueryTerms.extract(from: "\"gaz parfait\""), monospaced: false)
        XCTAssertEqual(phrase.occurrences, 1, "« gaz parfaitement » n'est pas le jeton")

        let prefix = TextHighlighter.attributed(
            "la spectroscopie", terms: QueryTerms.extract(from: "spectro*"),
            monospaced: false)
        XCTAssertEqual(prefix.occurrences, 1)
    }

    /// Une ligne OCR se surligne selon la même règle (`QueryTerms.matchInText`,
    /// qui décide de la boîte à dessiner sur la page).
    func testLigneOCRSurlignéeSurUnJetonSeulement() {
        let terms = QueryTerms.extract(from: "or")
        XCTAssertNil(QueryTerms.matchInText("il sort du corps", terms: terms))
        XCTAssertNotNil(QueryTerms.matchInText("l'or et l'argent", terms: terms))
        XCTAssertNotNil(QueryTerms.matchInText(
            "la spectroscopie", terms: QueryTerms.extract(from: "spectro*")))
    }

    /// Une page immense est coupée, et le DIT (jamais de troncature muette).
    func testTexteTronqueEstAnnonce() {
        let long = String(repeating: "a", count: TextHighlighter.maxCharacters + 500)
        let out = TextHighlighter.attributed(long, terms: [], monospaced: true)
        XCTAssertTrue(out.truncated)
        XCTAssertEqual(out.text.characters.count, TextHighlighter.maxCharacters)
    }

    // MARK: - Tri (U4)

    private func triFixture() throws -> (TempAppDB, SearchModel) {
        let db = try makeAppDB()
        // Trois documents : ordre de pertinence, de date, de nom et de chemin
        // volontairement TOUS différents.
        try db.addDoc(relPath: "Users/essai/zebre.txt", mtime: 1_500_000_000,
                      pages: ["alpha alpha alpha alpha : le plus pertinent."])
        try db.addDoc(relPath: "Users/essai/abeille.txt", mtime: 1_900_000_000,
                      pages: ["alpha : le plus récent."])
        try db.addDoc(relPath: "Users/autre/mouette.txt", folder: "Autre",
                      mtime: 1_700_000_000, pages: ["alpha : entre les deux."])
        return (db, SearchModel(service: db.service))
    }

    func testTriParDate() async throws {
        let (_, model) = try triFixture()
        await run(model, "alpha")
        model.sortOrder = .dateDesc
        XCTAssertEqual(model.groups.map { ($0.path as NSString).lastPathComponent },
                       ["abeille.txt", "mouette.txt", "zebre.txt"])
        model.sortOrder = .dateAsc
        XCTAssertEqual(model.groups.map { ($0.path as NSString).lastPathComponent },
                       ["zebre.txt", "mouette.txt", "abeille.txt"])
    }

    func testTriParNomEtParChemin() async throws {
        let (_, model) = try triFixture()
        await run(model, "alpha")
        model.sortOrder = .title
        XCTAssertEqual(model.groups.map { ($0.path as NSString).lastPathComponent },
                       ["abeille.txt", "mouette.txt", "zebre.txt"])
        model.sortOrder = .path
        XCTAssertEqual(model.groups.map(\.path).map {
            ($0 as NSString).deletingLastPathComponent
        }, ["Users/autre", "Users/essai", "Users/essai"],
                       "« autre » avant « essai » : tri sur le chemin entier")
    }

    /// Le tri ne change pas la requête et ne perd aucun résultat ; il ne casse
    /// pas non plus le regroupement par document.
    func testTriPreserveLesGroupesEtLeJeu() async throws {
        let db = try makeAppDB()
        try db.addDoc(relPath: "Users/essai/a.txt", mtime: 1_900_000_000,
                      pages: ["alpha un", "alpha deux", "alpha trois"])
        try db.addDoc(relPath: "Users/essai/b.txt", mtime: 1_500_000_000,
                      pages: ["alpha quatre"])
        let model = SearchModel(service: db.service)
        await run(model, "alpha")
        let avant = model.groups.count
        let pagesAvant = model.groups.reduce(0) { $0 + $1.hits.count }
        model.sortOrder = .dateAsc
        XCTAssertEqual(model.groups.count, avant)
        XCTAssertEqual(model.groups.reduce(0) { $0 + $1.hits.count }, pagesAvant)
        XCTAssertEqual(model.groups.first?.hits.map(\.page), [1],
                       "b.txt, le plus ancien, en tête")
        XCTAssertEqual(model.groups.last?.hits.map(\.page), [1, 2, 3],
                       "les pages d'un document restent dans l'ordre")
    }

    /// La préférence de tri est persistée et relue.
    func testTriPersiste() async throws {
        let (db, model) = try triFixture()
        XCTAssertEqual(model.sortOrder, .score, "défaut : le tri du moteur")
        model.sortOrder = .title
        XCTAssertEqual(Prefs.defaults.string(forKey: Prefs.sortOrder), "title")
        let relu = SearchModel(service: db.service)
        XCTAssertEqual(relu.sortOrder, .title)
    }

    /// Un tri sur un jeu partiel doit être ANNONCÉ comme tel.
    func testTriPartielEstSignale() async throws {
        let db = try makeAppDB()
        for i in 0..<(SearchModel.pageSize + 10) {
            try db.addDoc(relPath: "Users/essai/d\(i).txt",
                          pages: ["alpha numéro \(i)"])
        }
        let model = SearchModel(service: db.service)
        await run(model, "alpha")
        XCTAssertTrue(model.canLoadMore)
        XCTAssertFalse(model.sortIsPartial, "le tri par pertinence est celui du moteur")
        model.sortOrder = .title
        XCTAssertTrue(model.sortIsPartial)
    }

    // MARK: - Export (U4)

    func testExportCSV() async throws {
        let (_, model) = try triFixture()
        await run(model, "alpha")
        model.sortOrder = .title
        let data = try ResultExport.data(model.exportRows, format: .csv,
                                         query: "alpha")
        let texte = String(decoding: data, as: UTF8.self)
        // En-têtes ANGLAIS et stables : un export est de la donnée, pas de
        // l'interface (palier 3.2, `ResultExport.columns`).
        XCTAssertTrue(texte.hasPrefix("\u{FEFF}path,page,score,snippet,root,modified,link"),
                      "BOM UTF-8 puis l'en-tête : sinon Excel lit en latin-1")
        let lignes = texte.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lignes.count, 4, "un en-tête et trois résultats")
        XCTAssertTrue(lignes[1].contains("abeille.txt"),
                      "l'export suit l'ordre affiché")
        XCTAssertFalse(texte.contains("«"), "les marqueurs du snippet ne sortent pas")
        XCTAssertTrue(lignes[1].contains("\"Essai\""), "étiquette de racine")
    }

    /// Un chemin qui contient une virgule ou un guillemet ne doit pas décaler
    /// les colonnes.
    func testExportCSVEchappeLesChampsPiegeux() async throws {
        let db = try makeAppDB()
        try db.addDoc(relPath: "Users/essai/a, b \"c\".txt", pages: ["alpha"])
        let model = SearchModel(service: db.service)
        await run(model, "alpha")
        let texte = String(decoding: try ResultExport.data(model.exportRows,
                                                           format: .csv,
                                                           query: "alpha"),
                           as: UTF8.self)
        XCTAssertTrue(texte.contains("\"Users/essai/a, b \"\"c\"\".txt\""),
                      "RFC 4180 : guillemets doublés, champ encadré")
    }

    func testExportJSON() async throws {
        let (_, model) = try triFixture()
        await run(model, "alpha")
        let data = try ResultExport.data(model.exportRows, format: .json,
                                         query: "alpha")
        let objet = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(objet["query"] as? String, "alpha")
        XCTAssertEqual(objet["count"] as? Int, 3)
        let resultats = try XCTUnwrap(objet["results"] as? [[String: Any]])
        XCTAssertEqual(resultats.count, 3)
        let premier = resultats[0]
        for cle in ["path", "page", "score", "snippet", "root", "modified", "link"] {
            XCTAssertNotNil(premier[cle], "champ « \(cle) » attendu")
        }
        XCTAssertEqual(premier["root"] as? String, "Essai")
    }

    /// La colonne `link` (lot INT-L1) : un export sert à citer, et une ligne
    /// qui dit où regarder sans y ramener oblige à retrouver la page à la
    /// main. Le volume de la base jetable n'est pas monté : c'est donc la
    /// forme de repli `doc` qui sort, exactement comme sur un disque externe
    /// débranché.
    func testExportCarrieALinkBackToEachPage() async throws {
        let (_, model) = try triFixture()
        await run(model, "alpha")
        let ligne = try XCTUnwrap(model.exportRows.first)
        XCTAssertTrue(ligne.link.hasPrefix("fouine://open?"), ligne.link)
        XCTAssertTrue(ligne.link.contains("page=\(ligne.page)"), ligne.link)
        // Et le lien se relit : c'est tout ce qu'on lui demande.
        let relu = try XCTUnwrap(DeepLink(url: XCTUnwrap(URL(string: ligne.link))))
        guard case .open(_, let page, _, _) = relu else {
            return XCTFail("le lien exporté doit ouvrir une page")
        }
        XCTAssertEqual(page, ligne.page)
    }

    /// Ce que le panneau annonce doit correspondre à ce qui part.
    func testResumeDExportDitLeJeuCharge() async throws {
        let db = try makeAppDB()
        let total = SearchModel.pageSize + 30
        for i in 0..<total {
            try db.addDoc(relPath: "Users/essai/d\(i).txt", pages: ["alpha \(i)"])
        }
        let model = SearchModel(service: db.service)
        await run(model, "alpha")
        XCTAssertEqual(model.exportRows.count, SearchModel.pageSize)
        // Langue de BASE dans les tests : `Bundle.main` n'a pas de .lproj
        // hors de Fouine.app, le catalogue rend donc la clé anglaise.
        XCTAssertTrue(model.exportSummary.contains("currently loaded"),
                      model.exportSummary)
        XCTAssertTrue(model.exportSummary.contains(Format.integer(total)),
                      "le panneau dit sur quel total porte la troncature")
        XCTAssertTrue(model.canExport)
    }

    func testNomDeFichierPropose() {
        XCTAssertEqual(
            ResultExport.suggestedName(query: "alpha -beta \"gaz parfait\"",
                                       format: .csv),
            "fouine-alpha-beta-gaz-parfait.csv")
        // Le repli passe par le catalogue depuis l'audit B1-29 b ; hors de
        // Fouine.app, `String(localized:)` rend la CLÉ, donc l'anglais source.
        XCTAssertEqual(ResultExport.suggestedName(query: "***", format: .json),
                       "fouine-results.json")
    }

    // MARK: - Comptes honnêtes (A12)

    /// `DocGroup.pageCount` ne compte que les hits reçus : le vrai nombre de
    /// pages touchées vient d'une requête de comptage.
    func testComptePagesToucheesParDocument() async throws {
        let db = try makeAppDB()
        let gros = try db.addDoc(
            relPath: "Users/essai/gros.txt",
            pages: (1...300).map { "alpha, page \($0)" })
        let petit = try db.addDoc(relPath: "Users/essai/petit.txt",
                                  pages: ["alpha, page unique"])
        let plan = try QueryParser.searchPlan("alpha", limit: SearchModel.pageSize)
        let counts = try db.store.matchedPageCounts(
            plan.query, excludingDocsMatching: plan.negative)
        XCTAssertEqual(counts[gros], 300)
        XCTAssertEqual(counts[petit], 1)

        let model = SearchModel(service: db.service)
        await run(model, "alpha")
        let groupe = try XCTUnwrap(model.groups.first { $0.docID == gros })
        // Depuis le lot R1, un document ne prend pas tout l'écran : la page du
        // petit document entre dans la première tranche, et le gros n'y a donc
        // pas ses 300 pages. La PROPRIÉTÉ, pas la place exacte (AUDIT-R1 I5) :
        // la tranche est pleine, le petit y est, le gros a le reste.
        let charges = model.groups.reduce(0) { $0 + $1.hits.count }
        XCTAssertEqual(charges, SearchModel.pageSize, "la première tranche est pleine")
        XCTAssertNotNil(model.groups.first { $0.docID == petit },
                        "R1 : le petit document est visible dès la première tranche")
        XCTAssertEqual(groupe.hits.count, SearchModel.pageSize - 1,
                       "le gros document a toute la tranche moins la page du petit")
        XCTAssertGreaterThanOrEqual(groupe.hits.count, Schema.diversityFullStrengthPages)
        XCTAssertEqual(groupe.matchedPageCount, 300,
                       "A12 : le compte annoncé est celui des pages touchées")
    }

    /// Le comptage honore les exclusions, comme la recherche.
    func testComptePagesRespecteLesExclusions() throws {
        let db = try makeAppDB()
        let garde = try db.addDoc(relPath: "Users/essai/garde.txt",
                                  pages: ["alpha un", "alpha deux"])
        let exclu = try db.addDoc(relPath: "Users/essai/exclu.txt",
                                  pages: ["alpha trois", "beta quatre"])
        let plan = try QueryParser.searchPlan("alpha -beta")
        let counts = try db.store.matchedPageCounts(
            plan.query, excludingDocsMatching: plan.negative)
        XCTAssertEqual(counts[garde], 2)
        XCTAssertNil(counts[exclu], "le document exclu n'est pas compté")
    }
}

/// A2-16 — l'export ne mange plus les vrais guillemets français.
///
/// `snippet(page_fts, 0, '«', '»', …)` emploie comme marqueurs deux caractères
/// qui sont AUSSI la ponctuation courante du français. L'export les retirait
/// tous les deux à l'aveugle : `Il dit « bonjour »` ressortait `Il dit  bonjour `.
/// Sur un corpus francophone, c'était systématique — et à l'export,
/// contrairement à l'affichage, rien ne remplace les guillemets retirés.
final class SnippetGuillemetsTests: XCTestCase {

    /// Un marqueur de FTS5 encadre un JETON : pas d'espace à l'intérieur.
    func testMarkersAreStrippedAndTheTextKeepsItsQuotes() {
        XCTAssertEqual(
            ResultExport.plainSnippet("la «cinétique» des gaz"),
            "la cinétique des gaz")
        XCTAssertEqual(
            ResultExport.plainSnippet("Il dit « bonjour » à la «cinétique»"),
            "Il dit « bonjour » à la cinétique",
            "A2-16 : les vrais guillemets survivent, le marqueur part")
    }

    /// Un extrait sans un seul marqueur — le cas d'un hit sémantique pur —
    /// ressort intact.
    func testAPurelyTypographicSnippetIsUntouched() {
        let text = "L'auteur écrit : « la chaleur n'est pas une substance »."
        XCTAssertEqual(ResultExport.plainSnippet(text), text)
    }

    /// Le parseur d'affichage rend les mêmes segments : c'est la même règle,
    /// et il n'y en a qu'une dans le dépôt.
    func testTheDisplayParserAgrees() {
        let segments = SnippetParser.segments("Il dit « bonjour » à la «cinétique»")
        XCTAssertEqual(segments.filter(\.marked).map(\.text), ["cinétique"])
        XCTAssertEqual(segments.map(\.text).joined(),
                       "Il dit « bonjour » à la cinétique")
    }

    /// Un guillemet ORPHELIN (l'extrait est coupé au milieu d'une citation)
    /// reste du texte : il ne fait pas basculer la moitié de l'extrait en
    /// surligné.
    func testAnOrphanQuoteIsNotAMarker() {
        let segments = SnippetParser.segments("…une substance » disait-il")
        XCTAssertTrue(segments.allSatisfy { !$0.marked })
        XCTAssertEqual(segments.map(\.text).joined(), "…une substance » disait-il")
    }

    /// Les retours à la ligne et les tabulations sont toujours repliés : une
    /// cellule CSV multiligne se lit mal partout.
    func testNewlinesAreStillFolded() {
        XCTAssertEqual(
            ResultExport.plainSnippet("une «page»\r\net\tla suite  "),
            "une page et la suite")
    }
}

