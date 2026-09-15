// OCRRun.swift — la pompe OCR (SPEC §6.2, §6.3). Propriété : A-OCR.
// SIGNATURE IMPOSÉE : la CLI (`fouine ocr`) se câble sur `OCRRun.run`.
//
//   file --> rendu 150 dpi gris ≤ 4 Mpx --> Vision .accurate --> completeOCR
//
// Ce que ce fichier tient, point par point :
//   · concurrence PLAFONNÉE À 4 (§6.3) — 8 est une régression mesurée (0,576 p/s
//     contre 0,699) ; une demande supérieure est ramenée à 4 avec un avertissement,
//     jamais refusée ;
//   · `customWords` lu UNE fois au démarrage (`topVocabulary(3000, ≥ 6 lettres)`,
//     durcissement n°2 du §6.2) ;
//   · préchauffage AVANT d'ouvrir la file (8,5 s mesurées, une fois par processus) ;
//   · QoS `.utility` pour tout le travail ;
//   · garde-fou thermique sur `CPU_Speed_Limit`, pas sur `thermalState` (piège n°4) ;
//   · toute erreur de page -> `failOCR` + on continue. JAMAIS d'arrêt du lot
//     (piège n°13) : les PDF illisibles existent dans le corpus ;
//   · `--budget-minutes` : les pages en vol se terminent, la file reste INTACTE,
//     et le run rend `.budgetExhausted` (la CLI en fait la sortie 4) ;
//   · `vocab_tri` alimenté depuis le TEXTE FRAÎCHEMENT RECONNU, par lot et en
//     fin de run (§5.5.2 ; audit A2 du 01/09/2026 — le balayage global de
//     fts5vocab coûtait 18-25 s par lot de 10 min, les quatre fils à l'arrêt,
//     pour insérer zéro terme).

import Foundation
import Dispatch
import FouineCore

public enum OCRRunOutcome: Sendable { case completed, budgetExhausted }

public enum OCRRun {

    /// Plafond de concurrence IMPOSÉ (§6.3). Ce n'est pas un défaut, c'est un mur.
    public static let maxJobs = 4
    /// Défaut de la CLI.
    public static let defaultJobs = 4
    /// Taille d'un lot tiré de la file.
    public static let batchSize = 16
    /// `customWords` : nombre de termes et longueur minimale (§6.2).
    /// ARBITRAGE ORCHESTRATEUR (recette OCR, 2026-09-01) : `customWords` est
    /// DÉSACTIVÉ par défaut. Mesuré par A-Recette sur 8 pages réelles : sortie
    /// Vision identique octet pour octet avec et sans les 3 000 termes, pour
    /// +5 % à +51 % de temps par page — `topVocabulary` rend les termes les
    /// plus FRÉQUENTS (energy, reaction, figure…), que Vision connaît déjà,
    /// quand `customWords` sert les mots rares. Sur la passe complète, la
    /// désactivation économise ~1,5 à 4 h. Réactivable pour expérimenter :
    /// FOUINE_CUSTOM_WORDS=<n> (n termes, ≥ vocabularyMinLength lettres).
    public static var vocabularyLimit: Int {
        Int(ProcessInfo.processInfo.environment["FOUINE_CUSTOM_WORDS"] ?? "") ?? 0
    }
    public static let vocabularyMinLength = 6
    /// Balayage global de `vocab_tri` toutes les N pages complétées.
    ///
    /// INOPÉRANT dans le régime de l'agent, et c'est voulu (audit A2) : les
    /// compteurs naissent avec le run, et un lot d'agent de 10 min ne dépasse
    /// pas ~150 pages. Le seuil ne sert plus qu'aux longues passes `fouine ocr`
    /// lancées avec FOUINE_OCR_VOCAB_SCAN — voir `vocabFullScan`.
    public static let warmEveryPages = 500
    /// Échappatoire : rétablit l'ancien balayage global de `vocab_tri` (par
    /// seuil et en fin de run) à la place de la récolte ciblée. À n'utiliser que
    /// pour réconcilier une base dont on soupçonne le vocabulaire d'avoir dérivé
    /// — une passe d'indexation le fait déjà (`Pipeline.finish`, §5.1).
    public static var vocabFullScan: Bool {
        ProcessInfo.processInfo.environment["FOUINE_OCR_VOCAB_SCAN"] == "1"
    }
    /// Fenêtre de balayage pour `--only` et `--prio-folder` (file entière attendue
    /// entre 38 000 et 50 000 pages, §6.4).
    static let scanLimit = 500_000

