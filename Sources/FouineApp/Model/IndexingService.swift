// IndexingService.swift — l'adaptateur app d'`IndexPass` (SPEC §5.6).
// Propriété : A-App.
//
// La boucle d'indexation vivait ici, transcrite de la CLI. Elle en avait dérivé
// sur cinq points (audit F2), tous corrigés par le passage à `FouineIndex` :
//   · un seul `catch` : un volume débranché marquait CHAQUE document `.failed` ;
//   · pas d'`upsertDoc` post-extraction — `docs.n_pages` restait à 0 ;
//   · pas de budget ;
//   · `fouine.lock` gardé jusqu'à la fermeture de la fenêtre (audit F3) ;
//   · la priorité de file décidée sur l'étiquette « Livres » (audit F4).
//
// Ce qui reste ici, et qui est le propre de l'app : `IndexingState`, sa
// publication estampillée, et la pompe OCR avec sa sonde de progression.
//
// Trois corrections de l'audit du 01/09/2026 sont toujours tenues ici :
//   · A10.1 — tout état publié porte un numéro de série ; le récepteur écarte
//     ce qui est plus ancien que ce qu'il a déjà appliqué ;
//   · A10.2 — « Annuler » interrompt réellement la pompe OCR ;
//   · TOP 5 n°4 — `only:` remonte jusqu'à l'interface (« OCRiser ce document
//     d'abord »).

import Foundation
import FouineCore
import FouineEmbed
import FouineIndex
import FouineLicense
import FouineOCR

struct IndexingState: Sendable, Equatable {
    var running = false
    /// Ce que la passe fait (mise à jour, lecture des pages scannées,
    /// préparation de la recherche par le sens) : la carte « Index » et la
    /// barre des menus le nomment sans relire la phrase.
    var activity: IndexActivity = .updating
    var phase = ""
    var done = 0
    var total = 0
    var extracted = 0
    var failed = 0
    var skipped = 0
    var pages = 0
    var queued = 0
    var summary: String?
    var error: String?
    var cancelled = false
    /// Numéro de série, croissant sur tout le processus (audit A10.1). Voir
    /// `stamped()` et `AppModel.apply(_:)`.
    private(set) var seq = 0

    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    /// Estampille l'état avant publication.
    ///
    /// La sonde de progression de l'OCR vit sur un fil indépendant et ne s'arrête
    /// qu'à sa prochaine itération ; côté réception, chaque publication devient un
    /// `Task { @MainActor }` NON ordonné. Sans numéro de série, une publication
    /// retardataire réinstalle `running = true` APRÈS l'état terminal : feuille
    /// infermable, boutons d'indexation morts à vie (audit A10.1).
    ///
    /// Le compteur est global au processus, pas propre à un `IndexingService` :
    /// une publication attardée d'une exécution précédente ne peut pas non plus
    /// écraser l'état d'une nouvelle.
    func stamped() -> IndexingState {
        var copy = self
        copy.seq = StateSequence.shared.next()
        return copy
    }
}

/// Compteur monotone des états publiés (audit A10.1).
private final class StateSequence: @unchecked Sendable {
    static let shared = StateSequence()
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

final class IndexingService: @unchecked Sendable {

    private let store: GRDBStore
    private let lock = NSLock()
    private var cancelled = false
    /// L'observateur de la passe en cours, s'il y en a une (ST1) : « Stop » doit
    /// pouvoir lui faire publier TOUT DE SUITE ce qu'on attend, sans attendre le
    /// prochain document terminé.
    private weak var sink: Sink?

    init(store: GRDBStore) { self.store = store }

    // MARK: - La garde d'essai (lot L1C)

    /// L'index a-t-il le droit de se mettre à jour ?
    ///
    /// Relu à chaque passe, comme les réglages, et pour la même raison : une
    /// clé activée dans la fenêtre de réglages doit rendre la mise à jour
    /// possible sans redémarrer l'application. Le fichier suit la base
    /// (`FOUINE_DB` l'emmène sur une copie jetable dans les tests).
    private func licenceAllowsIndexing() -> Bool {
        let databaseURL = store.databaseURL ?? AppPaths.databaseURL()
        let url = LicenseStore.fileURL(databaseURL: databaseURL)
        return LicenseState.compute(file: LicenseStore.load(at: url)).allowsIndexing
    }

