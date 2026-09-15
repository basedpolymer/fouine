// GoldenTranscriptTests.swift — le contrat de sortie, sous forme de fichiers.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// POURQUOI DES TRANSCRIPTIONS. Le protocole est textuel et sans état : une
// séance est une liste de lignes envoyées et de lignes attendues. Un test =
// deux fichiers, aucun ordonnanceur, aucun réseau — et surtout, la revue de la
// PR devient MÉCANIQUE : on lit `Transcripts/*.jsonl` et on voit exactement ce
// que le serveur promet, sans dérouler du Swift.
//
// FORMAT. Une ligne `> …` est une requête envoyée telle quelle (elle n'a pas
// besoin d'être du JSON valide : `bad-json.jsonl` en dépend). Une ligne `< …`
// est la réponse attendue. Une requête sans réponse attendue derrière elle est
// une NOTIFICATION : le serveur ne doit rien écrire. `#` ouvre un commentaire.
//
// COMPARAISON STRUCTURELLE, pas textuelle : les deux côtés sont analysés, et
// l'ordre des clés n'entre pas en compte. Les valeurs qui dépendent de la
// machine — chemin de la base jetable, taille en octets, horodatage — portent
// le joker `"<any>"`. Tout le reste est figé : un champ qui apparaît, disparaît
// ou change de nom fait rougir le test.

import Foundation
import XCTest
import FouineMCP
import FouineMCPKit

final class GoldenTranscriptTests: XCTestCase {

    private struct Step {
        let request: String
        let expected: [String: Any]?
        let lineNumber: Int
    }

    /// Les treize séances, avec la BASE que chacune demande. La liste est
    /// explicite — un fichier ajouté et jamais nommé ici ne serait jamais
    /// rejoué, et le second test le vérifie dans les deux sens.
    ///
    /// La base fait partie du contrat : `search-hybrid-fallback` n'a de sens
    /// que sur une base qui porte des VECTEURS sans modèle installé, et
    /// `read-page-offset` que sur des pages assez longues pour être coupées.
    /// Les nommer ici plutôt que dans le fichier `.jsonl` garde la
    /// transcription lisible comme une séance, ce qu'elle est.
    private static let transcripts: [(name: String, index: () throws -> TempIndex)] = [
        ("initialize", { try TempIndex() }),
        ("discover", { try TempIndex() }),
        ("tools-list", { try TempIndex() }),
        ("status", { try TempIndex() }),
        ("bad-json", { try TempIndex() }),
        ("bad-version", { try TempIndex() }),
        ("search-lexical", { try TempIndex() }),
        ("search-hybrid-fallback", { try TempIndex(vectorisedPages: 2) }),
        ("read-page", { try TempIndex() }),
        ("read-page-offset", { try TempIndex(pageChars: 600) }),
        ("similar-no-vector", { try TempIndex(vectorisedPages: 2) }),
        ("list-documents", { try TempIndex() }),
        ("list-documents-failed",
         { try TempIndex(failedDocuments: 1, skippedDocuments: 1) }),
    ]

    func testEveryTranscriptReplaysExactly() throws {
        for (name, makeIndex) in Self.transcripts {
            let index = try makeIndex()
            let server = try index.makeServer()
            let steps = try load(name)
            XCTAssertFalse(steps.isEmpty, "\(name).jsonl est vide")

            for step in steps {
                let response = server.handle(Data(step.request.utf8))
                guard let expected = step.expected else {
                    XCTAssertNil(response,
                                 "\(name).jsonl:\(step.lineNumber) — cette requête est une "
                                 + "notification, le serveur ne doit rien écrire")
                    continue
                }
                guard let response else {
                    XCTFail("\(name).jsonl:\(step.lineNumber) — aucune réponse")
                    continue
                }
                let actual = try JSONMatch.object(response)
                if let problem = JSONMatch.mismatch(expected: expected, actual: actual) {
                    XCTFail("""
                        \(name).jsonl:\(step.lineNumber) — \(problem)
                        rendu : \(String(decoding: response, as: UTF8.self))
                        """)
                }
            }
        }
    }

    /// Le contrôle que la comparaison structurelle ne peut pas faire : les
    /// transcriptions existent bien sur le disque, et le fichier qu'on croit
    /// rejouer n'est pas vide.
    func testEveryTranscriptFileExists() throws {
        for (name, _) in Self.transcripts {
            let url = RepoPaths.transcripts.appendingPathComponent("\(name).jsonl")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "transcription manquante : \(url.path)")
        }
        // Et l'inverse : un `.jsonl` posé dans le dossier mais absent de la
        // liste ci-dessus ne serait jamais joué, ce qui est pire qu'une absence.
        let onDisk = try FileManager.default
            .contentsOfDirectory(at: RepoPaths.transcripts, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        XCTAssertEqual(onDisk, Self.transcripts.map(\.name).sorted(),
                       "la liste des transcriptions rejouées diverge du dossier")
    }

    /// Un pourcentage doit sortir LISIBLE, et c'est un contrôle sur les OCTETS,
    /// pas sur la valeur analysée.
    ///
    /// `JSONSerialization` sérialise un `Double` sur dix-sept chiffres
    /// significatifs dès que la valeur n'est pas exactement représentable en
    /// binaire : 16,63 y sort en `16.629999999999999`. Sur un serveur d'agent ce
    /// n'est pas cosmétique — le modèle recopie ce nombre tel quel dans sa
    /// phrase à l'utilisateur. Relevé sur la base de production avant
    /// correction, d'où ce test.
    func testCoverageIsWrittenAsAReadableDecimal() throws {
        // 2 vecteurs sur 6 pages = 33,333… %, la valeur la plus hostile qui soit.
        let index = try TempIndex(vectorisedPages: 2)
        let server = try index.makeServer()
        let response = try XCTUnwrap(server.handle(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fouine_status","arguments":{"include_agent":false}}}"#.utf8)))
        let text = String(decoding: response, as: UTF8.self)

        XCTAssertTrue(text.contains(#""vector_coverage_pct":33.33"#),
                      "pourcentage illisible dans la réponse : \(text)")
        XCTAssertFalse(text.contains("33.329999"), "dix-sept chiffres significatifs")
        // Et la valeur reste un NOMBRE JSON, pas une chaîne : `outputSchema`
        // annonce `"type": "number"`.
        let payload = try JSONMatch.object(response)
        let structured = ((payload["result"] as? [String: Any])?["structuredContent"]
                           as? [String: Any]) ?? [:]
        let coverage = try XCTUnwrap(structured["vector_coverage_pct"] as? NSNumber)
        XCTAssertEqual(coverage.doubleValue, 33.33, accuracy: 0.001)
        XCTAssertEqual(structured["vectors"] as? Int, 2)
    }

    // MARK: - Lecture des fichiers

    private func load(_ name: String) throws -> [Step] {
        let url = RepoPaths.transcripts.appendingPathComponent("\(name).jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        var steps: [Step] = []

        for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let number = offset + 1
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            if line.hasPrefix("> ") {
                steps.append(Step(request: String(line.dropFirst(2)), expected: nil,
                                  lineNumber: number))
            } else if line.hasPrefix("< ") {
                guard let last = steps.popLast() else {
                    XCTFail("\(name).jsonl:\(number) — une réponse sans requête")
                    continue
                }
                let expected = try JSONMatch.object(Data(line.dropFirst(2).utf8))
                steps.append(Step(request: last.request, expected: expected,
                                  lineNumber: last.lineNumber))
            } else {
                XCTFail("\(name).jsonl:\(number) — ligne ni `> ` ni `< ` : \(line)")
            }
        }
        return steps
    }
}
