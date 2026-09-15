# Le guide de Fouine

Fouine est une application de recherche locale pour macOS. Elle parcourt les
dossiers que vous lui désignez, extrait le texte de chaque document, et vous
rend une page par ses mots ou par son sens. Rien ne quitte votre Mac.

- [1. La fenêtre principale](#1-la-fenêtre-principale)
- [2. Aperçu](#2-aperçu)
- [3. Emporter les résultats](#3-emporter-les-résultats)
- [4. La carte Index](#4-la-carte-index)
- [5. La fenêtre Votre index](#5-la-fenêtre-votre-index)
- [6. Tous vos documents](#6-tous-vos-documents)
- [7. La mise à jour automatique](#7-la-mise-à-jour-automatique)
- [8. La barre des menus](#8-la-barre-des-menus)
- [9. Options de recherche et filtres](#9-options-de-recherche-et-filtres)
- [10. Citer une page](#10-citer-une-page)
- [11. Les réglages](#11-les-réglages)
- [12. Fouine dans Spotlight](#12-fouine-dans-spotlight)
- [13. Fouine dans Raccourcis et Siri](#13-fouine-dans-raccourcis-et-siri)
- [14. Raccourcis clavier](#14-raccourcis-clavier)
- [15. Le menu Aide](#15-le-menu-aide)

---

## 1. La fenêtre principale

La fenêtre se divise en trois panneaux :

| Panneau | Ce qu'il porte |
|---|---|
| **Barre latérale** (gauche) | la carte « Index », l'interrupteur de mise à jour automatique, vos dossiers, les options de recherche et les filtres |
| **Résultats** (centre) | les documents trouvés, dépliables page par page, avec l'extrait, vos mots surlignés et l'origine du texte |
| **Aperçu** (droite) | le document sélectionné, ouvert à la bonne page, les occurrences surlignées |

Tant qu'aucun dossier n'a été ajouté, la fenêtre affiche un écran d'accueil qui
invite à en désigner un. Sa dernière ligne s'adresse à qui se sert d'un
assistant IA : pour utiliser Fouine avec Claude, Codex, Antigravity ou un autre,
demandez à l'assistant d'installer le MCP de Fouine. Le bouton **Copier la
demande pour votre assistant**, juste dessous, met toute la demande dans le
presse-papiers, prête à coller dans l'assistant : la commande à lancer, avec
l'emplacement réel de la ligne de commande de Fouine dans l'application, ce
qu'elle configure (Claude Desktop, Claude Code, Cursor, Codex, Antigravity) et
ses options, de sorte que l'assistant n'a besoin de rien d'autre. Fouine attend
d'avoir lu l'état réel de vos dossiers avant d'afficher l'interface, ce qui
évite tout clignotement.

**Si vous refusez l'autorisation que macOS demande** au moment d'ajouter ce
premier dossier, ou si les droits du fichier l'interdisent, le dossier n'est pas
ajouté et Fouine le dit. L'alerte porte alors **deux gestes** en plus d'« OK » :
**« Ouvrir les Réglages Système »**, qui va droit au volet Confidentialité et
sécurité ▸ Fichiers et dossiers, et **« Réessayer »**, qui repropose le panneau
de choix du dossier. Un dossier introuvable ou vide n'offre pas ces deux
boutons : il n'y a rien à autoriser.

L'index s'ouvre **au lancement**, que la fenêtre s'affiche ou non : Fouine
ouverte à la session, sans fenêtre, répond quand même dans le panneau de la
barre des menus.

### Déposer un dossier sur l'icône de Fouine

Un dossier pris dans le Finder et **lâché sur l'icône de Fouine dans le Dock**
fait l'une de deux choses, selon que Fouine le connaît déjà ou non.

- **Le dossier est suivi**, ou vit à l'intérieur d'un dossier suivi : la fenêtre
  vient devant et le champ de recherche reçoit le filtre du dossier, prêt à
  compléter, avec le curseur derrière. **Rien n'est lancé** : ce que vous
  cherchez là-dedans, vous seul le savez. L'étiquette posée est celle du
  **dossier suivi**, pas celle du sous-dossier déposé, le filtre ne sachant
  désigner que les dossiers de votre liste.
- **Personne ne suit ce dossier** : Fouine **demande**, « Chercher dans
  “Factures” avec Fouine ? », « Fouine va lire ce dossier et le tenir à jour. »,
  avec **« Ajouter ce dossier »** et **« Annuler »**. C'est la différence avec le
  dépôt sur la **liste des dossiers de la barre latérale**, qui ajoute sans rien
  demander : là, on vise la liste, ce qui dit déjà « ajoute-le » ; sur l'icône du
  Dock, on vise l'application, et le même geste peut vouloir dire « cherche ».
  Plusieurs dossiers lâchés d'un coup tiennent dans une seule demande. Une fois
  ajouté, le dossier suit le chemin ordinaire : aucune lecture n'est lancée
  d'autorité, c'est « Mettre à jour maintenant » ou la mise à jour automatique.

Un **fichier** déposé sur l'icône ne fait rien, et sans un mot : Fouine cherche
dans des dossiers, elle n'ouvre pas les documents. Elle n'apparaît d'ailleurs
jamais dans le « Ouvrir avec » d'un dossier, le double-clic restant au Finder ;
l'icône du Dock accepte le dépôt, c'est tout.

### Le champ de recherche

Le champ annonce **« Cherchez dans vos documents »**. La syntaxe, guillemets
pour une phrase exacte, astérisque pour un préfixe, tiret devant un terme pour
l'exclure, est dans son infobulle et dans son aide parlée. Trois fautes de
frappe ordinaires ne trouvaient rien sans un mot ; une ligne sous le champ les
nomme :

| Ce qui est tapé | Ce qui s'affiche |
|---|---|
| `"energie` | Un guillemet n'est pas fermé. |
| `pres:` (ou `pres:` suivi d'un seul mot) | « pres: » attend deux mots. |
| `-energie` | Une recherche qui ne fait qu'exclure ne trouve rien. |

Rien ne s'affiche pour une requête simplement infructueuse : la ligne dit une
faute de forme, jamais un reproche.

### Quand rien n'est trouvé

Sous **« Aucun résultat pour “…” »**, Fouine propose les gestes qui, dans cet
état, peuvent encore ramener quelque chose, et eux seuls :

- **« Tolérer les fautes de frappe »**, si le réglage n'est pas déjà sur
  « toujours » ;
- **« Retirer les filtres »**, si un filtre, une facette ou une portée est
  actif ;
- **« Chercher aussi par le sens »**, si le modèle est prêt et l'interrupteur
  éteint.

Puis la phrase « Essayez moins de mots, ou vérifiez l'orthographe. » Chaque
geste change le réglage qu'il annonce et relance la recherche. Fouine ne change
jamais de règle toute seule. Dans cet état, les sections de facettes vides ne
s'affichent pas : elles ne feraient que pousser ces gestes hors de vue.

### Ce qu'on peut faire d'un résultat

- **Clic droit** : « Afficher dans le Finder », « Ouvrir » (dans l'application
  habituelle), « Rechercher dans ce document », et, seulement si des pages de ce
  document attendent d'être lues, « Lire ses pages scannées en premier ».
  S'ajoutent « Ouvrir l'aperçu dans sa propre fenêtre » et « Copier une référence
  vers cette page ».
- **Glisser** une ligne vers Mail, un dossier du Finder ou une application de
  bibliographie : c'est le **fichier** qui part.
- **Espace** sur la ligne sélectionnée : le Coup d'œil de macOS, comme dans le
  Finder.
- **Double-clic** ou **⌘⏎** : la page dans sa propre fenêtre d'aperçu.

Les boutons de la barre d'outils (tri, export, « Dans les résultats ») et ceux
de l'aperçu ne sont pas dans le parcours de **Tab** : c'est le comportement
normal de macOS tant que Réglages Système ▸ Clavier ▸ « Accès clavier complet »
est éteint. Une fois cette option activée, Tab les atteint tous.

### Les comptes, et la liste

Au-dessus de la liste, une ligne dit ce qui a été trouvé et en combien de temps
(« 29 037 pages dans 776 documents · 120 ms »).

Quand **« Chercher aussi par le sens »** est allumé, les deux recherches ne
partent plus ensemble : Fouine cherche d'abord les mots, **affiche ces
résultats**, puis interroge le sens. Pendant cette seconde étape, les comptes
restent lisibles et un tourniquet paraît à côté, avec « recherche par le
sens… », ou, au tout premier essai, « préparation de la recherche par le sens :
la première prend quelques secondes… ». Quand le sens répond, la liste est
**reclassée** : les deux recherches sont fondues, l'ordre change, et des pages
qui ne portent aucun des mots tapés peuvent apparaître. Tant que le sens n'a pas
répondu, « Charger plus » attend, une tranche de plus arrivant dans une liste
sur le point d'être refaite. Une nouvelle frappe annule les deux recherches.

Chaque document trouvé porte, à droite de son nom, le nombre de ses pages
présentes dans la liste. Fouine montre d'abord les **meilleures pages de chaque
document**, pour qu'un seul ouvrage de six cents pages ne remplisse pas l'écran
à lui seul : un livre dont trois cents pages répondent n'en affiche donc que
quelques-unes.

Quand c'est le cas, le compte devient un **geste** : « 3 pages sur 300 · Les voir
toutes ». Un clic restreint la recherche à ce document et ramène toutes ses pages
trouvées, de la première à la dernière. Une pastille « dans “nom du document” »
apparaît alors sous le champ de recherche ; la refermer d'un clic rend la
recherche à l'ensemble des dossiers. Sous cette pastille, le compte redevient un
simple compte : il n'y a plus d'ailleurs où aller, et les pages suivantes
s'obtiennent par « Charger plus » en bas de la liste.

Le compte reste **honnête** dans tous les cas : tant que Fouine n'a pas fini de
compter les pages trouvées dans tout le document, il annonce « pages chargées »
et rien de plus ; quand tout est à l'écran, il n'affiche qu'un seul nombre et ne
propose aucun geste.

**Aucun pourcentage sur les lignes.** Fouine n'affiche pas de « pertinence :
47 % ». Le chiffre qui existait rapportait le score d'une page au meilleur score
de la tranche chargée : il changeait à chaque « Charger plus » et n'avait pas le
même sens d'une recherche à l'autre. Ce qui reste, et qui est vrai : l'**ordre**
des documents, et la phrase « Trouvé parce que… » sous la ligne sélectionnée.

---

## 2. Aperçu

Le panneau de droite montre la page trouvée. Son en-tête porte le **nom du
document** et, en dessous, le chemin **abrégé**, le même que la liste des
résultats. Le chemin entier est dans l'infobulle, à la demande, et nulle part
ailleurs.

**Quatre sortes d'aperçu**, selon ce que le document est :

| Ce qu'on voit | Pour quels documents |
|---|---|
| La **page du PDF**, avec les mots surlignés | `.pdf` |
| Une **image de la page**, rendue depuis le fichier | archives de bandes dessinées, `.docx`, `.pptx`, `.xlsx`, images, maquettes Figma et InDesign |
| Le **document tel que macOS le dessine** | `.rtf`, `.doc`, `.odt`, Pages, Numbers, Keynote, pages web, `.csv`, `.tsv`, `.svg`, `.ai`, anciens `.xls` et `.ppt` |
| Le **texte retenu par Fouine**, mots cherchés en évidence | tout le reste : EPUB, DjVu, carnets, sous-titres, boîtes aux lettres, fichiers texte et code |

Au-dessus de l'aperçu, un sélecteur **« Document | Texte »** passe de l'un à
l'autre dès qu'il y a les deux. « Document », c'est ce que montre la barre
d'espace du Finder, la mise en page, les images, les couleurs, mais **les mots
cherchés n'y sont pas mis en évidence** : c'est macOS qui dessine la page,
Fouine n'y a pas la main, et l'infobulle du sélecteur le dit. Le dernier choix
vaut pour tous les documents **jusqu'à la fermeture de Fouine** ; il ne se range
nulle part dans les réglages, pour ne pas changer l'affichage d'un mois sur
l'autre sans que rien ne le dise.

Ce mode « Document » **commence toujours à la première page** pour les documents
que macOS dessine (`.rtf`, `.doc`, `.odt`, Pages, pages web…) : c'est macOS qui
tient le rendu, il n'y a pas moyen de lui demander une page. Un **PDF**, lui,
s'ouvre bien à la page trouvée, parce que c'est Fouine qui le dessine.

**« Ouvrir le document »**, le bouton en haut à droite de l'aperçu, ouvre le
fichier dans l'application qui l'ouvrirait depuis le Finder, et **à la page que
Fouine montre, quand cette application sait y aller**. Cela ne vaut que pour les
**PDF** : la « page 3 » d'un livre numérique dépend du corps de texte choisi par
le lecteur, et celle d'un enregistrement est une tranche de dix minutes inventée
par Fouine.

| Ce qui ouvre vos PDF | Ce qui se passe |
|---|---|
| **Aperçu**, le lecteur d'usine de macOS | le document s'ouvre à sa première page |
| **Chrome**, **Edge**, **Brave**, **Vivaldi**, **Opera**, **Arc**, **Firefox** | le document s'ouvre à la page trouvée |
| **Safari** | le document s'ouvre à sa première page |
| un autre lecteur | le document s'ouvre comme un double-clic l'ouvrirait |

Aperçu **ne sait pas** ouvrir un PDF à une page donnée : macOS n'offre aucun
moyen de le lui demander, et ce n'est pas quelque chose que Fouine peut
contourner. L'infobulle du bouton le dit sans rien promettre, « Ouvrir dans
l'application par défaut — à la page 412 quand elle le permet ». Quand la page
ne peut pas être demandée, le document s'ouvre comme avant, sans message et sans
attente ; si quelque chose empêche l'ouverture à la page, Fouine ouvre le
document tout court plutôt que de ne rien faire.

Pour ouvrir vos PDF à la page trouvée, il faut donc changer l'application qui
ouvre les PDF : dans le Finder, clic droit sur un PDF ▸ « Lire les
informations » ▸ « Ouvrir avec » ▸ choisir le navigateur ▸ « Tout modifier ».

**D'un mot trouvé au suivant.** Sous le numéro de page, une ligne dit combien de
fois chaque mot cherché apparaît sur la page : une **pastille de la couleur du
mot**, le mot, le nombre, soit « azote 3 ». Un mot et les formes que Fouine
cherche avec lui (« polymère », « polymères ») partagent une couleur et un seul
compte ; un mot absent de la page n'a pas de pastille. Cinq au plus tiennent sur
la ligne, les autres sont dans l'infobulle. « 400+ » signale que le surlignage
s'est arrêté à 400 occurrences de ce mot sur la page.

Sur la page d'un **PDF**, la même ligne porte **« 3 / 27 »** et deux chevrons :
**⌘G** va à l'occurrence suivante, **⇧⌘G** à la précédente, ou menu Édition ▸
« Occurrence suivante » / « Occurrence précédente ». Les occurrences se
parcourent dans l'ordre où on les lit, de haut en bas puis de gauche à droite, et
l'occurrence atteinte est sélectionnée. **Le parcours reste dans la page** :
après la dernière, on revient à la première, et pour changer de page, on fait
défiler le PDF. Sur une page lue sur une image, chaque ligne où un mot a été
trouvé compte une fois. En mode **Texte**, seules les pastilles s'affichent : ce
panneau ne sait pas défiler jusqu'à un mot, et un « 3 / 27 » sans geste possible
promettrait un saut qui ne viendrait pas.

**Un son ou une vidéo** a son **lecteur**, et sa transcription en dessous. Le
texte est coupé en paragraphes qui portent chacun leur **horodatage**
(« 12:40 ») : chacun est un bouton qui envoie le lecteur à ce passage. Ouvrir un
résultat place la tête de lecture au début du passage trouvé et **ne démarre
rien** : un son qui part tout seul dans une salle ou un train est une mauvaise
surprise. Les flèches « page précédente » et « page suivante » parcourent
l'enregistrement par tranches de dix minutes, comme les pages d'un livre.

**Quand le disque n'est pas branché**, l'aperçu montre le texte que Fouine avait
gardé et le dit en une ligne : « Le disque qui contient “Livres” n'est pas
branché. Voici le texte que Fouine avait gardé. », avec un bouton **« Copier ce
texte »**. Les autres pages du document restent consultables : le texte vient de
l'index, pas du disque.

Quand la recherche est restreinte à un document, le bouton **« Quitter ce
document »** la rend à l'ensemble des dossiers.

**Les fenêtres d'aperçu détachées**, celles du double-clic, du panneau de la
barre des menus et des liens `fouine://`, suivent deux règles : **une fenêtre par
document** (un second lien vers le même ouvrage change la page de sa fenêtre et
la ramène devant) et **trois au plus** (au-delà, la fenêtre la moins récemment
consultée sert au nouveau document). Un PDF de plusieurs centaines de pages coûte
cher en mémoire ; trois ouverts côte à côte sont un usage, dix oubliés dans la
journée sont un problème.

**Une page qui n'existe plus.** Un lien cité il y a un an peut désigner la page
99 999 d'un document depuis raccourci. Fouine ouvre alors la **première page** et
le dit : « La page 99 999 n'existe plus dans ce document. »

**« Relire cette page »** (clic droit sur la page). Le geste n'apparaît que si le
texte de la page affichée a été **lu sur une image**, ce que l'en-tête dit déjà, à
côté du numéro de page. Une page dont le document portait le texte, ou une page
transcrite depuis un son, n'a pas d'image à relire.

Au clic, la page est remise en attente et une ligne s'affiche sous l'aperçu :
**« Cette page sera relue à la prochaine lecture des scans. Son texte ne changera
que si vous venez de cocher sa langue dans Réglages ▸ Indexation. »** Là encore,
rien ne démarre : c'est la lecture des pages scannées qui la reprendra. Si l'index est
occupé par une écriture : « L'index est en train de se mettre à jour. Réessayez
dans un instant. »
La ligne disparaît dès qu'on change de page.

---

## 3. Emporter les résultats

### Exporter (⇧⌘E, ou le bouton de partage au-dessus de la liste)

Le panneau d'enregistrement propose **trois formats** et dit, en toutes lettres,
ce qui part : « Export : 200 lignes — les résultats chargés, sur 29 037 pages
trouvées. » C'est le **jeu chargé** qui est exporté, dans l'ordre affiché, tri et
filtres compris, jamais un total que l'on n'a pas vu à l'écran.

| Format | Pour quoi faire |
|---|---|
| **CSV (tableur)** | Numbers, Excel, LibreOffice. Colonnes `path, page, score, snippet, root, modified, link`, en anglais et stables : c'est de la donnée, qu'un script relit. |
| **JSON (script)** | les mêmes champs, pour un traitement automatique. |
| **Markdown (notes)** | un carnet (Obsidian, Bear, Notion), un document Word, une bibliographie. |

Le fichier Markdown est un titre, puis **une ligne par page trouvée** :

```
# Fouine — chlorure (3 résultats)

- [Chimie organique — CAPES tome 2.pdf, page 87](fouine://open?…) — … l'extrait …
```

La référence cliquable est **exactement celle de « Copier la référence »**, et
l'extrait est coupé à deux cents caractères. Ni tableau, ni en-tête technique :
le fichier se colle tel quel dans un carnet.

**« Copier toutes les références » (⌥⌘C**, menu Édition, sous « Copier la
référence de cette page »**)** met dans le presse-papiers une référence par
résultat chargé, dans l'ordre affiché. Sans résultat, l'élément de menu est
éteint.

### Trier

Le menu de tri au-dessus de la liste range les documents par **pertinence** (le
défaut), **date de modification** (récent ou ancien d'abord), **nom de fichier**
ou **chemin**.

Dès qu'un autre ordre que la pertinence est choisi, Fouine **charge tout le jeu
avant de trier** : trier les deux cents premiers résultats d'un fonds de
vingt-neuf mille pages ne rendait pas les deux cents plus récents, mais les plus
pertinents remis en ordre, et « le document le plus récent qui parle de X »
n'avait pas de réponse. Pendant le chargement, la ligne sous les compteurs
annonce **« Chargement de tous les résultats avant de les trier… »** ; le sélecteur
reste actif, et revenir à « pertinence » interrompt tout.

Le chargement s'arrête à **deux mille résultats**, une poignée de secondes sur le
fonds de référence. Au-delà, Fouine le dit plutôt que de laisser croire à un
classement complet : **« Tri par date ↓ sur les 2 000 premiers résultats, sur
29 037 pages trouvées. »** Quand tout tient sous le plafond, il n'y a plus rien à
avouer et la ligne disparaît. Une nouvelle recherche arrête le chargement en
cours.

La recherche par le sens ne pagine pas : elle rend un jeu déjà complet, et son
tri est donc toujours entier.

### Recherches enregistrées

L'historique (le pictogramme d'horloge, à droite du champ) retient les quarante
dernières requêtes, puis les oublie. Pour garder « mes factures 2025 » d'un mois
sur l'autre, son premier élément est **« Enregistrer cette recherche… »** :
Fouine propose comme nom la requête elle-même, qu'on remplace par ce qu'on veut.

Les recherches enregistrées apparaissent dans la barre latérale, section
**« Recherches enregistrées »**, au-dessus des filtres rapides, et seulement s'il
y en a. Un clic rejoue la recherche ; un clic droit propose **« Renommer… »** et
**« Retirer »**. On en change la place en la faisant glisser vers le haut ou vers
le bas ; Fouine garde le nouvel ordre. Cinquante au plus ; au-delà, la plus
ancienne sort.

**Ce qui est retenu, et ce qui ne l'est pas.** La requête **telle qu'elle a été
tapée**, préfixes compris : `dossier:Factures 2025`, `"phrase exacte"`,
`-brouillon` s'enregistrent tels quels. Les **filtres cochés dans la barre
latérale** n'en font pas partie : ils se recochent d'un clic, et surtout ils sont
comptés sur le corpus du moment. Une sélection de dossier enregistrée l'an
dernier pourrait ne plus désigner aucun document, et la recherche rejouée ne
rendrait rien sans dire pourquoi.

---

## 4. La carte Index

En haut de la barre latérale, la carte **« Index »** dit l'essentiel : ce que
fait Fouine, si l'index est à jour, et si un geste est attendu de vous. Elle ne
porte que cela :

- une **phrase d'état** (« À jour », « Lecture des pages scannées »…) et,
  dessous, une **précision** quand il y en a une (« Mis à jour il y a 3 min »,
  « Elles seront lues dès que le Mac sera branché sur le secteur. ») ;
- pendant un travail, une **barre d'avancement** et, si Fouine le sait, le
  **temps restant** (« environ 2 h restantes ») ; ni le nom du document en cours,
  ni le compte des pages, qui changent sans cesse et vivent dans la fenêtre
  « Votre index » ;
- **au plus un bouton**, quand un geste est attendu ;
- la phrase de **place disque**, seulement quand Fouine risque de ne plus avoir
  la place de finir ;
- en dernière ligne, le lien **« Détails… »**, qui ouvre la fenêtre **« Votre
  index »**, où tout le reste se trouve.

Sous la carte, l'interrupteur « Mettre l'index à jour automatiquement ».

**Le bouton « Arrêter ».** Il répond tout de suite : au clic, il se désactive, un
petit tourniquet paraît à côté de la phrase, et celle-ci dit ce que Fouine
attend, **« Arrêt — “cours.mp4” se termine… »** quand un seul document est en
cours de lecture, **« Arrêt — 3 documents se terminent… »** quand il y en a
plusieurs. Fouine lit jusqu'à quatre documents à la fois : ce sont ceux-là qu'on
attend, et l'attente ne dure que quelques secondes. Une lecture en cours
s'interrompt entre deux pages (PDF, DjVu) ou pendant la mise par écrit d'un
enregistrement, au lieu d'aller jusqu'au bout. Un document ainsi interrompu
**n'est ni lu ni mis en échec** : il reste à faire, et la prochaine mise à jour
le reprend depuis le début. Rien n'est perdu, rien n'est à moitié écrit. La
lecture des pages scannées et la préparation de la recherche par le sens
s'arrêtent de la même façon, avec leurs propres phrases.

### États de la carte

Un seul état à la fois, choisi dans cet ordre : vérification, aucun dossier,
passe lancée depuis l'application, geste attendu, autre programme qui écrit, mise
à jour automatique, à jour.

| Titre affiché | Ligne secondaire | Signification | Bouton |
|---|---|---|---|
| **Vérification…** | — | Fouine lit l'état de l'index au lancement | aucun |
| **Aucun dossier à indexer** | — | aucun dossier n'a été ajouté | Ajouter un dossier… |
| **Mise à jour de l'index** | le temps restant quand il est connu | parcours des dossiers, extraction du texte | Arrêter *(passe lancée depuis l'application)* |
| **Lecture des pages scannées** | « Environ 2 h restantes » | reconnaissance du texte des pages scannées | Arrêter *(idem)* |
| **Préparation de la recherche par le sens** | le temps restant quand il est connu | préparation des pages pour la recherche par le sens | Arrêter *(idem)* |
| **L'index se met à jour** | « Un autre programme écrit dans l'index ; la recherche fonctionne quand même. » | la ligne de commande met l'index à jour | aucun |
| **À jour — N pages scannées à lire** | « Elles seront lues dès que le Mac sera branché sur le secteur. » (ou : dès que le mode Économie d'énergie sera désactivé, dès que le Mac aura refroidi, dès que l'autre programme aura terminé, dès que tous les dossiers pourront être lus) | le texte est à jour ; la lecture des pages scannées attend que la machine s'y prête | aucun *(« Lire les pages scannées… » est dans la fenêtre « Votre index »)* |
| **Fouine n'a pas le droit de lire « … »** | « Ses documents restent consultables. Autorisez Fouine dans Réglages Système ▸ Confidentialité et sécurité ▸ Fichiers et dossiers… » | macOS refuse la lecture du dossier | Autoriser l'accès… |
| **Le disque contenant « … » n'est pas branché** | « Ses documents restent consultables. Branchez le disque… » | le dossier est sur un disque absent | Revérifier |
| **La mise à jour automatique attend votre accord** | « Autorisez Fouine dans Réglages Système ▸ Général ▸ Ouverture et extensions. » | macOS attend votre confirmation | Ouvrir les Réglages Système |
| **La mise à jour automatique ne démarre pas** | « La relancer suffit en général… » | le service n'a jamais donné signe de vie, ou s'est arrêté | Relancer la mise à jour automatique |
| **Plusieurs copies de Fouine sont installées** | « Ne gardez que celle du dossier Applications… » | deux Fouine.app se disputent la place | Relancer la mise à jour automatique |
| **La mise à jour automatique est indisponible** | « Fouine doit être installée dans le dossier Applications… » | l'application n'est pas dans Applications | Afficher dans le Finder *(la copie à déposer dans Applications)* |
| **À jour** | « Mis à jour il y a 3 min » | rien à faire | aucun |
| **À jour — N pages scannées à lire** | « Elles sont lues automatiquement quand le Mac est branché et au repos. » | le texte est à jour, les pages scannées suivront | aucun |
| **Mise à jour manuelle** (— N pages scannées à lire) | « Fouine ne met l'index à jour que lorsque vous le demandez. » | la mise à jour automatique est éteinte | Mettre à jour maintenant |

Un service de mise à jour automatique vivant mais silencieux depuis quelques
minutes (Mac sorti de veille) est montré **« À jour »**, pas en panne : seul un
service qui n'a jamais écrit ou dont le processus a disparu déclenche « ne
démarre pas ».

### Ce que l'essai ajoute à la carte

- **Pendant l'essai**, une ligne discrète en bas de la carte : « Essai : 12 jours
  restants · **Acheter** ». Rien d'autre : pas de fenêtre au lancement, pas de
  compte à rebours en gros caractères, pas de rappel qui revient. Le reste de la
  carte dit ce qu'il dirait de toute façon.
- **À la fin de l'essai**, la carte remplace son bouton d'action par la phrase
  « Votre essai est terminé : la recherche fonctionne toujours, l'index ne se met
  plus à jour » et deux boutons, **« Saisir une clé de licence… »** et
  **« Acheter »**. Le bouton « Mettre à jour maintenant » disparaît : le proposer
  alors qu'il ne peut plus rien faire serait une promesse qui casse au clic.
- **L'interrupteur ne change pas**, et ce n'est pas un oubli : la mise à jour
  automatique se tait d'elle-même, et griser l'interrupteur obligerait à
  expliquer pourquoi à un endroit où la carte vient déjà de le dire.
- **Si le vendeur a désactivé votre clé**, la carte dit « Cette clé a été
  désactivée par le vendeur » et les deux mêmes boutons reviennent.

---

## 5. La fenêtre Votre index

On l'ouvre par le lien **« Détails… »** de la carte « Index », ou par **Fenêtre ▸
Votre index**. Il n'y en a qu'une : la rouvrir ramène celle qui existe. Elle
relit tout à l'ouverture, puis se tient à jour tant que Fouine est au premier
plan. Pendant une mise à jour de l'index, ses comptes suivent : ils sont relus
toutes les dix secondes au plus, et une fois encore quand la mise à jour se
termine. Elle dit, en quatre parties, ce que la carte ne dit plus.

**Ce que fait Fouine.** La phrase d'état de la carte, avec sa précision
**complète**, le nom du document en cours compris, la barre d'avancement et le
compte des pages (« 312 / 1 200 pages · environ 2 h restantes »). Les gestes de
l'état sont là aussi : le bouton de la carte et, en second, en lien, **« Lire les
pages scannées… »** quand des pages scannées attendent. Un geste qui ouvre une
feuille ramène d'abord la fenêtre principale.

**Mise à jour automatique.** Le même interrupteur **« Mettre l'index à jour
automatiquement »** que sous la carte ; la phrase qui dit ce qu'il fait
(« Fouine vérifie vos dossiers de temps en temps et met l'index à jour toute
seule, même quand sa fenêtre est fermée. ») ; la réponse du dernier geste,
confirmations comprises (« La mise à jour automatique est activée. macOS peut
vous demander de confirmer dans Réglages Système ▸ Général ▸ Ouverture. ») ; et
où se règlent les moments où elle travaille : **Réglages ▸ Indexation ▸ Quand
mettre à jour automatiquement**.

**Ce que contient l'index.**

- **« 1 527 documents · 408 951 pages »**, deux nombres groupés de la même façon.
  **Cette ligne est un geste** : elle ouvre « Tous vos documents ». Elle reste un
  simple texte quand les statistiques n'ont pas encore répondu ou que l'index est
  vide, ouvrir une liste de zéro ligne n'apprenant rien.
- Quand des documents n'ont pas pu être lus, **« 23 documents illisibles »**, qui
  ouvre la fenêtre qui les liste, et ce que c'est : « Ces fichiers sont dans vos
  dossiers, mais Fouine n'a pas pu les lire. Vos fichiers ne sont pas modifiés. »
- Quand la mise à jour automatique a lu de nouvelles pages pendant que Fouine
  était fermée : **« Depuis votre dernière visite : 4 200 nouvelles pages »**. La
  ligne vaut pour la session, sans croix : on ouvre cette fenêtre pour lire.
- La place qui reste sur le disque, **seulement si elle manque** (ci-dessous).

**Quand la place manque sur le disque.** Cette ligne n'apparaît que si la place
vient à manquer sur le disque qui porte l'index. Fouine ne compare jamais l'index
à une « taille prévue » : ce chiffre est une promesse de conception, et un nombre
« prévu » se lit comme un plafond par qui n'a pas la spécification sous les yeux.

| Situation | Phrase | Où |
|---|---|---|
| plus de 5 Go libres | *aucune ligne* | — |
| moins de 5 Go libres | « Il reste 3,2 Go libres sur votre disque ; votre index en occupe 2,15 Go » | la fenêtre « Votre index » |
| moins de 1 Go libre, ou moins que ce que la préparation du sens doit encore écrire | « Il ne reste que 800 Mo libres sur votre disque et votre index en occupe 2,15 Go : Fouine risque de manquer de place pour le finir. Libérez de l'espace, ou retirez un dossier dont vous n'avez plus besoin » | la fenêtre **et** la carte « Index » |

Trois choses à savoir sur cette ligne. **Rien ne s'arrête jamais**, ni
l'indexation, ni la lecture des pages scannées, ni la préparation de la recherche
par le sens : Fouine avertit, et c'est le système qui refusera d'écrire le jour
où le disque est vraiment plein. Il n'y a **aucun bouton** : le geste possible
est de libérer de l'espace ou de retirer un dossier, et la phrase le dit. Et la
place libre est celle que **macOS promet à une écriture importante**, le chiffre
du Finder, purge automatique comprise, relue en même temps que les comptes de
l'index ; si le volume ne répond pas, la ligne se tait plutôt que d'annoncer un
reste faux. Les tailles sont écrites comme le Finder les écrit (« 2,15 Go »).

**Pages scannées sans texte lisible.** Cette partie n'apparaît que s'il y en a.
Une page scannée peut avoir été **lue** sans que Fouine en tire un texte sûr ;
son document est bien dans l'index, ce ne sont donc pas des « documents
illisibles ». Deux cas, chacun sur sa ligne :

```
3 157 pages scannées où Fouine n'a reconnu aucun texte
    Le plus souvent des pages blanches, des images ou des dessins.
1 053 pages scannées lues avec des lettres incertaines
    Scans pâles ou de travers, écriture manuscrite, polices inhabituelles :
    une recherche peut manquer certains de leurs mots.
```

**Il n'y a pas de bouton pour les relire, et c'est voulu.** Fouine les a lues du
mieux qu'elle peut : une nouvelle lecture passe par la même reconnaissance, avec
les mêmes réglages, et rend le même résultat. Les remettre en file, mesuré sur un
index réel, laisse les mêmes pages en place une fois la file vidée.

**Le seul cas où relire change quelque chose** : un document écrit dans une
langue qui n'est pas cochée dans **Réglages ▸ Indexation ▸ Langues des documents
scannés**. Cochez-la, puis faites un clic droit sur la page dans l'aperçu et
choisissez **« Relire cette page »**. La ligne sous l'aperçu le rappelle.

En ligne de commande, `fouine ocr requeue [--doubtful|--no-lines]` remet toujours
ces pages en attente, et les deux comptes sont dans `fouine status`.

---

## 6. Tous vos documents

On y entre par le compte de la fenêtre « Votre index », ou par **Fenêtre ▸ Tous
vos documents (⌘⇧L)**. Il n'y en a qu'une : la rouvrir ramène celle qui existe.

- un champ **« Filtrer par nom »** (il cherche dans le nom **et** le dossier ; la
  liste se relit 300 ms après la dernière frappe) ;
- un menu **« Dossier »** (les dossiers surveillés, ou « Tous les dossiers ») ;
- un menu **« Type »** (les extensions réellement présentes, la plus fréquente
  d'abord, ou « Tous les types ») ;
- un menu d'ordre : **« Récents »** (défaut), **« Nom »**, **« Pages »** ;
- le **compte** de tout ce qui répond aux filtres, pas seulement ce qui est à
  l'écran ;
- la liste, par tranches de **200**, avec « Charger plus (N restants) ».

Une ligne porte le nom du fichier, le dossier **abrégé**, le nombre de pages et
la date en clair (« Modifié hier »). Le chemin entier reste dans l'infobulle. Les
documents que Fouine n'a pas pu lire **sont dans la liste**, avec la phrase qui
dit pourquoi, les cacher recréerait le trou d'avant ; ceux qui attendent encore
portent « Pas encore lu — il le sera à la prochaine mise à jour ».

**Un clic** ouvre l'aperçu du document à sa première page, dans sa propre fenêtre
(mêmes règles qu'ailleurs : une fenêtre par document, trois au plus). **Un clic
droit** offre « Afficher dans le Finder », « Ouvrir » et « Rechercher dans ce
document », ce dernier refermant la fenêtre et posant la portée dans la fenêtre
principale.

Quand aucun document ne répond : **« Aucun document ne correspond »**.

La même liste s'obtient en ligne de commande par `fouine list`.

---

## 7. La mise à jour automatique

Placé directement sous la carte « Index », l'interrupteur **« Mettre l'index à
jour automatiquement »** confie la surveillance de vos dossiers au système. C'est
le même interrupteur dans la fenêtre « Votre index » : un seul nom, un seul
geste.

Quand vous le basculez, **rien ne s'écrit dessous** : la carte dit déjà le nouvel
état, et une attente d'accord de macOS a son propre état (« La mise à jour
automatique attend votre accord »). Seul un **refus** s'y affiche. L'interrupteur
revient alors en arrière, et la phrase dit pourquoi : aucun dossier (« Ajoutez
d'abord un dossier : il n'y aurait rien à tenir à jour. »), lecture des dossiers
pas encore autorisée, ou Fouine installée ailleurs que dans le dossier
Applications. La fenêtre « Votre index » garde la réponse du dernier geste,
confirmations comprises.

Dès qu'un document est créé, modifié ou supprimé dans un dossier indexé, Fouine
prend la modification en compte en quelques secondes.

Pour préserver l'autonomie et les performances du Mac, la lecture des pages
scannées attend que la machine s'y prête :

1. le Mac est branché sur le secteur ;
2. le mode Économie d'énergie est désactivé ;
3. le Mac ne chauffe pas ;
4. aucun autre programme n'écrit dans l'index ;
5. tous les dossiers sont lisibles.

Les trois premières se règlent dans Réglages ▸ Indexation. Dès que l'une de ces
conditions fait défaut, la carte dit laquelle (« Elles seront lues dès que le Mac
sera branché sur le secteur. ») et la lecture reprend d'elle-même ensuite. Pour
ne pas attendre, **« Lire les pages scannées… »**, dans la fenêtre « Votre
index », lance une passe tout de suite, avec une durée à choisir.

---

## 8. La barre des menus

Fouine dispose d'une présence discrète dans la barre des menus de macOS.

**L'icône change avec ce que fait l'index**, et trois formes suffisent :

| Icône | Quand | Ce que dit la ligne d'état du panneau |
|---|---|---|
| **Loupe** | rien en cours : à jour, mises à jour manuelles, en pause, aucun dossier, contrôle en cours | « À jour », « Mise à jour manuelle », « Aucun dossier à indexer » |
| **Flèches circulaires** | l'index travaille | « Mise à jour de l'index », « Lecture des pages scannées », « Préparation de la recherche par le sens » |
| **Triangle** | Fouine attend un geste de vous | « Fouine n'a pas le droit de lire “…” », « La mise à jour automatique attend votre accord »… |

Une icône qui change dit qu'il se passe quelque chose ; la ligne d'état du
panneau dit quoi. VoiceOver annonce l'icône par cette même phrase d'état, jamais
par « icône ».

**Le panneau.** Un clic sur l'icône ouvre un petit panneau. **Le curseur est déjà
dans le champ** : on tape.

- **Les résultats arrivent pendant la frappe**, après un quart de seconde de
  silence. Une ligne = une page : le nom du fichier, son numéro de page, et
  l'extrait sur une ligne. Les pages d'un même document se suivent. Si vous avez
  éteint **« Chercher pendant que je tape »** (§ 11), la frappe ne cherche plus :
  le premier **⏎** cherche dans le panneau, le suivant ouvre la fenêtre sur la
  même question.
- **Huit pages au plus.** Quand il y en a davantage, une ligne **« Tout voir dans
  Fouine »** ferme le panneau et pose la question dans la fenêtre, où il y a les
  filtres, les facettes et l'aperçu.
- **Un clic sur une page** l'ouvre dans sa propre fenêtre d'aperçu, la même que
  le double-clic sur un résultat, à la même page, avec les mêmes surlignages.
- **⌘-clic** ouvre le fichier dans son application habituelle.
- **↑ et ↓** parcourent les lignes, **⏎** ouvre celle qui est désignée ; sans
  ligne désignée, **⏎** passe la question à la grande fenêtre.
- **Échap** ferme le panneau. **⌘Q** quitte Fouine.

Ce panneau ne cherche que dans les **mots** de vos documents : la recherche par
le sens, qui demande de charger un modèle, reste dans la fenêtre, un panneau
devant répondre tout de suite. Il ne touche à rien de ce qui est ouvert à côté :
les filtres, la sélection et la requête de la grande fenêtre restent où ils sont.
Le raccourci global **⌥⌘F** ouvre toujours la fenêtre.

**Sous les résultats**, une ligne d'état puis deux gestes, et rien d'autre. La
ligne est la phrase d'état de la carte « Index », en gris, sans bouton : elle
explique la forme de l'icône. Puis **« Ouvrir Fouine »**, qui affiche ou ramène
au premier plan la fenêtre principale (aussi dans le menu Fenêtre, ⌘0), et
**« Quitter Fouine »**. Quand la mise à jour automatique est allumée, une bulle
d'aide rappelle que l'index continue de se mettre à jour tout seul après la
fermeture ; éteinte, la bulle ne s'affiche pas, puisque plus rien ne tournerait.
⌘Q fonctionne depuis le panneau, mais son glyphe n'y est pas affiché : un panneau
de barre des menus n'est pas un menu, et macOS n'y dessine pas les raccourcis.

**Fermer la fenêtre ne quitte pas Fouine** : si l'option de barre des menus est
active, fermer la fenêtre masque l'icône du Dock et laisse l'application
disponible dans la barre des menus. « Ouvrir Fouine » ou ⌥⌘F rouvre la fenêtre.
Un réglage permet aussi de lancer Fouine dès la connexion à votre session,
directement dans la barre des menus, sans ouvrir la fenêtre.

---

## 9. Options de recherche et filtres

### Fautes de frappe

Un sélecteur à trois positions ajuste la tolérance aux erreurs d'orthographe ou
aux coquilles de reconnaissance :

| Option | Comportement |
|---|---|
| **Jamais** | recherche stricte mot à mot |
| **Auto** (défaut) | tolérance seulement si un mot ne donne aucun résultat exact |
| **Toujours** | recherche élargie systématiquement aux variantes proches |

### Chercher aussi par le sens

La recherche par le sens ramène les passages dont le sujet correspond à votre
requête, même sans mots communs. L'interrupteur **« Chercher aussi par le sens »**
réunit les pages trouvées par vos mots et celles trouvées par le sens. Si vos documents
n'ont pas encore été préparés pour elle, un bouton lance la préparation. Le
mécanisme et ce qu'il vaut : la page « Chercher » de la documentation.

### Filtres

Sous le champ de recherche, cinq sections restreignent la vue :

- **« Dossiers »** : filtrer par dossier d'origine ;
- **« Types de fichiers »** : filtrer par format (PDF, DOCX, EPUB…) ;
- **« Langues »** : filtrer par langue du document (la section n'apparaît qu'à
  partir de deux) ;
- **« Origine du texte »** : texte tapé, pages scannées lues par Fouine,
  reconnaissances antérieures, parole mise par écrit. Ces quatre noms sont les
  mêmes partout : facette, en-tête de l'aperçu, pictogramme d'une ligne, lecture
  d'écran ;
- **« Modifié en »** : l'année de **dernière modification du fichier**, pas
  l'année de l'ouvrage. Un livre de 2003 recopié sur le Mac en 2024 est rangé
  sous 2024, et l'infobulle de la section le dit.

**« Daté de »** paraît au-dessus de « Modifié en » dès que des résultats portent
une date : l'année inscrite **dans le document lui-même** (PDF, Word, EPUB,
courriel, photo). Cocher une année ne garde que ces documents-là. C'est un filtre
d'affichage, comme « Modifié en », et son infobulle le dit.

Chaque section affiche au plus **douze valeurs**, les plus fournies ; au-delà,
une ligne annonce « Seules les 12 premières sont affichées ». Toutes relancent la
recherche, et les totaux annoncés les suivent, sauf « Modifié en » et « Daté
de », qui ne trient que les résultats déjà affichés.

« Origine du texte » est la seule qui porte sur la **page** : un même livre peut
mêler des pages tapées et des planches scannées, et le filtre rapide « Scans
seulement » pose exactement le même filtre.

### Filtres rapides

Au-dessus des facettes, quatre puces couvrent les filtres que l'on pose le plus
souvent : **« Modifié cette année »**, **« Modifié ces 5 dernières années »**,
**« PDF seulement »**, **« Scans seulement »**. Les fenêtres de date sont des
années civiles. Les puces pilotent les mêmes états que les facettes : décocher
« pdf » dans « Types de fichiers » éteint la puce « PDF seulement », et **« Tout
effacer »** les retire toutes.

### Pourquoi ce résultat

Sous l'extrait du résultat **sélectionné**, et sous lui seul, une ligne discrète
dit pourquoi cette page est là : « Trouvé parce que cette page contient
“cinétique” et “chimie”. », « Trouvé par une orthographe proche : “converslon” →
“conversion”. », « Aucun de vos mots n'est sur cette page, mais elle parle du
même sujet. », « Trouvé par vos mots et par le sens. »

Aucun nombre n'y figure. Les mots cités sont **les vôtres**, et un terme exclu
n'est jamais nommé : ce serait désigner exactement ce que vous avez demandé
d'écarter.

---

## 10. Citer une page

Une page trouvée peut être **citée** : son nom, son numéro de page, et un lien
qui ramène droit dessus. C'est ce qui permet de renvoyer quelqu'un, ou soi-même
six mois plus tard, à la bonne page d'un ouvrage de mille pages.

Deux gestes, les mêmes mots aux deux endroits : dans le panneau d'aperçu, le
bouton **« Copier une référence vers cette page »**, et, par un clic droit sur
n'importe quelle ligne de résultat, le sous-menu du même nom. Au clavier,
**⇧⌘C** (menu Édition ▸ **« Copier la référence de cette page »**) agit sur le
résultat sélectionné.

Chacun propose **« Copier la référence »** et **« Copier le lien »**. La
référence fait deux lignes :

```
Chimie organique — CAPES tome 2.pdf, page 87
fouine://open?path=/Users/…/Chimie%20organique.pdf&page=87
```

Le lien est seul sur sa ligne, à dessein : Mail, Notes, Pages et Word ne rendent
cliquable une adresse que lorsqu'elle n'a rien après elle. Pour la même raison,
les **parenthèses** d'un nom de fichier y sont écrites `%28` et `%29` : un ouvrage
universitaire sur deux porte son année entre parenthèses, et ces mêmes détecteurs
coupent une adresse sur une parenthèse fermante.

**Une page de son ou de vidéo se cite par son moment.** « Page 2 » d'un cours de
deux heures ne renvoie personne nulle part : la référence dit alors le moment, et
le lien le porte.

```
cours de chimie 12 mars.m4a, 12:40
fouine://open?path=/Users/…/cours%20de%20chimie.m4a&page=2&t=760
```

Le paramètre **`t`** est un nombre de **secondes** depuis le début de
l'enregistrement : le moment où la tête de lecture se trouvait quand vous avez
copié la référence. À l'ouverture, Fouine y place le lecteur, sans démarrer. Seule
l'application émet `t` ; `fouine search --json` et le serveur d'assistance citent
la page.

**Ce que fait un lien `fouine://`.** Cliqué depuis n'importe quelle application,
il ramène Fouine au premier plan et ouvre la page dans sa propre fenêtre
d'aperçu. Quand le lien porte aussi la recherche qui avait mené à cette page,
celle-ci est rejouée dans le document et les mots sont de nouveau surlignés.

**« Fouine ne connaît pas ce document ».** Un lien cité l'an dernier peut désigner
un document déplacé, renommé, ou qui n'est plus dans un dossier suivi. Fouine le
dit alors, avec le nom du fichier. Une mise à jour de l'index rattrape la plupart
de ces cas.

Le bouton **« Ouvrir le fichier »** n'apparaît que pour un **document** que
Fouine aurait pu indexer : un fichier ordinaire, **sous l'un des dossiers que
vous suivez**, et qui n'est pas un programme. Un lien peut venir de n'importe où,
d'une page web, d'un courriel, et son auteur choisit le chemin qu'il porte : il
n'y a donc aucune raison d'ouvrir une application, un dossier, un script, ni quoi
que ce soit qui vive hors de vos dossiers. Quand un fichier existe à ce chemin
sans remplir ces conditions, la fenêtre le dit, « Il est en dehors des dossiers
que Fouine surveille : Fouine ne l'ouvrira pas. », et ne propose aucun bouton. Un
`.rtfd`, qui est techniquement un dossier, reste un document et s'ouvre
normalement.

Le lien voyage aussi dans l'export des résultats (colonne `link`), dans `fouine
search --json` et dans les réponses du serveur d'assistance : c'est ainsi qu'un
assistant peut citer une page de vos documents de façon vérifiable.

---

## 11. Les réglages

Les réglages s'ouvrent par ⌘, et comptent sept onglets.

### Général

- **« Garder Fouine dans la barre des menus »** (actif par défaut) : maintient
  l'icône dans la barre des menus et évite de quitter Fouine à la fermeture de la
  fenêtre. « La petite icône en haut de l'écran permet de chercher dans vos
  documents et d'ouvrir Fouine. Elle montre aussi ce que fait l'index. »
- **« Chercher pendant que je tape »** (actif par défaut) : « Les résultats
  apparaissent au fil de la frappe. Éteint, appuyez sur Entrée pour chercher. »
  Le réglage vaut pour la fenêtre **et** pour le panneau de la barre des menus, et
  il s'applique dès la touche suivante. Éteint, la frappe ne fait plus que
  proposer des mots sous le champ ; c'est **⏎** qui lance la recherche. Rien
  d'autre ne change : mêmes filtres, mêmes résultats, même historique.
- **« Ouvrir Fouine à l'ouverture de session »** : démarre l'application en
  arrière-plan à la connexion.
- **« Me prévenir quand toutes les pages scannées sont lues »** : envoie une
  notification macOS à la fin du traitement. **L'autorisation est demandée
  d'abord** : Fouine coche la case seulement si macOS a dit oui. Bannière
  ignorée, refus, ou autorisation retirée plus tard dans les Réglages Système, et
  la case revient à zéro avec une ligne sous elle, « macOS n'a pas encore autorisé
  les messages de Fouine », et le bouton **« Ouvrir les Réglages Système »**.
  L'état est relu à chaque ouverture de l'onglet : la case ne promet jamais un
  message qui ne viendra pas.
- **Spotlight** : voir le § 12.
- **Raccourci clavier** : rappel de la combinaison ⌥⌘F.

### Licence

Le deuxième onglet, juste après Général : c'est celui qu'on ouvre après avoir
acheté, et le seul endroit où un essai qui se termine se dénoue.

- **L'état, en une phrase** : « Essai : 12 jours restants », « Votre essai est
  terminé : la recherche fonctionne toujours, l'index ne se met plus à jour »,
  « Sous licence — clé se terminant par ·····XYZ456 » avec la date du dernier
  contrôle, « Cette clé a été désactivée par le vendeur », ou, quand la
  vérification mensuelle apprend que vous avez libéré ce Mac depuis votre
  espace client, « Ce Mac a été libéré depuis votre espace client. Saisissez de
  nouveau votre clé pour l’utiliser ici. »
- **Un champ « Clé de licence » et un bouton « Activer »**, inactif tant que le
  champ est vide. Le champ accepte ce que vous collez : espaces, retours à la
  ligne et minuscules sont nettoyés avant l'envoi.
- **Un bouton « Acheter Fouine — 39 € »**, qui ouvre la page de paiement dans
  votre navigateur. Fouine ne demande jamais un numéro de carte elle-même.
- **Une fois la clé posée**, le champ laisse la place à **« Désactiver ce Mac »**,
  qui demande confirmation : « Ce Mac ne comptera plus parmi vos 3 activations.
  Vous pourrez l'activer à nouveau plus tard. »
- **Les refus s'affichent sous le champ, en une phrase et un geste** : « Pas de
  connexion : connectez-vous à Internet, puis réessayez. », « Cette clé n'est pas
  reconnue. Vérifiez qu'il n'y a pas de faute de frappe, ou retrouvez-la dans le
  courriel que Creem vous a envoyé. », « Cette clé est déjà utilisée sur 3 Mac.
  Désactivez-en un depuis les réglages, ou depuis votre espace client Creem. »,
  « Le service de licence est indisponible pour le moment. Votre essai continue ;
  réessayez plus tard. »
- **Le pied de l'onglet dit ce qui part et quand**, comme celui des mises à jour :
  la clé et le nom de ce Mac, à l'activation, à la libération, et lors d'une
  vérification silencieuse par mois. Rien pendant que Fouine indexe ou cherche.
  Détail : la page « Vie privée » de la documentation.

Le menu **Fouine ▸ Saisir une clé de licence…** ouvre directement cet onglet, et
**À propos de Fouine** rappelle l'état en une ligne.

### Dossiers

- La liste de vos dossiers avec leur nom et leur emplacement, et les boutons pour
  en ajouter ou en retirer un.
- Par dossier : **« Lire ses pages scannées en premier »** (les pages scannées de
  ce dossier passent avant celles des autres), et **Ce que Fouine ignore…**
  (ci-dessous).
- La case de gauche active ou désactive le dossier.
- Quand un réglage est grisé (Fouine hors du dossier Applications, valeur imposée
  par l'environnement), la raison s'affiche **en clair sous le contrôle**, et pas
  seulement au survol.

**Garder une partie d'un dossier en dehors.** Sous chaque dossier, **Ce que
Fouine ignore…** ouvre une feuille qui dit en clair ce que Fouine laisse de côté
dans ce dossier : « Le dossier « Santé » », « Tous les fichiers .md », « Les
fichiers nommés « INDEX.md » ». Une croix au bout d'une ligne cesse de l'ignorer.
Trois boutons en ajoutent une, sans taper de motif :

- **Ignorer un dossier…** ouvre un sélecteur de dossier sur ce dossier. Choisissez
  un dossier à l'intérieur. Le dossier lui-même est refusé (« C'est le dossier
  entier. Pour ne plus l'indexer, décochez-le dans la liste. »), un dossier
  ailleurs aussi.
- **Ignorer un type de fichier** est un menu des types de fichier réellement
  présents dans ce dossier, les plus nombreux d'abord, chacun avec son compte.
- **Ignorer les fichiers nommés…** affiche un champ pour un nom de fichier, par
  exemple `INDEX.md`.

Ce qui est déjà ignoré ne s'ajoute pas deux fois : la feuille dit « Fouine ignore
déjà cet élément. » Avant d'enregistrer, une phrase dit ce qui va se passer :
« Environ 41 documents sortiront de l'index à la prochaine mise à jour. Vos
fichiers ne sont pas touchés. » Retirer une ligne dit « Ce que vous n'ignorez
plus revient à la prochaine mise à jour. » Rien ne change avant **Enregistrer**.
Ensuite, si la mise à jour automatique est éteinte, **Mettre à jour maintenant**
applique le changement tout de suite ; si elle est allumée, Fouine l'applique
d'elle-même dans quelques minutes.

**Fouine n'écrit rien dans votre dossier.** Elle garde ces règles dans son
propre index : elles partent si vous retirez le dossier de Fouine (le décocher
les garde). Un petit fichier nommé **`.fouineignore`** en haut d'un dossier
marche toujours, pour un dossier que vous partagez ou copiez sur un autre Mac :
une ligne par chose à laisser de côté — un nom de dossier suivi d'une barre
oblique (`Santé/`), une sorte de fichier (`*.md`), ou le nom exact d'un fichier
(`INDEX.md`). Ses lignes apparaissent dans la même feuille, grisées, avec « vient
du fichier .fouineignore de ce dossier » et sans croix : Fouine ne fait que lire
ce fichier, une ligne se retire donc en le modifiant. Fouine applique les deux
ensemble. Ce qu'ils nomment sort de l'index, et les recherches cessent de le
trouver. **Vos fichiers ne sont jamais touchés**, seulement ce que Fouine en
retient.

**Applications.** Sous la liste des dossiers, une case par application dont
Fouine sait lire les notes : **Apple Notes**, **Bear** et **Anki**. Cochée, Fouine copie le
texte des notes dans son propre dossier pour pouvoir les chercher. La ligne sous
les cases le dit, et dit aussi que **rien ne quitte ce Mac**.
Décocher efface les copies et retire les notes de l'index ; vos notes, elles, ne
sont jamais modifiées. Sous chaque case, l'état en clair : « pas installée sur ce
Mac » (la case est grisée), « Fouine n'a pas le droit de lire ces notes » avec un
bouton **« Ouvrir les Réglages Système »** (Apple Notes range ses notes dans un
endroit protégé, ce qui demande l'**Accès complet au disque**, un autre volet que
« Fichiers et dossiers »), ou « N notes trouvables ».

Ajouter le dossier d'Anki, d'Apple Notes ou de Bear avec « Ajouter un dossier… »
ne marche pas, et l'alerte le dit : elle invite à cocher l'application ici, et
son bouton **« Ouvrir les Réglages »** ouvre cet onglet.

Fouine montre ces notes comme elles sont **dans leur application**, jamais comme
la copie qu'elle s'est fabriquée : une note trouvée porte son titre et l'icône
de Notes ou de Bear, et s'ouvre dans son application — dans l'aperçu, le bouton
« Afficher dans le Finder » devient **« Ouvrir dans Notes »** (ou « Ouvrir dans
Bear »), parce que ce que l'on veut modifier, c'est la note. L'aperçu montre son
texte, et le Coup d'œil, le glisser-déposer et « Ouvrir » ne sont pas proposés :
ils ne montreraient que la copie de Fouine. Dans « Vos dossiers » et dans la
liste ci-dessus, le dossier d'une application porte l'icône de cette
application ; son menu n'a ni « Afficher dans le Finder », ni « Renommer », ni
« Retirer » : l'application s'éteint ici, avec sa case.

Les cartes **Anki** arrivent paquet par paquet : chaque paquet est un document de
la liste, sous son nom, avec l'icône d'Anki et, au-dessus, les paquets dans
lesquels vous l'avez rangé (« Anki › Chimie »). Ses pages sont ses **cartes** :
la liste dit « carte 12 » et « 74 cartes », l'aperçu « carte 3 sur 642 », et une
référence copiée cite la carte. Une recherche qui touche quarante cartes d'un
même paquet montre donc ce paquet une fois, avec « Les voir toutes » pour
parcourir les cartes. Le nom d'un paquet n'est pas un mot de ses cartes : un
paquet se trouve par son nom, comme un fichier. Anki peut rester ouvert pendant que
Fouine le lit ; une carte ajoutée il y a une minute est trouvée à la mise à jour
suivante. Dans l'aperçu, le bouton devient **« Ouvrir dans Anki »** : Anki pour
Mac ne sait pas ouvrir une carte donnée depuis l'extérieur, il ouvre donc Anki,
où la carte est à une recherche. L'aperçu montre le texte de la carte, puis ses
**images**, lues dans le dossier d'Anki lui-même : une image effacée dans Anki
n'est simplement pas montrée. Les mots écrits dans une image ne sont pas
cherchés, seulement le texte de la carte ; sons, indices et étiquettes restent
dans Anki.

**Notion et Craft** n'ont pas de case : leurs notes ne se lisent pas sur ce Mac.
Exportez vos pages en Markdown, puis ajoutez le dossier d'export avec « Ajouter
un dossier… ». Une page exportée de Notion se rouvre dans Notion depuis l'aperçu.

### Indexation

- **« Quand mettre à jour automatiquement »** : trois critères cochables
  (seulement quand le Mac est branché, pas en mode économie d'énergie, pas quand
  le Mac chauffe).
- **« Préparer aussi la recherche par le sens en arrière-plan »**, décochée par
  défaut. Cochée, Fouine produit elle-même, par courtes tranches et sous les mêmes
  trois critères, ce que la recherche par le sens réclame, une fois toutes les
  pages scannées lues. Sous la case, une phrase dit quand cela se fera, ou, si le
  modèle n'est pas encore téléchargé, où le prendre.
- **« Langues des documents scannés »** : les langues que Fouine s'attend à
  trouver sur les pages scannées, la plus probable d'abord. Ce sont aussi les
  langues de la mise par écrit des enregistrements. Les langues portent **leur
  nom**, rangé par ordre alphabétique de ce nom, et le code technique passe en
  infobulle.
- **« Indexer les images (photos, scans, fichiers RAW d'appareil photo) »**,
  cochée par défaut. Cochée, les photos, les scans et les fichiers RAW des
  dossiers suivis entrent dans l'index et passent par la reconnaissance de texte.
  Deux phrases l'accompagnent, et elles disent l'essentiel : **chaque image passe
  par la reconnaissance de texte**, ce qui peut occuper Fouine des heures sur un
  gros dossier de photos ; et **Fouine lit le texte des documents photographiés**,
  la photo d'un ticket, d'un courrier, d'une page, tandis que les enseignes, les
  étiquettes et les écritures décoratives lui échappent souvent.
- **« Indexer les fichiers son et vidéo (titres, artistes, chapitres…) »**,
  cochée par défaut ; décochez-la si un dossier suivi est une bibliothèque
  musicale plutôt qu'un fonds documentaire. Cochée, les titres, artistes, albums, paroles et chapitres d'un enregistrement
  deviennent cherchables sans en écouter une seconde. Sous elle, **« Mettre aussi
  par écrit ce qui est dit »**, cochée par défaut elle aussi : Fouine écoute sur
  ce Mac et écrit les mots, rien
  n'est envoyé nulle part ; comptez à peu près la durée de l'enregistrement, et
  la langue doit être installée dans Réglages Système ▸ Clavier ▸ Dictée (sinon le
  document est écarté en le disant). **« Durée maximale mise par écrit
  (minutes) »** borne l'effort (120 par défaut ; au-delà, seules les métadonnées
  entrent). Une page vaut dix minutes d'enregistrement, chaque paragraphe précédé
  de son horodatage `[mm:ss]`.

### Recherche par le sens

L'activation de la recherche par le sens, l'état du modèle (téléchargement unique
de 220 Mo, stocké localement), le décompte des pages préparées et un bouton
**« Préparer la recherche par le sens… »**. Quand Fouine s'en charge toute seule
(la case ci-dessus cochée, le modèle installé, la mise à jour automatique
active), ce bouton disparaît, remplacé par « Fouine s'en occupe toute seule,
quand l'ordinateur est branché et au repos. » : le travail se fait, il n'y a rien
à cliquer.

### Mises à jour

Une recherche manuelle par **« Rechercher les mises à jour… »**, et un
interrupteur de vérification périodique, désactivé par défaut. Aucune donnée
personnelle ni adresse relative à vos documents n'est jamais transmise. **Quand la
vérification n'aboutit pas** (pas de réseau, serveur muet), la ligne « Dernière
vérification » dit « impossible de joindre le serveur », et l'onglet ajoute :
« Fouine n'a pas pu vérifier s'il existe une version plus récente. Réessayez plus
tard : Fouine continue de fonctionner. » Détail : la page « Mises à jour » de la
documentation.

### Avancé

- Ce que Fouine fait à la fois : combien de documents elle lit ensemble, combien
  de pages scannées, et combien de documents quand elle travaille en
  arrière-plan.
- La durée d'un lot de reconnaissance, en minutes.
- La période de re-vérification de l'état, en secondes.
- La portée de la tolérance aux fautes de frappe : pages scannées seules, ou
  ensemble de l'index.
- **« Installer l'outil en ligne de commande… »** : pose le lien symbolique.
- **« Ouvrir le journal d'activité »** : ouvre le fichier de diagnostic.
- L'emplacement et le volume occupé par l'index, avec un bouton pour l'afficher
  dans le Finder.

---

## 12. Fouine dans Spotlight

Spotlight, la loupe en haut à droite de l'écran (⌘-Espace), ne lit pas tout : un
PDF scanné, un DjVu, une bande dessinée ou une archive de courriel ne lui rendent
**aucun texte**. Fouine, elle, les a lus. Elle donne donc à Spotlight ce qu'elle a
lu, et Spotlight le montre comme n'importe quel autre résultat.

**Ce qui apparaît.** Le nom du fichier, les premières lignes du texte, le nom du
dossier suivi par Fouine. Cliquer ouvre **Fouine**, sur la page où sont vos mots
quand Spotlight transmet ce que vous avez tapé, sur la première page sinon. Effet
de bord agréable : Fouine ne cherche pas dans les noms de fichiers, Spotlight si,
et les documents donnés deviennent donc trouvables par leur nom.

**Pourquoi seulement les scans, par défaut.** Donner un `.docx` ou un `.pdf`
ordinaire, que macOS lit déjà, ferait apparaître **deux** résultats pour le même
fichier. Fouine ne donne donc que ce que Spotlight ne sait pas lire : les
documents dont au moins une page vient de la reconnaissance de caractères, les
enregistrements dont Fouine a mis la parole par écrit (Spotlight lit le titre
d'une vidéo, jamais ce qui s'y dit), et les formats mesurés comme muets
(`.djvu`, `.cbz`, `.cbr`, `.epub`, `.ai`, `.sketch`, `.fig`, `.indd`). Le second
bouton radio, **« Tous les documents que Fouine a lus »**, lève cette réserve.

**Les deux boutons.** **« Mettre Spotlight à jour maintenant »** efface ce que
Fouine avait donné et redonne tout : c'est le seul geste qui retire de Spotlight
un document effacé du disque depuis, l'index ne gardant aucune trace d'une
suppression. **« Retirer les documents de Fouine de Spotlight »** (avec
confirmation) rend le Mac exactement à ce qu'il était : vos documents ne sont pas
touchés, et la recherche de Fouine continue de les trouver.

**Ce qui prouve qu'un don a eu lieu.** Sous les deux boutons, une ligne :
« Dernière remise le <date> · <N> documents », lue dans l'index lui-même. Sans
compte (remise faite par une version antérieure), la date seule ; avant la
première remise, ou après un retrait, « Aucune remise pour l'instant ». C'est la
seule vérification possible depuis l'extérieur : `mdfind` n'interroge pas l'index
de Spotlight que Fouine alimente.

**Quand la mise à jour se fait toute seule.** À chaque fin de mise à jour de
l'index et à chaque ouverture de Fouine. La commande `fouine` et la mise à jour
automatique en arrière-plan ne peuvent pas parler à Spotlight : ce qu'elles
indexent part à la prochaine ouverture de l'application.

**Ce que cela coûte.** Fouine donne au plus **un mégaoctet de texte par
document**, les premières pages entières qui tiennent, jamais une page coupée au
milieu. Sur le corpus de recette (1 527 documents, surtout des livres scannés),
la première remise transmet 561 Mo à Spotlight en 25 secondes, en tâche de fond ;
ensuite, chaque mise à jour ne touche que ce qui a changé et se compte en
millisecondes. Ce plafond se règle en ligne de commande.

**Rien ne quitte le Mac.** L'index de Spotlight est local, comme celui de
Fouine ; la désinstallation retire les documents donnés avant d'effacer quoi que
ce soit (la page « Vie privée » de la documentation).

---

## 13. Fouine dans Raccourcis et Siri

L'application **Raccourcis**, livrée avec macOS, sait enchaîner des actions.
Fouine y ajoute **trois actions**, qui apparaissent dès l'installation quand on
tape « Fouine » dans la liste des actions.

| Action | Ce qu'elle prend | Ce qu'elle rend |
|---|---|---|
| **Rechercher dans Fouine** | ce que vous cherchez, et combien de résultats (10 par défaut, 50 au plus) | une liste de pages trouvées |
| **Ouvrir dans Fouine** | une page trouvée | rien : Fouine s'ouvre sur cette page |
| **Obtenir le texte d'une page** | une page trouvée | le texte que Fouine a lu sur cette page |

Chaque page trouvée porte son **nom de fichier**, sa **page**, un **extrait**, le
**dossier** d'où elle vient, son **chemin** et son **lien Fouine** : six variables
que l'on glisse dans l'action suivante.

Un premier enchaînement, retrouver une page et l'ouvrir : *Rechercher dans
Fouine* → « cinétique de réticulation », puis *Choisir dans la liste*, puis
*Ouvrir dans Fouine*. Un second, se fabriquer une note à partir d'un cours :
*Rechercher dans Fouine* → « électrolyse », 5 résultats, puis *Répéter chaque
élément*, puis *Obtenir le texte d'une page*, puis *Créer une note* (Notes), ou
*Envoyer un courriel*, ou *Ajouter au presse-papiers*.

Sur **macOS 26 et au-delà**, ces mêmes actions se proposent directement dans
Spotlight : ⌘-Espace, tapez « Fouine », et « Rechercher dans Fouine » est là.

**On peut aussi les dicter à Siri** : « Dis Siri, cherche dans Fouine », ou « Dis
Siri, cherche dans mes documents avec Fouine ». Siri lance l'action, puis
Raccourcis demande *quoi* chercher : une phrase parlée ne peut pas transporter un
mot libre, seule une liste de choix connue d'avance se dictant.

**Ce que ces actions ne font pas.** Elles ne lisent que l'index, jamais le fichier
d'origine : « Obtenir le texte d'une page » rend ce que Fouine a extrait ou
reconnu, pas le PDF. Elles n'indexent rien et ne modifient rien. Elles cherchent
**dans le texte**, comme la fenêtre, sans la recherche par le sens, celle-ci
chargeant un modèle qui met deux secondes à s'ouvrir, ce qu'un raccourci ne
supporte pas. Enfin, seule « Ouvrir dans Fouine » met l'application au premier
plan ; les deux autres travaillent sans rien déranger, même si Fouine n'était pas
ouverte.

**Si Fouine n'a encore rien lu**, l'action le dit (« Fouine n'a encore rien lu.
Ouvrez Fouine et ajoutez un dossier. ») au lieu de rendre une liste vide, qui se
lirait comme « ce mot n'est nulle part ».

---

## 14. Raccourcis clavier

| Raccourci | Action |
|---|---|
| **⌘F** | activer et sélectionner le champ de recherche dans la fenêtre |
| **⌥⌘F** | raccourci global : afficher Fouine et chercher depuis n'importe quelle application |
| **⇧⌘E** | exporter les résultats de la recherche |
| **⇧⌘C** | copier la référence de la page sélectionnée (nom, page, lien) |
| **⌥⌘C** | copier toutes les références des résultats chargés |
| **Tab** | donner le focus à la liste des résultats depuis le champ de recherche ; ↑ et ↓ y déplacent la sélection, ⏎ ouvre |
| **⌘⏎** | ouvrir l'aperçu de la page sélectionnée dans sa propre fenêtre |
| **Espace** | coup d'œil sur le document sélectionné, depuis la liste des résultats |
| **⌘G** | aperçu d'un PDF : aller à l'occurrence suivante des mots cherchés sur la page (menu Édition ▸ Occurrence suivante ; après la dernière, retour à la première) |
| **⇧⌘G** | aperçu d'un PDF : revenir à l'occurrence précédente |
| **⌘?** | ouvrir le guide de Fouine (menu Aide) |
| **⌘,** | ouvrir les Réglages |
| **⌘W** | fermer la fenêtre principale (l'application reste dans la barre des menus) |
| **⌘0** | rouvrir la fenêtre principale (menu Fenêtre ▸ Ouvrir Fouine) |
| **⌘⇧L** | ouvrir « Tous vos documents » (menu Fenêtre) |
| **⌘Q** | quitter l'application |

---

## 15. Le menu Aide

Le menu **Aide** contient **« Guide de Fouine »** (**⌘?**) : il ouvre, dans sa
propre fenêtre, la page que vous lisez. Elle est **fournie avec l'application** :
aucune connexion n'est nécessaire, et rien n'est demandé à Internet pour
l'afficher. Elle existe en français et en anglais, et suit la langue de
l'application.

- Les renvois internes restent dans la fenêtre du guide.
- Un lien vers un site s'ouvre dans **votre navigateur habituel**, jamais dans la
  fenêtre du guide.

**« À propos de Fouine »** (menu Fouine) donne la version, la phrase qui compte,
Fouine lit vos documents sur ce Mac et rien n'en sort, puis trois liens : **la
licence** (source-available, livrée avec l'application), **les composants tiers**
et **le code source** du projet. Les deux premiers ouvrent des fichiers fournis
dans l'application ; le troisième ouvre la page du projet dans votre navigateur.
