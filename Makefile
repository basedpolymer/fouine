# Fouine — Makefile. Propriété : orchestrateur (vagues 0-2), puis A-Pack (vague 3).
#
# Cibles héritées : build · release-cli · test · clean
# Cibles d'empaquetage (SPEC §11.2) : bundle · release · verify · notarize
# Cibles du palier 1 (audit D3, D4, D13, D19) : check-version · dmg · ci-bundle
# Cible du palier 4 (contre-expertise D2 §5.10) : mcpb (extension Claude Desktop)
#
# Chaîne `make release`, dans l'ordre imposé par le §11.2 :
#   1. swift build -c release            (produits SwiftPM)
#   2. Packaging/bundle.sh               (Fouine.app)
#   2 bis. estampillage des versions dans Contents/Info.plist (D19)
#   3. codesign de l'INTÉRIEUR vers l'extérieur :
#        Sparkle.framework/Versions/B/{Autoupdate,Updater.app} puis le
#        framework lui-même, Contents/MacOS/FouineAgent,
#        Contents/Helpers/fouine (CLI), puis Contents/MacOS/Fouine, puis le
#        bundle avec --entitlements
#   4. contrôles S1 (§8.3)
# La notarisation est une cible SÉPARÉE : elle exige un geste humain préalable
# (`notarytool store-credentials`, voir Packaging/notarize.sh) et, selon le
# §11.1, elle ne sert qu'à ouvrir l'app sur une AUTRE machine.
#
# ─── IDENTITÉ DE SIGNATURE (audit D3) ──────────────────────────────────────
# Ce Makefile ne code plus AUCUNE identité personnelle. `IDENTITY` est vide par
# défaut, ce qui déclenche la signature AD HOC (`codesign --sign -`) : elle
# suffit à faire tourner l'app SUR CETTE MACHINE, et rien de plus.
# Pour signer avec un vrai certificat Developer ID, créez `Makefile.local`
# (gitignoré, jamais versé) à la racine :
#
#     IDENTITY := Developer ID Application: Prénom Nom (TEAMID)
#     FOUINE_NOTARY_PROFILE := nom-du-profil-notarytool
#
# ou, ponctuellement : `make release IDENTITY="Developer ID Application: …"`.

SWIFT    := swift
# `APP` est le bundle LIVRABLE : il sort à la racine du dépôt, où `make dmg`
# et RELEASING.md vont le chercher. Surchargeable — `bundle`, `stamp`,
# `release`, `verify`, `notarize` et `dmg` n'emploient que cette variable.
APP      := Fouine.app
# `CI_APP` est le bundle de CONTRÔLE : celui que `ci-bundle` bâtit pour prouver
# que la structure est signable, et qu'on jette ensuite. Il ne DOIT PAS
# s'appeler Fouine.app à la racine (lot J2). Le 03/09/2026, la copie laissée
# par le gate portait un `CFBundleVersion` supérieur à celui de l'app
# installée — LaunchServices la préférait, et l'agent d'arrière-plan armé
# depuis /Applications échouait en boucle (`spawn failed`, EX_CONFIG), sans que
# rien ne dise pourquoi. Sous `.build/` : Spotlight n'indexe pas les dossiers à
# point, LaunchServices n'y voit donc jamais l'app.
CI_APP   := .build/bundle/Fouine.app
DIST     := dist

# Vide = signature ad hoc. Surchargeable par Makefile.local, par
# l'environnement ou en ligne de commande. `?=` et non `:=` : une valeur
# héritée de l'environnement (release.yml) doit gagner.
IDENTITY ?=

# Profil de trousseau notarytool, transmis à Packaging/notarize.sh. Vide ici :
# le script retombe sur « fouine ».
FOUINE_NOTARY_PROFILE ?=
export FOUINE_NOTARY_PROFILE

# Architectures du binaire livré. Le §11.2 demande un binaire UNIVERSEL ; vérifié
# sur cette machine (Intel, Xcode 26.2 / Swift 6.2.3) : `swift build -c release
# --arch x86_64 --arch arm64` produit bien les deux tranches, en 3 min 06 s, et
# range le résultat dans .build/apple/Products/Release. Pour ne construire que
# l'architecture locale (itérations rapides) :
#     make release ARCHS=x86_64
ARCHS      ?= x86_64 arm64
ARCH_FLAGS := $(foreach a,$(ARCHS),--arch $(a))
BIN_PATH    = $(shell $(SWIFT) build -c release $(ARCH_FLAGS) --show-bin-path)

# --- Versions : une seule source de vérité (audit D19) ----------------------
# VERSION (fichier d'une ligne) et Sources/FouineCore/Version.swift portent la
# MÊME chaîne ; `check-version` échoue sinon. CFBundleVersion est un entier
# monotone — le nombre de commits — parce que Sparkle compare ce champ-là et
# qu'il doit croître à chaque build publié.
VERSION      := $(shell cat VERSION 2>/dev/null | tr -d '[:space:]')
VERSION_SWIFT = $(shell sed -n 's/.*static let string = "\([^"]*\)".*/\1/p' \
                        Sources/FouineCore/Version.swift)
# BUILD_OFFSET s'ajoute au compte de commits. Il sert le jour où le dépôt
# PUBLIC part d'une histoire neuve (RELEASING § 1.d, décision du 14/09/2026) :
# Sparkle compare CFBundleVersion, et une copie installée depuis l'histoire
# privée (build 848 le 14/09) ne doit jamais voir un nombre plus PETIT. Poser
# BUILD_OFFSET au dernier numéro privé avant de publier, et ne jamais le
# baisser. Zéro tant que l'histoire est celle-ci.
BUILD_OFFSET ?= 915
BUILD_NUMBER := $(shell echo $$(( $$(git rev-list --count HEAD 2>/dev/null || echo 1) + $(BUILD_OFFSET) )))

