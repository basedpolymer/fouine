// AppInstallationTests.swift — « puis-je armer l'agent depuis CETTE copie ? »
// (lot J2). La décision est pure : trois URL en entrée, un verdict en sortie.

import XCTest
import FouineCore
@testable import FouineApp

final class AppInstallationTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private let installed = URL(fileURLWithPath: "/Applications/Fouine.app", isDirectory: true)

    // MARK: - Le cas où l'on arme

    func testInstalledUniqueAndDefaultCanRegister() {
        let d = AppInstallationCheck.decide(bundleURL: installed,
                                            copies: [installed], defaultCopy: installed)
        XCTAssertEqual(d, .canRegister)
        XCTAssertTrue(d.allowsRegistration)
        XCTAssertNil(AppInstallationText.describe(d))
    }

    /// LaunchServices qui ne connaît encore RIEN n'est pas un motif de refus :
    /// l'app vient peut-être d'être glissée dans Applications.
    func testUnknownToLaunchServicesStillRegisters() {
        XCTAssertEqual(
            AppInstallationCheck.decide(bundleURL: installed, copies: [], defaultCopy: nil),
            .canRegister)
    }

    // MARK: - Les trois refus

    /// Un build de travail, une copie dans Téléchargements, une app ouverte
    /// depuis l'image disque : launchd n'aura pas de chemin qui survive.
    func testOutsideApplicationsIsRefused() {
        let dev = url("/Users/moi/fouine/Fouine.app")
        let d = AppInstallationCheck.decide(bundleURL: dev, copies: [dev], defaultCopy: dev)
        XCTAssertEqual(d, .notInApplications)
        XCTAssertFalse(d.allowsRegistration)
        let text = AppInstallationText.describe(d)
        XCTAssertEqual(text, "Fouine must be in the Applications folder to index in the background. Move it there, open it from there, then try again.")
    }

    /// Le piège du 03/09/2026 : la copie du dépôt laissée par `make ci-bundle`
    /// porte un numéro de build supérieur et devient celle que macOS ouvre.
    func testSeveralCopiesAreRefusedEvenFromApplications() {
        let stray = url("/Users/moi/fouine/Fouine.app")
        let d = AppInstallationCheck.decide(bundleURL: installed,
                                            copies: [installed, stray], defaultCopy: stray)
        XCTAssertEqual(d, .severalCopies(others: ["/Users/moi/fouine/Fouine.app"]))
        XCTAssertNotNil(AppInstallationText.describe(d))
    }

    func testAnotherCopyIsTheDefault() {
        let other = url("/Users/moi/Desktop/Fouine.app")
        // `copies` ne rend que celle-ci, mais la copie par défaut est ailleurs :
        // deux chemins distincts, donc plusieurs copies.
        let d = AppInstallationCheck.decide(bundleURL: installed,
                                            copies: [installed], defaultCopy: other)
        XCTAssertEqual(d, .severalCopies(others: ["/Users/moi/Desktop/Fouine.app"]))
    }

    /// Une seule copie connue, ce n'est pas la mienne, et je suis pourtant sous
    /// /Applications : macOS ouvrirait l'autre.
    func testDefaultElsewhereWithSingleKnownCopy() {
        let other = url("/Applications/Utilities/Fouine.app")
        let d = AppInstallationCheck.decide(bundleURL: installed, copies: [], defaultCopy: other)
        XCTAssertEqual(d, .notTheDefaultCopy(defaultPath: "/Applications/Utilities/Fouine.app"))
        XCTAssertNotNil(AppInstallationText.describe(d))
    }

    /// Un dossier qui COMMENCE par « /Applications » sans être dedans
    /// (/ApplicationsBis) ne passe pas pour une installation.
    func testSiblingDirectoryIsNotApplications() {
        let fake = url("/ApplicationsBis/Fouine.app")
        XCTAssertEqual(
            AppInstallationCheck.decide(bundleURL: fake, copies: [fake], defaultCopy: fake),
            .notInApplications)
    }

    /// Le dossier attendu est paramétrable : le test n'écrit pas dans un vrai
    /// /Applications.
    func testApplicationsDirectoryIsParameterised() {
        let app = url("/tmp/Apps/Fouine.app")
        XCTAssertEqual(
            AppInstallationCheck.decide(bundleURL: app, copies: [app], defaultCopy: app,
                                        applicationsDirectory: "/tmp/Apps"),
            .canRegister)
    }
}

/// La marge sémantique DITE, pas chiffrée en écarts-types (lot J2).
final class SemanticMarginTextTests: XCTestCase {

    /// Quatre paliers, quatre phrases distinctes, et aucune ne dit « σ »,
    /// « écart-type », « cosinus » ni « vecteur » : le public n'est pas
    /// technicien (CLAUDE.md).
    func testFourTiersAndNoJargon() {
        let texts = [3.4, 2.0, 1.0, 0.2].map(SemanticMarginText.describe)
        XCTAssertEqual(Set(texts).count, 4, "quatre paliers, quatre phrases")
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            for banned in ["σ", "sigma", "cosine", "cosinus", "vector", "vecteur",
                           "margin", "marge", "standard deviation", "écart-type", "rank"] {
                XCTAssertFalse(text.lowercased().contains(banned), "« \(banned) » dans « \(text) »")
            }
        }
    }

    /// Les bornes tombent du bon côté : 2,5 · 1,5 · 0,75.
    func testTierBoundaries() {
        XCTAssertEqual(SemanticMarginText.describe(2.5), SemanticMarginText.describe(9.0))
        XCTAssertEqual(SemanticMarginText.describe(1.5), SemanticMarginText.describe(2.49))
        XCTAssertEqual(SemanticMarginText.describe(0.75), SemanticMarginText.describe(1.49))
        XCTAssertEqual(SemanticMarginText.describe(0.74), SemanticMarginText.describe(-3.0))
        XCTAssertNotEqual(SemanticMarginText.describe(2.5), SemanticMarginText.describe(2.49))
        XCTAssertNotEqual(SemanticMarginText.describe(0.75), SemanticMarginText.describe(0.74))
    }
}

