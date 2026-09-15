// IndexPass.swift — UNE passe d'indexation, pour les trois pipelines.
// Propriété : A-Core, audit F2 / F3 / X3.
//
// Avant : `Sources/fouine/Pipeline.swift`, `Sources/FouineAgent/AgentPipeline.swift`
// et `Sources/FouineApp/Model/IndexingService.swift` faisaient la même chose,
// recopiée trois fois — « RECODÉE et non importée : la CLI est un exécutable,
// on n'importe pas un exécutable », disait l'en-tête de l'agent. La copie a
// dérivé sur cinq points, et chacun était un défaut visible :
//
//   1. l'app n'avait qu'un `catch` : un volume débranché marquait CHAQUE
//      document `.failed` — 1 330 documents perdus pour un câble USB —, là où
//      la CLI et l'agent arrêtaient le lot ;
//   2. l'agent avait gardé `try? setDocState` (audit X3) : un document dont
//      l'état ne s'écrivait pas restait `.discovered` et était RÉ-EXTRAIT à
//      chaque salve, indéfiniment, sans une ligne de journal ;
//   3. l'app ne faisait pas d'`upsertDoc` après extraction : `docs.n_pages`
//      restait à 0 pour tout ce qu'elle indexait ;
//   4. l'app n'avait pas de budget, la CLI pas d'annulation ;
//   5. l'app ne rendait jamais `fouine.lock` (audit F3).
//
// Ce fichier est la réponse : une passe, un observateur, un `shouldStop`, un
// budget, et une distinction TYPÉE entre l'erreur qui arrête tout et celle qui
// ne concerne qu'un document. Les trois pipelines n'en gardent que leur sortie.
//
// LE VERROU (F3). Il est pris ICI, en début de passe, en se nommant, et rendu
// par un `defer` — donc aussi sur une erreur fatale ou une annulation. Le
// prendre d'emblée fait échouer TÔT, avec le nom du détenteur, au lieu de
// découvrir l'occupation à la première écriture, après avoir déjà parcouru
// toutes les racines.

import Foundation
import FouineCore
import FouineCrawl
import FouineExtract

/// Ce que le rapprochement de la transcription demande à la base (TR1). À part
/// d'`IndexPassStore`, comme `SpotlightSyncStore` : un mandataire de test n'a
/// pas à le porter, et la passe s'en passe alors.
public protocol TranscriptionRevisionStore {
    func transcriptionRevision() throws -> String?
    func setTranscriptionRevision(_ value: String) throws
    func requeueMediaForTranscription(extensions: Set<String>,
                                      skipReasons: [String],
                                      skipReasonPrefixes: [String],
                                      failedReasonSubstrings: [String],
                                      revision: String) throws -> Int
}

extension GRDBStore: TranscriptionRevisionStore {}

/// Ce qu'une passe doit faire, et jusqu'où.
public struct IndexPassOptions: Sendable {
    /// Mode de parcours, ou `nil` pour n'extraire que ce qui est déjà découvert
    /// (`fouine extract`).
    public var crawl: CrawlMode?
    /// Extraire les documents `.discovered` (`fouine crawl` seul dit non).
    public var extract: Bool
    /// Un seul document, par chemin absolu ou `rel_path` (`--only`).
    public var only: String?
    /// Fils d'extraction demandés ; bornés par `JobsCap` (audit X1).
    public var jobs: Int
    public var budget: Budget
    /// Fin de passe : `page_fts optimize` (§5.1). L'agent dit non.
    public var optimize: Bool
    /// Fin de passe : réalimentation de `vocab_tri` (§5.5.2).
    public var warmVocabulary: Bool
    /// Fin de passe : rattrapage de `docs.lang` sur le texte déjà indexé
    /// (lot U3, R-10), au plus ce nombre de documents. `0` = ne rien rattraper.
    ///
    /// BORNÉ, et c'est tout l'intérêt : les trois pipelines jouent la même
    /// passe, l'agent d'arrière-plan compris, et personne ne doit attendre
    /// 1 392 détections d'un coup. Mesuré le 05/09/2026 sur la base réelle :
    /// 300 documents relus en 1,0 s (échantillon lu dans `page_fts` +
    /// NLLanguageRecognizer), sous les ~2 s qu'une fin de passe peut absorber.
    /// `fouine maintain --detect-languages` fait le reste d'un coup.
    public var languageBackfillLimit: Int
    /// Une racine illisible n'arrête pas la passe (§5.6, « ne jamais planter »).
    ///
    /// C'est la SEULE divergence conservée entre les trois adaptateurs, et elle
    /// est contractuelle : la CLI doit sortir en 5 sur une racine illisible
    /// (§4.3) et l'agent traite une racine par passe, quand l'app doit garder
    /// ses autres racines vivantes.
    public var continueAfterRootFailure: Bool
    /// Le rôle inscrit dans `fouine.lock` (audit F3).
    public var role: LockRole

