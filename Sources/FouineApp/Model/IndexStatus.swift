// IndexStatus.swift — UN état de l'index pour toute l'interface (SPEC §5.6,
// amendement du 04/09/2026 « carte Index »). Propriété : A-App.
//
// Pourquoi. La barre latérale montrait le même sujet à quatre endroits : la
// ligne « indexation en arrière-plan » du bandeau de santé, la section
// « Indexation » (deux boutons et un interrupteur), le bloc de la passe
// manuelle et celui de l'agent — et, au démarrage, un bouton « Ré-enregistrer »
// s'affichait deux secondes avant que la première lecture d'`agent_status` ne
// le fasse disparaître. Le public visé n'a pas à savoir qu'il existe un agent,
// un verrou et une file OCR : il veut savoir si l'index est à jour, s'il
// travaille, et s'il attend un geste de lui. Une carte, une phrase, au plus un
// bouton ; le détail vit dans la fenêtre « Votre index », et la barre des menus
// ne parle plus d'indexation du tout (IX2, 12/09/2026).
//
// Cet état est PUR : calculé depuis des données déjà lues par `AppModel`, sans
// la moindre entrée-sortie, donc testable ligne à ligne (`IndexStatusTests`).
// Les phrases sont l'affaire d'`IndexStatusText` (LocalizedText.swift) ; ici on
// ne manipule que des cas.

import Foundation
import FouineCore

/// Ce qui occupe l'index en ce moment.
enum IndexActivity: Equatable, Sendable {
    /// Parcours des dossiers et extraction du texte (passe manuelle ou agent).
    case updating
    /// Reconnaissance du texte des pages scannées (OCR).
    case readingScans
    /// Préparation de la recherche par le sens (campagne d'embedding).
    case preparingMeaning
    /// Un autre programme écrit dans l'index (ligne de commande).
    case externalWrite
}

/// Avancement d'un travail en cours. `total == 0` = indéterminé.
struct IndexProgress: Equatable, Sendable {
    var done: Int
    var total: Int
    /// Secondes restantes estimées, ou `nil` faute de débit connu : on ne
    /// devine pas — « il reste environ 2 h » se comprend, un chiffre inventé
    /// est pire que rien.
    var remainingSeconds: TimeInterval?

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var isDeterminate: Bool { total > 0 }
}

/// Le geste que l'état propose. UN seul bouton principal, jamais deux.
enum IndexAction: Equatable, Sendable {
    case updateNow
    case stop
    /// Ouvre la feuille « Lire les pages scannées » (budget, avertissement).
    case readScans
    case addFolder
    case openLoginItems
    case openPrivacySettings
    case revealInstalledCopy
    /// = ré-enregistrer l'agent, dit dans la langue de l'utilisateur.
    case restartAutomaticUpdates
    case retestFolders

    /// Ce geste a-t-il besoin de la fenêtre PRINCIPALE ?
    ///
    /// Oui pour tout ce qui s'y accroche — une feuille (« Lire les pages
    /// scannées… »), le panneau d'ajout de dossier, une passe qui s'annonce
    /// dans une feuille. Déclenché depuis la fenêtre « Votre index » alors que
    /// la fenêtre principale est fermée, le clic n'aurait aucun effet visible.
    /// Non pour ce qui ouvre les Réglages Système ou le Finder : ces
    /// fenêtres-là sont ailleurs. (Était `MenuBarModel.needsWindow` tant que
    /// la barre des menus portait ces gestes ; même table de vérité.)
    var needsMainWindow: Bool {
        switch self {
        case .updateNow, .readScans, .addFolder, .restartAutomaticUpdates:
            return true
        case .stop, .openLoginItems, .openPrivacySettings, .revealInstalledCopy,
             .retestFolders:
            return false
        }
    }
}

/// Pourquoi la mise à jour automatique attend. Déduit du texte libre que
/// l'agent publie en phase `waiting` (les six conditions du §5.7).
enum IndexPauseReason: Equatable, Sendable {
    case onBattery
    case lowPowerMode
    case machineHot
    case anotherProgramWriting
    case folderUnreadable
    /// Un motif que cette version ne sait pas nommer : le texte est montré tel
    /// quel, parce que lire quelque chose vaut mieux que rien.
    case other(String)

    /// Le premier blocage cité décide : l'agent les liste dans l'ordre du §5.7,
    /// et c'est aussi l'ordre dans lequel l'utilisateur peut agir.
    static func parse(_ detail: String) -> IndexPauseReason {
        let first = detail.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? detail
        let lower = first.lowercased()
        if lower.contains("no ac power") { return .onBattery }
        if lower.contains("low power mode") { return .lowPowerMode }
        if lower.contains("cpu_speed_limit") || lower.contains("thermalstate") {
            return .machineHot
        }
        if lower.contains("fouine.lock") || lower.contains("lock is held") {
            return .anotherProgramWriting
        }
        if lower.contains("unreadable root") { return .folderUnreadable }
        return .other(first)
    }
}

