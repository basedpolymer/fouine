// SpeechTranscriber.swift — mettre par écrit ce qui est dit, SUR CETTE MACHINE
// (SPEC §5.3, lot INT-F3). Propriété : A-Ingest.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// SECOND ÉTAGE de la famille « médias », et le seul qui coûte cher : compter
// une minute de machine par minute d'enregistrement sur un i5. D'où le réglage
// séparé (`extract.transcribe`, éteint), et d'où le plafond de durée.
//
// « SUR L'APPAREIL » N'EST PAS UN VŒU, C'EST UN DRAPEAU.
// `requiresOnDeviceRecognition = true` fait ÉCHOUER la requête plutôt que de
// l'envoyer aux serveurs d'Apple. C'est la seule façon de tenir la promesse de
// `docs/privacy.md` : sans ce drapeau, `SFSpeechRecognizer` téléverse l'audio
// dès que la reconnaissance locale n'est pas installée pour la langue demandée,
// et personne ne le verrait passer.
//
// CE QUE ÇA EXIGE DE L'UTILISATEUR, et qu'on ne peut pas contourner :
//   · la langue de DICTÉE installée (Réglages Système ▸ Clavier ▸ Dictée) —
//     sans elle, `supportsOnDeviceRecognition` est faux et on refuse par un
//     message qui nomme le geste ;
//   · l'autorisation « Reconnaissance vocale » (TCC), demandée par
//     `requestAuthorization` et déclarée par `NSSpeechRecognitionUsageDescription`
//     dans l'Info.plist du bundle.
//
// LES SEGMENTS PORTENT LEUR HORODATAGE, et c'est ce qui rend la page utile :
// « [12:40] … » dit où réécouter. Sans cela, une heure de transcription est un
// mur de texte dans lequel une citation ne se retrouve pas.

import Foundation
import AVFoundation
import Speech
import FouineCore

enum SpeechTranscriber {

    // MARK: - Refus nommés

    /// Le début INVARIABLE du refus ci-dessous, les langues variant d'une
    /// machine à l'autre : c'est lui que le cœur range en `.skipped`
    /// (`ExtractOutcome.isMediaSkip`) et que la relecture des médias reprend
    /// (`MediaExtractor.rereadSkipReasonPrefixes`, TR1).
    static let notInstalledPrefix = "speech: on-device recognition is not installed"

    /// Aucune des langues demandées n'a sa reconnaissance installée.
    /// Les langues sont interpolées dans une phrase CONSTANTE — le motif
    /// s'écrit dans `docs.err`, et l'app en recompose sa propre phrase.
    static func notInstalledReason(languages: [String]) -> String {
        notInstalledPrefix + " for "
        + languages.joined(separator: ", ")
        + " — add the language under System Settings ▸ Keyboard ▸ Dictation"
    }

    /// L'autorisation TCC « Reconnaissance vocale » manque ou a été refusée.
    static let notAuthorisedReason =
        "speech recognition not authorised — System Settings ▸ Privacy & "
        + "Security ▸ Speech Recognition"

    /// Une piste qui DURE dont la reconnaissance n'a rendu aucun caractère.
    /// C'est un ÉCHEC, pas une réussite muette : le document repart en
    /// `.failed`. Une passe ne relit que les documents `.discovered` : il est
    /// repris quand son fichier change, ou à la révision suivante de la
    /// transcription (`MediaExtractor.rereadFailedReasonSubstrings`). Texte
    /// EXACT — la carte « documents illisibles » de l'app le reconnaît au mot
    /// « speech recognition returned nothing ».
    static let emptyResultReason =
        "speech recognition returned nothing — try again"

    /// Une fenêtre dont la reconnaissance s'est TUE plus de `silenceSeconds`
    /// (BT2). Même sort que la transcription vide : `.failed`, repris par la
    /// révision suivante ou un changement du fichier — jamais une boucle. Texte
    /// EXACT : l'app le reconnaît au mot « speech recognition stopped answering ».
    static let stoppedAnsweringReason = "speech recognition stopped answering"

    /// Une fenêtre coupée par le silence fait échouer le document. L'écrire à
    /// moitié sous un document `extracted`, c'était la perdre pour toujours
    /// (13/09 : deux vidéos tronquées, que rien ne reprenait).
    static func refuseIfCut(_ end: WindowEnd?) throws {
        if end == .expired { throw FouineError.extraction(stoppedAnsweringReason) }
    }

