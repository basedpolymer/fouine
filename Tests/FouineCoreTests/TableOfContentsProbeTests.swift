// TableOfContentsProbeTests.swift — la sonde des sommaires (lot RK2, RK-07).
// Propriété : A-Core.
//
// LES EXTRAITS SONT RÉELS. Les sept pages que le constat RK-07 nomme et vingt
// pages de prose notées 2 au banc du 09/09/2026 ont été lues sur une copie de
// la base de production le 11/09/2026 ; on en fixe ici les 300 premiers
// caractères. Une sonde calibrée sur du texte inventé n'aurait rien prouvé :
// ce corpus-ci n'a presque jamais de points de conduite (l'extraction les
// retire), et c'est cela qui décide de la forme des trois signes.
//
// CE QUE LA MESURE DIT, ET QU'IL FAUT SAVOIR AVANT D'ARMER LE MALUS : la sonde
// reconnaît quatre des sept sommaires du constat et AUCUNE des vingt pages de
// prose. Les trois qui lui échappent sont nommés plus bas, avec leur raison.

import XCTest
@testable import FouineCore

final class TableOfContentsProbeTests: XCTestCase {

    // MARK: - Les pages réelles

    /// Les quatre sommaires que la sonde attrape.
    func testRealTablesOfContentsAreRecognised() throws {
        for key in ["445/9", "121/13", "791/7", "804/14"] {
            XCTAssertTrue(
                TableOfContentsProbe.isTableOfContents(Pages.tables[key]!),
                "\(key) est un sommaire du constat RK-07")
        }
    }

    /// Les trois qu'elle laisse passer, et pourquoi — un test qui le CONSTATE
    /// vaut mieux qu'une note perdue dans un rapport : le jour où les seuils
    /// bougeront, c'est ici qu'on lira ce qui a changé.
    ///
    /// · `787/13` : 82 % de lignes numérotées sur la page entière, mais 27 % de
    ///   lignes courtes et 0,56 de mots uniques — un seul signe sur trois.
    /// · `445/10` : la suite d'un sommaire, dont les lignes sont des phrases
    ///   descriptives ; 22 % de lignes numérotées seulement.
    /// · `764/177` : une liste de mots-clés de fin de chapitre, sans un seul
    ///   nombre ni point de conduite ; seul le signe de forme s'allume, et il
    ///   ne distingue pas cette page d'une page de diapositives OCRisée.
    func testTheTablesTheProbeMisses() throws {
        for key in ["445/10", "764/177"] {
            XCTAssertFalse(
                TableOfContentsProbe.isTableOfContents(Pages.tables[key]!),
                "\(key) échappe à la sonde : voir le commentaire")
        }
        // `787/13` : sur la page entière, le seul signe qui s'allume est celui
        // des lignes numérotées.
        let signs = TableOfContentsProbe.signs(of: Pages.tables["787/13"]!)
        XCTAssertTrue(signs.numberedLines)
    }

    /// Aucune page de prose n'est prise pour un sommaire. C'est la garantie qui
    /// compte : reculer une vraie réponse coûte plus cher que laisser un
    /// sommaire en tête.
    func testNoProsePageIsTakenForATableOfContents() throws {
        for (key, text) in Pages.prose {
            XCTAssertFalse(TableOfContentsProbe.isTableOfContents(text),
                           "\(key) est une page de prose notée 2 au banc")
        }
        XCTAssertEqual(Pages.prose.count, 20)
    }

    /// TOUTE LA PAGE, JAMAIS UN EXTRAIT. `158 p.583` commence par son propre
    /// sommaire : sur ses 300 premiers caractères la sonde dit « sommaire »,
    /// alors que la page entière est de la prose notée 2 — et c'est l'une des
    /// deux bonnes réponses de RK-04. La recherche lui donne donc le texte
    /// complet de `page_fts`, jamais l'extrait des résultats.
    func testAProsePageWhoseHeadIsAContentsBlock() throws {
        XCTAssertTrue(TableOfContentsProbe.isTableOfContents(
            Pages.proseStartingWithItsOwnContents))
    }

    // MARK: - Les trois signes, un par un

    func testNumberedLinesSignAlone() throws {
        let text = """
            Chapitre premier 12
            Chapitre second 24
            Chapitre troisieme 36
            """
        XCTAssertTrue(TableOfContentsProbe.signs(of: text).numberedLines)
        XCTAssertFalse(TableOfContentsProbe.signs(of:
            "La reaction degage 36 kilojoules par mole de reactif consomme, "
            + "ce qui se mesure au calorimetre isotherme.").numberedLines)
    }