/// Ce qui réclame un geste de l'utilisateur. Chaque cas porte SON geste
/// (`action`), jamais un geste générique (§5.6 amendé, A2-11).
enum IndexAttention: Equatable, Sendable {
    case folderNotAllowed(folder: String)
    case folderNotFound(folder: String)
    case folderCannotBeRead(folder: String)
    case diskNotPluggedIn(folder: String)
    case awaitingApproval
    case automaticUpdatesNotStarting
    case severalCopies
    case serviceMissing

    var action: IndexAction {
        switch self {
        case .folderNotAllowed: return .openPrivacySettings
        // Rien à autoriser : on revérifie une fois le dossier remis en place
        // ou le disque rebranché.
        case .diskNotPluggedIn, .folderNotFound, .folderCannotBeRead:
            return .retestFolders
        case .awaitingApproval: return .openLoginItems
        // « Relancer » ne peut RIEN faire quand Fouine n'est pas dans le
        // dossier Applications (AP-21) : le ré-enregistrement se refuse avant
        // même d'atteindre le système, et le bouton ne faisait que réafficher
        // le problème dans d'autres mots. Le seul geste qui répare est de
        // déposer cette copie dans Applications — on la montre au Finder.
        case .serviceMissing: return .revealInstalledCopy
        case .automaticUpdatesNotStarting, .severalCopies:
            return .restartAutomaticUpdates
        }
    }
}

enum IndexStatus: Equatable, Sendable {
    /// Au démarrage, tant que l'app n'a pas lu l'état réel (racines, statut de
    /// l'agent) : rien à dire, rien à proposer. C'est ce qui remplace le
    /// « Ré-enregistrer » furtif.
    case checking
    /// Aucun dossier : la seule chose à faire est d'en ajouter un.
    case noFolders
    /// Un geste de l'utilisateur est nécessaire.
    case needsAttention(IndexAttention)
    /// L'index travaille. `stoppable` : la passe est celle de l'application,
    /// on peut l'arrêter d'ici ; celle de l'agent ou d'une commande, non.
    case working(activity: IndexActivity, progress: IndexProgress?,
                 detail: String?, stoppable: Bool)
    /// La mise à jour automatique attend que la machine s'y prête.
    case paused(reason: IndexPauseReason, scansWaiting: Int)
    /// Rien ne tourne. `scansWaiting` pages scannées attendent d'être lues ;
    /// `lastUpdate` est la dernière nouvelle connue (statut de l'agent).
    case idle(automatic: Bool, scansWaiting: Int, lastUpdate: Date?)

    /// Le bouton principal de la carte, s'il y en a un.
    var primaryAction: IndexAction? {
        switch self {
        case .checking: return nil
        case .noFolders: return .addFolder
        case .needsAttention(let attention): return attention.action
        case .working(_, _, _, let stoppable): return stoppable ? .stop : nil
        case .paused(_, let scans): return scans > 0 ? .readScans : nil
        case .idle(let automatic, _, _):
            return automatic ? nil : .updateNow
        }
    }

    /// Un second geste, discret, quand il a un sens : lire les pages scannées
    /// tout de suite alors que la mise à jour est manuelle.
    var secondaryAction: IndexAction? {
        if case .idle(let automatic, let scans, _) = self, !automatic, scans > 0 {
            return .readScans
        }
        return nil
    }

    var isWorking: Bool { if case .working = self { return true }; return false }
    var needsAttention: Bool { if case .needsAttention = self { return true }; return false }

    /// Le pictogramme de la barre des menus, par famille d'état.
    ///
    /// RENDU LE 13/09/2026 (AP1), après l'avoir retiré la veille (IX2). Ce
    /// qu'on reprochait alors au triangle orange — inquiéter sans expliquer —
    /// tenait au panneau, devenu muet sur l'index : l'icône changeait, et ce
    /// qu'elle ouvrait n'en disait pas un mot. Le panneau porte de nouveau UNE
    /// ligne d'état (`MenuBarItem.status`) : l'icône dit qu'il se passe quelque
    /// chose, la ligne dit quoi. Trois symboles et pas un de plus — dans une
    /// barre des menus de vingt icônes, une nuance ne se voit pas.
    enum Glyph: Equatable, Sendable { case quiet, working, attention }
    var glyph: Glyph {
        switch self {
        case .working: return .working
        case .needsAttention: return .attention
        case .checking, .noFolders, .paused, .idle: return .quiet
        }
    }
}

