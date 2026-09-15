// AgentEmbed.swift — la recherche par le sens se prépare toute seule
// (constat PR-21, décision du 09/09/2026, lot AG1). Propriété : A-Agent.
//
// POURQUOI ICI. `fouine embed` était le SEUL chemin vers la recherche par le
// sens : une commande de terminal, une campagne de trente heures d'un bloc, sur
// un public qui n'ouvre pas de terminal. La carte « Index » disait honnêtement
// « 274 244 sur 408 951 pages sont prêtes · environ 8 h », et c'était tout ce
// qu'elle pouvait dire. L'agent, lui, sait déjà travailler par tranches de dix
// minutes sous les six conditions du §5.7 : c'est exactement le même contrat.
//
// TROIS RÈGLES, ET ELLES SE TIENNENT.
//
//   · L'OCR D'ABORD. Un lot de vecteurs ne part que si la file d'OCR est VIDE.
//     `completeOCR` invalide les vecteurs de la page qu'il réécrit : vectoriser
//     une page scannée avant sa reconnaissance, c'est la vectoriser deux fois.
//   · UN SEUL MOTEUR À LA FOIS. Le verrou de campagne (`EmbedCampaignLock`,
//     C2-11) est pris pour la durée du lot et rendu à la fin : une campagne
//     lancée à la main pendant un lot est refusée en nommant l'agent, et
//     l'agent qui trouve le verrou pris se tait et réessaie au tic suivant.
//   · LE MODÈLE NE RESTE PAS EN MÉMOIRE POUR RIEN. `E5Encoder` pèse ~90 Mio
//     une fois chargé (~1,1 s avec le cache de vocabulaire). Il est gardé entre
//     deux lots CONSÉCUTIFS — recharger toutes les dix minutes coûterait 1,1 s
//     sur 600 — et libéré dès que l'agent se met au repos ou qu'une condition
//     tombe. Sur une machine à 8 Gio, un démon qui garde 90 Mio pour un travail
//     qu'il ne fait plus est un démon qu'on finit par éteindre.

import Foundation
import FouineCore
import FouineEmbed

/// Ce que l'agent sait de la préparation du sens au moment de décider. PUR :
/// c'est l'appelant qui paie les sondes, `tick` n'en voit que le résultat.
public struct AgentEmbedSituation: Equatable, Sendable {
    /// `agent.prepareMeaning`.
    public var enabled: Bool
    /// Le modèle CoreML est installé (`EmbedPaths.modelAvailable`).
    public var modelInstalled: Bool
    /// Une AUTRE campagne tient `fouine-embed.lock`.
    public var campaignHeldByAnother: Bool
    /// Pages indexées qui n'ont pas toutes leurs fenêtres.
    public var pagesLeft: Int

    public init(enabled: Bool = false, modelInstalled: Bool = false,
                campaignHeldByAnother: Bool = false, pagesLeft: Int = 0) {
        self.enabled = enabled
        self.modelInstalled = modelInstalled
        self.campaignHeldByAnother = campaignHeldByAnother
        self.pagesLeft = pagesLeft
    }

    /// Rien à préparer, rien à décider : la valeur par défaut de `tick`.
    public static let none = AgentEmbedSituation()
}

/// Ce que la décision a conclu. Chaque refus PORTE SON NOM : un agent qui ne
/// prépare rien sans jamais dire pourquoi est exactement le défaut qu'on répare.
public enum AgentEmbedVerdict: Equatable, Sendable {
    /// On y va.
    case go
    /// Le réglage est éteint, ou il n'y a rien à préparer : silence.
    case nothingToDo
    case noModel
    case campaignBusy
    /// Une des six conditions du §5.7 n'est pas réunie.
    case waiting(String)

    /// La ligne du journal, ou `nil` quand il n'y a rien à dire.
    public var note: String? {
        switch self {
        case .go: return "meaning: the six conditions of §5.7 are met"
        case .nothingToDo: return nil
        case .noModel:
            return "meaning: the semantic model is not installed — "
                + "`fouine model download` (or turn agent.prepareMeaning off)"
        case .campaignBusy:
            return "meaning: another vectorisation is already running — "
                + "trying again at the next tick"
        case .waiting(let why): return "meaning waiting — " + why
        }
    }
}

