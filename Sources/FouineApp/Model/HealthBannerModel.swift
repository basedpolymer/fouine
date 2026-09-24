// HealthBannerModel.swift — état de santé visible à quatre lignes (audit H4, registre I1).
// Propriété : A-App. SPEC §5.6.
//
// Quatre lignes : indexation en arrière-plan (agent), index (verrou
// d'écriture), recherche sémantique, dossiers. RÈGLE DE SÉVÉRITÉ (lot I1,
// amendement du 03/09/2026 au §5.6) :
//   · ORANGE seulement si l'utilisateur doit faire un geste pour retrouver une
//     fonction promise ;
//   · ROUGE seulement si des données sont en danger ou une fonction est cassée ;
//   · tout le reste est VERT, et une ligne verte n'a pas besoin de bouton.
//
// Deux conséquences qui ne vont pas de soi. Un verrou TENU est une activité
// normale — l'agent, la CLI ou l'app elle-même indexe — et se dit comme telle
// (« L'index se met à jour… »). Un verrou PÉRIMÉ (détenteur mort) se répare
// tout seul à la prochaine écriture (`ExclusiveLock.stamp` reprend le verrou en
// le journalisant) : c'est vert, sans « Réessayer ». Sur la machine du
// propriétaire, `fouine.lock` portait justement un détenteur mort depuis la
// veille, et le bandeau H4 l'affichait en rouge.
//
// Le public n'est pas technicien : la ligne se rend depuis le CAS de
// `HealthRow.Message` (`localizedText`, dans LocalizedText.swift), et aucune
// phrase ne dit « verrou », « pid » ou « vecteur ».

import Foundation
import FouineCore

/// Gravité de santé pour chaque élément.
enum HealthSeverity: String, Sendable, Equatable, Comparable {
    case green
    case orange
    case red

    static func < (lhs: HealthSeverity, rhs: HealthSeverity) -> Bool {
        switch (lhs, rhs) {
        case (.green, .orange), (.green, .red), (.orange, .red):
            return true
        default:
            return false
        }
    }
}

/// Le geste proposé sur une ligne. Le libellé du bouton se tire du cas
/// (`localizedLabel`), il ne voyage pas en clé.
enum HealthAction: Sendable, Equatable {
    /// Réglages Système ▸ Général ▸ Ouverture : l'agent attend l'accord de l'utilisateur.
    case openLoginItems
    /// Réglages Système ▸ Confidentialité et sécurité ▸ Fichiers et dossiers.
    case openPrivacySettings
    case reregisterAgent
    case chooseRoots
    /// Montrer dans le Finder la Fouine.app installée, pour la remplacer :
    /// c'est le seul geste qui répare une copie d'une ancienne version, et
    /// aucun bouton ne peut le faire à la place de l'utilisateur (A2-03).
    case revealInstalledCopy
}

/// Une ligne du bandeau de santé.
struct HealthRow: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case agent
        case writeLock
        case semantic
        case roots
    }

    /// Ce que la ligne dit, sous forme de DONNÉES. Les tests comparent le cas ;
    /// la phrase est l'affaire de `localizedText`.
    enum Message: Sendable, Equatable {
        // Indexation en arrière-plan
        case backgroundIndexingOn
        case backgroundIndexingStarting
        case backgroundIndexingOff
        case backgroundIndexingNotStarting
        /// Ne démarre pas ET macOS connaît plusieurs Fouine.app : c'est la
        /// cause, et elle se nomme (lot J2).
        case backgroundIndexingSeveralCopies
        case backgroundIndexingAwaitingApproval
        case backgroundIndexingServiceMissing
        case backgroundIndexingUnknown
        // Index (verrou d'écriture)
        case indexAvailable
        /// `since` est déjà l'heure en langage courant (`LockHolder.clockText`).
        /// `ownProcess` : c'est CETTE application qui écrit — sa propre passe
        /// de lecture des pages scannées, par exemple (BU-31).
        case indexUpdating(by: LockRole, since: String, ownProcess: Bool)
        // Recherche sémantique
        case semanticReady
        case semanticPreparing
        case semanticNotInstalled
        // Dossiers
        case noFolders
        case diskNotPluggedIn(folder: String)
        /// macOS refuse la lecture : le SEUL cas qui mène aux Réglages Système.
        case folderNotAllowed(folder: String)
        /// Dossier déplacé, renommé ou supprimé.
        case folderNotFound(folder: String)
        /// Aucun fichier lisible, ou une erreur du système (disque qui
        /// répond mal) : rien à autoriser non plus.
        case folderCannotBeRead(folder: String)
        case foldersAllAccessible
    }

    let kind: Kind
    let severity: HealthSeverity
    let message: Message
    let action: HealthAction?

    init(kind: Kind, severity: HealthSeverity, message: Message, action: HealthAction? = nil) {
        self.kind = kind
        self.severity = severity
        self.message = message
        self.action = action
    }
}