// MARK: - Évaluation

/// Tout ce que l'évaluateur regarde, en une structure : les tests la
/// construisent à la main, `AppModel` la remplit depuis son état publié.
struct IndexStatusInput {
    /// Vrai quand racines ET statut de l'agent ont été lus au moins une fois.
    var probed: Bool
    var roots: [RootStatus]
    var rootsError: String?
    var health: HealthBannerReport
    var indexing: IndexingState
    /// Position de l'interrupteur « Mettre l'index à jour automatiquement ».
    var automatic: Bool
    var agentState: AgentOperationalState
    var agentStatus: AgentStatusRecord?
    var scansWaiting: Int
    /// Estimation du temps restant pour la phase de l'agent (voir
    /// `IndexRateEstimator`), ou `nil`.
    var agentRemainingSeconds: TimeInterval?
    var now: Date = Date()
}

enum IndexStatusEvaluator {

    static func evaluate(_ input: IndexStatusInput) -> IndexStatus {
        guard input.probed else { return .checking }
        if input.roots.isEmpty, input.rootsError == nil { return .noFolders }

        // 1. La passe lancée depuis l'application passe avant tout : c'est
        //    l'utilisateur qui l'a demandée, et c'est elle qu'il peut arrêter.
        if input.indexing.running {
            let progress = input.indexing.total > 0
                ? IndexProgress(done: input.indexing.done, total: input.indexing.total,
                                remainingSeconds: nil)
                : nil
            return .working(activity: input.indexing.activity, progress: progress,
                            detail: input.indexing.phase.isEmpty ? nil : input.indexing.phase,
                            stoppable: !input.indexing.cancelled)
        }

        // 2. Ce qui réclame un geste. Un dossier illisible ou un disque absent
        //    empêche l'index d'être complet ; une mise à jour automatique qui
        //    ne démarre pas trahit une promesse.
        if let attention = attention(input) { return .needsAttention(attention) }

        // 3. Un autre programme écrit (ligne de commande, seconde copie de
        //    Fouine) : l'index se met à jour, on ne peut pas l'arrêter d'ici.
        //    Si c'est l'agent, sa phase dit mieux ce qu'il fait — on la lit
        //    plus bas.
        //
        //    SA PROPRE ÉCRITURE N'EST PAS CELLE D'UN AUTRE (BU-31). Une passe
        //    lancée depuis cette fenêtre tient le verrou du début à la fin ;
        //    le rapport de santé, lui, ne se relit que toutes les trente
        //    secondes, et il survivait à la fin de la passe. La carte
        //    annonçait alors « Un autre programme écrit dans l'index » pendant
        //    que Fouine lisait ses propres pages scannées.
        if case .indexUpdating(let role, _, let ownProcess) = input.health.writeLockRow.message,
           role != .agent, !ownProcess {
            return .working(activity: .externalWrite, progress: nil,
                            detail: nil, stoppable: false)
        }

        // 4. La mise à jour automatique, d'après ce qu'elle publie.
        if input.automatic, let status = input.agentStatus, !status.isStale(at: input.now) {
            switch status.phase {
            case .crawl, .extract:
                return .working(activity: .updating,
                                progress: progress(status, remaining: nil),
                                detail: detail(status), stoppable: false)
            case .ocr:
                return .working(activity: .readingScans,
                                progress: progress(status, remaining: input.agentRemainingSeconds),
                                detail: detail(status), stoppable: false)
            // La préparation du sens menée par la mise à jour automatique
            // (AG1, PR-21) : l'activité est celle que l'app affiche DÉJÀ pour
            // sa propre campagne, avec « N pages sur M ». On ne l'arrête pas
            // d'ici — c'est le réglage qui la commande, pas un bouton.
            case .preparingMeaning:
                return .working(activity: .preparingMeaning,
                                progress: progress(status, remaining: input.agentRemainingSeconds),
                                detail: detail(status), stoppable: false)
            case .waiting:
                return .paused(reason: IndexPauseReason.parse(status.detail),
                               scansWaiting: input.scansWaiting)
            case .idle, .stopped:
                return .idle(automatic: true, scansWaiting: input.scansWaiting,
                             lastUpdate: status.updatedAt)
            }
        }

        // 5. Verrou tenu par l'agent sans statut frais : il travaille, sans
        //    plus de détail.
        if case .indexUpdating(.agent, _, _) = input.health.writeLockRow.message {
            return .working(activity: .updating, progress: nil, detail: nil,
                            stoppable: false)
        }

        return .idle(automatic: input.automatic, scansWaiting: input.scansWaiting,
                     lastUpdate: input.agentStatus?.updatedAt)
    }

