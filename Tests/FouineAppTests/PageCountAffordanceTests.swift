// PageCountAffordanceTests.swift — le compte de pages devient un geste (PERSP-Q4).
// Propriété : A-App.
//
// Ce que ces tests protègent : depuis la diversité par document (lot R1), la
// liste montre les meilleures pages de chaque document et rétrograde les
// autres. Presque chaque en-tête annonce donc « 3 / 300 p. ». Deux choses
// doivent rester vraies :
//
//   1. le compte ne devient cliquable QUE s'il reste des pages à montrer et
//      que la recherche n'est pas déjà bornée à ce document — sinon le clic
//      promettrait un ailleurs qui n'existe pas ;
//   2. le clic ramène bien toutes les pages appariées de ce document.
//
// LANGUE : `swift test` ne tourne pas depuis Fouine.app, `String(localized:)`
// rend donc la clé, c'est-à-dire l'anglais source (même raison que
// `AccessibilityTextTests`). Les assertions portent sur cet anglais-là ; le
// français se vérifie sur le catalogue (`L10nTests`).

import XCTest
import FouineCore
@testable import FouineApp

final class PageCountAffordanceTests: XCTestCase {

    // MARK: - La décision

    /// Tant que le comptage différé n'a pas répondu, on ne connaît que les
    /// pages reçues : rien à proposer, et il faut le dire.
    func testSansComptageOnNeParleQueDesPagesRecues() {
        let a = PageCountAffordance.decide(loaded: 3, matched: nil,
                                           scopedToThisDocument: false)
        XCTAssertEqual(a, .loadedOnly(loaded: 3))
        XCTAssertFalse(a.isGesture, "on ne propose pas un geste sur un compte inconnu")
        XCTAssertNil(a.accessibilityHint)
        XCTAssertTrue(a.label.contains("loaded"), a.label)
    }

    /// Tout est à l'écran : un seul nombre, pas de geste.
    func testToutesLesPagesLaSontDejaCompteSimple() {
        let a = PageCountAffordance.decide(loaded: 7, matched: 7,
                                           scopedToThisDocument: false)
        XCTAssertEqual(a, .complete(count: 7))
        XCTAssertFalse(a.isGesture)
        XCTAssertEqual(a.label, "\(Format.integer(7)) p.")
    }

    /// Le cas de tous les jours : 3 pages montrées sur 300 trouvées.
    func testPagesManquantesLeCompteDevientUnGeste() {
        let a = PageCountAffordance.decide(loaded: 3, matched: 300,
                                           scopedToThisDocument: false)
        XCTAssertEqual(a, .gesture(loaded: 3, matched: 300))
        XCTAssertTrue(a.isGesture)
        XCTAssertTrue(a.label.contains(Format.integer(3)), a.label)
        XCTAssertTrue(a.label.contains(Format.integer(300)), a.label)
        XCTAssertTrue(a.label.contains("See them all"),
                      "le libellé doit dire le GESTE, pas seulement le compte : \(a.label)")
        XCTAssertNotNil(a.accessibilityHint, "un bouton doit dire où il mène")
    }

    /// Déjà dans le document : le geste n'aurait nulle part où mener, le compte
    /// redevient le compte honnête d'avant (audit A12).
    func testSousLaPorteeDuDocumentLeCompteRedevientUnCompte() {
        let a = PageCountAffordance.decide(loaded: 200, matched: 300,
                                           scopedToThisDocument: true)
        XCTAssertEqual(a, .counts(loaded: 200, matched: 300))
        XCTAssertFalse(a.isGesture, "on ne restreint pas deux fois au même document")
        XCTAssertNil(a.accessibilityHint)
        XCTAssertEqual(a.label,
                       "\(Format.integer(200)) / \(Format.integer(300)) p.")
    }

    /// Défensif : un comptage d'une génération précédente peut rester affiché
    /// une fraction de seconde et annoncer MOINS que le jeu reçu. Le geste
    /// n'aurait rien de plus à montrer.
    func testComptagePerimeInferieurAuJeuRecuPasDeGeste() {
        let a = PageCountAffordance.decide(loaded: 12, matched: 5,
                                           scopedToThisDocument: false)
        XCTAssertEqual(a, .complete(count: 12))
        XCTAssertFalse(a.isGesture)
    }

    // MARK: - Ce qui se lit et ce qui s'entend