# Le nom de l'identité sert de test « ad hoc ou pas » un peu partout ; on le
# réduit ici à un seul endroit.
SIGN_ARG = $(if $(strip $(IDENTITY)),$(IDENTITY),-)

# Droits du bundle. DEUX fichiers, et le choix dépend de l'identité (palier 2.9,
# audit D13) : le runtime durci active la VALIDATION DE BIBLIOTHÈQUE, qui exige
# que l'app et Sparkle.framework portent le même identifiant d'équipe. Signés
# Developer ID, ils le portent — Fouine.entitlements reste vide, comme il doit.
# Signés AD HOC, ni l'un ni l'autre n'a d'équipe, et dyld refuse de charger le
# framework AVANT la première ligne de code de l'app. Le fichier -adhoc lève la
# validation pour ce seul cas, celui d'un binaire qui ne s'ouvre de toute façon
# que sur la machine qui l'a bâti. Voir son en-tête.
ENTITLEMENTS = $(if $(strip $(IDENTITY)),Packaging/Fouine.entitlements,Packaging/Fouine-adhoc.entitlements)

.PHONY: build release-cli test clean dist-clean release-build bundle release verify \
        notarize check-version check-docs check-changelog check-ranking \
        check-changelog-release dmg ci-bundle stamp check-no-stray-app

# Réglages personnels (identité de signature, profil notarytool). Gitignoré,
# facultatif : le `-` fait que son absence n'est pas une erreur.
-include Makefile.local

build:
	$(SWIFT) build

# Les MÊMES drapeaux que `release-build` (CONST_VALUES_FLAGS, définis plus bas) :
# les deux cibles écrivent dans le même .build/<triplet>/release dès que
# `release-build` ne demande qu'une architecture (le gate : `ci-bundle
# ARCHS=$(uname -m)`), et une ligne de compilation qui change d'un appel à
# l'autre rebâtit tout le release à chaque alternance — mesuré le 08/09/2026,
# ~3 min de plus par gate. Les valeurs constantes émises pour la CLI ne
# servent à rien et ne coûtent rien.
release-cli:
	$(SWIFT) build -c release --product fouine $(CONST_VALUES_FLAGS)

# `make test` dépend de `release-cli`, et ce n'est pas un ornement : la cible
# IntegrationTests pilote le BINAIRE `fouine` par `Process`, mais elle ne dépend
# que des quatre bibliothèques (Package.swift) — SwiftPM ne bâtit donc jamais
# l'exécutable pour elle. Sans cette dépendance, TOUTE la recette d'intégration
# se saute sur `Recette.requireBinary` (« binaire `fouine` absent »), en vert.
# En RELEASE parce que les seuils de performance du §8.2 ne sont contractuels
# qu'en release, et que `Recette.binary` cherche `.build/release/fouine` en
# priorité (`FOUINE_BIN` reste prioritaire sur les deux).
#
# Depuis le palier 0 (audit S3), la recette n'écrit plus jamais dans la base de
# production : elle fabrique une base jetable, et le corpus complet ne s'ouvre
# que sur `FOUINE_TEST_DB=<copie>` (en-tête de Tests/Integration/IntegrationSupport.swift).
test: release-cli
	$(SWIFT) test

dist-clean:
	rm -rf $(DIST) Fouine.zip

clean: dist-clean
	$(SWIFT) package clean
	rm -rf $(APP) $(CI_APP)

# --- Versions ---------------------------------------------------------------

# Garde-fou appelé par `bundle` et par la CI : deux fichiers, une seule valeur.
check-version:
	@if [ -z "$(VERSION)" ]; then \
	    echo "check-version : fichier VERSION absent ou vide" >&2; exit 1; fi
	@if [ "$(VERSION)" != "$(VERSION_SWIFT)" ]; then \
	    echo "check-version : VERSION ($(VERSION)) ≠ FouineVersion.string ($(VERSION_SWIFT))" >&2; \
	    echo "                mettez les DEUX à jour (voir RELEASING.md § 2)." >&2; \
	    exit 1; fi
	@echo "check-version : $(VERSION) (build $(BUILD_NUMBER)) — VERSION et Version.swift concordent"