    // MARK: - Entrée publique

    /// `log:` a une valeur par défaut : la signature imposée est préservée, et
    /// l'agent peut enfin faire passer son journal horodaté plutôt que de laisser
    /// la pompe écrire par `print` (audit, point 6 — « journal hétérogène »).
    ///
    /// `shouldStop:` a également une valeur par défaut. Consulté entre deux pages,
    /// il donne un point d'arrêt à l'appelant — l'app en fait son bouton
    /// « Annuler », jusque-là purement décoratif (audit A10.2). L'arrêt suit
    /// exactement le protocole du budget (§6.3) : les pages en vol se terminent,
    /// aucune transaction n'est coupée, la file reste INTACTE, et le run rend
    /// `.budgetExhausted` — c'est à l'appelant, qui sait ce qu'il a demandé, de
    /// distinguer les deux.
    @discardableResult
    public static func run(store: GRDBStore, jobs: Int, budgetMinutes: Int?,
                           prioFolder: String?, only: String?,
                           languages: [String]? = nil,
                           log: @escaping @Sendable (String) -> Void = { print($0) },
                           shouldStop: @escaping @Sendable () -> Bool = { false })
        throws -> OCRRunOutcome {
        try run(store: store, jobs: jobs,
                budgetSeconds: budgetMinutes.map { Double($0) * 60 },
                prioFolder: prioFolder, only: only, languages: languages, log: log,
                shouldStop: shouldStop)
    }

    // MARK: - Langues (audit X2)

    /// Les langues effectivement passées à Vision, et la ligne de journal qui
    /// va avec.
    ///
    /// Trois choses dans l'ordre, et pas une de plus :
    ///   1. la liste DEMANDÉE vient de l'appelant, ou à défaut du réglage
    ///      `ocr.languages` (table `settings`, variable `FOUINE_OCR_LANGUAGES`),
    ///      ou à défaut du couple historique `fr-FR, en-US` ;
    ///   2. elle est FILTRÉE sur `supportedRecognitionLanguages` de la machine —
    ///      une langue inconnue de la révision fait échouer la requête ENTIÈRE,
    ///      donc chaque page, et le seul symptôme serait un compteur d'échecs ;
    ///   3. tout ce qui a été écarté est DIT, une fois par run.
    static func resolveLanguages(store: GRDBStore, requested: [String]?,
                                 log: (String) -> Void) -> [String] {
        var wanted = requested ?? []
        if wanted.isEmpty {
            let (settings, warning) = SettingsSnapshot.load(from: store)
            if let warning { log(warning) }
            for w in settings.warnings { log(w) }
            wanted = settings.ocrLanguages
        }
        if wanted.isEmpty { wanted = VisionOCREngine.defaultLanguages }

        let (kept, rejected) = VisionOCREngine.filterLanguages(wanted)
        if !rejected.isEmpty {
            log("OCR language(s) ignored — not supported by Vision on this "
                + "machine: " + rejected.joined(separator: ", ")
                + " (see `fouine config get ocr.languages`)")
        }
        log("OCR languages: " + kept.joined(separator: ", "))
        return kept
    }

    // MARK: - Entrée interne (budget en secondes : bancs d'essai et tests)

