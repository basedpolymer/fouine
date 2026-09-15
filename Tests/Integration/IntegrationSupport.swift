// IntegrationSupport.swift — plomberie de la recette rejouable (SPEC §8, §9.3).
// Propriété : A-Recette.
//
// Ces tests pilotent le BINAIRE `fouine` par `Process` : ils exercent la CLI
// telle que la recette du §8 la décrit, codes de sortie compris. Rien n'est
// écrit sous une racine indexée — le corpus est en lecture seule stricte.
//
// ═══ OÙ CES TESTS ÉCRIVENT (audit S3, 01/09/2026) ═══════════════════════════
//
// Jusqu'à cet audit, la recette d'intégration désignait la base de PRODUCTION,
// `~/Library/Application Support/Fouine/fouine.db` : sur une machine sans base
// tout se sautait proprement, mais sur le poste du mainteneur chaque `make
// test` réindexait le corpus (T10) et consommait une minute de file OCR (T11)
// — pendant que l'agent d'arrière-plan écrivait dans la même base.
//
// Règle désormais : PAR DÉFAUT, AUCUN TEST NE LIT NI N'ÉCRIT LA BASE DE
// PRODUCTION NI LES RACINES RÉELLES DE L'UTILISATEUR. Deux régimes :
//
//   1. BASE JETABLE (le défaut, modèle de `MovedRootTests`). `makeIndexedScratch`
//      fabrique une racine temporaire peuplée de petits fichiers, l'enregistre
//      dans une base temporaire et l'indexe. `IndexHygieneTests` (T8, T10) et
//      `StatusContractTests` tournent là-dessus : ils testent le PRODUIT, pas
//      le corpus, et n'ont donc besoin de rien de personnel.
//
//   2. CORPUS COMPLET, SUR OPT-IN EXPLICITE. Ce qui n'a de sens que sur le
//      vrai corpus — performance (P4), recette OCR (T6, T7, T11, T13), bancs
//      OCR (P2, P3), contrôles de recherche (T1-T5, T12, T14, T15) — exige la
//      variable d'environnement `FOUINE_TEST_DB`, qui doit désigner une COPIE
//      de la base faite par le mainteneur. Sans elle, ces tests se SAUTENT.
//      Elle ne tombe jamais en repli sur la base par défaut, et pointer la base
//      de production est REFUSÉ (échec explicite, pas un saut).
//
//      Préparation d'une copie, agent arrêté ou non (SQLite sait copier une
//      base WAL par sa propre API de sauvegarde) :
//
//        sqlite3 "file:$HOME/Library/Application Support/Fouine/fouine.db?mode=ro" \
//                ".backup /tmp/fouine-recette.db"
//        FOUINE_TEST_DB=/tmp/fouine-recette.db make test
//
//      La copie porte ses propres racines : il n'y a pas de seconde variable à
//      poser pour les désigner. Les tests qui ont AUSSI besoin des chemins de
//      fixtures du §8.1 lisent, comme avant, `Tests/Fixtures/paths.json`.
//
// Tout ce qui touche au corpus personnel dépend de `Tests/Fixtures/paths.json`,
// GITIGNORÉ : si le fichier est absent OU MALFORMÉ (autre machine, CI), les
// tests concernés se sautent proprement par `XCTSkip`, jamais par un échec.
// Le modèle versionné est `Tests/Fixtures/paths.example.json` : le copier à
// côté sous le nom `paths.json` et y mettre les chemins de la machine.

import Foundation
import XCTest

/// Refus dur, à distinguer d'un `XCTSkip` : une configuration DANGEREUSE ne
/// doit pas passer pour une précondition manquante.
struct RecetteRefus: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Fixtures (Tests/Fixtures/paths.json)

struct FixtureCase: Decodable {
    let path: String
    let query: String
    let expectedPages: [Int]?
    let expectedSource: String?
    let secondaryTerms: [String]?

    enum CodingKeys: String, CodingKey {
        case path, query
        case expectedPages = "expected_pages"
        case expectedSource = "expected_source"
        case secondaryTerms = "secondary_terms"
    }
}

struct FixtureFile: Decodable {
    let roots: [String: String]
    let fixtures: [String: FixtureCase]
}