    /// L'état terminal d'un refus. UN ÉTAT PUBLIÉ, PAS UNE ALERTE : les trois
    /// pompes sont appelées par la carte « Index », par la fenêtre « Votre
    /// index » et par la feuille d'indexation, et une alerte modale surgissant
    /// d'une pompe de fond serait au mieux surprenante. La carte dit déjà la
    /// chose, avec les deux gestes.
    private func trialOverState(activity: IndexActivity) -> IndexingState {
        var state = IndexingState(running: false, activity: activity, phase: "")
        // La MÊME phrase que la carte « Index » et l'onglet des réglages : trois
        // formulations de la même chose, c'est trois occasions de se contredire.
        state.summary = LicenseStatusText.headline(.trialOver)
        return state.stamped()
    }

    /// Les réglages, relus au démarrage de CHAQUE passe (audit U2).
    ///
    /// La concurrence d'extraction était un `private let jobs = 4` : le même
    /// littéral que la CLI, et aucun moyen de le baisser sur une machine qui
    /// swappe. Elle vient maintenant d'`extract.jobs`, que la fenêtre de
    /// réglages écrit. Une lecture par passe, pas par document.
    private func settings() -> SettingsSnapshot {
        let (snapshot, warning) = SettingsSnapshot.load(from: store)
        if let warning { NSLog("%@", warning) }
        return snapshot
    }

