// AgentPaths.swift — emplacements de l'agent (SPEC §10). Propriété : A-Pack.
//
// La base est celle de la CLI et de l'app, à la variable d'environnement près :
// `FOUINE_DB` (chemin complet du .db). Les trois outils DOIVENT regarder la même
// base — c'est la seule chose qui les relie. Depuis le palier 2.3, ils ne le
// font plus par trois copies du même code mais par `FouinePaths` (FouineCore).
//
// LES RÉGLAGES ONT DÉMÉNAGÉ (audit U2). Ce fichier portait `extractJobs`,
// `ocrBudgetMinutes` et `pollSeconds`, lus dans l'environnement du processus —
// c'est-à-dire dans le plist du LaunchAgent, à l'intérieur du bundle signé,
// « des variables d'environnement que personne ne peut poser ». Ils vivent
// maintenant dans la table `settings` (`SettingKeys.agent*`), que la fenêtre de
// réglages ⌘, et `fouine config set` écrivent, et que l'agent relit à chaque
// tic. Les MÊMES variables d'environnement continuent de fonctionner et restent
// PRIORITAIRES (`SettingSpec.environmentVariable`) : un agent qu'on dépanne
// doit pouvoir l'être sans base accessible.
//
// Il reste ici ce qui n'est pas un réglage d'utilisateur : les chemins, et le
// délai de grâce à l'arrêt — une constante de protocole avec launchd, pas une
// préférence (au-delà de 20 s, launchd tue).

import Foundation
import FouineCore

enum AgentPaths {

    /// `~/Library/Application Support/Fouine/fouine.db`, ou `FOUINE_DB` (§10).
    static func databaseURL() -> URL { FouinePaths.databaseURL() }

    /// `~/Library/Logs/Fouine/fouine.log` (§10). C'est le SEUL canal de
    /// diagnostic d'un agent lancé par launchd. `FOUINE_AGENT_LOG` le détourne
    /// (test manuel) ; l'app ouvre le même fichier depuis la fenêtre de réglages.
    static func logURL() -> URL { FouinePaths.agentLogURL() }

    /// Le verrou de la base ouverte (§3, §5.1). L'agent en teste la
    /// DISPONIBILITÉ sans jamais le retenir : c'est le store qui le prend.
    ///
    /// Il recomposait « fouine.lock » à la main : depuis BU-30 le nom suit
    /// celui de la base, et l'agent doit sonder le MÊME fichier que le store.
    static func lockURL() -> URL { FouinePaths.lockURL(for: databaseURL()) }

    // MARK: - Arrêt

    /// Délai laissé au travail en vol après SIGTERM. launchd tue à 20 s : ce
    /// n'est pas une préférence, c'est la marge sous ce couperet — d'où son
    /// absence du catalogue de `Settings`.
    static var shutdownGraceSeconds: Double {
        guard let raw = ProcessInfo.processInfo.environment["FOUINE_AGENT_GRACE_SECONDS"],
              let value = Int(raw) else { return 15 }
        return Double(Swift.min(19, Swift.max(1, value)))
    }
}