    /// En deçà, une transcription vide n'est pas suspecte : cinq secondes de
    /// son, c'est un jingle, un bip, une notification.
    static let judgedFromSeconds: TimeInterval = 5

    /// Ce qui a empêché de transcrire. Distinct d'une `FouineError` parce que
    /// l'appelant en fait deux choses selon le contexte : un refus du document
    /// s'il n'y avait rien d'autre à indexer, une simple note dans `docs.meta`
    /// si les métadonnées, elles, sont là.
    enum Refusal: Error {
        case notInstalled(languages: [String])
        case notAuthorised

        var reason: String {
            switch self {
            case .notInstalled(let languages): return notInstalledReason(languages: languages)
            case .notAuthorised:               return notAuthorisedReason
            }
        }
    }

    // MARK: - Budgets

    /// SILENCE maximal de la reconnaissance pendant une fenêtre : elle est
    /// coupée quand elle n'a rien rendu depuis ce délai, pas au bout d'une
    /// durée fixe (BT2, 14/09/2026).
    ///
    /// MESURÉ. Un morceau d'environ 60 s de parole arrive toutes les 30 à 40 s
    /// sur un i5 au repos (245 s pour 7 min 45) ; sous une charge de 160, la
    /// reconnaissance est au moins six fois plus lente ; dans l'agent, le 13/09
    /// (processeur bridé à 41 %), un morceau toutes les 450 s. L'ancienne
    /// échéance FIXE de 1 800 s par fenêtre coupait ce travail lent mais bien
    /// vivant et perdait le reste de la fenêtre : deux vidéos du corpus sont
    /// sorties tronquées (4 min sur 7 min 45 ; 2, 5 et 3,5 min sur trois
    /// fenêtres de dix). 900 s valent deux fois le morceau le plus lent vu.
    /// `FOUINE_SPEECH_TIMEOUT` (secondes) le remplace, pour les tests.
    static var silenceSeconds: TimeInterval {
        Deadline.seconds(from: "FOUINE_SPEECH_TIMEOUT") ?? 900
    }

    /// Attente maximale de la réponse TCC. Sans borne, un processus sans
    /// interface qui déclenche la boîte d'autorisation resterait pendu à
    /// l'attendre — exactement le gel qu'`AVAssetReader` et `Subprocess`
    /// évitent chacun de leur côté.
    static let authorizationSeconds: TimeInterval = 20

    /// Longueur d'un paragraphe de transcription, en secondes. Quarante
    /// secondes font trois à quatre phrases : assez pour se lire, assez court
    /// pour que l'horodatage qui les précède reste utile.
    static let paragraphSeconds: TimeInterval = 40

    // MARK: - Disponibilité

    /// Le premier reconnaisseur, dans l'ORDRE DES LANGUES demandées, dont la
    /// reconnaissance sur l'appareil est installée.
    ///
    /// L'ordre compte : `ocr.languages` vaut « fr-FR,en-US » par défaut, et
    /// c'est le français qu'on veut sur un corpus français même si l'anglais
    /// est lui aussi installé. Aucune clé de réglage de plus — les langues des
    /// documents scannés et celles des enregistrements sont les mêmes langues.
    /// UNE FILE DÉDIÉE, ET C'EST INDISPENSABLE (mesuré, lot INT-F3).
    /// `SFSpeechRecognizer.queue` vaut la file PRINCIPALE par défaut : un
    /// appelant qui attend son résultat en bloquant son fil — ce que fait tout
    /// extracteur, dont le protocole est synchrone — n'est jamais rappelé. Le
    /// symptôme observé n'était pas une erreur mais un GEL : aucun rappel en
    /// 120 s, ni résultat ni erreur, pendant que Speech tournait à 100 % de
    /// processeur à réessayer et à journaliser. Deux voies (fichier et flux)
    /// donnaient le même gel ; la file dédiée rend les deux immédiates (1,5 s
    /// pour 1,95 s d'audio).
    static func recognizer(languages: [String]) -> SFSpeechRecognizer? {
        for code in languages {
            guard let candidate = SFSpeechRecognizer(locale: Locale(identifier: code)),
                  candidate.supportsOnDeviceRecognition,
                  candidate.isAvailable
            else { continue }
            candidate.queue = OperationQueue()
            return candidate
        }
        return nil
    }

