// AppleNotesSource.swift — les notes d'Apple Notes (lot INT-F4).
// Propriété : A-Ingest.
//
// LA BASE : `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`.
// C'est un magasin Core Data, d'où les noms de colonnes en `Z…` :
//
//   · `ZICCLOUDSYNCINGOBJECT` porte À LA FOIS les notes et les dossiers. Une
//     NOTE a un `ZNOTEDATA` (clé étrangère vers `ZICNOTEDATA`), un titre dans
//     `ZTITLE1` et un dossier dans `ZFOLDER` ; un DOSSIER a son nom dans
//     `ZTITLE2`. La même table, deux entités : c'est l'héritage Core Data
//     « single table », et c'est pourquoi la requête se joint à elle-même.
//   · `ZICNOTEDATA.ZDATA` porte le corps de la note : protobuf gzippé
//     (`NotesProtobuf`).
//   · les dates sont des dates Core Data : secondes depuis le 01/01/2001,
//     ce qu'est exactement `Date(timeIntervalSinceReferenceDate:)`.
//
// LES COLONNES CHANGENT D'UNE VERSION DE macOS À L'AUTRE. `ZISPASSWORDPROTECTED`
// n'existe pas partout, `ZMARKEDFORDELETION` non plus. La requête est donc
// CONSTRUITE à partir de `PRAGMA table_info` : une colonne absente devient un
// `NULL` littéral, et Fouine lit une base d'une version qu'elle ne connaît pas
// au lieu de tomber sur « no such column ».
//
// TCC. Cette base est protégée par « Accès complet au disque » — mesuré le
// 08/09/2026 : même le Terminal du propriétaire reçoit « authorization
// denied ». Le refus remonte en `SourceError.accessDenied`, et c'est
// l'application qui dit le geste.

import Foundation

public struct AppleNotesSource: AppSource {

    public static let identifier = "notes"

    public let id = AppleNotesSource.identifier
    public let displayName = "Apple Notes"
    public let rootLabel = "Notes"
    public let openURLTemplate = "notes://showNote?identifier=%@"
    public let bundleIdentifiers = ["com.apple.Notes"]
    public let storeURL: URL

    /// - Parameter storeURL: la base à lire. Injectée par les tests, qui en
    ///   fabriquent une au schéma réel : la vraie est inaccessible sans
    ///   « Accès complet au disque ».
    public init(storeURL: URL = AppleNotesSource.defaultStoreURL()) {
        self.storeURL = storeURL
    }

    public static func defaultStoreURL(
        fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/group.com.apple.notes",
                isDirectory: true)
            .appendingPathComponent("NoteStore.sqlite")
    }

    public func notes() throws -> [SourceNote] {
        let reader = try SQLiteReader(url: storeURL, source: displayName)
        defer { reader.close() }
        guard reader.hasTable("ZICCLOUDSYNCINGOBJECT"),
              reader.hasTable("ZICNOTEDATA") else {
            throw SourceError.unreadable(
                source: displayName,
                detail: "unknown schema (no ZICCLOUDSYNCINGOBJECT table)")
        }
        let available = reader.columns(of: "ZICCLOUDSYNCINGOBJECT")

        // Chaque colonne facultative devient `NULL` quand cette version de
        // macOS ne la porte pas : l'ordre des colonnes du SELECT, lui, ne
        // bouge jamais — c'est lui qui indexe les lignes plus bas.
        func column(_ name: String, _ prefix: String = "n") -> String {
            available.contains(name.lowercased()) ? "\(prefix).\(name)" : "NULL"
        }
        let sql = """
            SELECT \(column("ZIDENTIFIER")), \(column("ZTITLE1")), \
            \(column("ZMODIFICATIONDATE1")), \(column("ZMARKEDFORDELETION")), \
            \(column("ZISPASSWORDPROTECTED")), \
            \(available.contains("ztitle2") ? "f.ZTITLE2" : "NULL"), d.ZDATA
            FROM ZICCLOUDSYNCINGOBJECT AS n
            JOIN ZICNOTEDATA AS d ON d.Z_PK = n.ZNOTEDATA
            \(available.contains("zfolder")
              ? "LEFT JOIN ZICCLOUDSYNCINGOBJECT AS f ON f.Z_PK = n.ZFOLDER"
              : "")
            """

        var out: [SourceNote] = []
        try reader.forEachRow(sql) { row in
            guard let identifier = row[0].stringValue, !identifier.isEmpty,
                  let link = self.openURL(forNote: identifier) else { return }
            let locked = row[4].isTrue
            let deleted = row[3].isTrue
            let text: String
            var problem: String?
            if locked || deleted {
                // Une note verrouillée porte un corps chiffré, une note à la
                // corbeille n'a pas à être lue : dans les deux cas on ne
                // décompresse rien — c'est aussi ce qui rend la passe rapide
                // sur une grosse corbeille.
                text = ""
            } else if let blob = row[6].dataValue {
                let read = NotesProtobuf.readNote(inCompressed: blob)
                text = read.text ?? ""
                problem = read.problem
            } else {
                text = ""
            }
            let title = SourceMaterializer.title(row[1].stringValue,
                                                 text: text)
            out.append(SourceNote(
                id: identifier, title: title, text: text,
                folder: row[5].stringValue,
                modified: Date(timeIntervalSinceReferenceDate:
                                row[2].doubleValue ?? 0),
                openURL: link, deleted: deleted, locked: locked,
                problem: problem))
        }
        return out
    }
}
