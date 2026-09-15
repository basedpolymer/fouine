// CommandsLicenses.swift — `fouine licenses` (SPEC §4.3, audit B1-10 / B1-22).
// Propriété : A-Pack.
//
// POURQUOI CETTE COMMANDE EXISTE. Fouine redistribue trois paquets tiers :
// GRDB (MIT) et swift-argument-parser (Apache-2.0) liés statiquement, Sparkle
// (MIT) embarqué en XCFramework. MIT exige que la notice de copyright
// accompagne toute copie du logiciel ; Apache-2.0 § 4(a) exige qu'une copie de
// la licence soit remise au destinataire. Jusqu'au 02/09/2026 rien n'était
// livré : ni fichier de notices à la racine, ni copie dans le bundle, ni dans
// le DMG, ni dans l'interface — et `fouine --version` rendait « 1.0.0 » et rien
// d'autre. Citer le nom d'une licence en prose dans le README n'est pas
// reproduire sa notice.
//
// AJOUT AU CONTRAT GELÉ, PAS MODIFICATION. Le §4.3 gèle les noms de
// sous-commandes, leurs options, les codes de sortie et la forme du JSON : on
// peut y AJOUTER, on n'y renomme rien. `fouine --version` n'est pas touchée —
// une bannière plus bavarde y casserait les scripts qui la lisent.
//
// DEUX RÉGIMES, selon d'où tourne le binaire :
//
//   · DEPUIS LE BUNDLE (Fouine.app/Contents/Helpers/fouine) : le texte
//     INTÉGRAL, lu dans ../Resources/THIRD_PARTY_LICENSES.md. C'est le cas de
//     l'utilisateur qui n'a que le DMG — celui, précisément, que la licence et les
//     licences permissives visent à servir.
//   · HORS BUNDLE (.build/release/fouine, un lien /usr/local/bin, un clone) :
//     les notices, puis le CHEMIN du fichier dans le dépôt. On ne recopie pas
//     4 000 lignes de licence dans un terminal quand le fichier est à deux pas.
//
// Les messages sont en ANGLAIS, comme tout ce que rend la CLI (CONTRIBUTING,
// « la ligne de commande parle anglais »). Ce sont aussi les termes des
// licences elles-mêmes.

import Foundation
import ArgumentParser
import FouineCore

