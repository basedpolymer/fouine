// AppModel.swift — état global : racines, TCC, statistiques, agent, indexation.
// Propriété : A-App. SPEC §5.6, §7.1, §11.2.

import Foundation
import SwiftUI
import AppKit
import OSLog
import UniformTypeIdentifiers
import ServiceManagement
import FouineCore
import FouineCrawl
import FouineEmbed
import FouineIndex

/// État d'une racine tel que l'interface doit le montrer : montée, lisible, et
/// pourquoi pas (§5.6, « ne jamais planter, ne jamais vider l'affichage »).
struct RootStatus: Identifiable, Equatable {
    var id: Int64 { record.id }
    let record: RootRecord
    var absolutePath: String?
    var mounted: Bool
    var readable: Bool
    var reason: String?

    var label: String { record.label }

    static func == (a: RootStatus, b: RootStatus) -> Bool {
        a.id == b.id && a.mounted == b.mounted && a.readable == b.readable
            && a.absolutePath == b.absolutePath && a.reason == b.reason
            && a.record.enabled == b.record.enabled
            && a.record.label == b.record.label
    }
}

/// Les journaux s'adressent aux dépanneurs : anglais, comme le reste. AU
/// NIVEAU DU FICHIER : une propriété statique d'une classe `@MainActor` est
/// elle-même isolée, et la remise à Spotlight tourne sur un fil de fond.
private let spotlightLog = Logger(subsystem: "io.github.basedpolymer.fouine",
                                  category: "spotlight")

/// Message d'alerte des gestes de gestion des racines (D1).
struct RootNotice: Equatable {
    let title: String
    let message: String
    /// Le refus se répare : l'alerte porte alors « Ouvrir les Réglages
    /// Système » et « Réessayer » à côté d'« OK » (AP-01).
    ///
    /// C'EST UN CHAMP, PAS UNE ANALYSE DU TEXTE. La nature du refus se sait là
    /// où il est fabriqué ; relire la phrase affichée pour la deviner serait
    /// juste jusqu'à la première traduction. Sans ces deux boutons, le mode
    /// d'échec numéro un du produit — l'invite de macOS refusée au premier
    /// dossier — laissait un « OK », un écran d'accueil vide et aucun chemin
    /// vers les Réglages Système.
    var offersRecovery = false
    /// Le dossier refusé est celui d'une application que Fouine sait lire
    /// (Anki, Apple Notes, Bear) : l'alerte porte « Ouvrir les Réglages », sur
    /// l'onglet où se trouve la case de l'application. Un champ, pour la même
    /// raison qu'`offersRecovery`.
    var offersApplicationSettings = false

    /// Une erreur d'ajout de dossier se répare-t-elle dans les Réglages
    /// Système ? Oui pour une lecture refusée (autorisation, droits du
    /// fichier), non pour un dossier disparu ou vide, où il n'y a rien à
    /// autoriser.
    static func offersRecovery(for error: Error) -> Bool {
        guard case .rootUnreadable(_, let raw)? = error as? FouineError else {
            return false
        }
        switch RootProbe.reason(raw) {
        case .permissionDenied, .system: return true
        case .missing, .noReadableFile, .none: return false
        }
    }

    static func offersRecovery(for refusal: RootPolicy.Refusal) -> Bool {
        switch refusal {
        case .permissionDenied, .unreadable: return true
        case .missing, .notADirectory, .wholeDisk, .homeDirectory,
             .privateFolder, .systemTree, .applicationData:
            return false
        }
    }

    static func offersApplicationSettings(for refusal: RootPolicy.Refusal) -> Bool {
        if case .applicationData = refusal { return true }
        return false
    }
}

@MainActor
final class AppModel: ObservableObject {

    let service: StoreService

    @Published var openError: String?
    /// Issue d'une restauration de sauvegarde depuis l'écran d'échec
    /// d'ouverture (B1-14) : succès (avec le nom de la base écartée) ou refus.
    /// Affichée en alerte au niveau de la fenêtre, effacée à la fermeture.
    @Published var restoreNotice: RestoreNotice?
    /// Échec de LECTURE des racines (≠ index vierge). Sans lui, un `try?` avalé
    /// affichait « Aucune racine enregistrée » et faisait perdre le diagnostic —
    /// TCC, base verrouillée, schéma illisible (audit A10.7).
    @Published var rootsError: String?
    @Published var roots: [RootStatus] = []
    /// Refus de `RootPolicy`, avertissement Téléchargements ou échec d'un geste
    /// de gestion des racines. Affiché en alerte, effacé à la fermeture. Le titre
    /// voyage avec le texte : « non ajouté » et « à savoir » ne se disent pas
    /// sous le même en-tête.
    @Published var rootNotice: RootNotice?
    @Published var stats: [String: Int] = [:]
    /// La place libre sur le volume de l'index, relue avec `stats` ; `nil`
    /// tant qu'elle n'a pas été lue ou si le volume ne répond pas.
    @Published var diskFreeBytes: Int?
    /// Bandeau persistant de refus TCC (§7.1). Nil = rien à signaler.
    @Published var tccBanner: String?
    @Published var firstRunProbeDone: Bool =
        Prefs.defaults.bool(forKey: Prefs.firstRunProbeDone)

    // Agent d'arrière-plan (§5.7, §11.2)
    @Published var backgroundIndexing = false
    /// Ce qu'a répondu le dernier geste sur l'interrupteur : une confirmation
    /// ou un problème (IX2). La carte ne montre que les problèmes, la fenêtre
    /// « Votre index » les deux.
    @Published var agentMessage: AutomaticUpdatesMessage?
    /// État opérationnel combinant SMAppService et agent_status (B1-05).
    @Published var agentOperationalState: AgentOperationalState = .off
    /// Date d'armement de l'agent dans cette session (pour les 5 premières minutes).
    @Published var agentEnabledAt: Date?
    /// Ce que l'agent FAIT, lu dans `agent_status` (audit F7).
    ///
    /// « `agentStatusText` ne dit jamais ce que l'agent fait ni où en est la
    /// file ; pour un travail de vingt heures, c'est le point d'abandon le plus
    /// probable. » `nil` = aucun agent n'a jamais écrit sur cette base.
    @Published var agentStatus: AgentStatusRecord?
    /// Vrai pendant que la fenêtre est au premier plan : la sonde bat alors
    /// toutes les 2 s, sinon toutes les 30 s.
    private(set) var agentStatusTask: Task<Void, Never>?
    /// Dernier état vu, pour ne notifier qu'aux TRANSITIONS.
    private var lastSeenAgentPhase: String?

    /// État de santé à quatre lignes (audit H4).
    @Published private(set) var healthReport: HealthBannerReport = HealthBannerEvaluator.evaluate(
        agentState: .off,
        lockStatus: .free,
        semanticInstalled: false,
        hasVectors: false,
        roots: []
    )
    private(set) var healthProbeTask: Task<Void, Never>?

    // Indexation manuelle
    @Published var indexing = IndexingState()

    // L'état unique de l'index (session UX du 04/09/2026)

    /// Vrai dès que la base est ouverte et les racines lues : `ContentView`
    /// n'affiche rien de décidé avant — ni l'écran d'accueil, ni les trois
    /// panneaux. Sans ce fanion, l'accueil « Bienvenue » s'affichait une
    /// fraction de seconde à chaque lancement, le temps de lire les racines.
    @Published private(set) var isReady = false
    /// Vrai après la première lecture d'`agent_status` : avant, la carte
    /// « Index » dit « Vérification… » au lieu d'un état deviné — c'était le
    /// bouton « Ré-enregistrer » qui apparaissait deux secondes au démarrage.
    private(set) var agentProbed = false
    /// Ce que la carte « Index » et la fenêtre « Votre index » affichent. Recalculé à
    /// chaque rafraîchissement d'une de ses entrées (`refreshIndexStatus`).
    @Published private(set) var indexStatus: IndexStatus = .checking
    /// Débit de la phase courante de l'agent, pour « environ 2 h restantes ».
    private var rateEstimator = IndexRateEstimator()

