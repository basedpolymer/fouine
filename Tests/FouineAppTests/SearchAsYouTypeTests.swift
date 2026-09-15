// SearchAsYouTypeTests.swift — le réglage « Chercher pendant que je tape »
// (AP1, demande du propriétaire du 13/09/2026). Propriété : A-App.
//
// Ce que ces tests protègent : la clé ABSENTE vaut allumé (sans quoi la
// première mise à jour éteindrait la recherche au fil de la frappe chez tout le
// monde) ; éteint, la frappe n'arme plus rien dans AUCUN des deux modèles et
// c'est ⏎ qui cherche ; allumé, rien n'a changé.
//
// L'attente est de 400 ms : l'anti-rebond des deux modèles est de 250 ms, et un
// test qui n'attendrait que cela conclurait d'une course.

import XCTest
@testable import FouineApp

@MainActor
final class SearchAsYouTypeTests: XCTestCase {

    /// Plus long que l'anti-rebond de 250 ms, assez court pour ne pas peser.
    private static let afterDebounce: UInt64 = 400_000_000

    override func setUp() {
        super.setUp()
        _ = TestPrefs.isolate
        // Chaque test part de la préférence ABSENTE : c'est l'état d'une
        // installation neuve, et celui que le premier test exige.
        Prefs.defaults.removeObject(forKey: Prefs.searchAsYouType)
    }

    override func tearDown() {
        Prefs.defaults.removeObject(forKey: Prefs.searchAsYouType)
        super.tearDown()
    }

    // MARK: - La préférence

    /// Une clé jamais écrite vaut ALLUMÉ : `bool(forKey:)` rendrait `false` et
    /// éteindrait, à la mise à jour, ce que Fouine fait depuis toujours.
    func testTheSettingIsOnWhenItHasNeverBeenTouched() {
        XCTAssertTrue(Prefs.searchesAsYouType, "une installation neuve cherche au fil de la frappe")
        Prefs.searchesAsYouType = false
        XCTAssertFalse(Prefs.searchesAsYouType)
        Prefs.searchesAsYouType = true
        XCTAssertTrue(Prefs.searchesAsYouType)
    }

    /// L'interrupteur des réglages écrit la préférence, et une instance neuve la
    /// relit : le choix survit à la fermeture de la fenêtre.
    func testTheToggleIsRememberedAcrossInstances() {
        let prefs = InterfacePreferences()
        XCTAssertTrue(prefs.searchesAsYouType)
        prefs.searchesAsYouType = false
        XCTAssertFalse(Prefs.searchesAsYouType)
        XCTAssertFalse(InterfacePreferences().searchesAsYouType)
    }

    // MARK: - La fenêtre

    /// Éteint : taper ne cherche pas, même longtemps après l'anti-rebond ; ⏎
    /// (`submit()`) cherche.
    func testTheWindowSearchesOnlyOnReturnWhenTheSettingIsOff() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt", pages: ["alpha beta gamma"])
        let model = SearchModel(service: db.service)
        Prefs.searchesAsYouType = false

        model.text = "alpha"
        model.textChanged()
        try await Task.sleep(nanoseconds: Self.afterDebounce)
        XCTAssertEqual(model.executedText, "", "la frappe a cherché alors que le réglage est éteint")
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertFalse(model.isSearching)

        model.submit()
        await settle(model)
        XCTAssertEqual(model.executedText, "alpha")
        XCTAssertFalse(model.hits.isEmpty, "⏎ doit chercher")
    }

    /// Allumé : le comportement d'avant AP1 — la frappe cherche toute seule.
    func testTheWindowStillSearchesWhileTypingWhenTheSettingIsOn() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt", pages: ["alpha beta gamma"])
        let model = SearchModel(service: db.service)

        model.text = "alpha"
        model.textChanged()
        try await Task.sleep(nanoseconds: Self.afterDebounce)
        await settle(model)
        XCTAssertEqual(model.executedText, "alpha")
        XCTAssertFalse(model.hits.isEmpty)
    }

    // MARK: - Le panneau de la barre des menus

    func testThePanelSearchesOnlyOnReturnWhenTheSettingIsOff() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt", pages: ["alpha beta gamma"])
        let mini = MenuBarSearchModel(service: db.service)
        Prefs.searchesAsYouType = false

        mini.text = "alpha"
        mini.textChanged()
        try await Task.sleep(nanoseconds: Self.afterDebounce)
        XCTAssertEqual(mini.state, .idle, "la frappe a cherché alors que le réglage est éteint")
        XCTAssertTrue(mini.rows.isEmpty)

        mini.submit()
        await settle(mini)
        XCTAssertFalse(mini.rows.isEmpty, "⏎ doit chercher")
    }

    func testThePanelStillSearchesWhileTypingWhenTheSettingIsOn() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt", pages: ["alpha beta gamma"])
        let mini = MenuBarSearchModel(service: db.service)

        mini.text = "alpha"
        mini.textChanged()
        try await Task.sleep(nanoseconds: Self.afterDebounce)
        await settle(mini)
        XCTAssertFalse(mini.rows.isEmpty)
    }

    /// Réglage éteint, le premier ⏎ cherche DANS le panneau ; le second, la
    /// question étant posée, passe la main à la grande fenêtre (comme avant
    /// AP1). Réglage allumé, ⏎ ouvre la fenêtre dès le premier coup.
    func testReturnSearchesInThePanelOnceThenOpensTheWindow() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Users/essai/un.txt", pages: ["alpha beta gamma"])
        let mini = MenuBarSearchModel(service: db.service)

        mini.text = "alpha"
        XCTAssertFalse(mini.returnSearchesHere, "réglage allumé : ⏎ ouvre la fenêtre")

        Prefs.searchesAsYouType = false
        XCTAssertTrue(mini.returnSearchesHere)
        mini.submit()
        await settle(mini)
        XCTAssertFalse(mini.returnSearchesHere, "la question est posée : ⏎ ouvre la fenêtre")

        mini.text = "beta"
        XCTAssertTrue(mini.returnSearchesHere, "une autre question n'a pas encore été cherchée")
    }

    /// Attend la fin d'une recherche du panneau.
    private func settle(_ mini: MenuBarSearchModel, timeout: TimeInterval = 20,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if mini.state != .searching { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("le panneau ne s'est pas stabilisé en \(timeout) s", file: file, line: line)
    }
}
