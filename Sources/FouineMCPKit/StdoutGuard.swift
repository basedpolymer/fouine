// StdoutGuard.swift — six lignes contre une classe entière de bogues.
// SPDX-License-Identifier: MIT
//
// « The server MUST NOT write anything to its stdout that is not a valid MCP
//   message. » C'est le piège n°1 du transport stdio, et en Swift il est
//   particulièrement traître : un seul `print()` oublié — dans FouineCore, dans
//   une dépendance, dans un `debugPrint` de mise au point resté derrière —
//   casse le protocole pour toute la session, et le client rend un message
//   d'erreur qui ne nomme jamais le coupable.
//
// LE REMÈDE N'EST PAS LA DISCIPLINE. On ne peut pas relire tout FouineCore à
// chaque version pour vérifier qu'aucun `print` n'y est entré. On rend donc la
// faute INOFFENSIVE : au démarrage, on duplique le descripteur 1 dans un
// descripteur privé, puis on pointe le 1 sur `/dev/null`. Le protocole écrit
// sur la copie ; tout le reste du programme écrit dans le vide.
//
// Ce que ce garde-fou NE FAIT PAS : rediriger `stderr`. C'est exactement
// l'inverse qu'on veut — la spec recommande `stderr` pour le journal, et Claude
// Desktop l'archive dans `~/Library/Logs/Claude/mcp-server-<nom>.log`.

import Foundation

/// Met `stdout` à l'abri et rend le descripteur sur lequel écrire les messages.
///
/// Cycle de vie : `install()` au tout début de la commande, `restore()` à la
/// fin — ce dernier n'est indispensable qu'en TEST, où le processus survit à la
/// session et où XCTest a encore des choses à imprimer.
public final class StdoutGuard {

    /// La copie privée du descripteur d'origine : c'est LUI le canal MCP.
    public let output: FileHandle

    private let protectedDescriptor: Int32
    private let savedDescriptor: Int32
    private var restored = false

    private init(output: FileHandle, protectedDescriptor: Int32, savedDescriptor: Int32) {
        self.output = output
        self.protectedDescriptor = protectedDescriptor
        self.savedDescriptor = savedDescriptor
    }

    public enum Failure: Error, CustomStringConvertible {
        case cannotDuplicate(String)
        case cannotOpenNull(String)

        public var description: String {
            switch self {
            case .cannotDuplicate(let e): return "cannot duplicate stdout: \(e)"
            case .cannotOpenNull(let e): return "cannot open /dev/null: \(e)"
            }
        }
    }

    /// - Parameter descriptor: celui qu'on protège. `STDOUT_FILENO` en
    ///   production ; les tests passent le même après l'avoir eux-mêmes fait
    ///   pointer sur un tube, ce qui leur permet de lire ce qui SORT vraiment.
    public static func install(protecting descriptor: Int32 = STDOUT_FILENO,
                               nullPath: String = "/dev/null") throws -> StdoutGuard {
        let saved = dup(descriptor)
        guard saved >= 0 else {
            throw Failure.cannotDuplicate(String(cString: strerror(errno)))
        }
        let null = open(nullPath, O_WRONLY)
        guard null >= 0 else {
            close(saved)
            throw Failure.cannotOpenNull(String(cString: strerror(errno)))
        }
        // Après ce `dup2`, tout `print` du programme part dans /dev/null.
        _ = dup2(null, descriptor)
        close(null)
        return StdoutGuard(
            output: FileHandle(fileDescriptor: saved, closeOnDealloc: false),
            protectedDescriptor: descriptor,
            savedDescriptor: saved)
    }

    /// Remet le descripteur protégé à sa destination d'origine. Idempotent.
    public func restore() {
        guard !restored else { return }
        restored = true
        _ = dup2(savedDescriptor, protectedDescriptor)
        close(savedDescriptor)
    }
}