    /// L'info-bulle s'adresse à quelqu'un qui n'a jamais entendu parler de
    /// classement : elle dit pourquoi il n'y a que quelques pages et ce que
    /// fait le clic — sans un mot de jargon (règle du public cible).
    func testInfoBulleDuGesteSansJargon() {
        let help = PageCountAffordance.decide(loaded: 3, matched: 300,
                                              scopedToThisDocument: false).help
        for jargon in ["scope", "rank", "score", "diversity", "semantic",
                       "vector", "query", "BM25", "index"] {
            XCTAssertFalse(help.lowercased().contains(jargon.lowercased()),
                           "« \(jargon) » n'a rien à faire dans une info-bulle : \(help)")
        }
        XCTAssertTrue(help.contains("Click"),
                      "l'info-bulle doit dire le geste à faire : \(help)")
    }

    /// VoiceOver entend le MÊME compte que l'en-tête du document : une seule
    /// façon de dire « 3 pages chargées sur 300 ».
    func testCompteParleIdentiqueACeluiDeLEnTete() {
        let inconnu = PageCountAffordance.decide(loaded: 3, matched: nil,
                                                 scopedToThisDocument: false)
        XCTAssertEqual(inconnu.accessibilityLabel,
                       AccessibilityText.groupValue(loaded: 3, matched: nil))

        let sousPortee = PageCountAffordance.decide(loaded: 3, matched: 300,
                                                    scopedToThisDocument: true)
        XCTAssertEqual(sousPortee.accessibilityLabel,
                       AccessibilityText.groupValue(loaded: 3, matched: 300))
    }

    /// BU-17 : le lien porte SON NOM, le compte reste au document.
    ///
    /// Le bouton du document annonce déjà « 3 pages chargées sur 300 pages
    /// touchées » ; le lien voisin portait la même phrase, et un groupe faisait
    /// donc lire deux fois le même compte sans dire que le second est un geste.
    func testLeLienDUnGroupePorteSonNomEtNonLeCompte() {
        let gesture = PageCountAffordance.decide(loaded: 3, matched: 300,
                                                 scopedToThisDocument: false)
        XCTAssertEqual(gesture.accessibilityLabel,
                       String(localized: "See them all"))
        XCTAssertNotEqual(gesture.accessibilityLabel,
                          AccessibilityText.groupValue(loaded: 3, matched: 300))
        XCTAssertEqual(gesture.accessibilityHint,
                       AccessibilityText.seeAllPagesHint)
    }
}

/// Ce que le geste FAIT, sur une vraie base : la portée se pose et la liste ne
/// garde que les pages du document désigné.
@MainActor
final class ScopeToDocumentTests: XCTestCase {

    private func fixture() throws -> (db: TempAppDB, un: Int64, deux: Int64,
                                      model: SearchModel) {
        let db = try TempAppDB()
        let un = try db.addDoc(relPath: "Users/essai/un.txt", pages: [
            "polymere en tête de ce document",
            "encore polymere, deuxième page",
            "toujours polymere, troisième page",
        ])
        let deux = try db.addDoc(relPath: "Users/essai/deux.txt", pages: [
            "polymere dans un autre document",
        ])
        return (db, un, deux, SearchModel(service: db.service))
    }

    func testLeGesteRamenneLesPagesDuSeulDocumentDesigne() async throws {
        let f = try fixture()
        await run(f.model, "polymere")
        XCTAssertEqual(Set(f.model.hits.map(\.docID)), [f.un, f.deux],
                       "sans portée, les deux documents répondent")

        f.model.scopeToDocument(id: f.un, name: "un.txt")
        await settle(f.model)

        XCTAssertEqual(f.model.scope, .document(id: f.un, name: "un.txt"))
        // Toutes les pages appariées reviennent. `hits` est la liste PLATE,
        // dans l'ordre du moteur — la pertinence (mesuré ici : 2, 3, 1) ; c'est
        // `ResultGrouping.group` qui, pour l'affichage, remet les pages d'un
        // même document dans l'ordre du livre (vérifié à l'écran le 05/09 :
        // 65 pages de 11 à 1 016, croissantes).
        XCTAssertEqual(Set(f.model.hits.map(\.page)), [1, 2, 3],
                       "toutes les pages appariées du document reviennent")
        XCTAssertEqual(Set(f.model.hits.map(\.docID)), [f.un])
        XCTAssertNotNil(f.model.scope.label,
                        "la puce de portée doit s'afficher pour pouvoir en sortir")
    }

    /// Le clic sur un compte déjà sous portée ne doit pas relancer la
    /// recherche : `didSet` ne compare pas les valeurs, c'est au modèle de le
    /// faire.
    func testPorteeIdentiqueNeRelancePas() async throws {
        let f = try fixture()
        await run(f.model, "polymere")
        f.model.scopeToDocument(id: f.un, name: "un.txt")
        await settle(f.model)

        f.model.scopeToDocument(id: f.un, name: "un.txt")
        XCTAssertFalse(f.model.isSearching,
                       "une portée identique ne doit déclencher aucune recherche")
        XCTAssertEqual(f.model.scope, .document(id: f.un, name: "un.txt"))
    }
}
