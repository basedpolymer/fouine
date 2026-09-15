// FileGuard.swift — plafond `limits.maxFileBytes` (SPEC §4.2 : « 2 Gio : au-delà
// -> .skipped »). Propriété : A-Ingest.
//
// Aucun extracteur n'ouvre un fichier sans passer par ici, et AUCUN n'écrit dans
// le fichier source : le corpus est en lecture seule stricte (§3).
//
// Un `.rtfd` n'est PAS un fichier : c'est un DOSSIER que le crawler indexe comme
// un document (FouineCrawler.swift). Son `st_size` vaut 128 octets quel que soit
// son contenu — mesuré : 128 pour un paquet de 5 Mio — donc le plafond ne s'y
// appliquait pas du tout (A11.8). La taille d'un paquet est la SOMME de son
// contenu.

import Foundation
import FouineCore

enum FileGuard {
    /// Taille du document. Pour un paquet-dossier (`.rtfd`), somme du contenu ;
    /// l'énumération s'arrête dès que `stopAbove` est franchi — inutile de
    /// parcourir un paquet de dix mille éléments pour savoir qu'il est trop gros.
    static func size(of url: URL, stopAbove: Int64 = .max) throws -> Int64 {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw FouineError.extraction(
                "unreadable file: \(String(cString: strerror(errno))) (\(url.path))")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return Int64(st.st_size) }
        return packageSize(of: url, stopAbove: stopAbove)
    }

    /// Somme des tailles des fichiers d'un paquet-dossier. Les liens symboliques
    /// ne sont pas suivis (`FileManager.enumerator` ne descend pas dedans) : rien
    /// ne fait sortir le compte du paquet.
    static func packageSize(of url: URL, stopAbove: Int64) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, _ in true })
        else { return total }
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let bytes = values.fileSize
            else { continue }
            total += Int64(bytes)
            if total > stopAbove { return total }
        }
        return total
    }

    /// Lève `FouineError.fileTooLarge` au-delà de `limits.maxFileBytes`.
    @discardableResult
    static func check(_ url: URL, _ limits: ExtractLimits) throws -> Int64 {
        let cap = Int64(limits.maxFileBytes)
        let bytes = try size(of: url, stopAbove: cap)
        if bytes > cap {
            throw FouineError.fileTooLarge(bytes: bytes)
        }
        return bytes
    }
}