    /// Les lignes orange du bandeau, converties en UN cas qui porte son geste.
    /// Les dossiers d'abord : sans lecture, rien d'autre n'a de sens.
    private static func attention(_ input: IndexStatusInput) -> IndexAttention? {
        switch input.health.rootsRow.message {
        case .folderNotAllowed(let folder): return .folderNotAllowed(folder: folder)
        case .diskNotPluggedIn(let folder): return .diskNotPluggedIn(folder: folder)
        case .folderNotFound(let folder): return .folderNotFound(folder: folder)
        case .folderCannotBeRead(let folder): return .folderCannotBeRead(folder: folder)
        default: break
        }
        switch input.health.agentRow.message {
        case .backgroundIndexingAwaitingApproval: return .awaitingApproval
        case .backgroundIndexingSeveralCopies: return .severalCopies
        case .backgroundIndexingServiceMissing: return .serviceMissing
        case .backgroundIndexingNotStarting:
            // Un processus VIVANT qui se tait n'est pas une panne : il est
            // au repos (machine sortie de veille, tour d'horloge à venir).
            // L'alerte n'est légitime que si le processus a disparu ou n'a
            // jamais écrit. Sans cette nuance, chaque réveil de la machine
            // affichait une minute d'orange et un bouton inutile.
            if let status = input.agentStatus, status.isAlive, status.phase != .stopped {
                return nil
            }
            return .automaticUpdatesNotStarting
        default: return nil
        }
    }

    private static func progress(_ status: AgentStatusRecord,
                                 remaining: TimeInterval?) -> IndexProgress? {
        guard status.total > 0 else { return nil }
        return IndexProgress(done: status.done, total: max(status.total, status.done),
                             remainingSeconds: remaining)
    }

    /// Le nom du document en cours ; les jetons de compte n'apportent rien de
    /// plus que la barre, et « starting » ou « queue-drained » ne sont pas
    /// des détails.
    private static func detail(_ status: AgentStatusRecord) -> String? {
        switch AgentStatusDetail.parse(status.detail) {
        case .document(let name): return name
        case .free(let text): return text.isEmpty ? nil : text
        default: return nil
        }
    }
}

// MARK: - Temps restant

/// Estime le temps restant d'une phase de l'agent depuis ses publications
/// successives (`done`/`total` à `updatedAt`).
///
/// Débit LISSÉ sur une fenêtre glissante de dix minutes : l'OCR avance par
/// à-coups (une page lourde, un lot qui se termine), et un débit instantané
/// ferait sauter l'estimation de « 1 h » à « 6 h » d'une seconde à l'autre.
/// La phase ou le total qui change remet l'estimateur à zéro : le compteur
/// repart, l'ancien débit ne veut plus rien dire. Pas d'estimation avant deux
/// points et une progression réelle.
struct IndexRateEstimator: Equatable, Sendable {
    private struct Sample: Equatable { let at: Date; let done: Int }
    private var samples: [Sample] = []
    private var phase: AgentStatusRecord.Phase?
    private var total = 0

    static let window: TimeInterval = 10 * 60
    /// Sous ce débit, l'estimation n'est pas rendue : une page par heure
    /// projetterait des semaines, ce qui ne renseigne personne.
    static let minimumRate = 1.0 / 3600

    init() {}

    mutating func observe(_ status: AgentStatusRecord, now: Date = Date()) {
        let at = status.updatedAt ?? now
        if status.phase != phase || status.total != total || status.done < (samples.last?.done ?? 0) {
            samples.removeAll()
            phase = status.phase
            total = status.total
        }
        if let last = samples.last, last.at == at { return }
        samples.append(Sample(at: at, done: status.done))
        let cutoff = at.addingTimeInterval(-Self.window)
        // On garde toujours au moins deux points : le débit se mesure entre eux.
        while samples.count > 2, samples[0].at < cutoff { samples.removeFirst() }
    }

    /// Secondes restantes, ou `nil` tant qu'on ne sait pas.
    var remainingSeconds: TimeInterval? {
        guard total > 0, let first = samples.first, let last = samples.last,
              last.at > first.at, last.done > first.done else { return nil }
        let rate = Double(last.done - first.done) / last.at.timeIntervalSince(first.at)
        guard rate >= Self.minimumRate else { return nil }
        let left = max(0, total - last.done)
        return Double(left) / rate
    }
}

// MARK: - Habillage de la carte

extension IndexStatus {

