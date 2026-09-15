// AgentLog.swift — journal de l'agent (SPEC §10). Propriété : A-Pack.
//
// « Journaux ~/Library/Logs/Fouine/fouine.log (rotation à 10 Mo) »
//
// Un agent launchd n'a ni terminal ni interface : ce fichier est le seul endroit
// où un diagnostic peut exister. Deux conséquences d'implémentation :
//
//  1. `captureStandardStreams()` redirige fd 1 et 2 vers le journal, pour que les
//     `print` d'OCRRun (progression, garde-fou thermique) y atterrissent aussi.
//     Sans cela, tout le travail OCR de l'agent serait muet.
//  2. Le descripteur est ouvert en O_APPEND : le journal reste cohérent quand la
//     ligne horodatée et la sortie standard s'y mêlent.
//
// AUDIT S4 (01/09/2026), deux corrections.
//
//   · DROITS 0o600, et non 0o644. Ce fichier contient l'ARBORESCENCE
//     DOCUMENTAIRE de l'utilisateur : chaque racine avec son chemin absolu
//     (« racine lisible : Livres — /Users/…/Livres »), chaque page en échec
//     avec le chemin de son document. En 0o644 il était lisible par tout compte
//     de la machine. Le mode est posé à la création ET rétabli par `fchmod` sur
//     un journal existant : une installation antérieure à ce palier a déjà un
//     fichier 0o644 sur le disque, que le `mode` d'`open()` ne toucherait pas.
//
//   · ROTATION RÉELLEMENT BORNÉE. Elle n'était testée que dans `emit`, jamais
//     pour ce qui arrive par `dup2` : les `print` d'`OCRRun` (une ligne par
//     page, plus le garde-fou thermique) pouvaient donc faire croître le
//     journal sans aucune limite, exactement dans le régime où il grossit le
//     plus. `enforceRotation()` est appelé par l'agent au tic de
//     `agent.pollSeconds` — la taille est alors vérifiée quelle que soit la
//     provenance des octets.

import Foundation

final class AgentLog: @unchecked Sendable {

    /// Rotation à 10 Mo (§10). Un seul fichier de secours, `fouine.log.1`.
    static let maxBytes: Int64 = 10 << 20

    private let url: URL
    private let mutex = NSLock()
    private let stamp: DateFormatter
    private let pid: Int32
    private var fd: Int32 = -1
    private var capturing = false

    init(url: URL) {
        self.url = url
        self.pid = ProcessInfo.processInfo.processIdentifier
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        self.stamp = f
    }

    deinit { if fd >= 0 { close(fd) } }

    var path: String { url.path }

    // MARK: - Écriture

    func info(_ message: String) { emit("info ", message) }
    func warn(_ message: String) { emit("warn ", message) }
    func error(_ message: String) { emit("error", message) }

    private func emit(_ level: String, _ message: String) {
        mutex.lock()
        defer { mutex.unlock() }
        let line = "\(stamp.string(from: Date())) fouine-agent[\(pid)] "
            + "\(level) \(message)\n"
        ensureOpen()
        rotateIfNeeded()
        guard fd >= 0 else {
            FileHandle.standardError.write(Data(line.utf8))
            return
        }
        rawWrite(line)
    }

    /// Redirige la sortie et l'erreur standard vers le journal : c'est ainsi que
    /// la progression d'`OCRRun` (qui écrit par `print`) devient consultable.
    func captureStandardStreams() {
        mutex.lock()
        defer { mutex.unlock() }
        ensureOpen()
        guard fd >= 0 else { return }
        setvbuf(stdout, nil, _IOLBF, 0)   // ligne à ligne : l'ordre est lisible
        setvbuf(stderr, nil, _IONBF, 0)
        dup2(fd, 1)
        dup2(fd, 2)
        capturing = true
    }

    // MARK: - Fichier

    /// Vérifie la taille du journal, quelle que soit la provenance des octets.
    /// Appelé par l'agent au tic de `agent.pollSeconds` (audit S4).
    func enforceRotation() {
        mutex.lock()
        defer { mutex.unlock() }
        ensureOpen()
        rotateIfNeeded()
    }

    private var directoryErrorReported = false

    private func ensureOpen() {
        guard fd < 0 else { return }
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            if !directoryErrorReported {
                directoryErrorReported = true
                let msg = "\(stamp.string(from: Date())) fouine-agent[\(pid)] "
                    + "error cannot create log directory \(dir.path): \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
            return
        }
        // 0o600 : le journal porte l'arborescence documentaire (audit S4).
        fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        // Le `mode` d'`open()` ne s'applique QU'À LA CRÉATION : un journal
        // hérité d'une version antérieure resterait en 0o644 pour toujours.
        if fd >= 0 {
            _ = fchmod(fd, 0o600)
        } else if !directoryErrorReported {
            directoryErrorReported = true
            let msg = "\(stamp.string(from: Date())) fouine-agent[\(pid)] "
                + "error cannot open log file \(url.path): \(String(cString: strerror(errno)))\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
    }

    private func rotateIfNeeded() {
        guard fd >= 0 else { return }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= Self.maxBytes else { return }
        close(fd)
        fd = -1
        _ = rename(url.path, url.path + ".1")   // remplace le précédent .1
        ensureOpen()
        if capturing, fd >= 0 { dup2(fd, 1); dup2(fd, 2) }
    }

    private func rawWrite(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                write(fd, buffer.baseAddress!.advanced(by: offset),
                      bytes.count - offset)
            }
            if written <= 0 { return }
            offset += written
        }
    }
}
