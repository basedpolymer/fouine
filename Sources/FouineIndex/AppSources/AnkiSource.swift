// AnkiSource.swift — les cartes d'Anki (lot AN1). Propriété : A-Ingest.
//
// LA BASE : `~/Library/Application Support/Anki2/<profil>/collection.anki2`,
// une base SQLite par profil. Trois tables suffisent :
//
//   · `notes` — `flds` porte les champs d'une note (`AnkiText`), `mod` sa date
//     de modification en secondes Unix ;
//   · `cards` — une note donne une ou plusieurs cartes, et c'est la CARTE qui
//     est rangée dans un paquet (`did`, ou `odid` quand elle est prêtée à un
//     paquet filtré) ;
//   · `decks` — le nom du paquet, niveaux séparés par U+001F depuis le schéma
//     15. Avant (schéma 11, Anki 2.1.27 et plus ancien), les paquets sont un
//     JSON dans `col.decks`, niveaux séparés par `::`. Les deux se lisent.
//
// Les types de note et les noms de champs ne sont PAS lus : l'ordre des champs
// est celui de `flds`, et les noms ne sont pas recopiés (voir `AnkiText`).
//
// UN FICHIER PAR PAQUET, UNE PAGE PAR NOTE. Une carte fait 250 caractères en
// moyenne (mesuré : 3 359 notes, 42 paquets). Un fichier par note ferait de
// chaque résultat un document d'une ligne, et 42 cartes trouvées rempliraient
// l'écran devant les cours ; un paquet-document avec une page par note donne
// « 3 cartes sur 42 · Tout voir », la recherche dans le paquet, et la règle de
// diversité le tient à sa place. Le saut de page est `MaterializedText`.
// L'arborescence des paquets devient celle des dossiers (« Chimie::Organique »
// → `Chimie/Organique.md`), que la facette « Dossiers » et `dossier:` suivent.
// Au-delà de `notesPerFile` notes, un paquet se découpe en volumes
// (« Paquet (2).md ») : le plafond de 5 000 pages d'un format re-paginé
// (`ExtractLimits.maxSplitPages`) tronquerait sinon un paquet partagé de
// 30 000 notes sans prévenir personne d'autre que le journal.
//
// POURQUOI UNE COPIE, ET PAS `immutable=1` COMME APPLE NOTES ET BEAR. Anki
// écrit en WAL sans fichier `-shm` (index du WAL en mémoire) et ne replie pas
// son journal dans la base tant qu'il reste ouvert. Mesuré le 14/09/2026 sur
// la collection du propriétaire, Anki 26.08 ouvert : `immutable=1` lit 3 235
// notes, la copie avec son WAL en lit 3 359 — les 124 notes des deux derniers
// jours n'existaient encore que dans le WAL. Une lecture ordinaire en
// `mode=ro`, elle, a CRÉÉ un `-shm` dans le dossier d'Anki (mesuré aussi) et
// pose un verrou sur la base d'une application vivante, en pleine révision.
// Fouine clone donc le WAL PUIS la base dans un dossier
// temporaire à elle (clone APFS : instantané, sans verrou), vérifie que ni l'un
// ni l'autre n'a bougé pendant la copie, et lit la copie (`.privateCopy`).
// L'ordre compte : un point de contrôle d'Anki qui tomberait entre les deux
// copies écrit dans la base des pages que le WAL déjà copié rejoue à
// l'identique ; l'ordre inverse perdrait les pages du WAL remis à zéro.
//
// RÉOUVRIR. Anki pour Mac n'a pas de lien vers une note : le fichier ne porte
// donc pas de `fouine-open:`, et l'aperçu ouvre l'application (retrouvée par
// son identifiant de paquet, jamais par un chemin écrit dans un fichier).

import Foundation
import FouineExtract

public struct AnkiSource: AppSource {

    public static let identifier = "anki"

    public let id = AnkiSource.identifier
    public let displayName = "Anki"
    public let rootLabel = "Anki"
    /// Pas de lien vers une note dans Anki pour Mac : voir l'en-tête.
    public let openURLTemplate = ""
    public let fileNoun = "deck"
    /// Le dossier des profils (`Anki2`), pas une base : il y en a une par profil.
    public let storeURL: URL
    /// Où la collection est copiée le temps d'une lecture.
    public let temporaryDirectory: URL

    /// Les identifiants de l'application, du plus récent au plus ancien : le
    /// lanceur d'Anki 25 s'appelle `net.ankiweb.anki`, les versions d'avant
    /// `net.ankiweb.dtop`.
    public static let bundleIdentifiers = ["net.ankiweb.anki", "net.ankiweb.dtop"]
    public var bundleIdentifiers: [String] { Self.bundleIdentifiers }