// MARK: - Schéma JSON de `fouine search` (§4.3, gelé)

struct SearchHit: Decodable {
    let docID: Int64
    let path: String
    let folder: String
    let page: Int
    let score: Double
    let source: String
    let engine: String
    let fuzzyDistance: Int
    let snippet: String
    /// Le lien `fouine://` qui rouvre Fouine sur cette page (lot INT-L1).
    let link: String

    enum CodingKeys: String, CodingKey {
        case docID = "doc_id"
        case path, folder, page, score, source, engine, snippet, link
        case fuzzyDistance = "fuzzy_distance"
    }
}

struct SearchPayload: Decodable {
    let query: String
    let offset: Int?
    let hasMore: Bool?
    let elapsedMS: Double
    let totalPages: Int
    let totalDocs: Int
    let hits: [SearchHit]
    let facets: [String: [String: Int]]?
    /// Documents trouvés par leur NOM DE FICHIER (lot MP1, PR-02). Absent du
    /// JSON quand aucun ne répond : c'est un canal, pas un compte.
    let nameMatches: [NameMatch]?
    /// La recherche exacte n'a rien rendu et la requête a été rejouée en
    /// tolérant les fautes (lot MP1, C2-08). Absent quand cela n'a pas eu lieu.
    let fuzzyFallback: Bool?

    enum CodingKeys: String, CodingKey {
        case query, hits, facets, offset
        case hasMore = "has_more"
        case elapsedMS = "elapsed_ms"
        case totalPages = "total_pages"
        case totalDocs = "total_docs"
        case nameMatches = "name_matches"
        case fuzzyFallback = "fuzzy_fallback"
    }
}

struct NameMatch: Decodable {
    let docID: Int64
    let path: String
    let folder: String
    let link: String

    enum CodingKeys: String, CodingKey {
        case path, folder, link
        case docID = "doc_id"
    }
}

// MARK: - Exécution

struct CommandResult {
    let arguments: [String]
    let status: Int32
    let stdout: String
    let stderr: String

    var describe: String {
        "fouine \(arguments.joined(separator: " ")) -> \(status)\n"
        + "stdout: \(stdout)\nstderr: \(stderr)"
    }
}

enum Recette {

    // MARK: Emplacements

    /// Racine du paquet, déduite de ce fichier source : Tests/Integration/X.swift.
    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()       // Tests/Integration
        .deletingLastPathComponent()       // Tests
        .deletingLastPathComponent()       // racine

