// TranscriptionRevisionPassTests.swift — la passe relit les enregistrements
// quand la transcription s'allume ou change de révision (lot TR1).
// Propriété : A-Core.
//
// L'extracteur est SCRIPTÉ : ce qu'on éprouve ici est la PASSE — quels
// documents elle reprend, quand, et sous quelle forme les motifs arrivent dans
// `docs.err` —, pas la reconnaissance vocale, qui a son test réel dans
// `FouineExtractTests.MediaExtractorTests`.

import XCTest
import FouineCore
import FouineExtract
@testable import FouineIndex

/// Rend, pour chaque fichier, l'issue suivante de son script (la dernière se
/// répète), et compte les appels par nom de fichier.
final class ScriptedMediaRegistry: ExtractorRegistry, @unchecked Sendable {
    static let supportedExtensions: Set<String> = ["txt", "m4a"]

    enum Outcome {
        case pages([String])
        case refusal(String)
    }

    private let lock = NSLock()
    private let scripts: [String: [Outcome]]
    private var counts: [String: Int] = [:]

    init(_ scripts: [String: [Outcome]]) { self.scripts = scripts }

    func calls(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[name] ?? 0
    }

    fileprivate func next(for name: String) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        let rank = counts[name] ?? 0
        counts[name] = rank + 1
        let script = scripts[name] ?? [.pages(["texte de \(name)"])]
        return script[min(rank, script.count - 1)]
    }

    func extractor(for ext: String) -> (any TextExtractor)? {
        Self.supportedExtensions.contains(ext) ? ScriptedExtractor(registry: self) : nil
    }
}

private struct ScriptedExtractor: TextExtractor {
    static let supportedExtensions: Set<String> = []
    let registry: ScriptedMediaRegistry

    func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        switch registry.next(for: url.lastPathComponent) {
        case .refusal(let reason):
            throw FouineError.extraction(reason)
        case .pages(let texts):
            let pages = texts.enumerated().map {
                PageText(page: $0.offset + 1, text: $0.element, source: .native)
            }
            return ExtractionResult(pages: pages, pageCount: pages.count,
                                    ocrCandidates: [], meta: [:])
        }
    }
}

final class TranscriptionRevisionPassTests: XCTestCase {

    /// Le refus « dictée non installée » tel que `SpeechTranscriber` le compose :
    /// son préfixe PUBLIC, puis les langues et le geste.
    private let notInstalled = MediaExtractor.rereadSkipReasonPrefixes[0]
        + " for fr-FR — add the language under System Settings ▸ Keyboard ▸ Dictation"

    private func options() -> IndexPassOptions {
        IndexPassOptions(crawl: .delta, jobs: 2, optimize: false,
                         warmVocabulary: false, languageBackfillLimit: 0)
    }

    /// Une racine jetable : une fiche texte et les enregistrements nommés, la
    /// famille « médias » allumée, la transcription comme demandé.
    private func scratch(_ name: String, media: [String],
                         transcribe: Bool) throws -> IndexScratch {
        let scratch = try IndexScratch(name, documents: 1)
        for file in media {
            try Data("pas un vrai son".utf8)
                .write(to: scratch.root.appendingPathComponent(file))
        }
        try setTranscription(scratch, transcribe)
        return scratch
    }

    private func setTranscription(_ scratch: IndexScratch, _ on: Bool) throws {
        let settings = Settings(store: scratch.store, ttl: 0, environment: [:])
        _ = try settings.set(SettingKeys.extractMedia.key, "true")
        _ = try settings.set(SettingKeys.extractTranscribe.key, on ? "true" : "false")
        scratch.store.releaseWriteLock()
    }

    /// Une passe « d'avant TR1 » : par un mandataire qui ne porte pas la marque,
    /// donc sans rapprochement — états et motifs écrits par la vraie passe, et
    /// aucune `transcription_revision`.
    private func passWithoutMark(_ scratch: IndexScratch,
                                 _ registry: ScriptedMediaRegistry) throws {
        let before = FailingStore(scratch.store, fail: .upsertDoc, after: .max)
        _ = try IndexPass(store: before, registry: registry)
            .run(roots: [scratch.rootRecord], options: options())
    }

    private func texts(_ scratch: IndexScratch, _ name: String) throws -> [String] {
        let row = try XCTUnwrap(try scratch.documents()
            .first { $0.record.relPath.hasSuffix(name) })
        return try scratch.store.pageTexts(docID: row.id, limit: 100).map(\.text)
    }

    private func transcriptionNotes(_ observer: RecordingObserver) -> [String] {
        observer.notes.filter { $0.hasPrefix("transcription:") }
    }