    /// État de l'autorisation, la demandant si elle n'a jamais été tranchée.
    ///
    /// MESURÉ (lot INT-F3, machine du mainteneur) : depuis un processus SANS
    /// BUNDLE — les tests, la CLI lancée du terminal —, `authorizationStatus()`
    /// rend directement `.authorized` et `requestAuthorization` répond en
    /// quelques millisecondes SANS présenter de fenêtre : l'autorisation est
    /// celle du processus hôte (le terminal), déjà accordée. C'est le bundle
    /// signé qui obtient la boîte de dialogue, grâce à
    /// `NSSpeechRecognitionUsageDescription`. Sur une machine où elle manque,
    /// le refus est NOMMÉ plutôt que silencieux, et la carte « documents
    /// illisibles » dit quoi faire.
    static func authorization() -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        let box = StatusBox()
        let done = DispatchSemaphore(value: 0)
        SFSpeechRecognizer.requestAuthorization { status in
            box.set(status)
            done.signal()
        }
        if done.wait(timeout: .now() + authorizationSeconds) == .timedOut {
            return .notDetermined
        }
        return box.take() ?? .notDetermined
    }

    // MARK: - Transcription

    struct Segment {
        /// Début ABSOLU dans l'enregistrement, fenêtre comprise.
        let start: TimeInterval
        let text: String
    }

    /// Le verrou de la reconnaissance : un seul jeton pour tout le processus.
    /// `nonisolated(unsafe)` parce qu'un `DispatchSemaphore` est fait pour
    /// traverser les fils — c'est même sa seule raison d'être.
    nonisolated(unsafe) private static let serialisation = DispatchSemaphore(value: 1)

    /// LA RÈGLE, PURE : une transcription est-elle un échec ?
    ///
    /// Rien de compliqué et rien de plus : zéro caractère utile sur une piste
    /// d'au moins cinq secondes. La durée mesurée, elle, ne sert pas de critère
    /// — « 0,2 s pour 30 s d'audio » est le symptôme, pas la définition, et une
    /// machine rapide sur un fichier court le produirait légitimement.
    static func isEmptyFailure(characters: Int, duration: TimeInterval) -> Bool {
        characters == 0 && duration >= judgedFromSeconds
    }

    /// Caractères utiles d'une transcription rendue par fenêtre.
    static func usefulCharacters(_ pages: [String]) -> Int {
        pages.reduce(0) {
            $0 + $1.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
    }

    /// Le texte d'un média, UNE ENTRÉE PAR FENÊTRE de dix minutes.
    ///
    /// Une fenêtre muette rend une chaîne vide : la place est gardée, pour que
    /// le numéro de page corresponde toujours au même moment de
    /// l'enregistrement — page 4, c'est la vingtième à la trentième minute,
    /// que la vingtième minute ait été silencieuse ou non.
    ///
    /// UN SILENCE TROP LONG FAIT ÉCHOUER LE DOCUMENT (BT2). L'ancienne échéance
    /// fixe « ne perdait rien » : elle gardait les morceaux reçus et perdait le
    /// reste de la fenêtre, sous un document `extracted` que rien ne reprenait.
    /// Une fenêtre coupée lève désormais `stoppedAnsweringReason`.
    ///
    /// L'ARRÊT (ST1) est consulté entre deux fenêtres ET pendant une fenêtre —
    /// l'attente du résultat se fait par tranches d'une seconde plutôt qu'en
    /// un seul `wait` de trente minutes. C'est le seul extracteur dont une
    /// UNITÉ de travail dure des minutes : sans cela, « Stop » attendait la fin
    /// de la fenêtre en cours, jusqu'à dix minutes de reconnaissance.
    static func transcribe(url: URL, duration: TimeInterval,
                           languages: [String],
                           windowLength: TimeInterval = MediaDecoder.windowSeconds,
                           shouldStop: @escaping () -> Bool = { false },
                           log: ((String) -> Void)? = nil) throws -> [String] {
        guard let recognizer = recognizer(languages: languages) else {
            throw Refusal.notInstalled(languages: languages)
        }
        guard authorization() == .authorized else {
            throw Refusal.notAuthorised
        }

        // UNE SEULE RECONNAISSANCE À LA FOIS (constat C2-05, reproduit deux
        // fois). `SFSpeechRecognizer` n'en sert qu'une : à la seconde il rend un
        // résultat VIDE, sans erreur — et Fouine écrivait « transcribed …: 00:30
        // of audio, 0,2 s », une ligne de succès pour une page perdue. Le
        // réglage par défaut étant `extract.jobs = 4`, trois enregistrements sur
        // quatre d'un dossier de dictaphone y passaient en silence.
        //
        // Le reste de l'extraction (PDF, OCR, archives) garde tout son
        // parallélisme : seule cette porte-là est étroite, et elle l'était déjà
        // dans le système — on ne fait que cesser de l'ignorer.
        serialisation.wait()
        defer { serialisation.signal() }

        let started = Date()
        let silence = silenceSeconds
        let ranges = MediaDecoder.windows(duration: duration, length: windowLength)
        var pages: [String] = []
        for range in ranges {
            if shouldStop() { throw FouineError.cancelled }
            let offset = CMTimeGetSeconds(range.start)
            let heard = try? window(url: url, range: range, offset: offset,
                                    recognizer: recognizer, silence: silence,
                                    shouldStop: shouldStop)
            let segments = heard?.segments ?? []
            // APRÈS la fenêtre, et non seulement avant : une fenêtre écourtée
            // par l'arrêt rend un texte TRONQUÉ, qu'il ne faut surtout pas
            // écrire en base — le document doit repartir entier.
            if shouldStop() { throw FouineError.cancelled }
            // Le journal dit quelle fenêtre a été coupée et ce qu'elle avait
            // déjà rendu ; `docs.err`, lui, ne porte que le motif.
            if heard?.end == .expired {
                log?("speech window \(MediaMetadata.timestamp(offset)) of "
                     + "\(url.lastPathComponent): nothing heard for "
                     + "\(Int(silence)) s, cancelled after \(segments.count) segments")
            }
            try refuseIfCut(heard?.end)
            pages.append(paragraphs(segments))
        }
        log?("transcribed \(url.lastPathComponent): "
             + "\(MediaMetadata.timestamp(duration)) of audio, "
             + "\(recognizer.locale.identifier), "
             + String(format: "%.1f s", Date().timeIntervalSince(started)))
        return pages
    }

    /// UNE fenêtre : on arme la tâche, on lui verse les échantillons, on ferme,
    /// on CUMULE les morceaux jusqu'au résultat final (`TranscriptChunks`).
    ///
    /// `shouldReportPartialResults = false` : les résultats partiels
    /// n'apportent rien à un indexeur (personne ne regarde le texte apparaître)
    /// et ne sont PAS le remède aux morceaux d'une minute — mesuré le
    /// 12/09/2026 sur trois minutes de cours : mêmes trois morceaux, le texte
    /// repart de zéro après chacun, 365 rappels au lieu de 3.
    private static func window(url: URL, range: CMTimeRange, offset: TimeInterval,
                               recognizer: SFSpeechRecognizer,
                               silence: TimeInterval,
                               shouldStop: () -> Bool = { false })
        throws -> (segments: [Segment], end: WindowEnd) {
        guard let audio = try MediaDecoder.window(
                url: url, range: range, seconds: 60) else { return ([], .settled) }
        defer { audio.cancel() }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let box = ChunkBox()
        let done = DispatchSemaphore(value: 0)
        let task = recognizer.recognitionTask(with: request) { result, error in
            var settles = false
            if let result {
                settles = box.receive(.result(
                    segments: result.bestTranscription.segments.map {
                        Segment(start: offset + $0.timestamp, text: $0.substring)
                    },
                    endOfUtterance: result.speechRecognitionMetadata != nil,
                    isFinal: result.isFinal))
            }
            if error != nil {
                // « No speech detected » est une réponse, pas une panne : une
                // fenêtre de silence (générique de fin, blanc entre deux
                // interventions) ne rend rien de plus — et garde ce qui a déjà
                // été cumulé. Le rappel peut survenir APRÈS une annulation :
                // seule la première réponse délie l'attente.
                settles = box.receive(.failure) || settles
            }
            if settles { done.signal() }
        }

        // La tâche est annulée DANS TOUS LES CAS en sortant, pas seulement au
        // dépassement : une tâche abandonnée sans être annulée continue de
        // réessayer en arrière-plan, à plein processeur (mesuré).
        defer { task.cancel() }

        while let sample = audio.next() {
            if shouldStop() { break }
            request.appendAudioSampleBuffer(sample)
        }
        request.endAudio()
        // Le silence se compte à partir d'ici : verser dix minutes d'audio prend
        // quelques secondes, et ce n'est pas la reconnaissance qui se tait.
        box.heardNow()

        // Silence trop long OU arrêt demandé : la tâche est annulée en sortant
        // (`defer`), et les morceaux déjà rendus reviennent à l'appelant, qui
        // décide de leur sort.
        let end = awaitWindow(settled: done, silence: silence,
                              lastHeard: box.lastHeard, shouldStop: shouldStop)
        return (box.segments(), end)
    }

    /// Pourquoi l'attente d'une fenêtre a pris fin.
    enum WindowEnd: Equatable {
        /// La reconnaissance a répondu : résultat final, ou erreur.
        case settled
        /// L'arrêt a été demandé (ST1).
        case stopped
        /// L'échéance est tombée sans réponse.
        case expired
    }

    /// L'ATTENTE D'UNE FENÊTRE, sans Speech : elle s'éprouve avec un sémaphore
    /// que personne ne signale — une reconnaissance qui ne répond jamais (BT2).
    ///
    /// SUR LE SILENCE, PAS SUR LA DURÉE. `.expired` tombe quand `lastHeard`
    /// n'a pas bougé depuis `silence` secondes : une reconnaissance lente qui
    /// rend un morceau de temps en temps n'est jamais coupée. La fin reste
    /// garantie sans plafond : chaque morceau couvre une minute d'un audio
    /// fini, et un résultat final ou une erreur délie.
    ///
    /// PAR TRANCHES D'UNE SECONDE (ST1) : c'est ce qui rend « Stop »
    /// perceptible pendant une fenêtre de dix minutes de parole. La dernière
    /// tranche est rognée à l'échéance.
    ///
    /// CE QUE L'ÉCHÉANCE NE COUVRE PAS (BT2, mesuré le 14/09/2026) : la
    /// construction du reconnaisseur, `recognitionTask(with:)`, le versement des
    /// échantillons, `cancel()`. Tous rendent la main en quelques
    /// millisecondes, trois processus concurrents compris ; le premier
    /// `supportsOnDeviceRecognition` coûte 100 à 130 ms. Le gel de
    /// `make ci-unit` du 14/09 venait de `say`, pas d'ici.
    static func awaitWindow(settled: DispatchSemaphore, silence: TimeInterval,
                            lastHeard: () -> Date,
                            shouldStop: () -> Bool,
                            tick: TimeInterval = 1.0) -> WindowEnd {
        while true {
            let remaining = silence - Date().timeIntervalSince(lastHeard())
            guard remaining > 0 else { return .expired }
            if shouldStop() { return .stopped }
            if settled.wait(timeout: .now() + min(tick, remaining)) == .success {
                return .settled
            }
        }
    }

    /// Les segments en paragraphes horodatés. Un paragraphe se ferme dès qu'il
    /// couvre `paragraphSeconds` : c'est une coupe RÉGULIÈRE et non
    /// grammaticale, parce que la reconnaissance ne rend pas de paragraphes et
    /// qu'une coupe à la ponctuation donnerait des blocs d'une ligne.
    static func paragraphs(_ segments: [Segment],
                           every span: TimeInterval = paragraphSeconds) -> String {
        guard !segments.isEmpty else { return "" }
        var blocks: [String] = []
        var words: [String] = []
        var blockStart = segments[0].start
        for segment in segments {
            if !words.isEmpty, segment.start - blockStart >= span {
                blocks.append("[\(MediaMetadata.timestamp(blockStart))] "
                              + words.joined(separator: " "))
                words = []
                blockStart = segment.start
            }
            let word = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty { words.append(word) }
        }
        if !words.isEmpty {
            blocks.append("[\(MediaMetadata.timestamp(blockStart))] "
                          + words.joined(separator: " "))
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Boîtes de traversée de fil

    private final class StatusBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var stored: SFSpeechRecognizerAuthorizationStatus?
        func set(_ value: SFSpeechRecognizerAuthorizationStatus) {
            mutex.lock(); stored = value; mutex.unlock()
        }
        func take() -> SFSpeechRecognizerAuthorizationStatus? {
            mutex.lock(); defer { mutex.unlock() }; return stored
        }
    }

    /// Le cumul, traversé par les rappels de Speech (sa file) et lu par
    /// l'appelant qui attend (le fil d'extraction).
    private final class ChunkBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var chunks = TranscriptChunks()
        /// Le dernier signe de vie de la reconnaissance : tout rappel, morceau
        /// retenu ou non. C'est lui que mesure le silence de `awaitWindow`.
        private var heard = Date()
        /// Rend `true` si ce rappel est la PREMIÈRE réponse qui délie l'attente.
        /// Un second `signal()` sur un sémaphore déjà consommé libérerait une
        /// attente qui n'a pas eu lieu.
        func receive(_ event: TranscriptChunks.Event) -> Bool {
            mutex.lock(); defer { mutex.unlock() }
            heard = Date()
            return chunks.receive(event)
        }
        func heardNow() {
            mutex.lock(); heard = Date(); mutex.unlock()
        }
        func lastHeard() -> Date {
            mutex.lock(); defer { mutex.unlock() }; return heard
        }
        func segments() -> [Segment] {
            mutex.lock(); defer { mutex.unlock() }; return chunks.segments
        }
    }
}