    /// Pages ajoutées depuis la dernière fois que Fouine a été ouverte (UX-06),
    /// ou `nil` : première visite, ou aucun progrès. Dit dans la fenêtre
    /// « Votre index », sans croix pour la refermer : on ouvre cette fenêtre
    /// pour lire, la nouvelle n'y dérange personne (IX2).
    ///
    /// C'est la seule récompense visible d'un travail qui se fait sans témoin :
    /// l'agent tourne fenêtre fermée, et rien ne le disait au retour.
    @Published private(set) var sinceLastVisitPages: Int?

    /// Le compte de pages relevé à la visite précédente. Clé PRIVÉE : elle ne
    /// décrit rien que l'utilisateur puisse régler, elle n'a donc rien à faire
    /// dans `Prefs`.
    private static let lastVisitPagesKey = "app.lastVisit.pagesIndexed"

    // `dismissSinceLastVisit()` a été retiré (IX2) : la nouvelle a quitté la
    // barre latérale pour la fenêtre « Votre index », où elle n'a pas de croix.

    // MARK: - Les pages scannées sans texte lisible (IX2)

    /// Ce que la fenêtre « Votre index » dit des pages scannées lues sans texte
    /// sûr, ou `nil`.
    ///
    /// Le geste « Les relire » (PR-24) et son accusé « … seront relues » ont
    /// été retirés : la relecture en masse passe par le même moteur, avec les
    /// mêmes réglages, et rend le même résultat — mesuré sur la production le
    /// 12/09/2026 (`ScannedPagesWithoutText`). `fouine ocr requeue` reste, pour
    /// les dépanneurs.
    var scannedPagesWithoutText: ScannedPagesWithoutText? {
        ScannedPagesWithoutText.of(noLines: stats["pages_ocr_no_lines"] ?? 0,
                                   doubtful: stats["pages_ocr_low_conf"] ?? 0)
    }

    // MARK: - Recherche par le sens (UX-12)

    /// Où en est la préparation de la recherche par le sens, et ce qu'il en
    /// reste. `nil` tant qu'on ne l'a pas demandé (c'est trois comptes en base,
    /// on ne les paie qu'à l'ouverture de la feuille ou de l'onglet).
    struct MeaningReadiness: Equatable {
        /// Pages entièrement préparées.
        var ready: Int
        /// Pages indexées, c'est-à-dire le total à préparer.
        var total: Int
        /// Heures de travail restantes au débit de la dernière passe, ou `nil`
        /// : aucune passe n'a encore tourné, donc rien de sincère à annoncer.
        var remainingHours: Double?

        var left: Int { max(0, total - ready) }
        var isComplete: Bool { total > 0 && left == 0 }
    }

    @Published private(set) var meaning: MeaningReadiness?

    /// Relit l'avancement de la préparation, hors du fil principal.
    ///
    /// Mesuré sur une copie de la base de production : 7 ms pour les pages
    /// indexées, 24 ms pour les pages prêtes, 48 ms pour la projection en
    /// heures. C'est le prix d'une ouverture de feuille, pas celui d'une sonde.
    func refreshMeaningReadiness() async {
        let store = service.store
        let fresh = await Task.detached(priority: .utility)
            { () -> MeaningReadiness? in
            guard let indexed = try? store.indexedPageCount(),
                  let forecast = try? store.embedForecast() else { return nil }
            return MeaningReadiness(
                ready: max(0, indexed - forecast.incompletePages),
                total: indexed, remainingHours: forecast.remainingHours)
        }.value
        // Une lecture qui échoue ne DOIT PAS effacer ce qui est affiché
        // (§5.6, « ne jamais vider l'affichage »).
        guard let fresh else { return }
        meaning = fresh
    }

    /// Feuille affichée, s'il y en a une.
    ///
    /// UNE seule feuille est attachée à la vue (audit A10.6) : deux `.sheet`
    /// empilés sur le même conteneur, avec des transitions qui basculent les deux
    /// drapeaux dans le même cycle de rafraîchissement, sont le cas d'école où la
    /// seconde ne s'ouvre pas. Ici, passer de l'indexation à la proposition d'OCR
    /// n'est qu'un changement de contenu DANS la feuille déjà présentée.
    enum Sheet: Equatable {
        case indexing
        case ocrPrompt
        /// « Préparer la recherche par le sens » (UX-12) : ce que la passe
        /// fait, où elle en est, combien de temps on lui donne.
        case prepareMeaning
        /// « Désinstaller Fouine… » (audit D13). Une feuille et non une alerte :
        /// elle porte trois cases à cocher et une demi-douzaine de chemins.
        case uninstall
        /// Un lien `fouine://` a désigné un document que Fouine ne connaît pas
        /// (lot INT-L1) : déplacé, retiré d'une racine, ou index reconstruit
        /// depuis. `canOpen` décide du bouton « Ouvrir le fichier » — et il
        /// n'est vrai que pour un document sous un dossier suivi (BU-01).
        case unknownDocument(path: String, canOpen: Bool)
    }
    @Published var sheet: Sheet?

    /// Le lien `fouine://` reçu avant l'ouverture de l'index (lot INT-L1).
    ///
    /// macOS remet le lien dès le lancement, souvent AVANT que `start()` ait
    /// ouvert la base : le résoudre à cet instant rendrait « document
    /// inconnu » pour une page parfaitement indexée. La décision est dans
    /// `DeepLinkQueue`, testée ; il ne reste ici que l'état.
    private var deepLinks = DeepLinkQueue()

    /// Rend le lien à traiter TOUT DE SUITE, ou `nil` s'il attend l'ouverture.
    func submitDeepLink(_ url: URL) -> URL? {
        deepLinks.submit(url, isReady: isReady)
    }

    /// Le lien mis en attente, une seule fois — à appeler après `start()`.
    func resumeDeepLink() -> URL? {
        deepLinks.resume()
    }

    // MARK: - Ce que macOS remet à l'application (lot DD2)

    /// Les URL remises par le système et pas encore traitées : un lien
    /// `fouine://`, un dossier lâché sur l'icône du Dock.
    ///
    /// POURQUOI UNE BOÎTE AUX LETTRES, ET PAS UN APPEL DIRECT. Les deux chemins
    /// de livraison — le délégué d'application et `.onOpenURL` — arrivent l'un
    /// avant la fenêtre, l'autre depuis elle ; et le dépôt peut tomber alors
    /// que la fenêtre principale est fermée (Fouine vit dans la barre des
    /// menus, UX-08). L'état attend donc ici, où il survit à l'absence de vue,
    /// et la vue le vide dès qu'elle est là.
    @Published private(set) var openedURLs: [URL] = []

    /// La double livraison de la même URL, écartée (voir `RecentOpenedURLs`).
    private var openedGuard = RecentOpenedURLs()

    /// Ce que le Finder ou le Dock viennent de remettre.
    func submitOpenedURLs(_ urls: [URL], now: Date = Date()) {
        for url in urls where openedGuard.accept(url, now: now) {
            openedURLs.append(url)
        }
    }

    /// Les URL à traiter, une seule fois.
    ///
    /// RIEN TANT QUE L'INDEX N'EST PAS OUVERT : les racines ne sont pas encore
    /// lues, et un dossier parfaitement suivi passerait pour inconnu — Fouine
    /// proposerait de l'ajouter une seconde fois. Elles restent en boîte, et la
    /// vue repasse à l'ouverture.
    func takeOpenedURLs() -> [URL] {
        guard isReady, !openedURLs.isEmpty else { return [] }
        defer { openedURLs = [] }
        return openedURLs
    }

    /// La confirmation en attente d'un dossier déposé sur l'icône du Dock.
    ///
    /// Plusieurs dossiers lâchés d'un coup tiennent dans UNE demande : trois
    /// alertes à la file pour un seul geste seraient trois fois le même
    /// dérangement.
    struct FolderAddRequest: Equatable {
        var urls: [URL]
        /// Le nom du dossier quand il n'y en a qu'un — jamais son chemin.
        var name: String { urls.first?.lastPathComponent ?? "" }
    }
    @Published var folderAddRequest: FolderAddRequest?

