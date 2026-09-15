// LicenseTerms.swift — ce que Fouine vend, en constantes (lot L1C).
// Propriété : A-Core.
//
// Fouine se vend une fois, 39 €, mises à jour à vie, avec un essai complet de
// 30 jours (décisions du 09/09 et du 13/09/2026). Le marchand est Creem —
// « merchant of record » : c'est lui qui encaisse, gère la TVA de chaque pays
// et envoie la clé. L'application ne parle JAMAIS à l'API de Creem : ses points
// de licence exigent la clé API SECRÈTE du marchand, qu'un binaire distribué ne
// peut pas porter. Elle parle à un relais, qui la porte, lui.
//
// TOUT CE QUI EST ICI EST PUBLIC ET VÉRIFIABLE : deux adresses, trois nombres,
// un prix. Rien d'autre n'est nécessaire pour dire à quelqu'un ce que Fouine
// contacte et pourquoi (docs/privacy.md).

import Foundation

public enum LicenseTerms {

    /// Durée de l'essai, en jours. Complet : rien n'est bridé pendant ces
    /// 30 jours — c'est le modèle Aseprite, et le seul honnête pour un outil
    /// qu'on ne peut juger qu'en lui donnant son propre fonds de documents.
    public static let trialDays = 30

    /// Nombre de Mac par clé. C'est la limite posée CÔTÉ CREEM : l'application
    /// ne la compte pas elle-même — elle lit `activation_limit` dans la réponse
    /// et l'affiche. Un compte tenu localement serait à la fois faux (deux Mac
    /// ne se parlent pas) et contournable.
    public static let activationLimit = 3

    /// Le prix, tel qu'il est écrit sur le bouton d'achat. TTC, en euros :
    /// Creem étant marchand de référence, c'est bien ce que la personne paie,
    /// quelle que soit sa TVA.
    public static let priceDisplay = "€39"

    /// La page de paiement Creem du produit `prod_5ZfJoGBRk7vxCN8xMqvOcR`.
    /// Ouverte dans le NAVIGATEUR, jamais dans une vue web embarquée : un
    /// paiement se fait dans le navigateur de la personne, où elle voit
    /// l'adresse et le cadenas.
    public static let purchaseURL = URL(
        string: "https://www.creem.io/product/prod_5ZfJoGBRk7vxCN8xMqvOcR")!

    /// Le relais. Il porte la clé API secrète du marchand et se contente de
    /// transmettre à Creem trois appels — activer, vérifier, désactiver — en
    /// rendant le code HTTP et le corps de Creem tels quels.
    public static let defaultRelayURL = URL(
        string: "https://basedpolymer.eu/api/fouine/license")!

    /// La variable qui remplace le relais, pour les essais (LC2) : le même
    /// relais servi en local contre le bac à sable de Creem.
    public static let relayVariable = "FOUINE_LICENSE_RELAY"

    /// L'adresse effectivement contactée, lue UNE fois au démarrage du
    /// processus : `FOUINE_LICENSE_RELAY` si elle est acceptée, sinon le relais.
    public static let relayURL: URL = resolvedRelayURL()

    public static func resolvedRelayURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let raw = environment[relayVariable], !raw.isEmpty else {
            return defaultRelayURL
        }
        return acceptedRelayURL(raw) ?? defaultRelayURL
    }

    /// `https://` n'importe où, ou `http://127.0.0.1:<port>` — rien d'autre.
    ///
    /// Une clé achetée voyage dans ce corps : en clair, elle ne peut aller
    /// qu'à cette machine-ci, par l'adresse de bouclage écrite en chiffres.
    /// Pas `localhost`, qu'un fichier `hosts` peut envoyer ailleurs.
    public static func acceptedRelayURL(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        switch scheme {
        case "https":
            return url
        case "http":
            return host == "127.0.0.1" && components.port != nil ? url : nil
        default:
            return nil
        }
    }

    /// Entre deux vérifications silencieuses d'une licence déjà activée : au
    /// plus une tous les 30 jours, au lancement de l'application ou quand on
    /// demande `fouine license status` — jamais pendant une indexation.
    ///
    /// Pourquoi si rare. Une vérification par lancement ferait de Fouine un
    /// logiciel qui appelle son éditeur tous les jours — ce que la page de vie
    /// privée promet précisément le contraire. Une par mois suffit à retirer
    /// une clé remboursée ou frauduleuse, et un mois hors ligne ne coupe
    /// personne : hors ligne, il ne se passe rien du tout.
    public static let revalidationInterval: TimeInterval = 30 * 24 * 3600

    /// Le délai de garde d'un appel au relais. 15 s : un aller-retour normal
    /// tient en moins d'une seconde, et personne ne doit regarder une roue
    /// tourner plus longtemps que cela pour apprendre que le réseau est absent.
    public static let requestTimeout: TimeInterval = 15
}