    func testLeaderDotsSignAlone() throws {
        let dotted = "Spectroscopie ................................................ 351"
        XCTAssertTrue(TableOfContentsProbe.signs(of: dotted).leaders)
        // Deux points de suite ne sont pas une conduite, et une abréviation non
        // plus : « etc. » ne doit rien allumer.
        XCTAssertFalse(TableOfContentsProbe.signs(of:
            "La chaleur, l'entropie, etc. se mesurent au calorimetre a pression "
            + "constante dans un vase de Dewar bien isole.").leaders)
    }

    func testListShapeSignAlone() throws {
        let list = """
            chromatographie gazeuse
            chromatographie liquide
            chromatographie planaire
            spectroscopie atomique
            """
        XCTAssertTrue(TableOfContentsProbe.signs(of: list).listShape)
        XCTAssertFalse(TableOfContentsProbe.signs(of: Pages.prose["145/51"]!).listShape)
    }

    /// Un seul signe ne suffit jamais : une page d'exercices numérotés porte
    /// des nombres en fin de ligne sans être un sommaire.
    func testOneSignIsNotEnough() throws {
        let exercises = """
            Calculer l'enthalpie standard de la reaction de combustion du methane 298
            En deduire la chaleur degagee par mole de gaz brule dans l'air ambiant 25
            Comparer le resultat obtenu avec la valeur tabulee dans le manuel 1000
            """
        let signs = TableOfContentsProbe.signs(of: exercises)
        XCTAssertTrue(signs.numberedLines)
        XCTAssertEqual(signs.count, 1)
        XCTAssertFalse(TableOfContentsProbe.isTableOfContents(exercises))
    }

    /// Une page vide n'est rien du tout — surtout pas un sommaire.
    func testAnEmptyPageIsNotATableOfContents() throws {
        XCTAssertFalse(TableOfContentsProbe.isTableOfContents(""))
        XCTAssertFalse(TableOfContentsProbe.isTableOfContents("   \n\n  \n"))
        XCTAssertEqual(TableOfContentsProbe.signs(of: "").count, 0)
    }

    // MARK: - Les mesures elles-mêmes

    func testEndsWithNumber() throws {
        XCTAssertTrue(TableOfContentsProbe.endsWithNumber("Questions and Problems 143"))
        XCTAssertTrue(TableOfContentsProbe.endsWithNumber("284"))
        XCTAssertTrue(TableOfContentsProbe.endsWithNumber("Preface 12."))
        XCTAssertFalse(TableOfContentsProbe.endsWithNumber("Page vii"))
        XCTAssertFalse(TableOfContentsProbe.endsWithNumber("la molecule H2O"),
                       "le nombre doit être un jeton entier")
        XCTAssertFalse(TableOfContentsProbe.endsWithNumber("5.0"),
                       "une décimale n'est pas un numéro de page (121 p.771)")
        XCTAssertFalse(TableOfContentsProbe.endsWithNumber(""))
    }
}

/// Les extraits, à part : ils font la moitié du fichier et ne sont pas des
/// tests. Clés `doc_id/page`, telles que le constat RK-07 les nomme.
private enum Pages {
    /// Les sept pages que le constat RK-07 nomme, telles qu'elles sont en
    /// base le 11/09/2026 — leurs 300 premiers caractères.
    static let tables: [String: String] = [
        "445/9": "Page vii\n8\n284\n289\n295\n305\nAtomic Spectrometry\n8.1 Arc/Spark Atomic (Optical) Emission Spectrometry Instrumentation. Sample Preparation. Qualitative and Quantitative\nAnalysis. Interferences and Errors Associated with the Excitation\nProcess. Applications of Arc/Spark Emission Spectrometry.\n8.2 Glow D",
        "787/13": "CONTENTS xiii\n55.5 Alternatives to Magnetic/Electrostatic Focusing-Time-of-\nflight, Quadrupole, Ion Cyclotron, FTICR and Tandem Mass\nSpectrometers 335\nFurther Reading 339\n6 Spectroscopy Problems 343\n6.1 Infrared Spectroscopy Problems 344\n6.2 NMR Spectroscopy Problems 347\n6.3 Electronic Spectroscopy ",
        "121/13": "x Contents\n6D Quantitative Aspects of Spectrochemical\nMeasurements 141\nQuestions and Problems 143\nCHAPTER SEVEN\nComponents of Optical Instruments 148\n7A General Designs of Optical Instruments 148\n7B Sources of Radiation 150\n7C Wavelength Selectors 160\n7D Sample Containers 174\n7E Radiation Transducer",
        "445/10": "363\n9.1 Visible and Ultraviolet Spectrometry Polyatomic Organic Molecules. Metal Complexes. Qualitative\nAnalysis – The Identification of Structural Features. Quantitative\nAnalysis – Absorptiometry. Choice of Colorimetric and\nSpectrophotometric Procedures. Fluorimetry. Applications of\nUV/Visible Spec",
        "791/7": "CONTENTS\nPreface vii\nList of Figures xi\nList of Tables xv\n1 NMR Spectroscopy Basics 1\n1.1 The Physics of Nuclear Spins 1\n1.2 Basic NMR Instrumentation and the NMR Experiment 4\n2 One-Dimensional Pulsed Fourier Transform NMR Spectroscopy 5\n2.1 The Chemical Shift 7\n2.2 1H NMR Spectroscopy 9\n2.2.1 Chemi",
        "804/14": "Contents xv\n15.4 Infrared Spectroscopy.................................................................................... 351\n15.4.1 Applications of IR Spectroscopy in Polymer Science. ...................... 352\n15.4.2 Practical Aspects of IR Spectroscopy. ..........................................",
        "764/177": "Further reading 133\nKEY TERMS\nThe following terms were introduced in this chapter. Do you know what they mean and what the techniques are used for?\nq gas chromatography\nq column liquid chromatography\nq plate liquid chromatography\nq high-performance liquid\nchromatography\nq mobile and stationary phase",
    ]

