// BearSource.swift — les notes de Bear (lot INT-F4). Propriété : A-Ingest.
//
// LA BASE : `~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/
// Application Data/database.sqlite`, Core Data elle aussi. Elle est plus
// simple que celle d'Apple Notes : le texte est en clair dans `ZSFNOTE.ZTEXT`,
// en Markdown — le format que Fouine indexe déjà. Il n'y a donc ni protobuf ni
// décompression, seulement une requête.
//
// CE QU'ON GARDE, ET POURQUOI :
//   · `ZTRASHED = 1` — corbeille : écartée, et son fichier effacé s'il
//     existait. C'est ce qu'attend quelqu'un qui vient de jeter une note.
//   · `ZARCHIVED = 1` — archivée : GARDÉE. Archiver dans Bear, c'est ranger,
//     pas jeter ; une note archivée reste une note qu'on cherche, et la cacher
//     ferait de « je ne la trouve plus » le résultat du rangement.
//   · `ZENCRYPTED = 1` — chiffrée : le texte n'est pas lisible, on la saute en
//     le disant (une ligne de journal), plutôt que d'écrire un fichier vide.
//
// LES DOSSIERS. Bear n'en a pas : il a des étiquettes (`ZSFNOTETAG`, jointes
// par une table d'association dont le NUMÉRO change d'une version à l'autre —
// `Z_7TAGS`, `Z_5TAGS`…). Ce numéro instable est la raison pour laquelle
// `folder` reste nul ici : les étiquettes sont d'ailleurs DANS le texte
// Markdown (`#projet`), donc déjà cherchables.
//
// NON VÉRIFIÉ SUR UNE VRAIE BASE : Bear n'est pas installé sur la machine de
// développement. Le schéma vient de la documentation publique et le lecteur se
// prouve sur une base fabriquée au même schéma.

import Foundation

public struct BearSource: AppSource {

    public static let identifier = "bear"

    public let id = BearSource.identifier
    public let displayName = "Bear"
    public let rootLabel = "Bear"
    public let openURLTemplate = "bear://x-callback-url/open-note?id=%@"
    public let bundleIdentifiers = ["net.shinyfrog.bear"]
    public let storeURL: URL

    public init(storeURL: URL = BearSource.defaultStoreURL()) {
        self.storeURL = storeURL
    }

    public static func defaultStoreURL(
        fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data",
                isDirectory: true)
            .appendingPathComponent("database.sqlite")
    }

    public func notes() throws -> [SourceNote] {
        let reader = try SQLiteReader(url: storeURL, source: displayName)
        defer { reader.close() }
        guard reader.hasTable("ZSFNOTE") else {
            throw SourceError.unreadable(source: displayName,
                                         detail: "unknown schema (no ZSFNOTE table)")
        }
        let available = reader.columns(of: "ZSFNOTE")
        func column(_ name: String) -> String {
            available.contains(name.lowercased()) ? name : "NULL"
        }
        let sql = """
            SELECT \(column("ZUNIQUEIDENTIFIER")), \(column("ZTITLE")), \
            \(column("ZTEXT")), \(column("ZMODIFICATIONDATE")), \
            \(column("ZTRASHED")), \(column("ZENCRYPTED"))
            FROM ZSFNOTE
            """

        var out: [SourceNote] = []
        try reader.forEachRow(sql) { row in
            guard let identifier = row[0].stringValue, !identifier.isEmpty,
                  let link = self.openURL(forNote: identifier) else { return }
            let locked = row[5].isTrue
            let text = locked ? "" : (row[2].stringValue ?? "")
            out.append(SourceNote(
                id: identifier,
                title: SourceMaterializer.title(row[1].stringValue, text: text),
                text: text, folder: nil,
                modified: Date(timeIntervalSinceReferenceDate:
                                row[3].doubleValue ?? 0),
                openURL: link, deleted: row[4].isTrue, locked: locked))
        }
        return out
    }
}
