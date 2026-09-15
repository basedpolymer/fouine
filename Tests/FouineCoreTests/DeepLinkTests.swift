// DeepLinkTests.swift — la grammaire du lien `fouine://` (lot INT-L1).
//
// Le test qui compte est l'ALLER-RETOUR sur un chemin hostile : une citation
// collée dans un mémoire six mois plus tôt doit rouvrir la bonne page, et un
// seul caractère mal échappé suffit à ouvrir une autre. Les cinq caractères
// éprouvés ici — espace, accent, `&`, `#`, `+`, `%` — viennent de chemins
// réels du corpus.

import XCTest
@testable import FouineCore

final class DeepLinkTests: XCTestCase {

    // MARK: - Aller-retour

    func testAHostilePathSurvivesTheRoundTrip() throws {
        let path = "/Volumes/Disque Éxterne/Cours & TD/100% #2 c+d/rapport %.pdf"
        let url = DeepLink.page(absolutePath: path, page: 87, query: "electrolyse")
        let read = try XCTUnwrap(DeepLink(url: url))
        XCTAssertEqual(read, .open(target: .path(path), page: 87,
                                   query: "electrolyse"))
        // Et l'URL doit être RELISIBLE par le système, pas seulement par nous :
        // c'est `URL(string:)` qui la reconstruira depuis le presse-papiers.
        let reparsed = try XCTUnwrap(URL(string: url.absoluteString))
        XCTAssertEqual(DeepLink(url: reparsed), read)
    }

    func testTheQueryTextSurvivesTheRoundTrip() throws {
        let url = DeepLink.page(absolutePath: "/a/b.pdf", page: 3,
                                query: "\"énergie libre\" & entropie")
        let read = try XCTUnwrap(DeepLink(url: url))
        XCTAssertEqual(read, .open(target: .path("/a/b.pdf"), page: 3,
                                   query: "\"énergie libre\" & entropie"))
    }

    func testAPageIsOptional() throws {
        let url = DeepLink.page(absolutePath: "/a/b.pdf", page: nil)
        XCTAssertFalse(url.absoluteString.contains("page="))
        XCTAssertEqual(DeepLink(url: url),
                       .open(target: .path("/a/b.pdf"), page: nil, query: nil))
    }

    func testTheDocumentFormSurvivesTheRoundTrip() throws {
        let url = DeepLink.page(docID: 1329, page: 87)
        XCTAssertEqual(url.absoluteString, "fouine://open?doc=1329&page=87")
        XCTAssertEqual(DeepLink(url: url),
                       .open(target: .doc(1329), page: 87, query: nil))
    }

    // MARK: - Le moment d'un enregistrement (lot PV1)

    /// Une page de son ou de vidéo se cite par son MOMENT : le lien le porte,
    /// et le relit.
    func testAMomentSurvivesTheRoundTrip() throws {
        let url = DeepLink.page(absolutePath: "/a/cours.m4a", page: 2, time: 760)
        XCTAssertTrue(url.absoluteString.hasSuffix("&t=760"), url.absoluteString)
        XCTAssertEqual(DeepLink(url: url),
                       .open(target: .path("/a/cours.m4a"), page: 2, query: nil,
                             time: 760))
    }

    /// Il n'est écrit QUE lorsqu'il existe : un PDF n'a pas de moment, et un
    /// paramètre vide dans une citation collée dans un mémoire se remarque.
    func testAMomentIsOptional() throws {
        let url = DeepLink.page(absolutePath: "/a/b.pdf", page: 3)
        XCTAssertFalse(url.absoluteString.contains("t="))
        XCTAssertEqual(DeepLink(url: url),
                       .open(target: .path("/a/b.pdf"), page: 3, query: nil,
                             time: nil))
        // Le début d'un enregistrement, lui, s'écrit : « t=0 » veut dire
        // quelque chose.
        XCTAssertTrue(DeepLink.page(absolutePath: "/a/c.mp3", page: 1, time: 0)
            .absoluteString.contains("t=0"))
    }

    /// UN MOMENT ILLISIBLE S'IGNORE, là où une page illisible refuse le lien :
    /// une page fausse ouvrirait une autre page que celle citée, un `t=`
    /// absurde ne coûte que la tête de lecture.
    func testAnUnreadableMomentIsIgnoredButKeepsTheLink() throws {
        for raw in ["abc", "-30", "12.5", ""] {
            let url = try XCTUnwrap(URL(string: "fouine://open?path=/a/b.mp3&page=1&t=\(raw)"))
            XCTAssertEqual(DeepLink(url: url),
                           .open(target: .path("/a/b.mp3"), page: 1, query: nil,
                                 time: nil),
                           "t=\(raw)")
        }
    }