    /// Vingt pages de PROSE notées 2 au banc du 09/09/2026, mêmes 300
    /// premiers caractères. Aucune ne doit être prise pour un sommaire.
    static let prose: [String: String] = [
        "102/335": "328 ALIPHATic NucLEOPHILic SuBSTITUTION\nToday carbocations, usually too unstable to observe as reaction intermediates, can\nbe directly observed in the gas phase and in superacid solution. We will discuss the\nresults of some of these observations in Section 4.5.\nAnd finally, in Section 4.6, we presen",
        "102/792": "9.5 Radical Additions and Eliminations· 789\nRelative Reactivity and Regioselectivity in Addition to Alkenes\nThe normal regioselectivity for the addition of a radical to an alkene is addition at the\nless substituted end, as shown in Equation 9.99 for hydrobromination. Note that this is\nfundamentally ",
        "104/655": "626 Chapter 17 THERMODYNAMICS: DIRECTIONALITY OF CHEMICAL REACTIONS\nbe positive and the T S° term will be negative, which favors the products. Because\nS° is multiplied by T, the entropy of the system is more important at higher tem-\nperatures.\nCONCEPTUAL\nEXERCISE\n17.9 Predicting Whether a Process Is",
        "121/327": "chapterTHIRTeeN\nAn Introduction to Ultraviolet-Visible\nMolecular Absorption Spectrometry\nMolecular absorption spectroscopy in the\n­ ultraviolet and visible spectral regions\nis widely used for the quantitative\n­ determination of a large number of inorganic, organic,\nand biological species. In this ch",
        "121/719": "chaptertwenty-six\nAn Introduction to\nChromatographic Separations\nThere are very few, if any, methods for chemical\nanalysis that are specific for a single ­ chemical\nspecies. At best, analytical methods are\n­ selective for a few species or a class of species. As a\nresult, the separation of the analyt",
        "121/769": "chapterTWENTY-EIGHT\nHigh-Performance Liquid\nChromatography\nHigh-performance liquid chromatography\n(HPLC) is the most versatile and widely used\ntype of elution chromatography. The technique\nis used by scientists for separating and determin-\ning species in a variety of organic, inorganic, and\n­ biolog",
        "121/771": "748 Chapter 28 High-Performance Liquid Chromatography\n5.0\n44.7 μm\nk = 1.2\n4.0\n34.9 μm\nPlate height H, mm\n3.0\n2.0\n1.0\n0.0\n22.6 μm\n13.2 μm\n8.8 μm\n6.1 μm\n3.0 4.0\n0.0 1.0\n2.0\nLinear velocity, cm/s\nFIGURE 28-2 Effect of particle size of packing and flow rate on plate height H in\nLC. Column dimensions: 30",
        "1294/184": "dE\n-\n)\nsys.\n=\nsortie\nOù P est la pression (Pa) et Vi est le volume molaire(m3/mol i). Le terme\n•\ns W\npeut-être produit par l’agitateur dans un réacteur parfaitement agité ou une turbine dans\nun réacteur piston. En recombinant les équations (2) et (3), on obtient :\n•\n•\nn\nn\nQ\nW\nF\nE\n+\nPV\ns PV\n+ å\nå\ni\n(",
        "1294/51": "D=-\nK\nRT R\nln[ T\n(\nT\n)]\nG\n°\n(\n)\nOù DGR\n°\n=\nå D\nu\ni i\nG\no\nf\n,\ni\n9) La relation entre la variation de l’énergie libre de Gibbs de l’enthalpie libre, H, et\nde l’entropie, S est : DG = DH- TDS\nExemple : La réaction équilibrée de production de l’hydrogène à partir de l’\neau se fait\nà une température de 1",
        "1294/63": "L’énergie d’activation est l’énergie minimum que les molécules réactants doivent\nposséder pour que la réaction se fasse. Du point de vue de la théorie cinétique des gaz,\nle facteur e-E/RT représente la fraction des collisions entre les molécules qui ont cette\nénergie minimale. La valeur de E peut va",
        "1294/89": "For a plug flow reactor, conversion varies down the longth of the reactor.\nA\nA\nA\nA\nA\nA\nA\nB\nA A\nB\nB\nB\nB\nД\nA\nA\nNote that the exit conversion does not\nmatch any point inside the PFR.\nIn a CSTR, the conversion at the exit of the reactor is assumed to be cqual\nto the conversion inside the reactor.\nA\nА\nNo",
        "143/36": "14\nFUNDAMENTAL PRINCIPLES\n§1.14 Equilibrium and reversible changes\nIf a system is in complete equilibrium, any conceivable infinitesimal change\nin it must be reversible. For a natural process is an approach towards\nequilibrium, and as the system is already in equilibrium the change cannot\nbe a natur",
        "145/126": "110 1,2-Azoles and 1,3-Azoles\n4-Halopyrazoles are accessible directly from the heterocycle, as are 4-bromoisothiazole and 4-bromoisoxazole, though\nless effi ciently.\nElectrophilic substitutions with carbon electrophiles, as in Friedel–Crafts processes, are virtually unknown in azole\nchemistry except",
        "145/51": "Pyridines 35\nIn contrast to what has been explained above, the presence of activating (electron-releasing) substituents such as amino\nand hydroxyl (or the tautomeric pyridones – see page 41) allows standard electrophilic substitutions in a pyridine ring\nto be carried out under relatively mild condit",
        "150/332": "318 5 Ab initio Calculations\nenergy” to mean Gibbs free energy. A free energy change is an enthalpy change\nadjusted by a temperature-weighted entropy change:\nΔG¼ ΔH TΔS ð*5:173Þ\nThe TΔS term is often a minor contributor to ΔG at room temperature or below,\nbut will dominate at sufficiently high tempe",
        "1520/4": "POLYMÈRES EN SOLUTION\n_______________________________________________________________________________________________________________\n(16)\nUn réarrangement immédiat avec l’équation (10) permet d’expri-\n1\n1\n1\n----------- -\n------- -\n+\n------------------ -\nTC,U\nΘU\nΨU ΘU\nr\nplus faibles en polymère impr",
        "1525/16": "Ce document a ete delivre pour le compte de 7200051104 - espci // 193.54.85.40\n__________________________________________________________________________________________ STRUCTURE MORPHOLOGIQUE DES POLYMÈRES\nT\nT1\nTcr\nT2\nT\nT\nT\nStable\nΦ B\nΦ B\nΦ B\na c\nb\nInstable\nMétastable\nBinodale\nSpinodale\n0\n0 1 Φ‘\nΦ",
        "158/35": "12 1 Foundations\n(b) The definition of energy\nEnergy is the capacity to do work. The SI unit of energy is the\nsame as that of work, namely the joule. The rate of supply of\nenergy is called the power (P), and is expressed in watts (W):\n=−\n1W 1Js 1\nCalories (cal) and kilocalories (kcal) are still enco",
        "158/589": "566 12 The First Law of thermodynamics\nthe white (metallic) form. There is one exception to this gen-\neral prescription: the reference state of phosphorus is taken\nto be white phosphorus despite this allotrope not being the\nmost stable form but simply the most reproducible form of\nthe element. Stand",
        "158/682": "( ; , ) μ μ\nα β\n=\nJ J\np T p T\n( ; , )\nμ μ\n( ; , ) ( , , )\n=\nβ γ\nJ J\np T p T\nμ μ\n( ; , ) ( ; ,\nγ δ\nJ J\np T p T\n= ) )\nare three equations for two unknowns (p and T) and are not\nconsistent (just as x + y = 2, 3x – y = 4, and x + 4y = 6 have no solu-\ntion). The general case is treated in the following J",
    ]

    /// `158 p.583` : une page de PROSE notée 2 (le sujet Thermochimie
    /// d'Atkins, l'une des deux bonnes réponses de RK-04) dont les 300
    /// premiers caractères sont son propre sommaire.
    static let proseStartingWithItsOwnContents = "TOPIC 57\nThermochemistry\nContents\n57.1 Calorimetry 560\n(a) Conventional calorimetry 561\nBrief illustration 57.1: The calorimeter constant 561\nExample 57.1: Calculating a change in enthalpy 562\n(b) Differential scanning calorimetry 562\n57.2 Standard enthalpy changes 563\n(a) Enthalpies of physical cha"
}
