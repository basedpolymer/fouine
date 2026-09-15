// SQLiteReader.swift — lire la base d'une AUTRE application, sans jamais y
// toucher (lot INT-F4). Propriété : A-Ingest.
//
// TROIS PRÉCAUTIONS, ET CHACUNE RÉPOND À UN ACCIDENT POSSIBLE :
//
//   1. `SQLITE_OPEN_READONLY`. La base d'Apple Notes ou de Bear est celle d'une
//      application VIVANTE. Une écriture — même une migration de schéma faite
//      par une version plus récente de SQLite que la leur — corromprait les
//      notes de quelqu'un. Fouine n'ouvre jamais rien d'autre qu'en lecture.
//
//   2. `immutable=1`. Une base ouverte par son application porte un journal WAL
//      (`-wal`, `-shm`). L'ouvrir normalement en lecture seule fait quand même
//      TOUCHER ces deux fichiers (SQLite doit lire le WAL, et pour cela mapper
//      le `-shm`) : sur une base dont on n'a pas les droits d'écriture, cela
//      échoue ; sur une base dont on les a, cela écrit dans le dos de
//      l'application. `immutable=1` dit à SQLite « ce fichier ne bouge pas » :
//      il lit le seul fichier principal, sans verrou et sans WAL.
//      LE COMPROMIS, ASSUMÉ ET DOCUMENTÉ : les toutes dernières écritures de
//      l'application, celles qui n'ont pas encore été repliées dans le fichier
//      principal, ne sont pas vues. On peut donc lire un état vieux de quelques
//      secondes — voire d'une session, si l'application n'a jamais fait de
//      point de contrôle. Pour un index de recherche mis à jour en continu,
//      c'est sans conséquence : la passe suivante rattrape.
//
//   3. `SQLITE_OPEN_NOMUTEX`. Le lecteur n'est utilisé que par un fil à la fois
//      (il n'est d'ailleurs pas `Sendable`) : le mutex interne de SQLite ne
//      protégerait rien et coûterait à chaque appel.
//
// TCC. `NoteStore.sqlite` est protégé par « Accès complet au disque ». Sans
// l'autorisation, `sqlite3_open_v2` échoue en `SQLITE_CANTOPEN` et
// `sqlite3_errmsg` dit « authorization denied » — c'est ce que le Terminal du
// propriétaire a reçu le 08/09/2026, autorisation refusée comprise. On le
// reconnaît ICI, une fois, et on rend `SourceError.accessDenied` : un
// `access(2)` ne suffirait pas (sous TCC il répond « lisible » et l'ouverture
// échoue quand même), et un `errno` non plus (SQLite l'a déjà consommé).

import Foundation
import SQLite3

/// Une valeur lue dans une colonne.
public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var intValue: Int64? {
        switch self {
        case .integer(let v): return v
        case .double(let v):  return Int64(v)
        default:              return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let v):  return v
        case .integer(let v): return Double(v)
        default:              return nil
        }
    }

    public var stringValue: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    public var dataValue: Data? {
        if case .blob(let v) = self { return v }
        return nil
    }

    /// `true` pour `1`, ce que Core Data écrit dans une colonne booléenne.
    public var isTrue: Bool { (intValue ?? 0) != 0 }
}

/// Une ligne, par index de colonne. Recopiée : elle survit à l'avancement du
/// curseur, ce qui rend les tests lisibles et évite les pointeurs pendants.
public struct SQLiteRow: Sendable {
    public let values: [SQLiteValue]
    public subscript(index: Int) -> SQLiteValue {
        index >= 0 && index < values.count ? values[index] : .null
    }
}

/// Un lecteur de base SQLite, en lecture seule stricte.
public final class SQLiteReader {

    /// Comment la base est ouverte.
    public enum Access: Sendable {
        /// La base d'une application vivante : `mode=ro&immutable=1`, le seul
        /// fichier principal, sans verrou ni WAL (précaution 2 ci-dessus).
        case liveApplication
        /// Une COPIE que Fouine vient de faire dans un dossier à elle (lot
        /// AN1) : `mode=ro` sans `immutable`, pour que SQLite rejoue le `-wal`
        /// copié à côté. Le `-shm` qu'il crée pour cela naît dans le dossier de
        /// la copie, jamais dans celui de l'application.
        case privateCopy
    }

    private var handle: OpaquePointer?
    private let source: String

