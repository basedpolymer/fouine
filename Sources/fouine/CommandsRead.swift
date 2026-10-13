// CommandsRead.swift — `fouine read` : LIRE ce qu'on a trouvé (constat PM-18).
// Propriété : A-Core.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// CE QUE ÇA RÉPARE. `fouine search` dit OÙ regarder ; rien ne disait CE QU'IL Y
// A. Le serveur MCP, lui, le sait depuis le palier 4 (`fouine_read_page`) : un
// assistant pouvait lire une page trouvée, un humain au terminal — ou un agent
// qui n'a que le shell — non. Ce que l'assistant peut faire, l'humain doit
// pouvoir le faire (même règle que `fouine list`, lot BR1).
//
// UNE SEULE IMPLÉMENTATION, PAS DEUX. `fouine read` passe par `PageReading`
// (FouineCore), que l'outil MCP reprendra : l'audit a montré où mène la
// duplication — le même nombre s'appelle `score` d'un côté et `bm25` de
// l'autre (PM-16b). Les clés de `--json` sont donc, au mot près, celles des
// outils correspondants.
//
// LECTURE SEULE (`openStoreReadOnly`) : lire une page pendant une passe
// d'indexation doit marcher.

import Foundation
import ArgumentParser
import FouineCore

// MARK: - fouine read

struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read the indexed text of one page.",
        discussion: """
            Returns the text Fouine extracted or recognised, NOT the original \
            file: `abs_path` says where the file is, opening it is up to you. \
            Long pages come back in slices — pass the announced next offset \
            back to --offset. A page that exists but carries no indexed text \
            is a success with an empty text and a note, not an error.
            """)

    @Argument(help: "Document identifier (`fouine search --json` gives doc_id).")
    var docID: Int64

    @Argument(help: "Page number, 1-indexed.")
    var page: Int

    @Option(name: .customLong("max-chars"),
            help: "Characters to read from this page, and from each context page.")
    var maxChars: Int = 4_000

    @Option(name: .long, help: "Start reading this many characters in.")
    var offset: Int = 0

    @Option(name: .long, help: "Also read this many pages before and after (0-2).")
    var context: Int = 0

    @Flag(name: .long, help: "JSON output.")
    var json = false

    /// Bornes en 64, AVANT la base : une valeur hors plage est une faute de
    /// frappe, pas une panne (§4.3). Les bornes sont celles de l'outil MCP.
    func validate() throws {
        guard docID >= 1 else { throw ValidationError("doc_id must be 1 or more.") }
        guard page >= 1, page <= Schema.maxPage else {
            throw ValidationError("page must be between 1 and \(Schema.maxPage).")
        }
        guard maxChars >= 200, maxChars <= 40_000 else {
            throw ValidationError("--max-chars must be between 200 and 40000.")
        }
        guard offset >= 0 else { throw ValidationError("--offset must be 0 or more.") }
        guard context >= 0, context <= 2 else {
            throw ValidationError("--context must be between 0 and 2.")
        }
    }

    func run() {
        CLI.guarded {
            let store = try CLI.openStoreReadOnly()
            let reading: PageReading
            do {
                reading = try PageReading.load(
                    store: store, docID: docID, page: page, maxChars: maxChars,
                    offset: offset, contextPages: context,
                    missingTextNote: PageReading.commandMissingTextNote)
            } catch let failure as PageReading.Failure {
                // Une page qui n'existe pas est une erreur d'USAGE (64), avec
                // le nombre de pages que le document a vraiment : c'est le
                // renseignement qui évite le second essai à l'aveugle.
                throw UsageRefusal(message: failure.description
                                   + Self.hint(for: failure))
            }
            if json {
                // Ce que la page DÉSIGNE (lot CL2) : une requête pour la
                // frontière diapositives / images incorporées, rien pour un PDF.
                let ext = reading.page.ext.lowercased()
                let textPages = PageLayout.textThenMedia.contains(ext)
                    ? try store.textPageCounts(forDocIDs: [docID])[docID] : nil
                var body = reading.json()
                Self.decorate(&body, page: reading.page, textPages: textPages)
                if var context = body["context"] as? [[String: Any]] {
                    for index in context.indices where index < reading.context.count {
                        Self.decorate(&context[index], page: reading.context[index],
                                      textPages: textPages)
                    }
                    body["context"] = context
                }
                try CLI.printJSON(body)
                return
            }
            print(Self.header(reading.page, pageCount: reading.pageCount))
            print(reading.page.text)
            if let note = reading.page.note { print("(\(note))") }
            if reading.page.truncated, let next = reading.page.nextOffset {
                print("… \(reading.page.totalChars - next) character(s) left "
                      + "— `--offset \(next)` for the rest")
            }
            for neighbour in reading.context {
                print("")
                print(Self.header(neighbour, pageCount: reading.pageCount))
                print(neighbour.text)
            }
        }
    }

    /// L'en-tête d'une page : de quel document, où, quelle page, d'où vient le
    /// texte. Une ligne — le reste de la sortie est la page elle-même, et un
    /// cartouche de cinq lignes la noierait.
    static func header(_ page: PageReading.Page, pageCount: Int) -> String {
        let total = pageCount > 0 ? "/\(pageCount)" : ""
        return "[\(page.docID)] \(page.relPath) · page \(page.number)\(total) · "
            + GRDBStore.sourceLabel(page.source.rawValue)
    }

    /// `slide`, `embedded_image`, `time_seconds` — et le lien horodaté qui va
    /// avec (lot CL2). Les mêmes quatre champs que `fouine_read_page`, avec
    /// `page_label` que `PageReading` porte déjà : la page qu'on va citer doit
    /// se citer de la même façon des deux côtés. « Page 170 » d'un cours est
    /// souvent la 117ᵉ image incorporée, et « page 1 » d'une vidéo de deux
    /// heures ne renvoie personne nulle part.
    ///
    /// Le moment se lit sur le TEXTE RENDU, sans lecture de plus : une page de
    /// transcription commence par son marqueur (`[00:01] …`), et c'est celui-là
    /// qu'il faut — il n'y a pas ici d'extrait qui désignerait un paragraphe
    /// plus loin.
    static func decorate(_ body: inout [String: Any], page: PageReading.Page,
                         textPages: Int?) {
        let time = page.source == .transcript
            ? TranscriptTime.first(in: page.text) : nil
        body["time_seconds"] = time.map { $0 as Any } ?? NSNull()
        if let time {
            body["link"] = DeepLink.link(absolutePath: page.absPath,
                                         docID: page.docID, page: page.number,
                                         time: time).absoluteString
        }
        let label = PageLayout.page(page.number, ext: page.ext,
                                    textPages: textPages)
        body["slide"] = label.slide.map { $0 as Any } ?? NSNull()
        body["embedded_image"] = label.embeddedImage.map { $0 as Any } ?? NSNull()
    }

    /// Le geste, quand la demande est impossible.
    static func hint(for failure: PageReading.Failure) -> String {
        switch failure {
        case .unknownDocument: return " — `fouine list` shows what is indexed"
        default: return ""
        }
    }
}