    /// Ce que la carte peint autour du pictogramme. PUR, donc testé : la
    /// couleur porte à elle seule « tout va bien » / « à toi de jouer », et
    /// une erreur de correspondance ne se verrait qu'à l'usage.
    enum Tint: Equatable, Sendable {
        /// Un travail est en cours.
        case working
        /// Un geste de l'utilisateur est attendu.
        case attention
        /// L'index est à jour.
        case upToDate
        /// Rien à signaler, rien à faire.
        case quiet
    }

    var tint: Tint {
        switch self {
        case .working:        return .working
        case .needsAttention: return .attention
        // « En attente » dit AUSSI que l'index est à jour : ce qui reste, ce
        // sont des pages scannées à lire, et elles le seront toutes seules.
        case .paused:         return .upToDate
        case .idle(let automatic, _, _): return automatic ? .upToDate : .quiet
        case .checking, .noFolders: return .quiet
        }
    }

    /// Le pictogramme de la carte. Il DOUBLE la phrase, il ne la remplace
    /// pas : un symbole seul n'est lisible que par qui connaît déjà l'app.
    var symbol: String {
        switch self {
        case .checking:       return "hourglass"
        case .noFolders:      return "folder.badge.plus"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .working(let activity, _, _, _):
            switch activity {
            case .updating, .externalWrite: return "arrow.triangle.2.circlepath"
            case .readingScans:             return "text.viewfinder"
            case .preparingMeaning:         return "wand.and.stars"
            }
        case .paused:         return "clock"
        case .idle(let automatic, _, _):
            return automatic ? "checkmark.circle.fill" : "checkmark.circle"
        }
    }
}

// MARK: - Ce que la carte « Index » peint (IX2, 12/09/2026)

/// La carte « Index » de la barre latérale, réduite à l'essentiel.
///
/// POURQUOI. Demande du propriétaire du 12/09/2026, capture du build 678 à
/// l'appui : sous « À jour / Mis à jour à l'instant » s'empilaient les comptes,
/// « 137 documents illisibles », « 4 214 pages seront relues… », puis une
/// confirmation de deux lignes sous l'interrupteur. « Laisser l'essentiel. »
/// Restent la phrase d'état, sa précision, la barre d'un travail en cours, AU
/// PLUS UN bouton, la place disque quand elle manque vraiment — et le lien
/// « Détails… » vers la fenêtre « Votre index », où tout le reste est dit.
///
/// Le tri se fait ICI, état par état : une vue ne se teste pas, et une ligne
/// revenue sous la carte ne se verrait qu'à l'écran (`IndexCardSummaryTests`).
/// Les phrases viennent toujours d'`IndexStatusText` : la carte et la fenêtre
/// disent les mêmes mots.
struct IndexCardSummary: Equatable {

    /// La barre d'avancement d'un travail en cours.
    enum Bar: Equatable {
        /// Le total est connu : la barre se remplit.
        case determinate(Double)
        /// Sans total, une barre à 0 % mentirait : elle dit « ça avance », ce
        /// qui est tout ce qu'on sait.
        case indeterminate
    }

    /// `IndexStatusText.headline`, inchangé.
    let headline: String
    /// La ligne sous le titre, ou `nil`.
    let detail: String?
    /// Seulement pendant un travail.
    let bar: Bar?
    /// Le seul bouton de la carte, ou `nil`.
    let action: IndexAction?
    /// L'arrêt a été demandé et la passe n'a pas encore rendu la main (ST1) :
    /// le bouton reste là mais ne répond plus, et un tourniquet accompagne la
    /// phrase. Le faire DISPARAÎTRE serait pire — on ne saurait plus si le clic
    /// a été pris.
    let isStopping: Bool
    /// La phrase de place disque, seulement quand Fouine risque d'en manquer.
    let diskSpace: String?

