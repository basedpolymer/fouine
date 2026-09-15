// WindowLifecycleTests.swift — fermer la fenêtre ne quitte plus Fouine
// (session UX du 04/09/2026, UX-08/UX-09). Propriété : A-App.
//
// La politique tient en trois questions, et chacune a une mauvaise réponse
// coûteuse : quitter alors que l'icône de la barre des menus reste (une icône
// morte), rester sans icône ni fenêtre (un processus invisible et inarrêtable),
// ouvrir une fenêtre à chaque ouverture de session (l'app qu'on désinstalle).

import XCTest
import AppKit
@testable import FouineApp

final class WindowLifecycleTests: XCTestCase {

    // MARK: - Quitter, ou non

    func testClosingTheLastWindowQuitsOnlyWithoutTheMenuBarIcon() {
        XCTAssertFalse(WindowLifecyclePolicy
            .terminatesAfterLastWindowClosed(menuBarShown: true))
        XCTAssertTrue(WindowLifecyclePolicy
            .terminatesAfterLastWindowClosed(menuBarShown: false))
    }

    // MARK: - Icône du Dock

    /// Sans fenêtre ET avec l'icône de la barre des menus : `.accessory`,
    /// l'usage macOS des utilitaires de barre des menus. Dans tous les autres
    /// cas `.regular` — surtout celui-ci : pas d'icône de barre des menus et
    /// pas d'icône de Dock ferait une application introuvable.
    func testDockIconFollowsTheLastWindow() {
        XCTAssertEqual(WindowLifecyclePolicy.activationPolicy(menuBarShown: true,
                                                              hasWindow: false),
                       .accessory)
        XCTAssertEqual(WindowLifecyclePolicy.activationPolicy(menuBarShown: true,
                                                              hasWindow: true),
                       .regular)
        XCTAssertEqual(WindowLifecyclePolicy.activationPolicy(menuBarShown: false,
                                                              hasWindow: false),
                       .regular)
    }

    // MARK: - Ouverture de session

    func testASessionLaunchOpensNoWindow() {
        XCTAssertTrue(WindowLifecyclePolicy.startsWithoutWindow(
            menuBarShown: true, launchedBySystem: true))
        // Sans icône de barre des menus, une fenêtre est le SEUL signe que
        // Fouine a démarré : on la montre.
        XCTAssertFalse(WindowLifecyclePolicy.startsWithoutWindow(
            menuBarShown: false, launchedBySystem: true))
        XCTAssertFalse(WindowLifecyclePolicy.startsWithoutWindow(
            menuBarShown: true, launchedBySystem: false))
    }

    // MARK: - Montrer la fenêtre (BU-02)

    /// « Ouvrir Fouine » a deux moyens, et un seul cas sans issue.
    ///
    /// L'action SwiftUI sait FAIRE NAÎTRE la fenêtre ; la `NSWindow` gardée en
    /// réserve ne sert que si la fenêtre est déjà apparue une fois. Sans
    /// aucune des deux — l'application lancée sans fenêtre, où le `.task` qui
    /// retenait l'action n'a jamais tourné —, le menu Fenêtre et le clic sur
    /// l'icône du Dock ne faisaient rien du tout. C'est pour cela que le
    /// panneau de la barre des menus, qui vit dès le lancement, retient
    /// l'action à son tour.
    func testShowingTheWindowPrefersTheSceneActionThenTheKeptWindow() {
        XCTAssertEqual(WindowLifecyclePolicy.showWindowRoute(hasOpener: true,
                                                             hasWindow: false),
                       .openScene)
        XCTAssertEqual(WindowLifecyclePolicy.showWindowRoute(hasOpener: true,
                                                             hasWindow: true),
                       .openScene)
        XCTAssertEqual(WindowLifecyclePolicy.showWindowRoute(hasOpener: false,
                                                             hasWindow: true),
                       .orderFrontExisting)
        XCTAssertEqual(WindowLifecyclePolicy.showWindowRoute(hasOpener: false,
                                                             hasWindow: false),
                       .nothing,
                       "BU-02 : c'est l'impasse que l'enregistrement de "
                       + "l'action depuis le panneau de la barre des menus évite")
    }

    /// `NSApplicationLaunchIsDefaultLaunchKey` vaut `false` quand c'est le
    /// système qui ouvre l'app. La clé ABSENTE (vieux système, lancement hors
    /// bundle) doit se lire « lancé par un humain », le cas le moins
    /// surprenant.
    func testLaunchedBySystemReadsTheSystemKey() {
        let key = NSApplication.launchIsDefaultUserInfoKey
        XCTAssertTrue(WindowLifecyclePolicy.launchedBySystem([key: false]))
        XCTAssertFalse(WindowLifecyclePolicy.launchedBySystem([key: true]))
        XCTAssertFalse(WindowLifecyclePolicy.launchedBySystem([:]))
        XCTAssertFalse(WindowLifecyclePolicy.launchedBySystem(nil))
    }

    // MARK: - Ouvrir les réglages sur un onglet (LB1)

    /// L'onglet demandé attend la fenêtre qui naît, et ne sert qu'une fois :
    /// une ouverture par ⌘, plus tard ne doit pas retomber sur « Licence ».
    @MainActor
    func testTheRequestedSettingsTabIsTakenOnce() {
        SettingsWindow.pendingTab = .licence
        XCTAssertEqual(SettingsWindow.takePendingTab(), .licence)
        XCTAssertNil(SettingsWindow.takePendingTab())
        XCTAssertNil(SettingsWindow.pendingTab)
    }

    /// `showSettingsWindow:` n'ouvre rien depuis macOS 14 (pièges connus) : le
    /// sélecteur ne vit qu'au repli de `SettingsWindow.open()`, pour macOS 13.
    /// Un bouton qui l'enverrait lui-même serait de nouveau muet, et aucun
    /// autre test ne le verrait.
    func testOnlySettingsWindowSendsTheSettingsSelector() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // FouineAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // racine du dépôt
            .appendingPathComponent("Sources/FouineApp")
        let files = (FileManager.default.enumerator(at: sources,
                                                    includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "sources introuvables : \(sources.path)")
        let needle = "Selector((\"showSettingsWindow:\"))"
        var sends = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            sends += text.components(separatedBy: needle).count - 1
        }
        XCTAssertEqual(sends, 1, "le sélecteur ne s'envoie que depuis SettingsWindow.open()")
    }
}
