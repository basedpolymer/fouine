// IgnoreRuleSet.swift — les règles d'exclusion gardées par Fouine pour UNE
// racine (lot IG2). Propriété : A-Ingest. PUR : aucune lecture de disque ni de
// base.
//
// LE PENDANT DU FICHIER. `IgnoreRules` lit `.fouineignore`, que l'utilisateur
// écrit lui-même ; ce type-ci porte les règles saisies dans l'app ou par
// `fouine root ignore add`, gardées dans `roots.ignore_rules`. Mêmes trois
// formes, même sémantique : le crawl compile les deux sources avec le même
// code et les unit (`IgnoreRules.load(root:stored:)`).
//
// LA DIFFÉRENCE : UNE RÈGLE INVALIDE EST REFUSÉE À LA SAISIE, JAMAIS STOCKÉE.
// Le fichier ne peut qu'avertir — il est déjà écrit quand Fouine le lit. Ici on
// tient la plume : `!x` (négation), `#x` (un commentaire dans le fichier), une
// ligne vide ou un chemin qui porte `..` sont refusés avec une phrase qui nomme
// la règle. Un chemin à `..` ne correspondrait jamais à rien (`matches` compare
// à des chemins sous la racine) : le fichier le tolère en silence, la saisie le
// refuse parce qu'elle PEUT le dire.
//
// UNE FORME CANONIQUE, pour que le dédoublonnage et le retrait marchent :
// espaces de tête et de queue retirés, `/` initiaux retirés, `/` final ramené à
// un seul, NFC. Deux règles sont LA MÊME quand leurs formes canoniques se
// replient sur la même clé (casse et accents ignorés, comme au crawl) :
// `Santé/` et `sante/` ne se stockent pas deux fois.

import Foundation
import FouineCore

/// Pourquoi une règle est refusée. Le message anglais est celui de la CLI ;
/// l'app rend le cas dans la langue de l'utilisateur.
public enum IgnoreRuleError: Error, Equatable, Sendable, LocalizedError {
    case empty
    case negation(String)
    case comment(String)
    case lineBreak(String)
    case badPath(String)

    public var message: String {
        switch self {
        case .empty:
            return "an empty rule excludes nothing"
        case .negation(let rule):
            return "“\(rule)”: negation (!) is not supported — a rule names "
                + "what to skip"
        case .comment(let rule):
            return "“\(rule)”: a rule cannot start with # (in a .fouineignore "
                + "file, that line is a comment)"
        case .lineBreak(let rule):
            return "“\(rule.replacingOccurrences(of: "\n", with: "↵"))”: a rule "
                + "is a single line"
        case .badPath(let rule):
            return "“\(rule)”: a path starts at the top of the folder and cannot "
                + "hold an empty, “.” or “..” part"
        }
    }

    public var errorDescription: String? { message }
}

/// Les règles gardées d'une racine, dans l'ordre où elles ont été ajoutées.
public struct IgnoreRuleSet: Sendable, Equatable {

    /// Formes canoniques, sans doublon (au sens de `key`).
    public private(set) var rules: [String] = []

    public init() {}

    /// Des règles venues d'ailleurs que la saisie (un test, la base) : la
    /// PREMIÈRE invalide lève, rien n'est gardé à moitié.
    public init(validating raw: [String]) throws {
        for rule in raw { try add(rule) }
    }

    public var isEmpty: Bool { rules.isEmpty }
    public var count: Int { rules.count }

    // MARK: - Saisie

