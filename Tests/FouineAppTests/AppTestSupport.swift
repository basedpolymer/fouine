// AppTestSupport.swift — base jetable et attente des tâches de l'interface.
// Propriété : A-App.
//
// `SearchModel` travaille par `Task` détachées (recherche, facettes, moteurs
// OCR) : un test qui lirait ses `@Published` juste après `execute` verrait
// l'état d'AVANT. `settle` attend que le modèle soit retombé au repos, sans
// jamais bloquer le fil principal — dont les tâches @MainActor ont besoin pour
// s'exécuter.

import Foundation
import XCTest
import FouineCore
import FouineEmbed
@testable import FouineApp

/// Le modèle CoreML réel, chargé UNE fois pour toute la suite (~2,5 s sur i5 ;
/// lot I2 : `SeedTests` le chargeait trois fois). `nil` quand il n'est pas
/// installé — les tests qui en dépendent se sautent en disant le geste.
enum SharedModel {
    private static let loaded = LoadedEncoder {
        try E5Encoder(modelDir: EmbedPaths.modelDirectory())
    }

    static func encoder() throws -> E5Encoder? {
        guard EmbedPaths.modelAvailable(at: EmbedPaths.modelDirectory()) else {
            return nil
        }
        return try loaded.result.get()
    }

    private final class LoadedEncoder: @unchecked Sendable {
        let result: Result<E5Encoder, Error>
        init(_ make: () throws -> E5Encoder) { result = Result(catching: make) }
    }
}

/// Une base neuve, dans son propre dossier (donc son propre `fouine.lock`),
/// et le `StoreService` de l'app branché dessus. La base de PRODUCTION n'est
/// jamais touchée : le chemin est explicite, `FOUINE_DB` n'entre pas en jeu.
/// Un domaine de préférences JETABLE par processus de test.
///
/// `Prefs.defaults` est le vrai domaine `io.github.basedpolymer.fouine`. Sous
/// `swift test --parallel` (ce que fait `make ci-unit`), chaque test tourne dans
/// son propre processus xctest, et tous écrivaient dans le même fichier de
/// préférences de l'utilisateur : la session mémorisée par un test était relue
/// par un autre (`QuickFiltersSessionTests`, échecs aléatoires le 05/09/2026),
/// et l'historique de recherche de la machine se remplissait de requêtes de
/// test. Le domaine est nommé par le pid — deux processus ne partagent donc
/// rien — et détruit à la sortie du processus.
enum TestPrefs {
    private static let prefix = "io.github.basedpolymer.fouine.tests."
    private static let suiteName =
        prefix + String(ProcessInfo.processInfo.processIdentifier)

    /// À appeler AVANT le premier `SearchModel` du processus (il lit
    /// `Prefs.defaults` dès son initialisation). `TempAppDB.init` le fait pour
    /// tous les tests qui passent par une base jetable.
    static let isolate: Void = {
        sweepStaleDomains()
        guard let isolated = UserDefaults(suiteName: suiteName) else { return }
        isolated.removePersistentDomain(forName: suiteName)
        Prefs.defaults = isolated
    }()

    /// Le ménage se fait à l'ENTRÉE, jamais à la sortie : sous `--parallel`,
    /// SwiftPM termine ses processus xctest sans passer par `atexit` (mesuré
    /// le 05/09/2026 : 35 `.plist` restaient après un `atexit` qui appelait
    /// `removePersistentDomain` puis `synchronize`). Chaque processus efface
    /// donc les domaines des processus MORTS des passes précédentes — au plus
    /// une passe de fichiers traîne, quelques kilo-octets chacun.
    private static func sweepStaleDomains() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".plist") {
            let suite = String(name.dropLast(".plist".count))
            guard let pid = Int32(suite.dropFirst(prefix.count)), pid != me,
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

final class TempAppDB {
    let directory: URL
    let service: StoreService

    init() throws {
        _ = TestPrefs.isolate
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fouine-app-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        service = StoreService(
            databaseURL: directory.appendingPathComponent("fouine.db"))
        try service.open()
    }

    var store: GRDBStore { service.store }

    @discardableResult
    /// `sources` : la provenance de chaque page, dans l'ordre. Vide = tout
    /// natif, ce qu'étaient toutes les bases de cette suite avant le lot P3.
    func addDoc(relPath: String, ext: String = "txt", folder: String = "Essai",
                mtime: Double = 1_700_000_000, lang: String? = nil,
                pages: [String], sources: [PageSource] = []) throws -> Int64 {
        let id = try store.upsertDoc(DocRecord(
            volUUID: "TEST-VOL", relPath: relPath, ext: ext, topFolder: folder,
            size: 1_000, mtime: mtime, nPages: pages.count, state: .extracted,
            lang: lang))
        try store.replacePages(docID: id, pages: pages.enumerated().map {
            PageText(page: $0.offset + 1, text: $0.element,
                     source: $0.offset < sources.count ? sources[$0.offset] : .native)
        })
        return id
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
extension XCTestCase {

    /// Attend que la recherche ET les facettes soient terminées.
    ///
    /// `Task.sleep` et non un `RunLoop.run` : le modèle est isolé sur le
    /// MainActor, et une attente qui monopolise le fil principal empêcherait
    /// justement ses continuations de s'y exécuter — le test se figerait.
    func settle(_ model: SearchModel, timeout: TimeInterval = 20,
                file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !model.isSearching && !model.isFaceting { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("le modèle de recherche ne s'est pas stabilisé en \(timeout) s",
                file: file, line: line)
    }

    /// Une recherche complète : saisie, exécution, attente.
    func run(_ model: SearchModel, _ text: String) async {
        model.text = text
        model.execute(remember: false)
        await settle(model)
    }
}
