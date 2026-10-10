# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Mod Factorio 2.0 (Lua 5.2) « Autonomous Car » : une voiture autonome qui construit des ghosts hors réseau de robots, se recharge et se gare seule. Ce fichier est la seule documentation du projet.

**Version en construction.** Le 2026-10-10 le propriétaire a jugé cette version satisfaisante pour les mécanismes en place (déplacement, manœuvre, chemin de secours, construction, recharge, garage, fenêtre des objets manquants) et l'a fusionnée dans `main` ; les problèmes ouverts plus bas et les fonctions à venir restent à traiter. Un mécanisme peut toujours être repris si un test ou le jeu le montre.

## Règles de travail

- Comprendre la cause d'un bug au niveau du tick avant de corriger ; pas de correctif de symptôme.
- Changements petits et chirurgicaux. Réutiliser les helpers et l'API Factorio existants ; pas de second système d'état.
- Le code fonctionne globalement en jeu : une incohérence vue à la lecture n'est pas un bug tant qu'elle n'est pas confirmée en jeu, par un scénario de test ou par le propriétaire.
- Ne lancer les tests que sur demande du propriétaire, et lui demander avant chaque lancement en indiquant la durée approximative (une catégorie de scénarios prend de 1 à 10 minutes). Dans l'environnement cloud, ne pas chercher à exécuter Factorio : le propriétaire lance les scénarios en local. Une vérification statique reste possible sans Factorio (voir « Commandes »).
- Git : `main` est la version de référence choisie par le propriétaire, pas une version validée (voir plus haut). Tout travail se fait sur une branche à part (la créer avant la première modification si on est sur `main`). Ne jamais pousser ni fusionner dans `main` sans demande explicite du propriétaire ; proposer de committer, pousser ou fusionner quand cela semble utile (fin d'un changement cohérent, version prête à valider), puis attendre sa réponse.
- Tenir à jour la liste « Problèmes connus » en bas de ce fichier : ajouter tout problème découvert ; un problème corrigé passe dans « Corrigés, à valider » et n'est retiré qu'après validation du propriétaire. Seul ce que le joueur voit ou peut faire y entre : un changement interne au code (renommage, refactoring sans effet visible) n'a pas à être validé.
- Une idée ou une tâche à garder pour plus tard se note à deux endroits : une ligne dans « À faire » (plus bas) et un commentaire `-- TODO` à l'endroit du code concerné. Retirer les deux quand c'est fait.
- Code, commentaires et messages du script (alertes, `print`) en anglais ; ce fichier en français. Les noms et descriptions des prototypes sont dans `locale/`, en anglais et en français : toute ligne ajoutée ou modifiée l'est dans les deux fichiers.

## Commandes

Pas de build, pas d'interpréteur Lua. Dépôt git privé (branche `main`) ; `.backup/` (état d'avant le dernier grand renommage) est ignoré par git.

- Le mod est chargé depuis ce dossier, dont le nom doit rester `<name>_<version>` de `info.json`.
- Changement runtime : recharger la sauvegarde. Changement de prototype (`data.lua`, `prototypes/`, valeur de `config.lua` lue par un prototype) : redémarrer Factorio.
- Erreurs : `%APPDATA%\Factorio\factorio-current.log`.
- Vérification statique, sans lancer Factorio (quelques secondes) : erreurs de syntaxe et noms globaux mal orthographiés, par le serveur de langage Lua de l'extension VS Code `sumneko.lua`, que `.luarc.json` configure. Un global de Factorio absent de sa liste `diagnostics.globals` s'y ajoute.

```powershell
& (Get-Item "$env:USERPROFILE\.vscode\extensions\sumneko.lua-*\server\bin\lua-language-server.exe")[-1] --check . --checklevel=Warning --logpath="$env:TEMP\lua-check" --metapath="$env:TEMP\lua-check"
```

Sous Linux (environnement cloud, sans Factorio) : `apt-get install lua5.2 lua-check`, puis `luac5.2 -p *.lua prototypes/*.lua` (syntaxe) et `luacheck --std lua52 --no-max-line-length --ignore 143 --globals game script storage defines prototypes helpers util data crash_trigger car_reflection volume_multiplier -- *.lua prototypes/*.lua` (variables non définies ou inutilisées ; doit répondre 0 warning). Le script n'a pas d'autre moyen de s'exécuter : un essai avec une fausse API Factorio ne remplace pas les scénarios.