    public init(crawl: CrawlMode? = .delta, extract: Bool = true,
                only: String? = nil, jobs: Int = 4, budget: Budget = .none,
                optimize: Bool = true, warmVocabulary: Bool = true,
                languageBackfillLimit: Int = 300,
                continueAfterRootFailure: Bool = false,
                role: LockRole = .cli) {
        self.crawl = crawl
        self.extract = extract
        self.only = only
        self.jobs = jobs
        self.budget = budget
        self.optimize = optimize
        self.warmVocabulary = warmVocabulary
        self.languageBackfillLimit = languageBackfillLimit
        self.continueAfterRootFailure = continueAfterRootFailure
        self.role = role
    }
}

public struct IndexPass: Sendable {

    private let store: any IndexPassStore
    private let crawler: any Crawler
    private let registry: any ExtractorRegistry
    private let observer: any IndexPassObserver
    private let shouldStop: ShouldStop
    private let limits: ExtractLimits
    /// La transcription est-elle allumée pour CETTE passe (TR1) ? Lue dans le
    /// même instantané que celui qui arme le registre : la marque inscrite en
    /// base doit dire ce que l'extracteur fera, pas ce que les réglages sont
    /// devenus entre la construction et `run`.
    private let transcribes: Bool

    public init(store: any IndexPassStore,
                observer: any IndexPassObserver = SilentObserver(),
                shouldStop: @escaping ShouldStop = { false },
                crawler: (any Crawler)? = nil,
                registry: (any ExtractorRegistry)? = nil,
                limits: ExtractLimits = ExtractLimits()) {
        self.store = store
        var extensions = DefaultExtractorRegistry.supportedExtensions
        let (snapshot, warning) = SettingsSnapshot.load(from: store)
        if let warning { observer.indexPass(.note(warning)) }
        if snapshot.extractImages {
            extensions.formUnion(DefaultExtractorRegistry.imageExtensions)
        }
        if snapshot.extractMedia {
            extensions.formUnion(DefaultExtractorRegistry.mediaExtensions)
        }
        self.crawler = crawler ?? FouineCrawler(
            store: store,
            indexableExtensions: extensions)
        // Le registre suit le MÊME réglage que le crawler (correctif de fusion
        // du lot H2) : construit sans lui, `DefaultExtractorRegistry()` ne
        // lisait que la variable d'environnement, et `fouine config set
        // extract.images true` faisait ramasser les images par le crawler
        // pour les voir refusées « unsupported » à l'extraction.
        self.registry = registry
            ?? DefaultExtractorRegistry(extractImages: snapshot.extractImages,
                                        extractMedia: snapshot.extractMedia,
                                        media: MediaOptions(snapshot: snapshot))
        self.observer = observer
        self.shouldStop = shouldStop
        self.limits = limits
        self.transcribes = snapshot.extractTranscribe
    }

    // MARK: - La passe

