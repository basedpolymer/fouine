// DeepLinkRouterTests.swift — ce que l'app fait d'un lien reçu (lot INT-L1).
// Propriété : A-App.
//
// Le routeur reçoit deux fermetures et rend une décision : les six cas se
// jouent donc ici en mémoire, sans base jetable, sans fenêtre et sans fichier.

import XCTest
import FouineCore
@testable import FouineApp

final class DeepLinkRouterTests: XCTestCase {

    private static let roots = ["/Users/x/Docs"]

    private func action(_ url: String, known: Int64? = nil,
                        kind: DeepLinkFileKind = .missing,
                        roots: [String] = DeepLinkRouterTests.roots)
        -> DeepLinkAction {
        DeepLinkRouter.action(for: URL(string: url)!,
                              resolve: { _ in known },
                              probe: { _ in kind },
                              roots: roots)
    }

    // MARK: - Les cinq décisions

    func testAKnownPageOpensItsPreview() {
        XCTAssertEqual(action("fouine://open?path=/a/b.pdf&page=87", known: 12),
                       .showPage(HitKey(docID: 12, page: 87)))
    }

    func testALinkWithoutAPageOpensTheDocument() {
        XCTAssertEqual(action("fouine://open?path=/a/b.pdf", known: 12),
                       .showDocument(docID: 12))
    }

    func testTheDocumentFormResolvesTheSameWay() {
        XCTAssertEqual(action("fouine://open?doc=12&page=3", known: 12),
                       .showPage(HitKey(docID: 12, page: 3)))
    }

    /// Le moment d'un enregistrement voyage jusqu'à la fenêtre (lot PV1) :
    /// c'est elle qui pose la tête de lecture.
    func testAMomentTravelsWithThePage() {
        XCTAssertEqual(action("fouine://open?path=/a/cours.m4a&page=2&t=760",
                              known: 12),
                       .showPage(HitKey(docID: 12, page: 2), time: 760))
    }

    /// Une page hors bornes ouvre la page 1 (BU-18) : le moment, lui, valait
    /// pour la fenêtre citée et ne la suit pas — il ferait écouter un autre
    /// passage que celui annoncé.
    func testAMomentDoesNotFollowAPageThatNoLongerExists() {
        XCTAssertEqual(
            DeepLinkRouter.action(
                for: URL(string: "fouine://open?doc=12&page=99&t=760")!,
                resolve: { _ in 12 }, probe: { _ in .missing },
                roots: Self.roots, pages: { _ in 4 }),
            .showPage(HitKey(docID: 12, page: 1), missingPage: 99))
    }

    func testASearchLinkReplaysTheQuery() {
        XCTAssertEqual(action("fouine://search?q=polym%C3%A8re"),
                       .search("polymère"))
    }

    /// Le document est encore là, SOUS UN DOSSIER SUIVI : la feuille peut
    /// proposer de l'ouvrir.
    func testAnUnknownDocumentUnderAWatchedFolderOffersToOpenIt() {
        XCTAssertEqual(action("fouine://open?path=/Users/x/Docs/b.pdf&page=2",
                              known: nil, kind: .regular),
                       .unknownDocument(path: "/Users/x/Docs/b.pdf", canOpen: true))
    }

    func testAnUnknownDocumentGoneFromDiskOffersNothing() {
        XCTAssertEqual(action("fouine://open?path=/Users/x/Docs/b.pdf&page=2",
                              known: nil, kind: .missing),
                       .unknownDocument(path: "/Users/x/Docs/b.pdf", canOpen: false))
    }

    /// Forme `doc` non résolue : il n'y a AUCUN chemin à proposer d'ouvrir —
    /// le lien n'en portait pas.
    func testAnUnknownDocumentIdentifierHasNoFileToOffer() {
        XCTAssertEqual(action("fouine://open?doc=99&page=2", known: nil,
                              kind: .regular),
                       .unknownDocument(path: "", canOpen: false))
    }

    // MARK: - BU-01 : ce que le bouton « Ouvrir le fichier » n'ouvre plus