    /// Un dossier remis par le système : ce qu'il faut en faire.
    ///
    /// La DÉCISION est pure (`FolderDropDecision`) et le regard sur le disque
    /// est ici ; les gestes qu'elle appelle — amener la fenêtre devant, poser
    /// le filtre dans le champ de recherche — vivent dans la vue, seule à avoir
    /// l'environnement SwiftUI qu'ils réclament.
    @discardableResult
    func handleOpenedFolder(url: URL) -> FolderDropDecision.Decision {
        let known = roots.compactMap { status in
            status.absolutePath.map {
                DroppedFolderRoot(label: status.label, path: $0)
            }
        }
        let decision = FolderDropDecision.decide(
            url: url, kind: DeepLinkRouter.probeFileSystem(url.path), roots: known)
        if case .proposeAdd(let folder) = decision {
            var request = folderAddRequest ?? FolderAddRequest(urls: [])
            guard !request.urls.contains(folder) else { return decision }
            request.urls.append(folder)
            folderAddRequest = request
        }
        return decision
    }

    /// « Ajouter ce dossier » : le même chemin que la barre latérale et le
    /// panneau d'ouverture (`addRoots`), refus et avertissements compris.
    func confirmFolderAdd() {
        guard let request = folderAddRequest else { return }
        folderAddRequest = nil
        Task { await addRoots(urls: request.urls) }
    }

    /// Raccourci global ⌥⌘F : `nil` tant qu'on n'a pas essayé de l'enregistrer,
    /// `false` si le système a refusé (audit A10.10 — l'échec était muet).
    @Published var globalHotKeyAvailable: Bool?

    private var indexingService: IndexingService?

    /// Le démarrage en cours, ou fini (audit A10.9, BU-02).
    ///
    /// UNE TÂCHE RETENUE, ET PLUS UN BOOLÉEN. `start()` part désormais du
    /// délégué d'application, c'est-à-dire du seul point de passage commun à
    /// tous les lancements — avec ou sans fenêtre. Le `.task` de la fenêtre,
    /// lui, a encore besoin de savoir QUAND la base est ouverte pour rejouer
    /// la dernière recherche : il rappelle `start()`, qui n'ouvre rien une
    /// seconde fois mais attend que la première ait fini.
    private var startTask: Task<Void, Never>?

    /// Dernier numéro de série d'`IndexingState` appliqué (audit A10.1).
    private var appliedIndexingSeq = 0

    init(service: StoreService) {
        self.service = service
    }

    /// Applique un état d'indexation SI et seulement s'il est plus récent que le
    /// dernier appliqué.
    ///
    /// La sonde de progression de l'OCR publie depuis un fil indépendant, et
    /// chaque publication devient ici un `Task { @MainActor }` NON ordonné : sans
    /// ce garde, une publication retardataire réinstalle `running = true` après
    /// l'état terminal, et l'app est bloquée à vie — feuille infermable
    /// (`interactiveDismissDisabled`), `guard !indexing.running` fermé, boutons de
    /// la barre latérale désactivés (audit A10.1).
    private func apply(_ state: IndexingState) {
        guard state.seq >= appliedIndexingSeq else { return }
        appliedIndexingSeq = state.seq
        indexing = state
        refreshIndexStatus()
    }

    /// Recalcule l'état unique de l'index depuis ce qui vient d'être lu.
    ///
    /// Appelé par chaque rafraîchissement d'entrée (racines, statistiques,
    /// santé, statut de l'agent, passe manuelle) : c'est moins fragile qu'un
    /// `didSet` par propriété, et l'évaluation est pure et instantanée.
    func refreshIndexStatus() {
        indexStatus = IndexStatusEvaluator.evaluate(IndexStatusInput(
            probed: isReady && agentProbed,
            roots: roots, rootsError: rootsError, health: healthReport,
            indexing: indexing, automatic: backgroundIndexing,
            agentState: agentOperationalState, agentStatus: agentStatus,
            scansWaiting: ocrQueueLength,
            agentRemainingSeconds: rateEstimator.remainingSeconds))
    }

    // MARK: - Démarrage

