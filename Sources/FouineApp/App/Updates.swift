// Updates.swift — mises à jour Sparkle 2 (audit produit D13, palier 2.9).
// Propriété : A-Pack.
//
// Fouine est distribuée hors App Store, en DMG téléchargé une fois. Sans
// mécanisme de mise à jour, un correctif de sécurité — la faille `bsdtar` du
// 01/09 en est l'exemple — ne parvient jamais à qui a déjà installé l'app.
// Sparkle 2 est la seule implémentation éprouvée sur macOS ; elle fonctionne en
// runtime durci SANS bac à sable, exactement notre configuration.
//
// ─── ÉTEINTE PAR DÉFAUT, ET CE N'EST PAS UN DÉTAIL ────────────────────────
// `SUEnableAutomaticChecks = false` est écrit explicitement dans l'Info.plist.
// Cette clé fait DEUX choses, et c'est la seconde qui compte :
//   1. elle met `automaticallyChecksForUpdates` à faux ;
//   2. elle empêche Sparkle de POSER LA QUESTION au deuxième lancement.
// Sans elle, une app qui promet « zéro réseau » ouvre au bout de deux
// démarrages une boîte de dialogue proposant d'envoyer des données à un
// serveur : la promesse est cassée avant même que l'utilisateur ait répondu.
// Tant qu'il n'a ni cliqué « Rechercher les mises à jour… » ni armé
// l'interrupteur des réglages, RIEN ne sort de la machine (docs/privacy.md).
//
// ─── L'APP NE DOIT JAMAIS ÉCHOUER À CAUSE DE SPARKLE ──────────────────────
// `SPUStandardUpdaterController` est construit avec `startingUpdater: false`,
// puis démarré par `try updater.start()`. Le démarrage ÉCHOUE quand le bundle
// est mal configuré — `SUPublicEDKey` vide, ou une clé qui ne correspond à
// aucune signature. Ce n'est plus l'état du dépôt : la clé PUBLIQUE est dans
// `Packaging/Info.plist` depuis le 02/09/2026, et c'est sa place — la clé
// PRIVÉE, elle, n'y a jamais été (trousseau et secret GitHub). Le cas reste
// atteignable par un fork qui n'a pas encore lancé `generate_keys`. Le
// `startUpdater()` du contrôleur, lui, journalise ET affiche une alerte au bout
// de quelques secondes : inacceptable pour un utilisateur qui n'a rien demandé.
// On prend donc la variante qui rend l'erreur, on la note, et l'élément de menu
// se désactive avec une aide qui dit pourquoi. L'app reste utilisable.
//
// Hors bundle (`swift run FouineApp`), rien de tout cela n'existe : pas de
// Info.plist, pas de mise à jour possible. `isSupported` le dit.

import Foundation
import AppKit
import os
import Sparkle

/// Ce que Fouine sait des mises à jour hors de Sparkle.
enum Updates {
    /// La page où l'on télécharge Fouine à la main.
    ///
    /// `nil` TANT QU'IL N'Y A PAS DE SITE (décision du 09/09/2026) : une
    /// alerte qui renvoie vers une adresse qui n'existe pas est pire que pas
    /// d'adresse du tout. La ligne « ou téléchargez-la depuis … » n'apparaît
    /// que le jour où cette constante est posée.
    static let downloadPage: URL? = nil
}

/// Le contrôleur Sparkle de l'app, sa disponibilité et son état d'erreur.
///
/// Un seul exemplaire, tenu par la scène SwiftUI (`FouineDesktopApp`) : Sparkle
/// exige le fil principal et un `SPUUpdater` unique par bundle hôte.
@MainActor
final class UpdatesController: ObservableObject {

    private static let log = Logger(subsystem: "io.github.basedpolymer.fouine", category: "updates")

    /// Nil si l'app ne tourne pas depuis un bundle : sans `Info.plist` de
    /// bundle, Sparkle n'a ni flux, ni clé, ni rien à remplacer.
    private let controller: SPUStandardUpdaterController?

    /// Raison pour laquelle les mises à jour sont indisponibles, dans la langue
    /// de l'utilisateur (info-bulle du menu, ligne des réglages). Nil quand tout
    /// va bien.
    @Published private(set) var unavailableReason: String?

    /// Redonné à l'interface après chaque changement d'un réglage : les
    /// propriétés de `SPUUpdater` ne sont pas des `@Published`.
    @Published private(set) var revision: Int = 0

    /// La dernière vérification s'est-elle terminée sans joindre le serveur ?
    ///
    /// Sparkle affiche, LUI, « Erreur pendant la mise à jour ! … Annuler la
    /// mise à jour » — trois choses fausses pour le public visé : aucune mise
    /// à jour n'était en cours, il n'y a rien à annuler, et rien ne dit s'il
    /// faut s'inquiéter (audit BU-22). Cette boîte appartient au pilote
    /// standard de Sparkle et ne se remplace pas sans écrire un `SPUUserDriver`
    /// entier ; l'onglet des réglages, lui, dit la chose en français de Fouine.
    @Published private(set) var lastCheckFailed = false

    /// Le délégué de l'`SPUUpdater`. Un objet à part, et non le contrôleur
    /// lui-même : `SPUUpdaterDelegate` est un protocole Objective-C, que cette
    /// classe `@MainActor` ne peut pas adopter sans se contorsionner.
    private let hook = UpdatesHook()

