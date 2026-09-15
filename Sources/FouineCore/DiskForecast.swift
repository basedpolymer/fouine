// DiskForecast.swift — « l'index approche-t-il de la taille prévue ? » (MO-03).
// Propriété : A-Core. PUR : aucune entrée-sortie, donc testable ligne à ligne.
//
// Pourquoi. Le budget P5 de la SPEC (2,5 Go, amendement du 05/09/2026) n'était
// câblé nulle part : `fouine status` projetait « 4,9 GiB at 1 M » par une règle
// de trois LINÉAIRE depuis l'état COURANT — donc depuis une base dont la
// campagne sémantique n'est qu'aux deux tiers, ce qui la rend optimiste à
// court terme et hors sujet à long terme (personne n'a un million de pages).
// Mesuré le 09/09/2026 sur la base de production : 2,151 Go pour 408 951 pages
// (5,14 Kio/page) à 274 244 pages complètement vectorisées ; à couverture
// pleine du corpus ACTUEL, ~2,26 Go, soit 90 % du budget, et le budget serait
// franchi vers 452 000 pages. C'est CETTE échéance-là qui intéresse, et elle ne
// se lit qu'en ajoutant les vecteurs qui manquent encore.
//
// Ce que la projection ne fait pas : rien ne s'arrête au budget (décision du
// propriétaire du 09/09/2026, n° 3). Fouine avertit — carte « Index », `status`,
// `doctor` — et continue d'indexer, d'OCRiser et de vectoriser.

import Foundation

/// Où en est le poids de l'index par rapport à la taille prévue, aujourd'hui
/// et à couverture sémantique pleine.
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
    /// chiffres de l'audit (2,151 Go / 408 951 pages = 5,14 Kio/page, 90 % du
    /// budget à couverture pleine, budget franchi vers 452 000 pages), et c'est
    /// aussi la façon dont le Finder compte les octets depuis macOS 10.6.
    public static let specBudgetBytes = 2_500_000_000

    /// Seuil de l'avertissement, en fraction du budget.
    public static let nearRatio = 0.80
    /// Seuil du dépassement.
    public static let overRatio = 1.00

    /// Fenêtres RÉELLES par page sur le corpus de production (mesuré le
    /// 03/09/2026, schéma v5). Repli quand l'appelant ne mesure pas la
    /// géométrie de SA base (`GRDBStore.embedForecast().windowsPerPage`).
    public static let productionWindowsPerPage = 2.13

    /// Coût sur le disque d'UNE fenêtre : 384 octets de vecteur int8 unitaire
    /// (§4.1) plus ~26 octets de ligne SQLite. Mesuré par `dbstat` le
    /// 10/09/2026 sur deux bases : corpus de recette C2 (page_vec 3 186 688
    /// octets pour 8 369 lignes dont 7 741 non vides → 384,0 octets de blob et
    /// 25,6 octets de ligne) et copie de la base de production. Les lignes
    /// SENTINELLES vides (§4.1, complétude) coûtent les 26 octets de ligne
    /// seuls, soit ~9 octets par page : négligées, et c'est dit.
    public static let bytesPerVectorRow = 410

    /// Taille de la base aujourd'hui, journal compris.
    public let bytes: Int
    public let budgetBytes: Int
    /// Ce que pèsera la base quand toutes les pages indexées auront leurs
    /// vecteurs, à corpus INCHANGÉ.
    public let bytesAtFullVectors: Int
    public let ratioOfBudgetNow: Double
    public let ratioAtFullVectors: Double
    /// Nombre de pages auquel le budget serait atteint, au coût par page
    /// « vecteurs complets ». `nil` quand l'index est vide : il n'y a alors
    /// aucun coût par page à extrapoler, et 0 se lirait comme « c'est déjà
    /// dépassé ».
    public let pagesAtBudget: Int?
    /// Coût par page à couverture pleine, en octets. `nil` sur un index vide.
    public let bytesPerPageAtFullVectors: Double?
    public let level: Level

    /// Pages indexées qui n'ont pas encore tous leurs vecteurs.
    public let pagesWithoutVectors: Int

    /// - Parameters:
    ///   - bytes: taille de la base (`stats["db_bytes"]`).
    ///   - pagesIndexed: `stats["pages_indexed"]`.
    ///   - pagesFullyVectorised: `stats["pages_vec_complete"]` — les pages dont
    ///     toutes les fenêtres sont produites. Les pages PARTIELLES comptent
    ///     comme non faites : leurs fenêtres manquantes sont à écrire, et
    ///     l'erreur va dans le sens prudent.
    ///   - windowsPerPage: géométrie de cette base, ou la constante de
    ///     production.
    ///   - bytesPerVector: coût d'une fenêtre sur le disque.
    ///   - budgetBytes: la taille prévue. Un budget nul ou négatif rend une
    ///     projection sans niveau (`.ok`, ratios nuls) plutôt qu'une division
    ///     par zéro.
    public init(bytes: Int,
                pagesIndexed: Int,
                pagesFullyVectorised: Int,
                windowsPerPage: Double = DiskForecast.productionWindowsPerPage,
                bytesPerVector: Int = DiskForecast.bytesPerVectorRow,
                budgetBytes: Int = DiskForecast.specBudgetBytes) {
        let missing = max(0, pagesIndexed - max(0, pagesFullyVectorised))
        let perPage = max(0, windowsPerPage)
        let toWrite = Double(missing) * perPage * Double(max(0, bytesPerVector))

        self.bytes = max(0, bytes)
        self.budgetBytes = budgetBytes
        self.pagesWithoutVectors = missing
        self.bytesAtFullVectors = self.bytes + Int(toWrite.rounded())

        guard budgetBytes > 0 else {
            self.ratioOfBudgetNow = 0
            self.ratioAtFullVectors = 0
            self.pagesAtBudget = nil
            self.bytesPerPageAtFullVectors = nil
            self.level = .ok
            return
        }

        let budget = Double(budgetBytes)
        self.ratioOfBudgetNow = Double(self.bytes) / budget
        let atFull = Double(self.bytesAtFullVectors) / budget
        self.ratioAtFullVectors = atFull

        if pagesIndexed > 0 {
            let costPerPage = Double(self.bytesAtFullVectors) / Double(pagesIndexed)
            self.bytesPerPageAtFullVectors = costPerPage
            self.pagesAtBudget = costPerPage > 0
                ? Int((budget / costPerPage).rounded()) : nil
        } else {
            self.bytesPerPageAtFullVectors = nil
            self.pagesAtBudget = nil
        }

        // Le NIVEAU se lit sur la projection, pas sur l'état courant : une
        // campagne sémantique aux deux tiers cache 100 Mo de vecteurs à
        // écrire, et avertir seulement quand ils sont écrits, c'est avertir
        // trop tard. `ratioAtFullVectors ≥ ratioOfBudgetNow` par construction.
        if atFull >= DiskForecast.overRatio { self.level = .over }
        else if atFull >= DiskForecast.nearRatio { self.level = .near }
        else { self.level = .ok }
    }

    /// Vrai dès qu'il y a quelque chose à dire à l'utilisateur.
    public var warns: Bool { level != .ok }
}
