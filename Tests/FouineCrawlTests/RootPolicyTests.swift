// RootPolicyTests.swift — ce qu'un dossier a le droit d'être (audit D1).
// Propriété : A-Ingest.
//
// Les phrases testées ici sont celles que l'utilisateur lit, à l'identique, dans
// l'alerte de l'app et sur `stderr` de `fouine root add`.

import XCTest
import FouineCore
@testable import FouineCrawl

final class RootPolicyTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-rootpolicy-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Ce qui est refusé

    func testRefusesSystemAndHomeItself() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let refused: [URL] = [
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/System"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Library"),
            URL(fileURLWithPath: "/private"),
            home,
            home.appendingPathComponent("Library", isDirectory: true),
        ]
        for url in refused {
            XCTAssertNotNil(RootPolicy.refusalReason(for: url),
                            "\(url.path) doit être refusé comme racine")
        }
    }

    /// Les arbres système sont refusés AVEC leur contenu : `~/Library/Mail` et
    /// `/Library/Fonts` n'ont pas plus leur place dans l'index que leur racine.
    func testRefusesInsideSystemTrees() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertNotNil(RootPolicy.refusalReason(
            for: home.appendingPathComponent("Library/Application Support",
                                             isDirectory: true)))
        XCTAssertNotNil(RootPolicy.refusalReason(
            for: URL(fileURLWithPath: "/Library/Fonts")))
    }

    /// Le dossier d'une application que Fouine lit (Anki, Apple Notes, Bear)
    /// reste refusé, mais pas comme « dossier système sans documents » : le
    /// refus nomme l'application, pour que l'app montre sa case (14/09/2026,
    /// `~/Library/Application Support/Anki2/Matisse` choisi pour des cartes).
    func testApplicationStoresAreRefusedWithTheirApplication() {
        let home = "/Users/x"
        let anki = RootPolicy.application(
            owning: "/Users/x/Library/Application Support/Anki2/Matisse", home: home)
        XCTAssertEqual(anki, .anki)
        XCTAssertEqual(RootPolicy.application(
            owning: "/Users/x/Library/Application Support/Anki2", home: home), .anki)
        XCTAssertEqual(RootPolicy.application(
            owning: "/Users/x/Library/Group Containers/group.com.apple.notes", home: home),
                       .notes)
        XCTAssertEqual(RootPolicy.application(
            owning: "/Users/x/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data",
            home: home), .bear)
        // Le parent n'appartient à personne, et un nom qui COMMENCE pareil non plus.
        XCTAssertNil(RootPolicy.application(
            owning: "/Users/x/Library/Application Support", home: home))
        XCTAssertNil(RootPolicy.application(
            owning: "/Users/x/Library/Application Support/Anki2-sauvegarde", home: home))
        XCTAssertNil(RootPolicy.application(
            owning: "/Users/y/Library/Application Support/Anki2", home: home))

        let english = RootPolicy.Refusal.applicationData(path: "~/Library/Application Support/Anki2",
                                                         application: .anki).english
        XCTAssertTrue(english.contains("fouine sources enable anki"), english)
    }

    /// Sur une machine où Anki est installé, le vrai dossier passe par ce refus.
    func testRealAnkiFolderIsRefusedAsApplicationData() throws {
        let anki = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Anki2", isDirectory: true)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: anki.path),
                          "Anki n'est pas installé sur cette machine")
        guard case .applicationData(_, .anki)? = RootPolicy.refusal(for: anki) else {
            return XCTFail("attendu .applicationData(anki), obtenu "
                           + String(describing: RootPolicy.refusal(for: anki)))
        }
    }

    /// `/` et `/private` sont refusés EUX-MÊMES, pas leur contenu : la recette
    /// bâtit ses corpus jetables sous `/private/var/folders/…` et doit pouvoir
    /// les enregistrer.
    func testAcceptsChildrenOfPrivate() {
        XCTAssertNil(RootPolicy.refusalReason(for: scratch),
                     "un dossier temporaire (sous /private) doit être acceptable ; "
                     + "obtenu : \(RootPolicy.refusalReason(for: scratch) ?? "")")
    }

    func testRefusesFileAndMissingPath() throws {
        let file = scratch.appendingPathComponent("note.txt")
        try "texte".write(to: file, atomically: true, encoding: .utf8)
        // Le refus est TYPÉ depuis le palier 3.5 : on affirme sur le CAS, ce
        // que la phrase — anglaise ici, française dans l'app — ne fige plus.
        guard case .notADirectory = try XCTUnwrap(RootPolicy.refusal(for: file))
        else { return XCTFail("un fichier doit rendre .notADirectory") }

        let missing = scratch.appendingPathComponent("absent", isDirectory: true)
        guard case .missing = try XCTUnwrap(RootPolicy.refusal(for: missing))
        else { return XCTFail("un dossier absent doit rendre .missing") }
    }

    /// Un dossier dont les droits POSIX interdisent la lecture : c'est le cas que
    /// l'on peut fabriquer sans TCC, et il emprunte le même chemin de code que le
    /// refus TCC (les deux rendent EACCES/EPERM à l'énumération).
    func testRefusesUnreadableDirectory() throws {
        let locked = scratch.appendingPathComponent("verrouille", isDirectory: true)
        try FileManager.default.createDirectory(at: locked,
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: locked.path)
        }
        // `root` passe outre les permissions POSIX : le test n'a de sens que
        // pour un utilisateur ordinaire.
        try XCTSkipIf(getuid() == 0, "lancé en root : les droits POSIX ne mordent pas")

        let refusal = try XCTUnwrap(RootPolicy.refusal(for: locked),
                                    "un dossier illisible doit être refusé")
        guard case .permissionDenied = refusal else {
            return XCTFail("attendu .permissionDenied, obtenu \(refusal)")
        }
        // Et c'est LE cas qui porte le geste à faire.
        XCTAssertTrue(refusal.english.contains(RootProbe.tccGuidance),
                      refusal.english)
    }

    // MARK: - Ce qui passe

    func testAcceptsOrdinaryFolder() throws {
        let corpus = scratch.appendingPathComponent("Livres", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus,
                                                withIntermediateDirectories: true)
        XCTAssertNil(RootPolicy.refusal(for: corpus))
        XCTAssertNil(RootPolicy.advisory(for: corpus))
        XCTAssertEqual(RootPolicy.suggestedLabel(for: corpus), "Livres")
    }

    // MARK: - Ce qui passe AVEC un avertissement

    /// `~/Downloads` est le mode d'échec n°1 du projet (audit D19) : lisible dans
    /// le Finder, muet pour une app sans l'autorisation TCC correspondante. On
    /// l'accepte — c'est un dossier de documents légitime — mais on le dit.
    func testWarnsAboutDownloads() throws {
        guard let downloads = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first,
              FileManager.default.fileExists(atPath: downloads.path) else {
            throw XCTSkip("pas de dossier Téléchargements sur cette machine")
        }
        // Ironie du sort : le processus de test peut lui-même se voir refuser
        // Téléchargements par TCC. C'est justement ce que l'avertissement
        // annonce, et ce n'est pas une régression de la politique.
        if let refusal = RootPolicy.refusalReason(for: downloads) {
            throw XCTSkip("Téléchargements illisible depuis les tests : \(refusal)")
        }
        XCTAssertEqual(RootPolicy.advisory(for: downloads), .downloads)
    }
}