    /// La forme canonique d'une règle, ou le refus.
    public static func canonical(_ raw: String) throws -> String {
        // Le saut de ligne de QUEUE d'un copier-coller (et le `\r` d'un texte
        // venu de Windows) se retire en silence ; un saut de ligne AU MILIEU
        // ferait deux règles d'une seule dans un fichier, et n'en fait aucune
        // qui marche ici : `matches` compare des noms, qui n'en portent pas.
        var rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.unicodeScalars.contains(where: {
            CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) {
            throw IgnoreRuleError.lineBreak(rule)
        }
        guard !rule.isEmpty else { throw IgnoreRuleError.empty }
        if rule.hasPrefix("!") { throw IgnoreRuleError.negation(rule) }
        if rule.hasPrefix("#") { throw IgnoreRuleError.comment(rule) }
        while rule.hasPrefix("/") { rule.removeFirst() }
        guard !rule.isEmpty else { throw IgnoreRuleError.empty }

        if rule.contains("/") {
            let directoryOnly = rule.hasSuffix("/")
            while rule.hasSuffix("/") { rule.removeLast() }
            let parts = rule.split(separator: "/", omittingEmptySubsequences: false)
            if parts.isEmpty || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                throw IgnoreRuleError.badPath(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            rule = parts.joined(separator: "/") + (directoryOnly ? "/" : "")
        } else if rule == "." || rule == ".." {
            throw IgnoreRuleError.badPath(rule)
        }
        return RelPath.normalized(rule)
    }

    /// La clé de comparaison : casse et accents repliés, comme au crawl.
    public static func key(_ canonical: String) -> String {
        IgnoreRules.fold(canonical)
    }

    /// Ajoute une règle. `false` : elle y était déjà (sous une autre casse,
    /// peut-être) — rien n'a changé. Lève sur une règle invalide.
    @discardableResult
    public mutating func add(_ raw: String) throws -> Bool {
        let rule = try Self.canonical(raw)
        guard !contains(canonical: rule) else { return false }
        rules.append(rule)
        return true
    }

    /// Retire une règle, reconnue sous sa clé. `false` : elle n'y était pas, ou
    /// elle est invalide — donc pas là non plus.
    @discardableResult
    public mutating func remove(_ raw: String) -> Bool {
        guard let rule = try? Self.canonical(raw) else { return false }
        let wanted = Self.key(rule)
        let before = rules.count
        rules.removeAll { Self.key($0) == wanted }
        return rules.count != before
    }

    public func contains(_ raw: String) -> Bool { stored(raw) != nil }

    /// La règle GARDÉE qui répond à celle-ci, sous sa forme gardée : « déjà
    /// ignoré : Santé/ » plutôt que l'écho de ce qu'on vient de taper (`sante/`).
    public func stored(_ raw: String) -> String? {
        guard let rule = try? Self.canonical(raw) else { return nil }
        let wanted = Self.key(rule)
        return rules.first { Self.key($0) == wanted }
    }

    private func contains(canonical rule: String) -> Bool {
        let wanted = Self.key(rule)
        return rules.contains { Self.key($0) == wanted }
    }

    // MARK: - Stockage

    /// Le texte de `roots.ignore_rules`, ou `nil` quand il n'y a rien à garder.
    public var json: String? {
        guard !rules.isEmpty,
              let data = try? JSONSerialization.data(
                withJSONObject: rules, options: [.withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Relit la colonne. TOLÉRANT, comme la lecture du fichier : un texte
    /// illisible n'applique aucune règle et le DIT, une règle invalide (écrite
    /// à la main en SQL, ou par une version future) est sautée et dite.
    /// Refuser tout le jeu pour une ligne ferait réindexer ce que les autres
    /// excluent — le pire des deux maux.
    public static func decode(_ json: String?) -> (set: IgnoreRuleSet, warnings: [String]) {
        guard let json, !json.isEmpty else { return (IgnoreRuleSet(), []) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let array = object as? [Any] else {
            return (IgnoreRuleSet(), [
                "the ignore rules kept in the settings are not readable — "
                + "no rule applied",
            ])
        }
        var set = IgnoreRuleSet()
        var warnings: [String] = []
        for element in array {
            guard let text = element as? String else {
                warnings.append("an ignore rule kept in the settings is not text — ignored")
                continue
            }
            do { try set.add(text) }
            catch let error as IgnoreRuleError {
                warnings.append("ignore rule kept in the settings ignored: \(error.message)")
            } catch {}
        }
        return (set, warnings)
    }

    // MARK: - Forme, pour la phrase en clair

    /// Ce qu'une règle désigne, pour la dire sans montrer de motif.
    public enum Shape: Equatable, Sendable {
        /// `Santé/`, `Cours/Archives/` : ce dossier et tout ce qu'il contient.
        case folder(components: [String])
        /// `Cours/INDEX.md` : ce fichier ou ce dossier, à cet endroit.
        case path(components: [String])
        /// `*.md` : tous les fichiers de cette extension, partout.
        case fileExtension(String)
        /// `INDEX.md` : les fichiers de ce nom exact, partout.
        case fileName(String)
        /// `*brouillon*` : un motif sur le nom, partout.
        case namePattern(String)
    }

    /// La forme d'une règle CANONIQUE.
    public static func shape(of rule: String) -> Shape {
        if rule.contains("/") {
            var path = rule
            let directoryOnly = path.hasSuffix("/")
            while path.hasSuffix("/") { path.removeLast() }
            let components = path.split(separator: "/").map(String.init)
            return directoryOnly ? .folder(components: components)
                                 : .path(components: components)
        }
        let wildcards = CharacterSet(charactersIn: "*?[")
        if rule.hasPrefix("*.") {
            let ext = String(rule.dropFirst(2))
            if !ext.isEmpty, ext.rangeOfCharacter(from: wildcards) == nil {
                return .fileExtension(ext)
            }
        }
        return rule.rangeOfCharacter(from: wildcards) == nil
            ? .fileName(rule) : .namePattern(rule)
    }
}