/// Issue d'un lot de vecteurs, du point de vue de la décision.
public enum EmbedBatchOutcome: Equatable, Sendable {
    /// Plus une page à préparer.
    case completed
    /// Budget écoulé, il en reste : un autre lot au tic suivant.
    case budgetExhausted
    /// Arrêt demandé (SIGTERM), ou lot en échec : on repasse au repos.
    case stopped
}

// MARK: - Le moteur, gardé juste ce qu'il faut

/// Le moteur d'inférence de l'agent, chargé à la demande et LIBÉRÉ dès le
/// repos. Une seule instance : la file série garantit qu'un seul lot tourne.
final class AgentEmbedder: @unchecked Sendable {

    private let log: AgentLog
    private let mutex = NSLock()
    private var engine: E5Encoder?

    init(log: AgentLog) { self.log = log }

    /// Le moteur, chargé si besoin. `nil` si le modèle ne se charge pas — ce
    /// n'est pas une panne d'agent : on le dit et on passe au tic suivant.
    func engineIfPossible() -> E5Encoder? {
        mutex.lock()
        defer { mutex.unlock() }
        if let engine { return engine }
        do {
            let started = Date()
            let fresh = try E5Encoder(modelDir: EmbedPaths.modelDirectory())
            engine = fresh
            log.info(String(format: "meaning: model loaded in %.1f s",
                            Date().timeIntervalSince(started)))
            return fresh
        } catch {
            log.warn("meaning: the model could not be loaded: "
                     + AgentText.describe(error)
                     + " — nothing is prepared until it is repaired")
            return nil
        }
    }

    /// Rend les ~90 Mio du moteur. Idempotent : appelé à chaque tic qui ne
    /// prépare rien.
    func release() {
        mutex.lock()
        let had = engine != nil
        engine = nil
        mutex.unlock()
        if had { log.info("meaning: model released (agent idle)") }
    }

    var isLoaded: Bool {
        mutex.lock(); defer { mutex.unlock() }; return engine != nil
    }
}

// MARK: - Le lot

extension Agent {

    /// Ce que l'agent sait de la préparation du sens, sondé À LA DEMANDE.
    ///
    /// Le coût est borné par la garde : sans le réglage, sans file d'OCR vide,
    /// aucune sonde n'est payée. Avec, ce sont deux comptes mesurés sur une
    /// copie de la base de production — 7 ms pour les pages indexées, 23 ms
    /// pour les pages complètes — une fois par tour d'horloge (60 s).
    func embedSituation(settings: SettingsSnapshot, ocrQueued: Int)
        -> AgentEmbedSituation {
        guard settings.agentPrepareMeaning, ocrQueued == 0 else { return .none }
        guard EmbedPaths.modelAvailable(at: EmbedPaths.modelDirectory()) else {
            return AgentEmbedSituation(enabled: true, modelInstalled: false)
        }
        let left: Int
        do {
            left = try max(0, store.indexedPageCount() - store.completeVectorPageCount())
        } catch {
            note("meaning: cannot count the pages left: "
                 + AgentText.describe(error))
            return AgentEmbedSituation(enabled: true, modelInstalled: true)
        }
        guard left > 0 else {
            return AgentEmbedSituation(enabled: true, modelInstalled: true,
                                       pagesLeft: 0)
        }
        let busy = store.databaseURL
            .flatMap { EmbedCampaignLock.probe(databaseURL: $0) } != nil
        return AgentEmbedSituation(enabled: true, modelInstalled: true,
                                   campaignHeldByAnother: busy, pagesLeft: left)
    }