    /// Ouvre la base. Jette `SourceError.missing`, `.accessDenied` ou
    /// `.unreadable` — jamais un code SQLite brut : l'appelant doit pouvoir
    /// choisir la phrase à montrer sans relire une chaîne d'erreur.
    public init(url: URL, source: String, access: Access = .liveApplication,
                fileManager: FileManager = .default) throws {
        self.source = source
        guard fileManager.fileExists(atPath: url.path) else {
            throw SourceError.missing(source: source)
        }
        // URI SQLite : le chemin doit être encodé (« Group Containers » porte
        // une espace, et un `?` dans un nom de dossier casserait la requête).
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("?")
        allowed.remove("#")
        let encoded = url.path.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? url.path
        let query = access == .liveApplication ? "mode=ro&immutable=1" : "mode=ro"
        let uri = "file:\(encoded)?\(query)"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let status = sqlite3_open_v2(uri, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) }
                ?? "cannot open the database"
            if let db { sqlite3_close_v2(db) }
            throw Self.classify(status: status, message: message, source: source)
        }
        // Un `SELECT` d'ouverture : `sqlite3_open_v2` réussit parfois sans avoir
        // touché le fichier (il ouvre paresseusement), et le refus TCC
        // n'apparaît qu'à la première lecture réelle. Sans cette ligne, `probe`
        // dirait « lisible » d'une base que la première requête refusera.
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(
            db, "SELECT count(*) FROM sqlite_master", -1, &statement, nil)
        if prepared == SQLITE_OK, let statement {
            let step = sqlite3_step(statement)
            sqlite3_finalize(statement)
            if step != SQLITE_ROW && step != SQLITE_DONE {
                let message = String(cString: sqlite3_errmsg(db))
                sqlite3_close_v2(db)
                throw Self.classify(status: step, message: message, source: source)
            }
        } else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close_v2(db)
            throw Self.classify(status: prepared, message: message, source: source)
        }
        handle = db
    }

    deinit { close() }

    public func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    /// Déclare une collation insensible à la casse sous `name`.
    ///
    /// Anki (lot AN1) indexe les noms de ses paquets et de ses types de note
    /// sous une collation `unicase` qu'il fournit lui-même : sans elle, SQLite
    /// refuse de PRÉPARER toute requête que son planificateur ferait passer par
    /// ces index — mesuré le 14/09/2026, `SELECT count(*) FROM decks` rend « no
    /// such collation sequence: unicase ». Les requêtes de `AnkiSource` n'en ont
    /// pas besoin aujourd'hui ; la déclarer rend la lecture indifférente au plan
    /// que choisira la version suivante de SQLite. Une comparaison, jamais une
    /// écriture : la base reste ouverte en lecture seule.
    public func registerCaseInsensitiveCollation(named name: String) {
        guard let handle else { return }
        sqlite3_create_collation_v2(
            handle, name, SQLITE_UTF8, nil,
            { _, leftLength, left, rightLength, right in
                let lhs = String(decoding: UnsafeRawBufferPointer(
                    start: left, count: Int(max(0, leftLength))), as: UTF8.self)
                let rhs = String(decoding: UnsafeRawBufferPointer(
                    start: right, count: Int(max(0, rightLength))), as: UTF8.self)
                switch lhs.caseInsensitiveCompare(rhs) {
                case .orderedAscending:  return -1
                case .orderedDescending: return 1
                case .orderedSame:       return 0
                }
            }, nil)
    }

    /// Les tables présentes. Sert à refuser TÔT une base au schéma inconnu :
    /// une requête sur une table absente ne dirait rien d'utile.
    public func hasTable(_ name: String) -> Bool {
        var found = false
        try? forEachRow(
            "SELECT count(*) FROM sqlite_master WHERE type IN ('table','view') "
            + "AND name = '\(name.replacingOccurrences(of: "'", with: "''"))'") { row in
            found = (row[0].intValue ?? 0) > 0
        }
        return found
    }

    /// Les colonnes d'une table, en minuscules. Les bases d'Apple Notes
    /// changent de colonnes d'une version de macOS à l'autre : une source lit
    /// ce qui EXISTE plutôt que de casser sur un `no such column`.
    public func columns(of table: String) -> Set<String> {
        var names: Set<String> = []
        let escaped = table.replacingOccurrences(of: "'", with: "''")
        try? forEachRow("PRAGMA table_info('\(escaped)')") { row in
            if let name = row[1].stringValue { names.insert(name.lowercased()) }
        }
        return names
    }

    /// Exécute une requête et appelle `body` par ligne. STREAMING : une base de
    /// notes porte un blob par note, et tout charger en mémoire coûterait des
    /// dizaines de mégaoctets pour rien.
    public func forEachRow(_ sql: String,
                           _ body: (SQLiteRow) throws -> Void) throws {
        guard let handle else { throw SourceError.unreadable(source: source,
                                                             detail: "closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw SourceError.unreadable(source: source, detail: message)
        }
        defer { sqlite3_finalize(statement) }

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else {
                let message = String(cString: sqlite3_errmsg(handle))
                throw Self.classify(status: step, message: message, source: source)
            }
            let count = Int(sqlite3_column_count(statement))
            var values: [SQLiteValue] = []
            values.reserveCapacity(count)
            for index in 0..<Int32(count) {
                values.append(Self.value(statement, index))
            }
            try body(SQLiteRow(values: values))
        }
    }

    private static func value(_ statement: OpaquePointer,
                              _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let raw = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: raw))
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, index))
            guard length > 0, let raw = sqlite3_column_blob(statement, index) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: raw, count: length))
        default:
            return .null
        }
    }

    /// La traduction d'une panne SQLite en `SourceError`.
    ///
    /// Le refus TCC se reconnaît au MESSAGE (« authorization denied ») autant
    /// qu'au code : SQLite rend `SQLITE_CANTOPEN` aussi bien pour un fichier
    /// absent que pour un fichier interdit, et `SQLITE_AUTH` n'apparaît que
    /// dans certains cas. `internal` et non `private` : c'est la fonction que
    /// le test interroge, elle est pure.
    static func classify(status: Int32, message: String,
                         source: String) -> SourceError {
        let lower = message.lowercased()
        if status == SQLITE_AUTH || lower.contains("authorization denied")
            || lower.contains("operation not permitted")
            || lower.contains("permission denied") {
            return .accessDenied(source: source)
        }
        return .unreadable(source: source, detail: message)
    }
}
