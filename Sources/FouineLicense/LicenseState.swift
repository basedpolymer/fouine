// LicenseState.swift — cinq états, une fonction pure (lots L1C, LC2).
// Propriété : A-Core.
//
// C'est ici que se décide TOUT ce que la licence commande, et c'est pour cela
// que le type ne connaît ni fichier, ni réseau, ni horloge : on lui donne le
// contenu du fichier et une date, il rend l'état. Tout le reste du produit —
// l'application, l'agent, la ligne de commande — ne fait que le lire.
//
// ─── LA FIN D'ESSAI EST DOUCE, ET C'EST UN CHOIX DE PRODUIT ────────────────
// `allowsIndexing` ne commande QUE la mise à jour de l'index. La recherche,
// l'aperçu, l'export, le serveur MCP, `fouine search`, `status` et `doctor`
// marchent dans les cinq états, y compris révoqué. Ce que quelqu'un a indexé
// pendant son essai lui reste lisible pour toujours : Fouine n'a jamais promis
// autre chose, et prendre en otage l'index d'un fonds de documents personnel
// serait un tout autre produit que celui-ci.

import Foundation

public enum LicenseState: Equatable, Sendable {

    /// Essai en cours. `daysLeft` est ce qui reste à vivre, jamais négatif —
    /// au dernier jour il vaut 1, pas 0 : « il vous reste 0 jour » se lit comme
    /// « c'est fini », alors que la journée est encore entière.
    case trial(daysLeft: Int)

    /// Essai terminé, aucune clé. L'index cesse de se mettre à jour ; tout le
    /// reste continue.
    case trialOver

    /// Clé activée sur ce Mac. `maskedKey` ne montre que les six derniers
    /// caractères — assez pour reconnaître SA clé parmi deux, jamais assez pour
    /// la recopier depuis une capture d'écran.
    case licensed(maskedKey: String, lastChecked: Date?)

    /// Le vendeur a désactivé cette clé (remboursement, fraude, expiration).
    case revoked(reason: String)

    /// Ce Mac a été libéré ailleurs — depuis le portail client (LC2). Ce n'est
    /// PAS une fraude : la personne a rendu cette activation, la clé est
    /// oubliée, et l'essai reprend son cours là où il en était.
    /// `trialDaysLeft` vaut 0 quand l'essai est terminé, ce qui est presque
    /// toujours le cas : une vérification n'a lieu que 30 jours après
    /// l'activation, qui suit elle-même le début de l'essai.
    case released(trialDaysLeft: Int)

    /// L'index a-t-il le droit de se mettre à jour ?
    public var allowsIndexing: Bool {
        switch self {
        case .trial, .licensed: return true
        case .trialOver, .revoked: return false
        case .released(let left): return left > 0
        }
    }

    /// La valeur de la clé `state` du JSON de `fouine license status`.
    public var jsonName: String {
        switch self {
        case .trial:     return "trial"
        case .trialOver: return "trial_over"
        case .licensed:  return "licensed"
        case .revoked:   return "revoked"
        case .released:  return "released"
        }
    }

    // MARK: - La décision

    /// - Parameter file: le contenu de `license.json`, ou `nil` s'il est absent
    ///   ou illisible — auquel cas l'essai est réputé commencer MAINTENANT.
    ///   Le fichier n'a pas encore été écrit à cet instant ; c'est
    ///   `LicenseStore.ensureTrialStarted` qui s'en charge, une fois.
    public static func compute(file: LicenseFile?, now: Date = Date()) -> LicenseState {
        guard let file else { return .trial(daysLeft: LicenseTerms.trialDays) }

        if file.state == .revoked, file.hasKey {
            return .revoked(reason: "disabled")
        }
        if file.hasKey {
            return .licensed(maskedKey: mask(file.key ?? ""),
                             lastChecked: file.lastChecked)
        }

        let trial = trialState(started: file.trialStarted, now: now)
        if file.state == .released {
            if case .trial(let left) = trial { return .released(trialDaysLeft: left) }
            return .released(trialDaysLeft: 0)
        }
        return trial
    }

    /// L'essai seul : en cours, ou terminé.
    private static func trialState(started trialStarted: Date, now: Date) -> LicenseState {
        // HORLOGE RECULÉE. Une date de départ dans le futur compte comme
        // aujourd'hui : reculer l'horloge du Mac ne rallonge donc pas l'essai
        // d'un jour, et — ce qui compte davantage — un Mac dont la pile de
        // sauvegarde est morte, et qui redémarre en 2001, ne perd pas son essai
        // non plus. Les deux cas se traitent par la même ligne.
        let started = min(trialStarted, now)
        let elapsed = now.timeIntervalSince(started)
        let daysUsed = Int(floor(elapsed / 86_400))
        let left = LicenseTerms.trialDays - daysUsed
        return left > 0 ? .trial(daysLeft: left) : .trialOver
    }

    // MARK: - Habillage d'une clé

    /// Les six derniers caractères, précédés de points de suspension épais.
    /// Une clé plus courte que six caractères est rendue telle quelle : elle
    /// n'est de toute façon pas une clé Creem, et la masquer n'apprendrait rien.
    public static func mask(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 6 else { return trimmed }
        return "·····" + String(trimmed.suffix(6))
    }

    /// Les six derniers caractères NUS, pour la clé `key_suffix` du JSON de la
    /// ligne de commande : un script n'a que faire de nos points.
    public static func suffix(_ key: String) -> String {
        String(key.trimmingCharacters(in: .whitespacesAndNewlines).suffix(6))
    }

    /// Ce qu'une clé devient quand on la colle depuis un courriel.
    ///
    /// Le format Creem est `ABC123-XYZ456-XYZ456-XYZ456`. Un copier-coller
    /// ramène des espaces, un retour à la ligne, parfois des minuscules quand
    /// la personne l'a retapée. Refuser sa clé pour cela serait la punir d'un
    /// détail : on nettoie, et le champ accepte ce qu'elle a collé.
    public static func normalize(_ typed: String) -> String {
        String(typed.uppercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })
    }
}