    /// UN lot de vecteurs, budgété, sous le verrou de campagne.
    ///
    /// Le verrou est pris ICI et rendu à la fin du lot : entre deux lots, une
    /// campagne lancée à la main peut passer devant — c'est le même arbitrage
    /// que `fouine.lock`, l'utilisateur au clavier passe avant le fond.
    func runEmbedBatch(budgetMinutes: Int, pagesLeft: Int) {
        guard let databaseURL = store.databaseURL else { return }
        let campaign: EmbedCampaignLock
        do {
            campaign = try EmbedCampaignLock.acquire(databaseURL: databaseURL)
        } catch is EmbedCampaignLock.Busy {
            // Course perdue depuis la sonde du tic : on se tait, comme prévu.
            return
        } catch {
            note("meaning: \(AgentText.describe(error))")
            return
        }
        defer { campaign.release() }
        guard let engine = embedder.engineIfPossible() else { return }

        note("meaning: the six conditions of §5.7 are met")
        log.info("meaning: batch of \(budgetMinutes) min, \(pagesLeft) page(s) left")
        let probe = startEmbedProbe(initial: pagesLeft)
        var config = EmbedRun.Config()
        config.budgetMinutes = Double(budgetMinutes)
        // LES MÊMES DOSSIERS QUE LA CLI (lot MC3, constat PM-05). La campagne
        // d'arrière-plan est celle qui tourne vraiment chez l'utilisateur :
        // c'est donc ELLE qui doit commencer par les racines qu'il a mises en
        // premier, sans quoi le réglage ne vaudrait que pour une commande de
        // terminal qu'il n'ouvrira jamais.
        let snapshot = settings.snapshot()
        config.priorityFolders = EmbedRun.pinnedFolderLabels(store: store,
                                                             settings: snapshot)
        if !snapshot.embedSkipSpreadsheets { config.skipExtensions = [] }
        // Le journal de la pompe est celui d'un dépanneur : il part dans le
        // même fichier que le reste, à la même heure, sans préfixe de plus.
        config.log = { [log] line in log.info(line) }

        var summary: EmbedRun.Summary?
        do {
            summary = try EmbedRun.run(store: store, engine: engine,
                                       config: config,
                                       shouldStop: { [weak self] in
                self?.shouldStopEmbedding() ?? true
            })
        } catch {
            log.error("meaning: \(AgentText.describe(error))")
        }
        probe.cancel()
        // Point de repos : `EmbedRun` rend déjà `fouine.lock` après chaque
        // écriture, mais l'agent porte son propre drapeau (§5.7, condition 5).
        releaseWriteLockAfterEmbed()
        markEmbedBatchDone()

        guard let summary else {
            embedder.release()
            execute(action: Self.postEmbedBatchTick(
                state: currentAgentState(), outcome: .stopped,
                remainingPages: pagesLeft, settings: settings.snapshot()).action)
            return
        }
        log.info(String(format:
            "meaning: %d page(s) prepared, %d left, %.0f s",
            summary.embedded, summary.remaining, summary.elapsed))

        let outcome: EmbedBatchOutcome
        if summary.interrupted {
            outcome = .stopped
            log.info("meaning: stopped before the end of the batch — the next "
                     + "batch picks up here")
        } else if summary.remaining == 0 {
            outcome = .completed
            log.info("meaning: every indexed page is ready")
        } else {
            outcome = .budgetExhausted
            log.info("meaning: batch budget reached, \(summary.remaining) "
                     + "page(s) left — the conditions will be decided again "
                     + "for the next batch")
        }
        // Le moteur ne survit qu'à un enchaînement immédiat.
        if outcome != .budgetExhausted { embedder.release() }

        let (action, _) = Self.postEmbedBatchTick(
            state: currentAgentState(), outcome: outcome,
            remainingPages: summary.remaining, settings: settings.snapshot())
        execute(action: action)
        if outcome == .budgetExhausted, !isStopping { requestOCRTick() }
    }

    /// Sonde de progression du lot (même procédé que l'OCR, audit F7).
    ///
    /// Cinq secondes et non deux : un lot d'inférence vaut ~4,8 s, sonder plus
    /// vite n'apprendrait rien et le compte des pages complètes coûte 23 ms.
    private func startEmbedProbe(initial: Int) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: embedProbeQueue)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5),
                       leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopping else { return }
            guard let indexed = try? self.store.indexedPageCount(),
                  let complete = try? self.store.completeVectorPageCount()
            else { return }
            let remaining = max(0, indexed - complete)
            self.status.progress(done: max(0, initial - remaining),
                                 total: initial,
                                 detail: AgentStatusDetail.pagesLeft(remaining))
        }
        timer.resume()
        return timer
    }
}