    // MARK: - Marque absente, transcription allumée

    /// Une base d'avant TR1, transcription allumée : les enregistrements
    /// `extracted`, « no metadata » exact, les deux refus de la
    /// reconnaissance et les `failed` « returned nothing » sont relus PAR
    /// CETTE PASSE, leurs pages remplacées en entier ; ni la fiche texte, ni
    /// le son sans piste, ni un autre échec ne le sont.
    func testAMissingMarkWithTranscriptionOnReadsRecordingsAgain() throws {
        let scratch = try scratch("marque-absente",
                                  media: ["cours.m4a", "muet.m4a", "refus.m4a",
                                          "dicte.m4a", "piste.m4a",
                                          "echec.m4a", "autre.m4a"],
                                  transcribe: true)
        let registry = ScriptedMediaRegistry([
            "cours.m4a": [.pages(["alpha un", "alpha deux", "alpha trois"]),
                          .pages(["beta un", "beta deux"])],
            "muet.m4a": [.refusal(MediaExtractor.noMetadataReason), .pages(["gamma"])],
            "refus.m4a": [.refusal(MediaExtractor.rereadSkipReasons[1]), .pages(["delta"])],
            "dicte.m4a": [.refusal(notInstalled), .pages(["epsilon"])],
            "piste.m4a": [.refusal(MediaExtractor.noAudioTrackReason)],
            "echec.m4a": [.refusal(MediaExtractor.rereadFailedReasonSubstrings[0]), .pages(["zeta"])],
            "autre.m4a": [.refusal("bad audio file")],
        ])
        try passWithoutMark(scratch, registry)
        XCTAssertNil(try scratch.store.transcriptionRevision())

        // La forme STOCKÉE des motifs est exactement celle que l'extracteur lève.
        XCTAssertEqual(try scratch.state(ofDocumentAt: "cours.m4a").0, .extracted)
        let stored: [(String, String)] = [
            ("muet.m4a", MediaExtractor.noMetadataReason),
            ("refus.m4a", MediaExtractor.rereadSkipReasons[1]),
            ("dicte.m4a", notInstalled),
            ("piste.m4a", MediaExtractor.noAudioTrackReason),
        ]
        for (name, reason) in stored {
            let (state, err) = try scratch.state(ofDocumentAt: name)
            XCTAssertEqual(state, .skipped, name)
            XCTAssertEqual(err, reason, name)
        }
        let (eState, eErr) = try scratch.state(ofDocumentAt: "echec.m4a")
        XCTAssertEqual(eState, .failed)
        XCTAssertEqual(eErr, "extraction: \(MediaExtractor.rereadFailedReasonSubstrings[0])")

        let (aState, aErr) = try scratch.state(ofDocumentAt: "autre.m4a")
        XCTAssertEqual(aState, .failed)
        XCTAssertEqual(aErr, "extraction: bad audio file")

        let observer = RecordingObserver()
        let summary = try IndexPass(store: scratch.store, observer: observer,
                                    registry: registry)
            .run(roots: [scratch.rootRecord], options: options())

        XCTAssertEqual(try scratch.store.transcriptionRevision(),
                       MediaExtractor.transcriptRevision)
        XCTAssertEqual(transcriptionNotes(observer),
                       ["transcription: 5 media document(s) queued to be written down again"])
        XCTAssertEqual(summary.counters.extracted, 5)
        XCTAssertEqual(Set(observer.documents.map { ($0.relPath as NSString).lastPathComponent }),
                       ["cours.m4a", "muet.m4a", "refus.m4a", "dicte.m4a", "echec.m4a"])
        XCTAssertEqual(registry.calls("fiche-0.txt"), 1)
        XCTAssertEqual(registry.calls("piste.m4a"), 1)
        XCTAssertEqual(try scratch.state(ofDocumentAt: "piste.m4a").1,
                       MediaExtractor.noAudioTrackReason)
        XCTAssertEqual(try scratch.state(ofDocumentAt: "autre.m4a").0, .failed)
        XCTAssertEqual(try scratch.state(ofDocumentAt: "autre.m4a").1, "extraction: bad audio file")

        // TOUTES les pages sont remplacées : la troisième page d'avant disparaît.
        XCTAssertEqual(try texts(scratch, "cours.m4a"), ["beta un", "beta deux"])
        let cours = try XCTUnwrap(try scratch.documents()
            .first { $0.record.relPath.hasSuffix("cours.m4a") })
        XCTAssertEqual(cours.record.nPages, 2)
        for name in ["muet.m4a", "refus.m4a", "dicte.m4a", "echec.m4a"] {
            let (state, err) = try scratch.state(ofDocumentAt: name)
            XCTAssertEqual(state, .extracted, name)
            XCTAssertNil(err, name)
        }
        XCTAssertEqual(try texts(scratch, "echec.m4a"), ["zeta"])
    }

