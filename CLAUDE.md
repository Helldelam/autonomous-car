# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Mod Factorio 2.0 (Lua 5.2) « Autonomous Car » : une voiture autonome qui construit des ghosts hors réseau de robots, se recharge et se gare seule. Ce fichier est la seule documentation du projet.

**Version en construction : rien, à ce stade, n'est définitivement validé**, ni le comportement en jeu, ni le contenu de `main`. Tout peut encore être repris, y compris ce que ce fichier décrit comme fonctionnant.

## Règles de travail

- Comprendre la cause d'un bug au niveau du tick avant de corriger ; pas de correctif de symptôme.
- Changements petits et chirurgicaux. Réutiliser les helpers et l'API Factorio existants ; pas de second système d'état.
- Le code fonctionne globalement en jeu : une incohérence vue à la lecture n'est pas un bug tant qu'elle n'est pas confirmée en jeu, par un scénario de test ou par le propriétaire.
- Ne lancer les tests que sur demande du propriétaire. Dans l'environnement cloud, ne pas chercher à exécuter Factorio : le propriétaire lance les scénarios en local. Une vérification statique reste possible sans Factorio (voir « Commandes »).
- Git : `main` est la version de référence choisie par le propriétaire, pas une version validée (voir plus haut). Tout travail se fait sur une branche à part (la créer avant la première modification si on est sur `main`). Ne jamais pousser ni fusionner dans `main` sans demande explicite du propriétaire ; proposer de committer, pousser ou fusionner quand cela semble utile (fin d'un changement cohérent, version prête à valider), puis attendre sa réponse.
- Tenir à jour la liste « Problèmes connus » en bas de ce fichier : ajouter tout problème découvert ; un problème corrigé passe dans « Corrigés, à valider » et n'est retiré qu'après validation du propriétaire.
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
tests\run.ps1                                  # tous les scénarios, quelques minutes
tests\run.ps1 construction -Ticks 8000         # un scénario, plus court
tests\run.ps1 -Reference <dossier ou zip>      # compare les traces avec une autre version du mod
tests\show.ps1 construction -Car 132           # changements d'état d'une voiture dans une trace
```

`run.ps1` lance Factorio sans fenêtre ni joueur sur une copie du mod dans `%TEMP%\autonomous-car-tests` ; rien n'est écrit dans le dossier Factorio et le jeu peut rester ouvert. Il affiche pour chaque scénario l'erreur de script éventuelle, les événements et le dernier résumé. `-Reference` sert à vérifier qu'un refactoring ne change aucun comportement : Factorio est déterministe, deux versions équivalentes donnent des traces identiques. La version de référence tourne avec son propre `tests/harness.lua` quand elle en a un, ce qui permet de comparer deux versions dont les noms diffèrent. Les scénarios posent de l'herbe (`grass-1`, friction 1.6) sur leur surface, comme en jeu : sur les tuiles de laboratoire les voitures vont bien plus vite. Les scénarios sont décrits dans `tests/harness.lua`, qui en est la seule liste : `run.ps1` y lit leurs noms et leur durée (22 000 ticks, ou le champ `ticks` du scénario), `show.ps1` y lit les noms des drapeaux. Ce fichier est greffé à la fin de `control.lua` et utilise ses locales (`on_area_selected`, `names`, les modules) : renommer l'une d'elles impose de le mettre à jour.

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

`storage.cars[id]` est l'entité, `storage.car_data[id]` son état (créé par `new_car_data` dans `control.lua`) ; même schéma pour chargeurs et garages. Les tables sont créées par `init_storage` au premier tick ; il n'y a ni `on_init` ni migration, donc un champ ajouté à `car_data` n'existe pas pour les voitures déjà posées.

Toute entité devenue invalide est libérée par `_utils.release_entity(kind, id)`. Les ghosts sont suivis par `on_object_destroyed`, pas par les événements died/mined.

### Tick

`on_tick` appelle `update_car` pour chaque voiture, qui exécute la première branche vraie, dans cet ordre :

1. batterie vide (`travel.handle_empty`), puis carburant critique (`travel.handle_critical_fuel`)
2. `moving` : `movement.update_mode`, puis `movement.maneuver_tick` si une manœuvre est active, sinon `movement.drive_tick`, puis `travel.stuck_reason`
3. `charging`
4. `parking`
5. `building` : un ghost toutes les `config.build_interval` ticks
6. `stuck` : `travel.stuck_tick` (réessai, ou abandon via `ghost_control.abandon`)
7. `waiting` : `end_wait` choisit la suite (reprise du batch, cluster en attente, garage)

`update_mode` fixe `precision_mode`, `emergency_brake`, `high_speed` et `friction_modifier` (recalculé chaque tick, jamais incrémenté), et peut démarrer une manœuvre ; `drive_tick` lit `emergency_brake` et `precision_mode` dans le même tick, l'ordre ne doit pas changer.

### Manœuvre, stuck, batterie vide

La manœuvre (`car_data.maneuver`) est un sous-mode de `moving` : même destination, conduite lente (friction), avant ou arrière. Elle choisit d'abord un **cap** (`choose_heading`, gardé dans `maneuver.heading`) : `1 / lookahead_angle` secteurs autour de la voiture, notés par l'espace libre (`free_room`) et, sauf pour `rear_turn`, par la densité (`steering_cost.density`). On part de la direction de la destination. Pour `rear_turn` on prend le secteur libre le plus proche ; pour les autres raisons, le plus dégagé et le moins dense, le plus proche de la destination en cas d'égalité. Le cap n'est remplacé qu'après `short_delay`, et seulement s'il est meilleur d'un pas de sonde entier. Ensuite, toutes les `maneuver_arc_duration`, `choose_arc` choisit l'un des six arcs (avant ou arrière × gauche, tout droit ou droite) qui rapproche l'orientation du cap : arc où la voiture tient, puis qui tourne vers le cap (tout droit une fois aligné), puis avant, puis espace libre. L'arc complémentaire du dernier (même braquage, sens opposé) est interdit : la voiture ne revient pas simplement sur ses pas. Le braquage passe par `riding_state`, jamais par l'orientation. Un mur en pierre n'a que 0,58 tile d'épaisseur : les sondes sont donc espacées de 0,5 tile, et la zone entre la voiture et le premier point (`maneuver_probe.start`) est sondée à part par `find_entities_filtered` (la voiture se détecterait elle-même avec `can_place_entity`). Une voiture qui roule mais reste sous `speed.stopped` pendant `short_delay` a un obstacle invisible, ou un mur qui l'empêche de tourner (elle pivote autour de son centre) : `back_off` l'envoie dans l'autre sens, tout droit, et elle **longe le mur** dans ce sens (`maneuver.follow` ; ses arcs restent dans cette direction) par tranches d'une longueur de voiture (ou `short_delay`), en tentant un virage entre chaque, jusqu'à ce qu'un virage de `lookahead_angle` réussisse. Un arc qui braque n'est retenu que si `can_turn` voit sa boîte, tournée par tiers d'arc sur place (`find_entities_filtered` avec une zone orientée), libre : la voiture n'essaie pas physiquement un virage impossible. Un virage qui cale fait continuer dans le même sens ; un calage en ligne droite marque le sens comme bloqué (`maneuver.blocked`, avec la position et l'orientation du calage) et renvoie la voiture dans l'autre. Un sens n'est bloqué que depuis cet endroit : le repère est périmé dès que la voiture s'est éloignée d'une longueur de voiture ou a tourné de `lookahead_angle` (`is_blocked`), si bien que dans une pièce elle fait la navette d'un mur à l'autre, en tentant un virage à chaque fois, jusqu'à `idle_delay`. Si les deux sens sont bloqués depuis le même endroit (ou si elle ne bouge pas à la fin d'un recul), `maneuver_tick` renvoie un échec « sans issue » : `travel.start_stuck(car, tick, true)` ne propose aucun réessai, la voiture attend `stuck_abandon_delay` puis abandonne toutes ses tâches. La raison `blocked` commence directement par ce recul. Pour rester loin des murs, `wall_margin` ajoute `steering_cost.margin` par côté où un obstacle longe un point d'échantillon à environ une largeur de voiture (coût de `drive_tick` quand quelque chose est à portée, et score des caps de la manœuvre). Elle démarre sur `rear_turn` (cible derrière), `blocked` (arrêt net) ou `no_progress` (peu de déplacement sur `medium_delay`) ; une durée de trajet dépassée (`timeout`) va directement en `stuck`. Elle finit quand la densité est basse et le devant libre (plus l'angle pour `rear_turn`, plus `maneuver_min_travel` sinon) ; au-delà de `idle_delay` elle échoue, et après `max_maneuver_attempts` échecs la voiture est `stuck`.

Sortie de `high_speed` : `update_mode` mémorise la vitesse d'entrée (`entry_speed`) et lève `slowing` à la sortie ; `drive_tick` freine alors jusqu'à cette vitesse, sans descendre sous `speed.slow`.

Voisines : toutes les `slow_check_interval` ticks (décalés par l'id de la voiture, `_utils.slow_check_due`), `refresh_neighbours` liste les autres voitures en mouvement à proximité. Un point d'échantillon de `drive_tick` situé dans la zone devant l'une d'elles (largeur de la voiture, longueur de la voiture plus `speed * braking_duration`) coûte un `steering_cost.blocked` de plus. Les trains pourront rejoindre cette liste.

`stuck` : arrêt, alerte, attente `long_delay`, puis nouvel essai du même trajet (`stuck.destination`, sa tâche est restée en tête de file). Après `max_stuck_retries` essais, ou sans carburant pour le trajet, attente `stuck_abandon_delay` puis abandon : les ghosts du batch sont libérés (le joueur doit les resélectionner) et la voiture rentre par les tâches existantes (dépôt, charge, garage). Un trajet vers un chargeur est réessayé sans limite. `stuck_retry_count` est remis à zéro à l'arrivée, pas dans `begin_leg`.

`empty` : batterie à 0, la voiture ne fait que surveiller `critical_fuel_ratio` (alerte `battery_empty`), puis reprend son batch par `waiting`. Rien dans le mod ne recharge une voiture vide : le joueur la ramasse et la repose, ce qui crée une nouvelle voiture.

### Trajets et tâches

`travel.begin_leg(car, destination, next_task)` démarre un trajet et pousse `next_task` en tête de `car_data.tasks`. `travel.set_destination` fait de même après avoir vérifié le carburant, avec un détour par un chargeur si besoin : c'est la variante par défaut.

Une voiture est arrivée quand elle est à l'arrêt à moins de `config.arrival_distance` ; elle peut alors agir sur sa destination. `movement.drive_tick` lève l'événement `autonomous_car_next_task` ; `on_next_task` termine alors le trajet (`moving` désactivé), dépile la tâche et lui passe la destination atteinte : `charging`, `parking`, `building`, `collect` ou `deposit`. La fin de charge lève le même événement. Cet événement est synchrone : `on_next_task` s'exécute à l'intérieur de `drive_tick`.

Un trajet abandonné passe par `travel.cancel_trip(car_data)` : trajet, manœuvre, attente `stuck`, charge, tâches en file et place de chargeur (`release_charger_slot`, qui couvre le trajet vers le chargeur comme la charge). `travel.reset_to_waiting` ajoute l'arrêt de la voiture et le retour en `waiting` (`_utils.start_waiting`). `begin_leg` désactive `waiting` : un appel qui démarre un trajet n'a pas à le faire lui-même, et un échec de `set_destination` remet la voiture en `waiting`.

Un nouveau type d'étape est une tâche de plus dans `on_next_task`, pas un nouvel état.

### Construction

Sélection du joueur → `on_area_selected` → `register_ghost` (ignore les ghosts couverts par un réseau logistique) → `build_clusters` → tous les clusters vont dans `storage.pending_clusters` → `retry_pending_clusters` : `find_available_car` (voiture en `waiting` au coffre vide, sinon sortie d'un garage) → `assign_cluster`, qui crée `car_data.construction` et appelle `fill_batch`.

Un batch peut contenir plusieurs clusters : `fill_batch` ajoute les clusters en attente les plus proches tant que la somme de leurs slots tient dans le coffre (`config.car_inventory_size`). Les slots se comptent cluster par cluster (`items_slots`), jamais partagés. `construction.ghosts` et `items_needed` fusionnent les clusters ; `construction.clusters` garde, par cluster, ses ghosts et ses items.

`ghost_control.proceed` est le point de décision unique, rappelé après chaque étape : coffre d'approvisionnement (`collect`), trajet vers le chantier (`go_to_site`), ou attente avec alerte si aucun coffre n'aide (`construction.missing_since`, que `gui.lua` lit). Après `long_delay` d'attente, les clusters dont les items manquent retournent dans `storage.pending_clusters` si un autre cluster du batch est complet (`release_unsupplied_clusters`). `go_to_site` choisit le ghost prêt le plus proche, quel que soit son cluster, et fait de ce cluster le chantier (`construction.site`) ; il passe par `travel.set_destination` : c'est lui qui fait recharger la voiture entre deux clusters. Sur place, `building_tick` construit un ghost à la fois, seulement parmi ceux du chantier (`revive` n'a pas de portée : sans cette limite la voiture construirait tout le batch depuis son premier arrêt) ; quand plus aucun n'est prêt (`attempt_one_ghost` renvoie `none`), il rappelle `go_to_site`, qui mène la voiture au cluster suivant, ou la recule si seuls restent des ghosts en attente de réessai. Un ghost du batch qui disparaît sans que la voiture l'ait construit retire ses items de `items_needed` et du cluster (`drop_ghost_items`, d'après l'item noté dans `construction.clusters[].ghosts` à l'ajout du cluster) ; `finish` dépose les restes (`deposit`) puis prend un cluster en attente ou repasse en `waiting`. Le dépôt remplit tout le groupe de coffres, puis le coffre suivant qui a de la place ; sans place, alerte `supply_full`, la voiture garde ses items et `end_wait` réessaie (une voiture au coffre non vide ne prend ni batch ni garage).

### Carburant

La voiture brûle un carburant caché, sans slot : la charge est `burner.remaining_burning_fuel`. Un brûleur vide perd son item de carburant et ignore alors toute écriture de la charge : lire et écrire la charge uniquement par `_utils` (`remaining_fuel`, `fuel_ratio`, `set_fuel`), qui remet l'item en place. `charger_data.users` est réservé au départ vers le chargeur.

Estimation : `charger_control.fuel_to_reach` (aller seul, `find_charger`) et `fuel_needed` = aller + `fuel_reserve` (trajet de la destination au chargeur le plus proche, places libres ignorées, plus `critical_fuel_ratio`). `set_destination` détourne par un chargeur si la charge ne suffit pas ; réservoir plein et toujours insuffisant : `mark_unreachable`. Recharge d'urgence : `handle_critical_fuel` compare la charge à `fuel_reserve` depuis la position de la voiture, recalculé toutes les `slow_check_interval` ticks.
`fuel_per_tile` reste approximatif : aucune estimation n'est meilleure que lui. Garage : `repair_parked_cars` rend `garage_repair_rate` de santé aux voitures garées toutes les `long_delay`.

## Invariants

- `building.active` n'est vrai qu'une fois la voiture arrêtée sur son chantier ; pendant un trajet c'est `car_data.construction` qui indique un batch en cours. `building` et `construction` ne se confondent pas.
- `moving.destination` peut être une table `{position, valid}` (waypoint de `step_back`) au lieu d'une entité : n'en lire que ces deux champs.
- `stuck` est un état de repli, pas une courte pause.
- Le mode précision est inachevé (actif en zone dense seulement) ; le propriétaire compte le reprendre, ne pas le traiter comme du code mort.
- `emergency_brake` ne s'applique que dans `drive_tick`, jamais en manœuvre.
- Pas de migration : le mod n'est pas publié, les nouveaux champs de `car_data` (`maneuver`, `empty`, `stuck.*`) imposent une nouvelle sauvegarde.
- Le script ne règle jamais l'orientation de la voiture, seulement `riding_state`. Constaté en jeu : en marche arrière, braquer à gauche envoie l'arrière de la voiture à sa gauche, donc l'orientation tourne dans l'autre sens (`REVERSE_STEERING_INVERTED = true` dans `movement.lua`) ; à revérifier en trace après la reprise de la manœuvre.
- Ce que les prototypes et les scripts doivent partager est défini une seule fois dans `config.lua` : les noms (`config.names`), la taille de la voiture (`config.car_size`, dont dérivent les sondes de manœuvre), les tailles d'inventaire. Ne jamais réécrire l'une de ces valeurs en dur ailleurs. Les noms sont enregistrés dans les sauvegardes : ne pas les changer sans accord. Ils servent aussi de clés dans `locale/` : un prototype ajouté ou renommé y a sa ligne dans chaque langue.
- Un prototype copié du jeu (`table.deepcopy`) garde tous les champs de l'original : `icons` l'emporte sur `icon`, `hidden` reste vrai (cas du chargeur, copié de l'interface d'énergie). Les vérifier à chaque copie.
- `config.lua` se termine par des vérifications (`assert`) des relations entre constantes dont le code dépend ; en ajouter une quand une nouvelle constante doit rester cohérente avec une autre.

## Conventions de nommage

- État : `car_data.<état>.active`, avec `since` pour le tick de début.
- Entités : `car`, `charger`, `garage`, `chest`, `ghost`, sans suffixe ; leurs données en `<entité>_data`. `destination` est l'entité ou le waypoint visé, `target` sa position.
- Fonctions : verbe en premier pour une action ; `find_*` pour une recherche, `alert_*` pour une alerte, `start_*` pour entrer dans un état. Une fonction qui calcule une valeur ou répond à une question peut porter le nom de ce qu'elle renvoie (`fuel_needed`, `obstacle_density`, `wall_margin`) ou une forme interrogative (`fits_at`, `can_turn`, `is_blocked`, `in_neighbour_zone`). Une alerte répétable passe par `_utils.alert_once` / `alert_reset`.
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
2. manœuvre : `rear_turn_min_angle`, `rear_turn_max_speed`, `maneuver_*`, `friction_maneuver_factor`
3. densité et précision : `high_speed_density`, `dense_area_threshold`, `precision_*`
4. vitesse : `friction_*`, `speed.*`
5. `density_radius`, `lookahead_*` et `steering_cost` si le problème persiste

| Symptôme | Constantes à regarder |
|---|---|
| oscille autour de la destination | `arrival_distance`, `emergency_brake_lookahead`, `precision_*`, `dense_area_threshold` |
| manœuvre à tort, ou trop tôt | `rear_turn_min_angle` (à augmenter), `rear_turn_max_speed`, `short_delay` (déclencheur `blocked`) |
| manœuvre qui n'aboutit pas | `idle_delay` (durée maximale), `short_delay` (recul, nouveau cap), `maneuver_exit_density`, `maneuver_exit_angle`, `maneuver_min_travel`, `maneuver_probe.*`, `friction_maneuver_factor` |
| s'arrête trop souvent en trajet | `density_radius`, `lookahead_length`, `dense_area_threshold`, `emergency_brake_lookahead`, `steering_cost` |
| trop rapide ou trop lente | `friction_*`, `high_speed_density`, `braking_duration` |

La friction agit sur le symptôme, pas sur la cause : régler d'abord les seuils de décision. Un seuil de densité se choisit en sachant que la voiture se compte elle-même (environ 0,035 dans un disque centré sur elle, 0,024 dans la densité mélangée de `update_mode`). La manœuvre doit rester une exception.

À vérifier en jeu après un réglage : ligne droite sans oscillation, cible derrière sans demi-tour inutile, arrêt propre près d'un obstacle, zone dense sans faux `stuck`, cluster construit sans arrêt inutile, recharge puis parking, plusieurs voitures sans blocage mutuel.

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

1. **Manœuvre dans un espace très étroit.** Avant la refonte de la manœuvre, dans une pièce de 5×5 murée, la voiture mettait jusqu'à ~3 cycles de manœuvre pour retrouver une ouverture d'une tile. Le choix d'un cap devrait le résoudre : à revérifier avec le scénario `sealed`.
3. **Carburant non calibré.** `fuel_per_tile` est approximatif : toute estimation (aller, retour, seuil critique) en hérite. À calibrer en jeu.
5. **Place de chargeur prise dans `basics`.** Le chargeur de la zone aux murs et aux arbres (11000, 0) garde `users = 1` en fin de scénario, sans voiture qui le vise. Cause non trouvée (à tracer avec `tests\show.ps1 basics -Car 62` et `-Car 63`). Deux fuites de places ont été corrigées à la lecture (voir « Corrigés ») mais aucune n'arrive dans ce scénario : aucune voiture n'y est détruite et aucun batch n'y finit pendant une charge.
6. **Coût de `wall_margin` dans `drive_tick`.** La marge double les appels à `can_place_entity` (un par point d'échantillon et par côté) dès qu'une entité autre que la voiture est à portée (`near`, presque toujours vrai en terrain naturel) : environ 20 appels de plus par voiture et par tick. À mesurer en jeu avec plusieurs voitures ; piste : ne recalculer la marge que toutes les `slow_check_interval` ticks.

### Corrigés, à valider

Passe de nettoyage de `plan/rework-report` (code relu et essayé sur une fausse API Factorio : Factorio n'a pas été lancé, rien n'est vérifié en jeu) :

- **Voiture qui ne retrouve pas l'ouverture d'une pièce étroite** (ancien problème 4). Dans `sealed`, la voiture A était déclarée sans issue avant l'ouverture du mur (abandon à t ≈ 2330) : `maneuver.blocked` retenait un calage en ligne droite pour toujours, si bien que le calage contre le mur d'en face (plusieurs tiles plus loin) concluait « bloqué des deux côtés ». `back_off` note maintenant la position et l'orientation du calage, et `is_blocked` ne le tient pour valable que si la voiture est à moins d'une longueur de voiture et n'a pas tourné de `lookahead_angle`. Cause trouvée à la lecture du code, pas à la trace. À valider avec `tests\show.ps1 sealed -Car 38` : la voiture A doit trouver l'ouverture ouverte à t = 600 ; la voiture B finit par abandonner, mais avec les réessais de son trajet (plus long qu'avant) tant qu'elle peut traverser la pièce. Si A ne trouve toujours pas l'ouverture, rouvrir le problème : l'autre piste est le choix du cap (12 secteurs de 30° sur 5.5 tiles de portée, qui ne visent pas une ouverture d'une tile).
- **Deux fuites de places de chargeur** (trouvées en cherchant le problème ouvert 5, qui reste ouvert). Le gestionnaire de libération d'une voiture détruite, ramassée ou perdue ne rendait pas la place d'un chargeur visé ou en cours d'utilisation, et `finish` (dernier ghost détruit pendant une charge) laissait la voiture en `charging`, à charger sans chargeur à portée. `travel.release_charger_slot` couvre maintenant le trajet vers le chargeur et la charge, et `travel.cancel_trip` l'appelle. À valider : détruire une voiture en route vers un chargeur ou en charge, puis lire `users` du chargeur (scénario à écrire, ou en jeu).
- **Voiture sans aucun état actif** (`end_wait`). `ghost_control.deposit_leftovers` renvoyait `true` même quand `set_destination` échouait (aucun chargeur, trop loin) : `end_wait` désactivait alors `waiting` sur une voiture déjà remise en `waiting`, qui ne faisait plus rien. `deposit_leftovers` renvoie le résultat de `set_destination`, et `end_wait` ne touche plus à `waiting.active` (`begin_leg` s'en charge).
- **Plusieurs clusters : la voiture ne se déplaçait pas d'un cluster à l'autre.** `building_tick` prenait le ghost le plus proche de tout le batch, et `revive` n'a pas de portée : tout le batch était construit depuis le premier arrêt, sans recharge entre les clusters. La voiture ne construit plus que les ghosts du chantier (`construction.site`) puis `go_to_site` la mène au cluster suivant. À valider avec `construction` : les lignes `BATCH` et la position de la voiture (la voiture doit se déplacer entre les clusters, et recharger si besoin).
- **Items d'un ghost disparu.** `items_needed` n'était pas mis à jour quand un ghost du batch disparaissait sans que la voiture l'ait construit (joueur, robots) : la voiture attendait des items inutiles et la fenêtre en affichait le manque. `drop_ghost_items` les retire (ceux déjà chargés restent dans le coffre et sont déposés à la fin). À valider avec `construction` (ghost détruit à t = 1700).
- **`charge_detour_count` bloqué au-delà du maximum.** Il est remis à zéro quand un but inatteignable est abandonné (`mark_unreachable`), pour que le batch suivant ait son budget de détours.
- **Doublons supprimés, sans changement de comportement voulu** : `travel.cancel_trip` (état d'un trajet abandonné, auparavant recopié dans `reset_to_waiting`, `handle_critical_fuel`, `handle_empty`, `finish`), `_utils.start_waiting`, `stop_parking` (park.lua), `fuel_for_distance` (charge.lua), `SENSOR_REACH` et `density_ahead` (movement.lua), `try_add` dans `build_clusters`, `set_body` dans `gui.lua`. Seules différences relevées par comparaison de l'ancien et du nouveau code sur une fausse API : `moving.destination` et `moving.departure_tick` sont remis à nil quand un trajet est abandonné, et une voiture abandonnée par `finish` ou `reset_to_waiting` n'a plus de manœuvre ni d'attente `stuck` actives. Pour le vérifier : `tests\run.ps1 -Reference <version du commit 7d4e793>` ; des traces identiques sont attendues sauf pour `construction` (déplacements entre clusters), `sealed` (voir plus haut) et, dans les autres scénarios, une voiture qui était déclarée sans issue.
- **Contrôles de cohérence** : `config.lua` vérifie maintenant que `lookahead_start` et `precision_lookahead_start` dépassent la demi-longueur de la voiture plus sa demi-diagonale (la première sonde ne doit pas chevaucher la voiture). Les listes d'usage des délais de `config.lua` sont à jour.

Refonte de la branche `plan/rework-report` (scénarios lancés, jeu non essayé) :

- **Boîte de la voiture tournée dans les sondes.** `fits_at` (movement.lua) passe à `can_place_entity` la direction (sur 16) de l'orientation testée : la boîte n'est plus celle d'une voiture tournée vers le nord. `lookahead_start` passe à 1.3 (minimum environ 1.11, noté dans `config.lua`), testé avec `garage-exit` : chargeur atteint en 180 ticks au lieu de 200 tiles parcourues en trop. `precision_lookahead_start` passe aussi à 1.2.
- **Friction de la tuile.** `set_friction` divise les facteurs de mode (base, haute vitesse, précision, manœuvre) par `vehicle_friction_modifier` de la tuile sous la voiture, lue à chaque calcul (chaque tick) ; le facteur d'urgence n'est pas divisé (freinage). La friction est recalculée à zéro à chaque tick, rien ne s'empile (vérifié dans la trace de `sealed` : 0.625, 2.5, 6.25). Les vitesses sur l'herbe (friction 1.6) augmentent donc d'autant par rapport à avant : à régler en jeu.

- **Portes.** La voiture n'a pas `can_open_gates` : `open_gates` (movement.lua), appelée par `update_mode` toutes les `slow_check_interval` ticks, appelle `gate.request_to_open(car.force, slow_check_interval)` sur les portes de sa force à portée (anticipation de la vue plus freinage). Scénario `gate` : la porte est franchie (construction à t = 2300 au lieu de 6220 en longeant le mur) ; à valider en jeu.
- **Suivi de mur, marge et voiture sans issue** : `back_off` longe le mur, `wall_margin` écarte la voiture des murs, deux sens bloqués depuis le même endroit = stuck sans réessai puis abandon (scénario `sealed`). À valider en jeu, avec le braquage en marche arrière.
- **Manœuvre reprise** : cap puis arcs, arc complémentaire interdit, recul sur obstacle invisible. Vérifier en jeu l'absence d'oscillation et `REVERSE_STEERING_INVERTED` (une voiture qui revient sur ses pas braque dans l'autre sens).
- **Freinage à la sortie de `high_speed`** : vérifier l'absence de freinages parasites près du seuil `leave`.
- **Plusieurs clusters par voiture**, avec retour des clusters sans items dans la liste d'attente après `long_delay`.
- **Dépôt** dans tout le groupe de coffres puis dans le suivant, alerte `supply_full`, une voiture au coffre non vide ne prend ni batch ni garage.
- **Estimation du carburant** avec retour au chargeur, seuil d'urgence selon la distance au chargeur, recharge entre deux clusters (`go_to_site` passe par `set_destination`).
- **Évitement des voitures en mouvement** (zone devant chaque voisine).
- **Fenêtre des objets manquants** (raccourci, `gui.lua`) : prototype donc redémarrage de Factorio ; l'icône est provisoire.
- **Réparation lente des voitures garées** : vérifier que la santé de l'item passe bien à la voiture (`release_car`).

- **Erreur de script dans `charge.lua`** (scénario `stale-task`). Une voiture en route vers un chargeur gardait `waiting.active` et recevait un batch ; sa tâche `charging` s'exécutait ensuite à l'arrivée d'un `step_back`. `begin_leg` désactive maintenant `waiting`, et `on_next_task` abandonne une tâche `charging` ou `parking` dont la destination atteinte ne correspond pas.
- **Places de chargeur non libérées sur un trajet remplacé ou un batch terminé.** `begin_leg` (leg remplacé) et `ghost_control.finish` rendent la place par `travel.release_charger_slot` ; voir plus haut pour les autres chemins.
- **Garage rempli pendant le trajet.** `parking_tick` remet la voiture en `waiting`.
- **`charge_detour_count`.** Il n'est plus remis à zéro par `begin_leg` mais à l'arrivée à une destination qui n'est pas un chargeur (`on_next_task`), dans `finish` et à l'abandon d'un but inatteignable : les détours d'un même trajet s'additionnent.
- **Surfaces multiples.** `_utils.closest` prend la surface en paramètre ; chargeurs, garages, coffres, voitures et clusters en attente sont filtrés par surface.
- **Tâche en file après un `reset_to_waiting`.** `reset_to_waiting` vide la file, et `end_wait` abandonne les tâches périmées.

Plus anciens :

- **Voiture bloquée à la sortie du garage.** `release_car` la pose contre le garage ; quand sa cible était derrière elle, elle reculait dans le garage. Le mode manœuvre le résout dans les scénarios `garage-exit` et `construction`, qui construisent maintenant tous leurs ghosts : reste à valider en jeu.
- **`stuck_retry_count` jamais atteint.** Il est maintenant remis à zéro à l'arrivée et non dans `begin_leg`, donc `max_stuck_retries` peut se déclencher : à valider en test (le scénario `sealed` passe par ce compteur).
- **`moving` restait actif après un `step_back`.** `on_next_task` le désactive quand la file est vide, et le scénario `garage-exit` (deuxième phase) construit maintenant son ghost : à valider en jeu.
- **Noms affichés en jeu.** Sans dossier `locale/`, entités, objets, raccourci et touche n'avaient pas de nom. `locale/en` et `locale/fr` les définissent maintenant, avec leurs descriptions. Factorio résout tous ces noms dans les deux langues (`--dump-prototype-locale`) : reste à les voir en jeu.
- **Icônes du chargeur et de la voiture.** Le chargeur et son objet, copiés de l'interface d'énergie du jeu, en gardaient l'icône (`icons` l'emporte sur `icon`) et l'objet restait caché (`hidden`) ; l'entité voiture utilisait l'icône du jeu. Tous utilisent maintenant l'icône du mod et l'objet chargeur n'est plus caché : à valider en jeu.