/// Rapport complet d'état de santé du bandeau.
struct HealthBannerReport: Sendable, Equatable {
    let agentRow: HealthRow
    let writeLockRow: HealthRow
    let semanticRow: HealthRow
    let rootsRow: HealthRow

    var rows: [HealthRow] {
        [agentRow, writeLockRow, semanticRow, rootsRow]
    }

    /// Vrai si les quatre lignes sont au vert ET qu'aucune ne propose de
    /// geste : la barre latérale ne montre alors que la pastille « Tout
    /// fonctionne ».
    ///
    /// La seconde condition n'est pas une coquetterie (A2-13). Sans racine,
    /// les quatre lignes sont vertes — l'agent est éteint, le verrou libre, le
    /// modèle absent, les dossiers « aucun » — et la pastille masquait la
    /// ligne « Aucun dossier à indexer » avec son bouton « Ajouter un
    /// dossier… », que le §5.6 amendé exige NOMMÉMENT comme la seule exception
    /// à « une ligne verte ne porte pas de bouton ». Le cas s'atteint dès que
    /// `rootsError != nil` : la barre latérale s'affiche, annonce que tout va
    /// bien, et le seul geste utile n'est nulle part.
    var isAllGreen: Bool {
        rows.allSatisfy { $0.severity == .green && $0.action == nil }
    }

    /// Les lignes que la barre latérale rend quand la pastille ne suffit pas.
    ///
    /// Tout est vert mais un geste reste proposé : on ne montre QUE la ligne
    /// actionnable — les trois autres n'ont rien à dire, et les afficher
    /// ferait un bandeau de quatre lignes pour une seule information.
    var rowsToDisplay: [HealthRow] {
        maxSeverity == .green ? rows.filter { $0.action != nil } : rows
    }

    var maxSeverity: HealthSeverity {
        rows.map(\.severity).max() ?? .green
    }
}

/// Évaluation pure de l'état de santé.
enum HealthBannerEvaluator {

    static func evaluate(
        agentState: AgentOperationalState,
        appCopies: AppCopiesReport.Verdict = .ok,
        lockStatus: WriteLock.LockStatus,
        semanticInstalled: Bool,
        hasVectors: Bool,
        roots: [RootStatus],
        /// Le processus courant, DONNÉ et non lu ici : l'évaluation reste pure,
        /// et le test peut jouer « c'est moi » comme « c'est un autre » (BU-31).
        currentPID: pid_t = getpid()
    ) -> HealthBannerReport {
        HealthBannerReport(
            agentRow: evaluateAgent(agentState, appCopies: appCopies),
            writeLockRow: evaluateLock(lockStatus, currentPID: currentPID),
            semanticRow: evaluateSemantic(installed: semanticInstalled, hasVectors: hasVectors),
            rootsRow: evaluateRoots(roots)
        )
    }

    // MARK: - 1. Indexation en arrière-plan

    /// `.off` : l'utilisateur l'a éteinte, c'est son choix — vert. `.notFound`
    /// est orange et non rouge : rien n'est perdu, il faut ré-enregistrer.
    private static func evaluateAgent(
        _ state: AgentOperationalState,
        appCopies: AppCopiesReport.Verdict
    ) -> HealthRow {
        // Plusieurs copies de Fouine.app : c'est LA cause connue d'un agent
        // enregistré qui ne démarre pas (lot J2). Elle ne se déduit d'aucun
        // message de launchd — il faut la nommer, sinon l'utilisateur presse
        // « Ré-enregistrer » en boucle sans effet.
        let severalCopies: Bool
        if case .multipleCopies = appCopies { severalCopies = true } else { severalCopies = false }

        switch state {
        case .active:
            return HealthRow(kind: .agent, severity: .green, message: .backgroundIndexingOn)
        case .waitingFirstReport:
            return HealthRow(kind: .agent, severity: .green, message: .backgroundIndexingStarting)
        case .off:
            return HealthRow(kind: .agent, severity: .green, message: .backgroundIndexingOff)
        case .registeredButSilent:
            return HealthRow(kind: .agent, severity: .orange,
                             message: severalCopies ? .backgroundIndexingSeveralCopies
                                                    : .backgroundIndexingNotStarting,
                             action: .reregisterAgent)
        case .requiresApproval:
            return HealthRow(kind: .agent, severity: .orange, message: .backgroundIndexingAwaitingApproval,
                             action: .openLoginItems)
        case .notFound:
            return HealthRow(kind: .agent, severity: .orange,
                             message: severalCopies ? .backgroundIndexingSeveralCopies
                                                    : .backgroundIndexingServiceMissing,
                             action: .reregisterAgent)
        case .unknown:
            // Aucun geste connu ne répare un état que l'on ne sait pas lire :
            // le dire, sans alarmer.
            return HealthRow(kind: .agent, severity: .green, message: .backgroundIndexingUnknown)
        }
    }

