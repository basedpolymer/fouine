// SourceMaterializer.swift — une note, un fichier Markdown (lot INT-F4).
// Propriété : A-Ingest.
//
// LE FICHIER EST LE CONTRAT. Tout le reste du produit — crawl, extraction,
// recherche, facettes, Spotlight, aperçu — ne voit qu'un `.md` ordinaire dans
// un dossier ordinaire. C'est ce qui rend ce lot petit : il n'ajoute pas un
// chemin d'indexation, il fabrique des fichiers.
//
// TROIS DÉCISIONS, ET CHACUNE A UNE RAISON MESURÉE :
//
//   1. LE TITRE EST DANS LE CORPS (`# Titre`). Fouine n'indexe PAS les noms de
//      fichiers (SPEC §5.3 (e), mesuré par le lot INT-F2) : un titre qui ne
//      serait que dans le nom du fichier ne serait pas cherchable, et chercher
//      une note par son titre est le premier geste de quiconque en écrit.
//      Pas pour un paquet Anki (`SourceNote.titleInText`, lot AN2) : le nom du
//      paquet n'appartient à aucune carte.
//
//   2. LE `mtime` DU FICHIER EST CELUI DE LA NOTE. Le crawl delta compare
//      (rel_path, taille, mtime) : sans cela, chaque passe verrait tous les
//      fichiers changés et ré-extrairait toutes les notes, indéfiniment. Avec,
//      une passe qui ne trouve rien de neuf ne coûte qu'un `stat` par note.
//
//   3. LE NOM PORTE L'IDENTIFIANT. Deux notes peuvent s'appeler « Courses » ;
//      jamais deux notes n'ont le même identifiant. Huit caractères suffisent
//      (un UUID en donne 32) et gardent le nom lisible dans le Finder.
//
// L'ÉCRITURE EST ATOMIQUE et se fait UNIQUEMENT sous le dossier reçu en
// paramètre. Aucun chemin de ce fichier ne connaît `~/Library` : c'est
// l'appelant qui décide où, et le test injecte un dossier temporaire.
//
// ANKI RANGE EN SOUS-DOSSIERS (lot AN1). Un paquet « Chimie::Organique » devient
// `Chimie/Organique.md` : la facette « Dossiers » et le filtre `dossier:`
// retrouvent l'arborescence que l'utilisateur a construite dans Anki. La source
// fournit donc un chemin relatif (`SourceNote.relativePath`) ; il est revérifié
// ICI composant par composant, parce que c'est ici qu'on écrit — un nom de
// paquet ne doit jamais faire sortir un fichier du dossier de la source.

import Foundation

/// Ce qu'une matérialisation a fait.
public struct SourceMaterializerReport: Sendable, Equatable {
    /// Fichiers écrits (créés ou mis à jour).
    public var written = 0
    /// Notes inchangées depuis la dernière fois : rien n'a été réécrit.
    public var unchanged = 0
    /// Fichiers effacés : note supprimée dans l'application, ou disparue.
    public var removed = 0
    /// Notes sautées : à la corbeille, verrouillées, ou vides.
    public var skipped = 0
    /// Ce qui a échoué, en anglais, une phrase par incident.
    public var errors: [String] = []

    public init() {}

    /// Le nombre de fichiers présents après coup.
    public var files: Int { written + unchanged }
}

public enum SourceMaterializer {

    /// Le titre de repli. Anglais dans le cœur ; l'application n'affiche pas
    /// cette chaîne, elle affiche le nom du fichier.
    public static let untitled = "Untitled"

    /// Longueur maximale du titre dans le nom de fichier. 80 caractères : au
    /// delà, le Finder tronque au milieu et le nom cesse d'aider.
    public static let titleLimit = 80

    /// Caractères de l'identifiant conservés dans le nom du fichier.
    public static let identifierLength = 8

    // MARK: - Le fichier

    /// Le titre affiché d'une note : celui de l'application, ou la première
    /// ligne du corps, ou « Untitled ». PURE.
    public static func title(_ stored: String?, text: String) -> String {
        if let stored,
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let firstLine = text.split(separator: "\n", maxSplits: 1,
                                   omittingEmptySubsequences: true).first
        let candidate = firstLine.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? untitled : candidate
    }

