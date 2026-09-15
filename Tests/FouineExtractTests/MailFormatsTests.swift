// MailFormatsTests.swift — emlx, olk15MsgSource, mbox fichier et paquet
// (lot INT-F1, SPEC §5.3). Propriété : A-Ingest.

import XCTest
import FouineCore
@testable import FouineExtract

final class MailFormatsTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("courriels")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func message(subject: String, body: String,
                        from: String = "Amelie <amelie@example.org>") -> String {
        """
        From: \(from)
        To: Bruno <bruno@example.org>
        Subject: \(subject)
        Date: Mon, 08 Sep 2026 09:00:00 +0200
        Content-Type: text/plain; charset=utf-8

        \(body)
        """
    }

    // MARK: - emlx (Apple Mail)

    /// Le compteur d'octets de tête est retiré, la liste de propriétés de fin
    /// aussi : seul le message est indexé.
    func testEMLXDropsItsByteCountAndItsFlagsPlist() throws {
        let message = Self.message(subject: "Convocation", body: "Actinométrie du jeudi.")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>flags</key><integer>8623620</integer></dict></plist>
        """
        let url = file("42.emlx")
        var data = Data("\(message.utf8.count)\n".utf8)
        data.append(Data(message.utf8))
        data.append(Data(plist.utf8))
        try data.write(to: url)

        let result = try DefaultExtractorRegistry().extract(url: url)
        let text = result.pages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Actinométrie"), text)
        XCTAssertTrue(text.contains("Subject: Convocation"), text)
        XCTAssertFalse(text.contains("8623620"), "la liste de drapeaux est indexée : \(text)")
    }

    /// Un `.emlx` sans compteur est un `.eml` : on ne perd pas le message pour
    /// une ligne d'en-tête absente.
    func testEMLXWithoutACounterIsReadAsAnEML() throws {
        let url = file("sans-compteur.emlx")
        try Data(Self.message(subject: "Sans compteur",
                              body: "Ellipsométrie.").utf8).write(to: url)
        let result = try DefaultExtractorRegistry().extract(url: url)
        XCTAssertTrue(result.pages.map(\.text).joined().contains("Ellipsométrie"))
    }

    /// `olk15MsgSource` porte des MAJUSCULES : le registre compare en
    /// minuscules, et c'est ce qui doit être vérifié.
    func testOutlookSourceIsReadThroughItsUppercaseExtension() throws {
        let url = file("courriel.olk15MsgSource")
        try Data(Self.message(subject: "Relevé",
                              body: "Ellipsométrie du mois.").utf8).write(to: url)
        XCTAssertNotNil(DefaultExtractorRegistry().extractor(for: "olk15MsgSource"))
        let result = try DefaultExtractorRegistry().extract(url: url)
        XCTAssertTrue(result.pages.map(\.text).joined().contains("Ellipsométrie"))
    }

    // MARK: - mbox

    /// Trois messages, trois pages — et une ligne « >From » dans un corps ne
    /// coupe RIEN : c'est l'échappement du format, pas une frontière.
    func testMailboxGivesOnePagePerMessage() throws {
        let url = file("archive.mbox")
        var text = ""
        text += "From amelie@example.org Mon Sep  8 09:00:00 2026\n"
        text += Self.message(subject: "Premier", body: "Colorimétrie.") + "\n\n"
        text += "From amelie@example.org Mon Sep  8 10:00:00 2026\n"
        text += Self.message(subject: "Deuxième",
                             body: ">From une citation\nConductimétrie.") + "\n\n"
        text += "From amelie@example.org Mon Sep  8 11:00:00 2026\n"
        text += Self.message(subject: "Troisième", body: "Gravimétrie.") + "\n"
        try Data(text.utf8).write(to: url)

        let result = try DefaultExtractorRegistry().extract(url: url)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.pages.count, 3)
        XCTAssertTrue(result.pages[0].text.contains("Colorimétrie"))
        XCTAssertTrue(result.pages[1].text.contains("Conductimétrie"))
        XCTAssertTrue(result.pages[1].text.contains(">From une citation"))
        XCTAssertTrue(result.pages[2].text.contains("Gravimétrie"))
        // Chaque page porte SON message, et pas celui du voisin.
        XCTAssertFalse(result.pages[0].text.contains("Gravimétrie"))
    }

    func testMailboxMetaCountsItsMessages() throws {
        let url = file("deux.mbox")
        let text = "From a@b Mon Sep  8 09:00:00 2026\n"
            + Self.message(subject: "Un", body: "Colorimétrie.") + "\n\n"
            + "From a@b Mon Sep  8 10:00:00 2026\n"
            + Self.message(subject: "Deux", body: "Gravimétrie.")
        try Data(text.utf8).write(to: url)
        let result = try MailboxExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.meta["messages"], "2")
    }

    /// Ce qui n'est ni une boîte ni un message est refusé NOMMÉMENT et classé
    /// `.skipped` : il n'y a rien à extraire, ce n'est pas un échec.
    func testANonMailboxIsSkippedByName() throws {
        let url = file("liste.mbox")
        try Data("courses\npain\nlait\n".utf8).write(to: url)
        XCTAssertThrowsError(try DefaultExtractorRegistry().extract(url: url)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("attendu extraction, obtenu \($0)")
            }
            XCTAssertEqual(message, MailboxExtractor.notAMailboxReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(message)),
                           MailboxExtractor.notAMailboxReason)
        }
    }

    /// Un export partiel — le message seul, sans ligne d'enveloppe — reste
    /// indexé, en une page.
    func testASingleMessageWithoutAnEnvelopeLineIsStillRead() throws {
        let url = file("seul.mbox")
        try Data(Self.message(subject: "Seul", body: "Colorimétrie.").utf8)
            .write(to: url)
        let result = try MailboxExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertTrue(result.pages[0].text.contains("Colorimétrie"))
    }

    // MARK: - Le paquet `Nom.mbox/` d'Apple Mail

    func testMailboxPackageReadsItsInnerMboxFile() throws {
        let package = file("Travail.mbox")
        try FileManager.default.createDirectory(at: package,
                                                withIntermediateDirectories: true)
        let text = "From a@b Mon Sep  8 09:00:00 2026\n"
            + Self.message(subject: "Un", body: "Colorimétrie.")
        try Data(text.utf8).write(to: package.appendingPathComponent("mbox"))

        let result = try DefaultExtractorRegistry().extract(url: package)
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertTrue(result.pages[0].text.contains("Colorimétrie"))
    }

    /// Sans fichier `mbox`, ce sont les `Messages/*.emlx` — et leur ORDRE est
    /// naturel : `5.emlx` avant `10.emlx`, jamais l'inverse.
    func testMailboxPackageReadsItsMessagesInNaturalOrder() throws {
        let package = file("Archive.mbox")
        let messages = package.appendingPathComponent("Messages")
        try FileManager.default.createDirectory(at: messages,
                                                withIntermediateDirectories: true)
        for (name, word) in [("5.emlx", "Colorimétrie"),
                             ("10.emlx", "Gravimétrie")] {
            let body = Self.message(subject: name, body: word + ".")
            var data = Data("\(body.utf8.count)\n".utf8)
            data.append(Data(body.utf8))
            try data.write(to: messages.appendingPathComponent(name))
        }

        let result = try DefaultExtractorRegistry().extract(url: package)
        XCTAssertEqual(result.pages.count, 2)
        XCTAssertTrue(result.pages[0].text.contains("Colorimétrie"),
                      result.pages[0].text)
        XCTAssertTrue(result.pages[1].text.contains("Gravimétrie"),
                      result.pages[1].text)
    }
}

// MARK: - Pièces jointes (lot EX1, constat C2-15)

/// Une facture reçue par courriel est souvent le seul exemplaire qu'on en ait :
/// elle doit devenir une page du courriel, après le corps.
final class EMLAttachmentTests: XCTestCase {

    var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory("eml-pieces")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static let boundary = "----=_EX1_9912"

    /// Un `multipart/mixed` : le corps, puis les parties données telles quelles.
    /// La frontière est un paramètre : un courriel JOINT doit avoir la sienne,
    /// sinon le découpage du courriel extérieur emporte ses parties (RFC 2046).
    static func mail(body: String, parts: [String],
                     boundary: String = EMLAttachmentTests.boundary) -> String {
        var text = """
        From: Gérard <contact@example.fr>
        To: Sonia <sonia@example.fr>
        Subject: Attestation
        Date: Wed, 21 Jan 2026 16:48:03 +0100
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="\(boundary)"

        --\(boundary)
        Content-Type: text/plain; charset="UTF-8"

        \(body)

        """
        for part in parts {
            text += "--\(boundary)\n" + part + "\n"
        }
        text += "--\(boundary)--\n"
        return text
    }

    /// Une partie de pièce jointe binaire, encodée en base64.
    static func attachedPart(type: String, name: String, data: Data) -> String {
        """
        Content-Type: \(type); name="\(name)"
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="\(name)"

        \(data.base64EncodedString(options: [.lineLength76Characters]))
        """
    }

    /// Une pièce jointe texte, sans encodage de transfert (7bit).
    static func attachedText(name: String, content: String) -> String {
        """
        Content-Type: text/plain; charset="UTF-8"; name="\(name)"
        Content-Disposition: attachment; filename="\(name)"

        \(content)
        """
    }

    func pdfBytes(_ lines: [String]) throws -> Data {
        let url = file("source-\(UUID().uuidString).pdf")
        try Fixtures.makePDF(pages: [lines], at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    /// Dossiers `fouine-eml-<pid>-*` de CE processus présents dans le dossier
    /// temporaire : ils doivent être aussi nombreux avant et après une
    /// extraction. Ceux des autres processus (`make ci-unit --parallel`) vont
    /// et viennent en même temps : ils ne comptent pas.
    func scratchCount() -> Int {
        let temporary = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: temporary.path)) ?? []
        let mine = "fouine-eml-\(ProcessInfo.processInfo.processIdentifier)-"
        return names.filter { $0.hasPrefix(mine) }.count
    }

    // MARK: - Le service qui manquait

    /// Le constat C2-15 : le PDF joint devient une page APRÈS le corps, et sa
    /// première ligne porte le nom du fichier — donc `search "attestation.pdf"`
    /// la trouve.
    func testAPDFAttachmentBecomesAPageAfterTheBody() throws {
        let pdf = try pdfBytes(["Attestation Malinot 2026",
                                "Police DEC-2021-778213"])
        let url = file("facture.eml")
        try Data(Self.mail(body: "Vous trouverez ci-joint l'attestation.",
                           parts: [Self.attachedPart(
                            type: "application/pdf",
                            name: "attestation-decennale-malinot.pdf",
                            data: pdf)]).utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 2, "corps + pièce")
        XCTAssertEqual(result.pages.count, 2)
        XCTAssertTrue(result.pages[0].text.contains("ci-joint"), result.pages[0].text)
        XCTAssertFalse(result.pages[0].text.contains("Attestation Malinot 2026"),
                       "la pièce n'est pas repliée dans le corps")
        let piece = result.pages[1]
        XCTAssertEqual(piece.page, 2)
        XCTAssertTrue(piece.text.hasPrefix("attestation-decennale-malinot.pdf\n"),
                      piece.text)
        XCTAssertTrue(piece.text.contains("Attestation Malinot 2026"), piece.text)
        XCTAssertEqual(result.meta["attachments"], "1")
        XCTAssertNil(result.meta["attachments_skipped"])
        // Aucune page de pièce en file OCR : le rendu de page ne sait pas
        // produire l'image d'une page de courriel.
        XCTAssertTrue(result.ocrCandidates.isEmpty)
    }

    /// Deux pièces : l'ordre des pages est celui des PARTIES du courriel.
    func testTwoAttachmentsKeepThePartOrder() throws {
        let pdf = try pdfBytes(["Attestation Malinot 2026"])
        let url = file("deux-pieces.eml")
        try Data(Self.mail(body: "Deux pièces.", parts: [
            Self.attachedPart(type: "application/pdf", name: "attestation.pdf",
                              data: pdf),
            Self.attachedText(name: "releve.txt",
                              content: "Relevé de conductimétrie du mois."),
        ]).utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertTrue(result.pages[1].text.hasPrefix("attestation.pdf\n"),
                      result.pages[1].text)
        XCTAssertTrue(result.pages[1].text.contains("Attestation Malinot 2026"))
        XCTAssertTrue(result.pages[2].text.hasPrefix("releve.txt\n"),
                      result.pages[2].text)
        XCTAssertTrue(result.pages[2].text.contains("conductimétrie"))
        XCTAssertEqual(result.meta["attachments"], "2")
    }

    /// Une archive jointe n'est PAS ouverte (décision SI1) : le corps reste
    /// indexé, la pièce est nommée dans la note.
    func testAZipAttachmentIsIgnoredAndTheBodyStays() throws {
        let url = file("archive-jointe.eml")
        try Data(Self.mail(body: "Colorimétrie du jeudi.", parts: [
            Self.attachedPart(type: "application/zip", name: "dossier.zip",
                              data: Data("PK\u{03}\u{04}bidon".utf8)),
        ]).utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1, "le corps seul")
        XCTAssertTrue(result.pages[0].text.contains("Colorimétrie"))
        XCTAssertNil(result.meta["attachments"])
        XCTAssertEqual(result.meta["attachments_skipped"], "dossier.zip (archive)")
    }

    /// Une image jointe n'entre pas dans ce lot : elle ne vaudrait que par
    /// l'OCR, et le rendu de page ne sait pas la produire depuis un courriel.
    func testAnImageAttachmentIsNamedInTheNoteAndNotRead() throws {
        let url = file("photo-jointe.eml")
        try Data(Self.mail(body: "Gravimétrie.", parts: [
            Self.attachedPart(type: "image/jpeg", name: "enseigne.jpg",
                              data: Data([0xFF, 0xD8, 0xFF, 0xE0])),
        ]).utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.meta["attachments_skipped"], "enseigne.jpg (no reader)")
    }

    // MARK: - Entrées hostiles

    /// Un nom de pièce qui remonte l'arborescence est ramené à son dernier
    /// composant : RIEN n'est écrit hors du dossier temporaire de la pièce.
    func testATraversingFilenameCannotEscapeTheScratchDirectory() throws {
        let target = directory.appendingPathComponent("evade.txt")
        let url = file("evasion.eml")
        try Data(Self.mail(body: "Ellipsométrie.", parts: [
            Self.attachedText(name: "../../../..\(target.path)",
                              content: "Contenu de la pièce."),
        ]).utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertTrue(result.pages[1].text.hasPrefix("evade.txt\n"),
                      result.pages[1].text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "la pièce a été écrite hors de son dossier")
    }

    /// Les noms hostiles, sans passer par un courriel : la règle est pure.
    func testSanitizedNamesAreNeverPaths() {
        XCTAssertEqual(MailAttachments.sanitized(name: "../../etc/passwd"), "passwd")
        XCTAssertEqual(MailAttachments.sanitized(name: "..\\..\\Windows\\a.txt"),
                       "a.txt")
        XCTAssertEqual(MailAttachments.sanitized(name: ".."),
                       MailAttachments.fallbackName)
        XCTAssertEqual(MailAttachments.sanitized(name: ""),
                       MailAttachments.fallbackName)
        XCTAssertEqual(MailAttachments.sanitized(name: "a\u{0}b\nc.pdf"), "a_b_c.pdf")
        XCTAssertEqual(MailAttachments.sanitized(name: "-o.txt"), "_o.txt")
        XCTAssertEqual(MailAttachments.sanitized(name: "note:2026.txt"),
                       "note_2026.txt")
        // 400 caractères : ramené à 120 octets, extension conservée.
        let long = String(repeating: "é", count: 400) + ".pdf"
        let cut = MailAttachments.sanitized(name: long)
        XCTAssertLessThanOrEqual(cut.utf8.count, MailAttachments.maxNameBytes)
        XCTAssertTrue(cut.hasSuffix(".pdf"), cut)
    }

    /// Douze pièces : dix sont lues, les deux autres comptées dans la note.
    func testTwelveAttachmentsAreCappedAtTen() throws {
        let parts = (1...12).map {
            Self.attachedText(name: "piece-\($0).txt",
                              content: "Enthalpie numéro \($0).")
        }
        let url = file("douze.eml")
        try Data(Self.mail(body: "Douze pièces.", parts: parts).utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.meta["attachments"], "10")
        XCTAssertEqual(result.pageCount, 11, "le corps + dix pièces")
        XCTAssertEqual(result.meta["attachments_skipped"],
                       "2 more attachment(s) ignored (limit 10)")
        XCTAssertTrue(result.pages.last!.text.contains("numéro 10"),
                      result.pages.last!.text)
    }

    /// Un courriel joint devient ses propres pages — mais SA pièce jointe n'est
    /// pas suivie : une profondeur, pas deux.
    func testAnAttachedMessageIsReadOneLevelDeep() throws {
        let inner = Self.mail(body: "Corps du courriel joint : polarimétrie.",
                              parts: [Self.attachedPart(
                                type: "application/pdf", name: "profondeur-deux.pdf",
                                data: try pdfBytes(["Attestation Malinot 2026"]))],
                              boundary: "----=_EX1_INTERIEUR")
        let url = file("imbrique.eml")
        try Data(Self.mail(body: "Je te transfère ce message.", parts: ["""
        Content-Type: message/rfc822
        Content-Disposition: attachment; filename="transfert.eml"

        \(inner)
        """]).utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.meta["attachments"], "1")
        let text = result.pages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("polarimétrie"), text)
        XCTAssertTrue(text.contains("transfert.eml"), text)
        XCTAssertFalse(text.contains("Attestation Malinot 2026"),
                       "la pièce de la pièce a été suivie : \(text)")
    }

    /// Une pièce illisible n'emporte pas le courriel, et le dossier temporaire
    /// disparaît quand même.
    func testAFailingAttachmentLeavesTheBodyIndexedAndNoScratch() throws {
        let before = scratchCount()
        let url = file("pdf-casse.eml")
        try Data(Self.mail(body: "Actinométrie du jeudi.", parts: [
            Self.attachedPart(type: "application/pdf", name: "casse.pdf",
                              data: Data("ceci n'est pas un PDF".utf8)),
        ]).utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertTrue(result.pages[0].text.contains("Actinométrie"))
        XCTAssertNil(result.meta["attachments"])
        XCTAssertTrue(result.meta["attachments_skipped"]?.hasPrefix("casse.pdf (")
                      ?? false, result.meta["attachments_skipped"] ?? "aucune note")
        XCTAssertEqual(scratchCount(), before, "dossier temporaire laissé derrière")
    }

    /// Succès : le dossier temporaire n'existe plus au retour.
    func testTheScratchDirectoryIsGoneAfterASuccessfulExtraction() throws {
        let before = scratchCount()
        let url = file("propre.eml")
        try Data(Self.mail(body: "Corps.", parts: [
            Self.attachedText(name: "note.txt", content: "Spectrométrie."),
        ]).utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.meta["attachments"], "1")
        XCTAssertEqual(scratchCount(), before)
    }

    /// Base64 tronqué, pièce vide, pièce sans nom : un refus ou un résultat
    /// vide, jamais un trap ni le corps perdu.
    func testTruncatedAndAnonymousAttachmentsNeverBreakTheMail() throws {
        let url = file("hostile.eml")
        try Data(Self.mail(body: "Le corps survit.", parts: [
            """
            Content-Type: application/pdf; name="tronque.pdf"
            Content-Transfer-Encoding: base64
            Content-Disposition: attachment; filename="tronque.pdf"

            JVBERi0xLjQKMSAwIG9iag
            """,
            """
            Content-Type: application/pdf
            Content-Disposition: attachment

            (sans nom)
            """,
            """
            Content-Type: application/pdf; name="vide.pdf"
            Content-Disposition: attachment; filename="vide.pdf"

            """,
        ]).utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertTrue(result.pages[0].text.contains("Le corps survit."))
        XCTAssertNil(result.meta["attachments"])
        XCTAssertNotNil(result.meta["attachments_skipped"])
    }

    /// NON-RÉGRESSION : un courriel sans pièce rend exactement ce qu'il rendait
    /// — mêmes pages, et aucune note d'extraction.
    func testAMailWithoutAnyAttachmentIsUnchanged() throws {
        let url = file("sans-piece.eml")
        try Data("""
        From: Amelie <amelie@example.org>
        To: Bruno <bruno@example.org>
        Subject: Convocation
        Date: Mon, 08 Sep 2026 09:00:00 +0200
        Content-Type: multipart/alternative; boundary="ALT"

        --ALT
        Content-Type: text/plain; charset=utf-8

        Actinométrie du jeudi.
        --ALT
        Content-Type: text/html; charset=utf-8

        <p>Actinométrie du jeudi.</p>
        --ALT--
        """.utf8).write(to: url)

        let result = try EMLExtractor().extract(url: url, limits: ExtractLimits())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertTrue(result.pages[0].text.contains("Subject: Convocation"))
        XCTAssertTrue(result.pages[0].text.contains("Actinométrie du jeudi."))
        XCTAssertNil(result.meta["attachments"])
        XCTAssertNil(result.meta["attachments_skipped"])
    }

    /// Une boîte aux lettres ne lit pas les pièces de ses messages (lot EX1) :
    /// une page par message, comme avant — un export Takeout de mille courriels
    /// n'a pas à devenir dix mille pages extraites une à une.
    func testAMailboxIgnoresTheAttachmentsOfItsMessages() throws {
        let url = file("boite.mbox")
        let message = Self.mail(body: "Colorimétrie.", parts: [
            Self.attachedPart(type: "application/pdf", name: "piece.pdf",
                              data: try pdfBytes(["Attestation Malinot 2026"])),
        ])
        try Data(("From a@b Mon Sep  8 09:00:00 2026\n" + message).utf8).write(to: url)

        let result = try MailboxExtractor().extract(url: url, limits: ExtractLimits())
        let text = result.pages.map(\.text).joined()
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertTrue(text.contains("Colorimétrie"), text)
        XCTAssertFalse(text.contains("Attestation Malinot 2026"), text)
        XCTAssertNil(result.meta["attachments"])
    }
}