    /// Parcourt, extrait, met en file OCR, consolide. Rend le bilan.
    ///
    /// Lève UNIQUEMENT sur une erreur fatale (§4.2 : volume non monté, panne de
    /// base, verrou occupé), telle quelle : les codes de sortie du §4.3 en
    /// dépendent. Une erreur qui ne concerne qu'un document ne remonte jamais —
    /// elle est dans `docs.err`, dans l'événement `.document` et dans le bilan.
    @discardableResult
    public func run(roots: [RootRecord],
                    options: IndexPassOptions) throws -> IndexPassSummary {
        // Les réglages sont lus UNE fois, ICI, au démarrage de la passe (audit
        // U2) : une lecture par document ferait onze analyses de chaînes pour
        // 1 330 documents, et surtout la priorité de file changerait au milieu
        // d'un lot si quelqu'un épinglait une racine pendant qu'il tourne. Une
        // passe travaille avec les réglages qu'elle avait au départ ; la
        // suivante, dans la minute, prendra les nouveaux.
        let (settings, warning) = SettingsSnapshot.load(from: store)
        let run = Run(observer: observer, pinnedRoots: settings.pinnedRoots)
        if let warning { run.emit(.note(warning)) }
        for w in settings.warnings { run.emit(.note(w)) }
        // Le verrou périmé d'un processus mort se signale au moment où on le
        // reprend, c'est-à-dire pendant `acquireWriteLock` : le journal doit
        // être branché AVANT.
        store.setWriteLockLog { message in run.emit(.note(message)) }
        try store.acquireWriteLock(as: options.role)
        defer { store.releaseWriteLock() }

        do {
            try body(roots: roots, options: options, settings: settings, run: run)
        } catch {
            // Le bilan part MÊME sur erreur fatale : l'app doit pouvoir dire
            // combien de documents avaient abouti avant le débranchement.
            run.emit(.finished(run.summary()))
            throw error
        }
        let summary = run.summary()
        run.emit(.finished(summary))
        return summary
    }

    private func body(roots: [RootRecord], options: IndexPassOptions,
                      settings: SettingsSnapshot, run: Run) throws {
        syncAppSources(settings: settings, options: options, run: run)
        if let mode = options.crawl {
            try crawl(roots: roots, mode: mode, options: options, run: run)
        }
        if options.extract, !run.isStopped {
            reconcileTranscription(run: run)
            let targets = try collectTargets(roots: roots, options: options, run: run)
            // Annulation pendant la collecte : ne pas annoncer « 0 document à
            // extraire », qui se lirait comme un delta vide.
            if run.isStopped { return }
            run.setTotal(targets.count)
            run.emit(.extractionWillStart(total: targets.count))
            if !targets.isEmpty {
                try extract(targets: targets, options: options, run: run)
            }
        }
        try finish(options: options, run: run)
        donateToSpotlight(options: options, run: run)
    }

    // MARK: - 0 · Sources applicatives (lot INT-F4)

    /// Recopie les notes des applications activées AVANT le parcours.
    ///
    /// AVANT, et non après : les fichiers Markdown que la synchronisation écrit
    /// doivent être là quand le crawl passe, sans quoi les notes ne seraient
    /// indexées qu'à la passe SUIVANTE — soixante secondes plus tard pour
    /// l'agent, et « rien ne s'est passé » pour qui vient de cocher la case.
    ///
    /// DANS la passe, comme la remise à Spotlight, et pour la même raison : ce
    /// qui est recopié dans les trois pipelines diverge dans les trois (audit
    /// F2). L'agent tient donc les notes à jour tout seul.
    ///
    /// COÛT NUL QUAND AUCUNE SOURCE N'EST ALLUMÉE : deux lectures de booléen
    /// dans un instantané déjà chargé, et on repart.
    ///
    /// UNE PASSE QUI NE PARCOURT PAS (`fouine extract`, `fouine ocr`) ne
    /// synchronise pas : écrire des fichiers que personne n'ira regarder serait
    /// du travail perdu, et une passe d'OCR n'a rien à voir avec des notes.
    ///
    /// AUCUNE ERREUR NE REMONTE : elle devient une note de journal. Les notes
    /// d'une application sont un SERVICE rendu par-dessus l'index, jamais une
    /// condition de l'index.
    private func syncAppSources(settings: SettingsSnapshot,
                                options: IndexPassOptions, run: Run) {
        guard options.crawl != nil, settings.anySourceEnabled,
              let store = store as? any SourceRootStore else { return }
        let sources = AppSources.enabled(settings)
        guard !sources.isEmpty else { return }
        SourceSync.run(store: store, sources: sources) { run.emit(.note($0)) }
    }

