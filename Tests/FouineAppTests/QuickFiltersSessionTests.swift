// QuickFiltersSessionTests.swift — puces de filtre, facette « Langue » et
// « reprendre où j'en étais ». Propriété : A-App. Lot U2 (R-07, R-10, R-11).
//
// Les vues SwiftUI ne se testent pas : ce qui est vérifié ici est l'ÉTAT du
// modèle que les puces manipulent, et le contenu de ce que Fouine rouvrira.

import XCTest
import FouineCore
@testable import FouineApp

@MainActor
final class QuickFiltersSessionTests: XCTestCase {

    private var live: [TempAppDB] = []

    /// Domaine de préférences jetable par processus (`TestPrefs`) : chaque test
    /// part d'une mémoire vide, et rien n'est écrit dans les préférences de
    /// l'utilisateur.
    override func setUp() {
        super.setUp()
        _ = TestPrefs.isolate
        Prefs.defaults.removeObject(forKey: Prefs.lastSession)
    }

    override func tearDown() {
        live.removeAll()
        super.tearDown()
    }

    /// Deux documents français, un anglais ; un vieux, deux récents.
    private func fixture() throws -> (db: TempAppDB, model: SearchModel,
                                      fr: Int64, en: Int64) {
        let db = try TempAppDB()
        live.append(db)
        let vieux = DateWindow.startOfYear(Date(), yearsBack: 20)!
        let recent = DateWindow.startOfYear(Date())! + 3_600
        let fr = try db.addDoc(relPath: "Users/a/Essai/cours.pdf", ext: "pdf",
                               mtime: recent, lang: "fr",
                               pages: ["enthalpie libre du système."])
        let en = try db.addDoc(relPath: "Users/a/Essai/course.txt", ext: "txt",
                               mtime: vieux, lang: "en",
                               pages: ["enthalpie of formation."])
        _ = try db.addDoc(relPath: "Users/a/Essai/notes.md", ext: "md",
                          mtime: recent, lang: nil,
                          pages: ["enthalpie ?"])
        return (db, SearchModel(service: db.service), fr, en)
    }

    // MARK: - Puces (R-07)

    func testPucePDFPiloteLeFiltreDExtension() async throws {
        let f = try fixture()
        await run(f.model, "enthalpie")
        XCTAssertFalse(f.model.pdfOnly)
        f.model.togglePDFOnly()
        await settle(f.model)
        XCTAssertEqual(f.model.selectedExts, ["pdf"])
        XCTAssertTrue(f.model.pdfOnly)
        XCTAssertEqual(f.model.hits.map(\.docID), [f.fr],
                       "vraie requête : le jeu de résultats change, pas seulement l'affichage")
        XCTAssertEqual(f.model.totalPages, 1, "et le total annoncé avec lui")
        f.model.togglePDFOnly()
        await settle(f.model)
        XCTAssertTrue(f.model.selectedExts.isEmpty, "une puce active se désactive d'un clic")
        XCTAssertEqual(f.model.totalPages, 3)
    }

    /// Cocher une autre extension dans la facette désarme la puce : elle dit
    /// « seulement », et ce ne serait plus vrai.
    func testPucePDFSeDesarmeSiUneAutreExtensionEstCochee() async throws {
        let f = try fixture()
        await run(f.model, "enthalpie")
        f.model.togglePDFOnly()
        await settle(f.model)
        f.model.selectedExts.insert("txt")
        await settle(f.model)
        XCTAssertFalse(f.model.pdfOnly)
    }

    func testPucesDeDateFiltrentSurLaDateDuDocument() async throws {
        let f = try fixture()
        await run(f.model, "enthalpie")
        XCTAssertEqual(f.model.totalPages, 3)
        f.model.toggleDate(.thisYear)
        await settle(f.model)
        XCTAssertEqual(f.model.totalPages, 2,
                       "le document d'il y a vingt ans sort du jeu, totaux compris")
        XCTAssertFalse(f.model.hits.contains { $0.docID == f.en })
        // Une puce exclut l'autre : ce sont deux fenêtres de la même dimension.
        f.model.toggleDate(.lastFiveYears)
        await settle(f.model)
        XCTAssertEqual(f.model.dateFilter, .lastFiveYears)
        f.model.toggleDate(.lastFiveYears)
        await settle(f.model)
        XCTAssertEqual(f.model.dateFilter, .any)
        XCTAssertEqual(f.model.totalPages, 3)
    }

