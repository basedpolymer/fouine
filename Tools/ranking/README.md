# Banc de classement — protocole

**Pourquoi.** Aucun réglage du classement — plancher de marge, poids du RRF,
profondeur — ne peut être calibré sans jugements humains. Sans eux, on
optimise ce qu'on croit ; l'audit du 02/09/2026 en a fait la démonstration
(C2-01 : la marge `z` classe les requêtes absurdes AU-DESSUS des pertinentes,
l'inverse de l'hypothèse). Ce répertoire fournit l'outillage ; **les jugements
appartiennent au propriétaire du corpus**, une demi-journée environ.

**Trois fichiers, trois scripts.** `queries.txt` : ~40 requêtes réparties en
catégories (une ligne `# nom` ouvre une catégorie). `systems.json` : un
« système » = un nom + des options de `fouine search`. `pool.py` exécute
chaque requête contre chaque système et met les top-10 en commun ;
`annotate.py` fait poser les notes, une touche par page, dans `grades.tsv` ;
`evaluate.py` les lit et rend nDCG@10, P@10 et MRR — par page et par
document — avec un test apparié contre un système de référence.
`test_ranking.py` (`make check-ranking`) prouve les conventions des trois
scripts sur un pool fabriqué.

**Produire le pool.** `fouine search` est en lecture seule et ne prend jamais
le verrou : ceci tourne sans risque sur la base de production.

```sh
python3 Tools/ranking/pool.py --fouine .build/release/fouine \
        --out verif/ranking/$(date +%F)
```

`queries.json` garde la **provenance** du pool : binaire résolu, sa date, sa
version, le commit du dépôt, la base, l'heure, et l'**état du corpus** —
`docs_total`, `pages_indexed`, `pages_vec`, lus dans `fouine status --json` du
même binaire. Ces trois nombres ne sont pas décoratifs : les pools du 05/09 et
du 09/09/2026 ne portent pas sur le même corpus (22 documents indexés le
08/09), et le 0,744 de l'un ne se compare donc pas au 0,541 de l'autre
(RK-14) — **comparer à l'intérieur d'un pool, jamais entre deux**. `pages_vec`
dit sur quelle couverture le canal sémantique a été jugé (67 % le
10/09/2026) : un tiers du corpus lui était invisible. Le pool M1 du 05/09/2026
(10 h 21) a été rendu caduc par un commit de 11 h 58 sans que rien dans le
pool ne le dise : c'est ce qu'il faut pouvoir lire avant de juger. Une
exécution en échec (`timeout`, sortie non nulle) est notée dans `runs/` et
écarte la requête de toutes les moyennes (voir « Évaluer »). `--grades` sur
un fichier qui n'existe pas encore n'est pas une erreur : la même ligne de
commande sert au premier pool et aux suivants.

**Annoter — guidé.** `annotate.py` présente les candidats un à un, requête
par requête et document par document, avec le **texte de la page** (lu par
`fouine mcp --stdio`, lecture seule, sans verrou : la production convient),
les mots de la requête surlignés, et les rangs de chaque système. Une touche
suffit : **0** hors sujet, **1** utile, **2** ce qu'il fallait ; `?` rappelle
le barème. Chaque note est écrite aussitôt dans `grades.tsv`, à côté du pool ;
quitter ne perd rien, relancer reprend.

```sh
python3 Tools/ranking/annotate.py --dir verif/ranking/$(date +%F) --status      # où en est-on
python3 Tools/ranking/annotate.py --dir verif/ranking/$(date +%F) --only-diff   # l'essentiel d'abord
```

L'ordre de passage est celui du **rendement** : d'abord les requêtes dont les
systèmes ne rendent pas le même top-10, parce qu'un candidat classé au même
rang partout apporte le même gain à tous les nDCG et ne départage rien (sur le
pool du 05/09/2026, 236 lignes sur 350). `--only-diff` s'y limite. Une requête
commencée se **finit** : un candidat sans note vaut 0 dans le calcul, passer
n'est pas neutre. Vingt requêtes bien jugées valent mieux que quarante bâclées.

Les jugements vivent **hors du pool**, clé (requête, `doc_id`, page) : la
pertinence d'une page pour une requête ne dépend ni du système ni de la date.
Le même `grades.tsv` sert donc à plusieurs pools — `--grades <fichier>` dans
les trois scripts — et `pool.py --grades` pré-remplit la colonne `grade` quand
on relance le pool avec un système ou un binaire de plus. Conséquence
assumée : l'**idéal** du nDCG se calcule sur toutes les notes connues pour la
requête, y compris des pages qu'aucun système du pool courant n'a rendues —
un système qui rate une page jugée utile ailleurs est pénalisé, uniformément
(convention TREC : les jugements sont la vérité, pas le pool).

Hors terminal (sortie redirigée, `--no-color`), `annotate.py` lit une ligne
par touche : les deux premières « Entrée » passent l'écran d'état puis la
carte de la requête avant le premier candidat.

