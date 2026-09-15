// NetworkSilenceTests.swift — LA PREUVE DYNAMIQUE DU SILENCE RÉSEAU.
// Propriété : A-Ingest, cible de test uniquement. Audit A1-01, A1-02, D2-01,
// D2-02, D2-03.
//
// ═══ POURQUOI CE FICHIER EXISTE ════════════════════════════════════════════
//
// Le produit promet qu'il n'ouvre aucune connexion qu'on ne lui ait demandée.
// Cette promesse était garantie par un `grep 'URLSession\|https://' Sources/`
// — une preuve STATIQUE, qui ne pouvait pas voir la faille qu'elle prétendait
// exclure (D2-03) : la requête était émise par CFNetwork depuis AppKit, à
// partir d'une URL venue DU DOCUMENT, jamais du code. Un `.doc` contenant du
// HTML faisait choisir à `NSAttributedString(url:options:[:])` l'importateur
// WebKit, qui téléchargeait `<img>` et `<link>` — en `http:` comme en `https:`
// (D2-02) — et attendait 62 s sur une adresse non routable (A1-02).
//
// Aucune inspection statique ne peut établir le silence réseau d'un produit qui
// confie des fichiers non fiables à des importateurs système. Il faut ÉCOUTER.
//
// ═══ CE QUE CES TESTS FONT ═════════════════════════════════════════════════
//
// Un écouteur TCP sur 127.0.0.1, port éphémère, qui JOURNALISE chaque
// acceptation — avant toute poignée de main, comme le serveur TLS de D2 : une
// connexion TLS refusée par un certificat auto-signé a déjà appris à
// l'attaquant l'adresse de la victime et l'instant de l'indexation. Des
// fixtures piégées visent ce port, en `http:` et en `https:`. On extrait, on
// laisse à la balise la fenêtre de `silenceWindow` pour se manifester, et on
// affirme ZÉRO acceptation.
//
// L'écouteur est vérifié par une contre-épreuve (`testTheListenerSeesRealTraffic`) :
// sans elle, un écouteur cassé rendrait tous les autres tests vert.
//
// RIEN NE SORT DE LA BOUCLE LOCALE : les fixtures ne citent que 127.0.0.1 et
// 10.255.255.1 (adresse noire du bloc privé). Aucun test de ce fichier ne
// contacte le réseau réel.

import Foundation
import XCTest
import FouineCore
@testable import FouineExtract

// MARK: - L'écouteur

/// Écouteur TCP sur 127.0.0.1, port éphémère. Il ACCEPTE puis ferme, et note
/// l'heure de chaque acceptation : c'est le seul fait qui compte — une balise a
/// fonctionné dès que la connexion a été établie, que la réponse arrive ou non.
final class LoopbackListener: @unchecked Sendable {
    private let socketFD: Int32
    private let mutex = NSLock()
    private var log: [String] = []
    private var closed = false

    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "LoopbackListener", code: Int(errno))
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                       // port éphémère
        // 127.0.0.1 SEULEMENT : cet écouteur ne doit être joignable de nulle
        // part ailleurs, y compris sur un runner partagé.
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "LoopbackListener", code: Int(errno))
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "LoopbackListener", code: Int(errno))
        }
        socketFD = fd
        port = UInt16(bigEndian: actual.sin_port)

        let sink: @Sendable (String) -> Void = { [weak self] line in
            self?.record(line)
        }
        Thread.detachNewThread {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { return }           // socket fermé : on sort
                sink("TCP-ACCEPT \(Date())")
                Darwin.close(client)
            }
        }
    }

    private func record(_ line: String) {
        mutex.lock(); log.append(line); mutex.unlock()
    }

    /// Le journal des acceptations. Vide = silence.
    var connections: [String] {
        mutex.lock(); defer { mutex.unlock() }; return log
    }

    func stop() {
        mutex.lock()
        let already = closed
        closed = true
        mutex.unlock()
        if !already { Darwin.close(socketFD) }
    }

    deinit { stop() }
}

// MARK: - Les tests

final class NetworkSilenceTests: XCTestCase {

