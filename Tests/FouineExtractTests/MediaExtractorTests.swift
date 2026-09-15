// MediaExtractorTests.swift — sons et vidéos (SPEC §5.3, lot INT-F3).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// Les fixtures vivent dans `Tests/Fixtures/media/`, HORS du corpus de recette
// et hors de son manifeste : la famille n'est inscrite que sous `extract.media`,
// que `Recette.makeIndexedCorpus` n'allume pas, et une fixture média rangée
// dans `corpus/` fausserait les comptes du manifeste (même décision que les
// images, INT-F2). Elles se refabriquent par `make fixtures-media`.

import XCTest
import AVFoundation
import CoreMedia
import FouineCore
@testable import FouineExtract

final class MediaExtractorTests: XCTestCase {

    /// Le dossier des fixtures médias, déduit de l'emplacement de CE fichier.
    private static var mediaDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // FouineExtractTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/media")
    }

    private func fixture(_ name: String) throws -> URL {
        let url = Self.mediaDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture média absente : \(name) "
                          + "(swift Tools/make_fixtures.swift media)")
        }
        return url
    }

    // MARK: - Étage 1 : les métadonnées

    func testTaggedAudioYieldsOneNativePage() throws {
        let url = try fixture("voix.m4a")
        let result = try MediaExtractor().extract(url: url, limits: ExtractLimits())

        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.pages.count, 1)
        let page = try XCTUnwrap(result.pages.first)
        XCTAssertEqual(page.page, 1)
        // La page de métadonnées est du texte NATIF : le fichier le portait.
        XCTAssertEqual(page.source, .native)
        XCTAssertTrue(page.text.contains("Title: Cristallisation"), page.text)
        XCTAssertTrue(page.text.contains("Artist: Fouine Fixtures"), page.text)
        XCTAssertTrue(page.text.contains("Duration: 00:0"), page.text)
        // Aucune page d'un média ne part en OCR : il n'y a pas d'image de page.
        XCTAssertTrue(result.ocrCandidates.isEmpty)
    }

    func testTaggedVideoYieldsTheSameFields() throws {
        let url = try fixture("clip.mp4")
        let result = try MediaExtractor().extract(url: url, limits: ExtractLimits())
        let page = try XCTUnwrap(result.pages.first)
        XCTAssertTrue(page.text.contains("Title: Cristallisation"), page.text)
        // QuickTime range l'interprète sous « contributor » : la ligne doit
        // sortir sous le même libellé que pour un fichier son.
        XCTAssertTrue(page.text.contains("Artist: Fouine Fixtures"), page.text)
    }

    /// Un média sans la moindre balise et sans transcription n'a rien à
    /// indexer : Fouine n'indexe pas les noms de fichiers (SPEC §5.3 (e)), et
    /// ce refus NOMMÉ — rangé en `.skipped`, pas en `.failed` — est sa seule
    /// trace dans la carte « documents illisibles ».
    func testUntaggedAudioIsSkippedWithANamedReason() throws {
        let url = try fixture("voix.aiff")
        XCTAssertThrowsError(try MediaExtractor().extract(url: url,
                                                          limits: ExtractLimits())) {
            guard let error = $0 as? FouineError,
                  case FouineError.extraction(let message) = error else {
                return XCTFail("erreur inattendue : \($0)")
            }
            XCTAssertEqual(message, MediaExtractor.noMetadataReason)
            XCTAssertEqual(ExtractOutcome.skipReason(for: error),
                           MediaExtractor.noMetadataReason)
        }
    }

    // MARK: - Conteneurs étrangers : ffmpeg

    /// Sans ffmpeg, un `.mkv` est refusé par un motif qui NOMME l'outil et
    /// porte le jeton que le crawl sait relire — sans quoi le document
    /// resterait sauté à vie après l'installation de ffmpeg (constat A3-05).
    func testForeignContainerWithoutFFmpegIsNamed() throws {
        let directory = try Fixtures.temporaryDirectory("media-mkv")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cours.mkv")
        // Un conteneur qu'AVFoundation n'ouvrira pas : le contenu n'a pas
        // d'importance, seule compte la branche de repli.
        try Data("pas un vrai matroska".utf8).write(to: url)

        // Aucun répertoire d'outils : ffmpeg est introuvable, quoi qu'il y ait
        // sur cette machine.
        let extractor = MediaExtractor(options: MediaOptions(), toolDirectories: [])
        XCTAssertThrowsError(try extractor.extract(url: url,
                                                   limits: ExtractLimits())) {
            guard let error = $0 as? FouineError,
                  case FouineError.unsupported(let ext) = error else {
                return XCTFail("erreur inattendue : \($0)")
            }
            XCTAssertEqual(ext, "mkv")
            let reason = ExtractOutcome.skipReason(for: error)
            XCTAssertEqual(reason, MediaExtractor.ffmpegMissingReason("mkv"))
            XCTAssertEqual(ExternalTool.missingTool(inSkipReason: reason), "ffmpeg")
        }
    }

    // MARK: - Registre et extensions

    func testMediaExtensionsStayOutOfTheStandardUnion() {
        // Les médias N'ENTRENT PAS dans l'union du §5.3 : sans le réglage, le
        // crawler ne doit pas les ramasser.
        for ext in ["mp3", "m4a", "mp4", "mkv", "flac"] {
            XCTAssertFalse(DefaultExtractorRegistry.supportedExtensions.contains(ext),
                           ext)
            XCTAssertTrue(DefaultExtractorRegistry.mediaExtensions.contains(ext), ext)
        }
        XCTAssertNil(DefaultExtractorRegistry(extractImages: false, extractMedia: false)
                        .extractor(for: "mp3"))
        XCTAssertNotNil(DefaultExtractorRegistry(extractImages: false, extractMedia: true)
                            .extractor(for: "mp3"))
    }

    // MARK: - Étage 2 : la transcription

    /// Bout en bout, sur `voix.aiff`. Le test SE SAUTE — et dit lequel des deux
    /// cas — quand la reconnaissance sur l'appareil n'est pas installée pour les
    /// langues demandées, ou quand l'autorisation « Reconnaissance vocale »
    /// manque : ce sont des conditions de la MACHINE, pas des régressions.
    func testTranscriptionOfSpokenAudio() throws {
        let url = try fixture("voix.aiff")
        let languages = ["fr-FR", "en-US"]
        // Une échéance COURTE, et SOUS le chien de garde (90 s) : c'est
        // l'échéance de la source qui doit tomber la première.
        setenv("FOUINE_SPEECH_TIMEOUT", "60", 1)
        defer { unsetenv("FOUINE_SPEECH_TIMEOUT") }

        guard let transcript = try speaking(budget: 90, { probe -> [PageText] in
            try Self.requireSpeechRecognition(languages: languages, probe: probe)
            probe.enter("reconnaissance de voix.aiff")
            let extractor = MediaExtractor(options: MediaOptions(transcribe: true,
                                                                 languages: languages))
            return try extractor.extract(url: url, limits: ExtractLimits())
                .pages.filter { $0.source == .transcript }
        }) else { return }
        guard !transcript.isEmpty else {
            throw XCTSkip("la reconnaissance sur l'appareil n'a rien rendu sur "
                          + "cette machine (installée et autorisée, mais muette)")
        }

        let text = transcript.map(\.text).joined(separator: " ").lowercased()
        let witnesses = ["polymère", "cristallise", "lentement", "le"]
        let found = witnesses.filter { text.contains($0) }
        XCTAssertGreaterThanOrEqual(found.count, 2,
                                    "mots témoins retrouvés : \(found) — texte : \(text)")
        // Chaque paragraphe est précédé de son horodatage.
        XCTAssertTrue(text.contains("[00:00]"), text)
    }

    // MARK: - TR1 : une parole de plus d'une minute, mise par écrit EN ENTIER

    /// Le texte lu par `say` : un peu moins de deux minutes à 175 mots par
    /// minute. Deux mots TÉMOINS, et chacun n'apparaît qu'une fois : « jardin »
    /// dans la première phrase, « voiture » dans la dernière.
    ///
    /// POURQUOI PLUS D'UNE MINUTE. Sur macOS 15, la reconnaissance sur
    /// l'appareil rend la parole en morceaux d'environ 60 s, et seul le dernier
    /// porte `isFinal` (mesuré le 12/09/2026). `voix.aiff` dure quelques
    /// secondes : un seul morceau, et la perte de tous les autres ne se voyait
    /// pas.
    static let longSpeechText = """
        Ce matin, le jardin était couvert de rosée, et le soleil se levait \
        lentement derrière les collines. Nous avons pris notre petit déjeuner \
        sur la terrasse, avec du pain frais, du beurre et de la confiture \
        d'abricot. Ensuite, nous sommes allés au marché du village, qui se tient \
        chaque samedi sur la grande place. Les marchands vendaient des légumes \
        de saison, des fromages de la région, du miel et des fleurs coupées. Une \
        vieille dame nous a expliqué comment préparer une soupe de potiron, avec \
        un peu de crème et beaucoup de patience. Plus tard, nous avons visité la \
        bibliothèque municipale, installée dans une ancienne école. On y trouve \
        des livres pour les enfants, des romans policiers, des cartes anciennes \
        et une salle de lecture très calme. Le bibliothécaire nous a montré un \
        atlas du dix-neuvième siècle, dont les pages étaient jaunies par le \
        temps. À midi, nous avons déjeuné dans un petit restaurant au bord de la \
        rivière. Le chef proposait une truite grillée, des pommes de terre \
        sautées et une tarte aux pommes pour le dessert. L'après-midi, le ciel \
        s'est couvert, et une pluie fine a commencé à tomber sur les toits. Nous \
        nous sommes abrités sous les arcades, en regardant les passants courir \
        avec leurs parapluies. Quand l'averse s'est calmée, nous avons marché le \
        long du canal jusqu'au vieux moulin. Le meunier nous a raconté \
        l'histoire du bâtiment, construit il y a plus de trois cents ans, et \
        plusieurs fois réparé après les crues. Il nous a aussi montré la grande \
        roue en bois, qui tourne encore quand le courant est assez fort. En fin \
        de journée, la lumière dorée donnait aux façades une couleur chaude et \
        douce. Nous avons acheté des cartes postales pour nos amis, et un pot de \
        miel pour nos voisins. Pour finir, nous sommes rentrés à la maison en \
        voiture.
        """

    /// Fabrique `long.aiff` dans `directory` par la voix française du système.
    /// SE SAUTE si `say` ou la voix Thomas manquent : ce sont des conditions
    /// de la machine, pas des régressions.
    ///
    /// `say` n'a aucune échéance à lui : c'est le chien de garde de `speaking`
    /// qui la porte, et `probe` lui donne le processus à tuer (BT2).
    static func makeLongSpeech(in directory: URL, probe: SpeechProbe? = nil) throws -> URL {
        let say = "/usr/bin/say"
        guard FileManager.default.isExecutableFile(atPath: say) else {
            throw XCTSkip("/usr/bin/say introuvable")
        }
        func run(_ arguments: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: say)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            probe?.track(process)
            defer { probe?.track(nil) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        probe?.enter("say -v ? (liste des voix)")
        let (_, voices) = try run(["-v", "?"])
        guard voices.split(separator: "\n").contains(where: {
            $0.hasPrefix("Thomas ") && $0.contains("fr_FR")
        }) else {
            throw XCTSkip("voix française « Thomas » absente de cette machine")
        }
        let url = directory.appendingPathComponent("long.aiff")
        probe?.enter("synthèse de la parole par say")
        // `-r 175` FIGE le débit : sans lui, la durée dépendrait du réglage
        // « Contenu énoncé » de la machine, et le test pourrait retomber sous
        // la minute sans rien dire. `BEI16` : AIFF est gros-boutiste (voir
        // `Tools/make_fixtures.swift`).
        let (status, output) = try run(["-v", "Thomas", "-r", "175",
                                        "-o", url.path,
                                        "--data-format=BEI16@22050",
                                        longSpeechText])
        guard status == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("say a échoué (\(status)) : \(output)")
        }
        return url
    }

    /// Bout en bout, sur une parole d'environ deux minutes : les DEUX témoins,
    /// le premier dit dans les quinze premières secondes et le second dans les
    /// quinze dernières, doivent se retrouver dans la transcription.
    ///
    /// Une transcription entièrement VIDE se saute (C2-05 : une autre
    /// reconnaissance tournait en même temps). Entre tests, ce n'est plus
    /// possible — le verrou de `speaking` les range l'un derrière l'autre,
    /// `--parallel` compris (BT2) ; reste l'app installée qui transcrit.
    /// Une transcription PARTIELLE échoue : c'est exactement le défaut TR1.
    ///
    /// Chien de garde à 600 s, synthèse comprise : 49 s en série à charge 3 ;
    /// à charge 159, la reconnaissance tournait encore après 269 s (14/09) —
    /// 300 s rendaient rouge un travail lent mais vivant.
    func testSpeechLongerThanAMinuteIsWrittenDownWhole() throws {
        let languages = ["fr-FR", "en-US"]
        let directory = try Fixtures.temporaryDirectory("media-long")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Silence maximal COURT au regard de la production (900 s), large au
        // regard de la mesure : un morceau d'une minute sort en 30 à 40 s au
        // repos. Le chien de garde, lui, tombe à 600 s du départ, synthèse
        // comprise.
        setenv("FOUINE_SPEECH_TIMEOUT", "300", 1)
        defer { unsetenv("FOUINE_SPEECH_TIMEOUT") }

        guard let heard = try speaking(budget: 600, { probe -> (TimeInterval, String) in
            try Self.requireSpeechRecognition(languages: languages, probe: probe)
            let url = try Self.makeLongSpeech(in: directory, probe: probe)
            let duration = MediaMetadata.read(url: url, seconds: 30).metadata.duration
            guard duration >= 75 else { return (duration, "") }

            probe.enter("reconnaissance de \(Int(duration)) s de parole")
            let extractor = MediaExtractor(options: MediaOptions(transcribe: true,
                                                                 languages: languages))
            let result: ExtractionResult
            do {
                result = try extractor.extract(url: url, limits: ExtractLimits())
            } catch FouineError.extraction(let message)
                        where message == SpeechTranscriber.emptyResultReason {
                throw XCTSkip("la reconnaissance n'a rien rendu (une autre tournait "
                              + "peut-être en même temps — l'app installée ? C2-05)")
            }
            return (duration, result.pages.filter { $0.source == .transcript }
                .map(\.text).joined(separator: "\n\n"))
        }) else { return }
        let (duration, text) = heard

        XCTAssertGreaterThanOrEqual(duration, 75,
                                    "la parole doit durer plus d'une minute : \(duration) s")
        guard duration >= 75 else { return }
        guard !text.isEmpty else {
            throw XCTSkip("la reconnaissance sur l'appareil n'a rien rendu sur "
                          + "cette machine (installée et autorisée, mais muette)")
        }

        let lowered = text.lowercased()
        XCTAssertTrue(lowered.contains("jardin"),
                      "le témoin des quinze PREMIÈRES secondes manque : \(text)")
        XCTAssertTrue(lowered.contains("voiture"),
                      "le témoin des quinze DERNIÈRES secondes manque : \(text)")
        let stamps = text.components(separatedBy: "\n\n")
            .filter { $0.range(of: #"^\[\d\d:\d\d\] "#, options: .regularExpression) != nil }
        XCTAssertGreaterThanOrEqual(stamps.count, 2,
                                    "au moins deux paragraphes horodatés : \(text)")
        print("TR1 long speech: \(Int(duration)) s of audio, \(text.count) characters, "
              + "paragraphs \(stamps.map { String($0.prefix(7)) })")
    }

    // MARK: - ST1 : « Stop » se voit PENDANT une fenêtre

    /// La transcription est le seul travail de Fouine dont une UNITÉ dure des
    /// minutes : une fenêtre de dix minutes de parole se reconnaît en dix
    /// minutes. Avant ST1, l'attente du résultat était un seul `wait` de trente
    /// minutes — « Stop » ne pouvait donc rien interrompre avant la fin de la
    /// fenêtre en cours.
    ///
    /// Deux minutes de parole, arrêt demandé deux secondes après le départ : la
    /// lecture doit rendre la main tout de suite, sur le cas NOMMÉ et sans rien
    /// écrire, là où la transcription entière prend une bonne minute.
    ///
    /// Mêmes sauts que les tests réels voisins : ce sont des conditions de la
    /// machine, pas des régressions.
    func testStopDuringAWindowRaisesTheNamedCase() throws {
        let languages = ["fr-FR", "en-US"]
        let directory = try Fixtures.temporaryDirectory("media-stop")
        defer { try? FileManager.default.removeItem(at: directory) }

        setenv("FOUINE_SPEECH_TIMEOUT", "300", 1)
        defer { unsetenv("FOUINE_SPEECH_TIMEOUT") }

        // Les assertions se font ICI, sur le fil du test : un corps abandonné
        // par le chien de garde ne doit rien écrire dans un test déjà fini.
        guard let run = try speaking(budget: 90, {
            probe -> (duration: TimeInterval, error: Error?, elapsed: TimeInterval) in
            try Self.requireSpeechRecognition(languages: languages, probe: probe)
            let url = try Self.makeLongSpeech(in: directory, probe: probe)
            let duration = MediaMetadata.read(url: url, seconds: 30).metadata.duration
            guard duration >= 75 else { return (duration, nil, 0) }

            // L'arrêt tombe DEUX SECONDES après le départ : la reconnaissance a
            // commencé, elle est loin d'avoir fini.
            probe.enter("reconnaissance, arrêt demandé à 2 s")
            let flipAt = Date().addingTimeInterval(2)
            var limits = ExtractLimits()
            limits.shouldStop = { Date() >= flipAt }
            let extractor = MediaExtractor(options: MediaOptions(transcribe: true,
                                                                 languages: languages))
            let started = Date()
            do {
                _ = try extractor.extract(url: url, limits: limits)
                return (duration, nil, Date().timeIntervalSince(started))
            } catch {
                return (duration, error, Date().timeIntervalSince(started))
            }
        }) else { return }
        let (duration, error, elapsed) = run

        XCTAssertGreaterThanOrEqual(duration, 75,
                                    "la parole doit durer plus d'une minute : \(duration) s")
        guard duration >= 75 else { return }
        guard case FouineError.cancelled? = error else {
            return XCTFail("attendu cancelled, obtenu \(String(describing: error))")
        }
        // Le silence maximal vaut 300 s ici et 900 s en production ; deux
        // minutes de parole se transcrivent en une minute. L'arrêt n'attend ni
        // l'un ni l'autre.
        XCTAssertLessThan(elapsed, 15, "l'arrêt a attendu la fin de la fenêtre")
        print("ST1 stop pendant la transcription : \(String(format: "%.1f", elapsed)) s "
              + "pour \(Int(duration)) s de parole")
    }

    // MARK: - TR1 : le cumul des morceaux (logique PURE, sans Speech)

    private func chunk(_ words: [(TimeInterval, String)]) -> [SpeechTranscriber.Segment] {
        words.map { SpeechTranscriber.Segment(start: $0.0, text: $0.1) }
    }

    /// Trois morceaux, comme la reconnaissance les rend sur macOS 15 : deux
    /// qui closent un énoncé, puis le final. Tout est gardé, dans l'ordre, et
    /// seul le final délie l'attente.
    func testEveryChunkIsKeptInOrder() {
        var chunks = TranscriptChunks()
        XCTAssertFalse(chunks.receive(.result(segments: chunk([(1.5, "un"), (30, "deux")]),
                                              endOfUtterance: true, isFinal: false)))
        XCTAssertFalse(chunks.receive(.result(segments: chunk([(60, "trois"), (90, "quatre")]),
                                              endOfUtterance: true, isFinal: false)))
        XCTAssertTrue(chunks.receive(.result(segments: chunk([(120.1, "cinq"), (179.4, "six")]),
                                             endOfUtterance: true, isFinal: true)))
        XCTAssertEqual(chunks.segments.map(\.text),
                       ["un", "deux", "trois", "quatre", "cinq", "six"])
        XCTAssertTrue(chunks.isSettled)
        // La tâche peut rappeler après la réponse : ni seconde déliaison, ni ajout.
        XCTAssertFalse(chunks.receive(.result(segments: chunk([(200, "sept")]),
                                              endOfUtterance: true, isFinal: true)))
        XCTAssertFalse(chunks.receive(.failure))
        XCTAssertEqual(chunks.segments.count, 6)
    }

    /// Un final qui répète le dernier morceau n'ajoute rien ; à l'intérieur
    /// d'un morceau, deux segments de même horodatage passent tous les deux.
    func testAFinalRepeatingTheLastChunkAddsNothing() {
        var chunks = TranscriptChunks()
        let second = chunk([(60, "trois"), (60, "trois-bis"), (90, "quatre")])
        _ = chunks.receive(.result(segments: chunk([(1, "un"), (30, "deux")]),
                                   endOfUtterance: true, isFinal: false))
        _ = chunks.receive(.result(segments: second, endOfUtterance: true, isFinal: false))
        XCTAssertTrue(chunks.receive(.result(segments: second,
                                             endOfUtterance: true, isFinal: true)))
        XCTAssertEqual(chunks.segments.map(\.text),
                       ["un", "deux", "trois", "trois-bis", "quatre"])
    }

    /// Une erreur après deux morceaux — « No speech detected » sur le silence
    /// de fin de fenêtre — délie l'attente et GARDE les deux morceaux.
    func testAnErrorKeepsTheChunksAlreadyReceived() {
        var chunks = TranscriptChunks()
        _ = chunks.receive(.result(segments: chunk([(1, "un"), (30, "deux")]),
                                   endOfUtterance: true, isFinal: false))
        _ = chunks.receive(.result(segments: chunk([(60, "trois"), (90, "quatre")]),
                                   endOfUtterance: true, isFinal: false))
        XCTAssertTrue(chunks.receive(.failure))
        XCTAssertEqual(chunks.segments.map(\.text), ["un", "deux", "trois", "quatre"])
    }

    /// Un son court : un seul résultat, final — le comportement d'avant TR1.
    /// Un résultat qui n'est ni final ni fin d'énoncé n'est pas retenu, et une
    /// erreur seule délie sans rien rendre.
    func testAShortRecordingIsASingleFinalResult() {
        var chunks = TranscriptChunks()
        XCTAssertFalse(chunks.receive(.result(segments: chunk([(0.2, "le")]),
                                              endOfUtterance: false, isFinal: false)))
        XCTAssertTrue(chunks.segments.isEmpty)
        XCTAssertTrue(chunks.receive(.result(segments: chunk([(0.2, "le"), (0.6, "polymère")]),
                                             endOfUtterance: false, isFinal: true)))
        XCTAssertEqual(chunks.segments.map(\.text), ["le", "polymère"])

        var silent = TranscriptChunks()
        XCTAssertTrue(silent.receive(.failure))
        XCTAssertTrue(silent.segments.isEmpty)
    }

    // MARK: - TR1 : « no metadata » dit pourquoi

    /// Une vidéo MUETTE de trois secondes, sans balise : AVFoundation l'ouvre,
    /// elle n'a aucune piste son.
    static func writeSilentVideo(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 160, height = 120
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw XCTSkip("AVAssetWriter refuse d'écrire : "
                          + (writer.error?.localizedDescription ?? "?"))
        }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(frame) * height)
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        for second in 0...3 {
            while !input.isReadyForMoreMediaData { usleep(2_000) }
            adaptor.append(frame, withPresentationTime:
                            CMTime(seconds: Double(second), preferredTimescale: 600))
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        XCTAssertEqual(writer.status, .completed,
                       writer.error?.localizedDescription ?? "écriture inachevée")
    }

    private func extractionMessage(_ extractor: MediaExtractor, _ url: URL,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) -> String? {
        do {
            _ = try extractor.extract(url: url, limits: ExtractLimits())
            XCTFail("extraction inattendue de \(url.lastPathComponent)",
                    file: file, line: line)
        } catch FouineError.extraction(let message) {
            return message
        } catch {
            XCTFail("erreur inattendue : \(error)", file: file, line: line)
        }
        return nil
    }

    /// Transcription ALLUMÉE, vidéo muette : la parenthèse dit qu'il n'y avait
    /// rien à écouter. Transcription éteinte : le motif exact, inchangé.
    func testSilentVideoNamesTheMissingSound() throws {
        let directory = try Fixtures.temporaryDirectory("media-muet")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("muette.mov")
        try Self.writeSilentVideo(to: url)

        let listening = MediaExtractor(options: MediaOptions(transcribe: true))
        XCTAssertEqual(extractionMessage(listening, url), "no metadata (no audio track)")
        XCTAssertEqual(extractionMessage(listening, url), MediaExtractor.noAudioTrackReason)
        XCTAssertEqual(extractionMessage(MediaExtractor(), url),
                       MediaExtractor.noMetadataReason)
    }

    /// Transcription allumée, plafond d'une minute, parole d'environ deux
    /// minutes : le motif nomme le plafond. Aucune reconnaissance n'est lancée
    /// — le plafond se juge sur la durée, avant.
    ///
    /// Aucune reconnaissance, mais `say` : c'est CE test qui a prouvé, le
    /// 14/09, que le gel de `make ci-unit` venait de la synthèse et non de la
    /// reconnaissance. Il passe donc lui aussi par le verrou et le chien de
    /// garde (BT2).
    func testRecordingLongerThanTheCapNamesTheCap() throws {
        let directory = try Fixtures.temporaryDirectory("media-plafond")
        defer { try? FileManager.default.removeItem(at: directory) }

        guard let message = try speaking(budget: 90, { probe -> String in
            let url = try Self.makeLongSpeech(in: directory, probe: probe)
            probe.enter("lecture de la durée, refus du plafond")
            let capped = MediaExtractor(options: MediaOptions(transcribe: true,
                                                              maxMinutes: 1))
            do {
                _ = try capped.extract(url: url, limits: ExtractLimits())
                return "extraction inattendue de long.aiff"
            } catch FouineError.extraction(let message) {
                return message
            } catch {
                return "erreur inattendue : \(error)"
            }
        }) else { return }
        XCTAssertEqual(message, "no metadata (longer than 1 min)")
        XCTAssertEqual(MediaExtractor.tooLongReason(maxMinutes: 1),
                       "no metadata (longer than 1 min)")
    }

    /// Toutes les formes de « no metadata » sont des `.skipped` : un
    /// enregistrement sans rien à indexer n'est pas un fichier cassé. L'échec
    /// d'une transcription vide, lui, reste un échec.
    func testEveryFormOfNoMetadataIsASkip() {
        let forms = [MediaExtractor.noMetadataReason,
                     MediaExtractor.noAudioTrackReason,
                     MediaExtractor.unknownDurationReason,
                     MediaExtractor.noSpeechReason,
                     MediaExtractor.tooLongReason(maxMinutes: 120)]
        XCTAssertEqual(forms, ["no metadata", "no metadata (no audio track)",
                               "no metadata (unknown duration)", "no metadata (no speech)",
                               "no metadata (longer than 120 min)"])
        for reason in forms {
            XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(reason)), reason)
        }
        let notInstalled = SpeechTranscriber.notInstalledReason(languages: ["fr-FR"])
        XCTAssertTrue(notInstalled.hasPrefix(SpeechTranscriber.notInstalledPrefix))
        XCTAssertEqual(ExtractOutcome.skipReason(for: .extraction(notInstalled)), notInstalled)
        XCTAssertNil(ExtractOutcome.skipReason(
            for: .extraction(SpeechTranscriber.emptyResultReason)))
        // Ce que la relecture reprend : le motif EXACT et les deux refus.
        XCTAssertEqual(MediaExtractor.rereadSkipReasons,
                       [MediaExtractor.noMetadataReason, SpeechTranscriber.notAuthorisedReason])
        XCTAssertEqual(MediaExtractor.rereadSkipReasonPrefixes,
                       [SpeechTranscriber.notInstalledPrefix])
    }

    // MARK: - Découpage et horodatage (logique PURE, sans machine)

    func testWindowsCoverTheWholeRecording() {
        let ranges = MediaDecoder.windows(duration: 1_500)   // 25 minutes
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(CMTimeGetSeconds(ranges[0].start), 0, accuracy: 0.01)
        XCTAssertEqual(CMTimeGetSeconds(ranges[2].start), 1_200, accuracy: 0.01)
        // La dernière fenêtre est COURTE, jamais arrondie : l'arrondir ferait
        // lire cinq minutes de silence, la tronquer perdrait la fin.
        XCTAssertEqual(CMTimeGetSeconds(ranges[2].duration), 300, accuracy: 0.01)
        XCTAssertTrue(MediaDecoder.windows(duration: 0).isEmpty)
    }

    func testParagraphsAreCutEveryFortySeconds() {
        let segments = (0..<10).map {
            SpeechTranscriber.Segment(start: Double($0) * 15, text: "mot\($0)")
        }
        let text = SpeechTranscriber.paragraphs(segments)
        let blocks = text.components(separatedBy: "\n\n")
        // 150 s de parole, une coupe toutes les 40 s : quatre blocs.
        XCTAssertEqual(blocks.count, 4, text)
        XCTAssertTrue(blocks[0].hasPrefix("[00:00] "), blocks[0])
        XCTAssertTrue(blocks[1].hasPrefix("[00:45] "), blocks[1])
        XCTAssertEqual(SpeechTranscriber.paragraphs([]), "")
    }

    func testTimestampsPastAnHourStayReadable() {
        XCTAssertEqual(MediaMetadata.timestamp(0), "00:00")
        XCTAssertEqual(MediaMetadata.timestamp(125), "02:05")
        XCTAssertEqual(MediaMetadata.timestamp(7_505), "2:05:05")
    }

    // MARK: - C2-05 : une transcription vide sur une piste qui dure

    /// La RÈGLE, pure. La machine, elle, n'est pas éprouvée ici : ce qui compte
    /// est qu'un résultat vide cesse d'être annoncé comme une réussite.
    func testAnEmptyTranscriptOfALongTrackIsAFailure() {
        XCTAssertTrue(SpeechTranscriber.isEmptyFailure(characters: 0,
                                                       duration: 30))
        XCTAssertFalse(SpeechTranscriber.isEmptyFailure(characters: 0,
                                                        duration: 2),
                       "deux secondes de son peuvent légitimement être muettes")
        XCTAssertFalse(SpeechTranscriber.isEmptyFailure(characters: 445,
                                                        duration: 30))
        // Les pages rendues par fenêtre : ce sont leurs caractères UTILES qui
        // comptent, pas leur nombre.
        XCTAssertEqual(SpeechTranscriber.usefulCharacters(["", "  \n "]), 0)
        XCTAssertEqual(SpeechTranscriber.usefulCharacters(["", " azote "]), 5)
        XCTAssertEqual(SpeechTranscriber.emptyResultReason,
                       "speech recognition returned nothing — try again")
    }

    // MARK: - CM-23 : la liste blanche des protocoles

    /// `-protocol_whitelist file` AVANT `-i`, dans les deux invocations. Sans
    /// elle, la protection contre un `.mkv` qui est en réalité une playlist
    /// vient entièrement de la version de ffmpeg installée.
    func testFFmpegAndFFprobeOnlyEverOpenLocalFiles() {
        let media = URL(fileURLWithPath: "/tmp/piege.mkv")
        let out = URL(fileURLWithPath: "/tmp/out.wav")

        for arguments in [MediaDecoder.convertArguments(url: media, to: out),
                          MediaMetadata.probeArguments(url: media)] {
            let whitelist = try? XCTUnwrap(
                arguments.firstIndex(of: "-protocol_whitelist"))
            let input = try? XCTUnwrap(arguments.firstIndex(of: "-i"))
            XCTAssertNotNil(whitelist, "\(arguments)")
            XCTAssertNotNil(input, "\(arguments)")
            guard let whitelist, let input else { continue }
            XCTAssertEqual(arguments[whitelist + 1], "file")
            XCTAssertLessThan(whitelist, input,
                              "la liste blanche doit précéder l'entrée : \(arguments)")
        }
    }

    // MARK: - BT2 : une reconnaissance qui se tait est coupée, une lente ne l'est pas

    /// La reconnaissance SIMULÉE qui ne répond jamais : un sémaphore que
    /// personne ne signale, et un dernier signe de vie figé. L'attente rend
    /// `.expired` au bout du silence, sans le déborder d'une tranche entière ;
    /// la fenêtre coupée fait alors échouer le document sur
    /// `stoppedAnsweringReason` — un `.failed`, pas un refus rangé en
    /// `.skipped` — que la révision suivante de la transcription reprend.
    func testARecognitionThatGoesQuietIsCutAndFailsTheDocument() {
        let neverAnswers = DispatchSemaphore(value: 0)
        let lastSign = Date()
        let started = Date()
        // Tranche de 5 s, silence de 0,3 s : sans la tranche rognée, l'attente
        // rendrait la main au bout de 5 s.
        let end = SpeechTranscriber.awaitWindow(settled: neverAnswers, silence: 0.3,
                                                lastHeard: { lastSign },
                                                shouldStop: { false }, tick: 5)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(end, .expired)
        XCTAssertGreaterThanOrEqual(elapsed, 0.29)
        XCTAssertLessThan(elapsed, 3, "l'attente a débordé le silence d'une tranche")

        XCTAssertThrowsError(try SpeechTranscriber.refuseIfCut(end)) {
            guard case FouineError.extraction(let message) = $0 else {
                return XCTFail("erreur inattendue : \($0)")
            }
            XCTAssertEqual(message, "speech recognition stopped answering")
            XCTAssertNil(ExtractOutcome.skipReason(for: .extraction(message)),
                         "un échec, pas un refus rangé")
        }
        XCTAssertTrue(MediaExtractor.rereadFailedReasonSubstrings
                        .contains(SpeechTranscriber.stoppedAnsweringReason))
        XCTAssertNoThrow(try SpeechTranscriber.refuseIfCut(.settled))
        XCTAssertNoThrow(try SpeechTranscriber.refuseIfCut(nil))
    }

    /// Le cas du 13/09, en petit : une reconnaissance LENTE qui rend un signe
    /// de vie toutes les 0,1 s pendant 2 s n'est jamais coupée par un silence
    /// de 1 s — là où une échéance fixe de 1 s l'aurait tronquée. Contre-
    /// épreuves : une réponse délie aussitôt, un arrêt aussi.
    func testASlowRecognitionThatKeepsAnsweringIsNeverCut() {
        let clock = HeardClock()
        let settled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<20 {
                usleep(100_000)
                clock.touch()
            }
            settled.signal()
        }
        let started = Date()
        let end = SpeechTranscriber.awaitWindow(settled: settled, silence: 1,
                                                lastHeard: clock.last,
                                                shouldStop: { false }, tick: 0.05)
        XCTAssertEqual(end, .settled, "une reconnaissance vivante a été coupée")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1,
                             "l'épreuve n'a pas duré plus qu'un silence")

        let answers = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { answers.signal() }
        XCTAssertEqual(SpeechTranscriber.awaitWindow(settled: answers, silence: 30,
                                                     lastHeard: { Date() },
                                                     shouldStop: { false }, tick: 0.05),
                       .settled)
        XCTAssertEqual(SpeechTranscriber.awaitWindow(settled: DispatchSemaphore(value: 0),
                                                     silence: 30, lastHeard: { Date() },
                                                     shouldStop: { true }),
                       .stopped)
    }

    // MARK: - BT2 : une parole à la fois, et jamais d'attente sans fin

    /// Deux prises du verrou s'excluent. Deux fils, chacun avec SA description
    /// de fichier — comme deux processus ; un compteur de présents ne dépasse
    /// jamais un. Contre-épreuve : verrou tenu, une prise bornée abandonne à
    /// son échéance au lieu d'attendre. Chemin propre au test, pour ne jamais
    /// retenir un vrai test de parole d'un autre processus.
    func testTheSpeechLockLetsOneHolderInAtATime() throws {
        let directory = try Fixtures.temporaryDirectory("speech-lock")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fouine-tests-speech.lock").path

        let presence = Presence()
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                for _ in 0..<5 {
                    guard let lock = SpeechTestLock(path: path, waitingAtMost: 20) else {
                        return presence.miss()
                    }
                    presence.enter()
                    usleep(20_000)
                    presence.leave()
                    lock.release()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(presence.entries, 10)
        XCTAssertEqual(presence.misses, 0)
        XCTAssertEqual(presence.peak, 1, "deux porteurs du verrou en même temps")

        let held = try XCTUnwrap(SpeechTestLock(path: path, waitingAtMost: 1))
        let started = Date()
        XCTAssertNil(SpeechTestLock(path: path, waitingAtMost: 0.3),
                     "une seconde prise a obtenu un verrou déjà tenu")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        held.release()
        XCTAssertNotNil(SpeechTestLock(path: path, waitingAtMost: 1),
                        "le verrou rendu doit se reprendre")
    }

    /// Attente maximale du verrou : les budgets des trois AUTRES tests de
    /// parole au pire (600 + 90 + 90 s), plus une marge.
    static let speechLockWait: TimeInterval = 900

    /// La charge de la machine, lue sans lancer de processus : un `uptime`
    /// lancé sur une machine à genoux pourrait attendre à son tour.
    static func loadAverages() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "charge illisible" }
        return "charge " + loads.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }

    /// Les deux sauts des tests réels : conditions de la MACHINE, pas
    /// régressions. Appelé DANS le corps gardé : `SFSpeechRecognizer(locale:)`
    /// et l'autorisation sont des appels de framework synchrones.
    static func requireSpeechRecognition(languages: [String], probe: SpeechProbe) throws {
        probe.enter("disponibilité de la reconnaissance")
        guard SpeechTranscriber.recognizer(languages: languages) != nil else {
            throw XCTSkip(SpeechTranscriber.notInstalledReason(languages: languages))
        }
        guard SpeechTranscriber.authorization() == .authorized else {
            throw XCTSkip(SpeechTranscriber.notAuthorisedReason)
        }
    }

    /// Tout test qui fait parler `say` ou écouter la reconnaissance passe par ici.
    ///
    /// UN À LA FOIS, ENTRE PROCESSUS. En `--parallel`, chaque test est un
    /// processus : seul un verrou de FICHIER les range l'un derrière l'autre.
    /// Le 14/09 (lot BT1), trois tests partis ensemble à charge 361 sont restés
    /// à 0 % de processeur pendant 24 minutes.
    ///
    /// ROUGE PLUTÔT QUE PENDU. Le corps tourne sur un fil à lui ; le test
    /// l'attend au plus `budget` secondes, comptées APRÈS la prise du verrou.
    /// À l'échéance, le `say` en cours est tué, le test échoue en disant
    /// l'étape où il en était et la charge, et le verrou est rendu. Le fil
    /// abandonné, lui, continue — comme dans `Deadline.run`.
    ///
    /// Le corps ne fait AUCUNE assertion : il rend ce qu'il a vu, et le test
    /// juge sur son propre fil. Une assertion écrite par un corps abandonné
    /// tomberait dans un test déjà fini.
    func speaking<T>(budget: TimeInterval,
                     _ body: @escaping (SpeechProbe) throws -> T,
                     test: String = #function,
                     file: StaticString = #filePath, line: UInt = #line) throws -> T? {
        let waitingSince = Date()
        guard let lock = SpeechTestLock(waitingAtMost: Self.speechLockWait) else {
            XCTFail("\(test) : le verrou des tests de parole (\(SpeechTestLock.sharedPath)) "
                    + "n'est pas venu en \(Int(Self.speechLockWait)) s — \(Self.loadAverages())",
                    file: file, line: line)
            return nil
        }
        defer { lock.release() }
        let waited = Date().timeIntervalSince(waitingSince)
        if waited >= 1 {
            print("BT2 \(test): speech lock taken after \(Int(waited)) s")
        }

        let probe = SpeechProbe()
        let outcome = SpeechOutcome<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            outcome.set(Result { try body(probe) })
            done.signal()
        }
        thread.name = "fouine.tests.speech"
        // 8 Mio, comme `Deadline.run` : Speech et AVFoundation descendent profond.
        thread.stackSize = 8 << 20
        thread.start()

        guard done.wait(timeout: .now() + budget) == .success else {
            probe.killChild()
            XCTFail("\(test) : chien de garde — aucun résultat en \(Int(budget)) s ; "
                    + "\(probe.state) ; \(Self.loadAverages())", file: file, line: line)
            return nil
        }
        guard let result = outcome.take() else {
            XCTFail("\(test) : corps signalé sans résultat", file: file, line: line)
            return nil
        }
        return try result.get()
    }

    /// Le compteur de présents du test du verrou.
    private final class Presence: @unchecked Sendable {
        private let mutex = NSLock()
        private var inside = 0
        private(set) var peak = 0
        private(set) var entries = 0
        private(set) var misses = 0
        func enter() {
            mutex.lock(); defer { mutex.unlock() }
            inside += 1; entries += 1; peak = max(peak, inside)
        }
        func leave() { mutex.lock(); inside -= 1; mutex.unlock() }
        func miss() { mutex.lock(); misses += 1; mutex.unlock() }
    }

    /// Le dernier signe de vie d'une reconnaissance simulée.
    private final class HeardClock: @unchecked Sendable {
        private let mutex = NSLock()
        private var heard = Date()
        func touch() { mutex.lock(); heard = Date(); mutex.unlock() }
        func last() -> Date { mutex.lock(); defer { mutex.unlock() }; return heard }
    }
}