    /// « Pages scannées seulement » est une VRAIE requête depuis le lot P3 :
    /// les totaux la suivent, et elle ne se contente plus de cacher des pages
    /// déjà chargées.
    func testPucePagesScanneesEstUneVraieRequete() async throws {
        let f = try fixture()
        let scan = try f.db.addDoc(relPath: "Users/a/Essai/photocopie.pdf",
                                   ext: "pdf",
                                   pages: ["enthalpie recopiée."],
                                   sources: [.ocrAccurate])
        await run(f.model, "enthalpie")
        XCTAssertEqual(f.model.totalPages, 4)
        f.model.toggleScannedOnly()
        await settle(f.model)
        XCTAssertEqual(f.model.selectedSources, SearchModel.scannedSources)
        XCTAssertTrue(f.model.scannedOnly)
        XCTAssertEqual(f.model.hits.map(\.docID), [scan],
                       "le moteur a été resollicité : seule la page scannée reste")
        XCTAssertEqual(f.model.totalPages, 1, "et le total annoncé la suit")
        XCTAssertFalse(f.model.hasDisplayFilters,
                       "la provenance n'est plus un filtre d'affichage : "
                       + "la ligne « Charger plus » n'a plus à s'en excuser")
        f.model.toggleScannedOnly()
        await settle(f.model)
        XCTAssertEqual(f.model.totalPages, 4, "une puce active se désactive d'un clic")
    }

    /// La facette « Origine du texte » relance la requête elle aussi — et se
    /// compte SANS son propre filtre, comme les quatre autres : sinon cocher
    /// « scanné » réduirait la section à cette seule ligne et il deviendrait
    /// impossible d'y ajouter « texte tapé ».
    func testLaFacetteOrigineRelanceEtSeCompteSansSonPropreFiltre() async throws {
        let f = try fixture()
        _ = try f.db.addDoc(relPath: "Users/a/Essai/photocopie.pdf", ext: "pdf",
                            pages: ["enthalpie recopiée."], sources: [.ocrAccurate])
        await run(f.model, "enthalpie")
        f.model.selectedSources = ["ocr_accurate"]
        await settle(f.model)
        XCTAssertEqual(f.model.totalPages, 1)
        let origine = Dictionary(uniqueKeysWithValues: f.model.facets[.source] ?? [])
        XCTAssertEqual(origine, ["native": 3, "ocr_accurate": 1])
        // Les AUTRES facettes, elles, voient le filtre.
        let extensions = Dictionary(uniqueKeysWithValues: f.model.facets[.ext] ?? [])
        XCTAssertEqual(extensions, ["pdf": 1])
    }

    /// La conversion des étiquettes de facette en provenances du moteur, seule.
    func testLesEtiquettesDeviennentDesProvenances() {
        XCTAssertNil(SearchModel.pageSources([]))
        XCTAssertEqual(SearchModel.pageSources(SearchModel.scannedSources),
                       PageSource.scanned)
        XCTAssertEqual(SearchModel.pageSources(["native"]), PageSource.typed)
        XCTAssertNil(SearchModel.pageSources(["quelque_chose_de_futur"]),
                     "une étiquette inconnue ne filtre rien : mieux vaut ne pas "
                     + "filtrer que filtrer sur rien")
    }

    func testToutEffacerRetireAussiLesNouveauxFiltres() async throws {
        let f = try fixture()
        await run(f.model, "enthalpie")
        f.model.toggleDate(.thisYear)
        await settle(f.model)
        f.model.selectedLangs = ["fr"]
        await settle(f.model)
        XCTAssertTrue(f.model.hasFilters)
        f.model.clearFilters()
        await settle(f.model)
        XCTAssertFalse(f.model.hasFilters)
        XCTAssertEqual(f.model.dateFilter, .any)
        XCTAssertTrue(f.model.selectedLangs.isEmpty)
        XCTAssertEqual(f.model.totalPages, 3)
    }

    // MARK: - Facette « Langue » (R-10)

    func testFacetteLangueEtFiltre() async throws {
        let f = try fixture()
        await run(f.model, "enthalpie")
        let langues = Dictionary(uniqueKeysWithValues: f.model.facets[.lang] ?? [])
        XCTAssertEqual(langues, ["fr": 1, "en": 1, FacetKey.undeterminedLanguage: 1],
                       "la langue indéterminée reste une valeur cochable")
        f.model.selectedLangs = ["fr"]
        await settle(f.model)
        XCTAssertEqual(f.model.hits.map(\.docID), [f.fr])
        XCTAssertEqual(f.model.totalPages, 1)
        // Convention du facettage à sélection multiple : la dimension filtrée
        // continue de montrer TOUTES ses valeurs, sans quoi on ne pourrait plus
        // en ajouter une seconde.
        XCTAssertEqual((f.model.facets[.lang] ?? []).count, 3)
    }