    // MARK: - 5 · Spotlight (lot INT-S1)

    /// Remet à Spotlight ce que cette passe a indexé.
    ///
    /// APRÈS la consolidation et AVANT `.finished` : le texte est en base, les
    /// segments sont fusionnés, et le bilan que reçoit l'appelant est donc
    /// celui d'une passe entièrement terminée, Spotlight compris.
    ///
    /// DANS la passe, et non dans les trois adaptateurs : c'est la leçon de
    /// l'audit F2 — ce qui est recopié trois fois diverge trois fois. Une
    /// erreur ne remonte JAMAIS : elle devient une note. Spotlight est un
    /// service rendu par-dessus l'index, pas une condition de l'index.
    ///
    /// Une passe ANNULÉE ne donne rien, pour la même raison que la
    /// consolidation : l'utilisateur vient de cliquer « Annuler ».
    private func donateToSpotlight(options: IndexPassOptions, run: Run) {
        guard !run.wasCancelled, run.fatalError == nil,
              let store = store as? any SpotlightSyncStore else { return }
        // « Spotlight : sauté, pas de bundle » ne se dit qu'à la ligne de
        // commande, et seulement quand la passe a produit quelque chose :
        // `fouine index` enchaîne DEUX passes (parcours puis extraction), et
        // annoncer sans condition la répétait pour un parcours qui n'a rien
        // indexé.
        SpotlightSync.afterPass(
            store: store,
            announceUnavailable: options.role == .cli
                && run.summary().counters.done > 0) { run.emit(.note($0)) }
    }

    // MARK: - 1 · Parcours

    private func crawl(roots: [RootRecord], mode: CrawlMode,
                       options: IndexPassOptions, run: Run) throws {
        for root in roots {
            // Le parcours d'une racine n'est pas interruptible : on n'annule
            // qu'ENTRE deux racines (le crawler est une boucle système).
            //
            // Le BUDGET, lui, ne s'applique pas au parcours : il compte des
            // documents laissés en file (§4.3, sortie 4), et c'est l'extraction
            // qui prend les heures — un crawl delta de tout le corpus tient en
            // quelques secondes. C'est aussi ce que faisait la CLI, dont seul
            // `extract` armait l'échéance.
            if shouldStop() { run.cancel(); return }
            run.emit(.willCrawl(root: root.label))
            do {
                let summary = try crawler.crawl(rootID: root.id, mode: mode,
                                                store: store)
                run.emit(.crawled(root: root.label, summary: summary))
            } catch {
                guard options.continueAfterRootFailure else { throw error }
                let message = IndexText.describe(error)
                run.noteRootFailure("“\(root.label)”: " + message)
                run.emit(.rootFailed(root: root.label, message: message))
            }
        }
    }

    // MARK: - 1 bis · Relire les enregistrements (lot TR1)

    /// Compare `meta.transcription_revision` au réglage, et remet en file les
    /// médias à relire quand la transcription s'allume ou change de révision.
    ///
    /// ICI, et non dans le crawl : le crawl ne réexamine que des causes
    /// EXTÉRIEURES au fichier, et un document `extracted` n'est jamais repris.
    /// Juste avant la collecte des cibles, sous le verrou déjà pris, pour que
    /// les documents remis en file soient extraits PAR CETTE passe — et pour
    /// les trois pipelines à la fois.
    ///
    /// Coût quand rien ne change : une lecture de `meta`. Transcription
    /// éteinte : la marque passe à `off`, rien n'est relu, les transcriptions
    /// déjà faites restent cherchables. Reliquat accepté : décocher puis
    /// recocher la case retranscrit tous les médias une fois.
    ///
    /// Une erreur ne remonte pas : elle devient une note. La marque n'étant
    /// écrite qu'avec la remise en file, la passe suivante réessaie.
    private func reconcileTranscription(run: Run) {
        guard let store = store as? any TranscriptionRevisionStore else { return }
        let expected = transcribes ? MediaExtractor.transcriptRevision
                                   : GRDBStore.transcriptionRevisionOff
        do {
            guard try store.transcriptionRevision() != expected else { return }
            guard transcribes else {
                try store.setTranscriptionRevision(expected)
                return
            }
            let queued = try store.requeueMediaForTranscription(
                extensions: DefaultExtractorRegistry.mediaExtensions,
                skipReasons: MediaExtractor.rereadSkipReasons,
                skipReasonPrefixes: MediaExtractor.rereadSkipReasonPrefixes,
                failedReasonSubstrings: MediaExtractor.rereadFailedReasonSubstrings,
                revision: expected)
            if queued > 0 {
                run.emit(.note("transcription: \(queued) media document(s) "
                               + "queued to be written down again"))
            }
        } catch {
            run.emit(.note("transcription: re-read check skipped: "
                           + IndexText.describe(error)))
        }
    }