    @discardableResult
    static func run(store: GRDBStore, jobs: Int, budgetSeconds: Double?,
                    prioFolder: String?, only: String?,
                    languages: [String]? = nil,
                    renderer: any PageRenderer = FouinePageRenderer(),
                    engine: any OCREngine = VisionOCREngine(),
                    log: @escaping @Sendable (String) -> Void = { print($0) },
                    shouldStop: @escaping @Sendable () -> Bool = { false })
        throws -> OCRRunOutcome {

        let started = Date()
        let deadline = budgetSeconds.map { started.addingTimeInterval($0) }
        let effectiveJobs = clampJobs(jobs, log: log)

        // --only : on résout le document AVANT de préchauffer. Un chemin qui n'est
        // pas dans l'index n'a aucune raison de coûter 8,5 s de modèle.
        var scopedDocID: Int64?
        if let only, !only.isEmpty {
            scopedDocID = try resolveDocument(only, store: store)
        }

        let customWords = loadVocabulary(store: store, log: log)
        // Les langues sont résolues UNE fois par run, avant le préchauffage :
        // le message « langue ignorée » doit sortir avant les 8,5 s de modèle,
        // pas après. (`prewarm` charge, lui, le modèle du couple par défaut :
        // la signature de `OCREngine` est gelée et ne porte pas de langues —
        // conséquence assumée, la première page paie le chargement manquant.)
        let effectiveLanguages = resolveLanguages(store: store,
                                                  requested: languages, log: log)

        let counters = Counters()
        let harvest = VocabHarvest()
        let governor = ThermalGovernor(nominalConcurrency: effectiveJobs, log: log)
        // Le moteur ne reçoit pas de `log:` (signature de protocole gelée) : on
        // lui branche celui du run pour que les lignes écartées par le seuil de
        // confiance soient enfin comptées quelque part (audit A5).
        if let vision = engine as? VisionOCREngine { vision.rejection.attach(log: log) }

        // Préchauffage : UNE fois par processus, avant d'ouvrir la file (§6.2).
        do {
            let warmStart = Date()
            try engine.prewarm()
            log(String(format: "engine %@ warmed up in %.2f s",
                       engine.revision, Date().timeIntervalSince(warmStart)))
        } catch {
            throw FouineError.ocr(
                "cannot warm up the OCR engine: \(describe(error))")
        }

        var budgetHit = false

        if let docID = scopedDocID {
            // ---- Un seul document -------------------------------------------
            let items = try queuedItems(store: store, matching: { $0 == docID })
            if items.isEmpty {
                log("no page queued for this document "
                    + "(doc_id \(docID)): nothing to do")
                summarize(counters: counters, started: started,
                          governor: governor, log: log)
                return .completed
            }
            let result = process(items: items, store: store, renderer: renderer,
                                 engine: engine, languages: effectiveLanguages,
                                 customWords: customWords,
                                 jobs: effectiveJobs, governor: governor,
                                 deadline: deadline, counters: counters,
                                 harvest: harvest, log: log,
                                 shouldStop: shouldStop)
            budgetHit = result.stoppedByBudget
        } else {
            // ---- Toute la file, éventuellement précédée d'un dossier ---------
            if let prioFolder, !prioFolder.isEmpty {
                let items = try queuedItems(store: store, inFolder: prioFolder)
                if items.isEmpty {
                    log("no page queued in “\(prioFolder)”: the queue is "
                        + "processed in its usual priority order")
                } else {
                    log("\(items.count) page(s) come first, in “\(prioFolder)”")
                    let result = process(items: items, store: store,
                                         renderer: renderer, engine: engine,
                                         languages: effectiveLanguages,
                                         customWords: customWords,
                                         jobs: effectiveJobs, governor: governor,
                                         deadline: deadline, counters: counters,
                                         harvest: harvest, log: log,
                                         shouldStop: shouldStop)
                    budgetHit = result.stoppedByBudget
                    warmHarvest(store: store, harvest: harvest, counters: counters,
                                log: log)
                }
            }
            if !budgetHit {
                budgetHit = try drainQueue(store: store, renderer: renderer,
                                           engine: engine,
                                           languages: effectiveLanguages,
                                           customWords: customWords,
                                           jobs: effectiveJobs, governor: governor,
                                           deadline: deadline, counters: counters,
                                           harvest: harvest, log: log,
                                           shouldStop: shouldStop)
            }
        }

        governor.cancel()
        // Fin de run : `vocab_tri` doit refléter tout ce qui vient d'entrer.
        // Ne coûte plus qu'une sonde de clé primaire par terme récolté (audit A2).
        warmHarvest(store: store, harvest: harvest, counters: counters, log: log,
                    force: true)
        if let vision = engine as? VisionOCREngine,
           let line = vision.rejection.summary() { log(line) }
        summarize(counters: counters, started: started, governor: governor, log: log)

        guard budgetHit else { return .completed }
        // `ocrQueueLength()`, pas `stats()` (audit C2-03) : neuf comptages
        // dont un balayage complet de `page_fts` étaient payés pour ce seul
        // nombre, à la fin de chaque passe.
        let remaining = (try? store.ocrQueueLength()) ?? 0
        guard remaining > 0 else { return .completed }
        log("budget exhausted: \(remaining) page(s) left in the queue, "
            + "the next run will pick up here")
        return .budgetExhausted
    }