    func testLibellesDeLangue() {
        XCTAssertEqual(LanguageNames.label("fr"),
                       Locale.current.localizedString(forLanguageCode: "fr")
                           .map { $0.prefix(1).uppercased() + $0.dropFirst() })
        XCTAssertEqual(LanguageNames.label(FacetKey.undeterminedLanguage),
                       String(localized: "language not determined"))
        XCTAssertEqual(LanguageNames.label(""),
                       String(localized: "language not determined"))
        XCTAssertEqual(LanguageNames.label("zzz"), "ZZZ",
                       "un code que le système ne connaît pas se montre tel quel, "
                       + "jamais une ligne vide")
    }

    // MARK: - Reprendre où j'en étais (R-11)

    func testLaRequeteValideeEtSesFiltresSontMemorises() async throws {
        let f = try fixture()
        f.model.text = "enthalpie"
        f.model.submit()
        await settle(f.model)
        f.model.selectedLangs = ["fr"]
        await settle(f.model)

        let session = try XCTUnwrap(SearchModel.loadSession())
        XCTAssertEqual(session.text, "enthalpie")
        XCTAssertEqual(session.langs, ["fr"])
        XCTAssertEqual(session.selectionDocID, f.fr,
                       "la page qu'on regardait fait partie de « où j'en étais »")
    }

    /// L'anti-rebond exécute pendant la frappe (`remember: false`) : ce n'est
    /// pas encore une question posée, et cela ne doit pas remplacer la dernière
    /// requête validée.
    func testUneRequeteNonValideeNeRemplacePasLaMemoire() async throws {
        let f = try fixture()
        f.model.text = "enthalpie"
        f.model.submit()
        await settle(f.model)
        await run(f.model, "libre")   // execute(remember: false)
        XCTAssertEqual(SearchModel.loadSession()?.text, "enthalpie")
    }

    func testLaCroixOublieLaSession() async throws {
        let f = try fixture()
        f.model.text = "enthalpie"
        f.model.submit()
        await settle(f.model)
        XCTAssertNotNil(SearchModel.loadSession())
        f.model.forgetLastSession()
        XCTAssertNil(SearchModel.loadSession())
    }

    func testAuLancementLaDerniereRechercheEstRejouee() async throws {
        let f = try fixture()
        f.model.text = "enthalpie"
        f.model.submit()
        await settle(f.model)
        f.model.toggleDate(.thisYear)
        await settle(f.model)
        let regarde = try XCTUnwrap(f.model.selection)

        // Un second modèle sur la MÊME base : c'est ce que fait le lancement
        // suivant de l'application.
        let suivant = SearchModel(service: f.db.service)
        suivant.restoreLastSession()
        await settle(suivant)
        XCTAssertEqual(suivant.text, "enthalpie")
        XCTAssertEqual(suivant.executedText, "enthalpie")
        XCTAssertEqual(suivant.dateFilter, .thisYear)
        XCTAssertEqual(suivant.totalPages, 2)
        XCTAssertEqual(suivant.selection, regarde)
    }

    /// La base a changé depuis la dernière fois : la requête se rejoue, la
    /// sélection retombe sur la première ligne, et rien n'est annoncé — il n'y
    /// a rien à annoncer, la recherche a bien eu lieu.
    func testUneSelectionDisparueNeCasseRien() async throws {
        let f = try fixture()
        let session = SearchSession(text: "enthalpie",
                                    selectionDocID: 987_654, selectionPage: 3)
        Prefs.defaults.set(try JSONEncoder().encode(session),
                           forKey: Prefs.lastSession)
        let model = SearchModel(service: f.db.service)
        model.restoreLastSession()
        await settle(model)
        XCTAssertEqual(model.totalPages, 3)
        XCTAssertNotNil(model.selection)
        XCTAssertNotEqual(model.selection?.docID, 987_654)
        XCTAssertNil(model.errorText)
    }

    func testRienAOuvrirSansMemoire() async throws {
        let f = try fixture()
        f.model.restoreLastSession()
        await settle(f.model)
        XCTAssertTrue(f.model.executedText.isEmpty)
        XCTAssertTrue(f.model.hits.isEmpty)
    }
}
