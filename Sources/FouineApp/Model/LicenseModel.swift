// LicenseModel.swift — ce que l'application sait de l'achat (lot L1C).
// Propriété : A-App.
//
// Un mandataire mince, et volontairement : toute la décision est dans
// `FouineLicense` (pur, testé état par état), tout le réseau est dans
// `LicenseClient` (testé par un `URLProtocol` de substitution). Il ne reste ici
// que ce qui appartient à une interface — un état publié, une roue qui tourne,
// et la phrase de chaque refus.
//
// ─── LES PHRASES SONT ÉCRITES ICI, PAS DANS LA VUE ─────────────────────────
// Chaque erreur du client devient UNE phrase et UN geste, dans la langue de
// l'utilisateur. Elles sont ici pour être lisibles d'un coup d'œil, à côté les
// unes des autres : c'est le seul endroit du produit où quelqu'un qui vient de
// payer 39 € peut se retrouver bloqué, et le ton de ces quatre phrases compte
// autant que le code qui les choisit.
//
// AUCUN APPEL AU LANCEMENT, SAUF UN. `revalidateIfDue()` ne sort que si la
// licence est activée ET vérifiée pour la dernière fois il y a plus de 30 jours.
// Hors ligne ou service en panne, rien ne change et on réessaie au prochain
// lancement : personne ne perd son logiciel parce qu'un serveur est tombé.

import Foundation
import AppKit
import os
import FouineLicense

@MainActor
final class LicenseModel: ObservableObject {

    private static let log = Logger(
        subsystem: "io.github.basedpolymer.fouine", category: "licence")

    /// L'état courant. Toute l'interface le lit, personne d'autre ne l'écrit.
    @Published private(set) var state: LicenseState = .trial(
        daysLeft: LicenseTerms.trialDays)

    /// La phrase affichée sous le champ après un refus. Effacée dès qu'on
    /// retente : une erreur qui reste à l'écran pendant la tentative suivante
    /// laisse croire qu'elle vient d'arriver.
    @Published var errorMessage: String?

    /// Vrai pendant un aller-retour : les boutons se désactivent, une roue
    /// tourne. Borné par le délai de garde de 15 s du client.
    @Published private(set) var busy = false

    private let fileURL: URL
    private let client: LicenseClient

    /// - Parameters:
    ///   - databaseURL: le fichier de licence vit à côté de la base
    ///     (`FOUINE_DB` l'emmène donc sur une copie jetable dans les tests).
    ///   - client: injectable pour les tests, qui n'ouvrent aucune connexion.
    init(databaseURL: URL = AppPaths.databaseURL(),
         client: LicenseClient = LicenseClient(version: FouineVersionString)) {
        self.fileURL = LicenseStore.fileURL(databaseURL: databaseURL)
        self.client = client
    }

    /// Au démarrage de l'application : l'essai commence s'il n'a jamais
    /// commencé, et l'état est publié.
    func start() {
        let file = LicenseStore.ensureTrialStarted(at: fileURL)
        state = LicenseState.compute(file: file)
    }

    /// Relit le fichier sans rien écrire (retour d'une autre fenêtre, de la
    /// ligne de commande, ou après une désinstallation partielle).
    func refresh() {
        state = LicenseState.compute(file: LicenseStore.load(at: fileURL))
    }

    var allowsIndexing: Bool { state.allowsIndexing }

    // MARK: - Les trois gestes