    private var directory: URL!
    private var listener: LoopbackListener!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("silence")
        listener = try LoopbackListener()
    }

    override func tearDownWithError() throws {
        listener?.stop()
        listener = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func file(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Le HTML piégé : quatre sous-ressources vers l'écouteur, deux en `http:`
    /// et deux en `https:` (D2-02 : ATS n'est pas une atténuation, et la CLI
    /// n'a même pas d'ATS), plus une adresse NOIRE qui faisait attendre 62 s.
    private func trappedHTML() -> String {
        """
        <html><head><title>Compte rendu</title>
        <link rel="stylesheet" href="http://127.0.0.1:\(listener.port)/BALISE_CSS">
        <link rel="stylesheet" href="https://127.0.0.1:\(listener.port)/BALISE_CSS_TLS">
        </head><body>
        <p>Compte rendu de reunion du 2 septembre. Ce texte est assez long pour
        depasser le seuil de cent caracteres natifs, de sorte qu'une extraction
        reussie soit indiscernable d'une extraction normale.</p>
        <img src="http://127.0.0.1:\(listener.port)/BALISE_IMG">
        <img src="https://127.0.0.1:\(listener.port)/BALISE_IMG_TLS">
        <img src="http://10.255.255.1/BALISE_TROU_NOIR">
        </body></html>
        """
    }

    /// LA FENÊTRE DE SILENCE. Onze tests de ce fichier l'attendent l'un après
    /// l'autre : chaque dixième de seconde compte onze fois (lot BT1, qui l'a
    /// ramenée de 1 s à 0,3 s — 7,7 s de moins par passe de la suite).
    ///
    /// Ce n'est pas une constante choisie à vue : `testTheListenerSeesRealTraffic`
    /// MESURE ce que l'écouteur met à voir une connexion réelle et échoue si
    /// cette latence dépasse le sixième de cette fenêtre. Le jour où la
    /// machine devient assez lente pour que la marge fonde, c'est LUI qui
    /// rougit — pas onze silences qui passeraient à vide.
    static let silenceWindow: TimeInterval = 0.3

    /// Le dixième de seconde qu'on laisse au réseau pour se manifester.
    private func settle() {
        Thread.sleep(forTimeInterval: Self.silenceWindow)
    }

    private func assertSilence(_ what: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        let seen = listener.connections
        XCTAssertTrue(seen.isEmpty,
                      "\(what) : \(seen.count) connexion(s) acceptée(s) sur "
                      + "127.0.0.1:\(listener.port) — \(seen)",
                      file: file, line: line)
    }

    // MARK: - Contre-épreuve de l'instrument

    /// SANS CE TEST, TOUS LES AUTRES SONT VIDES. Un écouteur qui n'accepterait
    /// rien — port fermé, fil d'acceptation mort — rendrait « zéro connexion »
    /// quoi qu'il arrive. On établit donc une connexion pour de vrai, et on
    /// vérifie qu'elle est vue.
    func testTheListenerSeesRealTraffic() throws {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { Darwin.close(client) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = listener.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "connexion locale impossible : errno \(errno)")
        // Preuve POSITIVE : on attend l'acceptation, pas la fenêtre de silence
        // — celle-ci n'a de sens que pour affirmer un SILENCE.
        // Quelques millisecondes sur la boucle locale ; 2 s de garde.
        let started = Date()
        let deadline = started.addingTimeInterval(2)
        while listener.connections.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let latency = Date().timeIntervalSince(started)
        XCTAssertEqual(listener.connections.count, 1,
                       "l'écouteur ne voit pas une connexion pourtant établie : "
                       + "les autres tests de ce fichier ne prouveraient rien")
        // LA GARDE DE LA FENÊTRE DE SILENCE (lot BT1). Les onze tests de
        // silence affirment un négatif au bout de `silenceWindow` : cette
        // affirmation ne vaut que si l'écouteur voit une connexion en un temps
        // très inférieur. On le vérifie ici, sur la seule connexion réelle du
        // fichier, plutôt que de le supposer.
        XCTAssertLessThan(latency, Self.silenceWindow / 6,
                          "l'écouteur a mis \(Int(latency * 1000)) ms à voir une "
                          + "connexion réelle : la fenêtre de silence de "
                          + "\(Int(Self.silenceWindow * 1000)) ms n'a plus de marge, "
                          + "élargissez-la (elle est lue par les onze tests de "
                          + "silence de ce fichier)")
    }

    // MARK: - Le piège d'origine : du HTML dans un .doc

    /// A1-01 / D2-01 / D2-02, le test qui manquait. Deux affirmations, et il
    /// faut les deux : l'extraction est REFUSÉE (donc l'importateur WebKit n'a
    /// pas été choisi), et AUCUNE connexion n'a été acceptée.
    func testTrappedDocIsRefusedAndOpensNoConnection() throws {
        let url = file("balise.doc")
        try Data(trappedHTML().utf8).write(to: url)

        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu .extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("unrecognised format"), message)
        }
        settle()
        assertSilence("un .doc piégé")
    }

    /// Le même contenu sous `.rtf`. L'extension forçait déjà l'analyseur RTF
    /// (mesuré par A1) ; on l'affirme, pour que le jour où le tri changerait,
    /// il change ici aussi.
    func testTrappedRTFIsRefusedAndOpensNoConnection() throws {
        let url = file("balise.rtf")
        try Data(trappedHTML().utf8).write(to: url)

        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu .extraction, obtenu \($0)")
            }
            XCTAssertTrue(message.contains("unrecognised format"), message)
        }
        settle()
        assertSilence("un .rtf piégé")
    }

    /// `.html` et `.webarchive` sont dépouillés À LA MAIN (`HTMLText`), sans
    /// jamais passer par `NSAttributedString` : ils doivent RÉUSSIR — le
    /// contenu est du HTML, c'est leur métier — et rester muets. C'est la
    /// contre-épreuve du refus : ce n'est pas « tout ce qui contient une balise
    /// est refusé », c'est « rien ne part sur le réseau ».
    func testTrappedHTMLAndWebArchiveAreExtractedWithoutAnyRequest() throws {
        let html = file("balise.html")
        try Data(trappedHTML().utf8).write(to: html)
        let fromHTML = try DefaultExtractorRegistry().extract(url: html)
        XCTAssertGreaterThan(fromHTML.pages.count, 0)
        XCTAssertTrue(fromHTML.pages[0].text.contains("Compte rendu de reunion"),
                      fromHTML.pages[0].text)

        let archive = file("balise.webarchive")
        let plist: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(trappedHTML().utf8),
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
                "WebResourceURL": "file:///balise.html",
            ],
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: archive)
        let fromArchive = try DefaultExtractorRegistry().extract(url: archive)
        XCTAssertTrue(fromArchive.pages[0].text.contains("Compte rendu de reunion"),
                      fromArchive.pages[0].text)

        settle()
        assertSilence("un .html et un .webarchive piégés")
    }

    // MARK: - A1-02 : la passe rend la main

    /// La fixture VERSIONNÉE à adresse noire (`pieges/balise-reseau.doc`, trois
    /// sous-ressources dont `http://10.255.255.1/`) : 62,2 s mesurées avant le
    /// correctif, sur UN document. Le tri par octets de tête ne lit que huit
    /// octets, donc le refus est instantané ; on borne large à 10 s, comme
    /// l'audit le demande.
    func testTrappedDocReturnsPromptly() throws {
        let fixture = CorpusManifest.directory
            .appendingPathComponent("pieges/balise-reseau.doc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path),
                          "fixture versionnée absente : lancez `make fixtures`")

        let started = Date()
        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: fixture))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 10,
                          "le document piégé a bloqué \(elapsed) s (A1-02)")
    }

    // MARK: - D2-01 : ce que le durcissement ne doit PAS coûter

    /// Les deux documents MAL NOMMÉS du corpus versionné. Ce sont eux qui ont
    /// fait rejeter le correctif par extension : ils s'indexaient la veille, et
    /// un tri sur l'extension les aurait fait passer en `failed` sans que rien
    /// ne le dise à l'utilisateur.
    func testMislabeledDocxAndRtfAreStillExtracted() throws {
        let registry = DefaultExtractorRegistry()

        let ooxml = CorpusManifest.directory.appendingPathComponent("faux-nom.doc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ooxml.path),
                          "fixture versionnée absente : lancez `make fixtures`")
        let fromOOXML = try registry.extract(url: ooxml)
        let ooxmlText = fromOOXML.pages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(ooxmlText.contains("QUINQUENNAT"), ooxmlText)
        XCTAssertTrue(ooxmlText.contains("éàçûî"),
                      "les accents du conteneur mal nommé sont perdus")

        let rtf = CorpusManifest.directory
            .appendingPathComponent("rtf-nomme-doc.doc")
        let fromRTF = try registry.extract(url: rtf)
        XCTAssertTrue(fromRTF.pages.map(\.text).joined().lowercased()
                        .contains("coulometrie"),
                      fromRTF.pages.map(\.text).joined())

        settle()
        assertSilence("les deux documents mal nommés")
    }

    // MARK: - CM-01 : les fixtures que les trois documents PROMETTAIENT

    /// `SECURITY.md`, `docs/privacy.md` et `README.md` annonçaient des
    /// fixtures piégées `.rtfd`, `.epub`, `.pdf` — et ce fichier n'en avait
    /// aucune. C'est l'argument de vente n° 1 du produit, et il se démentait en
    /// trente secondes. Les voici, fabriquées à la volée comme `trappedHTML()`,
    /// avec le `.docx` et le `.svg` des voies ouvertes depuis.

    /// Un `.rtfd` est un PAQUET (un dossier) : son `TXT.rtf` porte un champ
    /// `INCLUDEPICTURE` vers l'écouteur. C'est AppKit qui le lit — la voie
    /// exacte par laquelle la faille d'origine passait.
    func testTrappedRTFDPackageOpensNoConnection() throws {
        let package = file("balise.rtfd")
        try FileManager.default.createDirectory(at: package,
                                                withIntermediateDirectories: true)
        let rtf = """
        {\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}
        \\f0\\fs24 Compte rendu de reunion du 2 septembre, assez long pour \
        depasser le seuil de cent caracteres natifs.\\par
        {\\field{\\*\\fldinst{INCLUDEPICTURE "http://127.0.0.1:\(listener.port)/BALISE_RTFD"}}}\\par
        {\\field{\\*\\fldinst{HYPERLINK "https://127.0.0.1:\(listener.port)/BALISE_RTFD_TLS"}}}
        }
        """
        try Data(rtf.utf8).write(to: package.appendingPathComponent("TXT.rtf"))

        // Le refus est acceptable, le silence ne l'est pas : c'est la seule
        // affirmation de ce test.
        _ = try? DefaultExtractorRegistry().extract(url: package)
        settle()
        assertSilence("un paquet .rtfd piégé")
    }

    /// Un `.epub` piégé : image et feuille de style distantes dans le XHTML, et
    /// une ENTITÉ EXTERNE dans le DOCTYPE (XXE). Le livre doit être lu — c'est
    /// son métier — et rester muet.
    func testTrappedEpubIsExtractedWithoutAnyRequest() throws {
        let url = file("balise.epub")
        let chapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html [<!ENTITY balise SYSTEM "http://127.0.0.1:\(listener.port)/BALISE_XXE">]>
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <link rel="stylesheet" href="http://127.0.0.1:\(listener.port)/BALISE_EPUB_CSS"/>
        </head><body>
        <p>Chapitre premier, assez long pour depasser le seuil de cent
        caracteres natifs et ressembler a un vrai livre numerique.</p>
        <img src="http://127.0.0.1:\(listener.port)/BALISE_EPUB_IMG"/>
        <img src="https://127.0.0.1:\(listener.port)/BALISE_EPUB_IMG_TLS"/>
        </body></html>
        """
        try Fixtures.makeArchive([
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Fixtures.xml("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf"
            media-type="application/oebps-package+xml"/></rootfiles></container>
            """)),
            ("OEBPS/content.opf", Fixtures.xml("""
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Livre piege</dc:title></metadata>
            <manifest><item id="c1" href="ch1.xhtml"
            media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="c1"/></spine></package>
            """)),
            ("OEBPS/ch1.xhtml", Data(chapter.utf8)),
        ], at: url)

        let result = try DefaultExtractorRegistry().extract(url: url)
        XCTAssertTrue(result.pages.map(\.text).joined().contains("Chapitre premier"),
                      "le livre piégé doit rester lisible")
        settle()
        assertSilence("un .epub piégé")
    }

    /// Un `.docx` dont une relation est `TargetMode="External"` vers
    /// l'écouteur — l'image liée (`<a:blip r:link=…>`) et l'hyperlien du
    /// traitement de texte.
    func testTrappedDocxIsExtractedWithoutAnyRequest() throws {
        let url = file("balise.docx")
        let document = Fixtures.xml("""
        <w:document xmlns:w="x"
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
        <w:body>
        <w:p><w:r><w:t>Compte rendu de reunion du 2 septembre, assez long pour
        depasser le seuil de cent caracteres natifs.</w:t></w:r></w:p>
        <w:p><w:hyperlink r:id="rId2"><w:r><w:t>lien</w:t></w:r></w:hyperlink></w:p>
        <w:p><w:r><w:drawing><a:blip r:link="rId1"/></w:drawing></w:r></w:p>
        </w:body></w:document>
        """)
        let rels = Fixtures.xml("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" TargetMode="External"
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
        Target="http://127.0.0.1:\(listener.port)/BALISE_DOCX_IMG"/>
        <Relationship Id="rId2" TargetMode="External"
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
        Target="https://127.0.0.1:\(listener.port)/BALISE_DOCX_LINK"/>
        </Relationships>
        """)
        try Fixtures.makeArchive([
            ("word/document.xml", document),
            ("word/_rels/document.xml.rels", rels),
        ], at: url)

        let result = try DefaultExtractorRegistry().extract(url: url)
        XCTAssertTrue(result.pages.map(\.text).joined().contains("Compte rendu"),
                      "le document piégé doit rester lisible")
        settle()
        assertSilence("un .docx à relation externe")
    }

    /// Un `.pdf` écrit à la main, avec les trois gestes qu'un lecteur de PDF
    /// sait faire tout seul : `/OpenAction` vers une URL, un `/GoToR` distant,
    /// et un `/Launch`. PDFKit ne doit ni les suivre ni les exécuter — Fouine ne
    /// lui demande que du texte.
    func testTrappedPDFOpensNoConnection() throws {
        let url = file("balise.pdf")
        try trappedPDF().write(to: url)

        _ = try? DefaultExtractorRegistry().extract(url: url)
        settle()
        assertSilence("un .pdf à /OpenAction, /GoToR et /Launch")
    }

    /// Un `.svg` — voie ouverte depuis, et jamais couverte : image distante et
    /// entité externe. `XMLDocumentExtractor` ne résout pas les entités
    /// (`shouldResolveExternalEntities = false`) ; ce test le PROUVE au lieu de
    /// le lire.
    func testTrappedSVGOpensNoConnection() throws {
        let url = file("balise.svg")
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE svg [<!ENTITY fuite SYSTEM "http://127.0.0.1:\(listener.port)/BALISE_SVG_XXE">]>
        <svg xmlns="http://www.w3.org/2000/svg"
             xmlns:xlink="http://www.w3.org/1999/xlink">
        <image xlink:href="http://127.0.0.1:\(listener.port)/BALISE_SVG_IMG"
               width="10" height="10"/>
        <text>Schema de la reaction, avec assez de texte pour que l'extraction
        rende quelque chose de lisible.</text>
        </svg>
        """
        try Data(svg.utf8).write(to: url)

        _ = try? DefaultExtractorRegistry().extract(url: url)
        settle()
        assertSilence("un .svg à image distante et entité externe")
    }

    // MARK: - CM-23 : la voie des médias (ffprobe, puis ffmpeg)

    /// Deux conteneurs qui n'en sont pas : une playlist HLS et un script
    /// `ffconcat`, tous deux nommés `.mkv` — donc confiés à ffprobe dès
    /// `extract.media`, et à ffmpeg sous `extract.transcribe`. L'audit a mesuré
    /// que ffmpeg 9 les refuse DE LUI-MÊME ; ce test garde la borne que Fouine,
    /// elle, pose désormais (`-protocol_whitelist file`).
    ///
    /// SE SAUTE sans ffmpeg installé, comme les autres tests médias.
    func testTrappedMediaContainersOpenNoConnection() throws {
        guard let ffmpeg = MediaDecoder.ffmpeg() else {
            throw XCTSkip("ffmpeg n'est pas installé sur cette machine")
        }
        let hls = file("piege-hls.mkv")
        try Data("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXTINF:10,
        http://127.0.0.1:\(listener.port)/BALISE_HLS.ts
        #EXT-X-ENDLIST
        """.utf8).write(to: hls)

        let concat = file("piege-concat.mkv")
        try Data("""
        ffconcat version 1.0
        file http://127.0.0.1:\(listener.port)/BALISE_CONCAT.mp3
        """.utf8).write(to: concat)

        let registry = DefaultExtractorRegistry(extractImages: false,
                                                extractMedia: true)
        for trap in [hls, concat] {
            _ = try? registry.extract(url: trap)
        }
        // ffmpeg DIRECTEMENT, sans passer par l'extracteur : c'est l'autre
        // invocation, et elle a sa propre ligne d'arguments.
        let wav = file("sortie.wav")
        for trap in [hls, concat] {
            try? MediaDecoder.convert(url: trap, ffmpeg: ffmpeg, to: wav,
                                      timeout: 20)
        }
        settle()
        assertSilence("deux conteneurs médias piégés (ffprobe puis ffmpeg)")
    }

    /// PDF minimal mais VALIDE (table xref calculée), porteur des trois pièges.
    private func trappedPDF() -> Data {
        let base = "http://127.0.0.1:\(listener.port)"
        let objects = [
            """
            1 0 obj << /Type /Catalog /Pages 2 0 R
            /OpenAction << /S /URI /URI (\(base)/BALISE_PDF_OPEN) >>
            /Names << /JavaScript 7 0 R >> >> endobj
            """,
            "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj",
            """
            3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200]
            /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >>
            /Annots [6 0 R] >> endobj
            """,
            """
            4 0 obj << /Length 74 >> stream
            BT /F1 12 Tf 20 100 Td (Compte rendu de reunion du 2 septembre) Tj ET
            endstream endobj
            """,
            "5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj",
            """
            6 0 obj << /Type /Annot /Subtype /Link /Rect [0 0 200 200]
            /A << /S /GoToR /F (\(base)/BALISE_PDF_GOTOR) /D [0 /Fit] >> >> endobj
            """,
            """
            7 0 obj << /S /Launch /F (\(base)/BALISE_PDF_LAUNCH) >> endobj
            """,
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for object in objects {
            offsets.append(pdf.utf8.count)
            pdf += object + "\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += """
        trailer << /Size \(objects.count + 1) /Root 1 0 R >>
        startxref
        \(xref)
        %%EOF
        """
        return Data(pdf.utf8)
    }

    /// Un VRAI Word 97 (OLE Compound File) reste indexé : c'est ce que le
    /// durcissement devait préserver, et la fixture `.doc` que le registre
    /// n'avait pas (B1-34).
    func testRealWord97DocIsExtracted() throws {
        let fixture = CorpusManifest.directory
            .appendingPathComponent("vrai-word97.doc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path),
                          "fixture versionnée absente : lancez `make fixtures`")

        let result = try DefaultExtractorRegistry().extract(url: fixture)
        let text = result.pages.map(\.text).joined(separator: "\n").lowercased()
        XCTAssertTrue(text.contains("spectrophotometrie"), text)
        settle()
        assertSilence("un vrai Word 97")
    }
}