    /// LE CAS REPRODUIT À L'ÉCRAN. Une page web appelle
    /// `fouine://open?path=/System/Applications/Calculator.app`, Fouine passe au
    /// premier plan, et le bouton bleu aurait lancé la Calculette.
    func testAnApplicationBundleIsNeverOffered() {
        XCTAssertEqual(
            action("fouine://open?path=/System/Applications/Calculator.app",
                   known: nil, kind: .package),
            .unknownDocument(path: "/System/Applications/Calculator.app",
                             canOpen: false))
    }

    func testAFileOutsideEveryWatchedFolderIsNeverOffered() {
        XCTAssertEqual(action("fouine://open?path=/tmp/piege.pdf",
                              known: nil, kind: .regular),
                       .unknownDocument(path: "/tmp/piege.pdf", canOpen: false))
    }

    /// Un script est un fichier ORDINAIRE pour `FileManager` : c'est le bit
    /// d'exécution qui le distingue, et c'est justement celui qu'il ne faut pas
    /// lancer — même sous un dossier suivi.
    func testAnExecutableUnderAWatchedFolderIsNeverOffered() {
        XCTAssertEqual(action("fouine://open?path=/Users/x/Docs/piege.sh",
                              known: nil, kind: .executable),
                       .unknownDocument(path: "/Users/x/Docs/piege.sh",
                                        canOpen: false))
    }

    func testAFolderIsNeverOffered() {
        XCTAssertEqual(action("fouine://open?path=/Users/x/Docs/sous-dossier",
                              known: nil, kind: .directory),
                       .unknownDocument(path: "/Users/x/Docs/sous-dossier",
                                        canOpen: false))
    }

    /// LE PRÉFIXE TROMPEUR : `/Users/x/Docs2` n'est pas sous `/Users/x/Docs`.
    /// Une comparaison de chaînes sans le `/` final l'aurait cru.
    func testASiblingFolderWithAMisleadingPrefixIsNotUnderTheRoot() {
        XCTAssertEqual(action("fouine://open?path=/Users/x/Docs2/a.pdf",
                              known: nil, kind: .regular),
                       .unknownDocument(path: "/Users/x/Docs2/a.pdf",
                                        canOpen: false))
    }

    /// Un `.rtfd` EST un paquet, et c'est pourtant un document que Fouine
    /// indexe : la règle est « paquet dont l'extension est un format connu ».
    func testAnRTFDPackageUnderAWatchedFolderStaysOpenable() {
        XCTAssertEqual(action("fouine://open?path=/Users/x/Docs/note.rtfd",
                              known: nil, kind: .package),
                       .unknownDocument(path: "/Users/x/Docs/note.rtfd",
                                        canOpen: true))
    }

    /// Sans aucune racine — l'app lancée avant que l'index soit ouvert — rien
    /// n'est ouvrable. C'est le bon défaut.
    func testWithoutAnyWatchedFolderNothingIsOpenable() {
        XCTAssertEqual(action("fouine://open?path=/Users/x/Docs/b.pdf",
                              known: nil, kind: .regular, roots: []),
                       .unknownDocument(path: "/Users/x/Docs/b.pdf",
                                        canOpen: false))
    }

    func testAnythingElseIsInvalid() {
        XCTAssertEqual(action("https://example.org/a"), .invalid)
        XCTAssertEqual(action("fouine://open?page=4"), .invalid)
    }

    // MARK: - La sonde, sur de vrais fichiers

    /// La décision est pure, mais elle vaut ce que vaut la sonde : c'est elle
    /// qui distingue un paquet d'un dossier et un script d'un document. Sur de
    /// VRAIS fichiers, donc — la question « macOS voit-il un `.rtfd` comme un
    /// paquet ? » ne se répond pas en mémoire.
    func testTheFileSystemProbeTellsTheFourKindsApart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-probe-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let regular = directory.appendingPathComponent("note.txt")
        try Data("bonjour".utf8).write(to: regular)
        let script = directory.appendingPathComponent("piege.sh")
        try Data("#!/bin/sh\nsay pwned\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        let folder = directory.appendingPathComponent("dossier", isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let package = directory.appendingPathComponent("note.rtfd",
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: package,
                                                withIntermediateDirectories: true)

        XCTAssertEqual(DeepLinkRouter.probeFileSystem(regular.path), .regular)
        XCTAssertEqual(DeepLinkRouter.probeFileSystem(script.path), .executable)
        XCTAssertEqual(DeepLinkRouter.probeFileSystem(folder.path), .directory)
        XCTAssertEqual(DeepLinkRouter.probeFileSystem(package.path), .package)
        XCTAssertEqual(DeepLinkRouter.probeFileSystem(
            directory.appendingPathComponent("absent.pdf").path), .missing)

