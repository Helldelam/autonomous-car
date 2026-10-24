# CLAUDE.md

Mod Factorio 2.1 (Lua 5.2) « Autonomous Car » : des voitures qui travaillent hors réseau de robots (ghosts, remblai, démontage, mise à niveau), se rechargent et se garent seules. Seule documentation du projet. Tout ce qui est décrit ici est validé en jeu par le propriétaire, sauf mention.

## Règles de travail

- Bug : trouver la cause au niveau du tick avant de corriger ; changements petits, helpers et API existants, pas de second système d'état. Une incohérence lue n'est un bug qu'une fois confirmée (jeu, scénario, propriétaire).
- Tests sur demande seulement, en demandant avant chaque lancement avec sa durée (une catégorie : 1 à 18 min ; campagne avec `-Reference` : environ 45 min). Cloud : pas de Factorio, vérification statique seule.
- Tests lourds (deux catégories ou plus, `-Reference`, balayage `-Set`) : un `run.ps1` par catégorie en parallèle, chacun avec son `-Output`, sans scinder une catégorie (numéros d'entités, donc traces, changés) ; au plus 6 processus Factorio, autres sessions comprises (`Get-Process factorio`). Durée annoncée : la plus longue catégorie ; règle des 2 fois par processus.
- Mise au propre : campagne complète, scénarios redondants regroupés ou retirés, nouvelle base notée ; ce fichier réduit sans perdre décisions, limites, essais écartés et mesures utiles.
- Git : `main` est la référence choisie par le propriétaire, pas une version validée. Travail sur une branche à part ; commit, push et fusion seulement sur demande.
- API : la doc locale (`doc-html`, 2.1.23) fait foi. Nouvelle version du jeu : comparer `runtime-api.json` et `prototype-api.json` (l'ancienne sur `lua-api.factorio.com/<version>/`) et `data/changelog.txt`, puis proposer de revoir les contournements. Portage 2.0.77 → 2.1.23 : `fuel_categories`, `braking_force` = `friction_force` = puissance / 60, `circuit_connector` en liste, `robot_door`, `helpers.create_profiler`, plus de `crash_trigger()`. Nouveautés 2.1 revues : prises, `buffer` d'`apply_upgrade`, `add_custom_alert`, `set_tooltip_field`, pré-sélection, texte au curseur. Écartées : garage orientable (porte dessinée invisible), panneau du garage en `inventory` (voitures garées = fiches), `transfer_from_inventory` (prendrait batteries et slots verrouillés), `immune_to_all_impacts` (plus de contacts). Impossibles : tirer par script, animer un coffre pour une voiture, ignorer la voiture dans `can_place_entity`.
- Problèmes connus : ce que le joueur voit ou subit ; corrigé, il passe dans « Corrigés, à valider » jusqu'à validation du propriétaire.
- Code et commentaires en anglais, ce fichier en français. Aucun texte joueur en dur : chaîne localisée `{"autonomous-car-messages.<clé>", ...}` (`locale/<langue>/messages.cfg` ; noms, descriptions, fenêtres : `autonomous-car.cfg`), toujours en anglais et en français ; pluriels par `__plural_for_parameter__1__{1=…|rest=…}__`.
- Présentations (`README.md`, aussi description du portail ; `info.json` et `mod-description` dans le jeu) : mêmes faits, mises à jour avec chaque changement visible ; « non testé avec Space Age » (et en multijoueur pour le README) tant que ce n'est pas fait ; chacune finit par la mention de l'usage important de l'IA ; crédit du système de conduite à Pavement Drive Assist (Arcitos). Deux `.md` seulement : ce fichier et le README.

## Commandes

- Pas de build ni d'interpréteur Lua. Dossier du mod : `autonomous-car`, sans version (accepté par le jeu, aucun renommage à chaque version) ; encore `autonomous-car_0.1.3` jusqu'à ce que le propriétaire le renomme (jeu et sessions fermés ; déplacer aussi la mémoire de Claude, `~/.claude/projects/<chemin du dossier>`) : d'ici là, ce nom ne correspond plus à la version d'`info.json` (0.1.0), ce que la doc (`mod-structure`) interdit ; les scénarios ne sont pas touchés (copie nommée `autonomous-car`).
- Changement runtime : recharger la sauvegarde ; de prototype (`data.lua`, `prototypes/`, valeur de `config.lua` lue par un prototype) : redémarrer Factorio. Erreurs : `%APPDATA%\Factorio\factorio-current.log`.
- Vérification statique (quelques secondes ; `sumneko.lua`, `.luarc.json`, global manquant dans `diagnostics.globals` ; `--checklevel=Hint` signale aussi les variables masquées) :

```powershell
& (Get-Item "$env:USERPROFILE\.vscode\extensions\sumneko.lua-*\server\bin\lua-language-server.exe")[-1] --check . --checklevel=Warning --logpath="$env:TEMP\lua-check" --metapath="$env:TEMP\lua-check"
```

### Scénarios de test

`tests/` : exclu du zip publié (`.gitattributes`) ; le mod n'en charge rien.

```powershell
tests\run.ps1                                  # tout, une partie de Factorio par catégorie
tests\run.ps1 movement                         # une catégorie
tests\run.ps1 -Changed                         # catégories touchées depuis le dernier commit et leurs commandes ; ne lance rien
tests\run.ps1 maze, garage-exit -Ticks 8000    # des scénarios
tests\run.ps1 -Reference <dossier ou zip>      # compare les traces avec une autre version
tests\run.ps1 doors -Set "friction.slow=6" -Output $env:TEMP\essai1   # valeurs de config ; -Output pour le parallèle
tests\show.ps1 construction -Car 132           # états d'une voiture (hors dossier par défaut : chemin de la trace)
```

- `tests/harness.lua` : seule liste des scénarios (nom, `ticks` sinon 22 000, `category`, drapeaux de `show.ps1`). Greffé à la fin de `control.lua`, il en utilise les locales (`on_area_selected`, `names`, modules) : à mettre à jour si on les renomme.
- Une partie sans fenêtre ni joueur par catégorie, sur une copie du mod (jeu ouvert possible) ; une surface en herbe par scénario (sur les tuiles de laboratoire les voitures vont plus vite) ; une erreur de script arrête la catégorie. Trace `trace-<scénario>.txt` : `NOSTATE`, `EMERG` (frein d'urgence), `PATH`, `HEALTH` (contacts), `DONE <parcours> <tick>`, `EVENT`.
- Sélections du harnais (`select_ghosts`, `select_all`) en file, une à la fois après la fin de `storage.selection_job` : sinon refusées ou fusionnées, et des scénarios échouent sans que le mod y soit pour rien.
- `-Reference` : jeu déterministe, versions équivalentes = traces identiques ; la référence tourne avec son harnais (nommer les scénarios qu'elle a) ; pas de comparaison avec une version d'avant 2.1.
- `-Set` : `test_jitter=<n>` (départ ± 0,3 tile, ± 0,01 tour), `test_door_shift=1` (portes décalées d'une tile au plus), `test_research=<0|1|2>` (défaut : cargo et garage au niveau 2, le reste au 1 ; à 0, seul `modules` laisse 2 ghosts). `ONE_TILE_DOORS` (harnais) : portes d'une tile.
- `gif` (seul dans `capture`, hors campagnes) : `tests\run.ps1 gif -Set "test_capture=4"` ouvre une partie avec fenêtre (demander avant) et enregistre une image tous les 4 ticks dans `<Output>\write\script-output\gif`, puis `run.ps1` ferme le jeu. `--benchmark-graphics` s'arrête vers le tick 750 quelle que soit sa durée : partie ordinaire (`--load-game`), `SteamAppId` fixé (sinon Steam relance le jeu sans ses arguments). `autonomous-car-demo.gif` (racine, hors zip) : images 40 à 1000 assemblées avec PIL (800 × 450, palette de 64 couleurs échantillonnée aussi sur la voiture, sinon son bleu disparaît ; équilibre des blancs corrigé à 40 % (rouge × 0,9, vert × 0,98, bleu × 1,27 : la palette n'y est pour rien, les images brutes sont aussi chaudes) ; 12 images/s, attente du coffre accélérée). La scène est sur Nauvis à 120 tiles du point d'apparition, vidée autour (terre, herbe, étang) ; les teintes chaudes sont celles des tuiles du jeu (`grass-1` est la seule herbe verte), à refaire si le mod change visiblement.
- Provisoire : `crowd` (seul dans `scalability` ; `test_crowd=<n>`, `test_single=1`, `test_same=1`) et profileurs d'`install_profiler`.
- Base (2.1.23 ; checkup et mise au propre du 2026-10-24 : traces identiques à `cfb9985`) : `doors` 92/96 coffres et 73 contacts, `movement` 131 arrivées et 591 contacts, `energy` et `robustness` sans erreur (`range-*` : tous arrivés). Durées en parallèle : movement 18 min, energy 13, doors 11, robustness 5, construction 1.

Catégories (70 scénarios et `crowd`) :
- `movement` (14) : salles, murs, forêts (`forests`, 24 parcours), labyrinthes, `wall-corner`.
- `doors` (27), ouvertures de 3 tiles : `gates`, `gate`, `doors-clutter`, `doors-traffic`, `doors-odd`, `doors-base-1` à `6` (une base murée par scénario), `plain-base`, `garage-room`, 14 `series-<N>w-sp<S>-<f|b><a|s>`.
- `robustness` (12) : blocages, pannes, batterie vide, `technologies`, `armed*`, `flee*`, `batteries-*`.
- `construction` (8) : `rails`, `logistic-interface`, `construction`, `modules`, `cliffs`, `work`, `phases-single`, `network-parked`.
- `energy` (9) : `basics`, `garage-exit`, `circuit-links`, `critical-no-batch`, `range-*` (25 à 2500 tiles ; `test_long=1` jusqu'à 11 000, `test_tiles=0..5`), `regions`. Aucun n'atteint `travel.mark_unreachable`.

## Architecture

### Fichiers

- Racine : `info.json`, `data.lua` (catégorie et objet de carburant cachés, objet `locked_slot`, événement de fin d'étape, puis `prototypes/`), `control.lua` (événements, suivi des entités, tick), `config.lua` (lu par les deux étapes : noms et tailles partagés, puis réglages).
- `prototypes/` : `car` (et tourelle cachée), `charger`, `garage`, `chest` (approvisionnement, livraison, retour), `circuit` (liaison, signaux), `shortcuts` (sélecteur, raccourcis, touche), `technology`, `corpse` (restes, appelé par les autres).
- `graphics/` : seulement les images utilisées (scripts de génération et sources retirés le 2026-10-24 : `git show b0b202d:graphics/...`).
- Un module se charge partout par le même chemin pointé (`require("scripts.garage")`) : deux écritures le chargeraient deux fois.
- Dépendances sans cycle : `config` → `_utils` → `charger`, `garage`, `chest` → `travel` → `construction` → `control` ; `movement` : `config` et `_utils` seuls ; `gui` et `circuit` : en plus `garage`. D'où `requeue_construction` dans `travel`, et l'arrivée d'une voiture signalée par un événement. L'affichage ne fait que lire `car_data`.

| `scripts/` | Module | Rôle |
|---|---|---|
| `movement.lua` | `movement` | mode, direction, manœuvre, chemin, dégagement |
| `travel.lua` | `travel` | trajets, détours de recharge, stuck, abandon, fuite |
| `construction.lua` | `ghost_control` | sélection, clusters, affectation, construction, visites de coffre |
| `charger.lua` | `charger_control` | chargeurs, estimation du carburant, bornes et arcs dessinés |
| `garage.lua` | `garage_control` | voitures garées, réparation, porte animée |
| `chest.lua` | `chest_control` | trappe des coffres, requêtes des coffres de livraison |
| `circuit.lua` | `circuit_control` | liaison logique des garages et des chargeurs |
| `armed.lua` | `armed` | tourelle cachée de la voiture armée |
| `_utils.lua` | `_utils` | carburant, entité la plus proche, attente, deque, alertes, clés d'objets, libération d'entités |
| `gui.lua` | `gui` | objets manquants, panneaux du garage et de la voiture, infobulles, aperçu de sélection |
| `game_trace.lua` | `game_trace` | `/car-trace [unité]` (bascule, arrêtée par défaut) : `script-output/autonomous-car-trace.txt` chez qui la lance (le serveur depuis sa console) |

### État et tick

- `storage.cars[id]` l'entité, `storage.car_data[id]` son état (`create_car_data`) ; de même chargeurs et garages. `init_storage` au premier tick, qui est joué ; pas d'`on_init` ; `on_configuration_changed` vide le cache des recherches.
- Suivi dès la construction (`on_built`, `script_raised_revive`) et jusqu'au retrait (`on_removed`, aussi `script_raised_destroy` : autre mod, ou voiture qui démonte une entité du mod), événements filtrés sur les entités du mod ; entité invalide : `_utils.release_entity(kind, id)` ; ghosts : `on_object_destroyed`.
- `update_car`, première branche vraie : 1. batterie vide, carburant critique, danger ; 2. `moving` (`update_mode`, `maneuver_tick` ou `drive_tick`, `is_leg_too_long`) ; 3. `charging` ; 4. `parking` ; 5. `building` (un ghost par `build_interval`) ; 6. `stuck` ; 7. `waiting` (`end_wait`) ; 8. filet de sécurité : retour en `waiting`, `storage.idle_fallbacks`, `NOSTATE` (bug ailleurs).

### Charge par tick

Quelques millisecondes par tick au plus, quelle que soit la sélection. `crowd` (100 × 22 ghosts) : tick de sélection 1,1 → 0,4 s, de clustering 525 → 40 ms ; le « tick max » des tests (3 à 6 s) est la mise en place du scénario.
- Sélection : tâche `storage.selection_job` (`register`, `grid`, `cluster`), `selection_ghosts_per_tick` (200) ; une à la fois (une autre est refusée avec un message), aucune affectation avant sa fin ; cluster jamais coupé, au plus 200 ghosts.
- Voisins : grille de cellules de `cluster_radius`, 3 × 3 cellules (coût linéaire).
- Affectation : `assignments_per_tick` (2) lots par tick, reste dans `storage.assignment_backlog` ; un garage sort au plus `garage_exit.exits` voitures par `medium_delay` (`storage.assignment_wake_tick`).
- Plus proche (`_utils.find_closest` : `chargers`, `garages`, `supply_chests`) : index `storage.regions` par carrés de 64 tiles, anneaux arrêtés dès preuve, parcours complet après 2 ; même réponse que sans index (`regions`, 750 requêtes).
- Aperçu de sélection : 3 `count_entities_filtered` par changement du rectangle (très grande sélection non mesurée).
- `crowd` 100 (77 voitures) : pics de 788 et 380 ms (ticks 600 et 1200), puis 15 à 50 ms, 94 % dans les voitures (`drive_tick` ≈ 0,48 ms par voiture, accepté).
- Tâches étalées par `_utils.is_slow_check_due` (tick + numéro d'unité) : liaisons `short_delay`, tampons et réparation `long_delay`, filtres `slow_check_interval`, voiture en attente `idle_delay`. Livraison : une passe par `medium_delay`, `logistic_per_tick` par tick (`storage.logistic_job`). Clusters en attente remesurés en continu (`refresh_pending_clusters`, 200 ghosts par tick, une passe par `long_delay`).

### Conduite

- `update_mode` fixe `mode` (`fast`, `normal`, `slow`), `emergency_brake`, `friction_modifier` (recalculé), demande un chemin ou une manœuvre ; `drive_tick` les lit au même tick : ordre fixe.
- Densité (deux disques), `near_built`, friction de la tuile : toutes les `slow_check_interval` (mode en retard de 6 ticks au plus, frein d'urgence à chaque tick ; `update_mode` -32 %).
- `slow` : à moins de `built_zone_distance` d'un bâti de sa force, au-dessus de `dense_area_threshold`, ou `medium_delay` après frein d'urgence, manœuvre ou fin de chemin. Près d'un bâti, `normal` (jamais `fast`) si la cible est dans le cône `path_trigger.half_angle`, à plus de `normal_beside_built_distance`, hors porte et en ligne droite libre. Sortie de `fast` : freinage, pas sous `speed.slow`.
- Frein d'urgence : un événement (arrivée à `arrival_distance`, obstacle à `emergency_brake_lookahead`), seulement dans `drive_tick`, jamais en manœuvre ni en suivi de chemin (il calait la voiture).
- Direction : 3 caps (tout droit, ± `lookahead.angle`) notés par des points d'échantillon ; densité lue avant la cible seulement, × `path.density_factor` en suivi de chemin ; coûts : obstacle à une largeur de voiture (`steering_cost.margin`), écart au chemin au-delà de `path.corridor` (`path_deviation`), voiture en mouvement devant (`blocked`, `refresh_neighbours`).

### Manœuvre

Sous-mode de `moving`, lent (`friction.maneuver`), avant ou arrière. Recours : manœuvre, chemin, dégagement, `stuck`.
- Départ sur arrêt net seulement (vitesse nulle, loin du but, `short_delay` après le départ ou la manœuvre précédente) ; trajet trop long : chemin directement.
- Cap (`choose_heading`, gardé `short_delay`) : `1 / lookahead.angle` secteurs notés par l'espace libre et la densité (sans elle, `u-narrow` 13/20). Arc (`choose_arc`, 6 choix) : la voiture y tient, tourne vers le cap, avant, espace libre ; bloquée devant et derrière, un arc qui braque compte comme libre.
- Sondes tous les 0,5 tile (mur en pierre : 0,58) ; avant `maneuver.probe.start`, `find_entities_filtered` (`can_place_entity` verrait la voiture).
- Recul (`back_off`, sous `speed.stopped` pendant `short_delay`) : tout droit en sens inverse, longe le mur (`follow`) par longueurs de voiture en tentant un virage de `lookahead.angle`. Virage qui cale : même sens (deux fois au même endroit : inversé) ; calage en ligne droite : sens marqué bloqué, autre sens ; deux sens bloqués ou aucun mouvement : échec. Sur arrêt net, la manœuvre commence par ce recul.
- Fin : densité sous `exit_density`, devant libre, `min_travel` parcouru ; un essai d'au plus `idle_delay`.
- Retirés (`u-side`, `u-narrow` : 20/20 sans eux) : `rear_turn`, hystérésis du cap, interdiction de l'arc complémentaire, `can_turn`, `wedged`, `no_progress`. À garder (sauf nouvelle campagne) : densité du cap, recul sur arrêt net, `follow`, virage bloqué devant et derrière, chemin de secours.

### Chemin (section « Path » de `movement.lua`)

- `car_data.path`, remis à zéro par `begin_leg`. `surface.request_path`, une par `medium_delay` au plus : boîte + `path.margin` (0,4), `low_priority`, sans cache, `can_open_gates` (pathfinder asynchrone, budget fixe par tick). Secours (`request_path`, `path.max_requests`) : manœuvre échouée ou trajet trop long. Guidé (`request_guided_path`, `path_trigger.max_requests`) : zone bâtie ou dense, but hors du cône `half_angle`, ligne droite bloquée.
- But (`choose_path_goal`) : la destination, ou au-delà de `goal.range` le point le moins dense parmi `2 × sectors + 1` directions, plus `angle_cost` par pas d'écart.
- Attente freinée (`wait_for_path`) ; réponse `on_script_path_request_finished` (`try_again_later` : renvoi après `short_delay`) ; rien après `long_delay` : la voiture reprend. Le chemin redéfinit la durée admise du trajet.
- Suivi : angles et un point par `lookahead.length` ; `get_target` = waypoint courant (arrivée et frein restent ceux de la destination) ; waypoint passé à moins de deux longueurs de voiture, ou son plan dépassé à moins de `pass_radius`.
- Portes : `add_gate_waypoints` (points le long du mur repoussés jusqu'à `gate_waypoints.clear`, point devant la porte sur son axe, point de sortie) ; axe tiré des murs voisins (`measure_gate_axis`).
- Demi-tour (début de `drive_tick`) : waypoint à moins de `pass_radius` et à plus de `u_turn_angle` du cap : recul en braquant vers lui jusqu'à l'avoir devant, fin sur calage ou après `idle_delay`. Un par waypoint ; un deuxième par chemin seulement sous `dense_area_threshold`.

### Dégagement (section « Clearing »)

- Demandes de secours épuisées et arbre ou rocher à moins de `clearing.lookahead` ; ensuite à chaque arrêt net du trajet, `clearing.max_count` fois au plus.
- Sous-mode de la manœuvre (`idle_delay` ou `clearing.travel` au plus) : détruit `tree` et `simple-entity` autour (`clear_radius`) et devant (`reach`), sans rien ramasser ; cap toutes les `short_delay` (obstacles × `obstacle_cost` + écart ; secteur contenant autre chose écarté).
- Jamais un bâtiment, un mur ni une falaise. Arbres par `type`, pas par `collision_mask` (écrasés à pleine vitesse, pas à basse vitesse). `forests` 17/24 → 24/24 (96/96 en jitter).

### Stuck, batterie vide, batteries

- `stuck` : arrêt, alerte, `long_delay`, nouvel essai du trajet ; après `stuck.max_retries` ou sans carburant : `stuck.final` (`abandon_delay`) puis abandon (ghosts libérés, retour par dépôt, charge, garage). Vers un chargeur : essais illimités sans batch. `stuck_retry_count` remis à zéro à l'arrivée.
- `empty` (batterie à 0) : attend la charge (alerte `battery_empty` sans batterie), puis reprend.
- Batteries : dernier slot du coffre (`set_trunk_limits`, toutes les `slow_check_interval`) ; une batterie = `battery_fuel_ratio` (moitié du seuil critique), brûlée sous `battery_trigger_ratio` (le quart) ; comptées dans la portée vers un chargeur (`get_reachable_fuel`). `restock` avant de se garer et à la sortie du garage (`just_left_garage`) ; au garage, dans la fiche.

### Technologies (`prototypes/technology.lua`, coûts validés le 2026-10-24)

- `autonomous_car` (Automobilism, Battery, Electric engine ; la voiture coûte un `electric-engine-unit`) : voiture, chargeur, garage, coffre. `autonomous_car_repair` (+ `automation-3`) : réparation au garage. Armement : `military` du jeu.
- 5 améliorations à 2 niveaux (`config.upgrades`, `_utils.get_upgrade`, effet `nothing` décrit par la locale) : `cargo` 20/30/40 slots, `garage` 30/40/50, `chargers` 2/4/8, `charge_speed` et `build_speed` ×0,5/1/2.
- Capacité par filtres (pas `set_bar`) : coffre du prototype de 41 slots (`car_inventory_size`), batteries après le chargement, slots suivants verrouillés par `names.locked_slot` ; un objet refusé sort du slot. Tampon du chargeur : (voitures + 0,5) × réservoir.
- Réparation : toutes les `long_delay`, `garage_repair_rate` par voiture, kit usé d'autant.
- Cache `storage.research` par force, vidé par `on_research_finished` / `on_research_reversed` ; filtres remis à la construction puis périodiquement. Console : `/c game.player.force.technologies["nom"].researched = true`.

### Garage

- Voiture garée = fiche de `storage.garage_data[id].cars` (premier arrivé, premier sorti : `quality`, `health`, `fuel`, `batteries`, `ammo`) ; `parking_tick` l'ajoute et détruit la voiture, `release_car` la recrée.
- Slots : 1 voiture (joueur ou inserter, rangée toutes les `slow_check_interval` ; neuve : `critical_fuel_ratio`), 2 batteries, 3 munitions (verrouillé avant Military), puis kits (verrouillés avant la recherche). Les slots 2 et 3 rechargent la voiture sélectionnée du panneau (une pile au plus).
- Panneau : liste et bouton « sortir » (la sélectionnée, sinon la première) : `hand_out_car` donne voiture (santé et charge dans l'étiquette), batteries et munitions, tout ou rien ; remise au slot 1, elle garde santé et charge ; posée, elle repart neuve.
- Porte (un `container` n'a pas d'animation) : à l'entrée ou la sortie, le script dessine intérieur et porte, qui glisse vers le haut (un sprite rogné par étape) : `move_ticks`, `hold`, fermeture ; la voiture reste visible `enter_delay` ticks (`parking.door_tick`) ; à la sortie, `release_car` rend nil jusqu'à `release_tick` (`get_next_release_tick` relance l'affectation). `storage.garage_doors` : portes en mouvement seulement. Géométrie : `config.garage_door` (à refaire si le sprite change).
- Miné : `return_cars` rend tout au tampon de minage, sinon au joueur, sinon au sol ; détruit : au sol.

### Chargeur

- `electric-energy-interface` (pas d'animation de charge, réservée à `accumulator` : non essayé). Bornes dessinées par le script, une par place (`config.charger_visual` : 2 places sur une diagonale, 4 sur les deux, 8 en bornes dédoublées sur un support, `split_posts`), revues avec le tampon (`long_delay`) ; arc animé sur la borne de chaque voiture en charge (`refresh_arcs`, toutes les `short_delay`). `charger_data.posts`, `storage.charger_arcs`.

### Coffres

- Approvisionnement (jaune, `container`), livraison (bleu, demandeur), retour (violet, fournisseur actif) ; recette : coffre d'approvisionnement + coffre du jeu.
- Trappe : le jeu n'anime un coffre logistique que pour un joueur ou un robot ; pour une voiture, `chest_control` dessine intérieur et trappe (`storage.chest_doors`, géométrie `config.chest_door`).
- Visite (`collect`, `deposit`, `restock`) : `ghost_control.start_chest_visit` ouvre tout le groupe de coffres, la voiture attend `transfer_delay` (10 ticks) en `waiting` sans prendre de batch (`storage.chest_visits`) ; `update_chest_visits` (avant les voitures) transfère, puis la trappe se ferme après la dernière voiture (`users`). Une voiture qui n'attend plus (danger, batterie vide) ne transfère rien. Traces : 10 ticks de plus par visite.
- Livraison (`update_requests`) : pour chaque voiture dont il est le coffre de livraison le plus proche, ce qui manque à son batch moins le contenu des autres coffres de la surface. Retour : préféré pour déposer. Robots réels vérifiés en jeu seulement (les scénarios remplissent le coffre).

### Liaison logique (`circuit.lua`)

- `names.link` (combinateur constant sans collision, non minable, hors blueprints) au coin sud-est du garage ou sous le chargeur, remplie toutes les `short_delay`. Garage : objet voiture (garées), `free_places`, `health` et `charge` (%) ; chargeur : `buffer` (%), `power` (kW), `users`. Un blueprint de garage perd les fils de sa liaison.

### Voiture armée

- Un seul prototype (`vehicle-machine-gun`, `allow_passengers = false`), armé avec Military (`_utils.is_armed`) : un second prototype changerait les `unit_number`.
- Tir par script impossible : `armed.update` pose une tourelle cachée (portée 20) qui reçoit une copie du slot `car_ammo`, lequel fait foi.
- Munitions (`ammo_items` : uranium, perforantes, normales) : la plus forte du groupe de coffres, une plus faible échangée, type hors liste jamais ; gardées dans la fiche.
- Mesuré : 4 petits mordeurs pour 1 chargeur, sans dégât ; 2 mordeurs moyens (`armed-ammo`) : normales, voiture morte ; perforantes, 1 tué ; uranium, 2 tués sans dégât. Bonus de la force appliqués, pas celui de `gun-turret`.

### Fuite du danger

- `handle_danger`, toutes les `slow_check_interval` : ennemi dans `flee.radius`, ignoré en carburant critique.
- Refuge (`find_refuge`) : chargeur ou garage le plus proche à l'opposé de l'ennemi, à `max_refuge_distance` (150) au plus et à portée ; sinon point libre à 150 tiles, quelle que soit la charge (choix du propriétaire).
- `start_flee` : trajet annulé (batch gardé), tâche `flee`, `long_delay`, reprise ; après `flee.max_count` fuites, abandon du batch ; sans batch, ennemi ignoré.

### Trajets et tâches

- `travel.begin_leg(car, destination, next_task)` : trajet et tâche en tête de `car_data.tasks` ; `set_destination` vérifie d'abord le carburant (détour par un chargeur), échec : `waiting`.
- Arrivée (à l'arrêt, à moins de `arrival_distance`) : événement `autonomous_car_next_task`, `on_next_task` (synchrone) dépile la tâche (`charging`, `parking`, `building`, `collect`, `deposit`, `restock`, `flee`) ; fin de charge : même événement. Une nouvelle étape est une tâche, pas un état.
- `cancel_trip` (trajet, manœuvre, `stuck`, charge, stationnement, tâches, place de chargeur) ; `reset_to_waiting` arrête en plus la voiture.
- Rails : à l'arrivée, rail au sol dans `rails.scan` (3) : `start_retreat` vers le point sans rail le plus proche à moins de `rails.clearance` (3,5), en ligne droite, tolérance `rails.reach` (2 ; à 1,5 la voiture bouclait).

### Construction

- Flux : `on_area_selected` → `storage.selection_job` (`register_ghost` ignore ce que couvre un réseau logistique et ce qui est déjà suivi) → `storage.pending_clusters` → `retry_pending_clusters` → `find_available_car` (en attente, coffre vide, carburant non critique, sinon sortie d'un garage) → `assign_cluster` → `fill_batch`.
- Cibles : ghosts d'entité ou de tuile, marques de déconstruction (arbres, rochers, bâtiments, falaises) et de mise à niveau (entité ou qualité). `get_id` : `unit_number`, sinon surface, nom et position (`storage.target_by_registration`).
- Modes, un par batch : `build`, `landfill`, `deconstruct`, `upgrade`, `network` (roboports). Phases : démontages, remblais, mises à niveau et constructions, `network`. Un batch collecte tout de suite mais part après les phases antérieures de sa surface ; après `long_delay`, il cède sa voiture à un cluster antérieur en attente.
- Remblai : ghosts voisins d'une terre seulement, construits depuis la rive (`revive` sans portée) ; aucun : alerte, abandon.
- `compute_needs` (objet, inventaires demandés, modules ; pas la grille) et `compute_load` (plus le pire cas de ce qui est rendu) réservent les slots. Falaise : explosif pris au coffre, `destroy`. Démontage : `entity.mine` dans le coffre (plein : réessais) ; marque retirée = fait.
- Mise à niveau : `apply_upgrade` avec un `buffer` temporaire à la taille des inventaires de l'ancienne entité (sans `buffer`, contenu et objet détruits ; trop petit, le surplus détruit), vidé dans le coffre (surplus au sol, évité par `compute_load`). Étiquettes et santé des objets perdues.
- Qualité : clé `nom` (normale) ou `nom|qualité` (`_utils.make_item_key`) ; qualité de l'entité (ghost, mise à niveau, démontage). Effet sur la taille du coffre non lu (`car_inventory_size` en plafond).
- `fill_batch` : clusters en attente les plus proches tant que leurs slots (par cluster, jamais partagés) tiennent ; `construction.clusters`.
- `ghost_control.proceed`, rappelé après chaque étape : `collect`, `go_to_site` ou attente avec alerte (`missing_since`, fenêtre des objets manquants) ; après `long_delay`, les clusters dont les objets manquent retournent en attente si un autre est complet. `requeue_construction` : retour cluster par cluster.
- Chantier : le ghost prêt le plus proche fixe le cluster (`construction.site`) ; recharge possible entre deux clusters ; rien de prêt : cluster suivant ou `step_back`.
- Cible ratée `max_revive_attempts` fois : abandonnée, de retour en file après `very_long_delay` ; alerte sur la carte pour chacune, ligne de chat une fois par lot (`failure_printed`).
- Fin : ghost disparu, `drop_ghost_items` ; `finish` dépose (groupe de coffres, puis le suivant qui a de la place ; sinon alerte `supply_full` et réessai : coffre non vide = ni batch ni garage), puis cluster en attente ou `waiting`.

### Carburant

- Caché (`burner.remaining_burning_fuel`), lu et écrit seulement par `_utils.get_fuel` / `set_fuel` (un brûleur vide perd son item et ignore l'écriture). `charger_data.users` réservé dès le départ.
- `compute_fuel_to_reach` (aller) ; `compute_fuel_needed` = aller + `compute_fuel_reserve` (jusqu'au chargeur le plus proche, plus `critical_fuel_ratio`) ; `max_charge_detours` détours de suite au plus ; réservoir plein et insuffisant : `mark_unreachable`.
- Lu toutes les `slow_check_interval` (environ 120 J par tick en mouvement), à chaque tick si vide ou retenue avant un réessai. Urgence (`handle_critical_fuel`) : rien au-dessus de `critical_check_fuel_ratio` (0,8) ; sans chargeur joignable, `waiting`, nouvelle recherche toutes les `short_delay`, aucun batch.
- Formule (`config.fuel_estimate`) : 50 000 J + 2500 J/tile sur 100 tiles + 450 au-delà, estimation haute : couvre 90 % des trajets courts et tous les longs (364 trajets mesurés ; 11 000 tiles : 5,0 MJ estimés, 1,8 réels).

## Invariants

- `building.active` : seulement à l'arrêt sur le chantier ; en trajet, `car_data.construction` signale le batch.
- `moving.destination` peut être `{position, valid}` (`step_back`) : n'en lire que ces champs.
- `stuck` : état de repli, pas une pause.
- `slow_lookahead.start` (1,6) au-dessus du minimum de `lookahead.start` (`assert`) : `can_place_entity` voit la voiture elle-même, d'où obstacle imaginaire et cercles.
- Mod publié : les joueurs gardent leurs sauvegardes d'une version à l'autre. Un nouveau champ d'état est lu avec une valeur par défaut (`x or défaut`) ou rempli par une migration (`on_configuration_changed`, ou un fichier de `migrations/`) ; une nouvelle table de `storage` va dans `init_storage` ; un nom de prototype renommé demande une migration JSON.
- Le script ne règle que `riding_state`, jamais l'orientation ; marche arrière : `REVERSE_STEERING_INVERTED = true`, via `get_arc_rotation`.
- Ce que prototypes et scripts partagent est défini une fois dans `config.lua` (`config.names`, `car_size`, tailles d'inventaire, `car_color`). Les noms sont dans les sauvegardes et servent de clés de `locale/` : pas de changement sans accord.
- Prototype copié (`table.deepcopy`) : il garde tous les champs (`icons` passe avant `icon`, `hidden`) ; les vérifier.
- `config.lua` finit par des `assert` sur les relations entre constantes : en ajouter une pour toute nouvelle relation.

## Conventions de nommage

- État : `car_data.<état>.active`, `since`. Entités : `car`, `charger`, `garage`, `chest`, `ghost`, données `<entité>_data` ; `destination` entité ou waypoint, `target` sa position.
- Fonctions, verbe d'abord : `get_*` lit, `compute_*` calcule, `measure_*` interroge le monde, `count_*`, `find_*`, `is_*` / `can_*` / `fits_at`, `alert_*` (`alert_once` / `alert_reset`), `start_*` entre dans un état, `create_*` crée une table d'état ; exceptions `on_*`, `<état>_tick` (chaque tick), `new` / `length` de la deque.
- Abandon : « unreachable » (aucune recharge) ou « stuck » (bloqué), `stuck.final`. Manœuvre : « arc » (un des 6 choix), « heading » (direction).
- Prototypes : `autonomous_car` ou `autonomous_car_<chose>`, déclarés dans `config.names`.
- `config.lua` : constantes liées en tables ; `*_delay` avant réessai, `*_duration` action, `*_interval` période ; « fuel » charge de la voiture, « energy » tampon du chargeur. Un nouveau délai reprend `short_delay`, `medium_delay`, `idle_delay`, `long_delay` ou `very_long_delay` et s'ajoute à la liste d'usages de son commentaire (listes tenues à la main, complétées à chaque mise au propre : choix du propriétaire).

## Réglage du mouvement

Un paramètre à la fois, testé en jeu, dans cet ordre : 1. sécurité (`emergency_brake_lookahead`, `arrival_distance`, `braking_duration`) ; 2. manœuvre (`maneuver.*`, `friction.maneuver`) ; 3. densité et mode lent (`fast_density`, `dense_area_threshold`, `built_zone_distance`, `slow_lookahead`) ; 4. vitesse (`friction.*`, `speed.*`) ; 5. `density.radius`, `lookahead.*`, `steering_cost`. Les seuils de décision avant la friction (qui ne traite que le symptôme). La voiture compte dans sa propre densité (environ 0,024). La manœuvre reste une exception.

| Symptôme | Constantes |
|---|---|
| oscille autour de la destination | `arrival_distance`, `emergency_brake_lookahead`, `slow_lookahead`, `dense_area_threshold` |
| manœuvre à tort ou trop tôt | `short_delay` |
| manœuvre qui n'aboutit pas | `idle_delay`, `short_delay`, `maneuver.exit_density`, `maneuver.min_travel`, `maneuver.probe.*`, `friction.maneuver` |
| s'arrête trop souvent | `density.radius`, `lookahead.length`, `dense_area_threshold`, `emergency_brake_lookahead`, `steering_cost` |
| trop rapide ou trop lente | `friction.*`, `fast_density`, `braking_duration` |

À vérifier après un réglage : ligne droite sans oscillation, arrêt propre, zone dense sans faux `stuck`, cluster sans arrêt inutile, recharge puis parking, plusieurs voitures sans blocage.

## Essais sur le déplacement

Problème → solution gardée (effet) ; écartés, à ne pas refaire. « Contacts » : événements `HEALTH`. Détail d'avant le 2026-10-16 : `git show 3889bf9:CLAUDE.md`.
- Portes d'une tile : la voiture s'y engage une fois sur deux → ouverture de 3 tiles au moins (propriétaire). Dans `ccc6568` seulement : pas de mode rapide à moins de 15 tiles d'un mur ; plafond de friction (`friction_modifier` × friction de la tuile au-delà de 1000 inverse le freinage ; aujourd'hui 400 au plus). Écartés : freinage près des portes, `side_offset` 0,5 et 0,55, durées plus longues.
- Cercles près des murs (auto-détection, voir « Invariants ») → `slow_lookahead.start` 1,6, `pass_radius` 8, pas de frein d'urgence en chemin : 658/666 au lieu de 634. Écartés : limites de vitesse en virage ou aux coins (`turn_limit`, `corner_limit`, `gate_speed`), `friction.slow` 2, 3 ou 6, `path_offset`, vitesse minimale du frein.
- Dérive vers une poche (rivage, tourelles) → `path_deviation` 1, `path.corridor` 2,5 : `wall-turrets` 6/6. Couloir de 0,7 à 1,5 ou coût de 3 : pertes. Écartée : friction réduite en poche.
- Fuite dans la plaine (densité lue jusqu'à 33 tiles) → disques limités à la cible, `density_factor` 0,3 : trajets -6 à -17 %, contacts -18 à -48 % ; à 0, une voiture bloquée. Écartés : sauter les waypoints derrière, reculer en ligne droite, rayon d'atteinte élargi.
- Passages d'une tile dans le chemin → `path.margin` 0,4 : contacts -37 % par rapport à 0,3.
- But de chemin trop écarté (25°) → `goal.angle_cost` 0,1, pas de 30°, 3 secteurs : 17°, trajets -4 % (0,3 perd une voiture). Piste : `step` 1/24, `sectors` 6.
- Arrivée parallèle au mur d'une porte → points repoussés jusqu'à `gate_waypoints.clear` 7 : contacts -26 %.
- Fuite au départ d'un chemin (waypoint suivant dans le dos) → demi-tour sur tout waypoint, `u_turn_angle` 0,35 : 4 fuites de `plain-base` corrigées. Écartés : seuil 0,25 (reculs dans les arbres), un seul demi-tour par chemin, pas de limite en zone dense (+25 % de contacts), refus du mode rapide cible dans le dos.

## Publication

Portail mods.factorio.com, compte factorio.com (le jeu doit être possédé). Première version : 0.1.0, pas encore publiée.
- Première fois : « My Mods », « Submit mod », zip, description (le README), images ; catégorie « content », étiquettes logistics, transportation, logistic-network, circuit-network ; licence MIT (choix du propriétaire, comme Pavement Drive Assist Continued ; `LICENSE`, inclus dans le zip). Les images tirées du jeu restent à Wube, qui les autorise dans les mods.
- Chaque version : `version` d'`info.json`, section de `changelog.txt` (format strict du jeu : ligne de 99 tirets, `Version:`, catégories à 2 espaces, entrées à 4 espaces et un tiret, ni tabulation ni espace en fin de ligne, `doc-html/auxiliary/changelog-format.html`), présentations à jour, commit, puis zip envoyé depuis la page du mod (ou l'API d'envoi, clé « ModPortal: Upload Mods » du profil factorio.com).
- Zip, depuis le commit publié (`.gitattributes` exclut `tests/`, `CLAUDE.md`, `README.md` et les fichiers de configuration ; le dossier du zip peut porter n'importe quel nom, le zip doit s'appeler `<name>_<version>`) :

```powershell
git archive --prefix=autonomous-car/ -o "$env:TEMP\autonomous-car_0.1.0.zip" HEAD
```

- `thumbnail.png` (144 × 144) : la voiture du jeu, masque teint à `config.car_color`, avec son ombre, sur une variante 4 × 4 de `dirt-1` (direction 12 sur 64 ; script non gardé).
- Testeurs : onglet Discussion de la page du mod, forum officiel (catégorie « Mods »), Discord officiel, Reddit r/factorio.

## À faire

- Test en multijoueur avant publication : une sauvegarde lancée par `factorio.exe --start-server <sauvegarde>`, le jeu s'y connecte, quelques voitures travaillent une dizaine de minutes (désynchronisations).
- Test d'une longue partie réelle : menu de débogage (F4), `show-time-usage`, temps du mod par tick.

## Problèmes connus

### Ouverts

Aucun.

### Corrigés, à valider

Validation reportée : qualité des objets (ghosts, mises à niveau, collecte, dépôt, objets manquants, garage), écrite d'après la doc, non testable sans l'extension Qualité ; la qualité normale ne régresse pas.

### Limites assumées

À ne pas « corriger » sans l'accord du propriétaire.
- Liaison logique visible : sinon on ne saurait pas où brancher un fil.
- Ouverture de 3 tiles au moins dans un mur : une ouverture d'une tile n'est ni trouvée ni franchie de façon fiable.
- Portes successives (`series-*`) : alignées, dès 6 tiles entre les murs ; décalées, 10 tiles au moins, sinon un S trop serré et `stuck`. Piste non essayée : points d'approche plus larges dans `add_gate_waypoints`.
- Demi-tour contre un mur complexe (`wall-turrets`, 1 voiture sur 6 en jitter) : glissée contre des tourelles, la voiture oscille sans pouvoir tourner et finit en `stuck`. Essayés : marge de chemin plus large, friction réduite en poche.
- `doors-clutter` (bosquet collé à une sortie) et `doors-odd` (porte masquée, voiture dos à la porte) : 1 à 4 échecs par campagne.
- Forêt dense : dégagement (24/24) ; une voiture emmurée reste `stuck`.
- Les portes de la force s'ouvrent à portée d'une voiture en mouvement, quelle que soit sa direction.
- Plus de chargeur joignable : attente de `very_long_delay` avant l'abandon.
- Zone aveugle de la manœuvre (coin d'une grande entité), rattrapée au tick suivant.
- Porte du garage dessinée au-dessus d'une voiture posée contre sa façade.
- Aperçu de sélection : compte aussi ce que couvrent les robots ou qu'une voiture suit déjà (filtrage par entité essayé, écarté).
- Non couverts : voiture bloquée sur des rails en route, trains, `chunk_exploration_radius`.
