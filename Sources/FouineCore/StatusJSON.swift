// StatusJSON.swift — les objets JSON d'ÉTAT que plusieurs surfaces publient.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
// Propriété : A-Core. Lot MC4 (constat PM-32).
//
// POURQUOI CE FICHIER EXISTE. `disk_budget` et `meaning_background` étaient
// calculés dans `Sources/fouine/CommandsStatus.swift`, c'est-à-dire dans
// l'exécutable de la ligne de commande — inaccessible au serveur MCP, qui ne
// lie pas la CLI. Résultat mesuré le 13/09/2026 : `fouine status --json` disait
// `disk_budget.level = "over"` et `meaning_background.pages_left = 139 638`
// pendant que `fouine_status` ne publiait ni l'un ni l'autre, et qu'un
// assistant conseillait `fouine embed` sans savoir que le budget disque était
// dépassé.
//
// RIEN N'EST RECALCULÉ ICI. Les deux objets viennent des mêmes `stats()` et du
// même `SettingsSnapshot` qu'avant ; ce fichier ne fait que les mettre là où
// les TROIS surfaces peuvent les lire. Le contrat de `status --json` et de
// `doctor --json` est inchangé au caractère près — un test d'intégration le
// compare.

import Foundation

public enum StatusJSON {

    // MARK: - Préparation du sens en arrière-plan (constat PR-21, lot AG1)

    /// Pages indexées qui n'ont pas encore toutes leurs fenêtres. AUCUNE
    /// lecture nouvelle : les deux nombres viennent de `stats()`.
    public static func meaningPagesLeft(_ stats: [String: Int]) -> Int {
        max(0, (stats["pages_indexed"] ?? 0) - (stats["pages_vec_complete"] ?? 0))
    }

    /// L'objet `meaning_background`, le MÊME dans `status --json`,
    /// `doctor --json` et `fouine_status`.
    public static func meaningJSON(settings: SettingsSnapshot,
                                   stats: [String: Int]) -> [String: Any] {
        let at = settings.agentLastEmbedBatchAt
        return [
            "enabled": settings.agentPrepareMeaning,
            "budget_minutes": settings.agentEmbedBudgetMinutes,
            // `null` tant qu'aucun lot n'a tourné : `0` se lirait comme 1970.
            "last_batch": at > 0
                ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at)) as Any
                : NSNull(),
            "pages_left": meaningPagesLeft(stats),
        ]
    }

    // MARK: - Budget disque (constat MO-03)

    /// L'objet `disk_budget`, le MÊME dans `status --json`, `doctor --json` et
    /// `fouine_status`.
    public static func diskBudgetJSON(_ f: DiskForecast) -> [String: Any] {
        [
            "bytes": f.bytes,
            "budget_bytes": f.budgetBytes,
            "bytes_at_full_vectors": f.bytesAtFullVectors,
            "ratio_now": JSONNumber.rounded(f.ratioOfBudgetNow, places: 3),
            "ratio_at_full_vectors": JSONNumber.rounded(f.ratioAtFullVectors, places: 3),
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
    /// AUCUNE LECTURE NOUVELLE : les trois nombres viennent de `stats()`, que
    /// les trois surfaces appellent déjà. La géométrie des fenêtres reste la
    /// CONSTANTE du corpus de production (2,13) : la mesurer sur cette base
    /// (`embedForecast`) coûte 1,5 s sur la base de production du 09/09/2026.
    public static func diskForecast(stats: [String: Int]) -> DiskForecast {
        DiskForecast(bytes: stats["db_bytes"] ?? 0,
                     pagesIndexed: stats["pages_indexed"] ?? 0,
                     pagesFullyVectorised: stats["pages_vec_complete"] ?? 0)
    }
}
