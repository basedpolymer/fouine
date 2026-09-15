// AssistantRequest.swift — la demande à coller dans un assistant IA pour
// qu'il installe le serveur MCP de Fouine.
// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available
//
// L'écran d'accueil dit « demandez à votre assistant d'installer le MCP de
// Fouine ». Un assistant qui reçoit cette phrase tape `fouine mcp install` et
// tombe sur « command not found » : la commande n'est sur le PATH qu'après
// Réglages ▸ Avancé ▸ « Installer l'outil en ligne de commande… », et rien ne
// lui dit qu'elle vit dans `Fouine.app/Contents/Helpers/fouine`. Le dépôt
// étant privé, il ne trouvera pas non plus la documentation en ligne.
//
// D'où ce texte, copié d'un bouton : il porte le CHEMIN RÉEL du binaire
// embarqué, la commande, ce qu'elle fait et ses options — tout ce qu'il faut
// pour réussir sans rien chercher. Il s'adresse à l'assistant, pas à
// l'utilisateur : c'est la seule chaîne de l'app qui montre un chemin sans
// qu'on le demande, et elle ne s'affiche jamais à l'écran.

import AppKit
import Foundation

enum AssistantRequest {

    /// Le chemin du binaire quand l'app n'est pas un bundle (`swift run`) :
    /// celui d'une installation standard, qui reste le bon conseil.
    static let standardCLIPath = "/Applications/Fouine.app/Contents/Helpers/fouine"

    /// La page du site écrite pour l'assistant : installer Fouine, brancher
    /// le MCP, configurer un client que `mcp install` ne connaît pas.
    static let guideURL = "https://basedpolymer.eu/fouine/mcp"

    /// La demande complète, pour le presse-papiers. `cli` est le binaire
    /// embarqué (`AppPaths.bundledCLI()`), `nil` hors bundle.
    static func text(cli: URL?) -> String {
        let command = shellQuoted(cli?.path ?? standardCLIPath) + " mcp install"
        // Une seule ligne de source, `\n` explicites : la clé du catalogue est
        // exactement ce texte, sans dépendre de la mise en forme d'un littéral
        // multiligne.
        return String(localized: "Please install the Fouine MCP server so you can search my documents. Run this command (it needs no administrator password):\n\n\(command)\n\nIt configures Claude Desktop, Claude Code, Cursor, Codex and Antigravity in one go and skips the clients that are not installed; other servers and settings are kept. Add `--client <name>` to configure a single client (claude-desktop, claude-code, cursor, codex, antigravity), `--dry-run` to preview what would be written, and `--folders <labels>` to serve only some of my folders. If your client is not in that list, `--print` gives the server entry to add to its configuration by hand. Add `--help` for the details.\n\nThe server is read-only: it never changes the index and never hands over my files. Once configured, restart the client so it picks up the server. The full guide, written for assistants: \(guideURL)")
    }

    /// Le chemin entre apostrophes s'il contient autre chose que des
    /// caractères sûrs : un `Fouine.app` posé dans « Mes applications » se
    /// tape sinon en deux mots.
    static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@:"))
        if path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Copie la demande. `clearContents()` d'abord, pour la même raison que
    /// `Citation.copy` : un contenu d'un autre type resterait sinon.
    static func copy(cli: URL? = AppPaths.bundledCLI(),
                     to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text(cli: cli), forType: .string)
    }
}
