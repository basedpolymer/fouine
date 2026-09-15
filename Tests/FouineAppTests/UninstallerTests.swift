// UninstallerTests.swift — le PLAN de désinstallation (audit D13, palier 3.4).
// Propriété : A-App.
//
// `Uninstaller.perform` n'est PAS testé, et ne doit pas l'être : il
// désenregistre l'agent d'arrière-plan de la machine qui fait tourner les
// tests, et met une application à la corbeille. C'est pour cela que toute la
// logique vit dans `plan`, une fonction pure de chemins injectés — ce qui est
// vérifiable l'est ici, sur des répertoires temporaires.
//
// Les deux garde-fous qui comptent, et qui sont ce que ces tests protègent :
//
//   · RIEN HORS DE ~/Library. `FOUINE_DB` peut désigner un dossier du corpus,
//     un volume externe, `~/Library` lui-même. Un `rm -rf` sur ce chemin est
//     irrattrapable ; le plan le marque « non supprimable », l'affiche, et
//     s'arrête là ;
//   · RIEN QUI NE SOIT À NOUS dans /usr/local/bin. Le lien `fouine` n'est
//     retiré que s'il pointe DANS cette copie de l'application ; un binaire
//     Homebrew ou compilé à la main reste en place.

import Foundation
import XCTest
@testable import FouineApp

final class UninstallerTests: XCTestCase {