**Annoter — au tableur.** Ouvrir `candidates.tsv` (tabulations) et remplir la
SEULE colonne `grade` reste possible ; `evaluate.py` la lit aussi. Deux pièges :
un tableur **mange les guillemets** et confond `"energie libre"` avec
`energie libre` — vérifier après export que le fichier a toujours autant de
lignes et sept colonnes ; et l'extrait de 80 caractères ne suffit pas à
séparer « utile » de « ce qu'il fallait ». Laisser vide ce qu'on ne sait pas
juger. Une requête sans aucune note est simplement écartée des moyennes.

**Évaluer.** `python3 Tools/ranking/evaluate.py --dir verif/ranking/<date>`
imprime un tableau Markdown : nDCG@10, P@10, MRR **par page**, puis **nDCG@10
par document** et le nombre de documents distincts du top-10 — l'application
montre des documents, trois pages par document depuis la diversité (lot R1),
et un classement se juge de ce point de vue-là (leçon du 05/09/2026 : un
bonus par document noyait l'écran sans que le top-10 de pages le montre). Le
document prend le rang de sa première page et la meilleure note de ses pages
présentes ; l'idéal vient des meilleures notes par document sur tous les
jugements connus. La dernière colonne — requêtes absurdes ayant ramené au
moins un hit sémantique pur — se lit **sans aucun jugement** : c'est la
mesure directe du bruit du canal sémantique.

Vient ensuite le tableau **« contre la référence »** (`--baseline`, défaut
`lexical`) : écart moyen apparié, victoires / égalités / défaites requête par
requête, et la p-valeur d'un test de permutation par renversement de signe
(2 000 tirages, graine fixe). Sur vingt requêtes, 0,61 contre 0,59 est du
bruit : p < 0,05 se lit « l'écart tient sur ce jeu », au-dessus « on ne sait
pas », et juger d'autres requêtes vaut mieux que relire le chiffre.
`--by-category` ajoute un tableau par famille de requêtes, là où se lit ce
qu'un réglage fait aux guillemets, aux préfixes ou à l'anglais que la moyenne
noie ; `--per-query` donne le nDCG de chaque système requête par requête,
pour voir LESQUELLES basculent. Une requête dont une exécution a échoué dans
`runs/` est écartée pour **tous** les systèmes, et nommée : un classement
vide par panne de mesure vaudrait 0 et se lirait comme un défaut de
classement.

**La catégorie « absurde » ne mesure le bruit que si elle est pure.** Sa
dernière colonne compte les requêtes hors domaine qui ont ramené au moins un
résultat purement sémantique — donc du bruit, par construction. Encore faut-il
qu'aucun document du corpus ne réponde : le corpus du propriétaire contient
`doc_id 1`, la **notice d'un four à micro-ondes avec ses recettes**, et
« recette de tarte aux pommes de ma grand mère » y trouvait une vraie recette
de tarte, notée 1 à juste titre (RK-13). Deux requêtes ont donc été remplacées
le 10/09/2026. Règle pour toute requête absurde ajoutée : **elle ne doit
toucher aucun document, ni par les mots ni par le sens** — se vérifie par
`fouine search '<requête>'` sur la base de production (lecture seule), qui doit
rendre `0 page(s)`. Attention depuis le lot MP1 : une requête à zéro page
exacte est **rejouée en tolérant les fautes**, et la ligne « No exact match »
sur l'erreur standard est ce qui prouve que l'exact n'a rien rendu.

**Les deux réglages du lot RK2, jugés puis armés (11/09/2026).** Le quorum
(relâchement du ET sur *tous* les mots quand la recherche stricte rend moins de
dix pages, RK-04) et le malus des tables des matières (RK-07) ont été livrés
**éteints**, mesurés au banc sous les systèmes `lexical-quorum`, `lexical-toc`
et `lexical-quorum-toc` (pool `rk2-2026-09-11/`, produit avec un
`systems-rk2.json` posé à côté du pool), puis **jugés** : 149 candidats lus
(AUDIT-RK2), quorum **+0,031** nDCG@10 pages (6 V / 43 É / 0 D, p = 0,040), malus
**+0,021** (13 / 33 / 3, p = 0,019 ; +0,101 sur les préfixes), ensemble
**+0,052** (p < 0,001). Ils sont **armés par défaut** depuis : `lexical` les porte,
et ce sont `lexical-noquorum`, `lexical-notoc` et `lexical-noquorum-notoc`
(`--no-quorum`, `--no-demote-toc`) qui servent désormais de témoins —
`lexical-noquorum-notoc` est ce que le pool rk2 appelait `lexical`. Le premier
tour d'un système neuf le sous-estime **par construction** : un candidat que
lui seul remonte n'a aucun jugement, vaut 0 dans le nDCG, et ses chiffres sont
des **planchers** tant que les nouveaux candidats ne sont pas annotés
(`annotate.py --dir … --status` en donne le compte) — c'est exactement ce qui
est arrivé à RK2 (+0,000 lu, +0,031 réel). Sept requêtes ont été ajoutées à
`queries.txt` au passage (quatre paraphrases, trois préfixes).

**Limite connue et assumée.** On n'annote que ce qu'au moins un système a
remonté (méthode TREC dite du *pooling*) : une page qu'aucun système ne trouve
reste invisible aux métriques. Ajouter un système à `systems.json`
oblige donc à relancer `pool.py` et à annoter les nouveaux candidats.