# Garde-fou de DOCUMENTATION, appelé par la CI avant le build : aucune balise
# d'appel d'outil ne doit survivre dans un document public. Dix d'entre elles
# ont vécu jusqu'au 02/09/2026 dans neuf fichiers, README compris — où elles
# étaient la DERNIÈRE chose que voyait un visiteur de la page GitHub
# (audit B1-30). Le défaut est de crédibilité, pas de fonctionnement : la balise
# dit exactement comment le fichier a été écrit.
#
# `grep -r` rend 1 quand il ne trouve rien : c'est le cas NORMAL ici, d'où le
# `if ... then exit 1`.
check-docs:
	@if grep -rn '</content>\|</invoke>\|</parameter>' \
	        README.md docs/ Packaging/*.md \
	        CONTRIBUTING.md SECURITY.md RELEASING.md; then \
	    echo "check-docs : balise d'appel d'outil dans un document public —" >&2; \
	    echo "             supprimez les lignes ci-dessus (audit B1-30)." >&2; \
	    exit 1; \
	 fi
	@echo "check-docs : aucune balise d'appel d'outil dans les documents publics"

# Les trois scripts du banc de classement (Tools/ranking) n'ont ni cible Swift
# ni dépendance : leurs conventions — candidat non noté = 0, requête en échec
# écartée pour tous, idéal sur tous les jugements connus, nDCG par document —
# se prouvent sur un pool fabriqué, en une seconde. Sans ce garde-fou, le
# 05/09/2026, une colonne lue par position au lieu de son nom avait fait
# annoncer un nDCG sur 581 jugements qui n'existaient pas.
check-ranking:
	@python3 -m unittest -q Tools/ranking/test_ranking.py \
	    && echo "check-ranking : les scripts du banc tiennent leurs conventions"

# Garde-fou du JOURNAL. `Packaging/appcast.sh` fabrique les notes que Sparkle
# affiche à CHAQUE utilisateur en extrayant du CHANGELOG la SEULE section
# `## [$(VERSION)]`. Le 02/09/2026, deux sections coexistaient — `## Non
# publié`, qui portait le produit, et le titre de version, qui ne portait que
# le palier 0 : les notes de la première version publique auraient été un avis
# de faille et rien d'autre (audit B1-04, contre-expertise D2-06).
# `appcast.sh` refuse ce cas, mais il ne tourne qu'AU MOMENT DE PUBLIER, quand
# le tag est déjà posé. Cette cible-ci le fait voir à chaque run de CI.
#
# Le journal est en ANGLAIS depuis le 13/09/2026 (lot DC2) : le titre non daté
# porte « unreleased » et les rubriques sont Added/Changed/Fixed/Security. Les
# formes françaises restent reconnues par le premier garde-fou, pour qu'une
# section « Non publié » réintroduite par une fusion soit encore refusée.
#
# La DATE n'est PAS exigée ici : en intégration continue, la version en
# préparation porte légitimement « — unreleased », et l'exiger rendrait `main`
# rouge en permanence. C'est `check-changelog-release` — appelée par
# `release.yml` avant le build — et `appcast.sh` qui l'exigent, au moment où
# le titre doit être daté.
STRICT ?=

check-changelog:
	@set -eu; \
	unreleased=$$(awk '/^## +(Non publié|Unreleased)/ { i = 1; next } i && /^## / { exit } i && NF { print }' CHANGELOG.md | wc -l | tr -d ' '); \
	if [ "$$unreleased" -gt 0 ]; then \
	    echo "check-changelog : $$unreleased ligne(s) sous « ## Unreleased » —" >&2; \
	    echo "                  ce journal n'a pas de section « Unreleased » : les" >&2; \
	    echo "                  entrées vont sous \`## [$(VERSION)] — unreleased\`," >&2; \
	    echo "                  rubriques Added/Changed/Fixed/Security" >&2; \
	    echo "                  (CONTRIBUTING.md, RELEASING.md § 2, audit B1-04)." >&2; \
	    exit 1; \
	fi; \
	title=$$(grep "^## \[$(VERSION)\]" CHANGELOG.md | head -n 1); \
	if [ -z "$$title" ]; then \
	    echo "check-changelog : aucune section « ## [$(VERSION)] » dans CHANGELOG.md —" >&2; \
	    echo "                  les notes de version de cette release seraient vides." >&2; \
	    exit 1; \
	fi; \
	body=$$(awk -v v="$(VERSION)" '$$0 ~ "^## \\[" v "\\]" { i = 1; next } i && /^## / { exit } i && NF { print }' CHANGELOG.md | wc -l | tr -d ' '); \
	if [ "$$body" -eq 0 ]; then \
	    echo "check-changelog : « $$title » est vide — décrivez ce que cette" >&2; \
	    echo "                  version change pour l'utilisateur." >&2; \
	    exit 1; \
	fi; \
	case "$$title" in \
	    *unreleased*|*"à venir"*) \
	        if [ -n "$(STRICT)" ]; then \
	            echo "check-changelog : « $$title » — datez le titre" >&2; \
	            echo "                  (« ## [$(VERSION)] — $$(date +%Y-%m-%d) »)" >&2; \
	            echo "                  avant de publier (RELEASING.md § 2)." >&2; \
	            exit 1; \
	        fi; \
	        echo "check-changelog : $$body ligne(s) sous « $$title » — non datée," \
	             "ce qui est normal hors release" ;; \
	    *) \
	        echo "check-changelog : $$body ligne(s) sous « $$title »" ;; \
	esac

# Le même contrôle, plus la date. Appelée par `release.yml` avant le build :
# un tag posé sur un journal non refermé ne doit pas produire de DMG.
check-changelog-release: STRICT = 1
check-changelog-release: check-changelog

# --- Vague 3 : empaquetage et signature (§11.2) -----------------------------

# Émission des VALEURS CONSTANTES, exigée par les métadonnées App Intents
# (lot INT-R1). `appintentsmetadataprocessor` ne lit pas le binaire : il lit un
# `.swiftconstvalues` par fichier source, que le compilateur n'écrit QUE sous
# ces drapeaux. Sans eux, `Packaging/bundle.sh` s'arrête net — un bundle sans
# `Contents/Resources/Metadata.appintents` n'a aucune action dans Raccourcis, et
# rien d'autre ne le signalerait.
#
# Le JSON liste les protocoles dont on veut les conformités (AppIntent,
# AppEntity, EntityQuery, AppShortcutsProvider…) : c'est ce que Xcode génère
# sous le nom `<cible>-const-extract-protocols.json`, ici écrit à la main
# puisque Fouine se bâtit en SwiftPM pur.
#
# Le chemin est ABSOLU (`$(CURDIR)`) : le frontend Swift le résout depuis son
# répertoire de travail, qui n'est pas garanti être la racine du dépôt.
#
# Le prix : ces drapeaux changent la ligne de commande de compilation, donc le
# premier `make bundle` après ce lot rebâtit tout le release (~3 min).
CONST_VALUES_FLAGS := -Xswiftc -emit-const-values \
                      -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
                      -Xswiftc -Xfrontend \
                      -Xswiftc $(CURDIR)/Packaging/appintents-protocols.json

release-build:
	$(SWIFT) build -c release $(ARCH_FLAGS) $(CONST_VALUES_FLAGS)

bundle: check-version release-build
	Packaging/bundle.sh "$(BIN_PATH)" "$(APP)"
	@$(MAKE) --no-print-directory stamp APP="$(APP)"

# Estampillage APRÈS bundle.sh, qui reste la propriété d'un autre agent et
# copie Packaging/Info.plist tel quel. Les valeurs versionnées de ce fichier
# (1.0.0 / 1) ne sont donc qu'un REPLI : ce qui compte est ce que `plutil`
# écrit ici, dans la copie qui part dans le bundle.
stamp:
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" \
	       "$(APP)/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" \
	       "$(APP)/Contents/Info.plist"
	plutil -lint "$(APP)/Contents/Info.plist" >/dev/null
	@echo "stamp : CFBundleShortVersionString=$(VERSION)  CFBundleVersion=$(BUILD_NUMBER)"


# --- Signature de Sparkle.framework (palier 2.9, audit D13) -----------------
#
# Un framework VERSIONNÉ se signe de l'intérieur, et dans cet ordre précis :
#   1. Autoupdate — l'outil qui remplace l'app pendant qu'elle est quittée ;
#      c'est un exécutable Mach-O nu, donc une signature à part entière ;
#   2. Updater.app — une VRAIE application imbriquée (Contents/MacOS/Updater) :
#      elle affiche la fenêtre de progression après le lancement d'Autoupdate ;
#   3. Versions/B — et non « Sparkle.framework » : sur un framework versionné,
#      c'est le répertoire de version qui porte le sceau, et signer le lien
#      symbolique de tête laisse `--deep --strict` insatisfait.
# Les XPCServices ne sont pas dans cette liste : bundle.sh les retire, ils ne
# servent qu'aux applications en bac à sable (voir son commentaire).
#
# `--options runtime` sur CHAQUE morceau : la notarisation refuse un bundle dont
# un seul exécutable imbriqué n'a pas le runtime durci, et le message d'Apple ne
# dit pas lequel.
#
# $(1) = identité, $(2) = option de timestamp, $(3) = chemin du .app
define sign-sparkle
	@echo "== codesign : Sparkle.framework (de l'intérieur)"
	codesign --force --options runtime $(2) --sign "$(1)" \
	    "$(3)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
	codesign --force --options runtime $(2) --sign "$(1)" \
	    "$(3)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
	codesign --force --options runtime $(2) --sign "$(1)" \
	    "$(3)/Contents/Frameworks/Sparkle.framework/Versions/B"
endef

release: bundle
	@if [ -z "$(strip $(IDENTITY))" ]; then \
	    echo "=============================================================="; \
	    echo " SIGNATURE AD HOC : l'app ne s'ouvrira que sur cette machine"; \
	    echo " et ne peut PAS être notarisée. Pour une vraie signature,"; \
	    echo " créez Makefile.local avec IDENTITY := Developer ID Application: …"; \
	    echo "=============================================================="; \
	 else \
	    echo "== signature : $(IDENTITY)"; \
	 fi
	@echo "== codesign : helpers d'abord (de l'intérieur vers l'extérieur)"
	$(call sign-sparkle,$(SIGN_ARG),--timestamp,$(APP))
	@# -i : identifiant de signature explicite. Sans lui, codesign le déduit du
	@# nom de fichier (« FouineAgent ») ; on veut l'identité stable qui
	@# correspond au Label du LaunchAgent enregistré par SMAppService.
	codesign --force --options runtime --timestamp \
	         -i io.github.basedpolymer.fouine.agent \
	         --sign "$(SIGN_ARG)" "$(APP)/Contents/MacOS/FouineAgent"
	@# La CLI vit dans Contents/Helpers/fouine, PAS dans Contents/MacOS : le
	@# disque d'un Mac est insensible à la casse et « fouine » y désignerait
	@# « Fouine », l'exécutable de l'app (audit produit D1/V9 ; bundle.sh
	@# échoue si la CLI manque, donc pas de conditionnel ici).
	@echo "== codesign : Contents/Helpers/fouine (CLI embarquée)"
	codesign --force --options runtime --timestamp \
	         -i io.github.basedpolymer.fouine.cli \
	         --sign "$(SIGN_ARG)" "$(APP)/Contents/Helpers/fouine"
	codesign --force --options runtime --timestamp \
	         --sign "$(SIGN_ARG)" "$(APP)/Contents/MacOS/Fouine"
	@echo "== codesign : le bundle, avec les droits (runtime durci, sans bac à sable)"
	@echo "   droits : $(ENTITLEMENTS)"
	codesign --force --options runtime --timestamp \
	         --entitlements $(ENTITLEMENTS) \
	         --sign "$(SIGN_ARG)" "$(APP)"
	@$(MAKE) --no-print-directory verify

# S1 (§8.3) : flags=0x10000(runtime) et, en signature Developer ID, un
# TeamIdentifier non vide. On ne code plus AUCUN identifiant d'équipe ici : il
# est lu dans le certificat par `codesign -dv` et seulement affiché. En ad hoc,
# `TeamIdentifier=not set` est NORMAL et ne doit pas faire échouer la cible.
# S2 (spctl) ÉCHOUE tant que la notarisation n'a pas tourné : c'est attendu,
# d'où le `-` qui laisse la cible réussir.
verify:
	Packaging/tests/test_naming.sh
	@echo "== S1  codesign -dv --verbose=4"
	codesign -dv --verbose=4 "$(APP)"
	@echo "== runtime durci ?"
	@codesign -d --verbose=4 "$(APP)" 2>&1 | grep -q 'flags=.*runtime' \
	    || { echo "verify : runtime durci ABSENT (--options runtime) — §11.2" >&2; exit 1; }
	@echo "   oui (flags contient « runtime »)"
	@echo "== identité"
	@team=$$(codesign -dv --verbose=4 "$(APP)" 2>&1 \
	          | sed -n 's/^TeamIdentifier=//p'); \
	 if [ -z "$$team" ] || [ "$$team" = "not set" ]; then \
	     echo "   TeamIdentifier absent → signature AD HOC."; \
	     echo "   Attendu si IDENTITY est vide ; l'app ne s'ouvrira que sur cette"; \
	     echo "   machine et ne peut pas être notarisée."; \
	 else \
	     echo "   TeamIdentifier=$$team (signature Developer ID)"; \
	 fi
	@echo "== Sparkle.framework embarqué"
	@# Un framework absent ne se voit qu'au LANCEMENT (dyld), et le message
	@# part dans les journaux du système : on le contrôle ici.
	@test -x "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
	    || { echo "verify : Sparkle.framework absent de Contents/Frameworks" >&2; exit 1; }
	@echo "   tranches : $$(lipo -archs $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle)"
	@codesign -dv --verbose=2 \
	    "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B" 2>&1 \
	    | sed -n 's/^Identifier=/   identifiant /p'
	@echo "== lien dynamique vers Sparkle et rpath"
	@otool -L "$(APP)/Contents/MacOS/Fouine" | grep 'Sparkle.framework' \
	    || { echo "verify : Contents/MacOS/Fouine ne référence pas Sparkle" >&2; exit 1; }
	@otool -l "$(APP)/Contents/MacOS/Fouine" | grep -q '@executable_path/../Frameworks' \
	    || { echo "verify : LC_RPATH manquant — Sparkle introuvable au lancement" >&2; exit 1; }
	@echo "   LC_RPATH @executable_path/../Frameworks présent"
	@echo "== droits effectifs"
	@if codesign -d --entitlements - --xml "$(APP)" 2>/dev/null \
	    | grep -q 'disable-library-validation'; then \
	     echo "   validation de bibliothèque LEVÉE — normal en signature ad hoc,"; \
	     echo "   ANORMAL dans une version distribuée (voir ENTITLEMENTS du Makefile)."; \
	 else \
	     echo "   aucun droit d'assouplissement (validation de bibliothèque active)"; \
	 fi
	@echo "== codesign --verify --deep --strict"
	codesign --verify --deep --strict --verbose=2 "$(APP)"
	@echo "== S2  spctl -a -vv (rejet attendu tant que notarytool n'a pas tourné)"
	-spctl -a -vv "$(APP)"

# Accepte un .app ou un .dmg : `make notarize` notarise l'app, et
# `make notarize NOTARIZE_TARGET=dist/Fouine-1.0.0.dmg` le DMG signé — c'est
# ce dernier qui est distribué, et c'est donc lui qu'il faut agrafer.
NOTARIZE_TARGET ?= $(APP)
notarize:
	Packaging/notarize.sh "$(NOTARIZE_TARGET)"

# --- Palier 1.5 : image disque (audit D13) ----------------------------------

# `hdiutil` seul, aucune dépendance Homebrew (pas de create-dmg). Sort dans
# dist/, gitignoré. Signe le DMG si IDENTITY est renseignée.
#
# Cette cible ne dépend PAS de `release`, et c'est délibéré : l'ordre de
# RELEASING.md est `make release` → `make notarize` → `make dmg`, et une
# dépendance sur `release` relancerait `bundle`, qui commence par `rm -rf
# Fouine.app` — l'agrafe posée par la notarisation serait détruite au moment
# précis où l'on met l'app dans l'image. On se contente donc de bâtir l'app si
# elle n'existe pas encore.
dmg:
	@if [ ! -d "$(APP)" ]; then \
	    echo "dmg : $(APP) absente, construction préalable"; \
	    $(MAKE) --no-print-directory release; \
	 fi
	IDENTITY="$(IDENTITY)" VERSION="$(VERSION)" \
	    Packaging/dmg.sh "$(APP)"

# --- Palier 4 PR 3 : extension de bureau Claude Desktop (D2 § 5.10) ---------

# `.mcpb` : l'archive que Claude Desktop installe d'un double-clic. Elle
# embarque le binaire `fouine` DÉJÀ SIGNÉ ET NOTARISÉ de Fouine.app ; le script
# ne compile jamais rien (voir son en-tête, et RELEASING.md § 7).
#
# Comme `dmg`, cette cible ne dépend PAS de `release` : l'ordre imposé est
# `make release` → `make notarize` → `make mcpb`, et une dépendance relancerait
# `bundle`, qui commence par `rm -rf Fouine.app` — on empaquetterait un binaire
# tout juste rebâti, donc NON notarisé, au moment précis où c'est le contraire
# qui est requis.
#
# Deux échappatoires pour les ESSAIS LOCAUX, jamais pour une publication :
#     make mcpb MCPB_ALLOW_THIN=1     binaire mono-architecture accepté
#     make mcpb MCPB_ALLOW_ADHOC=1    signature ad hoc acceptée
# `export` : le script les lit dans l'environnement, et une variable posée en
# ligne de commande de `make` n'y arrive pas toute seule.
MCPB_ALLOW_THIN  ?=
MCPB_ALLOW_ADHOC ?=
export MCPB_ALLOW_THIN MCPB_ALLOW_ADHOC

.PHONY: mcpb
mcpb:
	VERSION="$(VERSION)" \
	    Packaging/mcpb.sh "$(APP)"

# --- CI ---------------------------------------------------------------------

# Ce que la CI peut faire sans le moindre secret : bâtir le bundle, le passer au
# linter, vérifier les tranches et le signer ad hoc pour prouver que la
# structure du bundle est signable. Aucune identité, aucun trousseau.
# `APP` propre à la cible : la valeur vaut aussi pour la prérequis `bundle`,
# qui bâtit donc directement sous .build/ (lot J2). Rien de visible de
# LaunchServices ne sort de cette cible.
ci-bundle: APP = $(CI_APP)
ci-bundle: check-no-stray-app bundle
	plutil -lint "$(APP)/Contents/Info.plist"
	plutil -lint "$(APP)/Contents/Library/LaunchAgents/io.github.basedpolymer.fouine.agent.plist"
	@# MIT exige que la notice de copyright accompagne toute copie, Apache-2.0
	@# §4(a) qu'une copie de la licence soit remise au destinataire : ces deux
	@# fichiers ne sont pas décoratifs, ils sont la conformité (audit B1-10).
	@# Ce sont aussi des ressources SCELLÉES — absentes ici, elles le seraient
	@# du DMG notarisé, et on ne s'en apercevrait jamais.
	@echo "== licences livrées dans le bundle"
	@for f in LICENSE THIRD_PARTY_LICENSES.md; do \
	    test -s "$(APP)/Contents/Resources/$$f" \
	        || { echo "ci-bundle : $(APP)/Contents/Resources/$$f absent ou vide" >&2; \
	             echo "            bundle.sh doit le copier AVANT la signature (B1-10)." >&2; \
	             exit 1; }; \
	    echo "   Contents/Resources/$$f ($$(wc -c < "$(APP)/Contents/Resources/$$f" | tr -d ' ') octets)"; \
	 done
	@echo "== lipo"
	lipo -archs "$(APP)/Contents/MacOS/Fouine"
	lipo -archs "$(APP)/Contents/MacOS/FouineAgent"
	lipo -archs "$(APP)/Contents/Helpers/fouine"
	lipo -archs "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
	@echo "== versions estampillées"
	plutil -p "$(APP)/Contents/Info.plist" | grep -E 'CFBundle(ShortVersionString|Version)'
	@echo "== codesign ad hoc (structure du bundle)"
	$(call sign-sparkle,-,--timestamp=none,$(APP))
	codesign --force --options runtime --timestamp=none \
	         -i io.github.basedpolymer.fouine.agent --sign - "$(APP)/Contents/MacOS/FouineAgent"
	codesign --force --options runtime --timestamp=none \
	         -i io.github.basedpolymer.fouine.cli --sign - "$(APP)/Contents/Helpers/fouine"
	codesign --force --options runtime --timestamp=none \
	         --sign - "$(APP)/Contents/MacOS/Fouine"
	@# La CI signe toujours ad hoc : d'où le fichier de droits ad hoc, sans
	@# lequel une app à framework embarqué ne se lance pas (voir ENTITLEMENTS).
	codesign --force --options runtime --timestamp=none \
	         --entitlements Packaging/Fouine-adhoc.entitlements --sign - "$(APP)"
	codesign --verify --deep --strict --verbose=2 "$(APP)"
	@echo "ci-bundle : OK — bundle de contrôle sous $(APP), invisible de LaunchServices"

# Garde-fou du lot J2, appelé AVANT `ci-bundle`. Un `Fouine.app` à la racine du
# dépôt est une deuxième copie que macOS voit : si son `CFBundleVersion`
# dépasse celui de l'app installée — et c'est le cas, il vaut le nombre de
# commits —, LaunchServices la préfère et l'agent d'arrière-plan armé depuis
# /Applications échoue en boucle. Ce n'est pas un avertissement : le 03/09/2026
# la panne a coûté une demi-journée de diagnostic, et supprimer la copie ne
# suffit même pas à réparer l'enregistrement (voir docs/pitfalls.md).
# `make bundle`, `make release` et `make dmg` en produisent un légitimement :
# RELEASING.md dit de le supprimer une fois l'app installée ou le DMG fait.
check-no-stray-app:
	@if [ -d "Fouine.app" ]; then \
	    echo "check-no-stray-app : Fouine.app traîne à la racine du dépôt." >&2; \
	    echo "  macOS la voit comme une deuxième installation et la préfère" >&2; \
	    echo "  (son CFBundleVersion vaut le nombre de commits) : l'agent" >&2; \
	    echo "  d'arrière-plan armé depuis /Applications échoue alors en" >&2; \
	    echo "  EX_CONFIG à chaque tentative. Supprimez-la :" >&2; \
	    echo "      rm -rf Fouine.app" >&2; \
	    echo "  puis relancez. Voir docs/pitfalls.md, « Deux copies de" >&2; \
	    echo "  Fouine.app »." >&2; \
	    exit 1; \
	 fi
	@echo "check-no-stray-app : aucune Fouine.app à la racine du dépôt"

# --- Fixtures versionnées (audit E5) ----------------------------------------

# Régénère Tests/Fixtures/corpus/ ET son manifeste. Les fichiers produits sont
# COMMITÉS : les tests les lisent tels quels et n'appellent jamais ce
# générateur. On ne lance cette cible que pour AJOUTER ou CORRIGER une fixture —
# après quoi on commite le corpus régénéré avec le générateur qui l'a produit.
#
# Aucune dépendance hors macOS : Foundation, CoreGraphics, CoreText, ImageIO et
# /usr/bin/zip. djvulibre est facultatif (sans lui, notice.djvu n'est pas
# produit et les tests qui en dépendent se sautent).
#
# ATTENTION : la régénération n'est pas reproductible à l'octet (CoreGraphics
# date chaque PDF, zip date chaque entrée). `git status` montrera donc TOUS les
# binaires modifiés même sans changement de contenu — c'est normal, et c'est
# pourquoi le manifeste décrit le CONTENU attendu et jamais une empreinte.
.PHONY: fixtures
fixtures:
	$(SWIFT) Tools/make_fixtures.swift

# Les fixtures MÉDIAS (lot INT-F3) vivent à part, sous Tests/Fixtures/media, et
# n'entrent PAS dans le manifeste du corpus : la famille son/vidéo n'est
# inscrite que sous `extract.media`, que la recette n'allume pas — une fixture
# média rangée dans corpus/ ne serait jamais indexée et fausserait ses comptes
# (même décision que pour les images). `say -v Thomas` fabrique la voix : sans
# la voix française, la fixture n'est pas produite.
.PHONY: fixtures-media
fixtures-media:
	$(SWIFT) Tools/make_fixtures.swift media

# Les deux suites qui exercent le corpus versionné, sans rien de personnel.
# `release-cli` d'abord : la recette pilote le BINAIRE `fouine` (voir `test`).
#
# COMMODITÉ LOCALE, malgré le préfixe `ci-` : AUCUN workflow ne lance cette
# cible (audit B1-28), et ce n'est pas une perte de couverture — les deux suites
# qu'elle nomme sont déjà prises, l'une par `ci-unit`, l'autre par
# `ci-integration`. Elle existe pour rejouer le corpus versionné SEUL, en
# quelques secondes, quand on ajoute ou corrige une fixture.
.PHONY: ci-corpus
ci-corpus: release-cli
	$(SWIFT) test --filter FouineExtractTests.CorpusFixturesTests \
	              --filter IntegrationTests.VersionedCorpusTests

# --- CI : ce que le runner lance, reproductible en local ---------------------

# Les mêmes commandes que .github/workflows/ci.yml, à un endroit unique : un
# contributeur qui veut savoir pourquoi la CI est rouge lance ces deux cibles,
# et la liste des suites ne vit pas en double dans le YAML.

# Les NEUF suites unitaires. FouineAppTests, FouineIndexTests et FouineAgentTests
# ne tournaient PAS en CI avant le palier 3.3 — la première existait pourtant
# depuis le palier 2 (audit D12/M23 : « zéro test sur FouineApp/, FouineAgent/,
# fouine/ »). FouineMCPTests est la neuvième, arrivée avec le serveur MCP
# (palier 4). Le filtre porte sur <cible>.<classe>/<test> : le préfixe de cible
# suffit à prendre la suite entière.
#
# FouineEmbedTests en fait partie : ses trois tests de parité avec le modèle e5
# se sautent d'eux-mêmes quand il est absent, ce qui est le cas d'un runner sans
# cache. Aucun filtre par nom n'est nécessaire.
#
# `CONFIG` permet de rejouer les MÊMES suites en release :
#     make ci-unit CONFIG="-c release"
# C'est ce que fait le job `release-tests` de la CI, sur `main` seulement.
CONFIG ?=

.PHONY: ci-unit
# `--parallel` depuis le lot I2 (03/09/2026) : un processus xctest par test,
# huit travailleurs. Mesuré sur le même bundle, machine libre : 53 s contre
# 129 s en série (87 s en série après le lot). Deux choses changent à la
# lecture : plus de durée par test ni de ligne « Executed N tests, with M
# skipped » — pour chronométrer ou compter les sauts, lancer la suite seule
# en série (`swift test --filter FouineOCRTests`). Détail dans docs/tests.md,
# § « Aller vite ».
ci-unit:
	$(SWIFT) test $(CONFIG) --parallel \
	    --filter FouineCoreTests \
	    --filter FouineCrawlTests \
	    --filter FouineExtractTests \
	    --filter FouineOCRTests \
	    --filter FouineIndexTests \
	    --filter FouineEmbedTests \
	    --filter FouineAppTests \
	    --filter FouineAgentTests \
	    --filter FouineMCPTests \
	    --filter FouineLicenseTests

# Le serveur MCP seul. COMMODITÉ, comme `ci-corpus` : aucun workflow ne lance
# cette cible, et ce n'est pas une perte de couverture — `ci-unit` prend déjà la
# suite. Elle existe pour rejouer les treize transcriptions « golden » en une
# vingtaine de secondes quand on touche au routeur ou au schéma d'un outil —
# dont trois secondes de silence réseau et, si le modèle e5 est installé, une
# trentaine pour l'hybride réel (sautée sans lui).
.PHONY: ci-mcp
ci-mcp:
	$(SWIFT) test $(CONFIG) --filter FouineMCPTests

# La recette d'intégration. `release-cli` d'abord : sans le binaire, TOUTE la
# recette se saute en vert (voir le commentaire de la cible `test`).
.PHONY: ci-integration
ci-integration: release-cli
	$(SWIFT) test --filter IntegrationTests

# Contrôles d'empaquetage sur les fichiers de LOCALISATION, ajoutés par le
# palier 3.2 (audit U1) : Contents/Resources/{en,fr}.lproj/*.strings.
#
# DEUX NIVEAUX DE SÉVÉRITÉ, et la différence est délibérée :
#
#   · `plutil -lint` sur chaque .strings est un ÉCHEC DUR. Un .strings malformé
#     n'est pas un choix de traduction, c'est un fichier cassé : macOS
#     l'ignorerait en silence et l'interface repartirait en anglais sans que
#     personne ne l'apprenne.
#
#   · la PARITÉ DES CLÉS entre en.lproj et fr.lproj s'affiche par `warn`, mais
#     ÉCHOUE : chaque appel pose `diverged=1`, et le bloc final (« clés
#     divergentes… ») fait `exit 1`. Le mot « AVERTISSEMENT » ne décrit que la
#     FORME du message — on veut la liste COMPLÈTE des divergences dans un seul
#     run, pas la première puis un arrêt. Mesuré par la contre-expertise D2 du
#     02/09/2026 sur un bundle volontairement divergent : `make ci-bundle-i18n`
#     rend `Error 1`. Le commentaire « À DURCIR : remplacer les warn par un
#     exit 1 » qui figurait ici était donc faux, et il a coûté un constat
#     d'audit (B1-27, INFIRMÉ) : ne le réintroduisez pas, et ne remplacez pas
#     les `warn` — ils sont l'accumulateur, pas la clémence.
#     Le palier 3.2 a son propre linter de catalogues (Tools/l10n/lint.py) —
#     c'est LUI qui fait autorité sur la complétude des traductions.
#
#   · l'ABSENCE TOTALE de .lproj est un ÉCHEC DUR (`exit 1`) : cette cible a été
#     écrite avant la fusion du palier 3.2 et devait pouvoir tourner sans lui,
#     mais depuis, `Packaging/bundle.sh` échoue lui-même quand les .strings
#     manquent — un bundle sans .lproj est donc forcément cassé.
#
#   · l'absence d'un des TROIS fichiers attendus dans une langue est un ÉCHEC
#     DUR (lot L2). La parité des clés ne voit qu'un fichier présent d'un seul
#     côté : `AppShortcuts.strings` oublié dans les DEUX langues passerait en
#     vert, et « Dis Siri, cherche dans Fouine » repartirait en anglais sans un
#     mot (audit BU-35). On nomme donc ce qu'on exige.
.PHONY: ci-bundle-i18n
# Même bundle de contrôle que `ci-bundle`, donc même emplacement (lot J2) :
# cette cible ne bâtit rien, elle relit ce que la précédente a laissé.
ci-bundle-i18n: APP = $(CI_APP)
ci-bundle-i18n:
	@set -eu; \
	res="$(APP)/Contents/Resources"; \
	warn() { \
	    printf 'ci-bundle-i18n : AVERTISSEMENT — %s\n' "$$1"; \
	    if [ -n "$${GITHUB_ACTIONS:-}" ]; then \
	        echo "::warning title=Localisation::$$1"; \
	    fi; \
	}; \
	if [ ! -d "$$res" ]; then \
	    echo "ci-bundle-i18n : $$res absent — lancez d'abord \`make ci-bundle\`" >&2; \
	    exit 1; \
	fi; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	found=0; \
	for lang in en fr; do \
	    for want in InfoPlist.strings Localizable.strings AppShortcuts.strings; do \
	        if [ ! -s "$$res/$$lang.lproj/$$want" ]; then \
	            echo "ci-bundle-i18n : $$lang.lproj/$$want absent ou vide —" \
	                 "cette langue perdrait ces chaînes en silence" >&2; \
	            exit 1; \
	        fi; \
	    done; \
	done; \
	for lang in en fr; do \
	    dir="$$res/$$lang.lproj"; \
	    [ -d "$$dir" ] || continue; \
	    for f in "$$dir"/*.strings; do \
	        [ -e "$$f" ] || continue; \
	        found=1; \
	        plutil -lint "$$f"; \
	        plutil -convert xml1 -o - "$$f" \
	            | sed -n 's/.*<key>\(.*\)<\/key>.*/\1/p' | sort \
	            > "$$tmp/$$lang-$$(basename "$$f")"; \
	    done; \
	done; \
	if [ "$$found" = 0 ]; then \
	    echo "ci-bundle-i18n : aucun Contents/Resources/{en,fr}.lproj/*.strings —" \
	         "bundle.sh aurait dû les compiler (palier 3.2)" >&2; \
	    exit 1; \
	fi; \
	diverged=0; \
	for f in "$$tmp"/en-*; do \
	    [ -e "$$f" ] || continue; \
	    base=$${f#$$tmp/en-}; \
	    other="$$tmp/fr-$$base"; \
	    if [ ! -e "$$other" ]; then \
	        warn "$$base existe en en.lproj mais pas en fr.lproj"; \
	        diverged=1; \
	        continue; \
	    fi; \
	    if diff -u "$$f" "$$other" > "$$tmp/diff-$$base"; then \
	        echo "ci-bundle-i18n : $$base — mêmes clés en en.lproj et fr.lproj ($$(wc -l < "$$f" | tr -d ' ') clés)"; \
	    else \
	        warn "$$base — clés divergentes entre en.lproj et fr.lproj"; \
	        grep -E '^[-+][^-+]' "$$tmp/diff-$$base" | head -20; \
	        diverged=1; \
	    fi; \
	done; \
	for f in "$$tmp"/fr-*; do \
	    [ -e "$$f" ] || continue; \
	    base=$${f#$$tmp/fr-}; \
	    if [ ! -e "$$tmp/en-$$base" ]; then \
	        warn "$$base existe en fr.lproj mais pas en en.lproj"; \
	        diverged=1; \
	    fi; \
	done; \
	if [ "$$diverged" = 0 ]; then \
	    echo "ci-bundle-i18n : OK"; \
	else \
	    echo "ci-bundle-i18n : ÉCHEC — clés divergentes entre en.lproj et fr.lproj," \
	         "une clé sans traduction \`fr\` dans un catalogue (Tools/l10n-lint.sh)" >&2; \
	    exit 1; \
	fi

