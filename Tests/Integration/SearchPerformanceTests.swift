// SearchPerformanceTests.swift — P4 et P8 rejouables (SPEC §8.2). Propriété : A-Recette.
//
// Les chiffres de référence de la recette sont pris hors XCTest, sur le binaire
// release et machine calme (voir la recette du 31/08/2026, rapport interne). Ces tests sont le FILET : ils
// rejouent la mesure et échouent si un seuil du §8.2 est franchi. La première
// exécution de chaque forme est écartée (cache froid), comme au §8.2.
//
// `elapsed_ms` du JSON (§4.3) est le temps MOTEUR — la même grandeur que le
// « p95 max 6,4 ms » du §2.6, sans le coût de démarrage du processus.
//
// Les seuils du §8.2 ne veulent rien dire sur trois fiches : ces mesures
// exigent le corpus complet, donc l'opt-in `FOUINE_TEST_DB` (audit S3).
// Sans lui, tout se saute.

import Foundation
import XCTest
import FouineCore

final class SearchPerformanceTests: XCTestCase {

    private var database: URL!

    /// Onze formes de requêtes : terme seul, phrase, proximité, préfixe ≥ 4,
    /// booléens, exclusion, filtres, facette (§8.2 P4).
    private static let forms: [(name: String, query: String, extra: [String])] = [
        ("terme seul",      "chromatographie",                    []),
        ("terme fréquent",  "chimie",                             []),
        ("phrase",          "\"règle de Markovnikov\"",           []),
        ("phrase courante", "\"énergie libre\"",                  []),
        ("proximité",       "pres:10 energie libre gibbs",        []),
        ("préfixe",         "spectro*",                           []),
        ("ET implicite",    "azote reduction",                    []),
        ("exclusion",       "enthalpie -biologie",                []),
        // `<racine>` est remplacé à l'exécution par une étiquette de racine
        // lue dans `Tests/Fixtures/paths.json` : aucun nom de dossier personnel
        // n'est écrit en dur dans le dépôt.
        ("filtre racine",   "dossier:<racine> enthalpie",         []),
        ("filtre ext",      "ext:pdf catalyseur",                 []),
        ("facette folder",  "chromatographie",   ["--facet", "folder"]),
    ]

    override func setUpWithError() throws {
        _ = try Recette.requireBinary()
        database = try Recette.requireFullIndex()
    }

    // MARK: - P4 · p95 < 50 ms

    /// BOGUE 2 (recette du 31/08/2026, rapport interne) : `GRDBStore.pageMeta(for:)` filtre sur
    /// `(doc_id * 100000 + page) IN (…)`, expression que SQLite ne peut pas
    /// résoudre par la clé primaire de `page_src` — `EXPLAIN QUERY PLAN` rend
    /// `SCAN page_src`. Mesuré : 43 à 50 ms de balayage par appel sur
    /// 363 058 pages, et il y a DEUX appels par `fouine search`. Le moteur
    /// FTS5 seul, forme imposée du §4.1, tient 0 à 30 ms hors préfixe.
    func testP4SearchLatency() throws {
        var all: [Double] = []
        var report: [String] = []
        let rootLabel = (try? Recette.requireFixtures())?
            .roots.keys.sorted().first ?? "Livres"
        for form in Self.forms {
            let query = form.query.replacingOccurrences(of: "<racine>",
                                                        with: rootLabel)
            var samples: [Double] = []
            for run in 0..<8 {
                let payload = try Recette.search(query, database: database,
                                                 extra: form.extra + ["--fuzzy", "off"],
                                                 limit: 50)
                if run == 0 { continue }          // exécution à froid écartée
                samples.append(payload.elapsedMS)
            }
            // Arbitrage n°2 (recette du 31/08/2026, rapport interne) : le coût FTS5 brut d'un préfixe sur
            // l'index complet est incompressible sans index préfixe (refusé
            // par D3) — la forme « préfixe » est mesurée et rapportée mais
            // n'entre pas dans le p95 seuillé.
            if form.name != "préfixe" { all += samples }
            report.append(String(format: "  %-16@ méd %.2f ms · p95 %.2f ms",
                                 form.name as NSString,
                                 Stats.median(samples), Stats.percentile(samples, 95)))
        }
        let p95 = Stats.percentile(all, 95)
        print("P4 — p95 hors préfixe \(String(format: "%.2f", p95)) ms sur \(all.count) mesures")
        report.forEach { print($0) }
        XCTAssertLessThan(p95, 50, "P4 : p95 de recherche au-dessus de 50 ms")
    }

    // MARK: - P8 · expansion floue ≤ 10 ms par terme