    init(status: IndexStatus, disk: DiskSpaceNotice, stopping: Bool = false,
         now: Date = Date()) {
        headline = IndexStatusText.headline(status)
        bar = Self.bar(for: status)
        isStopping = stopping && status.isWorking

        if case .working(let activity, let progress, let phase, _) = status {
            // NI LE NOM DU DOCUMENT, NI « 312 / 1 200 pages » : ils changent
            // toutes les deux secondes et se lisent mal dans 230 points. La
            // barre dit que ça avance, la ligne dit quand ce sera fini si on le
            // sait ; le reste est dans la fenêtre.
            //
            // UNE EXCEPTION, ET UNE SEULE (ST1) : pendant un arrêt, la phase EST
            // ce qu'on attend (« Arrêt — “cours.mp4” se termine… »). C'est le
            // seul moment où le nom d'un document sous la carte répond à une
            // question que l'utilisateur vient de poser.
            detail = isStopping
                ? (phase ?? IndexStatusText.detail(status, now: now))
                : Self.workingLine(activity: activity, progress: progress)
        } else {
            detail = IndexStatusText.detail(status, now: now)
        }

        // « Lire les pages scannées… » part dans la fenêtre : il ouvre une
        // feuille de budget, ce n'est pas le geste qu'attend une carte qui dit
        // « À jour ». Et jamais l'action secondaire : un bouton, pas deux.
        //
        // Pendant un arrêt, le bouton est celui qu'on vient de cliquer : il
        // reste affiché, désactivé (`isStopping`), là où l'état seul le rendait
        // `nil` — la carte perdait son bouton au moment du clic.
        let primary: IndexAction? = isStopping ? .stop : status.primaryAction
        action = primary == .readScans ? nil : primary

        // `.low` (moins de 5 Go) se dit dans la fenêtre : rien n'y presse.
        // `.tight` reste ici — Fouine risque de ne pas pouvoir finir, et la
        // phrase dit quoi faire.
        if case .tight = disk {
            diskSpace = disk.text
        } else {
            diskSpace = nil
        }
    }

    /// La barre d'un état : aucune hors travail, pleine d'une fraction quand le
    /// total est connu, indéterminée sinon. La fenêtre « Votre index » dessine
    /// la même.
    static func bar(for status: IndexStatus) -> Bar? {
        guard case .working(_, let progress, _, _) = status else { return nil }
        if let progress, progress.isDeterminate {
            return .determinate(progress.fraction)
        }
        return .indeterminate
    }

    private static func workingLine(activity: IndexActivity,
                                    progress: IndexProgress?) -> String? {
        if let seconds = progress?.remainingSeconds {
            return sentence(IndexStatusText.remaining(seconds))
        }
        if activity == .externalWrite { return IndexStatusText.anotherProgramWriting }
        return nil
    }

    /// « environ 2 h restantes » est écrit pour finir une ligne chiffrée ; seul
    /// sous le titre, il commence comme une phrase.
    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).localizedUppercase + text.dropFirst()
    }
}

/// Ce qu'a répondu le dernier geste sur l'interrupteur « Mettre l'index à jour
/// automatiquement » (IX2).
///
/// DEUX NATURES, DEUX PLACES. Une CONFIRMATION (« La mise à jour automatique
/// est activée… ») redit ce que la carte dit déjà par son état : sous la carte,
/// c'était deux lignes de trop, elle ne s'affiche plus que dans la fenêtre
/// « Votre index ». Un PROBLÈME (refus, échec) accompagne un interrupteur
/// revenu en arrière tout seul — le pire des cas s'il ne dit pas pourquoi : il
/// reste sous l'interrupteur de la carte.
struct AutomaticUpdatesMessage: Equatable {
    enum Kind: Equatable {
        case confirmation
        case problem
    }

    let text: String
    let kind: Kind

    static func confirmation(_ text: String) -> AutomaticUpdatesMessage {
        AutomaticUpdatesMessage(text: text, kind: .confirmation)
    }

    static func problem(_ text: String) -> AutomaticUpdatesMessage {
        AutomaticUpdatesMessage(text: text, kind: .problem)
    }

    /// Sous l'interrupteur de la barre latérale : les problèmes seulement.
    var showsUnderCard: Bool { kind == .problem }
}

// MARK: - La place qui reste sur le disque (MO-03, décision du 11/09/2026)