/// LA RÈGLE DE CUMUL d'une fenêtre, PURE — elle s'éprouve sans Speech (TR1).
///
/// MESURÉ LE 12/09/2026 (macOS 15.7.9). Alimentée en flux
/// (`SFSpeechAudioBufferRecognitionRequest`), la reconnaissance sur l'appareil
/// rend la parole en MORCEAUX d'environ 60 s. Chacun arrive comme un résultat
/// `isFinal == false` qui porte `speechRecognitionMetadata` (la fin d'un
/// énoncé) ; les morceaux se suivent sans chevauchement, horodatés depuis le
/// début de la requête, et seul le DERNIER est `isFinal`. Sur 0–180 s d'un
/// cours : 635, 753 puis 722 caractères. Ne retenir que `isFinal` en gardait
/// 722 sur 2 110 — la dernière minute de chaque fenêtre de dix, et une passe
/// qui annonçait une réussite.
struct TranscriptChunks {

    /// Ce qu'apporte un rappel de la reconnaissance.
    enum Event {
        /// Ses segments (début ABSOLU), s'il clôt un énoncé
        /// (`speechRecognitionMetadata != nil`), s'il est final.
        case result(segments: [SpeechTranscriber.Segment],
                    endOfUtterance: Bool, isFinal: Bool)
        /// Une erreur, « No speech detected » compris.
        case failure
    }

