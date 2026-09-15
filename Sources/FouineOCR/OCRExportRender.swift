// OCRExportRender.swift — rendus PNG pour `fouine ocr export --render-png`.
// Propriété : A-OCR. Annexe B (canal d'échange avec un poste GPU).
//
// Décision de vague 0 : le dossier est FOURNI par l'utilisateur, il est jetable, et
// Fouine n'y purge rien automatiquement. Un outil qui efface un dossier que
// l'utilisateur a nommé est un outil dangereux ; ces PNG servent un aller-retour
// manuel, l'utilisateur les supprime quand il a fini.
//
// Mêmes règles de rendu que la pompe : 150 dpi, niveaux de gris, plafond ~4 Mpx.
// Un producteur externe qui recevrait des images plus grandes n'y gagnerait rien
// (§2.7, point 3 : sur-échantillonner n'ajoute pas d'information) et le transfert
// des ~17 Go mesurés (annexe B) en serait alourdi d'autant.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FouineCore

public enum OCRExportRender {

    /// Écrit `<doc_id>_<page>.png` dans `dir` pour chaque page fournie.
    /// Une page qui ne se rend pas n'interrompt pas l'export (piège n°13) : elle
    /// est signalée et l'export continue. Rend le nombre de fichiers écrits.
    ///
    /// `store` figure dans la signature imposée et n'est PAS lu : l'appelant a déjà
    /// résolu les chemins absolus (`pendingOCRPages` + `VolumeResolver`), et un
    /// export ne doit rien écrire en base. Le paramètre reste pour que l'ajout
    /// éventuel d'un journal d'export ne change pas le contrat.
    @discardableResult
    public static func renderPNGs(store: GRDBStore,
                                  pages: [(docID: Int64, page: Int, path: String)],
                                  dpi: Double, to dir: URL) throws -> Int {
        try renderPNGs(store: store, pages: pages, dpi: dpi, to: dir,
                       renderer: FouinePageRenderer(), log: { print($0) })
    }

    @discardableResult
    static func renderPNGs(store: GRDBStore,
                           pages: [(docID: Int64, page: Int, path: String)],
                           dpi: Double, to dir: URL,
                           renderer: any PageRenderer,
                           log: (String) -> Void) throws -> Int {
        do {
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
        } catch {
            throw FouineError.ocr(
                "cannot create the render folder \(dir.path): "
                + (error as NSError).localizedDescription)
        }

        var written = 0
        for item in pages {
            do {
                try autoreleasepool {
                    let image = try renderer.render(url: URL(fileURLWithPath: item.path),
                                                    page: item.page, dpi: dpi)
                    let target = dir.appendingPathComponent(
                        "\(item.docID)_\(item.page).png")
                    try writePNG(image, to: target)
                }
                written += 1
            } catch {
                log("rendering failed (doc \(item.docID), page \(item.page)): "
                    + OCRRun.describe(error))
            }
        }
        return written
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FouineError.ocr("cannot open the PNG for writing: \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FouineError.ocr("cannot write the PNG: \(url.path)")
        }
    }
}
