// StatusJSON.swift — les objets JSON d'ÉTAT que plusieurs surfaces publient.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Core. Lot MC4 (constat PM-32).
//
// POURQUOI CE FICHIER EXISTE. `disk_budget` était calculé dans
// `Sources/fouine/CommandsStatus.swift`, c'est-à-dire dans l'exécutable de la
// ligne de commande — inaccessible au serveur MCP, qui ne lie pas la CLI.
// Résultat mesuré le 13/09/2026 : `fouine status --json` disait
// `disk_budget.level = "over"` pendant que `fouine_status` ne publiait rien, et
// qu'un assistant conseillait d'en indexer davantage sans savoir que le budget
// disque était dépassé.
//
// RIEN N'EST RECALCULÉ ICI. L'objet vient des mêmes `stats()` qu'avant ; ce
// fichier ne fait que le mettre là où les TROIS surfaces peuvent le lire. Le
// contrat de `status --json` et de `doctor --json` ne change que de ce que le
// lot SR1 en a retiré — un test d'intégration le compare.

import Foundation

public enum StatusJSON {

    // MARK: - Budget disque (constat MO-03)

    /// L'objet `disk_budget`, le MÊME dans `status --json`, `doctor --json` et
    /// `fouine_status`.
    public static func diskBudgetJSON(_ f: DiskForecast) -> [String: Any] {
        [
            "bytes": f.bytes,
            "budget_bytes": f.budgetBytes,
            "ratio_now": JSONNumber.rounded(f.ratioOfBudgetNow, places: 3),
            // `null` sur un index vide : il n'y a pas de coût par page à
            // extrapoler, et 0 se lirait comme « déjà dépassé ».
            "pages_at_budget": f.pagesAtBudget.map { $0 as Any } ?? NSNull(),
            "level": f.level.rawValue,
        ]
    }

    /// La projection du budget pour CETTE base. `status`, `doctor` et le
    /// serveur MCP la lisent ici tous les trois : trois calculs du même chiffre
    /// finiraient par ne plus dire la même chose.
    ///
    /// AUCUNE LECTURE NOUVELLE : les deux nombres viennent de `stats()`, que
    /// les trois surfaces appellent déjà.
    public static func diskForecast(stats: [String: Int]) -> DiskForecast {
        DiskForecast(bytes: stats["db_bytes"] ?? 0,
                     pagesIndexed: stats["pages_indexed"] ?? 0)
    }
}