    /// Un fichier par paquet, nommé comme lui : le nom du fichier EST le nom
    /// du paquet (volumes « (2) » compris), sans suffixe d'identifiant à ôter.
    public func documentTitle(fileStem: String) -> String { fileStem }

    /// Notes par fichier avant de passer au volume suivant. 2 000 laisse de la
    /// marge sous les 5 000 pages d'un document, même pour des cartes longues.
    public static let notesPerFile = 2_000

    /// Le nom de la collection dans un dossier de profil.
    static let collectionName = "collection.anki2"

    /// Les dossiers d'`Anki2` qui ne sont pas des profils.
    static let nonProfileFolders: Set<String> = ["addons21", "logs"]

    public init(storeURL: URL = AnkiSource.defaultStoreURL(),
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.storeURL = storeURL
        self.temporaryDirectory = temporaryDirectory
    }

    public static func defaultStoreURL(
        fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Anki2",
                                    isDirectory: true)
    }

    // MARK: - Présence

    /// Les profils qui portent une collection, triés par nom.
    public func profiles(fileManager: FileManager = .default)
        -> [(name: String, collection: URL)] {
        let names = (try? fileManager.contentsOfDirectory(atPath: storeURL.path)) ?? []
        return names.sorted()
            .filter { !$0.hasPrefix(".") && !Self.nonProfileFolders.contains($0) }
            .map { ($0, storeURL.appendingPathComponent($0, isDirectory: true)
                        .appendingPathComponent(Self.collectionName)) }
            .filter { fileManager.fileExists(atPath: $0.1.path) }
    }

    public func isPresent(fileManager: FileManager) -> Bool {
        !profiles(fileManager: fileManager).isEmpty
    }

    /// Sans copier ni ouvrir la collection : `probe` est appelé à chaque
    /// affichage de l'onglet des réglages, et la collection d'un étudiant en
    /// médecine pèse des centaines de mégaoctets. `Application Support` n'est
    /// pas protégé par TCC ; un fichier illisible reste un refus à dire.
    public func probe(fileManager: FileManager) -> SourcePresence {
        let found = profiles(fileManager: fileManager)
        guard !found.isEmpty else { return .absent }
        return found.allSatisfy { fileManager.isReadableFile(atPath: $0.collection.path) }
            ? .ready : .accessDenied
    }

    /// Les notes cherchables : une page par note, donc un saut de page de plus
    /// que de sauts de page dans chaque fichier.
    public func copiedNoteCount(in folder: URL, fileManager: FileManager) -> Int {
        SourceMaterializer.markdownFiles(in: folder, fileManager: fileManager)
            .reduce(0) { total, name in
                guard let text = try? String(
                    contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                else { return total }
                return total + text.components(separatedBy: MaterializedText.pageBreak).count
            }
    }

    // MARK: - Lecture

    /// Un fichier par paquet (ou par volume de paquet), tous profils confondus.
    /// Un profil illisible fait tout échouer : les copies déjà faites restent
    /// alors en place jusqu'à la passe suivante, plutôt que d'être effacées.
    public func notes() throws -> [SourceNote] {
        let fileManager = FileManager.default
        let found = profiles(fileManager: fileManager)
        guard !found.isEmpty else { throw SourceError.missing(source: displayName) }
        var out: [SourceNote] = []
        for profile in found {
            let decks = try readCollection(at: profile.collection,
                                           fileManager: fileManager)
            // Le nom du profil ne devient un dossier que s'il y a PLUSIEURS
            // profils : « User 1 » au-dessus de tous les paquets n'aiderait
            // personne.
            out += Self.documents(
                decks: decks,
                profileFolder: found.count > 1
                    ? SourceMaterializer.cleanComponent(profile.name) : nil)
        }
        return out
    }

    /// Ce qu'une collection contient, avant mise en fichiers.
    struct Deck: Equatable {
        let id: Int64
        /// Les niveaux du nom, du plus haut au plus bas.
        let path: [String]
        /// Par identifiant croissant — l'ordre de création.
        var notes: [Note]
    }

    struct Note: Equatable {
        let id: Int64
        /// Secondes Unix (`notes.mod`).
        let modified: Int64
        let text: String
        /// Les images de la note, noms du dossier `collection.media`.
        var images: [String] = []
    }

    /// Copie puis lit une collection.
    func readCollection(at collection: URL,
                        fileManager: FileManager) throws -> [Deck] {
        let folder = temporaryDirectory.appendingPathComponent(
            "fouine-anki-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        let copy = try Self.snapshot(collection: collection, into: folder,
                                     source: displayName, fileManager: fileManager)
        let reader = try SQLiteReader(url: copy, source: displayName,
                                      access: .privateCopy)
        defer { reader.close() }
        reader.registerCaseInsensitiveCollation(named: "unicase")
        return try Self.decks(reader: reader, source: displayName)
    }

    /// Clone le WAL puis la base dans `folder`, et recommence si l'un des deux a
    /// bougé pendant la copie. Rend l'URL de la base copiée.
    static func snapshot(collection: URL, into folder: URL, source: String,
                         fileManager: FileManager) throws -> URL {
        let wal = URL(fileURLWithPath: collection.path + "-wal")
        let copy = folder.appendingPathComponent(collectionName)
        let copyWAL = URL(fileURLWithPath: copy.path + "-wal")

        func stamp(_ url: URL) -> [String] {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            else { return ["absent"] }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let date = (attributes[.modificationDate] as? Date)?
                .timeIntervalSinceReferenceDate ?? -1
            return ["\(size)", "\(date)"]
        }

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw SourceError.unreadable(source: source,
                                         detail: "cannot prepare a copy: "
                                               + error.localizedDescription)
        }
        for _ in 1...3 {
            let before = stamp(collection) + stamp(wal)
            for url in [copy, copyWAL, URL(fileURLWithPath: copy.path + "-shm")] {
                try? fileManager.removeItem(at: url)
            }
            do {
                if fileManager.fileExists(atPath: wal.path) {
                    try fileManager.copyItem(at: wal, to: copyWAL)
                }
                try fileManager.copyItem(at: collection, to: copy)
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain,
                   nsError.code == NSFileReadNoPermissionError {
                    throw SourceError.accessDenied(source: source)
                }
                throw SourceError.unreadable(source: source,
                                             detail: "cannot copy the collection: "
                                                   + error.localizedDescription)
            }
            if stamp(collection) + stamp(wal) == before { return copy }
        }
        throw SourceError.unreadable(
            source: source,
            detail: "the collection kept changing while it was copied; "
                  + "the next pass will try again")
    }

    /// Les paquets d'une collection ouverte, avec leurs notes lisibles.
    static func decks(reader: SQLiteReader, source: String) throws -> [Deck] {
        guard reader.hasTable("notes"), reader.hasTable("cards") else {
            throw SourceError.unreadable(source: source,
                                         detail: "unknown schema (no notes table)")
        }
        let names = try deckNames(reader: reader, source: source)

        // Le paquet d'une note : celui de sa PREMIÈRE carte (ordre du modèle),
        // paquet d'origine quand la carte est prêtée à un paquet filtré.
        var deckOfNote: [Int64: Int64] = [:]
        try reader.forEachRow("""
            SELECT nid, CASE WHEN odid != 0 THEN odid ELSE did END
            FROM cards ORDER BY nid, ord
            """) { row in
            guard let note = row[0].intValue, let deck = row[1].intValue,
                  deckOfNote[note] == nil else { return }
            deckOfNote[note] = deck
        }

        var byDeck: [Int64: [Note]] = [:]
        try reader.forEachRow("SELECT id, mod, flds FROM notes ORDER BY id") { row in
            // Une note sans carte (Anki la supprime à « Vérifier la base ») n'a
            // pas de paquet : elle n'a nulle part où aller.
            guard let id = row[0].intValue, let deck = deckOfNote[id] else { return }
            let text = AnkiText.noteText(fields: row[2].stringValue ?? "")
            // Une carte qui n'est qu'une image n'a rien à chercher.
            guard !text.isEmpty else { return }
            let fields = row[2].stringValue ?? ""
            byDeck[deck, default: []].append(
                Note(id: id, modified: row[1].intValue ?? 0, text: text,
                     images: AnkiText.imageNames(fields: fields)))
        }

        return byDeck.keys.sorted().map { deckID in
            // Un paquet disparu de `decks` (base réparée à moitié) garde ses
            // cartes, sous le nom qu'Anki lui donnerait : « Default ».
            Deck(id: deckID, path: names[deckID] ?? ["Default"],
                 notes: byDeck[deckID] ?? [])
        }
    }

    /// Identifiant de paquet → niveaux du nom.
    static func deckNames(reader: SQLiteReader, source: String) throws -> [Int64: [String]] {
        var names: [Int64: [String]] = [:]
        if reader.hasTable("decks") {
            try reader.forEachRow("SELECT id, name FROM decks") { row in
                guard let id = row[0].intValue, let name = row[1].stringValue else { return }
                names[id] = deckPath(name)
            }
            return names
        }
        // Schéma 11 : un objet JSON `{ "<id>": { "name": "A::B", … } }`.
        var json: String?
        try reader.forEachRow("SELECT decks FROM col LIMIT 1") { row in
            json = row[0].stringValue
        }
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SourceError.unreadable(source: source,
                                         detail: "unknown schema (no deck list)")
        }
        for (key, value) in object {
            guard let id = Int64(key), let deck = value as? [String: Any],
                  let name = deck["name"] as? String else { continue }
            names[id] = deckPath(name)
        }
        return names
    }

    /// Les niveaux d'un nom de paquet : U+001F depuis le schéma 15, `::` avant.
    static func deckPath(_ name: String) -> [String] {
        let separator = name.contains("\u{1F}") ? "\u{1F}" : "::"
        let levels = name.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return levels.isEmpty ? ["Default"] : levels
    }

    // MARK: - Mise en fichiers

    /// Le segment d'une note dans son fichier : le texte, puis une ligne par
    /// image (`MaterializedText.imageLine`), que l'extracteur retire du texte
    /// indexé et que l'aperçu relit.
    static func segment(_ note: Note) -> String {
        ([note.text] + note.images.map(MaterializedText.imageLine))
            .joined(separator: "\n") + "\n"
    }

    /// Le dossier des médias du profil dont vient un paquet recopié, `nil` s'il
    /// ne se retrouve pas.
    ///
    /// - Parameter relativePath: le chemin du fichier SOUS le dossier « Anki »
    ///   de Fouine. Le premier niveau n'est un profil que s'il y a plusieurs
    ///   profils — la règle même de `notes()`.
    public func mediaFolder(forCopiedDeck relativePath: String,
                            fileManager: FileManager = .default) -> URL? {
        let found = profiles(fileManager: fileManager)
        let profile: (name: String, collection: URL)?
        if found.count == 1 {
            profile = found.first
        } else {
            let first = relativePath.split(separator: "/").first.map(String.init) ?? ""
            profile = found.first { SourceMaterializer.cleanComponent($0.name) == first }
        }
        return profile?.collection.deletingLastPathComponent()
            .appendingPathComponent("collection.media", isDirectory: true)
    }

    /// Le fichier d'une image dans un dossier de médias, s'il y est vraiment.
    ///
    /// Le nom vient d'un fichier `.md` — que n'importe qui peut écrire dans une
    /// racine : il est revérifié ici, et l'URL rendue est toujours DANS
    /// `folder`. Un nom qu'Anki a gardé encodé (`%20`) est essayé décodé.
    public static func mediaFile(named name: String, in folder: URL,
                                 fileManager: FileManager = .default) -> URL? {
        let candidates = [name, name.removingPercentEncoding].compactMap { $0 }
        for candidate in candidates where AnkiText.isMediaName(candidate) {
            let url = folder.appendingPathComponent(candidate, isDirectory: false)
            var isDirectory: ObjCBool = false
            guard url.standardizedFileURL.deletingLastPathComponent().path
                    == folder.standardizedFileURL.path,
                  fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            return url
        }
        return nil
    }

    /// Les fichiers d'une collection. PURE : les tests fabriquent des `Deck`.
    static func documents(decks: [Deck], profileFolder: String?) -> [SourceNote] {
        var used: Set<String> = []
        var out: [SourceNote] = []
        for deck in decks.sorted(by: { $0.id < $1.id }) where !deck.notes.isEmpty {
            let folders = (profileFolder.map { [$0] } ?? [])
                + deck.path.dropLast().map(SourceMaterializer.cleanComponent)
            let leaf = SourceMaterializer.cleanComponent(deck.path.last ?? "Default")
            let volumes = stride(from: 0, to: deck.notes.count, by: notesPerFile)
                .map { Array(deck.notes[$0..<min($0 + notesPerFile, deck.notes.count)]) }

            for (index, notes) in volumes.enumerated() {
                let title = index == 0 ? leaf : "\(leaf) (\(index + 1))"
                var path = (folders + ["\(title).md"]).joined(separator: "/")
                // Deux paquets que le nettoyage rend homonymes (« a/b » et
                // « a:b ») ne s'écrasent pas : le second prend son identifiant.
                // En minuscules, parce que le disque d'un Mac ignore la casse.
                if used.contains(path.lowercased().precomposedStringWithCanonicalMapping) {
                    path = (folders + ["\(title) \(deck.id).md"]).joined(separator: "/")
                }
                used.insert(path.lowercased().precomposedStringWithCanonicalMapping)

                out.append(SourceNote(
                    id: index == 0 ? "\(deck.id)" : "\(deck.id)-\(index + 1)",
                    title: title,
                    text: notes.map(Self.segment).joined(separator: MaterializedText.pageBreak),
                    folder: deck.path.dropLast().joined(separator: "::"),
                    modified: Date(timeIntervalSince1970:
                                    TimeInterval(notes.map(\.modified).max() ?? 0)),
                    openURL: nil,
                    relativePath: path,
                    titleInText: false))
            }
        }
        return out
    }
}