    // MARK: - 2 · Cibles

    struct Target: Sendable {
        let docID: Int64
        let record: DocRecord
        let url: URL
        /// La racine d'où vient le document. Elle n'était portée nulle part :
        /// `extractOne` ne pouvait donc pas savoir si la racine est ÉPINGLÉE, et
        /// le paramètre `isPinnedRoot` d'`OCRPriority` — prévu depuis F4 —
        /// n'avait aucun appelant capable de le renseigner (audit U2, F4).
        let rootID: Int64
    }

    /// Les documents `.discovered` des racines données.
    ///
    /// Un document dont le chemin ne se résout pas (volume démonté) est une
    /// erreur FATALE, et non un document à marquer `.failed` : le volume porte
    /// toute la racine, l'erreur est la même pour ses milliers de documents, et
    /// c'est le sens du code de sortie 2 (§4.3). C'est le défaut n°1 de l'app,
    /// qui marquait tout le corpus en échec pour un câble débranché.
    private func collectTargets(roots: [RootRecord], options: IndexPassOptions,
                                run: Run) throws -> [Target] {
        var out: [Target] = []
        let wanted = options.only.map { ($0 as NSString).expandingTildeInPath }
        for root in roots {
            if shouldStop() { run.cancel(); return [] }
            let rows: [DocRow]
            do { rows = try store.docs(underRoot: root.id) } catch {
                guard options.continueAfterRootFailure else { throw error }
                let message = IndexText.describe(error)
                run.noteRootFailure("documents of “\(root.label)” are "
                                    + "unreadable: " + message)
                run.emit(.rootFailed(root: root.label, message: message))
                continue
            }
            for row in rows where row.record.state == .discovered {
                let url = try VolumeResolver.absolutePath(
                    volUUID: row.record.volUUID, relPath: row.record.relPath)
                if let wanted, wanted != url.path, wanted != row.record.relPath {
                    continue
                }
                out.append(Target(docID: row.id, record: row.record, url: url,
                                  rootID: root.id))
            }
        }
        // À priorité égale, les plus petits d'abord : les gains arrivent tôt (§6.1).
        return out.sorted { $0.record.size < $1.record.size }
    }

    // MARK: - 3 · Extraction