    // MARK: - Concurrence

    /// Troncature de `--jobs`, déléguée à `JobsCap` (FouineCore, palier 1.4).
    ///
    /// Le plafond est le même que celui de l'extraction — 4 — mais pour une
    /// raison qui n'a rien à voir : l'extraction est bornée par la MÉMOIRE
    /// (279 Mo par fil PDFKit), l'OCR par le DÉBIT. La `reason` est donc portée
    /// ici, pas dans `JobsCap` ; seule la mécanique (tronquer avec un
    /// avertissement, jamais refuser, et le plancher à 1) est partagée. Le
    /// message rendu est mot pour mot celui d'avant — `testJobsAreCappedAtFour`
    /// le vérifie.
    static func clampJobs(_ jobs: Int, log: (String) -> Void) -> Int {
        JobsCap.clamp(jobs, max: maxJobs,
                      reason: "measured, 8 threads are a REGRESSION "
                            + "(0.576 p/s against 0.699 at 4 threads, §6.3)",
                      log: log)
    }

    // MARK: - Vocabulaire

    static func loadVocabulary(store: GRDBStore,
                               log: (String) -> Void) -> [String] {
        do {
            let words = try store.topVocabulary(limit: vocabularyLimit,
                                                minLength: vocabularyMinLength)
            if !words.isEmpty {
                log("customWords: \(words.count) term(s) from the index "
                    + "(≥ \(vocabularyMinLength) letters)")
            }
            return words
        } catch {
            // L'index peut être vide (première passe) : ce n'est pas une erreur.
            log("customWords unavailable (\(describe(error))): "
                + "OCR without the corpus lexicon")
            return []
        }
    }

    // MARK: - Sélection des pages

    struct Item: Sendable {
        let docID: Int64
        let page: Int
        let path: String
    }

    /// Pages en file appartenant aux documents retenus par `matching`.
    static func queuedItems(store: GRDBStore,
                            matching: (Int64) -> Bool) throws -> [Item] {
        try store.pendingOCRPages(limit: scanLimit)
            .filter { matching($0.docID) }
            .map { row in
                Item(docID: row.docID, page: row.page,
                     path: try VolumeResolver.absolutePath(volUUID: row.volUUID,
                                                           relPath: row.relPath).path)
            }
    }

    /// Pages en file des documents dont `top_folder` vaut `folder`.
    /// L'ordre de la file (prio, attempts, doc, page) est CONSERVÉ : `--prio-folder`
    /// réordonne la CONSOMMATION, il ne réécrit jamais `ocr_queue.prio` (§6.3).
    static func queuedItems(store: GRDBStore, inFolder folder: String) throws -> [Item] {
        var folders: [Int64: String] = [:]
        return try store.pendingOCRPages(limit: scanLimit)
            .filter { row in
                if let known = folders[row.docID] { return known == folder }
                let name = (try? store.docRow(id: row.docID))?.record.topFolder ?? ""
                folders[row.docID] = name
                return name == folder
            }
            .map { row in
                Item(docID: row.docID, page: row.page,
                     path: try VolumeResolver.absolutePath(volUUID: row.volUUID,
                                                           relPath: row.relPath).path)
            }
    }

