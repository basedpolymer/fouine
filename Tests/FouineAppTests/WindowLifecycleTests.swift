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

    // MARK: - La fenêtre qui déborde (pièges connus)

    /// La barre d'état des résultats n'est ni une `List` ni un `ScrollView` :
    /// un texte figé en hauteur y fait mesurer la colonne à largeur nulle, et
    /// le `NavigationSplitView` déborde de la fenêtre — champ de recherche
    /// derrière le titre. Arrivé deux fois : à requête vide (11/09/2026), puis
    /// par la ligne « Few pages carry all your words » (24/09/2026). Chaque
    /// ligne de la barre, et chaque avis qu'elle affiche, passe à la ligne par
    /// un cadre.
    func testResultsStatusBarNeverFixesATextHeight() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // FouineAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // racine du dépôt
            .appendingPathComponent("Sources/FouineApp/Views/ResultsView.swift")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: "\n")
        let pattern = try NSRegularExpression(
            pattern: #"^    private var (statusBar|countsRow|commandsRow|\w+Notice): some View \{$"#)
        var checked: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let match = pattern.firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line) else {
                index += 1
                continue
            }
            let name = String(line[nameRange])
            checked.append(name)
            index += 1
            // Le code seul : les commentaires citent le modificateur interdit.
            while index < lines.count, lines[index] != "    }" {
                let code = lines[index].components(separatedBy: "//")[0]
                XCTAssertFalse(code.contains("fixedSize(horizontal: false, vertical: true)"),
                               "\(name), ligne \(index + 1) : un cadre, pas fixedSize")
                index += 1
            }
        }
        XCTAssertTrue(checked.contains("statusBar"), "barre d'état introuvable")
        XCTAssertTrue(checked.contains("quorumNotice"), "avis de quorum introuvable")
        XCTAssertGreaterThanOrEqual(checked.count, 10, "blocs lus : \(checked)")
    }
}