    // MARK: - Marque à jour

    /// La marque écrite, une seconde passe ne relit rien et ne dit rien.
    func testASecondPassReadsNothingAgain() throws {
        let scratch = try scratch("seconde-passe", media: ["cours.m4a"], transcribe: true)
        let registry = ScriptedMediaRegistry([:])
        _ = try IndexPass(store: scratch.store, registry: registry)
            .run(roots: [scratch.rootRecord], options: options())
        XCTAssertEqual(try scratch.store.transcriptionRevision(),
                       MediaExtractor.transcriptRevision)
        XCTAssertEqual(registry.calls("cours.m4a"), 1)

        let observer = RecordingObserver()
        let again = try IndexPass(store: scratch.store, observer: observer,
                                  registry: registry)
            .run(roots: [scratch.rootRecord], options: options())
        XCTAssertEqual(again.counters.total, 0)
        XCTAssertEqual(registry.calls("cours.m4a"), 1)
        XCTAssertEqual(transcriptionNotes(observer), [])
    }

    // MARK: - Transcription éteinte

    /// Transcription éteinte : la marque passe à `off`, rien n'est relu, et
    /// le texte déjà en base reste là.
    func testTranscriptionOffWritesOffAndReadsNothing() throws {
        let scratch = try scratch("eteinte", media: ["cours.m4a", "muet.m4a"],
                                  transcribe: false)
        let registry = ScriptedMediaRegistry([
            "muet.m4a": [.refusal(MediaExtractor.noMetadataReason)],
        ])
        try passWithoutMark(scratch, registry)
        XCTAssertNil(try scratch.store.transcriptionRevision())

        let observer = RecordingObserver()
        let summary = try IndexPass(store: scratch.store, observer: observer,
                                    registry: registry)
            .run(roots: [scratch.rootRecord], options: options())

        XCTAssertEqual(try scratch.store.transcriptionRevision(),
                       GRDBStore.transcriptionRevisionOff)
        XCTAssertEqual(summary.counters.total, 0)
        XCTAssertEqual(registry.calls("cours.m4a"), 1)
        XCTAssertEqual(registry.calls("muet.m4a"), 1)
        XCTAssertEqual(transcriptionNotes(observer), [])
        XCTAssertEqual(try scratch.state(ofDocumentAt: "muet.m4a").1,
                       MediaExtractor.noMetadataReason)
        XCTAssertEqual(try texts(scratch, "cours.m4a"), ["texte de cours.m4a"])
    }

    /// Éteinte, puis allumée : les enregistrements lus sans transcription sont
    /// relus à la passe qui suit.
    func testSwitchingTranscriptionOnReadsRecordingsAgain() throws {
        let scratch = try scratch("rallumee", media: ["cours.m4a", "muet.m4a"],
                                  transcribe: false)
        let registry = ScriptedMediaRegistry([
            "cours.m4a": [.pages(["titre seul"]), .pages(["titre seul", "ce qui est dit"])],
            "muet.m4a": [.refusal(MediaExtractor.noMetadataReason), .pages(["paroles"])],
        ])
        _ = try IndexPass(store: scratch.store, registry: registry)
            .run(roots: [scratch.rootRecord], options: options())
        XCTAssertEqual(try scratch.store.transcriptionRevision(),
                       GRDBStore.transcriptionRevisionOff)
        XCTAssertEqual(try scratch.state(ofDocumentAt: "muet.m4a").0, .skipped)

        try setTranscription(scratch, true)
        let observer = RecordingObserver()
        let summary = try IndexPass(store: scratch.store, observer: observer,
                                    registry: registry)
            .run(roots: [scratch.rootRecord], options: options())

        XCTAssertEqual(try scratch.store.transcriptionRevision(),
                       MediaExtractor.transcriptRevision)
        XCTAssertEqual(transcriptionNotes(observer),
                       ["transcription: 2 media document(s) queued to be written down again"])
        XCTAssertEqual(summary.counters.extracted, 2)
        XCTAssertEqual(registry.calls("fiche-0.txt"), 1)
        XCTAssertEqual(try texts(scratch, "cours.m4a"), ["titre seul", "ce qui est dit"])
        XCTAssertEqual(try texts(scratch, "muet.m4a"), ["paroles"])
    }
}
