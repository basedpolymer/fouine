// VolumeResolver.swift — GELÉ EN VAGUE 0, propriété de l'orchestrateur.
// Résolution volume/chemin partagée par le Store (addRoot, nextOCRBatch) et le
// Crawler (§2.3, §5.2). Les sous-agents l'utilisent, ne l'éditent pas.
//
// Règles mesurées, non négociables (SPEC §2.3) :
//   · l'UUID se lit par URLResourceKey.volumeUUIDStringKey, JAMAIS par diskutil ;
//   · le volume d'un chemin se résout par préfixe de point de montage le plus
//     long parmi les volumes montés, hors /System/Volumes/{Preboot,VM,Update}.

import Foundation

public enum VolumeResolver {
    public struct ResolvedRoot: Sendable {
        public let volUUID: String
        public let volLabel: String
        public let mountPoint: URL
        /// Relatif à la racine du VOLUME, sans « / » initial (ex. "Users/<vous>/Livres").
        public let relPath: String
        public init(volUUID: String, volLabel: String, mountPoint: URL, relPath: String) {
            self.volUUID = volUUID
            self.volLabel = volLabel
            self.mountPoint = mountPoint
            self.relPath = relPath
        }
    }

    static let ignoredMounts: Set<String> = [
        "/System/Volumes/Preboot", "/System/Volumes/VM", "/System/Volumes/Update",
    ]

    public static func mountedVolumes() -> [(uuid: String, label: String, mountPoint: URL)] {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []) else { return [] }
        var out: [(uuid: String, label: String, mountPoint: URL)] = []
        for u in urls {
            if ignoredMounts.contains(u.path) { continue }
            guard let rv = try? u.resourceValues(forKeys: Set(keys)),
                  let uuid = rv.volumeUUIDString else { continue }
            out.append((uuid: uuid, label: rv.volumeName ?? u.path, mountPoint: u))
        }
        return out
    }

    /// Volume contenant `path`, par préfixe de montage le plus long.
    public static func resolve(path: URL) throws -> ResolvedRoot {
        let target = path.standardizedFileURL.resolvingSymlinksInPath().path
        var best: (uuid: String, label: String, mountPoint: URL)?
        var bestLen = -1
        for v in mountedVolumes() {
            let mp = v.mountPoint.path
            let prefix = mp.hasSuffix("/") ? mp : mp + "/"
            if (target == mp || target.hasPrefix(prefix)) && mp.count > bestLen {
                best = v
                bestLen = mp.count
            }
        }
        guard let vol = best else {
            throw FouineError.rootUnreadable(
                path: target, reason: RootProbe.Reason.system(
                    "no mounted volume holds this path").token)
        }
        var rel = String(target.dropFirst(vol.mountPoint.path.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        // NFC À L'ENTRÉE (A3-10) : `roots.rel_path` sert de PRÉFIXE à toutes les
        // requêtes par racine, et un préfixe décomposé ne reconnaît pas un
        // chemin précomposé — ni l'inverse. Voir `RelPath`.
        return ResolvedRoot(volUUID: vol.uuid, volLabel: vol.label,
                            mountPoint: vol.mountPoint,
                            relPath: RelPath.normalized(rel))
    }

    /// Point de montage actuel d'un volume enregistré ; nil si non monté.
    public static func mountPoint(forVolumeUUID uuid: String) -> URL? {
        mountedVolumes().first(where: { $0.uuid == uuid })?.mountPoint
    }

    /// Chemin absolu actuel d'un document (vol_uuid + rel_path relatif au volume).
    public static func absolutePath(volUUID: String, relPath: String) throws -> URL {
        guard let mp = mountPoint(forVolumeUUID: volUUID) else {
            throw FouineError.volumeNotMounted(uuid: volUUID)
        }
        return relPath.isEmpty ? mp : mp.appendingPathComponent(relPath)
    }
}