    /// Ouvre la base, enregistre les racines par défaut si l'index est vierge,
    /// puis exécute la sonde TCC du §11.2 étape 1 — dans cet ordre, et AVANT
    /// toute proposition d'enregistrer l'agent.
    ///
    /// IDEMPOTENT ET ATTENDABLE (audit A10.9, BU-02) : les modèles sont portés
    /// par l'`App`, pas par la fenêtre. Une seconde apparition de `ContentView`
    /// rejouerait sinon `open()`, la sonde TCC (invite système) et
    /// `loadVocabulary()` (~4 s de balayage). Le second appelant n'est pas
    /// éconduit pour autant : il ATTEND le premier, sans quoi le `.task` de la
    /// fenêtre reprendrait la main sur une base pas encore ouverte et ne
    /// rejouerait jamais la dernière recherche.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startTask = task
        await task.value
    }

    private func performStart() async {
        do {
            try service.open()
        } catch {
            openError = ErrorText.describe(error)
            return
        }
        // Plus aucune racine implicite (D1) : une base neuve reste vide, et
        // `ContentView` montre l'écran d'accueil au lieu d'une fenêtre morte.
        await refreshRoots(probe: true)
        isReady = true
        // AVANT le premier `refreshStats()`, qui écrase le repère : c'est le
        // compte de la visite PRÉCÉDENTE qu'on veut comparer.
        let pagesAtLastVisit = Self.rememberedPagesIndexed()
        await refreshStats()
        sinceLastVisitPages = SinceLastVisit.added(
            previous: pagesAtLastVisit, current: stats["pages_indexed"] ?? 0)
        await refreshAgentStatus()
        // La PREMIÈRE lecture d'`agent_status` se fait ici, avant tout
        // affichage d'un état : sans elle, l'agent enregistré était tenu pour
        // « silencieux » jusqu'au premier tour de la sonde, et la barre
        // latérale montrait « Ré-enregistrer » pendant deux secondes.
        await refreshAgentActivity()
        agentProbed = true
        await refreshHealth()
        refreshIndexStatus()
        startHealthProbe()
        // Ce que l'agent FAIT, et pas seulement s'il est enregistré (audit F7).
        startAgentStatusProbe()
        service.loadVocabulary()
        // Spotlight (lot INT-S1) : le RATTRAPAGE. Ni la commande `fouine`, ni
        // l'agent d'arrière-plan ne peuvent remettre quoi que ce soit au
        // système — ils n'en sont pas l'exécutable principal, et un processus
        // sans identité de bundle n'a rien à faire dans CoreSpotlight
        // (`SpotlightDonor.isAvailable`, et la leçon de `Notifier`). Tout ce
        // qu'ils indexent attend donc ici, et part au premier lancement de
        // l'application qui suit.
        syncSpotlight()
    }

    // MARK: - Spotlight (lot INT-S1)

    /// Remet à Spotlight ce qui a changé depuis la dernière fois.
    ///
    /// EN TÂCHE DE FOND, et sans rien afficher : le rattrapage n'est pas un
    /// geste de l'utilisateur, il n'a donc pas à occuper l'interface ni à
    /// annoncer son succès. Un échec part dans le journal — le texte est en
    /// base, la recherche de Fouine marche, et la remise se refera.
    ///
    /// - Parameter fullRebuild: tout redonner après avoir tout effacé. C'est
    ///   ce que font le bouton des réglages et un changement de portée ; c'est
    ///   aussi le seul geste qui retire de Spotlight les documents supprimés.
    func syncSpotlight(fullRebuild: Bool = false) {
        let store = service.store
        Task.detached(priority: .background) {
            let policy = SpotlightPolicy(SettingsSnapshot(
                rows: (try? store.settingsRows()) ?? [:]))
            do {
                _ = try SpotlightSync.run(store: store, policy: policy,
                                          donor: SpotlightDonor(),
                                          fullRebuild: fullRebuild)
            } catch {
                spotlightLog.error(
                    "Spotlight: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Ajout, retrait, renommage des racines (D1)

    /// Ajoute des dossiers choisis dans le panneau d'ouverture ou déposés sur la
    /// barre latérale.
    ///
    /// Trois choses dans l'ordre, et pas une de plus :
    ///   1. `RootPolicy` refuse ce qui ne peut pas être une racine — la phrase
    ///      affichée est celle de `fouine root add`, mot pour mot ;
    ///   2. `store.addRoot` résout le volume, SONDE la lisibilité (c'est ce geste
    ///      qui déclenche l'invite TCC, §7.1) et dédoublonne l'étiquette ;
    ///   3. `refreshRoots(probe: true)` remet le bandeau et l'interrupteur
    ///      d'arrière-plan à jour (D2).
    /// Aucune indexation n'est lancée d'autorité : c'est « Indexer maintenant »,
    /// proposé juste à côté, ou l'agent.
    func addRoots(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        var refusals: [String] = []
        var notices: [String] = []
        var added = 0
        // Un seul refus réparable suffit à offrir les deux gestes (AP-01).
        var recoverable = false
        var applicationData = false

        for url in urls {
            if let refusal = RootPolicy.refusal(for: url) {
                refusals.append(RootPolicyText.describe(refusal))
                recoverable = recoverable || RootNotice.offersRecovery(for: refusal)
                applicationData = applicationData
                    || RootNotice.offersApplicationSettings(for: refusal)
                continue
            }
            do {
                _ = try await addRoot(url: url, label: nil)
                added += 1
                if let notice = RootPolicy.advisory(for: url) {
                    notices.append(RootPolicyText.describe(notice))
                }
            } catch {
                refusals.append(String(localized: "“\(url.lastPathComponent)”: \(ErrorText.describe(error))"))
                recoverable = recoverable || RootNotice.offersRecovery(for: error)
            }
        }

        if !refusals.isEmpty {
            rootNotice = RootNotice(
                title: refusals.count == 1
                    ? String(localized: "Folder not added")
                    : String(localized: "Folders not added"),
                message: (refusals + notices).joined(separator: "\n\n"),
                offersRecovery: recoverable,
                offersApplicationSettings: applicationData)
        } else if !notices.isEmpty {
            rootNotice = RootNotice(
                title: String(localized: "Folder added — good to know"),
                message: notices.joined(separator: "\n\n"))
        } else {
            rootNotice = nil
        }
        guard added > 0 else { return }
        await refreshRoots(probe: true)
        await refreshStats()
        await refreshAgentStatus()
        // Rien de neuf côté indexation : on déclenche la passe manuelle qui
        // existe déjà (crawl delta + extraction), avec sa feuille de progression
        // et son bouton « Annuler ». Sans ce départ, un nouvel utilisateur ajoute
        // un dossier, voit une fenêtre de recherche vide, et n'a aucune raison de
        // deviner qu'il lui reste un bouton à trouver dans la barre latérale.
        if !indexing.running { startIndexing() }
    }

    private func addRoot(url: URL, label: String?) async throws -> Int64 {
        let store = service.store
        return try await Task.detached(priority: .userInitiated) {
            try store.addRoot(path: url, label: label)
        }.value
    }

    /// Retire une racine ET son index. `removeRoot` purge les documents sous la
    /// racine (`docs`, `page_fts`, `page_src`, `ocr_queue`) : c'est ce que dit la
    /// confirmation de la barre latérale, et c'est ce qui se passe.
    func removeRoot(_ root: RootStatus) async {
        let store = service.store
        let id = root.id
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.removeRoot(id: id)
            }.value
        } catch {
            rootNotice = RootNotice(title: String(localized: "Removal failed"),
                                    message: ErrorText.describe(error))
            return
        }
        await refreshRoots(probe: false)
        await refreshStats()
    }

    /// Désactive (ou réactive) une racine sans toucher à l'index : ses documents
    /// restent trouvables, plus rien ne les recrawle.
    func setRootEnabled(_ root: RootStatus, _ enabled: Bool) async {
        let store = service.store
        let id = root.id
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.setRootEnabled(id: id, enabled)
            }.value
        } catch {
            rootNotice = RootNotice(title: String(localized: "Change failed"),
                                    message: ErrorText.describe(error))
            return
        }
        await refreshRoots(probe: enabled)
    }

    /// Renomme l'étiquette de facette. Le store met `docs.top_folder` à jour dans
    /// la même transaction, sinon la facette « Dossiers » répondrait encore à
    /// l'ancien nom jusqu'au prochain crawl complet.
    func renameRoot(_ root: RootStatus, to label: String) async {
        let store = service.store
        let id = root.id
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try store.setRootLabel(id: id, label)
            }.value
        } catch {
            rootNotice = RootNotice(title: String(localized: "Rename failed"),
                                    message: ErrorText.describe(error))
            return
        }
        await refreshRoots(probe: false)
    }

    /// Panneau d'ouverture du §D1 : dossiers seulement, sélection multiple, pas
    /// de création de dossier — on choisit un corpus existant, on n'en fabrique
    /// pas un vide.
    func chooseRootsToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose one or more folders to index. Fouine reads them without ever modifying them.")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addRoots(urls: urls) }
    }

    /// Dossiers déposés sur la liste des racines. Les fichiers déposés par erreur
    /// sont écartés ici : `RootPolicy` les refuserait un par un avec la même
    /// phrase, ce qui ferait trois alertes pour un dossier glissé de travers.
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let relevant = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !relevant.isEmpty else { return false }
        Task { [weak self] in
            var urls: [URL] = []
            for provider in relevant {
                guard let url = await Self.loadFileURL(from: provider) else { continue }
                urls.append(url)
            }
            await self?.addRoots(urls: urls)
        }
        return true
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: - Racines et sonde TCC (§7.1, §11.2 étape 1)

    /// `probe: true` LIT RÉELLEMENT un fichier de chaque racine active. C'est ce
    /// geste, et lui seul, qui fait apparaître l'invite « Fouine voudrait accéder
    /// à votre dossier Documents » ; l'agent d'arrière-plan en est incapable.
    func refreshRoots(probe: Bool) async {
        let store = service.store
        let outcome: Result<[RootStatus], Error> = await Task.detached(
            priority: .userInitiated) {
            let records: [RootRecord]
            do { records = try store.roots() } catch { return .failure(error) }
            return .success(records.map { record -> RootStatus in
                let url = try? VolumeResolver.absolutePath(volUUID: record.volUUID,
                                                           relPath: record.relPath)
                guard let url else {
                    return RootStatus(record: record, absolutePath: nil, mounted: false,
                                      readable: false,
                                      reason: String(localized: "disk not plugged in"))
                }
                guard probe, record.enabled else {
                    return RootStatus(record: record, absolutePath: url.path,
                                      mounted: true, readable: record.enabled,
                                      reason: nil)
                }
                do {
                    try RootProbe.probe(url)
                    return RootStatus(record: record, absolutePath: url.path,
                                      mounted: true, readable: true, reason: nil)
                } catch let FouineError.rootUnreadable(_, raw) {
                    // Le motif est un enregistrement sans langue (palier 3.5) :
                    // il devient ici la phrase de la langue de l'utilisateur.
                    return RootStatus(record: record, absolutePath: url.path,
                                      mounted: true, readable: false,
                                      reason: RootProbeText.describe(raw: raw))
                } catch {
                    return RootStatus(record: record, absolutePath: url.path,
                                      mounted: true, readable: false,
                                      reason: ErrorText.describe(error))
                }
            })
        }.value

        let statuses: [RootStatus]
        switch outcome {
        case .success(let list):
            statuses = list
            rootsError = nil
        case .failure(let error):
            // La liste précédente est CONSERVÉE (§5.6, « ne jamais vider
            // l'affichage ») et l'échec est nommé au lieu d'être avalé (A10.7).
            rootsError = String(localized: "Reading the folders failed — \(ErrorText.describe(error))")
            refreshIndexStatus()
            return
        }

        roots = statuses
        refreshIndexStatus()
        guard probe else { return }

        let blocked = statuses.filter { $0.record.enabled && !$0.readable }
        if blocked.isEmpty {
            tccBanner = nil
            if !statuses.isEmpty {
                firstRunProbeDone = true
                Prefs.defaults.set(true, forKey: Prefs.firstRunProbeDone)
            }
        } else {
            let names = blocked
                .map { String(localized: "“\($0.label)”") }
                .joined(separator: ", ")
            let detail = blocked.compactMap(\.reason).first ?? ""
            tccBanner = String(localized: "Fouine cannot read \(names). Results already indexed stay searchable, but preview and indexing are impossible. \(detail.isEmpty ? TCCText.guidance : detail)")
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(AppPaths.privacyFilesPaneURL)
    }

    // MARK: - Statistiques

    /// Un échec de `stats()` ne DOIT PAS effacer les compteurs déjà affichés : la
    /// file OCR retomberait à zéro, le bouton « Lancer l'OCR (N p.) » et le pied
    /// de barre disparaîtraient sans un mot (audit A10.7, même travers que dans
    /// `IndexingService`). On garde la dernière valeur connue.
    func refreshStats() async {
        guard let fresh = try? await service.stats() else { return }
        stats = fresh
        // Au même rythme que les compteurs : un `statfs`, quelques
        // microsecondes, et la carte peut dire si la place manque
        // (`DiskSpaceNotice`). `nil` quand le volume ne répond pas : la carte
        // se tait alors, plutôt que d'annoncer un reste faux.
        diskFreeBytes = AppPaths.freeDiskBytes()
        rememberPagesIndexed(fresh["pages_indexed"] ?? 0)
        refreshIndexStatus()
    }

    var ocrQueueLength: Int { stats["ocr_queue_len"] ?? 0 }

    /// Le poids de l'index et ce qu'il doit encore écrire (MO-03). L'app ne
    /// compare plus ce poids à la taille prévue par la SPEC (décision du
    /// 11/09/2026) : elle s'en sert pour savoir si la place restante suffit à
    /// finir (`DiskSpaceNotice`).
    ///
    /// Calculé depuis `stats`, donc au rythme de `refreshStats` et SANS aucune
    /// lecture nouvelle : les trois nombres nécessaires (taille, pages
    /// indexées, pages entièrement préparées) sont déjà dans le lot que
    /// `stats()` rend, balayage de `page_vec` compris. La géométrie des
    /// fenêtres reste la constante du corpus de production : la mesurer coûte
    /// un second balayage (48 ms) et déplace la projection de moins de 2 %,
    /// ce qui ne change aucun seuil.
    var diskBudget: DiskForecast {
        DiskForecast(bytes: stats["db_bytes"] ?? 0,
                     pagesIndexed: stats["pages_indexed"] ?? 0,
                     pagesFullyVectorised: stats["pages_vec_complete"] ?? 0)
    }

    /// Le repère de la visite précédente, ou `nil` s'il n'y en a jamais eu.
    /// `object(forKey:)` et non `integer(forKey:)` : ce dernier rend 0 pour une
    /// clé absente, ce qui ferait passer la PREMIÈRE visite pour un index
    /// entièrement neuf.
    private static func rememberedPagesIndexed() -> Int? {
        Prefs.defaults.object(forKey: lastVisitPagesKey) as? Int
    }

    /// Zéro n'est jamais mémorisé : une base vide (essai, index effacé) ou une
    /// statistique qui n'a pas répondu remettrait le repère à zéro, et la
    /// visite suivante annoncerait tout l'index comme une nouveauté.
    private func rememberPagesIndexed(_ pages: Int) {
        guard pages > 0 else { return }
        Prefs.defaults.set(pages, forKey: Self.lastVisitPagesKey)
    }

    // MARK: - Agent d'arrière-plan (§5.7, §11.2 étape 2)

    private var agentService: SMAppService {
        SMAppService.agent(plistName: AppPaths.agentPlistName)
    }

    /// D'où vient l'état d'enregistrement de l'agent.
    ///
    /// UNE FERMETURE, ET JAMAIS SUR LE FIL PRINCIPAL (BU-03).
    /// `SMAppService.status` est un aller-retour XPC SYNCHRONE vers `smd` :
    /// lu sur le fil principal toutes les deux secondes par la sonde, il fige
    /// l'interface dès que ce service traîne — 69 échantillons du fil
    /// principal sur 2 484 y étaient encore le 10/09/2026, et 162 sur 162 sur
    /// la machine du propriétaire, où un enregistrement `launchd` orphelin
    /// ralentit `smd` (application figée plus de 100 s). Le test y branche un
    /// faux qui compte ses appels : c'est ainsi qu'on prouve qu'aucun rendu
    /// n'interroge plus le service au passage.
    var readServiceStatus: @Sendable () -> SMAppService.Status = {
        SMAppService.agent(plistName: AppPaths.agentPlistName).status
    }

    /// La lecture, hors du fil principal.
    private func serviceStatus() async -> SMAppService.Status {
        let read = readServiceStatus
        return await Task.detached(priority: .utility) { read() }.value
    }

    func refreshAgentStatus() async {
        let status = await serviceStatus()
        switch status {
        case .enabled:
            backgroundIndexing = true
        case .requiresApproval:
            backgroundIndexing = true
        case .notRegistered, .notFound:
            backgroundIndexing = false
        @unknown default:
            backgroundIndexing = false
        }
        updateOperationalState(serviceStatus: status)
    }

    /// Met à jour l'état opérationnel croisé.
    ///
    /// Le statut lui est DONNÉ (BU-03) : il ne va pas le chercher. C'est la
    /// seule façon de garantir qu'aucun rafraîchissement d'interface ne pose
    /// une question XPC au passage.
    func updateOperationalState(serviceStatus: SMAppService.Status) {
        agentOperationalState = AgentStateMachine.evaluate(
            serviceStatus: serviceStatus,
            switchEnabled: backgroundIndexing,
            agentStatus: agentStatus,
            enabledAt: agentEnabledAt
        )
        refreshIndexStatus()
    }

    // MARK: - Ce que l'agent fait (audit F7)

    /// Sonde `agent_status`. Une seule tâche pour la vie du processus.
    ///
    /// DEUX CADENCES. Fenêtre au premier plan : 2 s, la même que la cadence
    /// d'écriture de l'agent — au pire un battement de retard. Fenêtre au
    /// second plan ou réduite : 30 s, parce que personne ne regarde et qu'une
    /// lecture toutes les deux secondes sur une base de 1,8 Go pour rien est
    /// exactement le genre de dépense qui fait qu'on désinstalle une app.
    func startAgentStatusProbe() {
        guard agentStatusTask == nil else { return }
        agentStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAgentActivity()
                let active = NSApp?.isActive ?? false
                let seconds: UInt64 = active ? 2 : 30
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    func stopAgentStatusProbe() {
        agentStatusTask?.cancel()
        agentStatusTask = nil
    }

    // MARK: - Santé visible (audit H4)

    /// Sonde périodique du bandeau d'état de santé (toutes les 30 s).
    ///
    /// PAS DE SONDE QUAND LA FENÊTRE EST AU FOND (A2-08), même règle que
    /// `startAgentStatusProbe` : personne ne regarde le bandeau, et le tour de
    /// sonde ouvre le verrou, lit `page_vec` et interroge LaunchServices. Rien
    /// n'est perdu — `SidebarView` rafraîchit la santé sur
    /// `didBecomeActiveNotification`, c'est-à-dire au moment exact où le
    /// bandeau redevient visible.
    func startHealthProbe() {
        guard healthProbeTask == nil else { return }
        healthProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self else { return }
                guard NSApp?.isActive ?? false else { continue }
                await self.refreshHealth()
            }
        }
    }

    func stopHealthProbe() {
        healthProbeTask?.cancel()
        healthProbeTask = nil
    }

    /// Rafraîchit l'état des 4 composantes de santé.
    func refreshHealth() async {
        let store = service.store
        let lockPath = FouinePaths.lockURL(for: service.databaseURL).path
        let lockStatus = await Task.detached(priority: .utility) {
            WriteLock.inspect(path: lockPath)
        }.value
        let modelDir = EmbedPaths.modelDirectory()
        let modelInstalled = EmbedPaths.modelAvailable(at: modelDir)
        // EXISTS, pas count(*) (A2-08) : le bandeau ne teste qu'un booléen, et
        // le comptage exact balayait `page_vec` en entier — 0,10 s aujourd'hui,
        // une à deux secondes à campagne finie, toutes les 30 secondes.
        let hasVectors = (try? await Task.detached(priority: .utility) {
            try store.hasAnyVector()
        }.value) ?? ((stats["vectors_vec"] ?? 0) > 0)

        // LaunchServices se lit hors du fil principal : la base de services est
        // sur disque, et l'interroger bloque quelques millisecondes (lot J2).
        let copiesVerdict = await Task.detached(priority: .utility) {
            AppInstallationCheck.currentVerdict()
        }.value

        healthReport = HealthBannerEvaluator.evaluate(
            agentState: agentOperationalState,
            appCopies: copiesVerdict,
            lockStatus: lockStatus,
            semanticInstalled: modelInstalled,
            hasVectors: hasVectors,
            roots: roots
        )
        refreshIndexStatus()
    }

    func performHealthAction(_ action: HealthAction) {
        switch action {
        case .openLoginItems:
            // Le volet où macOS demande l'accord pour l'agent (§11.2 étape 2).
            SMAppService.openSystemSettingsLoginItems()
        case .openPrivacySettings:
            openPrivacySettings()
        case .reregisterAgent:
            reRegisterAgent()
        case .chooseRoots:
            chooseRootsToAdd()
        case .revealInstalledCopy:
            // Le Finder, sur la copie à remplacer : Fouine ne peut pas écrire
            // dans le dossier Applications à la place de l'utilisateur, et un
            // glisser-déposer qu'il fait lui-même est un geste qu'il comprend.
            //
            // DEUX CAS SOUS UN MÊME GESTE (AP-21). Une copie ancienne, ou
            // plusieurs copies : c'est celle du dossier Applications qu'il
            // faut remplacer. Aucune copie installée — l'état « la mise à jour
            // automatique est indisponible », celui de qui ouvre Fouine depuis
            // le DMG ou depuis Téléchargements — : c'est CETTE copie qu'il
            // faut y déposer, et montrer un chemin qui n'existe pas
            // n'ouvrirait rien.
            let installed = URL(fileURLWithPath: AppCopiesProbe.expectedPath)
            let toReveal = FileManager.default.fileExists(atPath: installed.path)
                ? installed : Bundle.main.bundleURL
            NSWorkspace.shared.activateFileViewerSelecting([toReveal])
        }
    }

    /// Le geste de la carte « Index » et de la fenêtre « Votre index ».
    func performIndexAction(_ action: IndexAction) {
        switch action {
        case .updateNow:               startIndexing()
        case .stop:                    cancelIndexing()
        case .readScans:               sheet = .ocrPrompt
        case .addFolder:               chooseRootsToAdd()
        case .openLoginItems:          performHealthAction(.openLoginItems)
        case .openPrivacySettings:     openPrivacySettings()
        case .revealInstalledCopy:     performHealthAction(.revealInstalledCopy)
        case .restartAutomaticUpdates: reRegisterAgent()
        case .retestFolders:           Task { await refreshRoots(probe: true) }
        }
    }

    /// Une lecture d'`agent_status` ET du statut d'enregistrement, toutes deux
    /// hors du fil principal (audit F7, BU-03).
    func refreshAgentActivity() async {
        let store = service.store
        let fresh = await Task.detached(priority: .utility) {
            try? store.agentStatus()
        }.value
        let registration = await serviceStatus()
        // Une lecture qui échoue ne DOIT PAS effacer l'état affiché (§5.6,
        // « ne jamais vider l'affichage ») : on garde le dernier connu.
        guard let fresh else {
            updateOperationalState(serviceStatus: registration)
            return
        }
        agentStatus = fresh
        rateEstimator.observe(fresh)
        updateOperationalState(serviceStatus: registration)
        await notifyIfQueueDrained(fresh)
    }

    /// « L'agent a fini » — la notification que l'audit F7 réclame.
    ///
    /// Elle part de l'APP, jamais de l'agent : un exécutable sans bundle propre
    /// n'a pas d'identité de notification et `UNUserNotificationCenter.current()`
    /// y est un plantage, pas un refus. Conséquence assumée et documentée
    /// (`docs/agent.md`) : si l'app n'est pas ouverte, il n'y a pas de
    /// notification — la file finira de se vider en silence.
    private func notifyIfQueueDrained(_ status: AgentStatusRecord) async {
        // La transition, et non l'état : sans cela, un agent au repos
        // notifierait toutes les deux secondes.
        let signature = status.phase.rawValue + "|" + status.detail
        let previous = lastSeenAgentPhase
        lastSeenAgentPhase = signature
        guard previous != nil, previous != signature else { return }
        guard status.phase == .idle, status.detail == AgentStatusDetail.queueDrained,
              !status.isStale else { return }

        let store = service.store
        let wanted = await Task.detached(priority: .utility) {
            SettingsSnapshot.load(from: store).snapshot.notifyOnQueueDrained
        }.value
        guard wanted else { return }
        Notifier.post(
            title: String(localized: "Fouine — text recognition finished"),
            body: String(localized: "Every scanned page has been read: all your scanned documents are searchable now."))
    }

    /// L'interrupteur n'est actif qu'APRÈS une sonde TCC réussie sur une racine
    /// existante : un agent enregistré avant l'invite est refusé en silence
    /// (§11.2, « ne jamais »).
    ///
    /// Audit D2 : `firstRunProbeDone` n'est posé que si des racines existent, ce
    /// qui laissait l'interrupteur grisé à vie sur une base neuve — il n'y avait
    /// alors aucun moyen d'ajouter une racine. Depuis D1 il y en a un, et le
    /// verrou tombe dès la première racine sondée. `backgroundIndexing` rouvre
    /// l'interrupteur quand l'agent est déjà enregistré : sinon, retirer sa
    /// dernière racine rendrait impossible de l'ARRÊTER.
    var canToggleBackgroundIndexing: Bool {
        backgroundIndexing || (firstRunProbeDone && !roots.isEmpty)
    }

    /// Ce que dit l'infobulle de l'interrupteur : distinguer « pas de racine » de
    /// « racine refusée » évite d'envoyer l'utilisateur cocher une case TCC alors
    /// qu'il n'a encore rien à indexer. L'état d'enregistrement n'y vit plus :
    /// il est affiché directement dans la barre latérale (B1-05).
    var backgroundIndexingHelp: String {
        if canToggleBackgroundIndexing {
            return String(localized: "Fouine checks your folders from time to time and updates the index by itself, even when its window is closed.")
        }
        if roots.isEmpty {
            return String(localized: "Add a folder first.")
        }
        return String(localized: "Available once Fouine is allowed to read your folders.")
    }

    /// Chaque réponse dit sa NATURE (IX2) : un refus ou un échec est un
    /// problème — l'interrupteur revient en arrière, la carte doit dire
    /// pourquoi ; « activée », « désactivée », « relancée » sont des
    /// confirmations, que seule la fenêtre « Votre index » répète.
    func setBackgroundIndexing(_ enabled: Bool) {
        agentMessage = nil
        guard canToggleBackgroundIndexing else {
            agentMessage = .problem(roots.isEmpty
                ? String(localized: "Add a folder first: there would be nothing to keep up to date.")
                : String(localized: "Allow Fouine to read your folders first: it cannot ask for that permission on its own while the window is closed."))
            backgroundIndexing = !enabled
            return
        }
        // Avant d'armer : cette copie de Fouine est-elle celle que macOS
        // ouvrira ? (lot J2). `register()` réussirait quand même, et launchd
        // échouerait ensuite à chaque lancement en figeant une exigence de code
        // qu'aucun ménage ultérieur ne défait.
        if enabled, let refusal = AppInstallationText.describe(AppInstallationCheck.current()) {
            agentMessage = .problem(refusal)
            backgroundIndexing = false
            return
        }
        do {
            if enabled {
                try agentService.register()
                agentEnabledAt = Date()
            } else {
                try agentService.unregister()
                agentEnabledAt = nil
            }
            agentMessage = .confirmation(enabled
                ? String(localized: "Automatic updates are on. macOS may ask you to confirm in System Settings ▸ General ▸ Login Items.")
                : String(localized: "Automatic updates are off. You can still update the index whenever you like."))
        } catch {
            backgroundIndexing = !enabled
            agentMessage = .problem(Self.automaticUpdatesFailure(error))
        }
        // Le statut se relit hors du fil principal (BU-03) : le geste, lui,
        // est déjà fait — l'interrupteur n'attend pas la réponse de `smd`.
        Task { await refreshAgentStatus() }
    }

    /// Ré-enregistre l'agent d'arrière-plan auprès de launchd (B1-05).
    func reRegisterAgent() {
        agentMessage = nil
        guard canToggleBackgroundIndexing else { return }
        // Même garde que sur l'interrupteur (lot J2) : ré-enregistrer depuis
        // une copie qui n'est pas celle que macOS ouvre reproduit la panne.
        if let refusal = AppInstallationText.describe(AppInstallationCheck.current()) {
            agentMessage = .problem(refusal)
            return
        }
        do {
            try? agentService.unregister()
            try agentService.register()
            agentEnabledAt = Date()
            backgroundIndexing = true
            agentMessage = .confirmation(String(localized: "Automatic updates have been restarted. macOS may ask you to confirm in System Settings ▸ General ▸ Login Items."))
        } catch {
            agentMessage = .problem(Self.automaticUpdatesFailure(error))
        }
        Task { await refreshAgentStatus() }
    }

    /// L'échec d'armement, dit dans l'ordre où on le lit : CE QUI SE PASSE et
    /// le geste d'abord, la cause technique entre parenthèses à la fin.
    ///
    /// La phrase commençait par « Failed: … Developer ID … swift run
    /// FouineApp » : trois notions qui n'existent pas pour le public visé,
    /// placées avant la seule chose qui le concerne — Fouine doit être dans le
    /// dossier Applications. La cause reste, parce qu'elle est ce qu'on
    /// recopie dans un rapport de bogue.
    private static func automaticUpdatesFailure(_ error: Error) -> String {
        let cause = (error as NSError).localizedDescription
        return String(localized: "Automatic updates could not be started. Fouine must be installed in the Applications folder. (\(cause) — requires a copy signed with a stable Developer ID; impossible from “swift run FouineApp”.)")
    }

    // MARK: - Indexation manuelle (§5.6)

    /// Pont entre les fils d'`IndexingService` et le fil principal.
    ///
    /// Il est construit ICI, hors du `Task` d'exécution, et pas en fermeture
    /// imbriquée : un `[weak self]` posé À L'INTÉRIEUR d'un autre `Task { [weak
    /// self] }` capture la VARIABLE `self` du `Task` englobant, ce que Swift 6
    /// refuse (`SendableClosureCaptures`, avertissement sur AppModel.swift:313
    /// et :343 avant cette version). La référence faible est prise une fois, et
    /// résolue en constante avant tout saut de domaine de concurrence ;
    /// `AppModel` étant isolé sur `@MainActor`, il est `Sendable`.
    private func progressPublisher() -> @Sendable (IndexingState) -> Void {
        { [weak self] state in
            guard let model = self else { return }
            Task { @MainActor in model.apply(state) }
        }
    }

    func startIndexing() {
        guard !indexing.running else { return }
        let svc = IndexingService(store: service.store)
        indexingService = svc

        // Annoncer le verrou AVANT d'attendre (B1-26).
        let lockPath = FouinePaths.lockURL(for: service.databaseURL).path
        let initialPhase: String
        if case .held(let holder) = WriteLock.inspect(path: lockPath) {
            let who = LockActivityText.describe(holder)
            initialPhase = String(localized: "The index is being updated (\(who)) — waiting for it to finish…")
        } else {
            initialPhase = String(localized: "preparing…")
        }

        service.store.setWriteLockWaitHandler { [weak self] holder, _ in
            let who = LockActivityText.describe(holder)
            let waitingText = String(localized: "The index is being updated (\(who)) — waiting for it to finish…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(IndexingState(running: true, phase: waitingText).stamped())
            }
        }

        apply(IndexingState(running: true, phase: initialPhase).stamped())
        sheet = .indexing
        let publish = progressPublisher()
        Task { [weak self] in
            let outcome = await svc.run(progress: publish)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apply(outcome)
                self.indexingService = nil
            }
            await self?.refreshStats()
        }
    }

    func cancelIndexing() {
        indexingService?.cancel()
        // La phrase IMMÉDIATE, avant toute publication du service : le clic doit
        // répondre dans la seconde. Le service la remplace dès qu'il sait ce
        // qu'il attend — « Arrêt — “cours.mp4” se termine… » (ST1).
        indexing.phase = String(localized: "cancelling…")
        // Et l'état « en cours d'arrêt » TOUT DE SUITE : c'est lui qui désarme
        // le bouton et allume le tourniquet de la carte. Sans cette ligne, le
        // bouton « Stop » restait cliquable, et cliquable plusieurs fois, tant
        // que la passe n'avait pas repris la main.
        indexing.cancelled = true
    }

    func startOCR(budgetMinutes: Int?, only: String? = nil, label: String? = nil) {
        guard !indexing.running else { return }
        let svc = IndexingService(store: service.store)
        indexingService = svc

        // Annoncer le verrou AVANT d'attendre (B1-26).
        let lockPath = FouinePaths.lockURL(for: service.databaseURL).path
        let opening: String
        if case .held(let holder) = WriteLock.inspect(path: lockPath) {
            let who = LockActivityText.describe(holder)
            opening = String(localized: "The index is being updated (\(who)) — waiting for it to finish…")
        } else {
            opening = only == nil
                ? String(localized: "getting ready…")
                : String(localized: "getting ready to read “\(label ?? String(localized: "this document"))”…")
        }

        service.store.setWriteLockWaitHandler { [weak self] holder, _ in
            let who = LockActivityText.describe(holder)
            let waitingText = String(localized: "The index is being updated (\(who)) — waiting for it to finish…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(IndexingState(running: true, phase: waitingText).stamped())
            }
        }

        apply(IndexingState(running: true, phase: opening).stamped())
        // Une seule affectation : la feuille présentée change de contenu, elle ne
        // se ferme pas pour se rouvrir (audit A10.6).
        sheet = .indexing
        let publish = progressPublisher()
        Task { [weak self] in
            let outcome = await svc.runOCR(budgetMinutes: budgetMinutes, only: only,
                                           label: label, progress: publish)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apply(outcome)
                self.indexingService = nil
            }
            await self?.refreshStats()
        }
    }

    /// Lance la préparation de la recherche par le sens (UX-12).
    ///
    /// Calquée sur `startOCR` : le verrou est ANNONCÉ avant d'être attendu
    /// (B1-26), la feuille change de contenu sans se fermer (A10.6), et
    /// « Continuer en arrière-plan » renvoie la progression à la carte
    /// « Index », qui porte « Arrêter ».
    func startPrepareMeaning(budgetMinutes: Int?) {
        guard !indexing.running else { return }
        let svc = IndexingService(store: service.store)
        indexingService = svc

        let lockPath = FouinePaths.lockURL(for: service.databaseURL).path
        let opening: String
        if case .held(let holder) = WriteLock.inspect(path: lockPath) {
            let who = LockActivityText.describe(holder)
            opening = String(localized: "The index is being updated (\(who)) — waiting for it to finish…")
        } else {
            opening = String(localized: "Preparing search by meaning — getting ready…")
        }

        service.store.setWriteLockWaitHandler { [weak self] holder, _ in
            let who = LockActivityText.describe(holder)
            let waitingText = String(localized: "The index is being updated (\(who)) — waiting for it to finish…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(IndexingState(running: true, activity: .preparingMeaning,
                                         phase: waitingText).stamped())
            }
        }

        apply(IndexingState(running: true, activity: .preparingMeaning,
                            phase: opening).stamped())
        sheet = .indexing
        let publish = progressPublisher()
        Task { [weak self] in
            let outcome = await svc.runEmbed(budgetMinutes: budgetMinutes,
                                             progress: publish)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.apply(outcome)
                self.indexingService = nil
            }
            await self?.refreshStats()
            await self?.refreshMeaningReadiness()
        }
    }

    // MARK: - « OCRiser ce document d'abord » (TOP 5 n°4)

    /// La file compte ~34 000 pages, soit ~41,5 h, consommées dans l'ordre des
    /// `doc_id` faute de priorités discriminantes (audit A9) : sans cette action,
    /// obtenir un ouvrage donné demande d'attendre plusieurs jours. `only:` est le
    /// `rel_path` du document, que `OCRRun.resolveDocument` sait résoudre (§8.1) ;
    /// pas de budget, l'exécution est désormais annulable à tout instant (A10.2).
    func startOCR(document row: DocRow) {
        startOCR(budgetMinutes: nil, only: row.record.relPath,
                 label: (row.record.relPath as NSString).lastPathComponent)
    }

    /// Le document a-t-il des pages en file ? `docs.ocr_state` le dit sans requête
    /// supplémentaire : `.queued` = au moins une page en attente, `.partial` = OCR
    /// commencé et pas fini (§4.2).
    func hasQueuedOCR(_ row: DocRow) -> Bool {
        row.record.ocrState == .queued || row.record.ocrState == .partial
    }

    // MARK: - Récupération d'échec d'ouverture (audit H4, B1-14)

    func retryOpen() async {
        openError = nil
        // La tâche de démarrage précédente s'est achevée sur un échec
        // d'ouverture : on l'oublie, sinon `start()` se contenterait de
        // l'attendre — elle est déjà finie — et ne réessaierait rien.
        startTask = nil
        await start()
    }

    func revealDatabaseInFinder() {
        let dbURL = service.databaseURL
        let dir = dbURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dbURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dbURL])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    /// « Diagnostic » : `fouine doctor` par le binaire embarqué, dont la sortie
    /// s'affiche dans une feuille. `nil` quand le binaire n'est pas dans le
    /// bundle (`swift run`) : le bouton ne se montre alors pas.
    func runDiagnostic() async -> BundledDoctor.Output? {
        await BundledDoctor.run(databaseURL: service.databaseURL)
    }

    /// La sauvegarde la plus récente à côté de la base, s'il y en a une qui
    /// RESSEMBLE à une base : nom de sauvegarde (`.db`, `.sqlite`, `.bak`,
    /// « backup », « sauvegarde ») ET en-tête SQLite. Un `-wal`, un `-shm`, un
    /// journal ou une base écartée (`.corrupt-…`) ne sont jamais proposés.
    func availableBackupURL() -> URL? {
        BackupCandidates.mostRecent(nextTo: service.databaseURL)
    }

    /// Efface l'index et rouvre : une base neuve naît au schéma courant.
    ///
    /// LE SEUL CHEMIN DE L'APPLICATION QUI DÉTRUISE L'INDEX, et il n'est
    /// atteignable que par une confirmation qui dit ce qui sera perdu
    /// (`OpenFailureView`). C'est le geste d'un index que Fouine n'ouvre pas —
    /// un autre schéma, un fichier abîmé — et de tout index qu'on décide de
    /// refaire.
    ///
    /// Les journaux `-wal` et `-shm` partent avec la base : laissés en place,
    /// SQLite refuserait la base suivante, qui ne leur appartient pas. Aucun
    /// document de l'utilisateur n'est touché — l'index n'en contient aucun.
    func discardIndexAndStartOver() async throws {
        let dbURL = service.databaseURL
        let fm = FileManager.default
        if fm.fileExists(atPath: dbURL.path) {
            try fm.removeItem(at: dbURL)
        }
        try? fm.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
        await retryOpen()
    }

    /// Restaure `backupURL` à la place de la base courante, puis rouvre.
    ///
    /// La base courante n'est pas détruite : elle est ÉCARTÉE à côté
    /// (`fouine.db.corrupt-<uuid>`), et le message de succès le dit. Si la
    /// copie échoue, la base écartée reprend sa place — sans cela, la
    /// réouverture suivante créerait une base VIDE et l'échec passerait pour
    /// une réussite. L'erreur remonte à l'appelant, qui l'affiche.
    func restoreBackup(from backupURL: URL) async throws {
        let dbURL = service.databaseURL
        let fm = FileManager.default
        let setAside = dbURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        let hadDatabase = fm.fileExists(atPath: dbURL.path)
        if hadDatabase {
            try fm.moveItem(at: dbURL, to: setAside)
        }
        // Les journaux de l'ancienne base ne valent rien pour la nouvelle, et
        // SQLite refuserait un `-wal` qui ne lui appartient pas.
        try? fm.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))

        do {
            try fm.copyItem(at: backupURL, to: dbURL)
        } catch {
            try? fm.removeItem(at: dbURL)
            if hadDatabase { try? fm.moveItem(at: setAside, to: dbURL) }
            throw error
        }
        await retryOpen()
        if openError == nil {
            restoreNotice = RestoreNotice(
                title: String(localized: "Backup restored"),
                message: hadDatabase
                    ? String(localized: "The backup “\(backupURL.lastPathComponent)” is now in use. The previous index was kept next to it, as “\(setAside.lastPathComponent)”; you can delete it once everything works.")
                    : String(localized: "The backup “\(backupURL.lastPathComponent)” is now in use."))
        }
    }
}