struct LicensesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "licenses",
        abstract: "Licence of Fouine and notices of the redistributed components.")

    @Flag(name: .long,
          help: "Print the full text of THIRD_PARTY_LICENSES.md even outside the app bundle.")
    var full = false

    /// Une notice = ce qu'il faut pour identifier un composant sans ouvrir le
    /// fichier : nom, version, licence, titulaire, adresse.
    struct Notice {
        let name: String
        let version: String
        let licence: String
        let copyright: String
        let url: String
    }

    /// Les versions viennent de `Package.resolved` et ne peuvent pas être lues
    /// à l'exécution (le fichier n'est pas livré) : elles sont recopiées ici, et
    /// `RELEASING.md` § 1 rappelle de les tenir à jour avec
    /// `THIRD_PARTY_LICENSES.md`.
    static let notices: [Notice] = [
        Notice(name: "GRDB.swift",
               version: "7.11.1",
               licence: "MIT",
               copyright: "Copyright (C) 2015-2025 Gwendal Roué",
               url: "https://github.com/groue/GRDB.swift"),
        Notice(name: "swift-argument-parser",
               version: "1.8.2",
               licence: "Apache-2.0",
               copyright: "Copyright (c) Apple Inc. and the Swift project authors",
               url: "https://github.com/apple/swift-argument-parser"),
        Notice(name: "Sparkle",
               version: "2.9.6",
               licence: "MIT (plus the licences of its bundled components)",
               copyright: "Copyright (c) 2006-2013 Andy Matuschak and others",
               url: "https://github.com/sparkle-project/Sparkle"),
        Notice(name: "multilingual-e5-small",
               version: "—",
               licence: "MIT",
               copyright: "Copyright (c) Microsoft Corporation",
               url: "https://huggingface.co/intfloat/multilingual-e5-small"),
    ]

    func run() {
        print("Fouine \(FouineVersion.string)")
        print("Copyright (C) 2026 Mathis Demory")
        print("Licence: Fouine Source-Available Licence 1.0 (LicenseRef-Fouine-Source-Available).")
        print("Source:  https://github.com/basedpolymer/fouine")
        print("")
        print("This program comes with ABSOLUTELY NO WARRANTY, to the extent permitted by law.")
        print("The source code is available: you may read, compile and modify it for your")
        print("own personal use, or to propose a contribution. You may not redistribute it.")
        print("")
        // UNE partie du dépôt n'est pas sous la licence source-available, et c'est le genre de chose
        // qu'un utilisateur doit pouvoir apprendre du binaire lui-même plutôt
        // que d'un fichier du dépôt (palier 4, D2 § 5.9). Ce n'est PAS un
        // composant tiers : il n'a donc pas sa place dans la liste ci-dessous,
        // ni dans THIRD_PARTY_LICENSES.md, qui reste inchangé.
        print("Part of this program is under a different licence:")
        print("")
        print("  Sources/FouineMCPKit — MIT")
        print("    Copyright (c) 2026 Mathis Demory")
        print("    MCP transport, JSON-RPC, dual-era router, tool envelopes,")
        print("    token budget and cursors. No dependencies: reusable on its own.")
        print("    The fouine binary as a whole is under the Fouine Source-Available Licence.")
        print("")
        print("Redistributed third-party components:")
        print("")
        for notice in Self.notices {
            let head = notice.version == "—"
                ? notice.name
                : "\(notice.name) \(notice.version)"
            print("  \(head) — \(notice.licence)")
            print("    \(notice.copyright)")
            print("    \(notice.url)")
        }
        print("")
        print("  The multilingual-e5-small model is NOT redistributed with the app:")
        print("  it is an optional 220 MB download you ask for explicitly.")
        print("")

        guard let file = Self.thirdPartyFile() else {
            print("Full licence texts: THIRD_PARTY_LICENSES.md at the root of the")
            print("source repository, and in Fouine.app/Contents/Resources/.")
            return
        }

        // Depuis le bundle, on IMPRIME : l'utilisateur n'a pas le dépôt sous la
        // main, et lui donner un chemin dans un paquet signé serait une réponse
        // de développeur à une question d'utilisateur.
        if full || Self.runsFromAppBundle() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                CLI.fail("fouine: cannot read \(file.path)")
                return
            }
            print("─── THIRD_PARTY_LICENSES.md " + String(repeating: "─", count: 40))
            print("")
            print(text)
            return
        }

        print("Full licence texts: \(file.path)")
        print("(run `fouine licenses --full` to print them here)")
    }

    /// Le binaire tourne-t-il depuis `Fouine.app/Contents/Helpers/fouine` ?
    ///
    /// On lit la STRUCTURE du chemin de l'exécutable, pas `Bundle.main` : pour
    /// un exécutable en ligne de commande posé dans `Contents/Helpers`,
    /// `Bundle.main` est le répertoire de l'exécutable, pas le `.app`.
    /// `resolvingSymlinksInPath()` parce que l'installation courante est un lien
    /// `/usr/local/bin/fouine` vers le helper (audit D1/V9).
    static func runsFromAppBundle() -> Bool { helpersResources() != nil }

    private static func executableDirectory() -> URL? {
        guard let path = Bundle.main.executableURL?.resolvingSymlinksInPath()
                ?? CommandLine.arguments.first.map({ URL(fileURLWithPath: $0) })
        else { return nil }
        return path.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// `Contents/Resources` quand l'exécutable est dans `Contents/Helpers`.
    private static func helpersResources() -> URL? {
        guard let dir = executableDirectory() else { return nil }
        let contents = dir.deletingLastPathComponent()
        guard dir.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents" else { return nil }
        return contents.appendingPathComponent("Resources")
    }

    /// Le `THIRD_PARTY_LICENSES.md` qui s'applique à CE binaire : celui du
    /// bundle s'il y en a un, sinon celui du dépôt, cherché en remontant depuis
    /// l'exécutable (`.build/release/fouine` est à deux niveaux de la racine).
    static func thirdPartyFile() -> URL? {
        let name = "THIRD_PARTY_LICENSES.md"
        let fm = FileManager.default

        if let resources = helpersResources() {
            let candidate = resources.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        guard var dir = executableDirectory() else { return nil }
        // Six niveaux : `.build/<triple>/release/fouine` dans le pire cas, plus
        // une marge. Au-delà, on remonterait hors du dépôt sans rien prouver.
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}
