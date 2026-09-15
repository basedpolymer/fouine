// UnreadableDocumentsTests.swift — « Documents que Fouine n'a pas pu lire »
// (UX-16). Propriété : A-App.
//
// Les motifs éprouvés ici ne sont pas inventés : chacun est COPIÉ du code qui
// l'écrit dans `docs.err` (`FouineExtract`, `FouineCrawl`, `FouineIndex`), et
// le premier vient de l'index de production, où 22 documents le portent. Un
// motif qu'on récrirait à la main dans le test serait un test qui se prouve
// lui-même.

import XCTest
import FouineCore
@testable import FouineApp

final class UnreadableReasonTests: XCTestCase {

    // MARK: - Les motifs réellement écrits par les trois pipelines

    /// Le motif que porte l'index de production (22 documents `.pages`).
    func testRealProductionReasonIsRecognised() {
        let raw = "extraction: iWork document without a QuickLook preview — "
                + "open it once in Pages to generate one"
        XCTAssertEqual(UnreadableReason.classify(raw), .iWorkWithoutPreview)
    }

    func testSkipReasonsOfTheExtractorRegistry() {
        // ExtractorRegistry.skipReason(ext:) — le format sans extracteur.
        XCTAssertEqual(UnreadableReason.classify("unsupported format"),
                       .unsupportedFormat)
        // IndexText.describe(.unsupported(ext)) — la même chose, extension dite.
        XCTAssertEqual(UnreadableReason.classify("unsupported format: .ppt"),
                       .unsupportedFormat)
        // RichTextExtractor.reason — celui de l'unique .ppt de la production.
        XCTAssertEqual(UnreadableReason.classify("unsupported binary OLE format"),
                       .legacyOfficeFormat,
                       "il contient « unsupported » : l'ordre des tests le sauve")
        // ExtractorRegistry.skipReason(for: .fileTooLarge)
        XCTAssertEqual(UnreadableReason.classify("file too large (734003200 B)"),
                       .fileTooLarge)
        // ImageExtractor.belowFloorReason, qui porte désormais les dimensions
        // mesurées (constat C2-02).
        XCTAssertEqual(UnreadableReason.classify("image below the OCR size floor"),
                       .imageTooSmall)
        XCTAssertEqual(
            UnreadableReason.classify("image below the OCR size floor: 100x100 px"),
            .imageTooSmall)
        // ImageExtractor.belowWeightFloorReason — l'AVIF de 53 814 octets qui
        // portait une page A4 entière : « trop petite » était FAUX, il fallait
        // deux motifs.
        XCTAssertEqual(
            UnreadableReason.classify(
                "image file below the OCR weight floor: 2048 bytes"),
            .imageFileTooLight)
        // DjvuExtractor : un scan sans couche texte (C2-09). Le motif brut
        // s'affichait tel quel, en anglais, dans la fenêtre française.
        XCTAssertEqual(
            UnreadableReason.classify(
                "extraction: djvu: no text layer (commons-sarmatiae-1578.djvu)"),
            .scanWithoutTextLayer)
        // MediaExtractor : une transcription vide sur une piste qui dure (C2-05,
        // motif émis par le lot SI1).
        XCTAssertEqual(
            UnreadableReason.classify(
                "speech recognition returned nothing (dictaphone.m4a)"),
            .transcriptionEmpty)
        // MediaExtractor : une fenêtre dont la reconnaissance s'est tue (BT2),
        // recopié de `SpeechTranscriber.stoppedAnsweringReason`.
        XCTAssertEqual(
            UnreadableReason.classify("speech recognition stopped answering"),
            .transcriptionStopped)
        // Les refus nommés du lot INT-F1 (`ExtractOutcome.skippedReasons`),
        // recopiés de PlainTextExtractor, XMLDocumentExtractor,
        // MailboxExtractor et des deux extracteurs OLE.
        XCTAssertEqual(UnreadableReason.classify("minified source"), .nothingToIndex)
        XCTAssertEqual(UnreadableReason.classify("no text"), .nothingToIndex)
        XCTAssertEqual(UnreadableReason.classify("not a mailbox"), .notAMailbox)
        // La suite sans blanc (EX2), recopiée de `PlainTextExtractor.dataDumpReason` ;
        // l'InDesign sans texte, qui commence presque pareil, n'y tombe pas.
        XCTAssertEqual(UnreadableReason.classify(
            "no readable text: 48213-character run without a space — data dump?"),
            .dataDump)
        XCTAssertNotEqual(UnreadableReason.classify(
            "indd: no readable text — export as PDF or IDML"), .dataDump)
        XCTAssertEqual(UnreadableReasonText.describe(
            raw: "no readable text: 2000-character run without a space — data dump?"),
            UnreadableReasonText.phrase(.dataDump))
        XCTAssertEqual(UnreadableReason.classify("password-protected workbook"),
                       .passwordProtected)
        XCTAssertEqual(UnreadableReason.classify("password-protected presentation"),
                       .passwordProtected)
        XCTAssertEqual(UnreadableReason.classify("OLE container without a workbook stream"),
                       .damagedFile)
        XCTAssertEqual(UnreadableReason.classify(
            "OLE container without a PowerPoint Document stream"), .damagedFile)
    }