    func testASearchLinkSurvivesTheRoundTrip() throws {
        let url = DeepLink.search(query: "polymère réticulé").url
        XCTAssertEqual(DeepLink(url: url), .search(query: "polymère réticulé"))
    }

    // MARK: - Refus

    func testAForeignSchemeIsRefused() {
        XCTAssertNil(DeepLink(url: URL(string: "https://open?path=/a&page=1")!))
        XCTAssertNil(DeepLink(url: URL(string: "file:///a/b.pdf")!))
    }

    func testAnUnknownHostIsRefused() {
        XCTAssertNil(DeepLink(url: URL(string: "fouine://index?path=/a")!))
    }

    func testPageZeroIsRefused() {
        // Les pages sont 1-indexées partout dans Fouine : `page=0` est un lien
        // trafiqué ou tronqué, pas « le document ».
        XCTAssertNil(DeepLink(url: URL(string: "fouine://open?path=/a/b.pdf&page=0")!))
        XCTAssertNil(DeepLink(url: URL(string: "fouine://open?path=/a/b.pdf&page=-3")!))
    }

    func testANonIntegerDocumentIsRefused() {
        XCTAssertNil(DeepLink(url: URL(string: "fouine://open?doc=abc&page=1")!))
        XCTAssertNil(DeepLink(url: URL(string: "fouine://open?doc=1.5")!))
    }

    func testARelativePathIsRefused() {
        XCTAssertNil(DeepLink(url: URL(string: "fouine://open?path=Users/moi/a.pdf")!))
    }

    func testAnOpenLinkWithoutATargetIsRefused() {
        XCTAssertNil(DeepLink(url: URL(string: "fouine://open?page=4")!))
    }

    func testASearchWithoutTextIsRefused() {
        XCTAssertNil(DeepLink(url: URL(string: "fouine://search")!))
        XCTAssertNil(DeepLink(url: URL(string: "fouine://search?q=%20%20")!))
    }

    // MARK: - Le choix de la forme

    func testTheAbsolutePathWinsWhenItIsKnown() {
        let url = DeepLink.link(absolutePath: "/Users/moi/cours.pdf",
                                docID: 12, page: 4)
        XCTAssertEqual(DeepLink(url: url),
                       .open(target: .path("/Users/moi/cours.pdf"), page: 4,
                             query: nil))
    }

    func testTheDocumentFormIsTheFallback() {
        // Volume démonté : il n'y a pas de chemin absolu à citer, et taire le
        // lien serait pire que d'en donner un qui vaut sur cette machine.
        let url = DeepLink.link(absolutePath: nil, docID: 12, page: 4)
        XCTAssertEqual(DeepLink(url: url),
                       .open(target: .doc(12), page: 4, query: nil))
    }

    func testARelativePathIsTreatedAsUnknown() {
        let url = DeepLink.link(absolutePath: "Users/moi/cours.pdf",
                                docID: 12, page: 4)
        XCTAssertEqual(DeepLink(url: url),
                       .open(target: .doc(12), page: 4, query: nil))
    }

    // MARK: - Chemin absolu -> document

    /// Le trajet inverse, sur un VRAI volume : c'est lui qui décide si un lien
    /// cité l'an dernier rouvre quelque chose. Le document est enregistré comme
    /// le fait le crawl — par `VolumeResolver`, en volume + chemin relatif —,
    /// puis retrouvé par son seul chemin absolu.
    func testADocumentIsFoundBackFromItsAbsolutePath() throws {
        let db = try makeDB()
        let file = db.directory.appendingPathComponent("cours & TD/100% #2.pdf")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("essai".utf8).write(to: file)

        let resolved = try VolumeResolver.resolve(path: file)
        let id = try db.store.upsertDoc(DocRecord(
            volUUID: resolved.volUUID, relPath: resolved.relPath, ext: "pdf",
            topFolder: "Essai", size: 5, mtime: 1_700_000_000))

        XCTAssertEqual(try db.store.docID(forAbsolutePath: file.path), id)
        // Et le lien construit sur ce chemin y ramène bien.
        let url = DeepLink.link(absolutePath: file.path, docID: id, page: 3)
        guard case .open(target: .path(let path), _, _, _) = DeepLink(url: url) else {
            return XCTFail("le lien devait porter le chemin")
        }
        XCTAssertEqual(try db.store.docID(forAbsolutePath: path), id)
    }

    func testAnUnknownAbsolutePathResolvesToNothing() throws {
        let db = try makeDB()
        XCTAssertNil(try db.store.docID(
            forAbsolutePath: db.directory.appendingPathComponent("absent.pdf").path))
    }
}