    private func extract(targets: [Target], options: IndexPassOptions,
                         run: Run) throws {
        let queue = OperationQueue()
        // Plafond de concurrence (X1) : l'extraction est bornée par la MÉMOIRE
        // (279 Mo/fil PDFKit + 128 Mio/worker bsdtar), pas par le processeur.
        queue.maxConcurrentOperationCount = JobsCap.clampExtract(
            options.jobs, log: { run.emit(.note($0)) })
        queue.qualityOfService = .utility

        // L'ARRÊT ENTRE DANS L'EXTRACTION (ST1). Jusqu'ici il n'était consulté
        // qu'entre deux documents : « Stop » attendait la fin des lectures en
        // vol — jusqu'à `jobs` documents, et une vidéo se transcrit en minutes.
        // Les extracteurs qui bouclent (PDF page à page, médias fenêtre à
        // fenêtre) le consultent désormais eux-mêmes et lèvent `.cancelled`.
        var passLimits = limits
        passLimits.shouldStop = { run.wasCancelled || self.shouldStop() }

        for target in targets {
            queue.addOperation {
                // Une erreur fatale coupe court sans rien compter : ce qui reste
                // n'a pas été « sauté », il n'a pas été tenté.
                if run.fatalError != nil { return }
                if run.wasCancelled || self.shouldStop() { run.cancel(); return }
                // Le budget, lui, COMPTE ce qu'il laisse : c'est le `remaining`
                // de `FouineError.budgetExhausted` et la sortie 4 (§4.3).
                if options.budget.isExhausted { run.exhaustBudget(); return }
                self.extractOne(target: target, limits: passLimits, run: run)
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        run.emitProgress(force: true)
        if let fatal = run.fatalError { throw fatal }
    }

    private func extractOne(target: Target, limits: ExtractLimits, run: Run) {
        do {
            guard let extractor = registry.extractor(for: target.record.ext) else {
                let reason = ExtractOutcome.skipReason(ext: target.record.ext)
                try store.setDocState(target.docID, .skipped, err: reason)
                run.finished(target, .skipped, reason: reason)
                return
            }
            run.emit(.willExtract(document: Self.name(of: target)))
            let result = try extractor.extract(url: target.url, limits: limits)
            try store.replacePages(docID: target.docID, pages: result.pages)
            try store.setPageCount(target.docID, result.pageCount)
            // `upsertDoc` post-extraction : `docs.n_pages` et `docs.state`
            // doivent refléter le résultat. L'app l'oubliait (audit F2).
            var updated = target.record
            updated.nPages = result.pageCount
            updated.state = .extracted
            _ = try store.upsertDoc(updated)
            try store.setDocState(target.docID, .extracted, err: nil)
            // Langue dominante (audit X2). C'est ICI, et nulle part ailleurs,
            // qu'on tient le texte du document : la détection ne coûte donc pas
            // une seule lecture supplémentaire. `nil` — texte trop court,
            // hypothèse trop faible — laisse la colonne vide, ce qu'elle était
            // de toute façon avant ce palier.
            try store.setDocLanguage(
                target.docID,
                LanguageDetector.detect(LanguageDetector.sample(pages: result.pages)))
            // Date du DOCUMENT (schéma v9, constat PR-07). Les extracteurs la
            // rendent telle que le format l'écrit ; `DocumentDate` l'analyse et
            // REFUSE ce qui n'a pas de sens (avant 1900, après demain, format
            // ambigu) — la colonne reste alors vide, ce qu'elle était de toute
            // façon. Rien n'est relu : la métadonnée vient de la même ouverture
            // que le texte.
            try store.setDocDate(target.docID,
                                 result.meta["date"].flatMap { DocumentDate.parse($0) })

            var queued = 0
            if !result.ocrCandidates.isEmpty {
                // Racine épinglée -> priorité 0, devant tout le reste. Le
                // paramètre existait depuis F4 ; la fenêtre de réglages du
                // palier 2.3 lui donne enfin une source (audit U2).
                let prio = OCRPriority.forDocument(
                    extension: target.record.ext, pageCount: result.pageCount,
                    isPinnedRoot: run.pinnedRoots.contains(target.rootID))
                try store.enqueueOCR(docID: target.docID,
                                     pages: result.ocrCandidates, priority: prio)
                queued = result.ocrCandidates.count
            }
            run.finished(target, .extracted, pages: result.pages.count,
                         queued: queued)
        } catch FouineError.cancelled {
            // L'ARRÊT EST ARRIVÉ PENDANT LA LECTURE (ST1). Ce document n'est ni
            // extrait, ni en échec, ni sauté : rien n'est écrit, `docs.err`
            // reste vide et l'état reste `.discovered` — la passe suivante le
            // reprendra depuis le début. Il est « non tenté », comme ce qui
            // suit une erreur fatale, et non « sauté » comme ce que le budget
            // laisse en file.
            run.abandon(target)
        } catch {
            handle(error, target: target, run: run)
        }
    }

    /// Le nom de fichier d'une cible — ce que l'utilisateur reconnaît, jamais
    /// le chemin (CLAUDE.md, public cible).
    private static func name(of target: Target) -> String {
        (target.record.relPath as NSString).lastPathComponent
    }

    /// Le tri qui manquait à l'app : fatal, ignoré, ou échec de ce document.
    private func handle(_ error: Error, target: Target, run: Run) {
        switch IndexFault.classify(error) {
        case .fatal(let fatal):
            run.abort(fatal)
        case .skipped(let reason):
            record(target, .skipped, reason: reason, run: run)
        case .perDocument:
            record(target, .failed, reason: IndexText.describe(error), run: run)
        }
    }

    /// Écrit l'état d'un document — et si CETTE écriture échoue, la passe
    /// s'arrête.
    ///
    /// L'agent avait ici un `try?` (audit X3) : le document restait
    /// `.discovered`, redevenait une cible à la salve suivante, et l'extraction
    /// se refaisait indéfiniment sans que rien ne l'indique. Une base qui
    /// n'accepte plus une écriture d'état ne va pas accepter les suivantes : il
    /// n'y a rien à sauver en continuant.
    private func record(_ target: Target, _ state: DocState, reason: String,
                        run: Run) {
        do {
            try store.setDocState(target.docID, state, err: reason)
            run.finished(target, state == .skipped ? .skipped : .failed,
                         reason: reason)
        } catch {
            run.abort(IndexFault.asFatal(error))
        }
    }

    // MARK: - 4 · Fin de passe (§5.1, §5.5.2)

    private func finish(options: IndexPassOptions, run: Run) throws {
        backfillLanguages(options: options, run: run)
        guard options.optimize || options.warmVocabulary else { return }
        // Une passe ANNULÉE ne consolide pas : `vocab_tri` coûte 18 à 25 s sur
        // le vocabulaire réel, et les faire attendre après un clic sur
        // « Annuler » est exactement ce que l'utilisateur a refusé. L'index
        // reste cohérent — la consolidation n'est qu'une optimisation, la
        // prochaine passe la fera.
        guard !run.wasCancelled else { return }
        run.emit(.willConsolidate)
        if options.optimize { try store.optimize() }
        if options.warmVocabulary { try store.warmVocabulary() }
    }

    /// Rattrapage de `docs.lang` (lot U3, R-10), en fin de passe et BORNÉ.
    ///
    /// Le texte est déjà en base : il n'y a rien à ré-extraire, seulement à
    /// relire quelques milliers de caractères par document. Les trois pipelines
    /// en profitent sans rien faire — l'app et l'agent passent par ici — et
    /// aucune chaîne visible ne change : la facette « Langue » se remplit
    /// toute seule, passe après passe.
    ///
    /// UNE PASSE ANNULÉE, à court de budget ou en erreur fatale ne rattrape
    /// rien : c'est un CONFORT, pas une obligation, et l'utilisateur qui vient
    /// de cliquer « Annuler » n'a pas à l'attendre.
    ///
    /// Une erreur n'arrête JAMAIS la passe pour la même raison : tout ce qui
    /// devait être indexé l'est déjà quand on arrive ici.
    private func backfillLanguages(options: IndexPassOptions, run: Run) {
        guard options.languageBackfillLimit > 0, !run.isStopped, !shouldStop()
        else { return }
        do {
            let report = try store.backfillLanguages(
                limit: options.languageBackfillLimit,
                sampleCharacters: LanguageDetector.sampleCharacters,
                chunk: GRDBStore.languageBackfillChunk,
                detect: { LanguageDetector.detect(LanguageDetector.sample(pages: $0)) })
            guard report.scanned > 0 else { return }
            run.countLanguages(report.scanned)
            run.emit(.note("language detected for \(report.scanned) document(s), "
                           + "\(report.remaining) left"))
        } catch {
            run.emit(.note("language backfill skipped: " + IndexText.describe(error)))
        }
    }

    // MARK: - État d'une exécution

    /// Compteurs, arrêt et sérialisation de l'observateur.
    ///
    /// L'observateur est appelé sous un verrou qui lui est PROPRE, jamais sous
    /// celui des compteurs : un adaptateur qui imprime ou publie un état ne
    /// retarde donc aucune écriture, et n'a pas à être réentrant. Il ne doit en
    /// revanche jamais rappeler la base — il serait alors appelé depuis un fil
    /// d'extraction, au milieu du lot.
    final class Run: @unchecked Sendable {
        private let observer: any IndexPassObserver
        /// Racines épinglées, figées au démarrage de la passe (audit U2, F4).
        let pinnedRoots: Set<Int64>
        private let counterLock = NSLock()
        private let observerLock = NSLock()
        private var counters = IndexCounters()
        private var fatal: FouineError?
        private var stop: IndexPassStop = .completed
        private var failures: [String] = []
        private var lastProgress = Date.distantPast

        init(observer: any IndexPassObserver, pinnedRoots: Set<Int64> = []) {
            self.observer = observer
            self.pinnedRoots = pinnedRoots
        }

        func emit(_ event: IndexPassEvent) {
            observerLock.lock()
            observer.indexPass(event)
            observerLock.unlock()
        }

        var fatalError: FouineError? {
            counterLock.lock(); defer { counterLock.unlock() }; return fatal
        }

        /// Vrai dès qu'il n'y a plus rien à tenter : erreur fatale, annulation
        /// ou budget épuisé.
        var isStopped: Bool {
            counterLock.lock(); defer { counterLock.unlock() }
            return fatal != nil || stop != .completed
        }

        var wasCancelled: Bool {
            counterLock.lock(); defer { counterLock.unlock() }
            return stop == .cancelled
        }

        func setTotal(_ total: Int) {
            counterLock.lock(); counters.total = total; counterLock.unlock()
        }

        func abort(_ error: FouineError) {
            counterLock.lock(); if fatal == nil { fatal = error }; counterLock.unlock()
        }

        func cancel() {
            counterLock.lock()
            if stop == .completed { stop = .cancelled }
            counterLock.unlock()
        }

        /// Un document lâché en cours de lecture (ST1) : la passe est annulée,
        /// aucun compteur ne bouge, et l'observateur apprend qu'il n'attend
        /// plus celui-là.
        func abandon(_ target: Target) {
            cancel()
            emit(.abandoned(document: IndexPass.name(of: target)))
        }

        /// Le budget ne jette pas le document : il le laisse en file, `.discovered`,
        /// pour la passe suivante. C'est ce que compte `budgetSkipped` (§4.3,
        /// sortie 4).
        func exhaustBudget() {
            counterLock.lock()
            counters.budgetSkipped += 1
            if stop == .completed { stop = .budgetExhausted }
            counterLock.unlock()
        }

        func countLanguages(_ n: Int) {
            counterLock.lock(); counters.languagesDetected += n; counterLock.unlock()
        }

        func noteRootFailure(_ message: String) {
            counterLock.lock(); failures.append(message); counterLock.unlock()
        }

        func finished(_ target: Target, _ kind: DocumentOutcome.Kind,
                      reason: String? = nil, pages: Int = 0, queued: Int = 0) {
            counterLock.lock()
            counters.done += 1
            switch kind {
            case .extracted: counters.extracted += 1
            case .failed:    counters.failed += 1
            case .skipped:   counters.skipped += 1
            }
            counters.pages += pages
            counters.queued += queued
            counterLock.unlock()

            emit(.document(DocumentOutcome(
                docID: target.docID, relPath: target.record.relPath, kind: kind,
                reason: reason, pages: pages, queuedForOCR: queued)))
            emitProgress(force: false)
        }

        /// Progression au plus dix fois par seconde : une racine de petits `.txt`
        /// rend des milliers de documents en quelques secondes, et chaque
        /// publication de l'app coûte un saut vers le fil principal.
        func emitProgress(force: Bool) {
            counterLock.lock()
            let now = Date()
            let due = force || now.timeIntervalSince(lastProgress) >= 0.1
            if due { lastProgress = now }
            let snapshot = counters
            counterLock.unlock()
            if due { emit(.progress(snapshot)) }
        }

        func summary() -> IndexPassSummary {
            counterLock.lock(); defer { counterLock.unlock() }
            return IndexPassSummary(counters: counters, stop: stop,
                                    rootFailures: failures)
        }
    }
}