    /// `DjvuExtractor.reason` porte le JETON `missing-tool:` du cœur : c'est lui
    /// qu'on reconnaît, pas la phrase anglaise qui l'entoure. Le jeton vient de
    /// `ExternalTool` (FouineCore), donc de la SOURCE ; la phrase, elle, est
    /// recopiée de `DjvuExtractor.swift` — FouineExtract n'est pas dans les
    /// dépendances de cette cible de tests, et l'y ajouter pour une constante
    /// coûterait plus qu'il ne prouverait.
    func testMissingToolIsRecognisedByTheCoreToken() {
        XCTAssertEqual(
            UnreadableReason.classify(
                "djvu: djvulibre is missing (\(ExternalTool.missingToolToken("djvused")))"),
            .missingTool)
        XCTAssertEqual(
            UnreadableReason.classify("anything (\(ExternalTool.missingToolToken("pdftotext")))"),
            .missingTool,
            "la phrase peut changer, le jeton reste")
    }

    /// `FileResidency.skipReason` (FouineCrawl), posé par le parcours des
    /// dossiers sur un fichier iCloud resté dans le nuage.
    func testCrawlSkipsAFileStillInTheCloud() {
        XCTAssertEqual(
            UnreadableReason.classify(
                "not downloaded (iCloud/File Provider) — it will be indexed once present"),
            .notDownloaded)
    }

    func testPDFReasons() {
        XCTAssertEqual(
            UnreadableReason.classify(
                "password-protected PDF: document is locked (secret.pdf)"),
            .passwordProtected)
        XCTAssertEqual(
            UnreadableReason.classify(
                "extraction: unreadable PDF: PDFDocument(url:) returned nil (x.pdf)"),
            .damagedFile)
        XCTAssertEqual(
            UnreadableReason.classify(
                "document too long: 120000 pages, limit 65535 per document (x.pdf)"),
            .tooManyPages)
    }

    /// Les deux délais de garde : `Deadline` (PDFKit) et `Subprocess` (outil
    /// externe). Deux phrases, une seule famille — le geste est le même.
    func testDeadlines() {
        XCTAssertEqual(
            UnreadableReason.classify(
                "extraction: deadline exceeded (30 s): opening gros.pdf"),
            .tookTooLong)
        XCTAssertEqual(
            UnreadableReason.classify(
                "djvused did not return within 120 s (listing pages): process terminated"),
            .tookTooLong)
    }

    /// Les refus de macOS arrivent par `strerror` (anglais quelle que soit la
    /// langue du système) ou par la phrase de `RootProbe`.
    func testDeniedAndMissingFiles() {
        XCTAssertEqual(
            UnreadableReason.classify(
                "extraction: unreadable file: Permission denied (/Users/a/b.pdf)"),
            .readDenied)
        XCTAssertEqual(
            UnreadableReason.classify("unreadable root: /Volumes/X — read denied"),
            .readDenied)
        XCTAssertEqual(
            UnreadableReason.classify(
                "extraction: unreadable file: No such file or directory (/Users/a/b.pdf)"),
            .fileMissing)
    }

    /// `MediaExtractor` : « no metadata » et ses formes à parenthèse (TR1),
    /// recopiés de `MediaExtractor.swift` — FouineExtract n'est pas une
    /// dépendance de cette cible. Le texte EXACT dit « transcription éteinte »,
    /// la parenthèse dit pourquoi une transcription allumée n'a rien écrit.
    func testRecordingsSayWhyNothingWasWrittenDown() {
        XCTAssertEqual(UnreadableReason.classify("no metadata"), .recordingNotWrittenDown)
        XCTAssertEqual(UnreadableReason.classify("no metadata (longer than 120 min)"),
                       .recordingTooLong)
        XCTAssertEqual(UnreadableReason.classify("no metadata (longer than 1 min)"),
                       .recordingTooLong)
        XCTAssertEqual(UnreadableReason.classify("no metadata (no audio track)"),
                       .nothingToIndex)
        XCTAssertEqual(UnreadableReason.classify("no metadata (unknown duration)"),
                       .nothingToIndex)
        XCTAssertEqual(UnreadableReason.classify("no metadata (no speech)"),
                       .nothingToIndex)
        // Et la phrase ne ressort plus en anglais brut : chaque cas en a une.
        XCTAssertNotEqual(UnreadableReasonText.describe(raw: "no metadata"), "no metadata")
        XCTAssertNotEqual(
            UnreadableReasonText.describe(raw: "no metadata (longer than 120 min)"),
            "no metadata (longer than 120 min)")
    }

