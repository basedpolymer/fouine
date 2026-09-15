// RootProbe.swift — test de lisibilité EFFECTIVE d'une racine (SPEC §5.2, §7.1).
// Propriété : A-Core.
//
// « Ouvrir et lire réellement un fichier de la racine. ~/Documents est protégé par
//   TCC, ~/Livres ne l'est pas : sans ce test, une racine s'indexe et l'autre reste
//   vide sans le moindre message. » — piège n°1.
//
// Un `FileManager.fileExists` ne détecte RIEN : c'est précisément le mode d'échec
// que l'on cherche (§4.3).
//
// LE MOTIF EST UNE DONNÉE, PAS UNE PHRASE (palier 3.5, audit U1). `FouineError`
// est un contrat gelé (§4.2) : `rootUnreadable` porte un `reason: String` qu'on
// ne peut pas remplacer par un cas typé sans casser les `switch` exhaustifs de
// FouineOCR et de la CLI. Ce champ porte donc, comme `fouine-lock-busy` avant
// lui, un ENREGISTREMENT sans langue :
//
//     fouine-root-unreadable 1 reason=permission-denied
//     fouine-root-unreadable 1 reason=missing
//     fouine-root-unreadable 1 reason=no-readable-file
//     fouine-root-unreadable 1 reason=system detail=<message du système>
//
// `detail=` est TOUJOURS le dernier champ : ce qui suit court jusqu'au bout de
// la ligne, espaces compris — un message système découpé aux blancs serait
// tronqué. `RootProbe.reason(_:)` le relit ; les couches d'affichage en font
// une phrase, ANGLAISE pour la CLI, l'agent et `docs.err` (`IndexText`), dans
// la langue de l'utilisateur pour l'application (`ErrorText`). Un motif qu'on
// ne sait pas relire — celui d'un binaire plus ancien, en français — devient
// `.system`, c'est-à-dire recopié tel quel : une base existante reste lisible.

import Foundation

public enum RootProbe {

    /// Pourquoi une racine ne se lit pas, sous forme de DONNÉES.
    public enum Reason: Sendable, Equatable {
        /// EPERM / EACCES — le SEUL cas où le geste TCC a un sens.
        case permissionDenied
        /// Dossier déplacé, renommé ou supprimé. Envoyer l'utilisateur cocher
        /// une case de confidentialité serait trompeur (recette tranche A,
        /// observation 5 ; le §7.1 réserve le geste au refus).
        case missing
        /// Des fichiers sous la racine, mais aucun lisible.
        case noReadableFile
        /// Tout le reste : un message du système, qui n'a pas de langue à nous.
        case system(String)

        /// L'enregistrement sans langue écrit dans `FouineError.rootUnreadable`.
        public var token: String {
            let head = "\(RootProbe.reasonToken) "
                + "\(RootProbe.reasonFormatVersion) reason="
            switch self {
            case .permissionDenied:   return head + "permission-denied"
            case .missing:            return head + "missing"
            case .noReadableFile:     return head + "no-readable-file"
            case .system(let detail): return head + "system detail=" + detail
            }
        }

        /// La phrase ANGLAISE, celle que lisent la CLI, l'agent et `docs.err`.
        /// L'application, elle, refait la sienne depuis le cas (`ErrorText`).
        public var english: String {
            switch self {
            case .permissionDenied:
                // « file permissions » et non « POSIX permissions » : le motif
                // finit dans `docs.err` et sous les yeux d'un utilisateur, où
                // POSIX ne veut rien dire de plus que « du fichier ». La
                // version française de l'app suit (audit B1-25).
                return "read denied (privacy settings or file permissions)"
            case .missing:
                return "folder not found (moved, renamed or deleted)"
            case .noReadableFile:
                return "no readable file under this root"
            case .system(let detail):
                return detail
            }
        }
    }

    static let reasonToken = "fouine-root-unreadable"
    static let reasonFormatVersion = "1"

