// NotificationConsent.swift — ce que la case « Me prévenir quand toutes les
// pages scannées sont lues » a le droit d'afficher (audit BU-23, lot UX3).
// Propriété : A-App.
//
// LE DÉFAUT MESURÉ. Cocher la case écrivait le réglage AVANT de demander
// l'autorisation à macOS. La bannière du système est restée quatre minutes
// sans réponse, la case est restée cochée, et quand la file de pages scannées
// s'est vidée, aucun message n'est venu (09/09/2026). L'utilisateur avait
// coché une promesse que rien ne tenait, et rien ne le lui disait.
//
// L'ORDRE EST DONC INVERSÉ, et c'est tout le mécanisme : on demande, on RELIT
// l'état auprès du système — jamais le `granted` rendu par la demande, qui
// vaut faux aussi bien pour un refus que pour une bannière ignorée —, et on
// n'écrit le réglage que si l'autorisation est là. Sinon la case revient à
// zéro et dit ce qui manque, avec le geste à faire.
//
// Ce fichier ne contient QUE la décision, sans interface ni système : c'est ce
// qui la rend éprouvable (`NotificationConsentTests`). La vue s'en sert pour
// trois choses : la position de la case, la ligne sous elle, et le lien.

import Foundation
import UserNotifications

enum NotificationConsent {

    /// Ce qui s'affiche sous la case quand la promesse ne peut pas être tenue.
    enum Notice: Equatable {
        /// macOS n'a pas encore dit oui : bannière ignorée, refus, ou
        /// autorisation retirée depuis les Réglages Système.
        case notAllowed
        /// Pas de bundle (`swift run FouineApp`) : le système ne connaît même
        /// pas l'application, et la demander ferait planter le processus.
        case unavailable

        var message: String {
            switch self {
            case .notAllowed:
                return String(localized: "macOS hasn't allowed Fouine's messages yet")
            case .unavailable:
                return String(localized: "Notifications require the installed application (Fouine.app): they do not work from “swift run FouineApp”.")
            }
        }

        /// Le volet des Réglages Système où l'autorisation se donne. Nil quand
        /// il n'y a rien à y régler : hors bundle, Fouine n'y figure pas.
        var settingsURL: URL? {
            switch self {
            case .notAllowed:
                return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            case .unavailable:
                return nil
            }
        }
    }

    /// Où doit être la case, et que faut-il dire sous elle.
    ///
    /// - Parameter wanted: ce que l'utilisateur vient de demander (ou ce que le
    ///   réglage dit, à l'ouverture de l'onglet).
    /// - Parameter status: l'état RELU auprès du système, `nil` hors bundle.
    static func resolve(wanted: Bool, status: UNAuthorizationStatus?)
    -> (switchOn: Bool, notice: Notice?) {
        // Décocher n'a rien à demander à personne : aucun message ne partira,
        // c'est exactement ce qui vient d'être demandé.
        guard wanted else { return (false, nil) }
        guard let status else { return (false, .unavailable) }
        switch status {
        case .authorized, .provisional:
            // « provisional » livre les messages silencieusement, dans le
            // centre de notifications : ils ARRIVENT, ce que la case promet.
            // Fouine ne le demande jamais elle-même — il vient des Réglages
            // Système —, mais le traiter comme un refus éteindrait une case
            // qui, elle, marcherait.
            return (true, nil)
        case .denied, .notDetermined:
            // `.notDetermined` après une demande = bannière ignorée : le cas
            // mesuré, et le pire, puisque rien ne s'est passé du tout.
            return (false, .notAllowed)
        case .ephemeral:
            // App Clips : hors de portée d'une application installée.
            return (false, .notAllowed)
        @unknown default:
            return (false, .notAllowed)
        }
    }
}