Scénarios de test (dossier `tests/`, temporaire : à retirer avant publication, le mod n'en charge rien) :

```powershell
testsun.ps1                                  # tous les scénarios, quatre lancements de Factorio
testsun.ps1 movement                         # une catégorie : movement, robustness, construction, energy
testsun.ps1 -Changed                         # les catégories que les fichiers modifiés depuis le dernier commit peuvent affecter
testsun.ps1 maze, garage-exit -Ticks 8000    # des scénarios précis (un lancement par catégorie concernée)
testsun.ps1 -Reference <dossier ou zip>      # compare les traces avec une autre version du mod
tests\show.ps1 construction -Car 132           # changements d'état d'une voiture dans une trace
```

Chaque scénario a une catégorie (champ `category` dans `tests/harness.lua`) ; les scénarios d'une catégorie qu'on lance tournent ensemble dans une seule partie, chacun sur sa surface et avec sa trace (`trace-<scénario>.txt`), pour ne pas lancer Factorio 24 fois : `movement` (17 scénarios, déplacements autour d'obstacles : salles, murs, forêts, labyrinthes, portes), `robustness` (voitures bloquées, pannes, batterie vide), `construction`, `energy` (chargeurs et garages). Une erreur de script arrête toute la catégorie. Un nouveau scénario prend la catégorie de ce qu'il vérifie, et une surface à lui (`new_surface`).

`run.ps1` lance Factorio sans fenêtre ni joueur sur une copie du mod dans `%TEMP%utonomous-car-tests` ; rien n'est écrit dans le dossier Factorio et le jeu peut rester ouvert. Il affiche pour chaque scénario l'erreur de script éventuelle, les événements et le dernier résumé. `-Reference` sert à vérifier qu'un refactoring ne change aucun comportement : Factorio est déterministe, deux versions équivalentes donnent des traces identiques (à scénarios groupés identiques : les numéros d'entités dépendent des scénarios lancés ensemble). La version de référence tourne avec son propre `tests/harness.lua` quand elle en a un, ce qui permet de comparer deux versions dont les noms diffèrent. Les scénarios posent de l'herbe (`grass-1`, friction 1.6) sur leur surface, comme en jeu : sur les tuiles de laboratoire les voitures vont bien plus vite. Les scénarios sont décrits dans `tests/harness.lua`, qui en est la seule liste : `run.ps1` y lit leurs noms, leur durée (22 000 ticks, ou le champ `ticks`) et leur catégorie, `show.ps1` y lit les noms des drapeaux. Ce fichier est greffé à la fin de `control.lua` et utilise ses locales (`on_area_selected`, `names`, les modules) : renommer l'une d'elles impose de le mettre à jour. Un événement `NOSTATE` dans une trace signale le filet de sécurité de `update_car` (voir « Tick »).

## Architecture

### Modules

`config` → `_utils` → `charge`, `park` → `travel` → `ghost` → `control`, et `movement` et `gui` à côté (ils ne dépendent que de `config` et `_utils`). Ce graphe doit rester acyclique : c'est pourquoi `requeue_construction` vit dans `travel.lua` et pourquoi l'arrivée d'une voiture passe par un événement plutôt que par un appel à `control.lua`.

| Fichier | Module | Rôle |
|---|---|---|
| `control.lua` | | événements, suivi des entités, tick |
| `movement.lua` | `movement` | mode de conduite, accélération, direction |
| `travel.lua` | `travel` | trajets, détours de recharge, stuck, abandon |
| `ghost.lua` | `ghost_control` | ghosts, clusters, assignation, construction |
| `charge.lua` | `charger_control` | chargeurs |
| `park.lua` | `garage_control` | garages, réparation lente des voitures garées |
| `gui.lua` | `gui` | fenêtre des objets manquants (raccourci `missing_items_shortcut`) |
| `_utils.lua` | `_utils` | carburant, recherche de l'entité la plus proche, passage en attente (`start_waiting`), deque, alertes, libération d'entités, événement de fin d'étape |
| `config.lua` | | noms et tailles communs aux prototypes et aux scripts, puis réglages |
| `colors.lua` | | couleur que le script donne à chaque voiture posée (un prototype de voiture n'a pas de couleur) |
| `data.lua`, `prototypes/` | | prototypes, un fichier par entité |
| `locale/en`, `locale/fr` | | noms et descriptions affichés en jeu |

### État

`storage.cars[id]` est l'entité, `storage.car_data[id]` son état (créé par `create_car_data` dans `control.lua`) ; même schéma pour chargeurs et garages. Les tables sont créées par `init_storage` au premier tick (qui lance ensuite `on_tick` pour ce même tick : aucun tick n'est sauté après un chargement) ; il n'y a ni `on_init` ni migration, donc un champ ajouté à `car_data` n'existe pas pour les voitures déjà posées.

Voitures, chargeurs, garages et coffres sont suivis dès leur construction (`on_built`), y compris quand une voiture les construit (`script_raised_revive`). Toute entité devenue invalide est libérée par `_utils.release_entity(kind, id)`. Les ghosts sont suivis par `on_object_destroyed`, pas par les événements died/mined.

### Tick

`on_tick` appelle `update_car` pour chaque voiture, qui exécute la première branche vraie, dans cet ordre :

1. batterie vide (`travel.handle_empty`), puis carburant critique (`travel.handle_critical_fuel`)
2. `moving` : `movement.update_mode`, puis `movement.maneuver_tick` si une manœuvre est active, sinon `movement.drive_tick`, puis `travel.is_leg_too_long`
3. `charging`
4. `parking`
5. `building` : un ghost toutes les `config.build_interval` ticks
6. `stuck` : `travel.stuck_tick` (réessai, ou abandon via `ghost_control.abandon`)
7. `waiting` : `end_wait` choisit la suite (reprise du batch, cluster en attente, garage)
8. sinon (aucune branche prise) : filet de sécurité, la voiture repasse en `waiting` et le cas est enregistré (`storage.idle_fallbacks`) ; c'est un bug ailleurs, que les scénarios signalent par `NOSTATE`

`update_mode` fixe `precision_mode`, `emergency_brake`, `high_speed` et `friction_modifier` (recalculé chaque tick, jamais incrémenté), et peut démarrer une manœuvre ; `drive_tick` lit `emergency_brake` et `precision_mode` dans le même tick, l'ordre ne doit pas changer.

### Manœuvre, stuck, batterie vide

La manœuvre (`car_data.maneuver`) est un sous-mode de `moving` : même destination, conduite lente (friction), avant ou arrière. Elle ne démarre que sur un arrêt net (`drive_tick` : vitesse nulle, loin de la destination, plus de `short_delay` après le début du trajet ou la fin de la dernière manœuvre) ; une durée de trajet dépassée (`travel.is_leg_too_long`) va directement au chemin de secours, puis en `stuck`. Une cible derrière la voiture ne déclenche rien : la conduite normale (`drive_tick`) braque jusqu'à ce que la voiture soit alignée (le déclencheur `rear_turn` a été supprimé : il faisait échouer des voitures qui s'en sortaient seules, mesuré avec `u-side`).

