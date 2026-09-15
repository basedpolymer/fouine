// PreviewWindowsTests.swift — une fenêtre par document, trois au plus (BU-19).
// Propriété : A-App.
//
// Le constat était une MESURE : trois liens vers trois pages du même PDF de
// 400 pages ouvraient trois fenêtres, et l'instance passait de 55 Mo à 793 Mo.
// Ce qui se teste ici est la décision qui l'empêche — quelle fenêtre ouvrir,
// laquelle réemployer —, la mémoire, elle, se mesure à l'exécution.

import XCTest
import FouineCore
@testable import FouineApp

final class PreviewWindowsTests: XCTestCase {

    func testASecondPageOfTheSameDocumentReusesItsWindow() {
        var windows = PreviewWindows()
        let first = windows.request(docID: 1, page: 25)
        XCTAssertTrue(first.isNew)

        let second = windows.request(docID: 1, page: 87)
        XCTAssertFalse(second.isNew, "BU-19 : pas de seconde fenêtre")
        XCTAssertEqual(second.identity, first.identity,
                       "SwiftUI ramène la fenêtre par la clé qui l'a ouverte")
        XCTAssertEqual(second.target, HitKey(docID: 1, page: 87))
        XCTAssertEqual(windows.count, 1)
    }

    func testThreeDocumentsMakeThreeWindows() {
        var windows = PreviewWindows()
        for doc in Int64(1)...3 {
            XCTAssertTrue(windows.request(docID: doc, page: 1).isNew)
        }
        XCTAssertEqual(windows.count, PreviewWindows.maximum)
    }

    /// Au-delà du plafond, c'est la fenêtre la MOINS RÉCEMMENT utilisée qui
    /// change de document — pas la première ouverte : celle qu'on vient de
    /// consulter est justement celle qu'on veut garder.
    func testTheFourthDocumentReusesTheLeastRecentlyUsedWindow() {
        var windows = PreviewWindows()
        let one = windows.request(docID: 1, page: 1)
        _ = windows.request(docID: 2, page: 1)
        _ = windows.request(docID: 3, page: 1)
        // On revient sur le document 1 : le 2 devient le plus ancien.
        _ = windows.request(docID: 1, page: 4)

        let fourth = windows.request(docID: 4, page: 9)
        XCTAssertFalse(fourth.isNew)
        XCTAssertEqual(windows.count, PreviewWindows.maximum,
                       "BU-19 : jamais plus de trois fenêtres détachées")
        XCTAssertEqual(fourth.target, HitKey(docID: 4, page: 9))
        XCTAssertNotEqual(fourth.identity, one.identity,
                          "la fenêtre revue reste sur son document")
        XCTAssertEqual(windows.showing(identity: fourth.identity),
                       HitKey(docID: 4, page: 9))
    }

    func testClosingAWindowFreesItsPlace() {
        var windows = PreviewWindows()
        let one = windows.request(docID: 1, page: 1)
        _ = windows.request(docID: 2, page: 1)
        windows.closed(identity: one.identity)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows.showing(identity: one.identity))

        // La place libérée sert à un document neuf, sans réemploi.
        XCTAssertTrue(windows.request(docID: 3, page: 1).isNew)
    }
}
