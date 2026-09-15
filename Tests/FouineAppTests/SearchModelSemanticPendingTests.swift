// SearchModelSemanticPendingTests.swift — le canal lexical s'affiche d'abord,
// et l'attente du sens se dit (ST1). Propriété : A-App. SPEC §12.
//
// Le défaut : « Chercher aussi par le sens » allumé, `execute` ne lançait
// qu'UNE tâche, qui faisait les deux canaux et ne rendait rien avant la fusion.
// La ligne des comptes disait « recherche… » pendant toute l'attente — au
// premier coup, le temps de charger le modèle, plusieurs secondes sur une liste
// vide — et rien ne disait que c'était le sens qui cherchait. Les deux canaux
// partent désormais l'un après l'autre, et `semanticPending` dit que la liste
// affichée va encore bouger.
//
// LA FUSION, PROUVÉE DEPUIS LE LOT MN2. Une base de test n'a ni modèle CoreML
// ni vecteur ; `SearchModel` reçoit donc un double (`GatedSemantic`) qui répond
// quand le test le décide. Trois états se prouvent autour d'une vraie réponse :
// le plein texte affiché pendant que le sens attend, la fusion qui le
// remplace, et une requête suivante qui rend l'attente caduque. Les deux tests
// du bas gardent la règle d'avant : tant que le sens ne peut pas répondre,
// rien n'est promis.
//
// LA FUSION DU DOUBLE rend une vraie page, trouvée par le sens seul — la
// seconde page du document de test, qu'aucun mot tapé ne touche —, avec des
// totaux (42 pages, 7 documents) que le canal lexical d'une base à deux pages
// ne peut pas rendre : on sait ainsi, sans ambiguïté, quelle liste est affichée.

import XCTest
import FouineCore
import FouineEmbed
@testable import FouineApp

/// Un sens qui répond quand le test le décide.
///
/// Chaque appel attend `release()`. Le test attend lui-même que l'appel soit
/// ARRIVÉ (`waiting`) avant de libérer : une libération qui précéderait
/// l'attente la laisserait pendre.
final class GatedSemantic: SemanticSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [CheckedContinuation<Void, Never>] = []
    private let quorum: Bool
    /// Ce que la fusion rend, posé par le test une fois la base remplie.
    private var answer: [HybridHit] = []

    init(quorum: Bool = false) { self.quorum = quorum }

    var isLoaded: Bool { true }

    var waiting: Int {
        lock.lock(); defer { lock.unlock() }
        return gates.count
    }

    func answer(with hits: [HybridHit]) {
        lock.lock(); answer = hits; lock.unlock()
    }

    /// Synchrone : un `NSLock` ne se prend pas dans un contexte `async`.
    private func currentAnswer() -> [HybridHit] {
        lock.lock(); defer { lock.unlock() }
        return answer
    }

    func availability() async -> SemanticAvailability { .ready(vectors: 1) }

    func search(query: SearchQuery, excludingDocsMatching negative: String?,
                rawQuery: String, typedQuery: String, limit: Int,
                depth: Int) async throws -> HybridResults {
        await withCheckedContinuation { continuation in
            lock.lock(); gates.append(continuation); lock.unlock()
        }
        let rendered = currentAnswer()
        return HybridResults(hits: rendered, lexTotalPages: 42, lexTotalDocs: 7,
                             semanticOnly: rendered.filter { $0.lexical == nil }.count,
                             elapsedMS: 1, quorum: quorum)
    }

    func release() {
        lock.lock(); let open = gates; gates = []; lock.unlock()
        open.forEach { $0.resume() }
    }
}

@MainActor
final class SearchModelSemanticPendingTests: XCTestCase {

    private func waitFor(_ what: String, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("jamais arrivé : \(what)", file: file, line: line)
    }

    /// Un modèle dont le sens est armé et prêt, sur une base d'une page.
    ///
    /// L'interrupteur relance une recherche dans une tâche à lui : on attend
    /// qu'elle soit passée, champ vide, pour qu'elle ne double pas la requête
    /// du test.
    private func armedModel(_ semantic: GatedSemantic) async throws
        -> (db: TempAppDB, model: SearchModel) {
        let db = try TempAppDB()
        let doc = try db.addDoc(relPath: "Users/essai/un.txt",
                                pages: ["alpha beta gamma", "une page sur le sens seul"])
        // La fusion rend la SECONDE page, trouvée par le sens seul.
        semantic.answer(with: [HybridHit(
            docID: doc, page: 2, path: "Users/essai/un.txt", rrf: 1.0 / 61,
            lexRank: nil, vecRank: 1, cosine: 0.83, z: 2.5, lexical: nil,
            preview: "une page sur le sens seul")])
        let model = SearchModel(service: db.service, semantic: semantic)
        model.semanticEnabled = true
        await waitFor("le sens prêt") { model.useSemantic }
        try await Task.sleep(nanoseconds: 50_000_000)
        return (db, model)
    }