    /// Relit le motif d'un `rootUnreadable`. Un champ qu'on ne reconnaît pas —
    /// une phrase écrite par un binaire plus ancien — devient `.system` : on ne
    /// perd jamais ce qu'on ne sait pas relire.
    public static func reason(_ raw: String?) -> Reason? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.hasPrefix(reasonToken) else { return .system(raw) }
        if let detail = raw.range(of: " detail=") {
            return .system(String(raw[detail.upperBound...]))
        }
        for token in raw.split(separator: " ") where token.hasPrefix("reason=") {
            switch token.dropFirst("reason=".count) {
            case "permission-denied": return .permissionDenied
            case "missing":           return .missing
            case "no-readable-file":  return .noReadableFile
            default:                  return .system(raw)
            }
        }
        return .system(raw)
    }

    /// Geste exact à donner à l'utilisateur en cas de refus TCC (SPEC §7.1).
    ///
    /// Phrase ANGLAISE, comme tout ce que le cœur écrit ; l'application compose
    /// la sienne depuis le catalogue (`TCCText.guidance`).
    public static let tccGuidance =
        "System Settings ▸ Privacy & Security ▸ Files and Folders ▸ Fouine ▸ "
        + "Documents Folder (or “Full Disk Access” if the background agent must "
        + "run without the app)."

    /// Vrai si ce motif d'échec appelle le geste TCC (`tccGuidance`).
    public static func isPermissionDenial(_ raw: String?) -> Bool {
        reason(raw) == .permissionDenied
    }

    /// Ouvre et LIT réellement un fichier régulier trouvé sous `url`.
    /// Parcours superficiel (largeur d'abord, borné) jusqu'au premier fichier
    /// régulier ; une racine vide est un succès.
    /// - Throws: `FouineError.rootUnreadable` si le dossier ou tous ses fichiers
    ///   refusent la lecture, ou si la racine a disparu.
    public static func probe(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FouineError.rootUnreadable(
                path: url.path, reason: Reason.missing.token)
        }
        guard isDir.boolValue else {
            // Une « racine » qui est un fichier : on la lit directement.
            try readOneByte(url)
            return
        }

        var queue: [URL] = [url]
        var visitedDirs = 0
        var lastFileError: Reason?
        var sawFile = false

        while !queue.isEmpty, visitedDirs < 64 {
            let dir = queue.removeFirst()
            visitedDirs += 1
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])
            } catch {
                if dir == url {
                    throw FouineError.rootUnreadable(
                        path: url.path, reason: classify(error).token)
                }
                continue
            }
            var subdirs: [URL] = []
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
                if values?.isRegularFile == true {
                    sawFile = true
                    do {
                        try readOneByte(entry)
                        return  // lecture effective réussie
                    } catch {
                        lastFileError = classify(error)
                    }
                } else {
                    subdirs.append(entry)
                }
            }
            queue.append(contentsOf: subdirs)
        }

        if sawFile {
            throw FouineError.rootUnreadable(
                path: url.path,
                reason: (lastFileError ?? .noReadableFile).token)
        }
        // Racine vide (ou sans fichier régulier atteignable) : succès (§ mission A-Core).
    }

    /// Ouvre le fichier et en lit un octet. Un fichier vide est un succès :
    /// c'est l'OUVERTURE qui teste l'autorisation.
    private static func readOneByte(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = try handle.read(upToCount: 1)
    }

    private static func classify(_ error: Error) -> Reason {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain {
            let code = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? ns.code
            if code == EPERM || code == EACCES || ns.code == NSFileReadNoPermissionError {
                // Le geste (tccGuidance) n'est PAS embarqué ici : c'est la
                // couche d'affichage qui l'ajoute, et seulement pour ce motif
                // (CLI.describe, doctor — observation 5 de la recette).
                return .permissionDenied
            }
        }
        return .system(ns.localizedDescription)
    }
}