    /// `--only` accepte indifféremment un chemin absolu ou un `rel_path` (§8.1).
    static func resolveDocument(_ argument: String, store: GRDBStore) throws -> Int64 {
        if argument.hasPrefix("/") {
            let resolved = try VolumeResolver.resolve(
                path: URL(fileURLWithPath: argument))
            if let id = try store.docID(volUUID: resolved.volUUID,
                                        relPath: resolved.relPath) {
                return id
            }
        }
        // rel_path : le volume n'est pas donné, on interroge ceux que l'on connaît.
        let relative = argument.hasPrefix("/") ? String(argument.dropFirst()) : argument
        for volume in try store.volumes() {
            if let id = try store.docID(volUUID: volume.uuid, relPath: relative) {
                return id
            }
        }
        throw FouineError.ocr(
            "document unknown to the index: \(argument) — run `fouine crawl` "
            + "then `fouine extract` before running OCR")
    }

    // MARK: - Boucle de file

    /// Vide la file par lots. Rend `true` si l'arrêt vient du budget ou de
    /// `shouldStop` (même sortie propre, cf. `run`).
    static func drainQueue(store: GRDBStore, renderer: any PageRenderer,
                           engine: any OCREngine, languages: [String],
                           customWords: [String],
                           jobs: Int, governor: ThermalGovernor,
                           deadline: Date?, counters: Counters,
                           harvest: VocabHarvest,
                           log: @escaping @Sendable (String) -> Void,
                           shouldStop: @escaping @Sendable () -> Bool = { false })
        throws -> Bool {
        var previousBatch: [Int64] = []
        var stall = 0
        while true {
            if let deadline, Date() >= deadline { return true }
            if shouldStop() { return true }
            let batch = try store.nextOCRBatch(limit: batchSize)
            if batch.isEmpty { return false }

            let signature = batch.map { Schema.ftsRowID(docID: $0.docID, page: $0.page) }
            let items = batch.map { Item(docID: $0.docID, page: $0.page, path: $0.path) }
            let before = counters.snapshot()
            let result = process(items: items, store: store, renderer: renderer,
                                 engine: engine, languages: languages,
                                 customWords: customWords,
                                 jobs: jobs, governor: governor,
                                 deadline: deadline, counters: counters,
                                 harvest: harvest, log: log,
                                 shouldStop: shouldStop)
            if result.stoppedByBudget { return true }
            warmHarvest(store: store, harvest: harvest, counters: counters, log: log)

            let after = counters.snapshot()
            if after.completed == before.completed && after.failed == before.failed
                && signature == previousBatch {
                stall += 1
                if stall >= 3 {
                    log("the queue is no longer moving (\(batch.count) page(s) "
                        + "unchanged over 3 batches): stopping rather than "
                        + "spinning")
                    return false
                }
            } else {
                stall = 0
            }
            previousBatch = signature
        }
    }

    // MARK: - Traitement d'un lot

    struct BatchResult { let stoppedByBudget: Bool }

    static func process(items: [Item], store: GRDBStore, renderer: any PageRenderer,
                        engine: any OCREngine, languages: [String],
                        customWords: [String], jobs: Int,
                        governor: ThermalGovernor, deadline: Date?,
                        counters: Counters, harvest: VocabHarvest,
                        log: @escaping @Sendable (String) -> Void,
                        shouldStop: @escaping @Sendable () -> Bool = { false })
        -> BatchResult {
        guard !items.isEmpty else { return BatchResult(stoppedByBudget: false) }

        let cursor = Cursor(limit: items.count)
        let group = DispatchGroup()
        // QoS .utility : l'OCR est du travail de fond, il ne dispute pas la main
        // à l'interface (§6.3).
        let queue = DispatchQueue(label: "fouine.ocr.workers", qos: .utility,
                                  attributes: .concurrent)

        for worker in 0..<max(1, jobs) {
            queue.async(group: group) {
                while true {
                    // Budget : on ne PREND plus de page passé l'échéance ; celles
                    // qui sont en vol se terminent (§6.3). L'arrêt demandé par
                    // l'appelant (« Annuler » de l'app, audit A10.2) emprunte le
                    // même chemin, et donc les mêmes garanties : fin de page
                    // propre, aucune transaction coupée, file intacte.
                    if let deadline, Date() >= deadline {
                        cursor.stopForBudget()
                        return
                    }
                    if shouldStop() {
                        cursor.stopForBudget()
                        return
                    }
                    // Le portillon rend la main si l'échéance tombe pendant une
                    // suspension thermique : sinon le budget ne serait jamais vu.
                    guard governor.admit(worker: worker, deadline: deadline) else {
                        if let deadline, Date() >= deadline { cursor.stopForBudget() }
                        return
                    }
                    guard let index = cursor.next() else { return }
                    let item = items[index]
                    autoreleasepool {
                        handle(item, store: store, renderer: renderer, engine: engine,
                               languages: languages, customWords: customWords,
                               counters: counters, harvest: harvest, log: log)
                    }
                }
            }
        }
        group.wait()
        return BatchResult(stoppedByBudget: cursor.stoppedByBudget)
    }