Elle choisit d'abord un **cap** (`choose_heading`, gardé dans `maneuver.heading` pendant `short_delay`, la durée d'un arc) : `1 / lookahead_angle` secteurs autour de la voiture, notés par l'espace libre (`measure_free_room`) et la densité (`steering_cost.density`, terme essentiel : sans lui `u-narrow` tombe à 13/20), le plus proche de la destination en cas d'égalité. Ensuite, toutes les `short_delay`, `choose_arc` choisit l'un des six arcs (avant ou arrière × gauche, tout droit ou droite) qui rapproche l'orientation du cap : arc où la voiture tient, puis qui tourne vers le cap (tout droit une fois aligné), puis avant, puis espace libre. Bloquée devant et derrière (aucun arc tout droit n'a de place), elle doit tourner : un arc qui braque compte alors comme libre dès qu'il a de la place. Le braquage passe par `riding_state`, jamais par l'orientation. Un mur en pierre n'a que 0,58 tile d'épaisseur : les sondes sont donc espacées de 0,5 tile, et la zone entre la voiture et le premier point (`maneuver_probe.start`) est sondée à part par `find_entities_filtered` (la voiture se détecterait elle-même avec `can_place_entity`). Une voiture qui roule mais reste sous `speed.stopped` pendant `short_delay` a un obstacle invisible, ou un mur qui l'empêche de tourner (elle pivote autour de son centre) : `back_off` l'envoie dans l'autre sens, tout droit, et elle **longe le mur** dans ce sens (`maneuver.follow` ; ses arcs restent dans cette direction) par tranches d'une longueur de voiture (ou `short_delay`), en tentant un virage entre chaque, jusqu'à ce qu'un virage de `lookahead_angle` réussisse. Un virage qui cale fait continuer dans le même sens ; un calage en ligne droite marque le sens comme bloqué (`maneuver.blocked`, avec la position et l'orientation du calage) et renvoie la voiture dans l'autre. Un sens n'est bloqué que depuis cet endroit : le repère est périmé dès que la voiture s'est éloignée d'une longueur de voiture ou a tourné de `lookahead_angle` (`is_blocked`). Si les deux sens sont bloqués depuis le même endroit (ou si elle ne bouge pas à la fin d'un recul), la manœuvre échoue aussitôt. La raison `blocked` commence directement par ce recul, sans rien noter comme bloqué : une voiture trouvée à l'arrêt n'a pas forcément calé tout droit (son propre frein d'urgence l'arrête aussi). Pour rester loin des murs, `measure_wall_margin` ajoute `steering_cost.margin` par côté où un obstacle longe un point d'échantillon à environ une largeur de voiture (coût de `drive_tick` seulement, quand quelque chose est à portée). Elle finit quand la densité est basse, le devant libre et que la voiture s'est déplacée de `maneuver_min_travel` ; elle n'a qu'un essai, d'au plus `idle_delay` : au-delà elle échoue, la voiture demande alors un chemin (voir plus bas), et s'il échoue ou a déjà été essayé sur ce trajet, elle est `stuck`. Une solution très simple (la manœuvre), puis une plus forte (le chemin), puis le blocage.

Mécanismes essayés puis retirés (campagne du 2026-10-09, `u-side` et `u-narrow` : 20 voitures chacun, départs et orientations variés, 20/20 après retrait) : déclencheur `rear_turn`, hystérésis du cap, interdiction de l'arc complémentaire, `can_turn`, détection `wedged` (voiture « sans issue » sans réessai), déclencheur `no_progress` (et `stuck_min_progress`). Retirés un par un, ils n'apportaient rien ou faisaient perdre des voitures. À l'inverse, le terme de densité du cap, le déclencheur `blocked`, `follow`, la règle « tourner quand on est bloqué devant et derrière » et le chemin de secours font perdre des voitures quand on les retire : à ne pas supprimer sans nouvelle campagne.

Sortie de `high_speed` : `update_mode` mémorise la vitesse d'entrée (`entry_speed`) et lève `slowing` à la sortie ; `drive_tick` freine alors jusqu'à cette vitesse, sans descendre sous `speed.slow`.

Chemin de secours (`car_data.path`, section « Path » de `movement.lua`) : quand la manœuvre a échoué, ou quand un trajet dépasse sa durée (`timeout`), la voiture demande un chemin au pathfinder du jeu (`surface.request_path`, boîte de la voiture agrandie de `PATH_MARGIN`, `low_priority`, sans cache, `can_open_gates`), une seule fois par trajet (`path.tried`, remis à zéro par `begin_leg`). Elle attend freinée dans sa manœuvre (`wait_for_path`) ; la réponse arrive par `on_script_path_request_finished` (`movement.on_path_finished`, `storage.path_requests` relie la requête à la voiture ; `try_again_later` renvoie la requête après `short_delay`). Le chemin est réduit aux angles et à un point tous les `lookahead_length` tiles, puis suivi : `get_target` renvoie le waypoint courant à `update_mode`, `drive_tick` et à la manœuvre pour la direction, tandis que l'arrivée et le freinage restent ceux de la destination ; un waypoint est dépassé à moins de deux longueurs de voiture. Le chemin trouvé redéfinit la durée admise du trajet (`departure_distance`). Sans chemin (`none`) ou sans réponse après `long_delay`, la voiture est `stuck` comme avant. La détection de blocage est suspendue pendant l'attente.

Voisines : toutes les `slow_check_interval` ticks (décalés par l'id de la voiture, `_utils.is_slow_check_due`), `refresh_neighbours` liste les autres voitures en mouvement à proximité. Un point d'échantillon de `drive_tick` situé dans la zone devant l'une d'elles (largeur de la voiture, longueur de la voiture plus `speed * braking_duration`) coûte un `steering_cost.blocked` de plus. Les trains pourront rejoindre cette liste.

`stuck` : arrêt, alerte, attente `long_delay`, puis nouvel essai du même trajet (`stuck.destination`, sa tâche est restée en tête de file). Après `max_stuck_retries` essais, ou sans carburant pour le trajet, attente `stuck_abandon_delay` puis abandon : les ghosts du batch sont libérés (le joueur doit les resélectionner) et la voiture rentre par les tâches existantes (dépôt, charge, garage). Un trajet vers un chargeur est réessayé sans limite. `stuck_retry_count` est remis à zéro à l'arrivée, pas dans `begin_leg`.

`empty` : batterie à 0, la voiture ne fait que surveiller `critical_fuel_ratio` (alerte `battery_empty`), puis reprend son batch par `waiting`. Rien dans le mod ne recharge une voiture vide : le joueur la ramasse et la repose, ce qui crée une nouvelle voiture.

### Trajets et tâches

`travel.begin_leg(car, destination, next_task)` démarre un trajet et pousse `next_task` en tête de `car_data.tasks`. `travel.set_destination` fait de même après avoir vérifié le carburant, avec un détour par un chargeur si besoin : c'est la variante par défaut.

Une voiture est arrivée quand elle est à l'arrêt à moins de `config.arrival_distance` ; elle peut alors agir sur sa destination. `movement.drive_tick` lève l'événement `autonomous_car_next_task` ; `on_next_task` termine alors le trajet (`moving` désactivé), dépile la tâche et lui passe la destination atteinte : `charging`, `parking`, `building`, `collect` ou `deposit`. La fin de charge lève le même événement. Cet événement est synchrone : `on_next_task` s'exécute à l'intérieur de `drive_tick`.

Un trajet abandonné passe par `travel.cancel_trip(car_data)` : trajet, manœuvre, attente `stuck`, charge, stationnement, tâches en file et place de chargeur (`release_charger_slot`, qui couvre le trajet vers le chargeur comme la charge). `travel.reset_to_waiting` ajoute l'arrêt de la voiture et le retour en `waiting` (`_utils.start_waiting`). `begin_leg` désactive `waiting` : un appel qui démarre un trajet n'a pas à le faire lui-même, et un échec de `set_destination` remet la voiture en `waiting`.

Un nouveau type d'étape est une tâche de plus dans `on_next_task`, pas un nouvel état.

### Construction

Sélection du joueur → `on_area_selected` → `register_ghost` (ignore les ghosts couverts par un réseau logistique et ceux déjà suivis, qui sont avec une voiture ou en attente) → `build_clusters` → tous les clusters vont dans `storage.pending_clusters` → `retry_pending_clusters` : `find_available_car` (voiture en `waiting` au coffre vide, sinon sortie d'un garage) → `assign_cluster`, qui crée `car_data.construction` et appelle `fill_batch`.

Un batch peut contenir plusieurs clusters : `fill_batch` ajoute les clusters en attente les plus proches tant que la somme de leurs slots tient dans le coffre (`config.car_inventory_size`). Les slots se comptent cluster par cluster (`count_items_slots`), jamais partagés. `construction.ghosts` et `items_needed` fusionnent les clusters ; `construction.clusters` garde, par cluster, ses ghosts et ses items.

`ghost_control.proceed` est le point de décision unique, rappelé après chaque étape : coffre d'approvisionnement (`collect`), trajet vers le chantier (`go_to_site`), ou attente avec alerte si aucun coffre n'aide (`construction.missing_since`, que `gui.lua` lit). Après `long_delay` d'attente, les clusters dont les items manquent retournent dans `storage.pending_clusters` si un autre cluster du batch est complet (`release_unsupplied_clusters`). Un cluster quitte un batch par `travel.requeue_cluster` ; un batch retiré à sa voiture (`travel.requeue_construction` : voiture perdue, but inatteignable) retourne dans la liste cluster par cluster, jamais fusionné. `go_to_site` choisit le ghost prêt le plus proche, quel que soit son cluster, et fait de ce cluster le chantier (`construction.site`) ; il passe par `travel.set_destination` : c'est lui qui fait recharger la voiture entre deux clusters. Sur place, `building_tick` construit un ghost à la fois, seulement parmi ceux du chantier (`revive` n'a pas de portée : sans cette limite la voiture construirait tout le batch depuis son premier arrêt) ; quand plus aucun n'est prêt (`attempt_one_ghost` renvoie `none`), il rappelle `go_to_site`, qui mène la voiture au cluster suivant, ou la recule si seuls restent des ghosts en attente de réessai. Un ghost du batch qui disparaît sans que la voiture l'ait construit retire ses items de `items_needed` et du cluster (`drop_ghost_items`, d'après l'item noté dans `construction.clusters[].ghosts` à l'ajout du cluster) ; `finish` dépose les restes (`deposit`) puis prend un cluster en attente ou repasse en `waiting`. Le dépôt remplit tout le groupe de coffres, puis le coffre suivant qui a de la place ; sans place, alerte `supply_full`, la voiture garde ses items et `end_wait` réessaie (une voiture au coffre non vide ne prend ni batch ni garage).

### Carburant

La voiture brûle un carburant caché, sans slot : la charge est `burner.remaining_burning_fuel`. Un brûleur vide perd son item de carburant et ignore alors toute écriture de la charge : lire et écrire la charge uniquement par `_utils` (`get_fuel`, `get_fuel_ratio`, `set_fuel`), qui remet l'item en place. `charger_data.users` est réservé au départ vers le chargeur.

Estimation : `charger_control.compute_fuel_to_reach` (aller seul, `find_charger`) et `compute_fuel_needed` = aller + `compute_fuel_reserve` (trajet de la destination au chargeur le plus proche, places libres ignorées, plus `critical_fuel_ratio`). `set_destination` détourne par un chargeur si la charge ne suffit pas ; réservoir plein et toujours insuffisant : `mark_unreachable`. Recharge d'urgence : `handle_critical_fuel` compare la charge à `compute_fuel_reserve` depuis la position de la voiture, recalculé toutes les `slow_check_interval` ticks ; sans chargeur joignable, la voiture s'arrête en `waiting` et cherche de nouveau toutes les `short_delay`.
`fuel_per_tile` reste approximatif : aucune estimation n'est meilleure que lui. Garage : `repair_parked_cars` rend `garage_repair_rate` de santé aux voitures garées toutes les `long_delay`.

## Invariants

- Une ouverture dans un mur doit faire 3 tiles au moins (conseil à donner au joueur) : une ouverture d'une tile n'est pas une sortie que la voiture sait trouver ni franchir.
- `building.active` n'est vrai qu'une fois la voiture arrêtée sur son chantier ; pendant un trajet c'est `car_data.construction` qui indique un batch en cours. `building` et `construction` ne se confondent pas.
- `moving.destination` peut être une table `{position, valid}` (waypoint de `step_back`) au lieu d'une entité : n'en lire que ces deux champs.
- `stuck` est un état de repli, pas une courte pause.
- Le mode précision est inachevé (actif en zone dense seulement) ; le propriétaire compte le reprendre, ne pas le traiter comme du code mort.
- `emergency_brake` ne s'applique que dans `drive_tick`, jamais en manœuvre.
- Pas de migration : le mod n'est pas publié, les nouveaux champs de `car_data` (`maneuver`, `empty`, `stuck.*`) imposent une nouvelle sauvegarde. Dernier cas, essayé dans Factorio : un batch enregistré avant le commit de nettoyage (`construction.clusters[].ghosts[id] = true`) arrête le jeu sur une erreur de script (`ghost.lua`, `drop_ghost_items`) dès qu'un de ses ghosts disparaît.
- Le script ne règle jamais l'orientation de la voiture, seulement `riding_state`. Le sens du braquage en marche arrière est réglé par `REVERSE_STEERING_INVERTED` dans `movement.lua` (`true` : braquer à gauche en marche arrière envoie l'arrière de la voiture à sa gauche, comme constaté en jeu ; le propriétaire a hésité sur ce réglage, c'est la valeur à retenir). Tout ce qui en dépend passe par `get_arc_rotation`.
- Ce que les prototypes et les scripts doivent partager est défini une seule fois dans `config.lua` : les noms (`config.names`), la taille de la voiture (`config.car_size`, dont dérivent les sondes de manœuvre), les tailles d'inventaire. Ne jamais réécrire l'une de ces valeurs en dur ailleurs. Les noms sont enregistrés dans les sauvegardes : ne pas les changer sans accord. Ils servent aussi de clés dans `locale/` : un prototype ajouté ou renommé y a sa ligne dans chaque langue.
- Un prototype copié du jeu (`table.deepcopy`) garde tous les champs de l'original : `icons` l'emporte sur `icon`, `hidden` reste vrai (cas du chargeur, copié de l'interface d'énergie). Les vérifier à chaque copie.
- `config.lua` se termine par des vérifications (`assert`) des relations entre constantes dont le code dépend ; en ajouter une quand une nouvelle constante doit rester cohérente avec une autre.

## Conventions de nommage

- État : `car_data.<état>.active`, avec `since` pour le tick de début.
- Entités : `car`, `charger`, `garage`, `chest`, `ghost`, sans suffixe ; leurs données en `<entité>_data`. `destination` est l'entité ou le waypoint visé, `target` sa position.
- Fonctions : verbe en premier, sans exception hors celles ci-dessous. `get_*` lit une valeur déjà connue (`get_fuel`, `get_leg_destination`), `compute_*` la calcule (`compute_fuel_needed`, `compute_angle_between`), `measure_*` l'interroge dans le monde (`measure_obstacle_density`, `measure_free_room`), `count_*` compte, `find_*` cherche (`find_closest`, `find_neighbours`), `is_*` / `can_*` / `fits_at` répondent par vrai ou faux, `alert_*` alerte, `start_*` entre dans un état, `create_*` construit une table d'état (`create_car_data`). Une alerte répétable passe par `_utils.alert_once` / `alert_reset`. Exceptions : les gestionnaires d'événements `on_*`, les fonctions `<état>_tick` (ci-dessous) et `new` / `length` de `_utils.deque`, qui suivent l'usage des conteneurs Lua.
- `<état>_tick` pour la fonction appelée à chaque tick tant que la voiture est dans cet état ou ce mode (`charging_tick`, `parking_tick`, `building_tick`, `stuck_tick`, `maneuver_tick`, `drive_tick`) ; `start_<état>` pour y entrer (`start_stuck`, `start_maneuver`).
- Abandon : « unreachable » (aucune recharge possible) et « stuck » (trajet bloqué) en sont les deux causes ; `stuck.final` marque la dernière attente d'une voiture bloquée, celle qui finit par l'abandon.
- Manœuvre : un « arc » est un des six choix de conduite (avant ou arrière × braquage), un « heading » est une direction.
- Prototypes : `autonomous_car`, puis `autonomous_car_<chose>`, en snake_case, déclarés dans `config.names`.
- Constantes de `config.lua` qui vont ensemble : regroupées dans une table (`speed`, `high_speed_density`, `steering_cost`, `maneuver_probe`) plutôt qu'en plusieurs constantes séparées.
- `config.lua` : `*_delay` attente avant de réessayer, `*_duration` durée d'une action, `*_interval` période. « fuel » est la charge de la voiture, « energy » le tampon du chargeur.
- Tout nouveau délai réutilise `short_delay`, `medium_delay`, `idle_delay` ou `long_delay` et s'ajoute à la liste d'usages de son commentaire.

## Réglage du mouvement

Régler un bloc à la fois, un paramètre à la fois, dans cet ordre, en testant en jeu entre chaque :

1. sécurité : `emergency_brake_lookahead`, `arrival_distance`, `braking_duration`
2. manœuvre : `maneuver_*`, `friction_maneuver_factor`
3. densité et précision : `high_speed_density`, `dense_area_threshold`, `precision_*`
4. vitesse : `friction_*`, `speed.*`
5. `density_radius`, `lookahead_*` et `steering_cost` si le problème persiste

| Symptôme | Constantes à regarder |
|---|---|
| oscille autour de la destination | `arrival_distance`, `emergency_brake_lookahead`, `precision_*`, `dense_area_threshold` |
| manœuvre à tort, ou trop tôt | `short_delay` (déclencheur `blocked`) |
| manœuvre qui n'aboutit pas | `idle_delay` (durée maximale de l'essai), `short_delay` (recul, nouveau cap), `maneuver_exit_density`, `maneuver_min_travel`, `maneuver_probe.*`, `friction_maneuver_factor` |
| s'arrête trop souvent en trajet | `density_radius`, `lookahead_length`, `dense_area_threshold`, `emergency_brake_lookahead`, `steering_cost` |
| trop rapide ou trop lente | `friction_*`, `high_speed_density`, `braking_duration` |

La friction agit sur le symptôme, pas sur la cause : régler d'abord les seuils de décision. Un seuil de densité se choisit en sachant que la voiture se compte elle-même (environ 0,035 dans un disque centré sur elle, 0,024 dans la densité mélangée de `update_mode`). La manœuvre doit rester une exception.

À vérifier en jeu après un réglage : ligne droite sans oscillation, arrêt propre près d'un obstacle, zone dense sans faux `stuck`, cluster construit sans arrêt inutile, recharge puis parking, plusieurs voitures sans blocage mutuel.

## À faire

Idées et tâches retenues par le propriétaire, pas encore commencées. Chacune a un commentaire `-- TODO` à l'endroit indiqué.

- **Détruire et remplacer des entités.** Permettre aux voitures de détruire et de remplacer des entités marquées pour destruction ou mise à jour. (`ghost.lua`, `ghost_control.revive_ghost`)
- **Ne pas stationner sur les rails.** Limiter les collisions avec les trains ; la liste des voisines de `movement.lua` (`refresh_neighbours`) peut accueillir les trains. (`park.lua`, `garage_control.parking_tick`)
- **Points de recharge automatiques.** Construire des chargeurs pour atteindre une destination éloignée, sans modifier le réseau électrique. (`charge.lua`, `charger_control.find_charger`)
- **Kits de réparation.** Slots de kits de réparation dans le garage pour réparer les voitures, en plus de la réparation gratuite (`garage_control.repair_parked_cars`). (`park.lua`)
- **Agrandissement du réseau de construction natif.** Un ghost qui agrandit le réseau de robots se construit en dernier, pour éviter le conflit avec les robots. (`ghost.lua`, `ghost_control.build_clusters`)
- **Recharger une voiture vide.** Ajouter un ou plusieurs moyens ; aujourd'hui il faut la ramasser et la reposer. (`travel.handle_empty`)
- **Réessai sans limite vers un chargeur.** Ne le garder que lorsque la voiture est sur le retour (recharge juste avant le garage, ou après un abandon complet) ; ailleurs, limiter les essais comme pour les autres trajets. Tant que ce réessai est sans limite, `release_charger_slot` dans `stuck_tick` ne libère jamais rien. (`travel.start_stuck`)
- **Graphismes provisoires.** Coffre d'approvisionnement, icône du sélecteur de ghosts, icône du raccourci des objets manquants (`prototypes/missing_items.lua`), restes du garage et du chargeur (leurs images sont déjà dans `graphics/*/remnants`, pas encore utilisées). (`prototypes/`)

## Problèmes connus

### Ouverts

1. **Coins et espaces étroits.** Décision du propriétaire : une ouverture d'une tile dans un mur n'est pas une sortie valide (conseil au joueur : 3 tiles au moins). Les coins de pièce restent un piège : la voiture s'y cale en diagonale, et le chemin du pathfinder arrivé trop tard ne la sort pas (voiture A de `sealed`, dont l'ouverture arrive après son abandon, t = 470 : elle sort au réessai ; l'attente du stuck est voulue, elle laisse à la situation le temps d'évoluer ; la voiture D, ouverture à t = 300, sort par la manœuvre seule). Piste : détecter les coins. Le couloir en L de 4 tiles (`l-corridor`) est franchi mais lentement (2400 et 4200 ticks, contre 600 à 900 pour 6 et 8 tiles).
2. **Départ au milieu d'une forêt.** Mesuré avec `forest`, `forest-edge`, `forest-depth` et `copse`. Une boucle d'arbres sur la route est contournée dans les six cas, quelle que soit la densité (`copse`, environ 530 ticks) ; une forêt traversée depuis l'extérieur passe à pleine vitesse (la voiture écrase les arbres). Une voiture qui démarre à 2 tiles de la lisière sort ou traverse sauf dans la forêt la plus dense (arbres espacés de 1,5 tile : 4 sur 6) ; à 4 tiles ou plus de la lisière, une seule voiture sur six s'en sort, même avec des arbres espacés de 3 tiles : à basse vitesse la voiture n'écrase pas les arbres et son pilotage réactif ne suit pas les passages étroits que le pathfinder trouve. Quinze réglages de `drive` essayés un par un (`dense_area_threshold`, `emergency_brake_lookahead`, `friction_precision_factor`, `friction_base`, `steering_cost.*`) n'y changent rien d'utile (0 à 2 voitures sur 6 en forêt profonde). Ce n'est donc pas un problème de réglage. À voir en jeu si le cas arrive ; pistes : laisser la voiture prendre de la vitesse et écraser un arbre quand tout le reste a échoué, ou ne pas compter les arbres dans la densité.
3. **Carburant non calibré.** `fuel_per_tile` est approximatif : toute estimation (aller, retour, seuil critique) en hérite. À calibrer en jeu.
5. **Place de chargeur prise dans `basics` : ce n'est pas une fuite.** La place du chargeur (11000, 0) est tenue par la voiture 69, celle de la zone (12000, 0) dont les deux chargeurs sont détruits : à t = 1810, avec 81 % de charge, elle part faire l'appoint avant de se garer (`top_up_before_parking`) au chargeur libre le plus proche de son garage, à 1055 tiles (le chargeur de sa zone n'est reconstruit qu'à t = 2500). Elle n'y arrive jamais : elle tourne autour de x ≈ 11715 entre y = -287 et y = 318 jusqu'à la fin, vraisemblablement le long du bord du terrain généré (x = 11712 et les y extrêmes tombent sur des limites de chunk), et son trajet vers un chargeur est réessayé sans limite. À décider : limiter la distance de l'appoint avant garage (ici 1055 tiles pour gagner 19 %), et relier les zones du scénario ou y laisser un chargeur.
6. **Coût de `measure_wall_margin` dans `drive_tick`.** La marge double les appels à `can_place_entity` (un par point d'échantillon et par côté) dès qu'une entité autre que la voiture est à portée (`near`, presque toujours vrai en terrain naturel) : environ 20 appels de plus par voiture et par tick. À mesurer en jeu avec plusieurs voitures ; piste : ne recalculer la marge que toutes les `slow_check_interval` ticks.
7. **Chargeur ignoré tant qu'un but est signalé inatteignable.** Passé `max_charge_detours`, `detour_to_charger` signale le but inatteignable sans plus chercher de chargeur, jusqu'à l'abandon (`unreachable_abandon_delay`). Essai dans Factorio : chargeur construit à 20 tiles de la voiture à t = 3000 (compteur à 10), la voiture n'y part qu'à t = 5400, après l'abandon de t = 5110 qui remet le compteur à zéro. Le joueur qui pose un chargeur en réponse à l'alerte attend donc jusqu'à une minute sans rien voir bouger.
8. **Portes ouvertes dans toutes les directions.** `open_gates` demande l'ouverture de toutes les portes de la force à moins de `SENSOR_REACH` (environ 16 tiles) d'une voiture en mouvement, qu'elle s'y dirige ou non : une voiture qui longe l'intérieur d'un mur tient ouvertes les portes à portée, derrière elle comprises. Vu à la lecture du code ; la solution demande un choix du propriétaire (ne garder que les portes devant la voiture, ou sur le chemin de la destination).
9. **Qualité des ghosts ignorée.** `get_ghost_item` ne renvoie que le nom de l'objet ; la collecte, `revive_ghost` et le dépôt ne manipulent que la qualité normale. Un ghost de qualité supérieure serait donc construit avec un objet normal. Vu à la lecture du code, à confirmer en jeu.
10. **Zone aveugle de la manœuvre sondée par le centre des entités.** Dans `measure_free_room`, la zone entre la voiture et la première sonde est cherchée par `find_entities_filtered` avec `position` et `radius`, qui ne retient que les entités dont le centre est dans le disque (documentation de l'API). Le coin d'une grande entité (machine, rocher) peut y passer inaperçu : la voiture choisit l'arc, cale `short_delay`, puis recule. Piste : une zone (`area`) orientée ; vérifier d'abord en jeu que `find_entities_filtered` tient compte de l'orientation d'une zone, ce que la documentation ne dit pas.
11. **Coût de `get_critical_fuel`.** Toutes les `slow_check_interval` ticks, chaque voiture, quel que soit son état, cherche le chargeur le plus proche parmi tous les chargeurs (`compute_fuel_reserve`). À mesurer en jeu avec beaucoup de voitures et de chargeurs ; piste : ne le recalculer que pour une voiture en mouvement.
12. **Batch donné à une voiture en panne de charge.** `find_available_car` ne regarde pas la charge : une voiture en `waiting`, arrêtée faute de chargeur joignable (`handle_critical_fuel`), peut recevoir un batch qu'elle garde sans pouvoir bouger. Vu à la lecture du code.

### Corrigés, à valider

Rien pour l'instant.