    /// `FOUINE_BIN`, sinon la release, sinon la debug. `nil` si rien n'est bâti.
    static var binary: URL? {
        if let override = ProcessInfo.processInfo.environment["FOUINE_BIN"],
           !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for flavour in ["release", "debug"] {
            let candidate = packageRoot
                .appendingPathComponent(".build/\(flavour)/fouine")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static let fixturesURL = packageRoot
        .appendingPathComponent("Tests/Fixtures/paths.json")

    /// Variable d'OPT-IN de la recette sur corpus complet (audit S3). Elle
    /// désigne une COPIE de la base, faite par le mainteneur — voir l'en-tête.
    static let optInVariable = "FOUINE_TEST_DB"

    /// La copie désignée par l'opt-in, ou `nil` si la variable n'est pas posée.
    /// Aucun repli : pas de variable, pas de corpus complet.
    static var optInDatabase: URL? {
        guard let raw = ProcessInfo.processInfo.environment[optInVariable],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
    }

    /// Base de PRODUCTION (§10). SEULE raison d'être de cette constante :
    /// la REFUSER si l'opt-in la désigne. Aucun test ne l'ouvre.
    static let refusedDatabase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Fouine/fouine.db")
        .resolvingSymlinksInPath()

    // MARK: Préconditions (skip propre, jamais d'échec)

    static func requireBinary() throws -> URL {
        guard let binary else {
            throw XCTSkip("binaire `fouine` absent — lancer `swift build -c release`")
        }
        return binary
    }

    static func requireFixtures() throws -> FixtureFile {
        guard let data = try? Data(contentsOf: fixturesURL) else {
            throw XCTSkip("Tests/Fixtures/paths.json absent (gitignoré) — "
                          + "recette du corpus personnel sautée. Modèle : "
                          + "Tests/Fixtures/paths.example.json")
        }
        // Un fichier PRÉSENT mais malformé se saute lui aussi : c'est une
        // fixture de machine manquante, pas une régression du produit. Sans ce
        // rattrapage, la DecodingError remontait en ÉCHEC de test (audit,
        // point 7).
        do {
            return try JSONDecoder().decode(FixtureFile.self, from: data)
        } catch {
            throw XCTSkip("Tests/Fixtures/paths.json malformé : \(error) — "
                          + "comparer à Tests/Fixtures/paths.example.json")
        }
    }

    static func requireFixture(_ name: String) throws -> FixtureCase {
        let file = try requireFixtures()
        guard let fixture = file.fixtures[name] else {
            throw XCTSkip("fixture \(name) absente de paths.json")
        }
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("fixture \(name) introuvable sur le disque : \(fixture.path)")
        }
        return fixture
    }

    /// Corpus complet, SUR OPT-IN (audit S3) : la copie désignée par
    /// `FOUINE_TEST_DB`, existante ET peuplée. On ne l'OUVRE pas pour le
    /// vérifier — `fouine` créerait la base au passage, ce qui fabriquerait un
    /// faux succès ; `sqlite` l'ouvre en `mode=ro`.
    ///
    /// Sans opt-in, saut propre. Avec un opt-in qui désigne la BASE DE
    /// PRODUCTION, refus dur : T10 y réindexerait le corpus et T11 y
    /// consommerait la file, pendant que l'agent écrit dedans.
    static func requireFullIndex() throws -> URL {
        guard let database = optInDatabase else {
            throw XCTSkip("""
                recette du corpus complet sautée : \(optInVariable) n'est pas \
                posée. Elle doit désigner une COPIE de la base — jamais celle \
                de production, où l'agent écrit :
                  sqlite3 "file:$HOME/Library/Application Support/Fouine/\
                fouine.db?mode=ro" ".backup /tmp/fouine-recette.db"
                  \(optInVariable)=/tmp/fouine-recette.db make test
                """)
        }
        guard database.path != refusedDatabase.path else {
            throw RecetteRefus(description:
                "\(optInVariable) désigne la BASE DE PRODUCTION (\(database.path)). "
                + "La recette y réindexerait le corpus et y consommerait la file "
                + "OCR, pendant que l'agent écrit dedans. Faites-en une copie "
                + "(`sqlite3 … \".backup …\"`) et pointez la copie.")
        }
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw XCTSkip("\(optInVariable) désigne \(database.path), qui n'existe "
                          + "pas — copier une base indexée à cet emplacement")
        }
        let pages = (try? sqlite("SELECT count(*) FROM page_src",
                                 on: database)) ?? ""
        guard let count = Int(pages.trimmingCharacters(in: .whitespacesAndNewlines)),
              count > 0 else {
            throw XCTSkip("la copie \(database.path) est vide — copier une base "
                          + "réellement indexée")
        }
        return database
    }

    // MARK: Lancement

    /// Lance la CLI sur la base DÉSIGNÉE. `database` n'est pas optionnel et
    /// `FOUINE_DB` est toujours posée : aucun chemin de la recette ne peut
    /// retomber sur la base par défaut (audit S3).
    @discardableResult
    /// `extraEnvironment` : variables posées EN PLUS de `FOUINE_DB`, pour les
    /// recettes qui exercent un chemin gouverné par l'environnement
    /// (`FOUINE_MODEL_URL`, `FOUINE_MODEL_DIR`…). Aucun appelant historique ne
    /// la pose : le comportement par défaut est inchangé.
    static func run(_ arguments: [String], database: URL,
                    timeout: TimeInterval = 900,
                    extraEnvironment: [String: String] = [:]) throws
        -> CommandResult {
        let binary = try requireBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["FOUINE_DB"] = database.path
        // Les trois familles « sur demande » sont allumées par défaut depuis
        // la 1.0.1 (DF1) ; le corpus versionné, lui, est compté SANS elles
        // (`pieges/photo.png` prouve qu'un réglage éteint ne ramasse rien,
        // les fixtures médias vivent hors du manifeste). La recette fige donc
        // ce que le défaut donnait avant, et `extraEnvironment` peut le lever.
        environment["FOUINE_EXTRACT_IMAGES"] = "false"
        environment["FOUINE_EXTRACT_MEDIA"] = "false"
        environment["FOUINE_EXTRACT_TRANSCRIBE"] = "false"
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Lecture concurrente : un tube plein bloquerait le processus fils.
        var outData = Data(), errData = Data()
        let lock = NSLock()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isOut { outData = data } else { errData = data }
                lock.unlock()
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            XCTFail("délai dépassé (\(Int(timeout)) s) : fouine "
                    + arguments.joined(separator: " "))
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 30)

