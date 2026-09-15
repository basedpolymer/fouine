// P8RealVocabularyTests.swift — mesure du budget P8 (§8.2 : expansion floue
// ≤ 10 ms par terme, SQL + Levenshtein) sur une RÉPLIQUE du vocabulaire réel.
// Propriété : A-Core (vague corrective, bogue 3).
//
// Sauté par défaut : le test exige une base désignée par FOUINE_P8_DB portant
// les tables `vocab_tri` et `vocab_seen` peuplées (p. ex. une copie des
// 1 486 739 termes de la base de production — la base de production elle-même
// n'est JAMAIS ouverte ici : GRDBStore.open écrit un journal WAL).
// Construction type :
//   sqlite3 replica.db "CREATE VIRTUAL TABLE vocab_tri USING fts5(term,
//     tokenize='trigram'); CREATE TABLE vocab_seen(term TEXT PRIMARY KEY)
//     WITHOUT ROWID; ATTACH 'file:...fouine.db?mode=ro' AS prod;
//     INSERT INTO vocab_tri(term) SELECT term FROM prod.vocab_seen;
//     INSERT INTO vocab_seen SELECT term FROM prod.vocab_seen;"
// puis : FOUINE_P8_DB=replica.db swift test -c release --filter P8RealVocabulary

import XCTest
@testable import FouineCore

final class P8RealVocabularyTests: XCTestCase {

    /// La série de la mission corrective : les 5 termes imposés + 3 choisis
    /// (dont `equilibre`, cas du §5.5.2, et deux termes longs fréquents).
    private static let series = [
        "enthalpie", "polymere", "catalyseur", "chromatographie", "conversion",
        "spectroscopie", "thermodynamique", "equilibre",
    ]

    func testExpansionBudgetOnRealVocabulary() throws {
        guard let path = ProcessInfo.processInfo.environment["FOUINE_P8_DB"],
              !path.isEmpty else {
            throw XCTSkip("FOUINE_P8_DB non défini : mesure sur vocabulaire réel sautée")
        }
        let store = GRDBStore()
        try store.open(at: URL(fileURLWithPath: path))
        let expander = TrigramExpander(store: store)

        var breaches: [String] = []
        for term in Self.series {
            var samples: [Double] = []
            var neighbours = 0
            for run in 0..<6 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let out = try expander.expand(term, cap: GRDBStore.fuzzyVariantCap)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                if run == 0 { continue }          // 1re exécution (cache froid) écartée
                samples.append(ms)
                neighbours = out.count - 1
            }
            samples.sort()
            let median = samples[samples.count / 2]
            print(String(format: "P8réel — %-16@ méd %6.2f ms · max %6.2f ms · %d voisin(s)",
                         term as NSString, median, samples.last ?? 0, neighbours))
            if median > 10 {
                breaches.append(String(format: "%@ %.1f ms", term, median))
            }
        }
        XCTAssertTrue(breaches.isEmpty,
                      "P8 : expansion > 10 ms par terme — \(breaches)")
    }
}
