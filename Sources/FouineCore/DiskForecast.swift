// DiskForecast.swift — « l'index approche-t-il de la taille prévue ? » (MO-03).
// Propriété : A-Core. PUR : aucune entrée-sortie, donc testable ligne à ligne.
//
// Pourquoi. Le budget P5 de la SPEC (2,5 Go, amendement du 05/09/2026) n'était
// câblé nulle part : `fouine status` projetait « 4,9 GiB at 1 M » par une règle
// de trois LINÉAIRE depuis l'état COURANT, c'est-à-dire hors sujet à long
// terme (personne n'a un million de pages). Mesuré le 09/09/2026 sur la base de
// production : 2,151 Go pour 408 951 pages, soit 5,14 Kio/page ; c'est ce
// coût-là qui dit à quel nombre de pages le budget serait franchi, et c'est la
// seule échéance qui intéresse.
//
// Ce que la projection ne fait pas : rien ne s'arrête au budget (décision du
// propriétaire du 09/09/2026, n° 3). Fouine avertit — carte « Index », `status`,
// `doctor` — et continue d'indexer et d'OCRiser.

import Foundation

/// Où en est le poids de l'index par rapport à la taille prévue.
public struct DiskForecast: Sendable, Equatable {

    /// Trois niveaux, et l'avertissement commence AVANT la limite : découvrir
    /// le plafond en le crevant ne laisse aucune marge de manœuvre.
    public enum Level: String, Sendable {
        /// Sous `nearRatio` du budget : rien à dire.
        case ok
        /// Entre `nearRatio` et le budget : on prévient.
        case near
        /// Au-delà du budget. Fouine fonctionne toujours.
        case over
    }

    /// Le budget P5 de la SPEC §8.2, relevé à 2,5 Go le 05/09/2026.
    ///
    /// **2,5 × 10⁹ octets, pas 2,5 Gio** : c'est la lecture qui rend les
    /// chiffres de l'audit (2,151 Go / 408 951 pages = 5,14 Kio/page, budget
    /// franchi vers 480 000 pages), et c'est aussi la façon dont le Finder
    /// compte les octets depuis macOS 10.6.
    public static let specBudgetBytes = 2_500_000_000

    /// Seuil de l'avertissement, en fraction du budget.
    public static let nearRatio = 0.80
    /// Seuil du dépassement.
    public static let overRatio = 1.00

    /// Taille de la base aujourd'hui, journal compris.
    public let bytes: Int
    public let budgetBytes: Int
    public let ratioOfBudgetNow: Double
    /// Nombre de pages auquel le budget serait atteint, au coût par page
    /// mesuré sur CETTE base. `nil` quand l'index est vide : il n'y a alors
    /// aucun coût par page à extrapoler, et 0 se lirait comme « c'est déjà
    /// dépassé ».
    public let pagesAtBudget: Int?
    /// Coût par page, en octets. `nil` sur un index vide.
    public let bytesPerPage: Double?
    public let level: Level

    /// - Parameters:
    ///   - bytes: taille de la base (`stats["db_bytes"]`).
    ///   - pagesIndexed: `stats["pages_indexed"]`.
    ///   - budgetBytes: la taille prévue. Un budget nul ou négatif rend une
    ///     projection sans niveau (`.ok`, ratio nul) plutôt qu'une division
    ///     par zéro.
    public init(bytes: Int,
                pagesIndexed: Int,
                budgetBytes: Int = DiskForecast.specBudgetBytes) {
        self.bytes = max(0, bytes)
        self.budgetBytes = budgetBytes

        guard budgetBytes > 0 else {
            self.ratioOfBudgetNow = 0
            self.pagesAtBudget = nil
            self.bytesPerPage = nil
            self.level = .ok
            return
        }

        let budget = Double(budgetBytes)
        let ratio = Double(self.bytes) / budget
        self.ratioOfBudgetNow = ratio

        if pagesIndexed > 0 {
            let costPerPage = Double(self.bytes) / Double(pagesIndexed)
            self.bytesPerPage = costPerPage
            self.pagesAtBudget = costPerPage > 0
                ? Int((budget / costPerPage).rounded()) : nil
        } else {
            self.bytesPerPage = nil
            self.pagesAtBudget = nil
        }

        if ratio >= DiskForecast.overRatio { self.level = .over }
        else if ratio >= DiskForecast.nearRatio { self.level = .near }
        else { self.level = .ok }
    }

    /// Vrai dès qu'il y a quelque chose à dire à l'utilisateur.
    public var warns: Bool { level != .ok }
}