    init() {
        // Un bundle ? Les deux tests du dépôt sont bons, contrairement à ce que
        // ce commentaire affirmait (A2-18). MESURÉ, exécutable nu bâti par
        // `swiftc` : `Bundle.main.bundleIdentifier` vaut **nil**,
        // `Bundle.main.bundleURL` vaut le dossier courant et son extension est
        // vide. `Notifier.isAvailable` (identifiant non nil) et le test
        // ci-dessous (extension du chemin) disent donc la même chose ; celui-ci
        // est simplement plus précis, puisqu'il exige un `.app` et pas un
        // bundle quelconque.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            self.controller = nil
            self.unavailableReason = String(localized: "Fouine is not running from Fouine.app: automatic updates only apply to an installed application.")
            Self.log.notice("Sparkle non démarré : exécution hors bundle")
            return
        }

        // `startingUpdater: false` : on veut l'erreur, pas l'alerte.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: hook, userDriverDelegate: nil)
        self.controller = controller
        // Le rappel est posé APRÈS l'initialisation du stockage : `hook` est
        // retenu par le contrôleur, `self` ne l'est que faiblement — pas de
        // cycle.
        hook.onCycleFinished = { [weak self] failed in
            self?.lastCheckFailed = failed
            self?.revision &+= 1
        }

        do {
            try controller.updater.start()
            Self.log.notice("Sparkle démarré — flux \(controller.updater.feedURL?.absoluteString ?? "aucun", privacy: .public), vérification automatique \(controller.updater.automaticallyChecksForUpdates ? "armée" : "éteinte", privacy: .public)")
        } catch {
            // Cas d'un fork, ou d'un build dont `SUPublicEDKey` a été vidée.
            // On le dit sans dramatiser : l'app marche, seule la recherche de
            // mise à jour est hors service.
            self.unavailableReason = String(localized: "This copy of Fouine is not configured for updates (signing key missing). Download the latest version from the project's releases page.\n\nDetail: \(error.localizedDescription)")
            Self.log.error("Sparkle n'a pas démarré : \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Ce que l'interface consulte

    /// Faux quand Sparkle n'a pas pu démarrer : l'élément de menu et le bouton
    /// des réglages se désactivent, avec `unavailableReason` en info-bulle.
    var isSupported: Bool { controller != nil && unavailableReason == nil }

    /// Sparkle refuse une vérification pendant qu'une session est en cours.
    var canCheckNow: Bool {
        guard let updater = controller?.updater, isSupported else { return false }
        return updater.canCheckForUpdates
    }

    /// L'adresse effectivement contactée, telle que Sparkle la voit — donc la
    /// vraie, pas celle que nous croyons avoir mise dans l'Info.plist.
    var feedURL: URL? { controller?.updater.feedURL }

    var lastCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    /// Interrupteur « Rechercher automatiquement les mises à jour ». Faux par
    /// défaut (`SUEnableAutomaticChecks`) et persisté par Sparkle dans les
    /// préférences du bundle hôte.
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            revision &+= 1
        }
    }

    /// Intervalle entre deux vérifications, en secondes. Sans effet tant que
    /// `automaticallyChecks` est faux.
    var checkInterval: TimeInterval {
        get { controller?.updater.updateCheckInterval ?? 86_400 }
        set {
            controller?.updater.updateCheckInterval = newValue
            revision &+= 1
        }
    }

    // MARK: - Gestes de l'utilisateur

    /// « Rechercher les mises à jour… » — la SEULE façon dont une connexion
    /// sortante part de Fouine sans que l'utilisateur ait armé l'interrupteur.
    func checkForUpdates() {
        guard let updater = controller?.updater, isSupported else { return }
        // L'échec précédent ne vaut plus : c'est une nouvelle tentative.
        lastCheckFailed = false
        updater.checkForUpdates()
        revision &+= 1
    }

    /// Ce que Fouine dit quand la vérification n'aboutit pas. Pas d'adresse de
    /// téléchargement tant qu'il n'y a pas de site (`Updates.downloadPage`).
    var failureMessage: String {
        let base = String(localized: "Fouine could not check whether a newer version exists. Try again later. Fouine keeps working as it is.")
        guard let page = Updates.downloadPage else { return base }
        return base + " " + String(localized: "Or download it from \(page.absoluteString).")
    }
}

// MARK: - Le délégué de Sparkle (audit BU-22)

/// Un `NSObject` minuscule dont le seul rôle est de rapporter qu'une
/// vérification s'est terminée sans réponse du serveur.
///
/// Sparkle appelle ses délégués sur le fil principal. Le rappel remonte au
/// contrôleur, qui est `@MainActor` : `MainActor.assumeIsolated` dit ce fait au
/// compilateur au lieu de repasser par une `Task`, qui afficherait l'état un
/// tour de boucle plus tard.
private final class UpdatesHook: NSObject, SPUUpdaterDelegate {

    /// `true` = la vérification a échoué (réseau, serveur, flux illisible) ;
    /// `false` = elle a abouti, y compris sur « aucune nouvelle version ».
    var onCycleFinished: ((Bool) -> Void)?

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // « Aucune mise à jour trouvée » passe par le MÊME chemin qu'un échec
        // réseau : sans ce tri, une vérification parfaitement réussie ferait
        // dire à l'onglet que le serveur est injoignable.
        let noUpdate = (error as NSError).code == Int(SUError.noUpdateError.rawValue)
        MainActor.assumeIsolated { onCycleFinished?(!noUpdate) }
    }
}
