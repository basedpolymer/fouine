// MenuBarModelTests.swift — le pied du panneau de la barre des menus (UX-07,
// recalé par IX2). Propriété : A-App.
//
// Ce que ces tests protègent depuis le 13/09/2026 (AP1) : le pied porte UNE
// ligne d'état — celle qui explique l'icône, qui change de nouveau —, puis les
// deux gestes. Une ligne de détail, une progression, un geste sur l'index ou un
// interrupteur qui reviendraient feraient échouer le premier test, car c'est la
// liste ENTIÈRE qui est comparée. L'aide de « Quitter » ne dit pas une chose
// fausse quand la mise à jour automatique est éteinte.

import XCTest
@testable import FouineApp

final class MenuBarModelTests: XCTestCase {

    /// L'état, ouvrir, quitter, rien d'autre : ni ligne de détail, ni
    /// progression, ni geste sur l'index, ni interrupteur.
    func testTheFooterIsOneStatusLineThenOpenAndQuit() {
        let status = IndexStatus.working(activity: .readingScans, progress: nil,
                                         detail: nil, stoppable: true)
        XCTAssertEqual(MenuBarModel.items(status: status),
                       [.status(IndexStatusText.headline(status)), .openWindow, .quit])
        XCTAssertEqual(MenuBarModel.items(status: status).map(\.identifier),
                       ["status", "openWindow", "quit"])
    }

    /// La ligne d'état dit EXACTEMENT ce que dit la carte « Index » : le
    /// panneau n'a pas ses propres mots pour l'index, et deux phrases pour un
    /// même état se liraient comme deux états.
    func testTheStatusLineIsTheSameSentenceAsTheCard() {
        for status: IndexStatus in [.checking,
                                    .noFolders,
                                    .idle(automatic: true, scansWaiting: 0, lastUpdate: nil),
                                    .needsAttention(.awaitingApproval)] {
            XCTAssertEqual(MenuBarModel.items(status: status).first,
                           .status(IndexStatusText.headline(status)))
        }
    }

    /// Trois pictogrammes, un par famille d'état — et ce que VoiceOver annonce
    /// de l'icône est la phrase d'état, pas « icône » ni « Fouine ».
    func testTheIconShowsTheFamilyAndSaysTheState() {
        XCTAssertEqual(MenuBarModel.symbolName(for: .quiet), "text.magnifyingglass")
        XCTAssertEqual(MenuBarModel.symbolName(for: .working), "arrow.triangle.2.circlepath")
        XCTAssertEqual(MenuBarModel.symbolName(for: .attention), "exclamationmark.triangle")

        let status = IndexStatus.needsAttention(.awaitingApproval)
        XCTAssertEqual(MenuBarText.iconLabel(status), IndexStatusText.headline(status))
    }

    /// « L'index continue de se mettre à jour après la fermeture » n'est vrai
    /// que si la mise à jour automatique est allumée.
    func testQuitHelpOnlyWhenTheIndexReallyKeepsUpdating() {
        XCTAssertEqual(MenuBarModel.quitHelp(automatic: true), MenuBarText.quitHelp)
        XCTAssertNil(MenuBarModel.quitHelp(automatic: false))
    }

    /// Le public visé ne sait pas ce qu'est un agent, un verrou ou un pid — et
    /// n'a pas à l'apprendre pour chercher un document.
    func testThePanelSpeaksNoMachineWords() {
        let texts = [MenuBarText.openWindow, MenuBarText.quit,
                     MenuBarText.quitHelp,
                     MenuBarText.iconLabel(.idle(automatic: true, scansWaiting: 0,
                                                 lastUpdate: nil)),
                     MenuBarText.searchPrompt, MenuBarText.searchHint,
                     MenuBarText.showAll]
        for text in texts {
            let lower = text.lowercased()
            for word in ["agent", "ocr", "lock", "verrou", "pid", "launchd",
                         "vector", "vecteur"] {
                XCTAssertFalse(lower.contains(word), "« \(text) » dit « \(word) »")
            }
        }
    }
}