/// Ce que l'écran d'échec d'ouverture dit d'une restauration : réussie, avec
/// le nom de la base écartée ; ou refusée, avec l'erreur du système.
struct RestoreNotice: Equatable {
    let title: String
    let message: String
}

/// Les fichiers voisins de la base qui peuvent être une sauvegarde (B1-14).
enum BackupCandidates {
    /// « SQLite format 3\0 » : les seize premiers octets de toute base SQLite.
    static let sqliteHeader = Data("SQLite format 3".utf8) + Data([0])

    static func looksLikeBackupName(_ name: String, databaseName: String) -> Bool {
        guard name != databaseName else { return false }
        let lower = name.lowercased()
        // Les journaux de la base et les bases écartées par une restauration
        // précédente portent le nom de la base : ils ne sont pas des sauvegardes.
        if lower.hasSuffix("-wal") || lower.hasSuffix("-shm") || lower.hasSuffix("-journal") { return false }
        if lower.contains(".corrupt-") { return false }
        let ext = (lower as NSString).pathExtension
        if ["db", "sqlite", "sqlite3", "bak", "backup"].contains(ext) { return true }
        return lower.contains("backup") || lower.contains("sauvegarde")
    }

    static func hasSQLiteHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: sqliteHeader.count) else { return false }
        return head == sqliteHeader
    }

    static func mostRecent(nextTo databaseURL: URL) -> URL? {
        let dir = databaseURL.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let candidates = files.filter { url in
            looksLikeBackupName(url.lastPathComponent, databaseName: databaseURL.lastPathComponent)
                && hasSQLiteHeader(url)
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
        }
        return candidates.max { modified($0) < modified($1) }
    }
}

