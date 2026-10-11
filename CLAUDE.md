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
- API de Factorio : la documentation locale (`doc-html` du dossier du jeu, version 2.0.77 le 2026-10-10) fait foi pour la version installée ; la documentation en ligne peut décrire une version expérimentale plus récente (cas de `apply_upgrade` et de son paramètre `buffer`, voir « Construction »). Très rarement (changement de version du jeu, ou quand un contournement dans le code existe à cause d'une limite de l'API), proposer au propriétaire de vérifier si l'API a évolué et si un contournement peut être simplifié ; ne pas le proposer à chaque session.
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
tests\run.ps1                                  # tous les scénarios, cinq lancements de Factorio
tests\run.ps1 movement                         # une catégorie : movement, robustness, construction, energy, doors
tests\run.ps1 -Changed                         # les catégories que les fichiers modifiés depuis le dernier commit peuvent affecter
tests\run.ps1 maze, garage-exit -Ticks 8000    # des scénarios précis (un lancement par catégorie concernée)
tests\run.ps1 -Reference <dossier ou zip>      # compare les traces avec une autre version du mod
tests\run.ps1 doors -Set "friction_precision_factor=6","friction_maneuver_factor=8" -Output $env:TEMP\essai1   # change des valeurs de config pour ce lancement (seulement celles que le script lit en jouant) ; -Output permet de lancer plusieurs essais en parallèle
tests\show.ps1 construction -Car 132           # changements d'état d'une voiture dans une trace
```

Chaque scénario a une catégorie (champ `category` dans `tests/harness.lua`) ; les scénarios d'une catégorie qu'on lance tournent ensemble dans une seule partie, chacun sur sa surface et avec sa trace (`trace-<scénario>.txt`), pour ne pas lancer Factorio 24 fois : `movement` (13 scénarios, déplacements autour d'obstacles : salles, murs, forêts, labyrinthes ; `forests` regroupe 24 parcours sur une grande carte), `doors` (11 scénarios, portes : `gates` 12 parcours de traversée d'un mur de 600 tiles par une ouverture de 3 tiles, seul moyen de passer ; `gate` une voiture et un mur de 600 tiles (toutes les ouvertures font 3 tiles ; `ONE_TILE_DOORS` dans le harnais ramène celles d'une tile) ; `doors-clutter` 7 parcours avec bâtiments, poteaux, forêt clairsemée ou bosquet près de la porte ; `doors-traffic` 3 parcours où 4 ou 8 voitures passent la même porte, dans un sens ou dans les deux ; `doors-odd` 11 cas rares : porte masquée par un coffre, sas, couloir, porte ennemie, voiture dos à la porte, longue marche le long du mur ; `doors-base-1` à `6` une base murée de 80 x 48 tiles, deux pièces et trois portes sur l'extérieur, avec garage, chargeur et coffre en divers endroits, un scénario chacun car une voiture va n'importe où sur sa surface ; les lignes `DONE <parcours> <tick>` de la trace donnent le tick où le parcours est fini), `robustness` (voitures bloquées, pannes, batterie vide), `construction` (3 scénarios : `construction`, `work` qui regroupe sur une grande carte démontage, mise à niveau, ghosts, tuiles et roboports avec trois voitures, `phases-single` pour l'ordre des phases avec une seule voiture), `energy` (chargeurs et garages). Une erreur de script arrête toute la catégorie. Un nouveau scénario prend la catégorie de ce qu'il vérifie, et une surface à lui (`new_surface`).

`run.ps1` lance Factorio sans fenêtre ni joueur sur une copie du mod dans `%TEMP%\autonomous-car-tests` ; rien n'est écrit dans le dossier Factorio et le jeu peut rester ouvert. Il affiche pour chaque scénario l'erreur de script éventuelle, les événements et le dernier résumé. `-Reference` sert à vérifier qu'un refactoring ne change aucun comportement : Factorio est déterministe, deux versions équivalentes donnent des traces identiques (à scénarios groupés identiques : les numéros d'entités dépendent des scénarios lancés ensemble). La version de référence tourne avec son propre `tests/harness.lua` quand elle en a un, ce qui permet de comparer deux versions dont les noms diffèrent. Les scénarios posent de l'herbe (`grass-1`, friction 1.6) sur leur surface, comme en jeu : sur les tuiles de laboratoire les voitures vont bien plus vite. Les scénarios sont décrits dans `tests/harness.lua`, qui en est la seule liste : `run.ps1` y lit leurs noms, leur durée (22 000 ticks, ou le champ `ticks`) et leur catégorie, `show.ps1` y lit les noms des drapeaux. Ce fichier est greffé à la fin de `control.lua` et utilise ses locales (`on_area_selected`, `names`, les modules) : renommer l'une d'elles impose de le mettre à jour. Un événement `NOSTATE` dans une trace signale le filet de sécurité de `update_car` (voir « Tick »).

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

Le sélecteur prend aussi les entités marquées pour destruction (arbres, rochers, bâtiments minables hors falaises) et celles marquées pour mise à niveau (changement d'entité ou de qualité) : un « ghost » du module est toute cible d'une voiture, `ghost_control.get_id` la désigne (arbres et rochers n'ont pas de `unit_number`, confirmé par `deconstruct` : leur clé est surface, nom et position, et `storage.target_by_registration` relie leur destruction à cette clé). Un batch construit, remblaie (mode `landfill` : ghost de tuile sur l'eau, `get_target_mode`), démonte, met à niveau ou construit les ghosts qui étendent le réseau logistique (mode `network`, les roboports), jamais deux de ces cinq (`construction.mode`, `get_target_mode` ; `fill_batch` n'ajoute que des clusters de son mode). Ordre du travail (`PHASE`) : d'abord les démontages, puis les remblais (un bâtiment à démonter sur le remblai part avant), puis les mises à niveau et les constructions, enfin le mode `network`. Un batch de remblai ne s'arrête que près d'une tuile de terre : `go_to_site` ne choisit que les ghosts de tuile voisins d'une terre (`is_next_to_land`, 8 tuiles autour), la voiture s'arrête sur la rive et construit tout le cluster de là (`revive` n'a pas de portée) ; si aucun ghost du batch n'est voisin d'une terre (`is_stranded`), alerte et abandon du batch (`abandon` avec son message), comme un trajet bloqué Un batch va chercher ses objets tout de suite (et signale ceux qui manquent) mais ne part vers son chantier que lorsque plus aucune cible d'une phase antérieure n'est suivie sur la surface de la voiture, en batch ou en attente (`is_waiting_for_phase` ; une marque annulée ne compte pas). Il attend alors comme pour des objets manquants (`construction.blocked_since`) ; après `long_delay`, si un cluster d'une phase antérieure attend faute de voiture, le batch retourne dans la liste et la voiture, libérée après avoir déposé ses objets, prend ce cluster (`wait_for_phase`). Les clusters en attente sont attribués par phase (`retry_pending_clusters`, `try_assign_pending`). Démonter = `entity.mine` dans le coffre de la voiture ; la charge d'un cluster à démonter (`compute_load`) est le pire cas de ce qu'il rend (produits au maximum, contenu des inventaires) et réserve des slots, mais rien n'est à collecter (`items_needed` reste vide) ; `finish` dépose ce que la voiture rapporte comme les restes. Chaque ghost a des besoins (`compute_needs` : l'objet à collecter, pour construire ou pour l'entité de remplacement) et une charge (`compute_load` : les besoins plus ce que le démontage ou le remplacement rend, qui réserve les slots) ; `release_unsupplied_clusters` ne compte que les besoins. Mise à niveau (`upgrade_entity`) : `LuaEntity.apply_upgrade` remplace l'entité, garde ses réglages et transfère ce que la nouvelle peut contenir, mais détruit le reste ainsi que l'objet de l'ancienne entité (mesuré le 2026-10-10 par un scénario d'essai : 400 plaques de fer et 2 modules disparus, rien au sol ; la documentation en ligne annonce un paramètre `buffer`, mais en 2.0.77 le passer avec le coffre d'une voiture ne change rien, le coffre reste vide ; à reprendre si une version l'accepte). La voiture compte donc le contenu avant et après (`count_contents`), consomme l'objet de remplacement dans son coffre et y met l'objet de l'ancienne entité et ce qui n'a pas suivi (coffre plus petit, moins de slots de modules), déposés ensuite comme les restes. Les données d'objet autres que la qualité (étiquettes, santé) ne sont pas conservées. Qualité : un objet est identifié par son nom et sa qualité, la clé des tables `[clé] = nombre` (besoins, charge, `items_needed`) est le nom seul en qualité normale et `nom|qualité` sinon (`_utils.make_item_key`, `split_item_key`, `make_stack`, `get_item_count`, `get_contents`) ; l'objet d'un ghost ou d'une mise à niveau a la qualité de l'entité, ce que rend un démontage ou une mise à niveau celle de l'entité démontée, le garage rend une voiture de la qualité de l'objet rangé. Limites : l'effet de la qualité sur la taille du coffre d'une voiture n'est pas lu (`config.car_inventory_size` sert de plafond, prudent), les demandes d'objets d'un ghost (modules) ne sont pas traitées. Un démontage qui échoue (coffre plein) suit le cycle des essais de `revive` ; une marque retirée par le joueur compte comme fait.

Un batch peut contenir plusieurs clusters : `fill_batch` ajoute les clusters en attente les plus proches tant que la somme de leurs slots tient dans le coffre (`config.car_inventory_size`). Les slots se comptent cluster par cluster (`count_items_slots`), jamais partagés. `construction.ghosts` et `items_needed` fusionnent les clusters ; `construction.clusters` garde, par cluster, ses ghosts et ses items.

`ghost_control.proceed` est le point de décision unique, rappelé après chaque étape : coffre d'approvisionnement (`collect`), trajet vers le chantier (`go_to_site`), ou attente avec alerte si aucun coffre n'aide (`construction.missing_since`, que `gui.lua` lit). Après `long_delay` d'attente, les clusters dont les items manquent retournent dans `storage.pending_clusters` si un autre cluster du batch est complet (`release_unsupplied_clusters`). Un cluster quitte un batch par `travel.requeue_cluster` ; un batch retiré à sa voiture (`travel.requeue_construction` : voiture perdue, but inatteignable) retourne dans la liste cluster par cluster, jamais fusionné. `go_to_site` choisit le ghost prêt le plus proche, quel que soit son cluster, et fait de ce cluster le chantier (`construction.site`) ; il passe par `travel.set_destination` : c'est lui qui fait recharger la voiture entre deux clusters. Sur place, `building_tick` construit un ghost à la fois, seulement parmi ceux du chantier (`revive` n'a pas de portée : sans cette limite la voiture construirait tout le batch depuis son premier arrêt) ; quand plus aucun n'est prêt (`attempt_one_ghost` renvoie `none`), il rappelle `go_to_site`, qui mène la voiture au cluster suivant, ou la recule si seuls restent des ghosts en attente de réessai. Un ghost du batch qui disparaît sans que la voiture l'ait construit retire ses items de `items_needed` et du cluster (`drop_ghost_items`, d'après l'item noté dans `construction.clusters[].ghosts` à l'ajout du cluster) ; `finish` dépose les restes (`deposit`) puis prend un cluster en attente ou repasse en `waiting`. Le dépôt remplit tout le groupe de coffres, puis le coffre suivant qui a de la place ; sans place, alerte `supply_full`, la voiture garde ses items et `end_wait` réessaie (une voiture au coffre non vide ne prend ni batch ni garage).

### Carburant

La voiture brûle un carburant caché, sans slot : la charge est `burner.remaining_burning_fuel`. Un brûleur vide perd son item de carburant et ignore alors toute écriture de la charge : lire et écrire la charge uniquement par `_utils` (`get_fuel`, `get_fuel_ratio`, `set_fuel`), qui remet l'item en place. `charger_data.users` est réservé au départ vers le chargeur.

Estimation : `charger_control.compute_fuel_to_reach` (aller seul, `find_charger`) et `compute_fuel_needed` = aller + `compute_fuel_reserve` (trajet de la destination au chargeur le plus proche, places libres ignorées, plus `critical_fuel_ratio`). `set_destination` détourne par un chargeur si la charge ne suffit pas ; réservoir plein et toujours insuffisant : `mark_unreachable`. Recharge d'urgence : `handle_critical_fuel` compare la charge à `compute_fuel_reserve` depuis la position de la voiture. Au-dessus de `critical_check_fuel_ratio` du réservoir (0,8), rien n'est mesuré (la voiture est forcément près d'un chargeur) ; en dessous, la mesure se fait toutes les `slow_check_interval` ticks, ou toutes les `short_delay` tant que la charge dépasse le double du dernier seuil mesuré. Sans chargeur joignable, la voiture s'arrête en `waiting` et cherche de nouveau toutes les `short_delay` ; tant que sa charge est sous le seuil (`travel.is_fuel_critical`), `find_available_car` et `try_assign_pending` ne lui donnent aucun batch.
`fuel_per_tile` reste approximatif : aucune estimation n'est meilleure que lui. Garage : `repair_parked_cars` rend `garage_repair_rate` de santé aux voitures garées toutes les `long_delay`.

## Invariants

- Une ouverture dans un mur doit faire 3 tiles au moins (conseil à donner au joueur) : une ouverture d'une tile n'est pas une sortie que la voiture sait trouver ni franchir.
- Limites acceptées par le propriétaire (ne pas les « corriger » sans accord) : un espace trop étroit pour la voiture est toujours bloquant ; une voiture qui démarre au milieu d'une forêt dense peut y rester bloquée (cas rare, le joueur la dégage : la voiture écrase les arbres à pleine vitesse mais pas à basse vitesse, `forest-depth` : 1 voiture sur 6 ; le scénario `forests`, qui regroupe les anciens `forest`, `forest-edge`, `forest-depth` et `copse`, construit 16 coffres sur 24 contre 14 sur 24 avec les anciens (2026-10-10), aucun réglage de `drive` n'y change rien) ; les portes de la force à portée d'une voiture en mouvement sont ouvertes dans toutes les directions (`open_gates`) ; une voiture qui n'a plus de chargeur joignable attend longtemps avant d'abandonner (`unreachable_abandon_delay`) : elle laisse le monde évoluer ; la zone aveugle de la manœuvre (le coin d'une grande entité peut passer inaperçu) se rattrape au tick suivant.
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
- Tout nouveau délai réutilise `short_delay`, `medium_delay`, `idle_delay`, `long_delay` ou `very_long_delay` et s'ajoute à la liste d'usages de son commentaire.

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

## Essais sur le déplacement

Campagne des 2026-10-10 et 2026-10-11 (catégorie `doors`, scénarios conservés dans `tests/harness.lua`), menée sur la branche `deconstruct-and-replace`. Le code de déplacement a ensuite été remis à celui de `main` pour valider la construction et le démontage seuls ; la version qui contient les essais gardés est le commit `ccc6568` de la branche (`git show ccc6568:movement.lua`, `:config.lua`). Une nouvelle branche de déplacement part de `main`.

Mesures, pour ne pas les refaire. Les scores sont des parcours réussis sur 60 (`gates`, `gate`, `doors-clutter`, `doors-odd`, `doors-traffic`, 9 000 ticks, bruit ± 3) :
- Ouvertures d'une tile (passage de 1,42 tile entre deux murs, voiture large de 0,7) : la voiture passe une fois sur deux ; jamais dans une base (`doors-base-*`, aussi à 18 000 ticks). Cause au tick près : elle longe le mur devant la porte sans s'y engager, car elle ne tourne de 90° vers l'ouverture que si elle est alignée à quelques dixièmes de tile, ce que les trois caps de `drive_tick` (droit, ± 1/12 de tour) ne donnent que par hasard. Décision du propriétaire : ouverture minimale de 3 tiles. Avec 3 tiles (9 000 ticks) : `gates` 11 sur 12, `doors-clutter` 6 sur 7, `doors-odd` 10 sur 11 (`blocked` n'est pas à construire), `doors-traffic` 3 sur 3, six bases sur six, `gate` réussi. Échecs constants : porte du milieu masquée par un coffre juste derrière (`doors-odd` 5), voiture dos à la porte à 4 tiles (8), bosquet dense collé à la sortie (`doors-clutter`).
- **Règle de vitesse près d'un mur** (gardée dans `ccc6568`, pas dans `main`) : `update_mode` interdit `high_speed` quand un mur ou une porte est à moins de `config.high_speed_wall_distance` (15 tiles, `measure_wall_nearby` = `find_entities_filtered` de `wall` et `gate` dans ce rayon, mesuré avec les contrôles lents et gardé dans `car_data.near_wall`). Effet mesuré : aucun hors du bruit (sans la règle 45, avec 43 ; distances 0, 8, 14,5, 15, 15,5, 16, 25 équivalentes), un peu mieux pour les ouvertures de 3 tiles encombrées (28 contre 26 sur 30). Intérêt réel : la voiture est plus lente dans une base, les portes ont le temps de s'ouvrir.
- **Plafond de friction** (dans `ccc6568`) : `friction_modifier` fois la friction de la tuile ne doit pas dépasser 1000 (le jeu multiplie la vitesse par 1 − friction × 0,002 à chaque tick : au-delà le signe s'inverse et la vitesse croît de 2,2 fois par tick, jusqu'à 53 tiles par tick, vu dans `doors-base-4` avec une friction de 16 et le frein d'urgence). Les réglages de `main` plafonnent à 400 (précision × urgence) : aucun risque sans réglage extrême. Correctif essayé : `config.friction_limit = 500` et `math.min(modifier, limit / tile_friction)` dans `set_friction`. À reprendre si on augmente une friction.
- Essayés sans gain, retirés : freinage près des portes (`config.gate_slow` : distance 6 à 25 tiles, friction de 2 à 16 fois, vitesse 0,1 à 0,2 ; à 9 000 ticks 30 à 34 contre 35 à 45 sans, à 18 000 ticks quatre bases sur six échouent) ; `lookahead_side_offset` à 0,55 et 0,5 ; waypoints de porte dans le chemin de secours (approche, porte passée par l'axe, sortie ; aucun gain, coûteux) ; allongement des durées (18 000 ticks) : seulement plus de réussites à une tile sur `gates`.
- Le pathfinder du jeu est asynchrone, budget fixe par tick (10 requêtes de tout type, 100 courtes), cache de chemins : une requête est coûteuse mais rationnée. Une voiture en demande une par trajet au plus (`path.tried`).
- Scénarios `doors-*` : un scénario par base car une voiture va n'importe où sur sa surface ; `-Set` et `-Output` de `run.ps1` permettent des essais de configuration en parallèle.


## À faire

Idées et tâches retenues par le propriétaire, pas encore commencées. Chacune a un commentaire `-- TODO` à l'endroit indiqué.

- **Réseaux logistique et logique.** Gérer les réseaux logistique et logique avec nos bâtiments (coffres d'approvisionnement, chargeurs, garages). (`ghost.lua`, `ghost_control.find_supply_chest`)
- **Ne pas stationner sur les rails.** Limiter les collisions avec les trains ; la liste des voisines de `movement.lua` (`refresh_neighbours`) peut accueillir les trains. (`park.lua`, `garage_control.parking_tick`)
- **Points de recharge automatiques.** Construire des chargeurs pour atteindre une destination éloignée, sans modifier le réseau électrique. (`charge.lua`, `charger_control.find_charger`)
- **Kits de réparation.** Slots de kits de réparation dans le garage pour réparer les voitures, en plus de la réparation gratuite (`garage_control.repair_parked_cars`). (`park.lua`)
- **Falaises.** Détruire les falaises marquées en consommant les explosifs de falaise nécessaires, comme les robots natifs. (`ghost.lua`, `ghost_control.is_target`)
- **Se dégager en détruisant.** Une voiture bloquée pourrait détruire des éléments naturels (arbres, rochers) autour d'elle, avec le même mécanisme que le démontage ; s'associe à « Secours d'une voiture coincée ». (`travel.lua`, `travel.start_stuck`)
- **Recharger une voiture vide.** Ajouter un ou plusieurs moyens ; aujourd'hui il faut la ramasser et la reposer. (`travel.handle_empty`)
- **Réessai sans limite vers un chargeur.** Ne le garder que lorsque la voiture est sur le retour (recharge juste avant le garage, ou après un abandon complet) ; ailleurs, limiter les essais comme pour les autres trajets. Tant que ce réessai est sans limite, `release_charger_slot` dans `stuck_tick` ne libère jamais rien. (`travel.start_stuck`)
- **Technologies.** Des technologies (`TechnologyPrototype`) pour débloquer et améliorer : l'ensemble minimal d'objets nécessaire au fonctionnement du mode (derrière Automobilism et d'autres), la vitesse de charge et de réparation, la réparation dans les garages, la capacité des garages, des chargeurs et des voitures, la vitesse de construction, la vitesse de déplacement (si possible sans perturber les trajets). (`data.lua`)
- **Autres types de robots** (facultatif). Logistique : objets, liquides. (`ghost.lua`, `ghost_control.register_ghost`)
- **Voiture armée.** Pouvoir armer la voiture (petite capacité) pour qu'elle se défende seule. (`prototypes/car.lua`)
- **Fuite du danger.** La voiture fuit une force ennemie. (`movement.lua`, `movement.update_mode`)
- **Construction automatique d'une mine.** Sans ghosts : le joueur sélectionne un gisement et les voitures posent et optimisent seules les foreuses, le réseau électrique et, quand c'est nécessaire (uranium), les tuyaux ; même chose pour le pétrole et les sources du même genre. Éventuellement une gare à proximité, les liens avec les réseaux électriques et les rails restant au joueur. Demanderait un haut niveau de recherche et peut-être un bâtiment de plus, une tour de contrôle dont la consommation d'énergie dépend de la distance du chantier et de sa taille. (`ghost.lua`, `ghost_control.register_ghost`)
- **Secours d'une voiture coincée.** Envoyer une voiture la récupérer ou la relancer (risque de bloquer toutes les voitures) ; s'associe à « Recharger une voiture vide ». Plus tard, aller chercher un train en panne. (`travel.lua`, `travel.start_stuck`)
- **Limiter la charge par tick.** Si le mod devient trop coûteux, répartir le travail sur plusieurs ticks, sans gêner le joueur : tri des entités à la sélection, construction des clusters et des batchs, répartition aux voitures, départ des voitures. (`control.lua`, `on_area_selected`)
- **Graphismes provisoires.** Coffre d'approvisionnement, icône du sélecteur de ghosts, icône du raccourci des objets manquants (`prototypes/missing_items.lua`), restes du garage et du chargeur (leurs images sont déjà dans `graphics/*/remnants`, pas encore utilisées). (`prototypes/`)

## Problèmes connus

### Ouverts

3. **Carburant non calibré.** `fuel_per_tile` est approximatif : toute estimation (aller, retour, seuil critique) en hérite. À calibrer en jeu.

4. **Ouvertures d'une tile : limite acceptée** (vu en jeu par le propriétaire, 2026-10-10). Le 2026-10-11 le propriétaire a jugé qu'une ouverture d'une tile est trop petite pour les voitures : le minimum accepté est 3 tiles (invariant plus haut) et les scénarios `doors` ne construisent plus que des ouvertures de 3 tiles (`ONE_TILE_DOORS` dans `tests/harness.lua` ramène les variantes d'une tile). Détails et essais : section « Essais sur le déplacement ».

5. **Grands détours près du bon passage** (vu en jeu par le propriétaire, 2026-10-11). Des voitures font de très grands détours en ratant de peu le bon passage ; les systèmes de recherche de chemin actuels (cap par échantillonnage, chemin de secours) sont moins satisfaisants que prévu. À analyser avec des scénarios.

_(Les essais de déplacement faits pour les portes sont retirés du code de cette branche : voir « Essais sur le déplacement ».)_

### Corrigés, à valider

- **Qualité des objets** (ancien problème 9). Les ghosts, les mises à niveau, la collecte, le dépôt, la fenêtre des objets manquants et le garage tiennent compte de la qualité (un ghost de qualité rare n'est construit qu'avec un objet rare, rien ne devient gratuitement normal ou rare, une voiture rare reste rare au garage). Écrit d'après la documentation, sans l'extension Qualité : ni essayé en jeu ni couvert par un scénario (Factorio refuse tout prototype de qualité sans l'extension : « Quality is disabled and can not be used », essayé le 2026-10-10 ; le jeu de test n'a que la qualité normale, et la qualité normale ne régresse pas). À faire essayer avec l'extension.
- **Coût de la mesure du seuil critique** (ancien problème 11), sans effet visible : plus de mesure au-dessus de 80 % de charge, mesure espacée (`short_delay`) tant que la charge dépasse le double du dernier seuil. À vérifier en jeu qu'une voiture qui passe sous le seuil part toujours se recharger à temps.