/// Verrou `flock` sur un fichier. Il exclut entre PROCESSUS, et aussi entre
/// deux fils qui ouvrent chacun le fichier : il tient à la description de
/// fichier ouverte, pas au processus (contrairement à `fcntl`). Le noyau le
/// rend de lui-même si le processus meurt.
final class SpeechTestLock: @unchecked Sendable {
    /// Nom FIXE, sous le dossier temporaire de l'utilisateur : deux worktrees
    /// qui testent en même temps passent eux aussi l'un après l'autre — une
    /// seule parole sur la machine.
    static let sharedPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("fouine-tests-speech.lock")

    private var descriptor: Int32

    /// Prend le verrou en l'attendant au plus `seconds` ; `nil` à l'échéance,
    /// ou si le fichier ne s'ouvre pas.
    init?(path: String = SpeechTestLock.sharedPath, waitingAtMost seconds: TimeInterval) {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        // Par sondes non bloquantes : un `flock` bloquant n'a pas d'échéance.
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { close(fd); return nil }
            usleep(50_000)
        }
        descriptor = fd
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

/// Ce que fait le corps d'un test de parole quand le chien de garde regarde :
/// l'étape, depuis quand, et le `say` en cours, à tuer.
final class SpeechProbe: @unchecked Sendable {
    private let mutex = NSLock()
    private var step = "départ"
    private var since = Date()
    private var child: Process?

    func enter(_ step: String) {
        mutex.lock(); defer { mutex.unlock() }
        self.step = step
        since = Date()
    }

    func track(_ process: Process?) {
        mutex.lock(); defer { mutex.unlock() }
        child = process
    }

    var state: String {
        mutex.lock(); defer { mutex.unlock() }
        return "étape « \(step) » depuis \(Int(Date().timeIntervalSince(since))) s"
    }

    func killChild() {
        mutex.lock(); defer { mutex.unlock() }
        if let child, child.isRunning { child.terminate() }
    }
}

/// Le résultat du corps, qui traverse deux fils.
final class SpeechOutcome<T>: @unchecked Sendable {
    private let mutex = NSLock()
    private var stored: Result<T, Error>?
    func set(_ value: Result<T, Error>) { mutex.lock(); stored = value; mutex.unlock() }
    func take() -> Result<T, Error>? { mutex.lock(); defer { mutex.unlock() }; return stored }
}