    /// La phrase d'attente d'un arrêt (ST1). Un seul document en vol : on le
    /// NOMME — c'est lui qu'on attend, et le dire est tout l'objet du lot.
    /// Plusieurs : leur nombre, parce que quatre noms de fichier ne tiennent pas
    /// sous une carte de 230 points. Aucun : il n'y a rien à nommer, l'arrêt est
    /// imminent, on garde la phrase du clic.
    ///
    /// PURE et à part de l'observateur : une phrase ne se vérifie pas à l'écran.
    static func stoppingPhrase(_ inFlight: [String]) -> String {
        switch inFlight.count {
        case 0:  return String(localized: "cancelling…")
        case 1:  return String(localized: "Stopping — finishing “\(inFlight[0])”…")
        default: return String(localized: "Stopping — \(inFlight.count) document(s) are finishing…")
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let observer = sink; lock.unlock()
        // HORS DU VERROU : l'observateur publie, donc saute vers le fil
        // principal. Le tenir pendant ce trajet ferait attendre le prochain
        // document terminé, c'est-à-dire exactement ce qu'on veut abréger.
        observer?.stopRequested()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    /// Publie un état en l'estampillant (audit A10.1). Toute sortie vers
    /// l'interface passe par ici ou par `stamped()` : un état non estampillé
    /// serait ignoré par le récepteur.
    private func publish(_ state: inout IndexingState,
                         _ progress: @Sendable (IndexingState) -> Void) {
        state = state.stamped()
        progress(state)
    }

    // MARK: - Crawl delta + extraction

    /// - Parameter budgetMinutes: arrêt propre après M minutes, comme
    ///   `fouine index --budget-minutes` (audit F2 : l'app n'en avait pas).
    ///   Aucune commande d'interface ne le renseigne encore ; le paramètre
    ///   existe pour que la fenêtre de réglages n'ait qu'à le passer.
    func run(budgetMinutes: Int? = nil,
             progress: @escaping @Sendable (IndexingState) -> Void)
        async -> IndexingState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: IndexingState().stamped())
                    return
                }
                continuation.resume(
                    returning: self.runSync(budgetMinutes: budgetMinutes,
                                            progress: progress))
            }
        }
    }

    private func runSync(budgetMinutes: Int?,
                         progress: @escaping @Sendable (IndexingState) -> Void)
        -> IndexingState {
        guard licenceAllowsIndexing() else { return trialOverState(activity: .updating) }
        let sink = Sink(progress: progress)
        lock.lock(); self.sink = sink; lock.unlock()
        // Un « Stop » arrivé AVANT que l'observateur ne soit enregistré serait
        // muet : on rejoue la demande ici, où elle ne peut plus se perdre.
        if isCancelled { sink.stopRequested() }
        do {
            let roots = try store.roots().filter(\.enabled)
            guard !roots.isEmpty else { return sink.noRoots() }
            let summary = try IndexPass(
                store: store, observer: sink,
                shouldStop: { [weak self] in self?.isCancelled ?? true })
                .run(roots: roots,
                     options: IndexPassOptions(
                        crawl: .delta, jobs: settings().extractJobs,
                        budget: .minutes(budgetMinutes),
                        // §5.6, « ne jamais planter » : une racine illisible
                        // (TCC, dossier disparu) n'arrête pas les autres.
                        continueAfterRootFailure: true, role: .app))
            return sink.done(summary, cancelled: isCancelled)
        } catch {
            // Erreur FATALE : volume démonté, panne de base, verrou tenu par
            // l'agent. La passe s'est arrêtée, elle n'a marqué aucun document
            // en échec pour une cause qui ne le concernait pas (audit F2).
            return sink.failed(ErrorText.describe(error))
        }
    }

    /// Traduit les événements de la passe en `IndexingState` publiés.
    ///
    /// `IndexPass` sérialise ses appels : cet objet n'a pas à se verrouiller
    /// contre lui-même, seulement à survivre au saut de fil.
    ///
    /// VERROUILLÉ DEPUIS ST1, et pour une seule raison : « Stop » publie
    /// maintenant lui aussi, depuis le fil de l'interface, pendant que la passe
    /// continue d'émettre. Les événements, eux, restent sérialisés entre eux
    /// par `IndexPass` ; le verrou ne protège que du geste de l'utilisateur.
    private final class Sink: IndexPassObserver, @unchecked Sendable {
        private let progress: @Sendable (IndexingState) -> Void
        private let mutex = NSLock()
        private var state = IndexingState(
            running: true, phase: String(localized: "walking the folders…"))
        /// Les documents dont la lecture est EN COURS, dans l'ordre où elle a
        /// commencé — un par fil d'extraction. C'est ce qu'on attend quand on
        /// demande l'arrêt, et donc ce que la phrase doit nommer.
        private var inFlight: [String] = []
        /// L'arrêt a été demandé : toute publication le dit, jusqu'au bilan.
        private var stopping = false
        /// Racines sautées et lignes de journal (verrou périmé repris,
        /// troncature de `--jobs`) : dédoublonnées et bornées.
        private let notes = ErrorSink()

        init(progress: @escaping @Sendable (IndexingState) -> Void) {
            self.progress = progress
            publish()
        }

        /// Mute l'état sous le verrou, puis publie HORS du verrou : la
        /// publication saute vers le fil principal, elle n'a pas à retenir
        /// l'observateur.
        private func publish(_ mutate: (inout IndexingState) -> Void = { _ in }) {
            mutex.lock()
            mutate(&state)
            // L'arrêt écrase la phrase de TOUTE publication qui le suit : une
            // progression arrivée entre-temps redirait « extraction de 1 200
            // documents… » alors que l'utilisateur vient de cliquer « Stop ».
            if stopping {
                state.cancelled = true
                state.phase = IndexingService.stoppingPhrase(inFlight)
            }
            state = state.stamped()
            let snapshot = state
            mutex.unlock()
            progress(snapshot)
        }

        /// « Stop » vient d'être cliqué (ST1). La phrase NOMME ce qu'on attend :
        /// sans elle, la carte disait « annulation… » pendant qu'une vidéo
        /// finissait de se transcrire, et rien ne disait pourquoi c'était long.
        func stopRequested() {
            mutex.lock(); stopping = true; mutex.unlock()
            publish()
        }

        func indexPass(_ event: IndexPassEvent) {
            switch event {
            case .willCrawl(let root):
                publish { $0.phase = String(localized: "walking “\(root)”…") }
            case .rootFailed(let root, let message):
                notes.note(String(localized: "“\(root)”: \(message)"))
            case .note(let message):
                notes.note(message)
            case .extractionWillStart(let total):
                publish {
                    $0.total = total
                    $0.phase = total == 0
                        ? String(localized: "nothing new to extract")
                        : String(localized: "extracting \(total) document(s)…")
                }
            case .willExtract(let document):
                // AUCUNE PUBLICATION tant qu'on ne s'arrête pas : une racine de
                // petits `.txt` rend des milliers de documents en quelques
                // secondes, et chaque publication coûte un saut vers le fil
                // principal. La progression, elle, est déjà cadencée.
                mutex.lock()
                inFlight.append(document)
                let announce = stopping
                mutex.unlock()
                if announce { publish() }
            case .abandoned(let document):
                remove(document)
            case .progress(let counters):
                publish { Self.apply(counters, to: &$0) }
            case .willConsolidate:
                publish { $0.phase = String(localized: "consolidating the index…") }
            case .document(let outcome):
                remove((outcome.relPath as NSString).lastPathComponent)
            case .finished(let summary):
                // Le bilan arrive AUSSI sur erreur fatale : les compteurs de
                // `failed()` doivent être ceux d'avant l'arrêt.
                mutex.lock(); Self.apply(summary.counters, to: &state); mutex.unlock()
            case .crawled:
                break
            }
        }

        /// Un document n'est plus en vol. La phrase d'arrêt se refait alors —
        /// « 4 documents se terminent… » doit devenir « “cours.mp4” se
        /// termine… » à mesure que les autres rendent la main.
        private func remove(_ document: String) {
            mutex.lock()
            if let index = inFlight.firstIndex(of: document) {
                inFlight.remove(at: index)
            }
            let announce = stopping
            mutex.unlock()
            if announce { publish() }
        }

        private static func apply(_ c: IndexCounters, to state: inout IndexingState) {
            state.total = c.total
            state.done = c.done
            state.extracted = c.extracted
            state.failed = c.failed
            state.skipped = c.skipped
            state.pages = c.pages
            state.queued = c.queued
        }

        // MARK: - États terminaux

        /// Les trois sorties ci-dessous sont rendues à l'appelant, pas publiées :
        /// elles prennent quand même le verrou, parce qu'un « Stop » tardif peut
        /// encore arriver du fil de l'interface pendant qu'elles s'écrivent.
        func noRoots() -> IndexingState {
            mutex.lock(); defer { mutex.unlock() }
            state.running = false
            state.summary = String(localized: "no active folder")
            return state.stamped()
        }

        func failed(_ message: String) -> IndexingState {
            mutex.lock(); defer { mutex.unlock() }
            state.running = false
            state.phase = String(localized: "failed")
            state.error = ([message] + notes.all()).joined(separator: " · ")
            return state.stamped()
        }

        func done(_ summary: IndexPassSummary, cancelled: Bool) -> IndexingState {
            mutex.lock(); defer { mutex.unlock() }
            state.running = false
            state.cancelled = cancelled || summary.stop == .cancelled
            var parts = [
                String(localized: "\(state.extracted) document(s) extracted"),
                String(localized: "\(state.pages) page(s)"),
            ]
            if state.queued > 0 {
                parts.append(String(localized: "\(state.queued) scanned page(s) to read"))
            }
            if state.skipped > 0 {
                parts.append(String(localized: "\(state.skipped) skipped"))
            }
            if state.failed > 0 {
                parts.append(String(localized: "\(state.failed) failure(s)"))
            }
            var prefix = state.cancelled ? String(localized: "Cancelled — ") : ""
            if summary.stop == .budgetExhausted {
                prefix = String(localized: "Time is up (\(summary.counters.budgetSkipped) document(s) left) — ")
            }
            state.summary = prefix + parts.joined(separator: " · ")
            let reported = notes.all()
            if !reported.isEmpty { state.error = reported.joined(separator: " · ") }
            state.phase = String(localized: "finished")
            return state.stamped()
        }
    }

    // MARK: - OCR (§6)

    /// Pompe OCR, avec trois ajouts de l'audit du 01/09 :
    ///
    ///   · `only:` cible UN document (TOP 5 n°4). Le moteur savait déjà le faire
    ///     (`OCRRun.run(only:)`, §6.3) ; l'app passait `nil` en dur, et la file —
    ///     41,5 h, priorités dégénérées — n'était donc consommée que dans l'ordre
    ///     des `doc_id`. `label:` n'est là que pour les libellés d'interface.
    ///   · l'annulation est RÉELLE (A10.2) : `shouldStop` est consulté par la
    ///     pompe entre deux pages. Les pages en vol se terminent, la file reste
    ///     INTACTE — même sortie propre que le budget du §6.3, base cohérente.
    ///   · le verrou d'écriture est RENDU en fin de passe (F3) : `OCRPass` le
    ///     prend en se nommant et le rend en `defer`. L'app le confisquait
    ///     jusqu'à sa fermeture, ce qui condamnait l'agent au message « arrêtez
    ///     l'indexation en cours » alors que personne n'indexait.
    ///
    /// La progression est toujours lue en interrogeant la longueur de file.
    func runOCR(budgetMinutes: Int?, only: String? = nil, label: String? = nil,
                progress: @escaping @Sendable (IndexingState) -> Void) async -> IndexingState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: IndexingState().stamped())
                    return
                }
                continuation.resume(
                    returning: self.runOCRSync(budgetMinutes: budgetMinutes,
                                               only: only, label: label,
                                               progress: progress))
            }
        }
    }

    private func runOCRSync(budgetMinutes: Int?, only: String?, label: String?,
                            progress: @escaping @Sendable (IndexingState) -> Void)
        -> IndexingState {
        guard licenceAllowsIndexing() else {
            return trialOverState(activity: .readingScans)
        }
        let scoped = !(only ?? "").isEmpty
        let target = label ?? String(localized: "this document")
        var state = IndexingState(
            running: true,
            activity: .readingScans,
            phase: scoped
                ? String(localized: "getting ready to read “\(target)” (about 8 s)…")
                : String(localized: "getting ready (about 8 s)…"))
        // `nil` = la base n'a pas répondu. Ce n'est PAS « 0 page » (audit A10.7).
        let initial = queueLength()
        // Un run ciblé ne traite que quelques dizaines de pages : mesurer sa
        // progression sur la file entière (34 000 pages) donnerait une barre figée
        // à 0 %. Total nul = progression indéterminée (cf. `IndexingSheet`).
        state.total = scoped ? 0 : (initial ?? 0)
        publish(&state, progress)

        // Sonde de progression : la pompe ne rapporte rien à l'appelant, mais la
        // file rétrécit page par page (une transaction par page, §6.3).
        //
        // Le fil est RÉVEILLÉ (`wake`) puis JOINT (`probe.wait()`) avant que l'état
        // terminal ne soit construit : plus aucune publication ne part après lui
        // (audit A10.1, ceinture ; le numéro de série est la bretelle).
        let stop = Flag()
        let wake = DispatchSemaphore(value: 0)
        let probe = DispatchGroup()
        let store = self.store
        let total = state.total
        probe.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { probe.leave() }
            while !stop.value {
                // `ocrQueueLength()` et non `stats()` (audit C2-03) : ce fil
                // tourne UNE FOIS PAR SECONDE pendant toute la passe d'OCR, et
                // `stats()` balayait `page_fts` — 1,1 Gio, 16 à 45 s — pour
                // lire ce seul nombre. La barre de progression bougeait au
                // mieux toutes les 45 s, et l'OCR partageait le disque avec ce
                // balayage continu. Le compte propre coûte des microsecondes
                // (`ocr_queue` est une table WITHOUT ROWID).
                let remaining = try? store.ocrQueueLength()
                var s = IndexingState(running: true, activity: .readingScans, phase: "")
                s.total = total
                if let remaining, let initial {
                    s.done = max(0, initial - remaining)
                    s.queued = remaining
                }
                s.cancelled = self?.isCancelled ?? false
                s.phase = s.cancelled
                    ? String(localized: "cancelling — the current page is finishing…")
                    : (remaining.map { r in
                        scoped
                            ? String(localized: "\(r) page(s) of “\(target)” left to read")
                            : String(localized: "\(r) page(s) left to read")
                    // Sans compte, on le DIT : « 0 page restante » ferait passer
                    // une base muette pour un OCR fini (audit A10.7).
                    } ?? String(localized: "progress unavailable (the database did not answer)"))
                progress(s.stamped())
                _ = wake.wait(timeout: .now() + 1.0)
            }
        }

        var outcome: OCRRunOutcome = .completed
        var failure: String?
        do {
            // `jobs` vient d'`ocr.jobs` ; les LANGUES, elles, ne sont pas
            // passées ici : `OCRRun` lit `ocr.languages` lui-même quand
            // l'appelant ne dit rien, et les filtre sur ce que Vision sait
            // faire (audit X2). Une seule source, pour les trois exécutables.
            outcome = try OCRPass.run(store: store, role: .app,
                                      jobs: settings().ocrJobs,
                                      budgetMinutes: budgetMinutes,
                                      only: only,
                                      shouldStop: { [weak self] in
                                          // Service disparu = plus personne pour
                                          // afficher le résultat : on s'arrête.
                                          self?.isCancelled ?? true
                                      })
        } catch {
            failure = ErrorText.describe(error)
        }
        stop.value = true
        wake.signal()
        probe.wait()

        let remaining = queueLength()
        let cancelled = isCancelled
        // Les compteurs de fin ne sont sincères que si les DEUX lectures de
        // `stats()` ont abouti (audit A10.7).
        let countsKnown = initial != nil && remaining != nil
        state.running = false
        state.cancelled = cancelled
        state.queued = remaining ?? 0
        if let initial, let remaining { state.done = max(0, initial - remaining) }
        state.phase = cancelled ? String(localized: "cancelled")
                                : String(localized: "finished")
        state.error = countsKnown
            ? failure
            : [failure,
               String(localized: "The pages left to read could not be counted (the database did not answer).")]
                .compactMap { $0 }.joined(separator: " · ")
        state.summary = Self.ocrSummary(failure: failure, cancelled: cancelled,
                                        outcome: outcome, scoped: scoped,
                                        target: target, done: state.done,
                                        remaining: remaining ?? 0,
                                        countsKnown: countsKnown)
        return state.stamped()
    }

    /// Le résumé de fin d'OCR. Une annulation ressort de la pompe comme un budget
    /// épuisé (même mécanisme, §6.3) : c'est l'app, qui sait ce qu'elle a demandé,
    /// qui tranche entre les deux.
    private static func ocrSummary(failure: String?, cancelled: Bool,
                                   outcome: OCRRunOutcome, scoped: Bool,
                                   target: String, done: Int,
                                   remaining: Int, countsKnown: Bool) -> String {
        if failure != nil { return String(localized: "Reading the scanned pages was interrupted.") }
        if !countsKnown {
            // DEUX phrases entières plutôt qu'un début interpolé (HU1) : la
            // forme « \(head) — précision » obligeait à lire un titre collé à
            // une explication, et la traduction héritait de l'ordre anglais.
            return cancelled
                ? String(localized: "Reading stopped. The pages left could not be counted (the database did not answer). Nothing is lost, starting again picks up here.")
                : String(localized: "Reading finished. The pages left could not be counted (the database did not answer). Nothing is lost, starting again picks up here.")
        }
        if cancelled {
            return String(localized: "Reading stopped: \(done) scanned page(s) read. Nothing is lost, starting again picks up here.")
        }
        if outcome == .budgetExhausted {
            return String(localized: "Time is up: \(remaining) scanned page(s) still to read. Starting again picks up here.")
        }
        if scoped {
            return done > 0
                ? String(localized: "Reading “\(target)” finished: \(done) scanned page(s) read.")
                : String(localized: "Nothing to do: no page of “\(target)” was waiting to be read.")
        }
        return String(localized: "Reading finished: \(done) scanned page(s) read.")
    }

    // MARK: - Préparation de la recherche par le sens (§12, UX-12)

    /// La pompe d'embedding, dans l'application — le pendant de `runOCR`.
    ///
    /// C'ÉTAIT LA DERNIÈRE DÉPENDANCE AU TERMINAL. L'onglet « Recherche par le
    /// sens » demandait de copier `fouine embed`, d'ouvrir Terminal, de coller
    /// et d'appuyer sur Entrée — pour un public qui, par définition, ne sait
    /// pas ce qu'est une ligne de commande. Le moteur, lui, était déjà prêt :
    /// `EmbedRun.run` est budgété, reprenable et annulable exactement comme
    /// `OCRPass.run`. Il n'y avait qu'à l'appeler d'ici.
    ///
    /// Trois choses sont copiées de `runOCR`, et pour les mêmes raisons :
    ///   · le moteur est chargé HORS du fil principal (`E5Encoder` : ~1,1 s
    ///     avec le cache de vocabulaire, ~8,8 s sans) ;
    ///   · l'annulation est RÉELLE — `shouldStop` est consulté entre deux lots,
    ///     le tampon en vol est écrit, la reprise est gratuite ;
    ///   · la progression est lue par une SONDE, parce que la pompe ne rapporte
    ///     rien à son appelant.
    ///
    /// LE MOTEUR N'EST PAS PARTAGÉ AVEC `SemanticService`. Celui-ci le charge
    /// paresseusement sur SA file série, derrière un `private var` qu'il ne
    /// publie pas ; le lui arracher demanderait de rendre son chargement
    /// public et de le sérialiser avec la recherche — c'est-à-dire de faire
    /// attendre une recherche derrière une campagne de vingt heures. Deux
    /// instances coûtent ~90 Mio de plus pendant la passe, et seulement
    /// pendant elle : la nôtre meurt avec la passe.
    func runEmbed(budgetMinutes: Int?,
                  progress: @escaping @Sendable (IndexingState) -> Void)
        async -> IndexingState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: IndexingState().stamped())
                    return
                }
                continuation.resume(
                    returning: self.runEmbedSync(budgetMinutes: budgetMinutes,
                                                 progress: progress))
            }
        }
    }

    private func runEmbedSync(budgetMinutes: Int?,
                              progress: @escaping @Sendable (IndexingState) -> Void)
        -> IndexingState {
        guard licenceAllowsIndexing() else {
            return trialOverState(activity: .preparingMeaning)
        }
        var state = IndexingState(
            running: true, activity: .preparingMeaning,
            phase: String(localized: "Preparing search by meaning — getting ready…"))

        // UNE SEULE PRÉPARATION À LA FOIS (constat C2-11). Le verrou d'écriture
        // ne peut pas le garantir — la pompe le rend après chaque lot, exprès —
        // et deux campagnes sur la même base refont exactement le même travail :
        // le double de chaleur et de batterie pour zéro page de plus. Le cas
        // réel est à un clic : ce bouton pendant qu'un terminal tourne.
        var campaign: EmbedCampaignLock?
        if let databaseURL = store.databaseURL {
            do {
                campaign = try EmbedCampaignLock.acquire(databaseURL: databaseURL)
            } catch is EmbedCampaignLock.Busy {
                state.running = false
                state.phase = String(localized: "failed")
                state.error = String(localized: "Fouine is already preparing the meaning of your documents, in another window or in Terminal. Wait for that work to finish.")
                state.summary = String(localized: "Search by meaning could not be prepared.")
                return state.stamped()
            } catch {
                // Verrou impossible à ouvrir : on n'empêche pas une préparation
                // pour un fichier d'annotation (même règle que la CLI).
                NSLog("%@", "embed campaign lock: \(error)")
            }
        }
        defer { campaign?.release() }

        // Le reste-à-faire AVANT la première inférence. `nil` = la base n'a pas
        // répondu, ce qui n'est PAS « 0 page » (audit A10.7).
        let start = Self.readiness(store)
        state.total = start.map(\.left) ?? 0
        publish(&state, progress)

        let engine: E5Encoder
        do {
            engine = try E5Encoder(modelDir: EmbedPaths.modelDirectory())
        } catch {
            state.running = false
            state.phase = String(localized: "failed")
            state.error = ErrorText.describe(error)
            state.summary = String(localized: "Search by meaning could not be prepared.")
            return state.stamped()
        }

        // Sonde de progression. La pompe écrit ses lots au fil de l'eau : le
        // nombre de pages COMPLÈTES est donc ce qui avance, et c'est le compte
        // le moins cher qui le dise — mesuré sur une copie de la base de
        // production (396 659 pages indexées, 72 177 fenêtres) :
        // `completeVectorPageCount()` 23 ms, l'ensemble des comptes de
        // `stats()` 109 ms, et l'écart ne fera que croître (`stats()` balaie
        // aussi `docs`, `page_src` et `ocr_queue`, qui n'ont rien à voir ici).
        // Cinq secondes entre deux sondes, et non une comme l'OCR : un lot
        // d'embedding vaut ~4,8 s, sonder plus vite n'apprendrait rien.
        let stop = Flag()
        let wake = DispatchSemaphore(value: 0)
        let probe = DispatchGroup()
        let store = self.store
        let total = state.total
        probe.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { probe.leave() }
            while !stop.value {
                let left = Self.pagesLeft(store, indexed: start?.indexed)
                var s = IndexingState(running: true, activity: .preparingMeaning,
                                      phase: "")
                s.total = total
                if let left, let start { s.done = max(0, start.left - left) }
                s.cancelled = self?.isCancelled ?? false
                s.phase = s.cancelled
                    ? String(localized: "stopping — the current batch is finishing…")
                    : (left.map { n in
                        String(localized: "\(n) page(s) left to prepare")
                    // Sans compte, on le DIT (audit A10.7).
                    } ?? String(localized: "progress unavailable (the database did not answer)"))
                progress(s.stamped())
                _ = wake.wait(timeout: .now() + 5.0)
            }
        }

        // Le journal de la pompe est celui d'un DÉPANNEUR : il nomme le
        // back-end de calcul, le pid, les balayages. Il part donc dans les
        // journaux du système, jamais dans la feuille. Ce que l'utilisateur
        // doit savoir, lui, tient en une phrase : un autre programme écrit
        // dans l'index, Fouine attend. `ErrorSink` la dédoublonne — la pompe
        // la répéterait toutes les dix secondes pendant un lot d'OCR de
        // l'agent.
        let notes = ErrorSink()
        var config = EmbedRun.Config()
        config.budgetMinutes = budgetMinutes.map(Double.init)
        config.log = { line in
            NSLog("%@", line)
            if line.contains("lock is held") || line.contains("waiting for a lock window") {
                notes.note(String(localized: "The index is being updated by another program. Fouine is waiting for it to finish."))
            }
        }

        var summary: EmbedRun.Summary?
        var failure: String?
        do {
            summary = try EmbedRun.run(
                store: store, engine: engine, config: config,
                shouldStop: { [weak self] in
                    // Service disparu = plus personne pour afficher le
                    // résultat : on s'arrête (même règle que l'OCR).
                    self?.isCancelled ?? true
                })
        } catch {
            failure = ErrorText.describe(error)
        }
        stop.value = true
        wake.signal()
        probe.wait()

        let cancelled = isCancelled
        let left = summary?.remaining ?? Self.pagesLeft(store, indexed: start?.indexed)
        state.running = false
        state.cancelled = cancelled
        if let start, let left { state.done = max(0, start.left - left) }
        state.phase = cancelled ? String(localized: "cancelled")
                                : String(localized: "finished")
        state.error = notes.all().isEmpty
            ? failure
            : ([failure] + notes.all()).compactMap { $0 }.joined(separator: " · ")
        state.summary = Self.embedSummary(
            failure: failure, cancelled: cancelled,
            prepared: summary?.embedded ?? state.done, left: left)
        return state.stamped()
    }

    /// Le bilan d'une passe de préparation. Aucune de ces phrases ne dit
    /// « vecteur » : ce que l'utilisateur a demandé, c'est de rendre des pages
    /// cherchables par le sens, et c'est en pages que le résultat se compte.
    static func embedSummary(failure: String?, cancelled: Bool,
                             prepared: Int, left: Int?) -> String {
        if failure != nil {
            return String(localized: "Preparation interrupted. Nothing is lost: it picks up where it stopped.")
        }
        guard let left else {
            return String(localized: "Search by meaning: \(prepared) page(s) prepared. The count of what is left is unavailable (the database did not answer).")
        }
        if left == 0 {
            return String(localized: "Search by meaning is ready: \(prepared) page(s) prepared, nothing left.")
        }
        // Le second nombre passe par `Format.integer` : une seule forme
        // plurielle par phrase (celle du premier `%lld`), c'est la convention
        // que le catalogue tient déjà (« OCR of “%@” — %lld page(s) … »).
        if cancelled {
            return String(localized: "Stopped: \(prepared) page(s) prepared, \(Format.integer(left)) left. Nothing is lost, starting again picks up here.")
        }
        return String(localized: "Search by meaning: \(prepared) page(s) prepared · \(Format.integer(left)) left")
    }

    /// Ce que la base sait du travail restant, en PAGES.
    private static func readiness(_ store: GRDBStore) -> (indexed: Int, left: Int)? {
        guard let indexed = try? store.indexedPageCount(),
              let complete = try? store.completeVectorPageCount() else { return nil }
        return (indexed, max(0, indexed - complete))
    }

    /// Pages qu'il reste à préparer. Le nombre de pages INDEXÉES est relevé une
    /// fois au départ et n'est plus relu : c'est le compte cher des deux
    /// (`page_fts_docsize`), et il ne bouge pas d'une passe à l'autre sauf si
    /// l'agent indexe en même temps — auquel cas la barre serait de toute
    /// façon fausse d'un côté ou de l'autre, et une barre stable vaut mieux
    /// qu'une barre qui recule.
    private static func pagesLeft(_ store: GRDBStore, indexed: Int?) -> Int? {
        guard let indexed, let complete = try? store.completeVectorPageCount()
        else { return nil }
        return max(0, indexed - complete)
    }

    // MARK: - Outils

    /// Longueur de la file OCR, ou `nil` si la base n'a pas répondu.
    ///
    /// Le repli `?? 0` d'origine (audit A10.7) transformait un échec de `stats()`
    /// en « 0 page restante » : l'interface annonçait « OCR terminé — 0 page(s)
    /// traitée(s) » alors que rien n'avait été lu.
    private func queueLength() -> Int? {
        // Idem (C2-03) : les deux bornes de la passe ne veulent que la file.
        try? store.ocrQueueLength()
    }

    /// Collecteur de messages, dédoublonné et borné (audit A10.7).
    ///
    /// Une racine illisible ou une panne se répètent autant de fois qu'il y a de
    /// documents ; l'utilisateur n'a besoin de les lire qu'une fois, et la
    /// feuille d'indexation ne peut pas afficher 34 000 lignes.
    private final class ErrorSink: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        private var seen: Set<String> = []
        private var dropped = 0

        func note(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            guard seen.insert(message).inserted else { return }
            if messages.count < 4 { messages.append(message) } else { dropped += 1 }
        }

        func all() -> [String] {
            lock.lock(); defer { lock.unlock() }
            guard dropped > 0 else { return messages }
            return messages + [String(localized: "… and \(dropped) other distinct error(s)")]
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }
}
