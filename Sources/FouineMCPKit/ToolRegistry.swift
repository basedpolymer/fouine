// ToolRegistry.swift — les outils, et la validation de leurs arguments.
// SPDX-License-Identifier: MIT
//
// LA DISTINCTION QUI STRUCTURE TOUT LE FICHIER : deux niveaux d'erreur.
//
//   · « ta requête est malformée » — outil inconnu, argument du mauvais type,
//     champ requis absent, borne dépassée, curseur d'une autre requête. C'est
//     une erreur JSON-RPC `-32602`, avec `data.reason`. Le client la voit ;
//     le modèle, souvent, non.
//   · « ta requête était bien formée, et voici pourquoi elle ne donne rien » —
//     page inexistante, volume démonté, base d'une autre version. C'est un
//     `CallToolResult{isError: true}` avec un bloc texte, et JAMAIS une erreur
//     JSON-RPC. La spec est explicite là-dessus, et la raison est pratique :
//     c'est cette forme-là que le modèle LIT et sait exploiter pour corriger
//     son appel suivant.
//
// VALIDATION MINIMALE, ET ASSUMÉE. On ne réimplémente pas JSON Schema 2020-12 —
// ce serait une dépendance déguisée. On vérifie ce qui protège réellement :
// le type, `required`, `additionalProperties: false`, `enum`, les bornes
// numériques et de longueur, et le type des éléments d'un tableau. Un schéma
// qui emploierait `oneOf`, `$ref` ou `pattern` passerait sans être vérifié :
// aucun des cinq outils du palier 4 n'en a besoin, et l'omission est ici,
// écrite, plutôt que découverte.
//
// Les valeurs par DÉFAUT du schéma sont appliquées avant l'appel : un outil
// reçoit toujours un dictionnaire complet, et sa lecture des arguments n'a pas
// à répéter les défauts que le schéma annonce déjà au modèle.

import Foundation

// MARK: - Le protocole

public protocol MCPTool {
    /// Nom appelable. Convention du projet : `fouine_<verbe>`.
    var name: String { get }
    /// Titre lisible (`BaseMetadata.title` de la spec).
    var title: String { get }
    var description: String { get }
    /// JSON Schema 2020-12, `type: "object"`, `additionalProperties: false`.
    var inputSchema: [String: Any] { get }
    var outputSchema: [String: Any] { get }

    /// Les `ToolAnnotations` de la spec : ce que le client peut dire à
    /// l'utilisateur AVANT d'appeler. Un client qui ne voit pas
    /// `readOnlyHint: true` doit supposer le pire et demander confirmation à
    /// chaque appel — sur un serveur qui ne peut rien casser, c'est une
    /// friction pour rien (CM-10).
    ///
    /// Le défaut ne porte que le titre : ces indices sont des PROMESSES, et un
    /// outil qui n'en fait aucune est mieux servi par le silence, qui vaut les
    /// valeurs conservatrices de la spec.
    var annotations: [String: Any] { get }

    /// Les arguments sont DÉJÀ validés et complétés par les défauts.
    /// Une erreur MÉTIER se rend par `ToolResult.failure`, pas par un `throw` :
    /// ce qui remonte ici en `throw` devient une `-32603`.
    func call(arguments: [String: Any]) throws -> ToolResult
}

extension MCPTool {

    public var annotations: [String: Any] { ["title": title] }

    /// L'entrée de `tools/list`.
    public var descriptor: [String: Any] {
        ["name": name, "title": title, "description": description,
         "inputSchema": inputSchema, "outputSchema": outputSchema,
         "annotations": annotations]
    }
}

public enum ToolAnnotations {

    /// Les annotations d'un outil qui LIT, et ne fait que cela.
    ///
    /// Les quatre indices disent la même chose sous quatre angles, et chacun
    /// sert un client différent : `readOnlyHint` autorise l'appel sans
    /// confirmation, `destructiveHint` ne veut rien dire sans lui mais se pose
    /// par symétrie, `idempotentHint` autorise un nouvel essai après une
    /// coupure, et `openWorldHint: false` dit que le domaine est CLOS —
    /// l'index local de l'utilisateur, pas le web.
    public static func readOnly(title: String) -> [String: Any] {
        ["title": title, "readOnlyHint": true, "destructiveHint": false,
         "idempotentHint": true, "openWorldHint": false]
    }
}

// MARK: - Le registre

public final class ToolRegistry {
    private let tools: [String: any MCPTool]
    private let order: [String]

    public init(_ tools: [any MCPTool]) {
        var byName: [String: any MCPTool] = [:]
        for tool in tools { byName[tool.name] = tool }
        self.tools = byName
        self.order = tools.map(\.name)
    }

    public var names: [String] { order }

    public func descriptors() -> [[String: Any]] {
        order.compactMap { tools[$0]?.descriptor }
    }

    public func tool(named name: String) -> (any MCPTool)? { tools[name] }