    /// Le nom du fichier d'une note. PURE.
    ///
    /// `/` et `:` sont interdits (le premier sépare les chemins, le second est
    /// le séparateur historique du Finder, qui l'affiche donc à l'envers) ;
    /// les retours à la ligne aussi — un titre de note EST souvent la première
    /// ligne du corps, retours compris.
    public static func fileName(title: String, id: String) -> String {
        let cleaned = cleanComponent(title)
        let suffix = String(id.filter { $0.isLetter || $0.isNumber }
                              .prefix(identifierLength))
        return suffix.isEmpty ? "\(cleaned).md" : "\(cleaned)-\(suffix).md"
    }

    /// Un nom de fichier ou de dossier lisible et sûr, sans extension. PURE.
    public static func cleanComponent(_ raw: String) -> String {
        var cleaned = raw
        for forbidden in ["/", ":", "\n", "\r", "\t"] {
            cleaned = cleaned.replacingOccurrences(of: forbidden, with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Un point en tête ferait un fichier CACHÉ, que le crawl saute
        // (`.skipsHiddenFiles`) : la note serait écrite et jamais indexée. Pour
        // un dossier, c'est tout un paquet qui disparaîtrait — Anki trie ses
        // paquets par nom, et « .📚 Géographie » est un nom réel, mesuré.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.count > titleLimit {
            cleaned = String(cleaned.prefix(titleLimit))
                .trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? untitled : cleaned
    }

    /// Le chemin relatif d'une note est-il sûr ? Des composants non vides, ni
    /// `.` ni `..`, pas de chemin absolu, et un `.md` au bout. PURE.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), path.lowercased().hasSuffix(".md") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    /// Les fichiers `.md` sous `folder`, sous-dossiers compris, en chemins
    /// relatifs. Un dossier absent n'en contient aucun.
    public static func markdownFiles(in folder: URL,
                                     fileManager: FileManager = .default) -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        // L'énumérateur peut rendre `/private/var/…` pour un dossier donné en
        // `/var/…` (dossier temporaire) : on essaie le chemin tel quel, puis
        // résolu — une seule résolution de la base, pas une par fichier.
        let bases = [folder.standardizedFileURL.path,
                     folder.standardizedFileURL.resolvingSymlinksInPath().path]
        var out: [String] = []
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "md" {
            let path = url.standardizedFileURL.path
            guard let base = bases.first(where: { path.hasPrefix($0 + "/") }) else {
                continue
            }
            out.append(String(path.dropFirst(base.count + 1)))
        }
        return out
    }

    /// Le contenu du fichier. PURE.
    public static func contents(sourceID: String, note: SourceNote) -> String {
        SourceLinks.header(sourceID: sourceID, openURL: note.openURL)
        + (note.titleInText ? "# \(note.title)\n\n" : "")
        + note.text
        + (note.text.hasSuffix("\n") ? "" : "\n")
    }

    // MARK: - L'écriture

    /// Écrit les notes d'une source dans `directory`, et efface ce qui n'a plus
    /// lieu d'être.
    ///
    /// Ne jette JAMAIS : chaque incident devient une ligne d'`errors`. Une
    /// note illisible ne doit pas empêcher les mille autres d'être indexées, et
    /// une passe d'indexation ne doit pas tomber parce qu'une application a
    /// changé son schéma.
    @discardableResult
    public static func write(notes: [SourceNote], sourceID: String,
                             into directory: URL,
                             fileManager: FileManager = .default)
        -> SourceMaterializerReport {
        var report = SourceMaterializerReport()
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true)
        } catch {
            report.errors.append("cannot create \(directory.lastPathComponent): "
                                 + error.localizedDescription)
            return report
        }

