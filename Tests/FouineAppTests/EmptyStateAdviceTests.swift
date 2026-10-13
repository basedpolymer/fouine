// EmptyStateAdviceTests.swift — les gestes de l'état vide (AP-07).
// Propriété : A-App.
//
// Ce qui se teste, c'est le CHOIX : proposer de tolérer les fautes de frappe à
// quelqu'un qui les tolère déjà rendrait l'écran vide bavard sans le rendre
// utile.

import XCTest
import FouineCore
@testable import FouineApp

final class EmptyStateAdviceTests: XCTestCase {

    /// DEPUIS LE LOT MP1 (C2-08) : le moteur a déjà rejoué la requête en
    /// tolérant les fautes sur tous les documents avant que cet écran ne
    /// s'affiche, sauf si le réglage les refuse (« jamais »). Le geste ne
    /// paraît donc que là où il change encore quelque chose.
    func testTheTypoGestureOnlyRemainsWhenTyposAreRefused() {
        XCTAssertTrue(EmptyStateAdvice.gestures(
            fuzzy: .off, filtersActive: false).contains(.tolerateTypos))
        for mode in [FuzzyMode.auto, .on] {
            XCTAssertFalse(EmptyStateAdvice.gestures(
                fuzzy: mode, filtersActive: false).contains(.tolerateTypos),
                "\(mode) : le repli automatique a déjà eu lieu")
        }
    }

    func testFiltersAreOfferedOnlyWhenSomethingFilters() {
        XCTAssertTrue(EmptyStateAdvice.gestures(
            fuzzy: .on, filtersActive: true).contains(.removeFilters))
        XCTAssertFalse(EmptyStateAdvice.gestures(
            fuzzy: .on, filtersActive: false).contains(.removeFilters))
    }

    /// Deux gestes au plus, et dans cet ordre : la faute de frappe est la
    /// cause la plus fréquente, le filtre oublié la plus facile à défaire.
    func testTheOrderIsStable() {
        XCTAssertEqual(EmptyStateAdvice.gestures(fuzzy: .off, filtersActive: true),
                       [.tolerateTypos, .removeFilters])
    }

    /// Aucun geste possible : il reste la phrase, et elle vaut toujours.
    func testTheAdviceSentenceIsAlwaysThere() {
        XCTAssertTrue(EmptyStateAdvice.gestures(
            fuzzy: .on, filtersActive: false).isEmpty)
        XCTAssertFalse(EmptyStateAdvice.sentence.isEmpty)
    }
}