    /// `failOCR` après trois tentatives : le seul motif que le cœur écrive
    /// AILLEURS que dans une passe d'extraction.
    func testOCRGivingUp() {
        XCTAssertEqual(
            UnreadableReason.classify("OCR gave up after 3 attempts (page 14)"),
            .scannedPagesUnreadable)
    }

    // MARK: - Ce qui doit rester inconnu

    func testUnknownAndEmptyReasonsStayUnclassified() {
        XCTAssertNil(UnreadableReason.classify(nil))
        XCTAssertNil(UnreadableReason.classify(""))
        XCTAssertNil(UnreadableReason.classify("database: disk I/O error"))
        XCTAssertNil(UnreadableReason.classify("quelque chose d'inédit"))
    }

    /// Le motif brut ressort TEL QUEL quand il n'est pas reconnu : une phrase
    /// vraie et recopiable vaut mieux qu'un « erreur inconnue » creux.
    func testDescribeFallsBackToTheRawReason() {
        XCTAssertEqual(UnreadableReasonText.describe(raw: "database: disk I/O error"),
                       "database: disk I/O error")
        // Un échec sans motif du tout ne doit pas rendre une chaîne vide.
        XCTAssertFalse(UnreadableReasonText.describe(raw: nil).isEmpty)
        XCTAssertFalse(UnreadableReasonText.describe(raw: "").isEmpty)
    }

    /// Chaque famille a une phrase, et aucune ne laisse fuir du jargon interdit
    /// (public visé : PLAN.md § 2).
    func testEveryFamilyHasAPlainPhrase() {
        // « metadata », « balise », « piste » : les mots de métier des médias
        // (TR1) — un enregistrement a un titre, pas des métadonnées.
        let banned = ["OCR", "verrou", "vecteur", "racine", "pid", "launchd",
                      "agent", "rowid", "extraction", "TCC",
                      "metadata", "métadonnées", "balise", "piste", "track"]
        for reason in UnreadableReason.allCases {
            let text = UnreadableReasonText.phrase(reason)
            XCTAssertFalse(text.isEmpty, "\(reason) sans phrase")
            for word in banned {
                XCTAssertFalse(text.contains(word),
                               "« \(word) » dans la phrase de \(reason) : \(text)")
            }
        }
    }
}

@MainActor
final class UnreadableDocumentsModelTests: XCTestCase {

    /// Deux documents en échec semés, un document sain : le modèle ne rend que
    /// les deux premiers, dans l'ordre du store, avec leur motif traduit.
    func testModelLoadsSeededFailures() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Livres/bon.txt", pages: ["du texte"])
        let failed = try db.store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Livres/casse.pdf", ext: "pdf",
            topFolder: "Livres", size: 10, mtime: 1_700_000_000))
        try db.store.setDocState(failed, .failed,
                                 err: "password-protected PDF: document is locked (casse.pdf)")
        let skipped = try db.store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: "Archives/vieux.ppt", ext: "ppt",
            topFolder: "Archives", size: 10, mtime: 1_700_000_000))
        try db.store.setDocState(skipped, .skipped,
                                 err: "unsupported binary OLE format")

        let model = UnreadableDocumentsModel(service: db.service)
        XCTAssertNil(model.documents, "avant lecture : « pas encore lu », pas « vide »")
        await model.load()

        let rows = try XCTUnwrap(model.documents)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.isTruncated)
        // Trié par dossier : Archives avant Livres.
        XCTAssertEqual(rows[0].fileName, "vieux.ppt")
        XCTAssertEqual(rows[0].folder, "Archives")
        XCTAssertEqual(rows[0].ext, "ppt")
        XCTAssertEqual(rows[0].reason, .legacyOfficeFormat)
        XCTAssertEqual(rows[1].fileName, "casse.pdf")
        XCTAssertEqual(rows[1].reason, .passwordProtected)
        XCTAssertEqual(rows[1].relPath, "Livres/casse.pdf")
        // Le volume de test n'existe pas : la ligne reste utile, seul le
        // bouton « Afficher dans le Finder » disparaît.
        XCTAssertNil(rows[1].fileURL)
    }

    /// Un index sans échec : liste VIDE et non `nil` — la fenêtre peut alors
    /// dire « tout a été lu » en toute confiance.
    func testModelDistinguishesEmptyFromNotLoaded() async throws {
        let db = try TempAppDB()
        try db.addDoc(relPath: "Livres/bon.txt", pages: ["du texte"])
        let model = UnreadableDocumentsModel(service: db.service)
        await model.load()
        XCTAssertEqual(model.documents?.count, 0)
        XCTAssertNil(model.errorText)
    }
}