# --- Le gate complet en une commande --------------------------------------
#
# Enchaîne, dans l'ordre de CLAUDE.md § « Gate complet avant fusion sur main »,
# en s'arrêtant au premier rouge : contrôles statiques (docs, changelog, banc,
# l10n), les neuf suites unitaires en --parallel, la recette CLI sur le binaire
# release, le bundle de contrôle et sa localisation. ~10 min machine libre,
# bundle chaud ; le double sous une autre compilation.
#
# `PURGE=1` vide d'abord .build/{debug,release} (les deux architectures) :
# obligatoire après une fusion qui change une struct publique partagée
# (Contracts.swift, Settings.swift, GRDBStore) — un SIGBUS dans un test de
# recherche est un build incrémental périmé, pas un bogue (docs/pitfalls.md,
# CLAUDE.md). Comptez 2 min de plus (84 s de build propre + 49 s de tests).
PURGE ?=

# Les contrôles de localisation (lot MN2) : les tests de l'outillage Python
# d'abord — `Tools/l10n/test_lint.py` n'était lancé par aucune cible, et un
# `add-strings.py` ou un `lint.py` cassé passait inaperçu jusqu'au jour où il
# servait —, puis le lint du catalogue. `gate` passe par ici.
.PHONY: check-l10n
check-l10n:
	python3 -m unittest -q Tools/l10n/test_lint.py
	./Tools/l10n-lint.sh

.PHONY: gate
gate:
	@if [ -n "$(PURGE)" ]; then \
	    echo "gate : purge de .build (debug, release, les deux architectures)"; \
	    rm -rf .build/debug .build/release \
	           .build/x86_64-apple-macosx/debug .build/x86_64-apple-macosx/release \
	           .build/arm64-apple-macosx/debug .build/arm64-apple-macosx/release; \
	fi
	$(MAKE) check-docs check-changelog check-ranking
	./Tools/l10n-lint.sh
	$(MAKE) ci-unit
	$(MAKE) ci-integration
	$(MAKE) ci-bundle ARCHS=$$(uname -m)
	$(MAKE) ci-bundle-i18n
	@echo "gate : tout est vert — la fusion peut partir"
