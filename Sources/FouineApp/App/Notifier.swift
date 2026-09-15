// Notifier.swift — la notification de fin d'OCR (audit F7). Propriété : A-App.
//
// « Aucune notification (`grep UNUserNotification` : 0). Pour un travail de
//   vingt heures, c'est le point d'abandon le plus probable. »
//
// DEPUIS L'APP, ET SEULEMENT DEPUIS L'APP. L'agent serait l'émetteur naturel —
// c'est lui qui vide la file — mais un exécutable launchd sans bundle propre n'a
// pas d'identité de notification : `UNUserNotificationCenter.current()` y est un
// PLANTAGE (« bundleProxy is nil »), pas un refus poli. L'app lit `agent_status`
// toutes les deux secondes et notifie à la transition ; si elle n'est pas
// ouverte, il n'y a pas de notification, et c'est documenté dans `docs/agent.md`.
//
// LE MÊME PIÈGE VAUT ICI. `swift run FouineApp` n'a pas non plus de bundle : le
// garde sur `Bundle.main.bundleIdentifier` n'est pas une précaution théorique,
// c'est la différence entre une session de développement et un crash au premier
// lot d'OCR terminé.
//
// L'AUTORISATION EST DEMANDÉE AU MOMENT DU GESTE — quand l'utilisateur coche
// « Me prévenir quand la file OCR est vide » —, jamais au démarrage : une invite
// système qui tombe sans qu'on ait rien demandé se refuse par réflexe, et le
// refus est définitif.
//
// ET ELLE EST RELUE APRÈS (audit BU-23). Le `granted` rendu par la demande ne
// distingue pas un refus d'une bannière restée sans réponse, et il ne dit rien
// d'une autorisation retirée depuis les Réglages Système pendant que Fouine
// était fermée. Seul `authorizationStatus` dit l'état réel ; c'est lui qui
// décide de la case (`NotificationConsent`).

import Foundation
import UserNotifications

enum Notifier {

    /// Vrai si le processus peut parler à `UNUserNotificationCenter`. Hors
    /// bundle (développement), non — et l'appeler quand même terminerait le
    /// processus.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Demande l'autorisation. Ne rend rien d'exploitable exprès : ce qui
    /// décide, c'est `authorizationStatus()` relu APRÈS (audit BU-23).
    static func requestAuthorization() async {
        guard isAvailable else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// L'état de l'autorisation tel que le système le voit, `nil` hors bundle.
    ///
    /// Relu à chaque affichage de l'onglet : une autorisation retirée dans les
    /// Réglages Système pendant que Fouine était fermée doit éteindre la case,
    /// et non la laisser promettre des messages qui n'arriveront pas.
    static func authorizationStatus() async -> UNAuthorizationStatus? {
        guard isAvailable else { return nil }
        return await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    /// Poste une notification immédiate. Silencieuse si le processus n'a pas de
    /// bundle, ou si l'autorisation n'a pas été donnée — jamais bloquante.
    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