    /// Valide puis exécute. `throws JSONRPCError` uniquement pour le premier
    /// niveau d'erreur décrit en tête de fichier.
    public func call(name: String, arguments: [String: Any]) throws -> ToolResult {
        guard let tool = tools[name] else {
            throw JSONRPCError.invalidParams(
                "unknown tool \"\(name)\" — this server exposes: "
                + order.joined(separator: ", "))
        }
        let checked = try SchemaCheck.validate(arguments, against: tool.inputSchema,
                                               toolName: name)
        do { return try tool.call(arguments: checked) }
        catch let error as JSONRPCError { throw error }
        catch { throw JSONRPCError.internalError(String(describing: error)) }
    }
}

// MARK: - Validation

public enum SchemaCheck {

    /// Rend les arguments COMPLÉTÉS par les défauts du schéma.
    public static func validate(_ arguments: [String: Any],
                                against schema: [String: Any],
                                toolName: String) throws -> [String: Any] {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = schema["required"] as? [String] ?? []

        if (schema["additionalProperties"] as? Bool) == false {
            for key in arguments.keys where properties[key] == nil {
                throw JSONRPCError.invalidParams(
                    "\(toolName): unknown argument \"\(key)\" — accepted: "
                    + (properties.keys.sorted().joined(separator: ", ").isEmpty
                       ? "(none)" : properties.keys.sorted().joined(separator: ", ")))
            }
        }
        for key in required where arguments[key] == nil || arguments[key] is NSNull {
            throw JSONRPCError.invalidParams("\(toolName): missing required argument \"\(key)\"")
        }

        var out: [String: Any] = [:]
        for (key, rawSpec) in properties {
            guard let spec = rawSpec as? [String: Any] else { continue }
            if let value = arguments[key], !(value is NSNull) {
                try check(value, against: spec, path: "\(toolName).\(key)")
                out[key] = value
            } else if let fallback = spec["default"] {
                out[key] = fallback
            }
        }
        return out
    }

    private static func check(_ value: Any, against spec: [String: Any],
                              path: String) throws {
        if let allowed = spec["enum"] as? [Any] {
            let matches = allowed.contains { same($0, value) }
            guard matches else {
                // SANS DEUX-POINTS après le chemin (PM-08) : la raison est
                // désormais recopiée dans `message`, derrière « Invalid
                // params: », et « Invalid params: fouine_search.mode: must
                // be… » se lisait comme une phrase cassée.
                throw JSONRPCError.invalidParams(
                    "\(path) must be one of \(allowed.map { "\($0)" }.joined(separator: ", "))")
            }
            return
        }
        guard let type = typeName(spec["type"]) else { return }
        switch type {
        case "string":
            guard let text = value as? String else { throw wrongType(path, "a string") }
            if let min = spec["minLength"] as? Int, text.count < min {
                throw JSONRPCError.invalidParams("\(path): at least \(min) character(s)")
            }
            if let max = spec["maxLength"] as? Int, text.count > max {
                throw JSONRPCError.invalidParams("\(path): at most \(max) character(s)")
            }
        case "integer":
            guard let number = value as? NSNumber, !isBoolean(number),
                  number == NSNumber(value: number.intValue)
            else { throw wrongType(path, "an integer") }
            try checkBounds(Double(number.intValue), spec: spec, path: path)
        case "number":
            guard let number = value as? NSNumber, !isBoolean(number)
            else { throw wrongType(path, "a number") }
            try checkBounds(number.doubleValue, spec: spec, path: path)
        case "boolean":
            guard let number = value as? NSNumber, isBoolean(number)
            else { throw wrongType(path, "a boolean") }
        case "array":
            guard let items = value as? [Any] else { throw wrongType(path, "an array") }
            if let min = spec["minItems"] as? Int, items.count < min {
                throw JSONRPCError.invalidParams("\(path): at least \(min) item(s)")
            }
            if let max = spec["maxItems"] as? Int, items.count > max {
                throw JSONRPCError.invalidParams("\(path): at most \(max) item(s)")
            }
            if let itemSpec = spec["items"] as? [String: Any] {
                for (offset, item) in items.enumerated() {
                    try check(item, against: itemSpec, path: "\(path)[\(offset)]")
                }
            }
        case "object":
            guard value is [String: Any] else { throw wrongType(path, "an object") }
        default:
            return
        }
    }

    private static func checkBounds(_ value: Double, spec: [String: Any],
                                    path: String) throws {
        if let min = (spec["minimum"] as? NSNumber)?.doubleValue, value < min {
            throw JSONRPCError.invalidParams("\(path): minimum is \(trim(min))")
        }
        if let max = (spec["maximum"] as? NSNumber)?.doubleValue, value > max {
            throw JSONRPCError.invalidParams("\(path): maximum is \(trim(max))")
        }
    }

    /// Le `type` d'un schéma peut être une chaîne ou un tableau
    /// (`["string","null"]`) : dans le second cas on ne vérifie rien, faute de
    /// pouvoir le faire sans réimplémenter l'union.
    private static func typeName(_ raw: Any?) -> String? { raw as? String }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func wrongType(_ path: String, _ expected: String) -> JSONRPCError {
        .invalidParams("\(path): expected \(expected)")
    }

    private static func same(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = a as? NSNumber, let y = b as? NSNumber { return x == y }
        return false
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value)) : String(value)
    }
}