        lock.lock(); defer { lock.unlock() }
        return CommandResult(arguments: arguments,
                             status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }

    /// `fouine search … --json`, décodé au schéma gelé du §4.3.
    static func search(_ query: String, database: URL, extra: [String] = [],
                       limit: Int = 200) throws -> SearchPayload {
        let result = try run(["search", query, "--json", "--limit", "\(limit)"] + extra,
                             database: database)
        XCTAssertEqual(result.status, 0, result.describe)
        guard let data = result.stdout.data(using: .utf8) else {
            XCTFail("sortie non UTF-8 : \(result.describe)")
            throw XCTSkip("sortie illisible")
        }
        return try JSONDecoder().decode(SearchPayload.self, from: data)
    }

    // MARK: Lecture SQL directe (contrôles du §8, base ouverte en LECTURE SEULE)

    /// `sqlite3` du système EN ÉCRITURE, réservé aux bases JETABLES : il sert à
    /// fabriquer un état que la CLI ne sait pas produire — un `agent_status`
    /// vieux de trois jours, par exemple (constat CM-12). Jamais sur la base de
    /// production, que `Recette.run` ne désigne d'ailleurs jamais.
    @discardableResult
    static func sqliteWrite(_ sql: String, on database: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `sqlite3` du système, base ouverte en `mode=ro` : aucun test de la recette
    /// n'écrit dans la base de production.
    static func sqlite(_ sql: String, on database: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["file:\(database.path)?mode=ro", sql]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Préconditions OCR (vague 3)

    /// Copie d'opt-in (`FOUINE_TEST_DB`) contenant AU MOINS une page OCRisée.
    /// Sans opt-in ou sans OCR, tous les tests du §8.1 qui en dépendent
    /// (T6, T7, T11, T13) se sautent.
    static func requireOCRPages() throws -> URL {
        let database = try requireFullIndex()
        let raw = try sqlite("SELECT count(*) FROM page_src WHERE src = 2",
                             on: database)
        guard let count = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              count > 0 else {
            throw XCTSkip("aucune page OCRisée dans la base — lancer "
                          + "`fouine ocr --only <fixture>` d'abord")
        }
        return database
    }

    /// `doc_id` d'un document dont le `rel_path` se termine par `suffix`.
    static func docID(endingWith suffix: String, on database: URL) throws -> Int64 {
        let escaped = suffix.replacingOccurrences(of: "'", with: "''")
        let raw = try sqlite(
            "SELECT id FROM docs WHERE rel_path LIKE '%\(escaped)' LIMIT 1",
            on: database)
        guard let id = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw XCTSkip("document introuvable dans l'index : …\(suffix)")
        }
        return id
    }

    /// Texte indexé d'une page (colonne `body` de `page_fts`, pas `text`).
    static func pageBody(docID: Int64, page: Int, on database: URL) throws -> String {
        let rowid = docID * 100_000 + Int64(page)
        return try sqlite("SELECT body FROM page_fts WHERE rowid = \(rowid)",
                          on: database)
    }

    /// Répertoire de travail jetable, hors corpus, détruit en fin de test.
    /// Le chemin est CANONIQUE (`/private/var/…` et non `/var/…`) : `root add`
    /// résout le volume par UUID puis reconstruit le chemin absolu, et les deux
    /// formes ne se comparent pas (§2.3).
    static func scratchDirectory(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fouine-recette-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    // MARK: Base et racine JETABLES (audit S3 ; modèle de MovedRootTests)

    struct Scratch {
        let directory: URL
        let root: URL
        let database: URL
        let label: String
        /// Nombre de documents INDEXABLES posés sous la racine.
        let documents: Int
    }

    /// Termes semés dans le corpus jetable, pour que les tests aient de quoi
    /// chercher sans rien emprunter au corpus personnel.
    static let scratchTerms = ["chromatographie", "enthalpie", "polymere",
                               "markovnikov"]

    /// Fabrique une racine jetable peuplée, l'enregistre dans une base jetable
    /// et l'indexe. C'est le régime PAR DÉFAUT de la recette (audit S3) : tout
    /// ce qui teste le PRODUIT et non le corpus doit passer par ici.
    ///
    /// La racine porte aussi les nuisances que le crawl doit écarter (§5.2) —
    /// `._*`, `.DS_Store`, `.git/`, `.Spotlight-V100/`, `.Trashes/`,
    /// `.fseventsd/`, et un paquet `.pages` qui est un FICHIER opaque et non un
    /// dossier à parcourir : sur une base jetable, T8 vérifie ainsi une
    /// exclusion RÉELLEMENT exercée, au lieu de constater a posteriori qu'une
    /// base de production n'en porte pas.
    static func makeIndexedScratch(_ name: String, label: String = "Jetable",
                                   documents: Int = 12) throws -> Scratch {
        _ = try requireBinary()
        let directory = try scratchDirectory(name)
        let root = directory.appendingPathComponent("racine", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        for index in 0..<documents {
            let term = scratchTerms[index % scratchTerms.count]
            let body = """
                Fiche \(index) du corpus jetable de la recette.
                \(term) : la règle de \(term) sert ici de terme témoin, répété
                assez souvent pour que l'index en porte la trace.
                \(String(repeating: "\(term) azote reduction catalyseur. ", count: 6))
                """
            try body.write(to: root.appendingPathComponent("fiche-\(index).txt"),
                           atomically: true, encoding: .utf8)
        }

        // Nuisances : rien de tout cela ne doit apparaître dans `docs`.
        try Data("junk".utf8).write(to: root.appendingPathComponent("._fiche-0.txt"))
        try Data("junk".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        for hidden in [".git", ".Spotlight-V100", ".Trashes", ".fseventsd"] {
            let dir = root.appendingPathComponent(hidden, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("junk".utf8).write(to: dir.appendingPathComponent("piege.txt"))
        }
        // Paquet Apple : un `.pages` est un FICHIER opaque (§1, §5.2).
        let package = root.appendingPathComponent("Notes.pages", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("interieur du paquet".utf8)
            .write(to: package.appendingPathComponent("index.txt"))

        let database = directory.appendingPathComponent("recette.db")
        // Tracé dans la sortie du test : la garantie de l'audit S3 — « aucun
        // test ne touche la base de production » — doit être VÉRIFIABLE d'un
        // coup d'œil sur le journal de `make test`, pas seulement par lecture
        // du code.
        print("recette : base jetable \(database.path)")

        // `root add` d'abord, et SANS racine par défaut (§4.3) : c'est le
        // garde-fou de `MovedRootTests` — un `index` qui partirait sur ~/Livres
        // n'aurait rien à voir avec la recette et durerait une demi-heure.
        let added = try run(["root", "add", root.path, "--label", label],
                            database: database)
        XCTAssertEqual(added.status, 0, added.describe)
        let listed = try run(["root", "list", "--json"], database: database)
        XCTAssertEqual(listed.status, 0, listed.describe)
        struct Listed: Decodable { let label: String }
        let roots = try JSONDecoder().decode([Listed].self,
                                             from: Data(listed.stdout.utf8))
        XCTAssertEqual(roots.map(\.label), [label],
                       "la base jetable doit ne contenir QUE la racine de test")

        let indexed = try run(["index"], database: database, timeout: 300)
        XCTAssertEqual(indexed.status, 0, indexed.describe)

        return Scratch(directory: directory, root: root, database: database,
                       label: label, documents: documents)
    }
}

// MARK: - Outils de mesure

enum Stats {
    /// Percentile par plus proche rang, sur une série déjà triable.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    static func median(_ values: [Double]) -> Double { percentile(values, 50) }
}