        var kept: Set<String> = []
        for note in notes {
            // Une note dont le CORPS n'a pas pu être lu pour une raison qui
            // mérite d'être dite (blob trop gros, CM-14) : le motif remonte, la
            // note est sautée, et les mille autres s'écrivent. C'est la même
            // discipline que le reste de ce fichier — jamais un jet, toujours
            // une ligne d'`errors`.
            if let problem = note.problem {
                report.errors.append("“\(note.title)”: \(problem)")
                report.skipped += 1
                continue
            }
            // Une note VIDE de tout — ni titre ni corps — ne produirait qu'un
            // fichier à en-tête, un document de plus dans l'index et zéro
            // résultat de recherche.
            let empty = note.text.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty && note.title == untitled
            guard !note.deleted, !note.locked, !empty else {
                report.skipped += 1
                continue
            }
            let name = note.relativePath ?? fileName(title: note.title, id: note.id)
            guard isSafeRelativePath(name) else {
                report.errors.append("refused path “\(name)”")
                report.skipped += 1
                continue
            }
            kept.insert(keptKey(name))
            let url = directory.appendingPathComponent(name)
            let body = contents(sourceID: sourceID, note: note)
            do {
                if try isUpToDate(url: url, note: note, body: body,
                                  fileManager: fileManager) {
                    report.unchanged += 1
                    continue
                }
                if name.contains("/") {
                    try fileManager.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                }
                try Data(body.utf8).write(to: url, options: .atomic)
                // Le `mtime` est posé APRÈS l'écriture : `write` le remet à
                // l'heure courante, et c'est justement lui que le crawl delta
                // regarde.
                try fileManager.setAttributes([.modificationDate: note.modified],
                                              ofItemAtPath: url.path)
                report.written += 1
            } catch {
                report.errors.append("cannot write “\(name)”: "
                                     + error.localizedDescription)
            }
        }

        // Ce qui n'est plus une note vivante s'en va : note effacée dans
        // l'application, note renommée (donc écrite sous un autre nom), note
        // passée à la corbeille, paquet Anki déplacé. Le crawl delta verra la
        // disparition et purgera le document.
        for name in markdownFiles(in: directory, fileManager: fileManager) {
            guard !kept.contains(keptKey(name)) else { continue }
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
                report.removed += 1
            } catch {
                report.errors.append("cannot delete “\(name)”: "
                                     + error.localizedDescription)
            }
        }
        removeEmptyFolders(under: directory, fileManager: fileManager)
        return report
    }

    /// La clé de comparaison entre ce qu'on vient d'écrire et ce qui est sur
    /// le disque : NFC, parce que le système de fichiers peut rendre un « é »
    /// décomposé, et SANS CASSE, parce que le disque d'un Mac l'ignore — un
    /// paquet renommé de « chimie » en « Chimie » est réécrit par-dessus son
    /// ancien fichier, qui peut garder l'ancien nom ; le comparer à la casse
    /// près ferait effacer le fichier qu'on vient d'écrire.
    private static func keptKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Les sous-dossiers devenus vides s'en vont : un paquet Anki supprimé ne
    /// doit pas laisser un dossier vide dans la facette « Dossiers ». Le dossier
    /// de la source lui-même reste — c'est une racine.
    private static func removeEmptyFolders(under directory: URL,
                                           fileManager: FileManager) {
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        var folders: [URL] = []
        for case let url as URL in enumerator
        where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            folders.append(url)
        }
        // Les plus profonds d'abord : un parent ne se vide qu'après ses enfants.
        for folder in folders.sorted(by: { $0.path.count > $1.path.count }) {
            let content = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
            // `.DS_Store`, laissé par le Finder, ne rend pas un dossier habité.
            if content.allSatisfy({ $0 == ".DS_Store" }) {
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    /// Le fichier existant est-il DÉJÀ celui qu'on s'apprête à écrire ?
    ///
    /// La comparaison porte sur la taille ET la date : réécrire un fichier
    /// identique lui donnerait un nouveau `mtime`… puis on le remettrait à
    /// celui de la note, donc rien ne changerait pour le crawl — mais on aurait
    /// réécrit des milliers de fichiers à chaque passe, pour rien. La date
    /// tolère une seconde d'écart : certains systèmes de fichiers arrondissent.
    private static func isUpToDate(url: URL, note: SourceNote, body: String,
                                   fileManager: FileManager) throws -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date else {
            return false
        }
        return size == Data(body.utf8).count
            && abs(modified.timeIntervalSince(note.modified)) < 1
    }
}
