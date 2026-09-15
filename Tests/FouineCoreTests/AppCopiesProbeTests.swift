// AppCopiesProbeTests.swift — le verdict sur les copies de Fouine.app (lot J2).
//
// Aucune interrogation de LaunchServices ici : `AppCopiesProbe.evaluate` est
// une fonction pure, on lui donne des URL et on lit son verdict. C'est tout
// l'intérêt d'avoir laissé l'appel système chez l'appelant.

import XCTest
@testable import FouineCore

final class AppCopiesProbeTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    // MARK: - Le cas sain

    func testSingleCopyInApplicationsIsOK() {
        let app = url("/Applications/Fouine.app")
        let r = AppCopiesProbe.evaluate(copies: [app], defaultCopy: app)
        XCTAssertEqual(r.verdict, .ok)
        XCTAssertTrue(r.isHealthy)
        XCTAssertNil(r.guidance)
        XCTAssertEqual(r.copies, ["/Applications/Fouine.app"])
        XCTAssertEqual(r.defaultCopy, "/Applications/Fouine.app")
        XCTAssertEqual(r.displayText, "/Applications/Fouine.app")
    }

    /// LaunchServices rend des URL de RÉPERTOIRE : elles portent une barre
    /// oblique finale. Sans normalisation, tout le reste compare de travers.
    func testTrailingSlashIsNormalised() {
        let r = AppCopiesProbe.evaluate(
            copies: [URL(fileURLWithPath: "/Applications/Fouine.app/")],
            defaultCopy: URL(fileURLWithPath: "/Applications/Fouine.app/"))
        XCTAssertEqual(r.verdict, .ok)
        XCTAssertEqual(r.copies, ["/Applications/Fouine.app"])
    }

    /// Le même chemin rendu deux fois (enregistrement disque + volatil) ne fait
    /// pas deux copies.
    func testDuplicateEntriesAreCollapsed() {
        let a = url("/Applications/Fouine.app")
        let r = AppCopiesProbe.evaluate(copies: [a, url("/Applications/Fouine.app/")], defaultCopy: a)
        XCTAssertEqual(r.copies.count, 1)
        XCTAssertEqual(r.verdict, .ok)
    }

    // MARK: - Le piège du 03/09/2026

    func testTwoCopiesAreReportedWithTheExtras() {
        let installed = url("/Applications/Fouine.app")
        let stray = url("/Users/moi/fouine/Fouine.app")
        // Numéro de build plus haut : LaunchServices préfère la copie du dépôt.
        let r = AppCopiesProbe.evaluate(copies: [installed, stray], defaultCopy: stray)
        XCTAssertEqual(r.verdict, .multipleCopies(extras: ["/Users/moi/fouine/Fouine.app"]))
        XCTAssertFalse(r.isHealthy)
        XCTAssertEqual(r.defaultCopy, "/Users/moi/fouine/Fouine.app")
        XCTAssertEqual(r.copies, ["/Applications/Fouine.app", "/Users/moi/fouine/Fouine.app"])
        // Le geste dit les DEUX moitiés : supprimer, PUIS refaire
        // l'enregistrement — supprimer seul ne répare pas (exigence de code
        // figée dans Background Task Management).
        XCTAssertTrue(r.guidance?.contains("delete the other copies") == true)
        XCTAssertTrue(r.guidance?.contains("off and on again") == true)
        XCTAssertTrue(r.displayText.contains("/Users/moi/fouine/Fouine.app"))
    }

    /// La copie par défaut peut ne pas figurer dans l'énumération : les deux
    /// appels LaunchServices ne sont pas atomiques. Elle compte quand même.
    func testDefaultAbsentFromEnumerationStillCounts() {
        let r = AppCopiesProbe.evaluate(
            copies: [url("/Applications/Fouine.app")],
            defaultCopy: url("/Users/moi/Downloads/Fouine.app"))
        guard case .multipleCopies = r.verdict else {
            return XCTFail("deux chemins distincts = deux copies, verdict \(r.verdict)")
        }
        XCTAssertEqual(r.copies.count, 2)
    }

    /// L'ordre de la liste ne doit pas dépendre de celui de LaunchServices :
    /// elle est lue par un humain qui va supprimer des fichiers.
    func testCopyListIsSorted() {
        let a = url("/Applications/Fouine.app")
        let b = url("/Users/moi/Downloads/Fouine.app")
        let one = AppCopiesProbe.evaluate(copies: [a, b], defaultCopy: a)
        let other = AppCopiesProbe.evaluate(copies: [b, a], defaultCopy: a)
        XCTAssertEqual(one.copies, other.copies)
        XCTAssertEqual(one.copies, ["/Applications/Fouine.app", "/Users/moi/Downloads/Fouine.app"])
    }

    // MARK: - Copie unique, mais au mauvais endroit

    func testSingleCopyOutsideApplications() {
        let d = url("/Users/moi/Downloads/Fouine.app")
        let r = AppCopiesProbe.evaluate(copies: [d], defaultCopy: d)
        XCTAssertEqual(r.verdict, .outsideApplications(path: "/Users/moi/Downloads/Fouine.app"))
        XCTAssertFalse(r.isHealthy)
        XCTAssertTrue(r.guidance?.contains("/Applications") == true)
    }

    // MARK: - Rien d'installé

    /// La CLI bâtie depuis le dépôt tourne sans app installée : ce n'est pas
    /// une panne, et `doctor` ne doit pas l'annoncer comme telle.
    func testNoCopyIsNotAFailure() {
        let r = AppCopiesProbe.evaluate(copies: [], defaultCopy: nil)
        XCTAssertEqual(r.verdict, .notInstalled)
        XCTAssertTrue(r.isHealthy)
        XCTAssertNil(r.guidance)
        XCTAssertEqual(r.copies, [])
        XCTAssertNil(r.defaultCopy)
    }

    /// L'emplacement attendu est paramétrable : les tests n'ont pas besoin
    /// d'un /Applications réel.
    func testExpectedPathIsParameterised() {
        let a = url("/opt/Fouine.app")
        let r = AppCopiesProbe.evaluate(copies: [a], defaultCopy: a, expected: "/opt/Fouine.app")
        XCTAssertEqual(r.verdict, .ok)
    }

    // MARK: - A2-03 · une Fouine.app d'un ANCIEN identifiant à l'emplacement canonique

    /// Le faux bundle du test : `<dir>/Fouine.app/Contents/Info.plist`, avec
    /// l'identifiant et le numéro de build qu'on veut lui donner.
    private func makeBundle(identifier: String?, version: String?) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-apps-\(UUID().uuidString)")
        let contents = dir.appendingPathComponent("Fouine.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleName": "Fouine"]
        if let identifier { plist["CFBundleIdentifier"] = identifier }
        if let version { plist["CFBundleVersion"] = version }
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.path
    }

    /// Un bundle d'un AUTRE identifiant posé à l'emplacement canonique : la
    /// sonde le LIT toujours — `atExpectedPath` le rend, et `doctor` l'affiche
    /// — mais il ne vaut plus de verdict à lui seul. LaunchServices, interrogé
    /// pour l'identifiant courant, n'en connaît aucune copie : c'est « pas
    /// installée », et c'est exact.
    func testAForeignBundleAtCanonicalPathIsReadButNotInstalled() throws {
        let dir = try makeBundle(identifier: "org.example.autre", version: "54")
        let stamp = AppCopiesProbe.stampAtCanonicalPath(applicationsDirectory: dir)
        XCTAssertEqual(stamp?.identifier, "org.example.autre")
        XCTAssertEqual(stamp?.version, "54")

        let r = AppCopiesProbe.evaluate(copies: [], defaultCopy: nil,
                                        expected: dir + "/Fouine.app",
                                        canonical: stamp)
        XCTAssertEqual(r.verdict, .notInstalled)
        XCTAssertNil(r.guidance)
        XCTAssertEqual(r.atExpectedPath?.path, dir + "/Fouine.app")
    }

    /// Le MÊME bundle avec le BON identifiant ne produit rien : le verdict
    /// retombe sur ce que LaunchServices sait.
    func testSameBundleWithCurrentIdentifierIsSilent() throws {
        let dir = try makeBundle(identifier: "io.github.basedpolymer.fouine", version: "241")
        let stamp = AppCopiesProbe.stampAtCanonicalPath(applicationsDirectory: dir)
        let app = url(dir + "/Fouine.app")
        let r = AppCopiesProbe.evaluate(copies: [app], defaultCopy: app,
                                        expected: dir + "/Fouine.app",
                                        canonical: stamp)
        XCTAssertEqual(r.verdict, .ok)
        XCTAssertNil(r.guidance)
    }

    /// Rien dans le dossier Applications : pas de sonde, pas de verdict.
    func testNoBundleAtCanonicalPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(AppCopiesProbe.stampAtCanonicalPath(applicationsDirectory: dir.path))
    }

    /// Un `Info.plist` sans `CFBundleIdentifier` n'est pas un bundle étranger :
    /// on ne juge que ce qu'on a lu.
    func testBundleWithoutIdentifierIsNotJudged() throws {
        let dir = try makeBundle(identifier: nil, version: "1")
        let stamp = AppCopiesProbe.stampAtCanonicalPath(applicationsDirectory: dir)
        XCTAssertNil(stamp?.identifier)
        let r = AppCopiesProbe.evaluate(copies: [], defaultCopy: nil,
                                        expected: dir + "/Fouine.app",
                                        canonical: stamp)
        XCTAssertEqual(r.verdict, .notInstalled)
    }
}
