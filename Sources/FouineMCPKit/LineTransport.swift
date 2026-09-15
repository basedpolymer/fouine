// LineTransport.swift — le cadrage stdio de MCP : une ligne = un message.
// SPDX-License-Identifier: MIT
//
// « Messages are delimited by newlines, and MUST NOT contain embedded
//   newlines » · « There is no header layer »
//   — spécification MCP, transport stdio (recontrôlé le 03/09/2026 sur la
//     révision 2026-07-28). Il n'y a donc NI `Content-Length` NI trame binaire :
//     c'est la partie la plus simple du protocole, et c'est aussi celle où l'on
//     se trompe.
//
// TROIS PIÈGES, et ce fichier n'existe que pour eux.
//
//  1. `readLine()` est inutilisable. Il lit sur `stdin` bufferisé par la libc,
//     ne dit rien de l'EOF autrement que par `nil`, et surtout il DÉCODE en
//     String : une ligne de 2 Mio y passe deux fois en mémoire, et un octet
//     invalide y devient un caractère de remplacement au lieu d'une erreur
//     d'analyse. On lit des OCTETS, on découpe sur `\n`, on décode une fois.
//
//  2. « Servers SHOULD exit promptly when their standard input is closed. »
//     `read()` qui rend 0 est le seul signal d'EOF ; `FileHandle.readDataToEnd`
//     bloquerait jusqu'à la fin des temps. La boucle rend `nil` et l'appelant
//     sort — code 0, pas un timeout de client.
//
//  3. Une ligne démesurée ne doit pas faire exploser la mémoire du serveur.
//     Le plafond est haut (16 Mio par défaut : une ligne de 2 Mio doit passer
//     confortablement, c'est ce que teste `FramingTests`), mais il existe, et
//     son dépassement est une erreur d'analyse — pas un `fatalError`.

import Foundation

/// Lecture et écriture ligne à ligne sur une paire de descripteurs.
///
/// Volontairement synchrone et mono-fil : un serveur stdio traite une requête
/// à la fois, la spec ne demande rien de plus, et cela supprime toute la classe
/// de bogues d'entrelacement des réponses.
public final class LineTransport {

    /// Ce que `nextLine()` a trouvé.
    public enum Line {
        /// Une ligne complète, saut de ligne exclu.
        case data(Data)
        /// La ligne dépassait `maxLineBytes` ; elle a été consommée et jetée.
        case oversized(bytes: Int)
        /// L'entrée est fermée : l'appelant doit sortir promptement.
        case endOfInput
    }

    private let input: Int32
    private let output: Int32
    private let maxLineBytes: Int
    private var pending = Data()
    private var atEnd = false

    /// - Parameters:
    ///   - input: descripteur de lecture (typiquement `STDIN_FILENO`).
    ///   - output: descripteur d'écriture — sur un vrai serveur, celui que
    ///     `StdoutGuard` a mis à l'abri, jamais `1` directement.
    public init(input: Int32, output: Int32, maxLineBytes: Int = 16 << 20) {
        self.input = input
        self.output = output
        self.maxLineBytes = maxLineBytes
    }

    public convenience init(input: FileHandle, output: FileHandle,
                            maxLineBytes: Int = 16 << 20) {
        self.init(input: input.fileDescriptor, output: output.fileDescriptor,
                  maxLineBytes: maxLineBytes)
    }

    public func nextLine() -> Line {
        while true {
            if let index = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<index])
                pending.removeSubrange(pending.startIndex...index)
                if line.count > maxLineBytes { return .oversized(bytes: line.count) }
                return .data(line)
            }
            if atEnd {
                // Dernière ligne sans `\n` final : un `printf` sans `\n`, ou un
                // client qui ferme brutalement. On la traite quand même.
                guard !pending.isEmpty else { return .endOfInput }
                let line = pending
                pending.removeAll()
                if line.count > maxLineBytes { return .oversized(bytes: line.count) }
                return .data(line)
            }
            // Le plafond s'applique AUSSI au tampon en cours d'accumulation :
            // sans cela, une ligne infinie sans `\n` remplirait la mémoire avant
            // d'être jetée.
            if pending.count > maxLineBytes {
                let bytes = pending.count
                pending.removeAll(keepingCapacity: false)
                drainToNewline()
                return .oversized(bytes: bytes)
            }
            guard readChunk() else { atEnd = true; continue }
        }
    }

    /// Écrit un message, saut de ligne compris. Les écritures partielles
    /// (`write()` sur un tube presque plein) sont reprises : sans cette boucle,
    /// une réponse de 40 000 caractères pourrait être tronquée en silence, et le
    /// client verrait un JSON invalide sans que rien ne le signale.
    public func write(_ message: Data) {
        var payload = message
        payload.append(0x0A)
        payload.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(output, pointer, remaining)
                if written > 0 {
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                } else if written < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    return   // tube fermé : le client est parti, la boucle sortira
                }
            }
        }
    }

    // MARK: - Lecture brute

    private static let chunkSize = 64 << 10

    /// `false` = fin de fichier.
    private func readChunk() -> Bool {
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(input, base, Self.chunkSize)
            }
            if count > 0 { pending.append(contentsOf: buffer[0..<count]); return true }
            if count == 0 { return false }
            if errno == EINTR { continue }   // un signal a interrompu la lecture
            return false
        }
    }

    /// Jette tout jusqu'au prochain `\n` après une ligne démesurée : on ne veut
    /// pas analyser la QUEUE d'un message qu'on vient de refuser.
    private func drainToNewline() {
        while !atEnd {
            if let index = pending.firstIndex(of: 0x0A) {
                pending.removeSubrange(pending.startIndex...index)
                return
            }
            pending.removeAll(keepingCapacity: false)
            guard readChunk() else { atEnd = true; return }
        }
    }
}