    private(set) var segments: [SpeechTranscriber.Segment] = []
    /// Vrai dès la réponse qui délie l'attente. Rien ne s'ajoute ensuite : la
    /// tâche peut encore rappeler après son annulation.
    private(set) var isSettled = false

    /// Intègre un rappel ; rend `true` s'il délie l'attente, une fois au plus.
    ///
    /// Un résultat est RETENU s'il est final OU clôt un énoncé. `isFinal`
    /// délie. Une erreur délie aussi, en GARDANT le cumul : un « No speech
    /// detected » sur le silence de fin de fenêtre n'efface pas les minutes
    /// d'avant.
    mutating func receive(_ event: Event) -> Bool {
        guard !isSettled else { return false }
        switch event {
        case .failure:
            isSettled = true
        case .result(let incoming, let endOfUtterance, let isFinal):
            if isFinal || endOfUtterance { append(incoming) }
            isSettled = isFinal
        }
        return isSettled
    }

    /// Les doublons se traitent au niveau du MORCEAU : d'un résultat retenu, on
    /// ne garde que les segments qui commencent après le début du dernier
    /// segment déjà cumulé. Un final qui répéterait le dernier morceau
    /// n'ajoute donc rien ; à l'intérieur d'un morceau, tous les segments
    /// passent, même à horodatage égal.
    private mutating func append(_ incoming: [SpeechTranscriber.Segment]) {
        guard let lastStart = segments.last?.start else {
            segments = incoming
            return
        }
        segments += incoming.filter { $0.start > lastStart }
    }
}
