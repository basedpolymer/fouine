// LicenseCheck.swift — ce qu'une vérification change au fichier (lot LC2).
// Propriété : A-Core.
//
// L'application la joue au lancement, `fouine license status` quand on la lui
// demande : DEUX appelants, UNE décision. Elle était écrite dans
// `LicenseModel.revalidateIfDue`, où la ligne de commande ne pouvait pas la
// lire, et elle ne regardait que le statut de la clé — un Mac libéré depuis le
// portail restait donc sous licence pour toujours (mesures du 14/09/2026,
// `~/Fouine-verif/session-2026-09-14-soir/mesures-licence/`).
//
// Pure, comme `LicenseState` : on lui donne le fichier, le résultat de l'appel
// et une date, elle rend le fichier suivant — ou rien, quand rien ne doit
// changer. Écrire et publier restent aux appelants.

import Foundation

public enum LicenseCheck {

    /// Une vérification est-elle due ? Seulement si une clé est posée ET
    /// qu'elle n'a pas été vue depuis 30 jours (ou jamais).
    public static func isDue(_ file: LicenseFile?, now: Date = Date()) -> Bool {
        guard let file, file.hasKey else { return false }
        guard let checked = file.lastChecked else { return true }
        return now.timeIntervalSince(checked) >= LicenseTerms.revalidationInterval
    }

    /// Le fichier après la vérification, ou `nil` si rien ne doit changer.
    ///
    /// - La clé ET l'instance sont actives : sous licence, date de vérification
    ///   posée.
    /// - La clé est désactivée ou expirée (remboursement, fraude) : révoquée.
    ///   Le vendeur a décidé ; la clé reste dans le fichier pour qu'une
    ///   réactivation côté vendeur la rende à la vérification suivante.
    /// - La clé sert encore ailleurs (`active`) ou plus nulle part
    ///   (`inactive`), mais CE Mac n'est plus compté — instance `deactivated`,
    ///   ou 404 d'instance inconnue : libéré. La clé est oubliée.
    /// - Hors ligne, relais en panne, réponse illisible : RIEN NE CHANGE, pas
    ///   même la date — sinon on n'essaierait plus avant un mois.
    public static func file(after result: Result<LicenseResponse, Error>,
                            of file: LicenseFile,
                            now: Date = Date()) -> LicenseFile? {
        switch result {
        case .failure(let error):
            guard case LicenseClientError.instanceNotFound = error else { return nil }
            return file.released()

        case .success(let response):
            // Une réponse qui ne dit RIEN de l'instance ne libère personne :
            // le relais rend le corps de Creem tel quel, qui la porte toujours
            // (mesuré) ; son absence serait une panne, pas une libération.
            let silentAboutInstance = response.isActive && response.instance == nil
            if response.instanceIsActive || silentAboutInstance {
                return checked(file, response, now, .active)
            }
            switch response.status {
            case "active", "inactive":
                return file.released()
            default:
                return checked(file, response, now, .revoked)
            }
        }
    }

    private static func checked(_ file: LicenseFile, _ response: LicenseResponse,
                                _ now: Date, _ state: LicenseFile.State) -> LicenseFile {
        var next = file
        next.lastChecked = now
        next.activationLimit = response.activationLimit ?? file.activationLimit
        next.state = state
        return next
    }
}
