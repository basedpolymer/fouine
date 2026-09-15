// AgentOperationalState.swift — états croisés de l'agent d'arrière-plan.
// B1-05 : machine à états pure reliant SMAppService et agent_status.

import Foundation
import ServiceManagement
import FouineCore

/// État opérationnel de l'agent d'arrière-plan, croisant la déclaration SMAppService
/// et l'activité réelle enregistrée en base.
public enum AgentOperationalState: String, Equatable, Sendable {
    /// Désactivé (interrupteur éteint ou service non enregistré).
    case off
    /// Armé depuis moins de 5 min mais aucun rapport n'a encore été publié.
    case waitingFirstReport
    /// Enregistré et publiant des rapports frais.
    case active
    /// Enregistré / armé mais aucun rapport publié depuis plus de 5 min ou rapport périmé.
    case registeredButSilent
    /// En attente d'approbation dans Réglages Système.
    case requiresApproval
    /// Binaire ou plist introuvable (l'app doit être installée et signée).
    case notFound
    /// État inconnu.
    case unknown
}

/// Machine à états pure, testable sans launchd réel.
public enum AgentStateMachine {

    /// Évalue l'état opérationnel à partir de données pures.
    ///
    /// - Parameters:
    ///   - serviceStatus: Statut renvoyé par `SMAppService.status`.
    ///   - switchEnabled: Position de l'interrupteur « Mettre l'index à jour automatiquement ».
    ///   - agentStatus: Dernier enregistrement `agent_status` lu en base.
    ///   - enabledAt: Date à laquelle l'interrupteur a été armé (nil si inconnu / au lancement).
    ///   - now: Date de référence pour le calcul de fraîcheur.
    ///   - staleThreshold: Durée au-delà de laquelle l'absence de rapport est considérée comme un silence.
    /// - Returns: L'état opérationnel déterminé.
    public static func evaluate(
        serviceStatus: SMAppService.Status,
        switchEnabled: Bool,
        agentStatus: AgentStatusRecord?,
        enabledAt: Date?,
        now: Date = Date(),
        staleThreshold: TimeInterval = AgentStatusRecord.staleAfter
    ) -> AgentOperationalState {
        switch serviceStatus {
        case .requiresApproval:
            return .requiresApproval

        case .notFound:
            return .notFound

        case .notRegistered:
            return .off

        case .enabled:
            guard switchEnabled else {
                return .off
            }

            if let agentStatus {
                if agentStatus.isStale(at: now) {
                    return .registeredButSilent
                }
                return .active
            } else {
                // Aucun rapport en base pour le moment
                if let enabledAt {
                    let elapsed = now.timeIntervalSince(enabledAt)
                    if elapsed >= 0 && elapsed < staleThreshold {
                        return .waitingFirstReport
                    }
                }
                // Si l'heure d'activation est inconnue ou dépasse le délai : silencieux
                return .registeredButSilent
            }

        @unknown default:
            return switchEnabled ? .unknown : .off
        }
    }
}