    /// UNE page. Toute erreur ici se solde par `failOCR` et par la page suivante :
    /// un PDF illisible ne fait pas tomber le lot (piège n°13).
    static func handle(_ item: Item, store: GRDBStore, renderer: any PageRenderer,
                       engine: any OCREngine, languages: [String],
                       customWords: [String],
                       counters: Counters, harvest: VocabHarvest,
                       log: @Sendable (String) -> Void) {
        do {
            let image = try renderer.render(url: URL(fileURLWithPath: item.path),
                                            page: item.page,
                                            dpi: FouinePageRenderer.defaultDPI)
            let result = try engine.recognize(image, level: .accurate,
                                              languages: languages,
                                              customWords: customWords)
            try store.completeOCR(docID: item.docID, page: item.page, result: result)
            counters.completed(seconds: result.seconds, characters: result.text.count)
            // Le vocabulaire de la page N'ENTRE dans vocab_tri que si la page est
            // entrée dans page_fts : `completeOCR` n'indexe rien sous
            // `minIndexedCharacters` (§6.2). Proposer à l'expansion floue un
            // voisin absent de l'index serait pire que de ne rien proposer.
            if result.text.count >= GRDBStore.minIndexedCharacters,
               harvest.record(result.text) {
                // Récolte trop grosse pour attendre la fin du lot : on la verse
                // ici même. Quelques millisecondes, sur le fil qui vient d'écrire.
                warmHarvest(store: store, harvest: harvest, counters: counters,
                            log: log)
            }
        } catch {
            counters.failed()
            log("page \(item.page) of \(item.path): \(describe(error))")
            do {
                try store.failOCR(docID: item.docID, page: item.page)
            } catch {
                // La base elle-même ne répond plus : on le dit, on n'insiste pas.
                log("could not record the failure "
                    + "(doc \(item.docID), page \(item.page)): \(describe(error))")
            }
        }
    }

    // MARK: - vocab_tri

    /// Alimentation de `vocab_tri` en fin de lot et en fin de run.
    ///
    /// AVANT (audit A2) : `warm(force: true)` balayait `fts5vocab(page_fts)` en
    /// entier — 1,5 M de termes, 18 à 25 s — à la fin de CHAQUE lot de 10 min,
    /// pendant que `group.wait()` tenait les quatre fils Vision à l'arrêt
    /// complet, et pour insérer zéro terme dans l'immense majorité des cas
    /// (`vocab` = `vocab_seen` = `vocab_tri`, 0 terme manquant, mesuré).
    ///
    /// MAINTENANT : le run a le texte en main, il ne vérifie QUE ses propres
    /// termes. Le balayage global reste joignable par FOUINE_OCR_VOCAB_SCAN=1 et
    /// s'exécute de toute façon en fin de passe d'indexation (§5.1).
    static func warmHarvest(store: GRDBStore, harvest: VocabHarvest,
                            counters: Counters, log: (String) -> Void,
                            force: Bool = false) {
        if vocabFullScan {
            warm(store: store, counters: counters, log: log, force: force)
            return
        }
        let texts = harvest.drain()
        if !texts.isEmpty {
            do {
                let inserted = try TrigramExpander(store: store).warm(texts: texts)
                harvest.tally(inserted: inserted, pages: texts.count)
            } catch {
                log("cannot feed vocab_tri: \(describe(error))")
            }
        }
        // UNE ligne par lot, pas une par vidage (A2-12). La récolte se vide
        // tous les ~1 Mio de texte reconnu, c'est-à-dire toutes les seize
        // pages en pratique : sur le journal réel du 01 au 03/09, ce message
        // faisait 44 % des LIGNES et 45 % des octets, et l'incident qu'on
        // cherche dedans était une aiguille dans une meule.
        guard force, let bilan = harvest.takeTally(), bilan.inserted > 0 else { return }
        log("vocab_tri: \(bilan.inserted) new term(s) added from "
            + "\(bilan.pages) OCR'd page(s)")
    }