    // MARK: - 2. Index (verrou d'écriture)

    /// Tenu = l'index se met à jour, périmé = se répare seul : vert dans les
    /// deux cas, jamais de bouton.
    private static func evaluateLock(_ status: WriteLock.LockStatus,
                                     currentPID: pid_t) -> HealthRow {
        switch status {
        case .free, .stale:
            return HealthRow(kind: .writeLock, severity: .green, message: .indexAvailable)
        case .held(let holder):
            // Le pid, et pas le rôle (BU-31). Une passe lancée depuis cette
            // fenêtre prend le verrou sous le rôle « app » — mais une SECONDE
            // Fouine ouverte sur la même base l'aurait pris sous le même rôle,
            // et ce serait alors bel et bien « un autre programme ».
            return HealthRow(kind: .writeLock, severity: .green,
                             message: .indexUpdating(by: holder.role,
                                                     since: holder.clockText,
                                                     ownProcess: holder.pid == currentPID))
        }
    }

    // MARK: - 3. Recherche sémantique

    /// Une option absente n'est pas un avertissement : le téléchargement se
    /// propose déjà dans Réglages ▸ Sémantique et sur l'écran d'accueil.
    /// `hasVectors` est un BOOLÉEN, pas un compte (A2-08) : la ligne n'a
    /// jamais eu besoin d'autre chose, et le compte exact coûtait un balayage
    /// complet de `page_vec` toutes les 30 secondes.
    private static func evaluateSemantic(installed: Bool, hasVectors: Bool) -> HealthRow {
        guard installed else {
            return HealthRow(kind: .semantic, severity: .green, message: .semanticNotInstalled)
        }
        if hasVectors {
            return HealthRow(kind: .semantic, severity: .green, message: .semanticReady)
        }
        return HealthRow(kind: .semantic, severity: .green, message: .semanticPreparing)
    }

    // MARK: - 4. Dossiers

    /// Seules les racines ACTIVES comptent : un dossier que l'utilisateur a
    /// désactivé — un disque externe rangé, par exemple — n'est plus une
    /// promesse à tenir.
    private static func evaluateRoots(_ roots: [RootStatus]) -> HealthRow {
        if roots.isEmpty {
            return HealthRow(kind: .roots, severity: .green, message: .noFolders, action: .chooseRoots)
        }
        let active = roots.filter(\.record.enabled)
        if let unmounted = active.first(where: { !$0.mounted }) {
            return HealthRow(kind: .roots, severity: .orange,
                             message: .diskNotPluggedIn(folder: unmounted.label))
        }
        // Le geste des Réglages Système ne vaut que pour un REFUS de macOS
        // (`probeReason`, PB1) : un dossier déplacé ou vide y envoyait
        // l'utilisateur cocher une case qui ne répare rien. Le refus passe
        // devant les autres cas : c'est le seul qu'un bouton répare.
        let unreadable = active.filter { !$0.readable }
        if let denied = unreadable.first(where: { $0.probeReason == .permissionDenied }) {
            return HealthRow(kind: .roots, severity: .orange,
                             message: .folderNotAllowed(folder: denied.label),
                             action: .openPrivacySettings)
        }
        if let missing = unreadable.first(where: { $0.probeReason == .missing }) {
            return HealthRow(kind: .roots, severity: .orange,
                             message: .folderNotFound(folder: missing.label))
        }
        if let other = unreadable.first {
            return HealthRow(kind: .roots, severity: .orange,
                             message: .folderCannotBeRead(folder: other.label))
        }
        return HealthRow(kind: .roots, severity: .green, message: .foldersAllAccessible)
    }
}