    private var sandbox: URL!
    private var home: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-uninstall-\(UUID().uuidString)",
                                    isDirectory: true)
        home = sandbox.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let sandbox else { return }
        // Un test rend un dossier non inscriptible : le rendre avant d'effacer.
        let bin = sandbox.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: bin.path)
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - Fabrique

    @discardableResult
    private func write(_ path: String, bytes: Int = 64,
                       under base: URL? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2A, count: bytes).write(to: url)
        return url
    }

    private func plan(databaseURL: URL, agentLogURL: URL? = nil,
                      preferencesURL: URL? = nil,
                      cliLink: URL? = nil,
                      bundledCLIParent: URL? = nil,
                      bundle: URL? = nil) -> Uninstaller.Plan {
        Uninstaller.plan(
            databaseURL: databaseURL,
            agentLogURL: agentLogURL
                ?? home.appendingPathComponent("Library/Logs/Fouine/fouine.log"),
            preferencesURL: preferencesURL
                ?? home.appendingPathComponent(
                    "Library/Preferences/io.github.basedpolymer.fouine.plist"),
            cliLink: cliLink
                ?? sandbox.appendingPathComponent("bin/fouine"),
            bundledCLIParent: bundledCLIParent,
            bundle: bundle,
            home: home)
    }

    // MARK: - Les trois emplacements

    func testPlanFindsTheThreeLocationsAndTheirSizes() throws {
        let database = try write("Library/Application Support/Fouine/fouine.db",
                                 bytes: 500)
        try write("Library/Application Support/Fouine/fouine.db-wal", bytes: 300)
        try write("Library/Application Support/Fouine/models/e5-small/meta.json",
                  bytes: 200)
        try write("Library/Logs/Fouine/fouine.log", bytes: 100)
        try write("Library/Preferences/io.github.basedpolymer.fouine.plist", bytes: 50)

        let result = plan(databaseURL: database)

        // Le dossier s'appelle « Fouine » : c'est LUI qui est visé, en entier.
        XCTAssertEqual(result.support.count, 1)
        XCTAssertEqual(result.support[0].url.lastPathComponent, "Fouine")
        XCTAssertTrue(result.support[0].exists)
        XCTAssertTrue(result.support[0].removable)
        // La taille est CUMULÉE : base + journal + modèle.
        XCTAssertEqual(result.support[0].bytes, 1_000)

        XCTAssertTrue(result.logs.exists)
        XCTAssertTrue(result.logs.removable)
        XCTAssertEqual(result.logs.bytes, 100)

        XCTAssertTrue(result.preferences.exists)
        XCTAssertTrue(result.preferences.removable)
        XCTAssertEqual(result.preferences.bytes, 50)
        XCTAssertEqual(result.preferencesDomain, Prefs.suite)
    }

    func testAbsentLocationsAreReportedWithoutSize() throws {
        let database = home.appendingPathComponent(
            "Library/Application Support/Fouine/fouine.db")
        let result = plan(databaseURL: database)
        XCTAssertFalse(result.support[0].exists)
        XCTAssertEqual(result.support[0].bytes, 0)
        // Absent mais LÉGITIME : la case reste cochable si le dossier apparaît.
        XCTAssertTrue(result.support[0].removable)
    }

    // MARK: - Garde-fou 1 : rien hors de ~/Library

    /// `FOUINE_DB` peut pointer n'importe où — un dossier du corpus, par
    /// exemple. Le plan le montre et REFUSE de le supprimer.
    func testDatabaseOutsideLibraryIsShownButNeverDeleted() throws {
        let database = try write("fouine.db", bytes: 128,
                                 under: sandbox.appendingPathComponent(
                                    "corpus", isDirectory: true))
        let result = plan(databaseURL: database)
        // Le dossier ne s'appelle pas « Fouine » : seuls le fichier de base et
        // ses deux compagnons sont visés — et, hors ~/Library, pas même eux.
        XCTAssertEqual(result.support.map(\.url.lastPathComponent),
                       ["fouine.db", "fouine.db-wal", "fouine.db-shm"])
        XCTAssertTrue(result.support[0].exists)
        XCTAssertTrue(result.support.allSatisfy { !$0.removable },
                      "hors ~/Library, rien ne doit être supprimable")
        XCTAssertFalse(result.support.contains { $0.url.lastPathComponent == "corpus" },
                       "le dossier PARENT ne doit jamais être une cible")
    }

    /// BU-32, LE CAS QUE LE GARDE-FOU NE COUVRAIT PAS. Une base posée DANS
    /// `~/Library` mais hors d'un dossier à nous est parfaitement légitime — et
    /// le plan visait alors le dossier PARENT, donc tout ce qu'il contenait.
    func testADatabaseInsideLibraryButOutsideOurFolderTargetsOnlyItsOwnFiles() throws {
        let database = try write("Library/Application Support/Autre/x.db",
                                 bytes: 500)
        try write("Library/Application Support/Autre/x.db-wal", bytes: 300)
        try write("Library/Application Support/Autre/x.db-shm", bytes: 100)
        // Ce qui appartient à quelqu'un d'autre, dans le même dossier.
        try write("Library/Application Support/Autre/precieux.sqlite", bytes: 9_000)

        let result = plan(databaseURL: database)

        XCTAssertEqual(result.support.map(\.url.lastPathComponent),
                       ["x.db", "x.db-wal", "x.db-shm"])
        XCTAssertTrue(result.support.allSatisfy(\.exists))
        XCTAssertTrue(result.support.allSatisfy(\.removable),
                      "sous ~/Library, les trois fichiers restent supprimables")
        XCTAssertEqual(result.support.reduce(0) { $0 + $1.bytes }, 900,
                       "la taille annoncée est celle des trois fichiers, "
                       + "pas celle du dossier")
        XCTAssertFalse(result.support.contains { $0.url.lastPathComponent == "Autre" },
                       "le dossier d'à côté ne doit jamais être une cible")
        // Le dossier reste connu pour ATTENDRE le verrou — jamais pour être
        // supprimé.
        XCTAssertEqual(result.supportDirectory.lastPathComponent, "Autre")
    }

    /// La borne la plus importante : `~/Library` et `~/Library/Application
    /// Support` ne sont PAS des dossiers à nous. Les supprimer emporterait les
    /// données de toutes les applications du Mac.
    func testLibraryItselfAndApplicationSupportAreRefused() {
        XCTAssertFalse(Uninstaller.isUnderLibrary(
            home.appendingPathComponent("Library"), home: home))
        XCTAssertFalse(Uninstaller.isUnderLibrary(
            home.appendingPathComponent("Library/Application Support"), home: home))
        XCTAssertFalse(Uninstaller.isUnderLibrary(home, home: home))
        XCTAssertFalse(Uninstaller.isUnderLibrary(
            URL(fileURLWithPath: "/Library/Application Support/Fouine"), home: home))

        XCTAssertTrue(Uninstaller.isUnderLibrary(
            home.appendingPathComponent("Library/Application Support/Fouine"),
            home: home))
        XCTAssertTrue(Uninstaller.isUnderLibrary(
            home.appendingPathComponent("Library/Logs/Fouine"), home: home))
        XCTAssertTrue(Uninstaller.isUnderLibrary(
            home.appendingPathComponent(
                "Library/Preferences/io.github.basedpolymer.fouine.plist"), home: home))
    }

    /// Un `..` ne doit pas servir à sortir de ~/Library en douce.
    func testRelativeEscapeIsRefused() {
        let sneaky = home.appendingPathComponent("Library/Logs/../../Documents")
        XCTAssertFalse(Uninstaller.isUnderLibrary(sneaky, home: home))
    }

    func testLogPathOutsideLibraryIsRefusedToo() throws {
        let log = try write("agent.log", bytes: 32,
                            under: sandbox.appendingPathComponent("ailleurs",
                                                                  isDirectory: true))
        let result = plan(
            databaseURL: home.appendingPathComponent(
                "Library/Application Support/Fouine/fouine.db"),
            agentLogURL: log)
        XCTAssertTrue(result.logs.exists)
        XCTAssertFalse(result.logs.removable)
    }

    // MARK: - Garde-fou 2 : rien qui ne soit à nous dans /usr/local/bin

    private func makeBundleWithCLI() throws -> URL {
        let bundle = sandbox.appendingPathComponent("Fouine.app", isDirectory: true)
        try write("Contents/Helpers/fouine", bytes: 16, under: bundle)
        return bundle
    }

    func testNoLinkAtAllIsNothingToUndo() {
        let result = plan(databaseURL: home.appendingPathComponent(
            "Library/Application Support/Fouine/fouine.db"))
        XCTAssertEqual(result.cli, .absent)
    }

    func testLinkIntoThisCopyIsRemoved() throws {
        let bundle = try makeBundleWithCLI()
        let link = sandbox.appendingPathComponent("bin/fouine")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = bundle.appendingPathComponent("Contents/Helpers/fouine")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: destination)

        let result = plan(databaseURL: home.appendingPathComponent(
            "Library/Application Support/Fouine/fouine.db"),
                          cliLink: link, bundledCLIParent: bundle)
        XCTAssertEqual(result.cli, .ours(link: link, target: destination.path))
    }

    /// Le cas qui compte : un lien vers une AUTRE copie de Fouine (ou vers
    /// autre chose). On n'y touche pas, et on dit où il pointe.
    func testLinkElsewhereIsLeftAlone() throws {
        let bundle = try makeBundleWithCLI()
        let other = sandbox.appendingPathComponent("Autre.app/Contents/Helpers/fouine")
        try FileManager.default.createDirectory(
            at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x1]).write(to: other)

        let link = sandbox.appendingPathComponent("bin/fouine")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: other)

        let result = plan(databaseURL: home.appendingPathComponent(
            "Library/Application Support/Fouine/fouine.db"),
                          cliLink: link, bundledCLIParent: bundle)
        XCTAssertEqual(result.cli, .foreign(link: link, target: other.path))
    }

    /// Hors bundle (`swift run FouineApp`) il n'y a aucune copie de référence :
    /// tout lien est alors étranger, et rien n'est retiré.
    func testWithoutABundleEveryLinkIsForeign() throws {
        let link = sandbox.appendingPathComponent("bin/fouine")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))

        let result = plan(databaseURL: home.appendingPathComponent(
            "Library/Application Support/Fouine/fouine.db"),
                          cliLink: link, bundledCLIParent: nil)
        XCTAssertEqual(result.cli, .foreign(link: link, target: "/usr/bin/true"))
    }

    func testARealFileIsNeverOurs() throws {
        let bundle = try makeBundleWithCLI()
        let link = try write("bin/fouine", bytes: 8, under: sandbox)
        let result = plan(databaseURL: home.appendingPathComponent(
            "Library/Application Support/Fouine/fouine.db"),
                          cliLink: link, bundledCLIParent: bundle)
        XCTAssertEqual(result.cli, .notALink(link))
    }

    /// Dossier non inscriptible : l'app n'appelle JAMAIS `sudo`, elle affiche
    /// la commande (mêmes règles que `CLIInstaller`).
    func testUnwritableDirectoryYieldsACommandInsteadOfSudo() throws {
        let bundle = try makeBundleWithCLI()
        let bin = sandbox.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin,
                                                withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("fouine")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: bundle.appendingPathComponent("Contents/Helpers/fouine"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: bin.path)
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: bin.path),
                      "le dossier reste inscriptible (test lancé en root ?)")

        let result = plan(databaseURL: home.appendingPathComponent(
            "Library/Application Support/Fouine/fouine.db"),
                          cliLink: link, bundledCLIParent: bundle)
        XCTAssertEqual(result.cli,
                       .manual(link: link, command: "sudo rm '\(link.path)'"))
    }

    // MARK: - Le bundle à mettre à la corbeille

    func testBundleIsCarriedThroughThePlan() {
        let bundle = URL(fileURLWithPath: "/Applications/Fouine.app")
        let result = plan(databaseURL: home.appendingPathComponent(
            "Library/Application Support/Fouine/fouine.db"), bundle: bundle)
        XCTAssertEqual(result.bundle, bundle)
    }

    /// Seule une `.app` est une application à jeter. Le bundle de test en est
    /// la démonstration la plus simple : `swift test` tourne dans un `.xctest`,
    /// et l'élément de menu doit y être désactivé exactement comme sous
    /// `swift run FouineApp`.
    func testOnlyADotAppIsABundleToTrash() {
        XCTAssertNil(Uninstaller.bundleToTrash(Bundle(for: Self.self)))
    }

    // MARK: - Tailles

    func testSizeOfAFileAndOfADirectory() throws {
        let file = try write("Library/Logs/Fouine/fouine.log", bytes: 77)
        XCTAssertEqual(Uninstaller.size(of: file), 77)
        XCTAssertEqual(Uninstaller.size(of: file.deletingLastPathComponent()), 77)
        XCTAssertEqual(Uninstaller.size(of: sandbox.appendingPathComponent("néant")), 0)
    }

    // MARK: - Alignement Cask (audit H4, U1)

    func testCaskZapPathsMatchUninstallerZapPaths() throws {
        let repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let caskURL = repoRoot.appendingPathComponent("Packaging/homebrew/fouine.rb")
        let content = try String(contentsOf: caskURL, encoding: .utf8)

        guard let zapRange = content.range(of: "zap trash: \\[([^\\]]+)\\]", options: .regularExpression) else {
            XCTFail("Bloc zap trash introuvable dans fouine.rb")
            return
        }
        let block = String(content[zapRange])
        let regex = try NSRegularExpression(pattern: "\"([^\"]+)\"")
        let nsBlock = block as NSString
        let matches = regex.matches(in: block, range: NSRange(location: 0, length: nsBlock.length))
        let extractedPaths = matches.map { nsBlock.substring(with: $0.range(at: 1)) }

        XCTAssertEqual(extractedPaths.count, 7, "Le bloc zap de fouine.rb doit contenir 7 chemins")
        XCTAssertEqual(extractedPaths, Uninstaller.zapPaths,
                       "Les chemins du bloc zap de fouine.rb doivent correspondre exactement à Uninstaller.zapPaths")
    }

    /// Le plan porte les sept cibles du bloc zap, et RIEN de plus : les quatre
    /// chemins `com.mathis.fouine*` de l'ancien identifiant de bundle ont
    /// disparu avec la rétrocompatibilité (lot J1). L'application n'a jamais
    /// été distribuée sous cet identifiant ; l'histoire du renommage reste au
    /// CHANGELOG.
    func testPlanCoversEveryZapPathAndNothingElse() throws {
        let database = try write("Library/Application Support/Fouine/fouine.db", bytes: 100)
        try write("Library/Caches/fouine/cache.db", bytes: 60)

        let result = plan(databaseURL: database)
        XCTAssertEqual(result.zapTargets.count, 7)
        XCTAssertEqual(result.zapTargets.map(\.url.lastPathComponent),
                       Uninstaller.zapPaths.map { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(result.zapTargets.filter(\.exists).count, 2,
                       "le dossier de la base et celui du cache existent, les cinq autres non")
        XCTAssertFalse(result.zapTargets.contains { $0.url.path.contains("com.mathis.fouine") },
                       "plus aucun chemin de l'ancien identifiant de bundle")
    }
}