        // Et le verdict complet, sur ces mêmes fichiers.
        let roots = [directory.path]
        XCTAssertTrue(DeepLinkRouter.canOpen(
            path: regular.path,
            kind: DeepLinkRouter.probeFileSystem(regular.path), roots: roots))
        XCTAssertTrue(DeepLinkRouter.canOpen(
            path: package.path,
            kind: DeepLinkRouter.probeFileSystem(package.path), roots: roots))
        for url in [script, folder] {
            XCTAssertFalse(DeepLinkRouter.canOpen(
                path: url.path,
                kind: DeepLinkRouter.probeFileSystem(url.path), roots: roots),
                           url.lastPathComponent)
        }
    }

    // MARK: - Le lien reçu avant l'ouverture de l'index

    func testALinkReceivedBeforeTheIndexOpensIsReplayedAfterwards() {
        var queue = DeepLinkQueue()
        let url = URL(string: "fouine://open?doc=1&page=2")!
        XCTAssertNil(queue.submit(url, isReady: false),
                     "rien à traiter tant que la base n'est pas ouverte")
        XCTAssertEqual(queue.resume(), url)
        XCTAssertNil(queue.resume(), "un lien en attente ne se rejoue qu'une fois")
    }

    func testTheLastLinkWins() {
        // Deux clics pendant les deux secondes d'ouverture sont une hésitation,
        // pas une file : ouvrir deux fenêtres d'aperçu serait une surprise.
        var queue = DeepLinkQueue()
        _ = queue.submit(URL(string: "fouine://open?doc=1&page=2")!, isReady: false)
        _ = queue.submit(URL(string: "fouine://open?doc=1&page=9")!, isReady: false)
        XCTAssertEqual(queue.resume()?.absoluteString, "fouine://open?doc=1&page=9")
    }

    func testAnIndexAlreadyOpenHandlesTheLinkAtOnce() {
        var queue = DeepLinkQueue()
        let url = URL(string: "fouine://search?q=alpha")!
        XCTAssertEqual(queue.submit(url, isReady: true), url)
        XCTAssertNil(queue.resume(), "rien ne reste en attente")
    }

    // MARK: - BU-18 : une page qui n'existe plus

    private func page(_ url: String, known: Int64, pages: Int?)
        -> DeepLinkAction {
        DeepLinkRouter.action(for: URL(string: url)!,
                              resolve: { _ in known },
                              probe: { _ in .regular },
                              roots: Self.roots,
                              pages: { _ in pages })
    }

    /// Le cas reproduit : une citation d'il y a un an, un document raccourci
    /// depuis. La fenêtre affichait « page 99 999 » et rien d'autre.
    func testAPageBeyondTheDocumentFallsBackToTheFirstAndSaysSo() {
        XCTAssertEqual(page("fouine://open?path=/a/b.pdf&page=99999",
                            known: 12, pages: 400),
                       .showPage(HitKey(docID: 12, page: 1), missingPage: 99999))
    }

    func testAPageInsideTheDocumentIsUntouched() {
        XCTAssertEqual(page("fouine://open?path=/a/b.pdf&page=25",
                            known: 12, pages: 400),
                       .showPage(HitKey(docID: 12, page: 25)))
        // La dernière page est DANS le document : elle ne se borne pas.
        XCTAssertEqual(page("fouine://open?path=/a/b.pdf&page=400",
                            known: 12, pages: 400),
                       .showPage(HitKey(docID: 12, page: 400)))
    }

    /// Nombre de pages inconnu (base ancienne, `n_pages` à zéro) : on ne borne
    /// rien plutôt que de refuser une page parfaitement valide.
    func testAnUnknownPageCountBoundsNothing() {
        XCTAssertEqual(page("fouine://open?path=/a/b.pdf&page=99999",
                            known: 12, pages: nil),
                       .showPage(HitKey(docID: 12, page: 99999)))
        XCTAssertEqual(page("fouine://open?path=/a/b.pdf&page=99999",
                            known: 12, pages: 0),
                       .showPage(HitKey(docID: 12, page: 99999)))
    }
}