    /// Le plein texte s'affiche, le sens attend ; la fusion arrive et remplace
    /// la liste, et le fanion retombe.
    func testThePendingMeaningPassEndsWithTheFusion() async throws {
        let semantic = GatedSemantic()
        let (db, model) = try await armedModel(semantic)
        defer { _ = db }

        model.text = "alpha"
        model.execute(remember: false)
        XCTAssertTrue(model.semanticPending, "le sens est attendu dès le départ")

        await waitFor("le plein texte affiché") { !model.hits.isEmpty && !model.isSearching }
        await waitFor("le sens interrogé") { semantic.waiting == 1 }
        XCTAssertEqual(model.hits.map(\.page), [1], "d'abord la page qui porte le mot")
        XCTAssertTrue(model.semanticPending, "la liste affichée va encore bouger")
        XCTAssertFalse(model.isHybrid)
        XCTAssertFalse(model.canLoadMore, "pas de tranche de plus avant la fusion")

        semantic.release()
        await waitFor("la fusion affichée") { model.isHybrid }
        XCTAssertFalse(model.semanticPending)
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.hits.map(\.page), [2], "la liste est celle de la fusion")
        XCTAssertEqual(model.semanticOnlyCount, 1)
        XCTAssertEqual(model.hybridInfo.values.first?.vecRank, 1)
        XCTAssertEqual(model.lexTotalPages, 42, "les totaux sont ceux de la fusion")
        XCTAssertEqual(model.lexTotalDocs, 7)
        XCTAssertFalse(model.quorum, "la fusion n'a pas relâché le ET")
    }

    /// Une requête suivante rend l'attente caduque : la fusion de la première,
    /// arrivée trop tard, ne s'affiche pas.
    func testANewQueryDropsThePendingFusion() async throws {
        let semantic = GatedSemantic()
        let (db, model) = try await armedModel(semantic)
        defer { _ = db }

        model.text = "alpha"
        model.execute(remember: false)
        await waitFor("le sens interrogé") { semantic.waiting == 1 }

        // Une phrase entre guillemets ne consulte pas le sens (RK-01).
        model.text = "\"alpha beta\""
        model.execute(remember: false)
        XCTAssertFalse(model.semanticPending, "plus rien à attendre")
        await settle(model)

        semantic.release()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(model.isHybrid, "la réponse d'une requête abandonnée est jetée")
        XCTAssertFalse(model.semanticPending)
        XCTAssertEqual(model.executedText, "\"alpha beta\"")
        XCTAssertEqual(model.hits.count, 1)
    }

    /// La fusion relâche le ET comme le plein texte, et la ligne « Peu de
    /// pages portent tous vos mots » paraît (MN1 § 5, lot MN2) : l'application
    /// l'écrivait fausse en dur dans ce mode.
    func testTheFusionCarriesTheQuorumLine() async throws {
        let semantic = GatedSemantic(quorum: true)
        let (db, model) = try await armedModel(semantic)
        defer { _ = db }

        model.text = "alpha delta"
        model.execute(remember: false)
        await waitFor("le sens interrogé") { semantic.waiting == 1 }
        semantic.release()
        await waitFor("la fusion affichée") { model.isHybrid }

        // La condition exacte de la ligne sous le champ (`ResultsView`).
        XCTAssertTrue(model.quorum && !model.isSearching)
    }

    private func waitUntilIdle(_ model: SearchModel,
                               file: StaticString = #filePath,
                               line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !model.isSearching { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("la recherche ne s'est pas terminée", file: file, line: line)
    }

    /// Interrupteur armé mais sens indisponible (ni modèle, ni vecteur) : la
    /// recherche est lexicale de bout en bout, et la ligne des comptes ne
    /// promet AUCUNE attente — un tourniquet qui ne s'éteint jamais serait pire
    /// que l'absence de sens.
    func testAnArmedSwitchWithoutMeaningPromisesNothing() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt",
                      pages: ["alpha beta gamma delta epsilon"])
        let model = SearchModel(service: db.service)
        model.semanticEnabled = true
        XCTAssertFalse(model.useSemantic,
                       "sans modèle ni vecteur, le sens ne peut pas répondre")

        model.text = "alpha"
        model.execute(remember: false)
        XCTAssertFalse(model.semanticPending,
                       "rien à attendre : le sens n'a pas été consulté")

        await waitUntilIdle(model)
        XCTAssertFalse(model.hits.isEmpty, "les résultats lexicaux s'affichent")
        XCTAssertFalse(model.semanticPending)
        XCTAssertFalse(model.isHybrid)
    }

    /// Et vider le champ éteint le fanion comme les autres (A2-01) : une ligne
    /// « recherche par le sens… » ne doit pas survivre à une requête effacée.
    func testClearingTheFieldClearsThePendingMeaningPass() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt", pages: ["alpha beta gamma"])
        let model = SearchModel(service: db.service)
        model.semanticEnabled = true

        model.text = "alpha"
        model.execute(remember: false)
        model.text = ""
        model.execute(remember: false)

        XCTAssertFalse(model.semanticPending)
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.hits.isEmpty)
    }
}
