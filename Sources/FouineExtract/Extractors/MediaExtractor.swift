// MediaExtractor.swift — fichiers son et vidéo (SPEC §5.3, lot INT-F3).
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Ingest.
//
// DEUX ÉTAGES, ET C'EST TOUT LE DESSIN DE CE FICHIER.
//
//   1. LES MÉTADONNÉES, toujours quand la famille est allumée : titre, artiste,
//      album, auteur, description, commentaire, paroles, date, durée,
//      chapitres. Coût : quelques millisecondes. C'est ce qui rend une
//      conférence nommée « Cristallisation des polymères — 3 mars » cherchable
//      sans écouter une seconde de son.
//   2. LA TRANSCRIPTION, seulement si on la demande (`extract.transcribe`) :
//      la parole mise par écrit SUR CETTE MACHINE. Coût : de l'ordre de la
//      durée de l'enregistrement. Rien ne quitte le Mac (voir
//      `SpeechTranscriber`, `requiresOnDeviceRecognition`).
//
// ÉTEINT PAR DÉFAUT, comme les images, et pour la même raison : une
// bibliothèque musicale de 20 000 titres n'est pas un fonds documentaire.
// L'inscription au registre est CONDITIONNELLE (`extract.media`), et les
// extensions vivent dans `DefaultExtractorRegistry.mediaExtensions` — hors de
// l'union du §5.3, exactement comme `imageExtensions`.
//
// LES CONTENEURS QU'AVFOUNDATION N'OUVRE PAS — mkv, avi, wmv, webm, ogg —
// passent par ffmpeg s'il est installé, et sont refusés par un motif À JETON
// (`missing-tool:ffmpeg`) s'il ne l'est pas : le crawl y revient tout seul le
// jour où l'outil apparaît, sans qu'il faille toucher au fichier (constat
// A3-05, même mécanique que djvulibre).

import Foundation
import AVFoundation
import FouineCore

/// Ce que l'extracteur de médias a besoin de savoir des réglages. Groupé en une
/// structure plutôt qu'en trois paramètres : le registre le transmet tel quel,
/// et une clé de plus n'oblige pas à retoucher trois signatures.
public struct MediaOptions: Sendable {
    public var transcribe: Bool
    /// Les langues de `ocr.languages` — VOLONTAIREMENT les mêmes que pour les
    /// documents scannés : ce sont les langues du fonds, pas celles d'un
    /// moteur, et une seconde clé serait un second endroit à tenir à jour.
    public var languages: [String]
    public var maxMinutes: Int

    public init(transcribe: Bool = false,
                languages: [String] = ["fr-FR", "en-US"],
                maxMinutes: Int = 120) {
        self.transcribe = transcribe
        self.languages = languages
        self.maxMinutes = maxMinutes
    }

    public init(snapshot: SettingsSnapshot) {
        self.init(transcribe: snapshot.extractTranscribe,
                  languages: snapshot.ocrLanguages,
                  maxMinutes: snapshot.transcribeMaxMinutes)
    }

    /// Repli quand personne n'a lu la base : les variables d'environnement
    /// seules. Même compromis que `DefaultExtractorRegistry(extractImages:)`.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MediaOptions {
        var options = MediaOptions()
        if let raw = environment["FOUINE_EXTRACT_TRANSCRIBE"],
           ["1", "true", "yes", "on"].contains(raw.lowercased()) {
            options.transcribe = true
        }
        if let raw = environment["FOUINE_OCR_LANGUAGES"] {
            let codes = SettingSpec.tokens(raw)
            if !codes.isEmpty { options.languages = codes }
        }
        if let raw = environment["FOUINE_TRANSCRIBE_MAX_MINUTES"],
           let value = Int(raw), (1...600).contains(value) {
            options.maxMinutes = value
        }
        return options
    }
}

public struct MediaExtractor: TextExtractor {