    /// Balayage GLOBAL de `fts5vocab`. Conservé pour la CLI et pour l'échappatoire
    /// FOUINE_OCR_VOCAB_SCAN ; ce n'est plus le chemin normal de la pompe.
    static func warmIfDue(store: GRDBStore, counters: Counters,
                          log: (String) -> Void) {
        warm(store: store, counters: counters, log: log, force: false)
    }

    static func warm(store: GRDBStore, counters: Counters, log: (String) -> Void,
                     force: Bool) {
        guard counters.takeWarmDebt(threshold: warmEveryPages, force: force) else {
            return
        }
        do {
            try TrigramExpander(store: store).warm()
        } catch {
            log("cannot refill vocab_tri: \(describe(error))")
        }
    }

    // MARK: - Résumé

    static func summarize(counters: Counters, started: Date,
                          governor: ThermalGovernor, log: (String) -> Void) {
        let snapshot = counters.snapshot()
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        let rate = Double(snapshot.completed) / elapsed
        var line = String(
            format: "OCR: %d page(s) done, %d failure(s), %.3f p/s, %@",
            snapshot.completed, snapshot.failed, rate, duration(elapsed))
        if snapshot.completed > 0 {
            line += String(format: " (median engine %.2f s/page, %d characters indexed)",
                           snapshot.medianSeconds, snapshot.characters)
        }
        if governor.suspendedSeconds >= 1 {
            line += String(format: " — %@ of thermal pause",
                           duration(governor.suspendedSeconds))
        }
        log(line)
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        if seconds < 3600 {
            return String(format: "%d min %02d s", Int(seconds) / 60, Int(seconds) % 60)
        }
        return String(format: "%d h %02d min", Int(seconds) / 3600,
                      (Int(seconds) % 3600) / 60)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as FouineError:
            switch e {
            case .volumeNotMounted(let uuid): return "volume not mounted (\(uuid))"
            case .rootUnreadable(let path, let raw):
                // Le motif est un enregistrement sans langue (palier 3.5) :
                // sans ce rendu, le journal afficherait le jeton brut.
                return "\(path) is unreadable: "
                    + (RootProbe.reason(raw)?.english ?? raw)
            case .databaseFailure(let m):
                // Idem pour le verrou occupé (`fouine-lock-busy`, palier 3.2).
                if let busy = WriteLock.busy(e) {
                    guard let holder = busy.holder else {
                        return "database locked by another process "
                            + "(\(busy.path))"
                    }
                    return "database locked — " + holder.phrase
                }
                return "database: \(m)"
            case .budgetExhausted(let n): return "budget exhausted (\(n) left)"
            case .unsupported(let ext): return "unsupported format: .\(ext)"
            case .fileTooLarge(let bytes): return "file too large (\(bytes) B)"
            case .extraction(let m): return m
            case .ocr(let m): return m
            case .cancelled: return "stopped before this document was read"
            }
        default:
            return (error as NSError).localizedDescription
        }
    }

    // MARK: - État partagé entre fils

    /// Distribution des pages d'un lot aux fils, et mémoire de l'arrêt budgétaire.
    final class Cursor: @unchecked Sendable {
        private let mutex = NSLock()
        private let limit: Int
        private var index = 0
        private var budgetStop = false

        init(limit: Int) { self.limit = limit }

        func next() -> Int? {
            mutex.lock(); defer { mutex.unlock() }
            guard index < limit else { return nil }
            defer { index += 1 }
            return index
        }

        func stopForBudget() {
            mutex.lock(); budgetStop = true; mutex.unlock()
        }

        /// Le budget n'a mordu que s'il RESTE des pages non distribuées : une
        /// échéance atteinte sur un lot déjà consommé n'est pas une interruption.
        var stoppedByBudget: Bool {
            mutex.lock(); defer { mutex.unlock() }
            return budgetStop && index < limit
        }
    }

    /// Le texte reconnu pendant le lot en cours, en attente d'être versé dans
    /// `vocab_tri` (audit A2). Écrit par les quatre fils, vidé entre les lots.
    ///
    /// Borné : au-delà de `flushBytes` accumulés, `record` le signale et le fil
    /// qui vient d'écrire vide lui-même la récolte. Sans cela, un
    /// `fouine ocr --only <gros livre>` — qui traite tous ses items en UN seul
    /// `process` — garderait plusieurs dizaines de mégaoctets de texte en
    /// mémoire jusqu'à la fin du run.
    final class VocabHarvest: @unchecked Sendable {
        /// ~1 Mio de texte reconnu, soit quelques centaines de pages.
        static let flushBytes = 1 << 20

        private let mutex = NSLock()
        private var texts: [String] = []
        private var bytes = 0
        /// Cumul des vidages du lot, pour la ligne de bilan (A2-12).
        private var insertedTotal = 0
        private var pagesTotal = 0

        /// Rend `true` si la récolte doit être vidée sans attendre la fin du lot.
        @discardableResult
        func record(_ text: String) -> Bool {
            mutex.lock(); defer { mutex.unlock() }
            texts.append(text)
            bytes += text.utf8.count
            return bytes >= Self.flushBytes
        }

        func drain() -> [String] {
            mutex.lock(); defer { mutex.unlock() }
            let out = texts
            texts.removeAll(keepingCapacity: true)
            bytes = 0
            return out
        }

        /// Compte un vidage sans rien journaliser.
        func tally(inserted: Int, pages: Int) {
            mutex.lock(); defer { mutex.unlock() }
            insertedTotal += inserted
            pagesTotal += pages
        }

        /// Le bilan du lot, remis à zéro : deux appels ne font pas deux lignes.
        func takeTally() -> (inserted: Int, pages: Int)? {
            mutex.lock(); defer { mutex.unlock() }
            guard pagesTotal > 0 else { return nil }
            let out = (inserted: insertedTotal, pages: pagesTotal)
            insertedTotal = 0
            pagesTotal = 0
            return out
        }
    }

    final class Counters: @unchecked Sendable {
        struct Snapshot {
            let completed: Int, failed: Int, characters: Int, medianSeconds: Double
        }

        private let mutex = NSLock()
        private var completedCount = 0
        private var failedCount = 0
        private var characterCount = 0
        private var sinceWarm = 0
        private var durations: [Double] = []

        func completed(seconds: Double, characters: Int) {
            mutex.lock()
            completedCount += 1
            characterCount += characters
            sinceWarm += 1
            durations.append(seconds)
            mutex.unlock()
        }

        func failed() {
            mutex.lock(); failedCount += 1; mutex.unlock()
        }

        /// Rend `true` — et remet le compteur à zéro — s'il faut réalimenter
        /// `vocab_tri`. `force` sert la fin de run.
        func takeWarmDebt(threshold: Int, force: Bool) -> Bool {
            mutex.lock(); defer { mutex.unlock() }
            guard sinceWarm > 0 else { return false }
            guard force || sinceWarm >= threshold else { return false }
            sinceWarm = 0
            return true
        }

        func snapshot() -> Snapshot {
            mutex.lock(); defer { mutex.unlock() }
            let sorted = durations.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            return Snapshot(completed: completedCount, failed: failedCount,
                            characters: characterCount, medianSeconds: median)
        }
    }
}