/// Ce que Fouine dit de l'espace disque — et le plus souvent, rien. La fenêtre
/// « Votre index » montre les deux phrases ; la carte « Index », la seconde
/// seulement, parce qu'elle seule attend un geste (IX2).
///
/// POURQUOI PAS LE BUDGET. Le lot MB1 affichait « Votre index occupe 2,15 Go
/// sur les 2,5 Go prévus » dès 80 % du critère P5 de la SPEC. Le propriétaire
/// lui-même l'a lu comme un maximum (« est-ce le plafond de ce que Fouine peut
/// indexer ? », 11/09/2026) : pour le public visé, un chiffre « prévu » est une
/// limite, quoi qu'on écrive à côté. Le critère P5 est une promesse de la SPEC
/// pour le fonds de référence, il reste dans `fouine status` et `fouine doctor`
/// (dépanneurs) ; l'application, elle, ne parle que de ce qui peut vraiment
/// gêner l'utilisateur : la place qui reste sur SON disque.
///
/// PUR et à part, comme `SinceLastVisit` : ce qui se décide ici est le SEUIL à
/// partir duquel on parle, et une erreur de seuil ne se verrait qu'un jour de
/// disque plein. Trois règles, dans l'ordre :
/// - la place manque pour FINIR (ce que la préparation du sens doit encore
///   écrire, `DiskForecast`, ne tient pas dans le reste) ou il reste moins de
///   1 Go : on le dit, avec le geste ;
/// - il reste moins de 5 Go (le seuil vers lequel macOS commence lui-même à
///   prévenir) : on dit le reste et ce que l'index occupe, sans alarme ;
/// - au-delà, silence — et silence aussi quand le volume ne répond pas
///   (`nil`) : une phrase fausse vaut moins que rien.
///
/// Les tailles annoncées sont celles du jour (le reste mesuré, la base sur le
/// disque), jamais une projection : « il reste 3,2 Go » doit être vrai à la
/// lecture.
enum DiskSpaceNotice: Equatable {
    case silent
    /// Il reste peu de place ; l'index pèse `index`.
    case low(free: Int, index: Int)
    /// La place ne suffit plus pour finir l'index, ou presque plus du tout.
    case tight(free: Int, index: Int)

    /// Sous ce reste, on parle (5 × 10⁹ octets, comptés comme le Finder).
    static let lowFreeBytes = 5_000_000_000
    /// Sous ce reste, on parle fort : le système lui-même n'est plus loin de
    /// refuser d'écrire.
    static let tightFreeBytes = 1_000_000_000

    /// - Parameters:
    ///   - freeBytes: la place libre sur le volume de l'index, ou `nil` si
    ///     elle n'a pas pu être lue.
    ///   - forecast: la base du jour et ce qu'elle doit encore écrire.
    static func decide(freeBytes: Int?, forecast: DiskForecast) -> DiskSpaceNotice {
        guard let free = freeBytes else { return .silent }
        let stillToWrite = max(0, forecast.bytesAtFullVectors - forecast.bytes)
        if free < tightFreeBytes || free < stillToWrite {
            return .tight(free: free, index: forecast.bytes)
        }
        if free < lowFreeBytes {
            return .low(free: free, index: forecast.bytes)
        }
        return .silent
    }

    /// La phrase, ou `nil` quand il n'y a rien à dire. Les tailles passent par
    /// `ByteCountFormatter` (« 3,2 Go », jamais « Gio » ni un nombre d'octets).
    var text: String? {
        switch self {
        case .silent:
            return nil
        case .low(let free, let index):
            return String(localized: "Your disk has \(Format.bytes(free)) left; your index uses \(Format.bytes(index))")
        case .tight(let free, let index):
            return String(localized: "Your disk has only \(Format.bytes(free)) left and your index uses \(Format.bytes(index)): Fouine may run out of room to finish it. Free up some space, or remove a folder you no longer need")
        }
    }
}

// MARK: - Les pages scannées sans texte lisible (IX2, remplace PR-24)

/// Ce que la fenêtre « Votre index » dit des pages scannées que la
/// reconnaissance a lues sans en tirer un texte sûr — et le plus souvent, rien.
///
/// CE QUI A CHANGÉ (IX2, 12/09/2026). La carte annonçait « 4 214 pages
/// scannées ont été mal lues » avec un geste « Les relire », puis « … seront
/// relues à la prochaine lecture des scans ». Mesuré sur la production le
/// 12/09/2026, file de lecture vidée : les 3 157 pages sans ligne et les 1 053
/// douteuses étaient toujours là. La relecture passe par le même moteur avec
/// les mêmes réglages (Vision `.accurate`, mêmes langues, rendu 150 dpi) : elle
/// rend le même résultat, et la phrase promettait un mieux qui ne vient jamais.
/// Plus de geste en masse ni d'état « en file », donc : on dit ce que sont ces
/// pages. Le seul cas où relire change quelque chose — une langue qu'on vient
/// de cocher — passe par « Relire cette page », dans l'aperçu.
///
/// DEUX LIGNES ET NON UN TOTAL. Une page sans aucun texte (une page blanche, un
/// dessin) ne fait manquer aucune recherche ; une page aux lettres incertaines
/// (un scan pâle, une écriture à la main) peut en faire manquer un mot. Les
/// additionner annonçait 4 214 problèmes dont les trois quarts n'en sont pas.
///
/// PUR et à part, comme `DiskSpaceNotice` : ce qui se décide ici est ce qu'on
/// dit et quand, et une phrase fausse ne se verrait qu'à l'usage.
struct ScannedPagesWithoutText: Equatable {
    /// Une population : ce qu'elle compte, puis ce que c'est.
    struct Line: Equatable {
        let title: String
        let explanation: String
    }