    /// Sons. `caf` est là parce que c'est le format des enregistrements de
    /// macOS lui-même (Dictaphone, `say -o`), `m4b` parce que c'est celui des
    /// livres audio — deux familles qu'on cherche exactement comme des
    /// documents.
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif",
        "flac", "caf", "ogg", "oga", "opus",
    ]

    /// Vidéos.
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "avi", "mkv", "wmv", "webm",
    ]

    public static let supportedExtensions: Set<String> =
        audioExtensions.union(videoExtensions)

    /// La RÉVISION de la voie de transcription, que la passe inscrit dans
    /// `meta` (`transcription_revision`) après avoir remis les médias en file.
    /// On la change quand la reconnaissance change assez pour justifier de
    /// TOUT relire : chaque enregistrement déjà lu repasse alors par elle, une
    /// fois (`IndexPass`, TR1). `speech-rev2` : les morceaux d'une minute sont
    /// cumulés — avant, seule la dernière minute de chaque fenêtre de dix
    /// était gardée. `speech-rev3` (BT2) : une fenêtre n'est plus coupée au bout
    /// de 1 800 s fixes mais sur un silence de la reconnaissance — les
    /// enregistrements transcrits lentement avaient perdu la fin de leurs
    /// fenêtres.
    public static let transcriptRevision = "speech-rev3"

    /// Le média s'ouvre, ne porte AUCUNE balise, et la transcription est
    /// ÉTEINTE. Refus `.skipped` et non `.failed` : le fichier n'est pas
    /// cassé, il n'y a simplement rien à indexer. Fouine n'indexe pas les noms
    /// de fichiers (SPEC §5.3 (e), mesuré par INT-F2) : ce refus nommé, lisible
    /// dans la carte « documents illisibles », est sa seule trace.
    ///
    /// Ce texte EXACT garde ce sens-là pour les lignes déjà en base — ni
    /// balise, ni transcription demandée — et c'est lui que la relecture
    /// reprend quand la transcription s'allume (TR1).
    public static let noMetadataReason = "no metadata"

    /// Transcription ALLUMÉE, mais rien à mettre par écrit : la parenthèse dit
    /// pourquoi (TR1). Même préfixe, donc même rangement `.skipped` dans le
    /// cœur (`ExtractOutcome.isMediaSkip`) — et aucune relecture quand la
    /// transcription s'allume, puisqu'elle l'était déjà.
    public static let noAudioTrackReason = "no metadata (no audio track)"
    public static let unknownDurationReason = "no metadata (unknown duration)"
    /// Transcrit, et rien entendu, sur moins de cinq secondes de son (au-delà,
    /// c'est l'échec `SpeechTranscriber.emptyResultReason`).
    public static let noSpeechReason = "no metadata (no speech)"
    public static func tooLongReason(maxMinutes: Int) -> String {
        "no metadata (longer than \(maxMinutes) min)"
    }

    /// Les motifs `.skipped` qu'une relecture reprend quand la transcription
    /// s'allume ou change de révision : « no metadata » EXACT (lu
    /// transcription éteinte), et les deux refus de la reconnaissance — la
    /// dictée a pu être installée, l'autorisation donnée, depuis.
    public static let rereadSkipReasons: [String] = [
        noMetadataReason, SpeechTranscriber.notAuthorisedReason,
    ]
    /// Même chose, par préfixe : le refus « non installée » porte les langues.
    public static let rereadSkipReasonPrefixes: [String] = [
        SpeechTranscriber.notInstalledPrefix,
    ]

    /// Les motifs `.failed` qu'une relecture reprend : l'échec « returned
    /// nothing » causé par le bogue des morceaux d'une minute d'avant TR1, et
    /// la fenêtre coupée par un silence de la reconnaissance (BT2). Une passe
    /// ne relit que les documents `.discovered` : sans cette liste, ces échecs
    /// n'attendraient plus qu'un changement de leur fichier.
    public static let rereadFailedReasonSubstrings: [String] = [
        SpeechTranscriber.emptyResultReason,
        SpeechTranscriber.stoppedAnsweringReason,
    ]

    /// Motif à jeton d'un conteneur étranger sans ffmpeg. Le jeton dit au crawl
    /// de revenir sur ce refus dès que l'outil apparaît
    /// (`ExternalTool.missingTool(inSkipReason:)`).
    public static func ffmpegMissingReason(_ ext: String) -> String {
        "\(ext): ffmpeg is missing "
        + "(\(ExternalTool.missingToolToken(MediaDecoder.ffmpegExecutable)))"
    }

    /// Échéance d'OUVERTURE d'un média — lire des balises et une durée. Mesuré
    /// à quelques millisecondes ; 60 s ne se déclenchent que sur un fichier qui
    /// piège l'analyseur, jamais sur un fichier lent.
    static let openSeconds: TimeInterval = 60

    /// Échéance de la conversion ffmpeg. Un démultiplexage sans vidéo (`-vn`)
    /// tourne à plusieurs dizaines de fois le temps réel : 1 800 s couvrent
    /// largement un film de deux heures.
    static let convertSeconds: TimeInterval = 1_800

    let options: MediaOptions
    /// Où chercher ffmpeg. Injectable pour les TESTS seulement (voir
    /// `MediaDecoder.ffmpeg(directories:)`) : l'init public n'en parle pas.
    let toolDirectories: [String]

    public init(options: MediaOptions = MediaOptions()) {
        self.init(options: options, toolDirectories: ExternalTool.searchPaths)
    }

    init(options: MediaOptions, toolDirectories: [String]) {
        self.options = options
        self.toolDirectories = toolDirectories
    }

    public func extract(url: URL, limits: ExtractLimits) throws -> ExtractionResult {
        try FileGuard.check(url, limits)
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }

        let reading = MediaMetadata.read(url: url, seconds: Self.openSeconds)
        var metadata = reading.metadata
        var notes: [String: String] = [:]
        /// Le fichier À DONNER à la reconnaissance : le média lui-même quand
        /// AVFoundation l'ouvre, le WAV converti sinon, `nil` s'il n'y a pas de
        /// son du tout.
        var speechURL: URL? = reading.hasAudio ? url : nil

        if !reading.opened {
            guard MediaDecoder.ffmpegContainers.contains(ext) else {
                throw FouineError.extraction("unreadable media (\(name))")
            }
            guard let ffmpeg = MediaDecoder.ffmpeg(directories: toolDirectories) else {
                // `.unsupported` et non `.extraction` : c'est `ExtractOutcome`
                // qui compose le motif à jeton, en un seul endroit, comme pour
                // djvu.
                throw FouineError.unsupported(ext: ext)
            }
            if let ffprobe = MediaDecoder.ffprobe(besides: ffmpeg),
               let probed = MediaMetadata.probe(url: url, ffprobe: ffprobe) {
                metadata = probed
            }
            if options.transcribe {
                let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("fouine-media-\(UUID().uuidString).wav")
                try MediaDecoder.convert(url: url, ffmpeg: ffmpeg, to: temporary,
                                         timeout: Self.convertSeconds)
                scratch = temporary
                let converted = MediaMetadata.read(url: temporary,
                                                   seconds: Self.openSeconds)
                speechURL = converted.hasAudio ? temporary : nil
                if metadata.duration <= 0 { metadata.duration = converted.metadata.duration }
            }
        }

        // ── Page 1 : les métadonnées ────────────────────────────────────────
        var budget = TextBudget(maxBytes: limits.maxTextBytes)
        var pages: [PageText] = []
        // LA DURÉE SEULE N'EST PAS UNE MÉTADONNÉE. Tout conteneur en porte une
        // (mesuré : un AIFF écrit par `say` n'a rien d'autre), et une page
        // « Duration: 00:01 » ne se cherche pas — elle ne ferait qu'ajouter un
        // document vide à l'index. Il faut au moins un CHAMP ou un CHAPITRE.
        let header = metadata.isEmpty ? "" : metadata.text
        if !header.isEmpty {
            pages.append(PageText(page: 1, text: budget.take(header), source: .native))
        }
        // Numérotation COMPACTE : sans métadonnées il n'y a pas de page 1 vide,
        // la première fenêtre transcrite est la page 1. Réserver une page vide
        // ferait afficher « page 2 sur 7 » sur le premier extrait d'un
        // enregistrement qui n'a pas de balise.
        let firstWindowPage = pages.isEmpty ? 1 : 2
        var pageCount = pages.count
        // Le motif si AUCUNE page ne sort (TR1) : « no metadata » tout court
        // quand la transcription est éteinte, sa forme à parenthèse quand elle
        // était allumée sans rien trouver à mettre par écrit. La distinction
        // décide de ce que la relecture reprend, et de la phrase de l'app.
        var nothingReason = Self.noMetadataReason

        // ── Pages suivantes : une par fenêtre de dix minutes ────────────────
        if options.transcribe {
            if let speechURL, metadata.duration > 0 {
                if metadata.duration > Double(options.maxMinutes) * 60 {
                    notes["transcription"] =
                        "skipped: longer than \(options.maxMinutes) min"
                    nothingReason = Self.tooLongReason(maxMinutes: options.maxMinutes)
                } else {
                    nothingReason = Self.noSpeechReason
                    do {
                        let windows = try SpeechTranscriber.transcribe(
                            url: speechURL, duration: metadata.duration,
                            languages: options.languages,
                            // L'arrêt demandé par l'utilisateur descend
                            // jusqu'ici (ST1) : c'est la seule unité de travail
                            // de Fouine qui dure des minutes.
                            shouldStop: limits.shouldStop,
                            log: { line in
                                FileHandle.standardError.write(Data((line + "\n").utf8))
                            })
                        // ZÉRO CARACTÈRE SUR UNE PISTE QUI DURE = ÉCHEC
                        // (constat C2-05). Ce refus est volontairement un
                        // `.failed` et non une note dans `docs.meta`, MÊME quand
                        // les métadonnées, elles, sont là : un document
                        // `extracted` n'est jamais retenté. Un `.failed` ne l'est
                        // pas non plus d'une passe à l'autre — une passe ne lit
                        // que les `.discovered` — : il est repris quand son
                        // fichier change, ou à la révision suivante de la
                        // transcription (`rereadFailedReasonSubstrings`).
                        if SpeechTranscriber.isEmptyFailure(
                            characters: SpeechTranscriber.usefulCharacters(windows),
                            duration: metadata.duration) {
                            throw FouineError.extraction(
                                SpeechTranscriber.emptyResultReason)
                        }
                        pageCount += windows.count
                        for (index, text) in windows.enumerated()
                        where !TextPagination.isBlank(text) {
                            pages.append(PageText(page: firstWindowPage + index,
                                                  text: budget.take(text),
                                                  source: .transcript))
                        }
                    } catch let refusal as SpeechTranscriber.Refusal {
                        // Le refus NOMMÉ vaut mieux que « no metadata » : s'il
                        // n'y avait rien d'autre à indexer, c'est LUI qui doit
                        // s'écrire dans `docs.err`, parce qu'il dit le geste à
                        // faire (installer la dictée, donner l'autorisation).
                        if header.isEmpty { throw FouineError.extraction(refusal.reason) }
                        notes["transcription"] = "skipped: " + refusal.reason
                    }
                }
            } else if speechURL == nil {
                notes["transcription"] = "skipped: no audio track"
                nothingReason = Self.noAudioTrackReason
            } else {
                nothingReason = Self.unknownDurationReason
            }
        }

        guard !pages.isEmpty else {
            throw FouineError.extraction(nothingReason)
        }

        for field in metadata.fields {
            notes[field.label.lowercased()] = field.value
        }
        if metadata.duration > 0 {
            notes["duration"] = MediaMetadata.timestamp(metadata.duration)
        }
        return ExtractionResult(pages: pages, pageCount: max(pageCount, pages.count),
                                ocrCandidates: [], meta: notes)
    }
}