    func activate(key typed: String) async {
        let key = LicenseState.normalize(typed)
        guard !key.isEmpty else { return }
        errorMessage = nil
        busy = true
        defer { busy = false }
        do {
            let response = try await client.activate(key: key)
            guard response.instanceIsActive, let instance = response.instance else {
                // Une clé connue mais inutilisable (expirée, désactivée), ou
                // une instance que Creem ne rend pas active : le relais rend
                // 200 avec un autre statut, ce n'est pas une panne.
                errorMessage = Self.refusedMessage
                Self.log.notice("activation refused, status \(response.status, privacy: .public), instance \(response.instance?.status ?? "none", privacy: .public)")
                return
            }
            var file = LicenseStore.ensureTrialStarted(at: fileURL)
            file.key = key
            file.instanceID = instance.id
            file.instanceName = instance.name ?? LicenseClient.thisMacName()
            file.activatedAt = Date()
            file.lastChecked = Date()
            file.activationLimit = response.activationLimit
                ?? LicenseTerms.activationLimit
            file.state = .active
            try LicenseStore.save(file, to: fileURL)
            state = LicenseState.compute(file: file)
        } catch let error as LicenseClientError {
            errorMessage = Self.message(for: error)
            if case .keyRefused(let detail) = error {
                // Le texte de Creem n'est pas documenté : journal seulement.
                Self.log.notice("licence service said: \(detail, privacy: .public)")
            }
        } catch {
            // Écriture impossible (disque plein, dossier en lecture seule).
            errorMessage = String(localized: "The key was accepted, but Fouine could not save it. Check that your disk is not full, then try again.")
            Self.log.error("could not save the licence: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// « Désactiver ce Mac ». Le fichier est nettoyé même si le relais est
    /// injoignable : garder une clé morte sur ce Mac ne servirait personne, et
    /// le vendeur libère l'activation de son côté sur demande. Un Mac DÉJÀ
    /// libéré (400 « already deactivated », 404 d'instance) se nettoie donc
    /// aussi, sans message : il n'y avait plus rien à libérer.
    func deactivate() async {
        guard let file = LicenseStore.load(at: fileURL), file.hasKey,
              let key = file.key, let instance = file.instanceID else { return }
        errorMessage = nil
        busy = true
        defer { busy = false }
        do {
            _ = try await client.deactivate(key: key, instanceID: instance)
        } catch {
            Self.log.notice("deactivation could not reach the service: \(String(describing: error), privacy: .public)")
        }
        do {
            try LicenseStore.save(file.withoutKey(), to: fileURL)
            state = LicenseState.compute(file: LicenseStore.load(at: fileURL))
        } catch {
            errorMessage = String(localized: "Fouine could not update its licence file. Check that your disk is not full, then try again.")
        }
    }

    /// Vérification silencieuse au lancement, au plus une fois tous les
    /// 30 jours. Rien à l'écran : ni roue, ni alerte, ni message. Les seuls cas
    /// visibles sont la clé désactivée par le vendeur et ce Mac libéré depuis
    /// le portail — la carte « Index » et les réglages le disent alors, et le
    /// bouton d'activation revient. La décision est dans `LicenseCheck`, que
    /// `fouine license status` joue aussi.
    func revalidateIfDue(now: Date = Date()) async {
        guard let file = LicenseStore.load(at: fileURL),
              LicenseCheck.isDue(file, now: now),
              let key = file.key, let instance = file.instanceID else { return }
        let result: Result<LicenseResponse, Error>
        do {
            result = .success(try await client.validate(key: key, instanceID: instance))
        } catch {
            result = .failure(error)
        }
        guard let next = LicenseCheck.file(after: result, of: file, now: now) else {
            // HORS LIGNE OU SERVICE EN PANNE : RIEN NE CHANGE. Ni `lastChecked`
            // (sinon on n'essaierait plus avant un mois), ni l'état. On
            // réessaiera au prochain lancement.
            if case .failure(let error) = result {
                Self.log.notice("licence revalidation postponed: \(String(describing: error), privacy: .public)")
            }
            return
        }
        if next.state != .active {
            Self.log.notice("licence revalidation: \(next.state?.rawValue ?? "none", privacy: .public)")
        }
        try? LicenseStore.save(next, to: fileURL)
        state = LicenseState.compute(file: next, now: now)
    }

    /// Ouvre la page de paiement dans le navigateur.
    func buy() {
        NSWorkspace.shared.open(LicenseTerms.purchaseURL)
    }

    // MARK: - Les phrases

    private static let refusedMessage = String(localized: "This key cannot be used any more. Contact the seller with the e-mail you used to buy it.")

    static func message(for error: LicenseClientError) -> String {
        switch error {
        case .offline:
            return String(localized: "No connection: connect to the Internet and try again.")
        case .unknownKey:
            return String(localized: "This key is not recognised. Check for typos, or look for it in the e-mail Creem sent you.")
        case .keyRefused where error.isActivationLimit:
            return String(localized: "This key is already in use on 3 Macs. Deactivate one of them from Settings, or from your Creem customer portal.")
        case .keyRefused:
            // Tout autre refus — clé désactivée, expirée : dire « déjà sur
            // 3 Mac » enverrait la personne libérer un Mac pour rien (LC2).
            return refusedMessage
        case .instanceNotFound:
            return LicenseStatusText.headline(.released(trialDaysLeft: 0))
        case .serviceUnavailable, .malformed:
            return String(localized: "The licence service is unavailable right now. Your trial continues; try again later.")
        }
    }
}

/// La version de Fouine, telle que l'en-tête `User-Agent` la porte.
///
/// Recopiée depuis `FouineVersion` (FouineCore) au point d'appel plutôt que
/// liée : `FouineLicense` ne dépend que de Foundation, et c'est ce qui lui
/// permet d'être lue par les trois exécutables sans traîner le store.
let FouineVersionString: String = {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "1.0.0"
}()