    /// P8 porte sur **l'expansion**, pas sur la requête étendue (§8.2 : « expansion
    /// floue ≤ 10 ms par terme, vocabulaire 1 M »). On appelle donc `TrigramExpander`
    /// directement. La version vague 2 de ce test approximait P8 par
    /// `elapsed_ms(flou) − elapsed_ms(exact)` faute de mieux ; cette approximation
    /// mesure en réalité le coût d'EXÉCUTION du OR étendu, qui relève de P4 et que
    /// `testP8ForcedFuzzyEndToEndCost` relève à part.
    func testP8FuzzyExpansionAlone() throws {
        let store = GRDBStore()
        try store.open(at: database)
        let expander = TrigramExpander(store: store)
        let terms = ["enthalpie", "polymere", "catalyseur", "chromatographie",
                     "conversion", "thermodynamique", "spectroscopie"]

        var worst = 0.0, worstTerm = ""
        for term in terms {
            _ = try expander.expand(term, cap: GRDBStore.fuzzyVariantCap)  // à froid
            var samples: [Double] = []
            for _ in 0..<10 {
                let started = DispatchTime.now().uptimeNanoseconds
                _ = try expander.expand(term, cap: GRDBStore.fuzzyVariantCap)
                samples.append(
                    Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            let median = Stats.median(samples)
            let variants = try expander.expand(term, cap: GRDBStore.fuzzyVariantCap)
            print(String(format: "P8 — %-16@ méd %.2f ms · p95 %.2f ms · %d variante(s)",
                         term as NSString, median, Stats.percentile(samples, 95),
                         variants.count - 1))
            if median > worst { worst = median; worstTerm = term }
        }
        // Le seuil du §8.2 est chiffré en Swift `-O`. En build DEBUG, la boucle
        // de Levenshtein n'est pas optimisée et le relevé enfle d'un facteur 2 à
        // 6 (mesuré : `polymere` 2,97 ms en release contre 17,53 ms en debug,
        // pour un SQL de sonde identique à 2 ms). Le seuil contractuel n'est donc
        // appliqué qu'en release ; en debug on garde une borne large, dont le seul
        // rôle est d'attraper une régression d'un ordre de grandeur.
        // `swift test -c release --filter IntegrationTests` applique le vrai P8.
        #if DEBUG
        let budget = 40.0
        #else
        let budget = 10.0
        #endif
        XCTAssertLessThan(worst, budget,
                          "P8 : expansion de « \(worstTerm) » au-dessus de "
                          + "\(Int(budget)) ms")
    }

    // MARK: - Coût de bout en bout du flou FORCÉ (informatif, hors critère)

    /// `--fuzzy on` FORCÉ sur un terme FRÉQUENT fait payer l'exécution d'un OR
    /// de 12 variantes sur 363 000 pages — 60 à 480 ms mesurés. Aucun critère du
    /// §8 ne le couvre, et le mode par défaut (`auto`, expansion seulement sous
    /// 20 pages exactes) ne l'atteint jamais : mesuré, les requêtes à faible
    /// rendement coûtent 1,7 à 12,7 ms en mode par défaut. Le relevé est donc
    /// informatif, et le seuil de garde est large — il n'existe que pour attraper
    /// une régression d'un ordre de grandeur.
    func testP8ForcedFuzzyEndToEndCost() throws {
        for term in ["enthalpie", "polymere", "catalyseur", "chromatographie"] {
            var exact: [Double] = [], fuzzy: [Double] = []
            for run in 0..<8 {
                let e = try Recette.search(term, database: database,
                                           extra: ["--fuzzy", "off"], limit: 50)
                let f = try Recette.search(term, database: database,
                                           extra: ["--fuzzy", "on"], limit: 50)
                if run == 0 { continue }
                exact.append(e.elapsedMS)
                fuzzy.append(f.elapsedMS)
            }
            print(String(format: "flou forcé — %-16@ exact %.2f ms · flou %.2f ms "
                         + "· surcoût %.2f ms", term as NSString,
                         Stats.median(exact), Stats.median(fuzzy),
                         Stats.median(fuzzy) - Stats.median(exact)))
            XCTAssertLessThan(Stats.median(fuzzy), 3_000,
                              "flou forcé sur « \(term) » : régression d'un ordre "
                              + "de grandeur")
        }
    }

    /// Le mode PAR DÉFAUT (`auto`) doit tenir le seuil P4 y compris sur les
    /// requêtes à faible rendement, celles qui déclenchent réellement l'expansion.
    func testP4DefaultModeOnLowYieldQueries() throws {
        let queries = ["\"règle de Markovnikov\"", "pres:10 energie libre gibbs",
                       "tellurium markovnikov", "\"énergie de Gibbs\""]
        var all: [Double] = []
        for query in queries {
            var samples: [Double] = []
            for run in 0..<8 {
                let payload = try Recette.search(query, database: database, limit: 50)
                if run == 0 { continue }
                samples.append(payload.elapsedMS)
            }
            all += samples
            print(String(format: "P4 (auto) — %-30@ méd %.2f ms",
                         query as NSString, Stats.median(samples)))
        }
        XCTAssertLessThan(Stats.percentile(all, 95), 50,
                          "P4 : le mode par défaut dépasse 50 ms")
    }
}