    /// `pages_ocr_no_lines` de `stats()`.
    let noText: Int
    /// `pages_ocr_low_conf` de `stats()`.
    let uncertain: Int

    /// `nil` quand il n'y a rien à dire : parler de pages mal lues à qui n'en a
    /// aucune ne fait qu'inquiéter.
    static func of(noLines: Int, doubtful: Int) -> ScannedPagesWithoutText? {
        let noText = max(0, noLines)
        let uncertain = max(0, doubtful)
        guard noText + uncertain > 0 else { return nil }
        return ScannedPagesWithoutText(noText: noText, uncertain: uncertain)
    }

    /// Une ligne par population non vide, les pages sans texte d'abord : les
    /// plus nombreuses, et les moins gênantes.
    var lines: [Line] {
        var out: [Line] = []
        if noText > 0 {
            out.append(Line(
                title: String(localized: "\(noText) scanned page(s) with no text Fouine could recognize"),
                explanation: String(localized: "Usually blank pages, pictures or drawings.")))
        }
        if uncertain > 0 {
            out.append(Line(
                title: String(localized: "\(uncertain) scanned page(s) read with uncertain letters"),
                explanation: String(localized: "Faint or skewed scans, handwriting, unusual fonts: a search may miss some of their words.")))
        }
        return out
    }

    /// La phrase commune, SANS PROMESSE : ce que relire donnerait, et le seul
    /// geste qui change quelque chose (une langue cochée, puis la page relue).
    static var closing: String {
        String(localized: "Fouine has read these pages as well as it can: reading them again would give the same result. If a document is written in a language that is not ticked in Settings ▸ Indexing, tick it, then right-click the page in the preview and choose “Read this page again”.")
    }

    /// Les deux clés à VARIATION DE PLURIEL (`%lld`) : un « 1 pages » se lit
    /// comme une coquille. Exposées pour que le test l'exige — le processus de
    /// test n'embarque pas le catalogue et ne peut pas comparer les phrases.
    static let pluralKeys = ["%lld scanned page(s) with no text Fouine could recognize",
                             "%lld scanned page(s) read with uncertain letters"]
}

// MARK: - « Depuis votre dernière visite »

/// Combien de pages se sont ajoutées entre deux visites (UX-06).
///
/// PUR et à part, parce que les trois cas qui comptent sont des cas limites :
/// la PREMIÈRE visite ne dit rien (sinon Fouine annoncerait tout l'index comme
/// une nouveauté), et un compte qui a BAISSÉ ne dit rien non plus — un dossier
/// retiré ou un index refait n'est pas une nouvelle à annoncer.
enum SinceLastVisit {
    static func added(previous: Int?, current: Int) -> Int? {
        guard let previous, current > previous else { return nil }
        return current - previous
    }
}

// MARK: - Qui prépare la recherche par le sens (constat PR-21, lot AG1)

/// Qui doit s'en charger : vous, ou Fouine toute seule.
///
/// POURQUOI C'EST UN CAS ET NON UN `if` DANS LA VUE. Le bouton « Préparer la
/// recherche par le sens… » ouvre une feuille qui demande un budget et
/// monopolise la fenêtre pendant des heures. Depuis que la mise à jour
/// automatique s'en charge par tranches, ce bouton n'est plus un geste utile
/// mais une façon de refaire à la main ce qui se fait tout seul — et deux
/// campagnes à la fois sont refusées de toute façon (verrou de campagne).
/// Trois conditions doivent tenir ENSEMBLE pour qu'on le retire, et une erreur
/// sur l'une d'elles laisserait un utilisateur sans aucun moyen de préparer
/// quoi que ce soit : cela se teste.
enum MeaningPreparation: Equatable {
    /// Le bouton, comme avant.
    case byHand
    /// Fouine s'en occupe : une phrase, pas de bouton.
    case inBackground

    /// - Parameters:
    ///   - settingOn: `agent.prepareMeaning`.
    ///   - modelInstalled: le modèle est là (sans lui, rien ne se prépare).
    ///   - agent: l'état croisé de la mise à jour automatique. Un agent en
    ///     attente d'approbation, introuvable ou muet ne prépare rien : le
    ///     bouton reste.
    static func decide(settingOn: Bool, modelInstalled: Bool,
                       agent: AgentOperationalState) -> MeaningPreparation {
        guard settingOn, modelInstalled else { return .byHand }
        switch agent {
        case .active, .waitingFirstReport: return .inBackground
        case .off, .registeredButSilent, .requiresApproval, .notFound, .unknown:
            return .byHand
        }
    }
}
