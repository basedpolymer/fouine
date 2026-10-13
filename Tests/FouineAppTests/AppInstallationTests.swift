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
