// IntentsTests.swift — les actions Raccourcis (lot INT-R1). Propriété : A-App.
//
// Ce que ces tests couvrent, et ce qu'ils NE PEUVENT PAS couvrir. Une
// `AppIntent` n'existe pour le système que par les métadonnées extraites du
// bundle : la faire tourner sous XCTest, hors bundle, ne prouverait rien de ce
// que Raccourcis en fera. Tout ce qui peut être faux vit donc dans
// `IntentSupport`, et c'est lui qu'on interroge ici. La présence des trois
// actions dans `Metadata.appintents` est vérifiée par `make ci-bundle`.

import XCTest
import FouineCore
@testable import FouineApp

final class IntentsTests: XCTestCase {

    // MARK: - La requête

    /// Le MÊME chemin que `fouine search` : `dossier:` est un filtre, pas un
    /// mot cherché. Une action Raccourcis qui construirait sa propre requête
    /// répondrait autrement que la ligne de commande à la même phrase.
    func testTheQueryIsBuiltLikeTheCommandLine() throws {
        let plan = try IntentSupport.plan(query: "dossier:Cours polymere", limit: 10)
        XCTAssertEqual(plan.query.folders, ["Cours"])
        XCTAssertEqual(plan.query.terms, ["polymere"])
        XCTAssertEqual(plan.query.fuzzy, .auto)
        XCTAssertTrue(plan.query.groupByDoc)
    }

    /// Raccourcis fait respecter les bornes dans son interface, mais un
    /// raccourci construit par script passe ce qu'il veut.
    func testTheNumberOfResultsIsBounded() throws {
        XCTAssertEqual(try IntentSupport.plan(query: "a", limit: 0).query.limit, 1)
        XCTAssertEqual(try IntentSupport.plan(query: "a", limit: 999).query.limit, 50)
        XCTAssertEqual(try IntentSupport.plan(query: "a", limit: 10).query.limit, 10)
    }

    /// Le littéral `default: 10` de `SearchFouineIntent` ne peut pas renvoyer à
    /// la constante (l'extraction des valeurs constantes exige une littérale) :
    /// ce test est ce qui empêche les deux de diverger.
    func testTheDefaultAndTheRangeMatchTheIntentLiterals() {
        XCTAssertEqual(IntentSupport.defaultLimit, 10)
        XCTAssertEqual(IntentSupport.limitRange, 1...50)
    }

    // MARK: - L'identifiant d'un résultat

    func testTheIdentifierRoundTrips() throws {
        let id = IntentSupport.entityID(docID: 1329, page: 87)
        XCTAssertEqual(id, "1329:87")
        XCTAssertEqual(IntentSupport.key(fromEntityID: id),
                       HitKey(docID: 1329, page: 87))
    }

    /// Raccourcis rejoue des identifiants enregistrés il y a des mois : celui
    /// qui n'est pas de nous doit se refuser, pas ouvrir un autre document.
    func testAnIdentifierThatIsNotOursIsRefused() {
        for bad in ["", "1329", "1329:87:3", "doc:1329", "abc:87", "1329:x",
                    "-1:87", "0:87"] {
            XCTAssertNil(IntentSupport.key(fromEntityID: bad), bad)
        }
    }

    // MARK: - L'extrait

    /// Les marqueurs de FTS5 partent : rien ne les colore dans Raccourcis, et
    /// ils arriveraient tels quels dans la note où l'extrait est recopié.
    func testTheExcerptLosesTheFTSMarkers() {
        XCTAssertEqual(IntentSupport.snippet("la «cinetique» de la reaction"),
                       "la cinetique de la reaction")
    }

    /// Coupé sur une frontière de MOT : « …la thermodynamiq » se relit deux
    /// fois avant qu'on comprenne que le document, lui, ne coupe rien.
    func testTheExcerptIsCutOnAWordBoundary() {
        let text = String(repeating: "polymere ", count: 60)
        let cut = IntentSupport.snippet(text)
        XCTAssertLessThanOrEqual(cut.count, IntentSupport.snippetCharacters + 1)
        XCTAssertTrue(cut.hasSuffix("polymere…"), cut)
    }

    /// Une page mal océrisée produit des « mots » de trois cents caractères :
    /// on coupe net plutôt que de rendre une chaîne vide.
    func testAnExcerptWithoutASpaceIsCutAnyway() {
        let cut = IntentSupport.snippet(String(repeating: "x", count: 400))
        XCTAssertEqual(cut.count, IntentSupport.snippetCharacters + 1)
    }

    // MARK: - Le texte d'une page

    func testAShortPageIsReturnedWhole() {
        let text = "Une page courte.\nDeux lignes."
        XCTAssertEqual(IntentSupport.truncate(pageText: text, note: "[coupé]"), text)
    }

    /// Le plafond est VISIBLE : une page tronquée sans le dire part dans une
    /// note où il manquera trois paragraphes que personne ne cherchera.
    func testALongPageIsCappedAndSaysSo() {
        let text = String(repeating: "mot ", count: 20_000)
        let out = IntentSupport.truncate(pageText: text, note: "[coupé]")
        XCTAssertTrue(out.hasSuffix("\n\n[coupé]"))
        XCTAssertLessThan(out.count,
                          IntentSupport.pageTextCharacters + "\n\n[coupé]".count)
        XCTAssertGreaterThan(out.count, IntentSupport.pageTextCharacters / 2)
    }

    // MARK: - Rien d'indexé

    /// Une liste vide se lit comme « ce mot n'est pas dans mes documents »,
    /// ce qui est faux quand il n'y a pas d'index du tout.
    func testAMissingIndexIsSaidAndNotAnEmptyResult() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-\(UUID().uuidString).db")
        XCTAssertThrowsError(try IntentSupport.checkIndex(at: missing)) { error in
            XCTAssertEqual(error as? FouineIntentError, .nothingIndexed)
        }
    }

    func testAnIndexThatExistsPassesTheGuard() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-\(UUID().uuidString).db")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try IntentSupport.checkIndex(at: url))
    }

    // MARK: - Ce que Raccourcis affiche

    /// Le titre passe par la clé `%@, page %lld` du catalogue — la même que la
    /// citation collée par ⌘C (INT-L1) : les deux surfaces nomment une page de
    /// la même façon, dans les deux langues.
    func testTheDisplayedTitleNamesTheFileAndThePage() {
        let entity = FouineHitEntity(
            id: IntentSupport.entityID(docID: 12, page: 5),
            fileName: "chimie.pdf", page: 5, snippet: "un extrait",
            path: "/Users/moi/Cours/chimie.pdf", folder: "Cours",
            link: DeepLink.page(absolutePath: "/Users/moi/Cours/chimie.pdf",
                                page: 5))
        XCTAssertEqual(String(localized: entity.displayRepresentation.title),
                       String(localized: "\("chimie.pdf"), page \(5)"))
    }

    /// Le nom du fichier, pas le chemin : c'est par lui que la personne
    /// reconnaît son document.
    func testTheFileNameIsTheLastComponent() {
        XCTAssertEqual(IntentSupport.fileName(relPath: "M2/Chimie/cours 3.pdf"),
                       "cours 3.pdf")
    }
}
