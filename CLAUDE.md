# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Mod Factorio 2.0 (Lua 5.2) « Autonomous Car » : une voiture autonome qui travaille hors réseau de robots (construit les ghosts, remblaie, démonte, met à niveau), se recharge et se gare seule. Ce fichier est la seule documentation du projet.

**Version en construction.** Le 2026-10-10 le propriétaire a jugé cette version satisfaisante pour les mécanismes en place (déplacement, manœuvre, chemin de secours, construction, recharge, garage, fenêtre des objets manquants) et l'a fusionnée dans `main` ; les problèmes ouverts et les fonctions à venir restent à traiter. Un mécanisme peut toujours être repris si un test ou le jeu le montre.

## Règles de travail

- Comprendre la cause d'un bug au niveau du tick avant de corriger ; pas de correctif de symptôme.
- Changements petits et chirurgicaux. Réutiliser les helpers et l'API Factorio existants ; pas de second système d'état.
- Le code fonctionne globalement en jeu : une incohérence vue à la lecture n'est pas un bug tant qu'elle n'est pas confirmée en jeu, par un scénario de test ou par le propriétaire.
- Tests : seulement sur demande du propriétaire, en lui demandant avant chaque lancement avec la durée approximative (une catégorie de scénarios : 1 à 10 minutes). Dans l'environnement cloud, ne pas exécuter Factorio : le propriétaire lance les scénarios en local ; la vérification statique reste possible (voir « Commandes »).
- Tests lourds (deux catégories ou plus, `-Reference`, balayage de valeurs `-Set`) : un `run.ps1` par catégorie en parallèle, chacun avec son propre `-Output` (deux lancements ne partagent jamais un dossier, ni celui par défaut), sans scinder une catégorie (les numéros d'entités changeraient et les traces ne correspondraient plus à une référence groupée). Au plus environ 6 processus Factorio à la fois, ceux d'une autre session compris (`Get-Process factorio`) ; ce gain et cette limite ne sont pas mesurés. L'estimation annoncée avant le lancement est celle de la plus longue catégorie ; la règle des 2 fois s'applique à chaque processus. `tests\show.ps1` ne lit que le dossier par défaut : lui donner le chemin de la trace (`tests\show.ps1 "$env:TEMP\autonomous-car-tests-doors\trace-gates.txt" -Car 15`).
- Git : `main` est la version de référence choisie par le propriétaire, pas une version validée. Tout travail se fait sur une branche à part (la créer avant la première modification si on est sur `main`). Ne jamais pousser ni fusionner dans `main` sans demande explicite du propriétaire ; proposer de committer, pousser ou fusionner quand cela semble utile (fin d'un changement cohérent, version prête à valider), puis attendre sa réponse.
- API de Factorio : la documentation locale (`doc-html` du dossier du jeu, version 2.0.77 le 2026-10-10) fait foi pour la version installée ; la documentation en ligne peut décrire une version plus récente (cas de `apply_upgrade` et de son paramètre `buffer`, voir « Construction »). Très rarement (nouvelle version du jeu, ou contournement d'une limite de l'API dans le code), proposer au propriétaire de vérifier si l'API a évolué et si un contournement peut être simplifié ; pas à chaque session.
- « Problèmes connus » (en bas) : y ajouter tout problème découvert ; un problème corrigé passe dans « Corrigés, à valider » et n'est retiré qu'après validation du propriétaire. Seul ce que le joueur voit ou peut faire y entre : un changement interne (renommage, refactoring sans effet visible) n'a pas à être validé.
- Une idée ou une tâche pour plus tard se note à deux endroits : une ligne dans « À faire » et un commentaire `-- TODO` à l'endroit du code. Retirer les deux une fois fait.
- Code, commentaires et messages du script (alertes, `print`) en anglais ; ce fichier en français. Les noms et descriptions des prototypes sont dans `locale/`, en anglais et en français : toute ligne ajoutée ou modifiée l'est dans les deux fichiers.

## Commandes

Pas de build, pas d'interpréteur Lua. Dépôt git privé (branche `main`) ; `.backup/` (état d'avant le dernier grand renommage) est ignoré par git.

- Le mod est chargé depuis ce dossier, dont le nom doit rester `<name>_<version>` de `info.json`.
- Changement runtime : recharger la sauvegarde. Changement de prototype (`data.lua`, `prototypes/`, valeur de `config.lua` lue par un prototype) : redémarrer Factorio.
- Erreurs : `%APPDATA%\Factorio\factorio-current.log`.
- Vérification statique sans Factorio (quelques secondes) : erreurs de syntaxe et noms globaux mal orthographiés, par le serveur de langage Lua de l'extension VS Code `sumneko.lua`, que `.luarc.json` configure (un global de Factorio absent de `diagnostics.globals` s'y ajoute). Avec `--checklevel=Hint` il signale aussi les variables masquées ; aucun problème à ce jour.

```powershell
& (Get-Item "$env:USERPROFILE\.vscode\extensions\sumneko.lua-*\server\bin\lua-language-server.exe")[-1] --check . --checklevel=Warning --logpath="$env:TEMP\lua-check" --metapath="$env:TEMP\lua-check"
```

Sous Linux (environnement cloud, sans Factorio) : `apt-get install lua5.2 lua-check`, puis `luac5.2 -p *.lua prototypes/*.lua` (syntaxe) et `luacheck --std lua52 --no-max-line-length --ignore 143 --globals game script storage defines prototypes helpers util data rendering log crash_trigger car_reflection volume_multiplier -- *.lua prototypes/*.lua` (variables non définies ou inutilisées ; doit répondre 0 warning). Le script n'a pas d'autre moyen de s'exécuter : un essai avec une fausse API Factorio ne remplace pas les scénarios.

### Scénarios de test

Dossier `tests/`, temporaire : à retirer avant publication (le mod n'en charge rien).

```powershell
tests\run.ps1                                  # tous les scénarios, cinq lancements de Factorio
tests\run.ps1 movement                         # une catégorie : movement, robustness, construction, energy, doors
tests\run.ps1 -Changed                         # les catégories que les fichiers modifiés depuis le dernier commit peuvent affecter
tests\run.ps1 maze, garage-exit -Ticks 8000    # des scénarios précis (un lancement par catégorie concernée)
tests\run.ps1 -Reference <dossier ou zip>      # compare les traces avec une autre version du mod
tests\run.ps1 doors -Set "friction.slow=6","friction.maneuver=8" -Output $env:TEMP\essai1   # valeurs de config pour ce lancement (seulement celles que le script lit en jouant) ; -Output pour des essais en parallèle
tests\show.ps1 construction -Car 132           # changements d'état d'une voiture dans une trace
```

- `tests/harness.lua` est la seule liste des scénarios : `run.ps1` y lit leurs noms, leur durée (22 000 ticks, ou le champ `ticks`) et leur catégorie (`category`), `show.ps1` les noms des drapeaux. Il est greffé à la fin de `control.lua` et utilise ses locales (`on_area_selected`, `names`, les modules) : renommer l'une d'elles impose de le mettre à jour.
- Les scénarios d'une catégorie tournent ensemble dans une seule partie, chacun sur sa surface (`new_surface`) et avec sa trace (`trace-<scénario>.txt`) ; une erreur de script arrête toute la catégorie. Un nouveau scénario prend la catégorie de ce qu'il vérifie. Les surfaces sont couvertes d'herbe (`grass-1`, friction 1,6) comme en jeu : sur les tuiles de laboratoire les voitures vont bien plus vite.
- `run.ps1` lance Factorio sans fenêtre ni joueur sur une copie du mod dans `%TEMP%\autonomous-car-tests` (rien n'est écrit dans le dossier Factorio, le jeu peut rester ouvert) et affiche pour chaque scénario l'erreur de script éventuelle, les événements et le dernier résumé. Un événement `NOSTATE` signale le filet de sécurité de `update_car` (voir « Tick ») ; la trace donne aussi `EMERG` (freinages d'urgence), `PATH` (chemins), `HEALTH` (contacts) et `DONE <parcours> <tick>`.
- `-Reference` vérifie qu'un refactoring ne change aucun comportement : Factorio est déterministe, deux versions équivalentes donnent des traces identiques (à scénarios groupés identiques : les numéros d'entités en dépendent). La version de référence tourne avec son propre `tests/harness.lua` quand elle en a un.
- Variantes de départ : `-Set "test_jitter=<n>"` (départ ± 0,3 tile, orientation ± 0,01 tour), `-Set "test_door_shift=1"` (portes décalées d'une tile au plus).

Catégories (70 scénarios) :
- `movement` (13) : déplacements autour d'obstacles (salles, murs, forêts, labyrinthes) ; `forests` regroupe 24 parcours sur une grande carte.
- `doors` (42), ouvertures de 3 tiles (`ONE_TILE_DOORS` dans le harnais ramène celles d'une tile) : `gates` (12 traversées d'un mur de 600 tiles par une ouverture, seul moyen de passer), `gate` (une voiture), `doors-clutter` (7 parcours : bâtiments, poteaux, forêt clairsemée ou bosquet près de la porte), `doors-traffic` (3 parcours où 4 ou 8 voitures passent la même porte, dans un sens ou les deux), `doors-odd` (11 cas rares : porte masquée par un coffre, sas, couloir, porte ennemie, voiture dos à la porte, longue marche le long du mur), `doors-base-1` à `6` (base murée de 80 × 48 tiles, deux pièces et trois portes, garage, chargeur et coffre en divers endroits ; un scénario chacun car une voiture va n'importe où sur sa surface), `plain-base`, et 30 `series-<N>w-sp<S>-<f|b><a|s>` (N murs espacés de S tiles, portes alignées ou décalées, voiture dans un sens ou l'autre ; voir « Limites assumées »).
- `robustness` (4) : voitures bloquées, pannes, batterie vide.
- `construction` (4) : `construction`, `work` (grande carte : démontage, mise à niveau, ghosts, tuiles et roboports, trois voitures), `phases-single` (ordre des phases avec une seule voiture), `network-parked` (roboports quand toutes les voitures sont au garage).
- `energy` (7) : chargeurs et garages ; `critical-no-batch` (une voiture sous son seuil critique ne reçoit pas de batch, une autre fait un détour de recharge entre le coffre et le chantier) ; `range-open`, `range-trees`, `range-built` (consommation sur des trajets de 25 à 800 tiles, voir « Carburant ») ; `range-long` (quatre trajets de 1000 à 2500 tiles, ou 5000, 8000 et 11 000 avec `-Set "test_long=1"`, sur la tuile choisie par `-Set "test_tiles=0..5"` ; lancer avec `-Set "fuel_estimate.near_per_tile=100"` pour mesurer sans détour de recharge).

## Architecture

### Modules

`config` → `_utils` → `charge`, `park` → `travel` → `ghost` → `control`, et `movement`, `gui` et `debug_view` à côté (ils ne dépendent que de `config` et `_utils`). Ce graphe doit rester acyclique : c'est pourquoi `requeue_construction` vit dans `travel.lua` et pourquoi l'arrivée d'une voiture passe par un événement plutôt que par un appel à `control.lua`.

| Fichier | Module | Rôle |
|---|---|---|
| `control.lua` | | événements, suivi des entités, tick |
| `movement.lua` | `movement` | mode de conduite, direction, manœuvre, chemin, dégagement |
| `travel.lua` | `travel` | trajets, détours de recharge, stuck, abandon |
| `ghost.lua` | `ghost_control` | ghosts, clusters, assignation, construction |
| `charge.lua` | `charger_control` | chargeurs, estimation du carburant |
| `park.lua` | `garage_control` | garages, réparation lente des voitures garées |
| `gui.lua` | `gui` | fenêtre des objets manquants (raccourci `missing_items_shortcut`) |
| `debug_view.lua` | `debug_view` | affichage de débogage de la voiture sous le curseur ou ouverte (destination, chemin, état, coûts de braquage), redessiné toutes les `slow_check_interval` ticks (raccourci `debug_view_shortcut`, activé par défaut : `config.debug_view_default`) ; ne fait que lire `car_data` (dont `car_data.steering`, écrit par `drive_tick` pour lui) |
| `_utils.lua` | `_utils` | carburant, entité la plus proche, passage en attente (`start_waiting`), deque, alertes, clés d'objets, libération d'entités, événement de fin d'étape |
| `config.lua` | | noms et tailles communs aux prototypes et aux scripts, puis réglages |
| `colors.lua` | | couleur que le script donne à chaque voiture posée (un prototype de voiture n'a pas de couleur) |
| `data.lua`, `prototypes/` | | prototypes, un fichier par entité |
| `locale/en`, `locale/fr` | | noms et descriptions affichés en jeu |

### État

- `storage.cars[id]` est l'entité, `storage.car_data[id]` son état (`create_car_data` dans `control.lua`) ; même schéma pour chargeurs et garages. Les tables sont créées par `init_storage` au premier tick, qui lance ensuite `on_tick` pour ce même tick (aucun tick n'est sauté après un chargement) ; ni `on_init` ni migration (voir « Invariants »).
- Voitures, chargeurs, garages et coffres sont suivis dès leur construction (`on_built`), y compris quand une voiture les construit (`script_raised_revive`). Toute entité devenue invalide est libérée par `_utils.release_entity(kind, id)`. Les ghosts sont suivis par `on_object_destroyed`, pas par les événements died/mined.

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

### Conduite

- `update_mode` fixe `car_data.mode` (`fast`, `normal` ou `slow`), `emergency_brake` et `friction_modifier` (recalculé chaque tick, jamais incrémenté), peut demander un chemin et démarrer une manœuvre ; `drive_tick` lit `emergency_brake` et `mode` dans le même tick : l'ordre ne doit pas changer.
- Trois modes de vitesse, par la friction (`config.friction`) : `fast` (densité sous `fast_density`, loin de tout bâti), `normal`, `slow` (points d'échantillon plus proches, `slow_lookahead`). `slow` à moins de `built_zone_distance` d'un bâti de sa force (murs, portes, bâtiments ; mesuré toutes les `slow_check_interval` ticks, `car_data.near_built`), au-dessus de `dense_area_threshold`, ou pendant `medium_delay` après un freinage d'urgence sur obstacle, une manœuvre ou la fin d'un chemin (`slow_until`). Près d'un bâti la voiture reste en `normal` (jamais `fast`) quand sa cible (waypoint ou destination) est dans le cône de `path_trigger.half_angle`, à plus de `normal_beside_built_distance`, hors porte, et que la ligne droite est libre (`car_data.line_clear`).
- Sortie de `fast` : `update_mode` mémorise la vitesse d'entrée (`entry_speed`) et lève `slowing` ; `drive_tick` freine alors jusqu'à cette vitesse, sans descendre sous `speed.slow`.
- Freinage d'urgence : un événement, pas un mode (arrivée à moins de `arrival_distance`, ou obstacle à `emergency_brake_lookahead`) ; seulement dans `drive_tick`, jamais en manœuvre, et **interdit en suivi de chemin** (le chemin frôle murs et arbres à moins de cette distance : l'arrêt y calait la voiture ; mesuré, sans dégât).
- Direction (`drive_tick`) : trois caps (tout droit et ± `lookahead.angle`) notés par des points d'échantillon. Le terme de densité (`steering_cost.density`) ne lit que les disques situés avant la cible (`measure_density_ahead`) et pèse `path.density_factor` fois moins en suivi de chemin : sans cela une voiture dont la cible était à côté d'une base partait à l'opposé, dans la plaine vide, jusqu'à 600 tiles. `measure_wall_margin` ajoute `steering_cost.margin` par côté où un obstacle longe un point d'échantillon à environ une largeur de voiture ; en suivi de chemin, un point à plus de `path.corridor` du segment suivi coûte `steering_cost.path_deviation` par largeur de voiture.
- Voisines : toutes les `slow_check_interval` ticks (décalés par l'id de la voiture, `_utils.is_slow_check_due`), `refresh_neighbours` liste les autres voitures en mouvement à proximité. Un point d'échantillon dans la zone devant l'une d'elles (largeur de la voiture, longueur de la voiture plus `speed × braking_duration`) coûte un `steering_cost.blocked` de plus. Les trains pourront rejoindre cette liste.

### Manœuvre

Sous-mode de `moving` (`car_data.maneuver`) : même destination, conduite lente (`friction.maneuver`), avant ou arrière. Recours successifs : la manœuvre, puis le chemin, puis le dégagement, puis `stuck`.
- Départ : seulement sur un arrêt net (`drive_tick` : vitesse nulle, loin de la destination, plus de `short_delay` après le début du trajet ou la fin de la dernière manœuvre). Une cible derrière la voiture ne déclenche rien : `drive_tick` braque jusqu'à ce que la voiture soit alignée. Un trajet trop long (`travel.is_leg_too_long`) passe directement au chemin.
- Cap (`choose_heading`, gardé dans `maneuver.heading` pendant `short_delay`, la durée d'un arc) : `1 / lookahead.angle` secteurs autour de la voiture, notés par l'espace libre (`measure_free_room`) et la densité (`steering_cost.density`, terme essentiel : sans lui `u-narrow` tombe à 13/20), le plus proche de la destination en cas d'égalité.
- Arc (`choose_arc`, toutes les `short_delay`) : l'un des six (avant ou arrière × gauche, tout droit ou droite) qui rapproche l'orientation du cap, par priorité : la voiture y tient, il tourne vers le cap (tout droit une fois alignée), avant, espace libre. Bloquée devant et derrière (aucun arc tout droit n'a de place), elle doit tourner : un arc qui braque compte alors comme libre dès qu'il a de la place.
- Sondes : un mur en pierre n'a que 0,58 tile d'épaisseur, les sondes sont donc espacées de 0,5 tile ; la zone entre la voiture et la première sonde (`maneuver.probe.start`) est sondée à part par `find_entities_filtered` (la voiture se détecterait elle-même avec `can_place_entity`).
- Recul (`back_off`) : une voiture qui roule mais reste sous `speed.stopped` pendant `short_delay` a un obstacle invisible, ou un mur qui l'empêche de tourner (elle pivote autour de son centre). Elle part dans l'autre sens, tout droit, et **longe le mur** (`maneuver.follow` : ses arcs restent dans cette direction) par tranches d'une longueur de voiture (ou `short_delay`), en tentant un virage entre chaque, jusqu'à ce qu'un virage de `lookahead.angle` réussisse. Un virage qui cale fait continuer dans le même sens (deux fois au même endroit : sens inversé, `turn_stall`) ; un calage en ligne droite marque le sens comme bloqué (`maneuver.blocked`, avec la position et l'orientation du calage) et renvoie la voiture dans l'autre. Ce repère est périmé dès que la voiture s'est éloignée d'une longueur de voiture ou a tourné de `lookahead.angle` (`is_blocked`). Deux sens bloqués depuis le même endroit, ou pas de mouvement à la fin d'un recul : la manœuvre échoue aussitôt. Une manœuvre lancée sur un arrêt net commence par ce recul (`start_maneuver`, `backing_off`), sans rien noter comme bloqué : une voiture trouvée à l'arrêt n'a pas forcément calé tout droit (son propre frein d'urgence l'arrête aussi).
- Fin : densité sous `maneuver.exit_density`, devant libre et déplacement d'au moins `maneuver.min_travel` ; un seul essai, d'au plus `idle_delay`. Échec (`fail_maneuver`) : demande de chemin, sinon dégagement, sinon `stuck`.
- Mécanismes retirés (campagne du 2026-10-09, `u-side` et `u-narrow` : 20 voitures chacun, départs et orientations variés, 20/20 après retrait) : déclencheur `rear_turn` (faisait échouer des voitures qui s'en sortaient seules), hystérésis du cap, interdiction de l'arc complémentaire, `can_turn`, détection `wedged` (voiture « sans issue » sans réessai), déclencheur `no_progress` (et `stuck_min_progress`). À l'inverse, le terme de densité du cap, le recul sur arrêt net, `follow`, la règle « tourner quand on est bloqué devant et derrière » et le chemin de secours font perdre des voitures quand on les retire : à ne pas supprimer sans nouvelle campagne.

### Chemin

Section « Path » de `movement.lua`, état `car_data.path` (remis à zéro à chaque trajet par `begin_leg` : `travel.create_path_state`).
- Demande : `surface.request_path` (boîte de la voiture agrandie de `path.margin`, 0,4 : le chemin ne passe plus par une ouverture d'une tile ; `low_priority`, sans cache, `can_open_gates`), envoyée par `start_path_request`, au plus une toutes les `medium_delay`. Demande d'échec (`movement.request_path`, le chemin de secours) quand la manœuvre échoue ou que le trajet dure trop, au plus `path.max_requests` par trajet (`path.count`). Demande guidée (`movement.request_guided_path`, `config.path_trigger`) en conduite normale, en zone bâtie ou dense, quand la destination est hors du cône de `half_angle` devant la voiture ou que la ligne droite est bloquée (`is_line_blocked`), au plus `path_trigger.max_requests` par trajet (`path.guided_count`).
- But (`choose_path_goal`) : la destination, ou au-delà de `path_trigger.range` le point le moins dense parmi `2 × sectors + 1` directions autour de celle de la destination, plus `angle_cost` par pas d'écart.
- Attente : freinée dans une manœuvre (`wait_for_path`), détection de blocage suspendue ; la réponse arrive par `on_script_path_request_finished` (`movement.on_path_finished`, `storage.path_requests` relie la requête à la voiture ; `try_again_later` renvoie la requête après `short_delay`). Sans chemin (`none`) ou sans réponse après `long_delay`, la voiture reprend la conduite ; ses demandes d'échec épuisées, elle se dégage si elle peut, sinon elle est `stuck`. Le chemin trouvé redéfinit la durée admise du trajet (`departure_distance`).
- Suivi : le chemin est réduit aux angles et à un point tous les `lookahead.length` tiles ; `get_target` renvoie le waypoint courant à `update_mode`, `drive_tick` et à la manœuvre pour la direction, tandis que l'arrivée et le freinage restent ceux de la destination. Un waypoint est passé à moins de deux longueurs de voiture, ou une fois son plan (perpendiculaire à l'arrivée) dépassé à moins de `path.pass_radius` : sans cette règle une voiture qui ne peut pas tourner à temps passe à côté et tourne en rond. Le chemin est effacé à l'arrivée (`on_next_task`).
- Portes : là où le chemin franchit une porte, `add_gate_waypoints` le refaçonne (`gate_waypoints` : points qui longent le mur repoussés jusqu'à `clear`, point devant la porte sur son axe, point de sortie) ; l'axe d'une porte se déduit des murs et portes voisins (`measure_gate_axis`), pas de son orientation (une porte posée par le joueur n'a pas celle des scénarios).
- **Demi-tour** (début de `drive_tick`) : quand le waypoint courant (points d'approche de porte compris ; le chemin part de la voiture, le premier est souvent franchi aussitôt) est à moins de `path.pass_radius` mais à plus de `path.u_turn_angle` du cap, la voiture recule lentement (`friction.maneuver`) en braquant l'avant vers lui, jusqu'à l'avoir à moins de `lookahead.angle` devant, ou atteint ; elle repart si elle cale (`short_delay`) ou après `idle_delay`. Un demi-tour par waypoint (`path.u_turn`, `path.u_turn_done` = index du dernier), et un deuxième sur le même chemin seulement sous `dense_area_threshold` (en forêt la voiture reculait dans les arbres). Sans lui une voiture partait tout droit et tournait en rond.

### Dégagement

Section « Clearing » de `movement.lua`, `config.clearing`. Dernier recours avant `stuck`, quand les demandes d'échec sont épuisées (après une manœuvre échouée ou un trajet trop long), si un arbre ou un rocher est assez proche (à moins de `clearing.lookahead`). Ensuite, un arrêt net sur le même trajet relance un dégagement tout de suite (`start_maneuver`), au plus `clearing.max_count` fois par trajet (`path.clear_count`).
- Sous-mode de la manœuvre (`maneuver.clearing`), d'au plus `idle_delay` ou `clearing.travel` tiles : la voiture détruit les arbres et les rochers (`type` `tree`, ou `simple-entity` qui compte comme rocher) à moins de `clear_radius` d'elle et jusqu'à `reach` devant elle, sans rien ramasser, et roule vers un cap choisi toutes les `short_delay` (`choose_clearing_heading` : secteurs de `lookahead.angle`, coût = arbres et rochers sur `clearing.lookahead` tiles × `obstacle_cost` + écart avec la destination en tours ; un secteur où se trouve autre chose qu'un arbre ou un rocher est écarté).
- Jamais un bâtiment, un mur ni une falaise : une voiture emmurée reste `stuck`. Les arbres ne bloquent pas la voiture par leur masque de collision : les trouver par `type`, pas par `collision_mask` (à pleine vitesse la voiture écrase les arbres, pas à basse vitesse : d'où les blocages en forêt).
- Mesuré (2026-10-12) : `forests` 17/24 → 24/24, et 96/96 avec `test_jitter` 1, 2 et 3 ; `movement` sans autre changement. Mesuré sur des arbres seulement : aucun scénario ne bloque une voiture parmi des rochers.

### Stuck, batterie vide

- `stuck` : arrêt, alerte, attente `long_delay`, puis nouvel essai du même trajet (`stuck.destination` ; sa tâche est restée en tête de file). Après `stuck.max_retries` essais, ou sans carburant pour le trajet, dernière attente (`stuck.final`) de `stuck.abandon_delay`, puis abandon : les ghosts du batch sont libérés (le joueur doit les resélectionner) et la voiture rentre par les tâches existantes (dépôt, charge, garage). Un trajet vers un chargeur est réessayé sans limite. `stuck_retry_count` est remis à zéro à l'arrivée, pas dans `begin_leg`.
- `empty` : batterie à 0, la voiture ne fait que surveiller `critical_fuel_ratio` (alerte `battery_empty`), puis reprend son batch par `waiting`. Rien dans le mod ne recharge une voiture vide : le joueur la ramasse et la repose, ce qui crée une nouvelle voiture.

### Trajets et tâches

- `travel.begin_leg(car, destination, next_task)` démarre un trajet et pousse `next_task` en tête de `car_data.tasks` ; `travel.set_destination`, la variante par défaut, vérifie d'abord le carburant et passe par un chargeur si besoin. `begin_leg` désactive `waiting` (un appel qui démarre un trajet n'a pas à le faire) ; un échec de `set_destination` remet la voiture en `waiting`.
- Arrivée : à l'arrêt à moins de `config.arrival_distance`. `movement.drive_tick` lève l'événement `autonomous_car_next_task` ; `on_next_task` termine le trajet (`moving` désactivé), dépile la tâche et lui passe la destination atteinte : `charging`, `parking`, `building`, `collect` ou `deposit`. La fin de charge lève le même événement. Il est synchrone : `on_next_task` s'exécute à l'intérieur de `drive_tick`.
- Abandon d'un trajet : `travel.cancel_trip(car_data)` (trajet, manœuvre, attente `stuck`, charge, stationnement, tâches en file et place de chargeur : `release_charger_slot` couvre le trajet vers le chargeur comme la charge) ; `travel.reset_to_waiting` y ajoute l'arrêt de la voiture et le retour en `waiting` (`_utils.start_waiting`).
- Un nouveau type d'étape est une tâche de plus dans `on_next_task`, pas un nouvel état.

### Construction

- Flux : sélection du joueur → `on_area_selected` → `register_ghost` (ignore ce qu'un réseau logistique couvre et ce qui est déjà suivi : avec une voiture ou en attente) → `build_clusters` → `storage.pending_clusters` → `retry_pending_clusters` → `find_available_car` (voiture en `waiting` au coffre vide et au carburant non critique, sinon sortie d'un garage) → `assign_cluster`, qui crée `car_data.construction` et appelle `fill_batch`.
- Cibles : un « ghost » du module est toute cible d'une voiture : ghost d'entité ou de tuile, entité marquée pour la déconstruction (arbres, rochers, bâtiments minables, pas les falaises), entité marquée pour la mise à niveau (autre entité ou autre qualité). `ghost_control.get_id` la désigne : `unit_number`, ou pour les arbres et rochers, qui n'en ont pas, surface, nom et position (`storage.target_by_registration` relie leur destruction à cette clé).
- Modes (`get_target_mode`, `construction.mode`) : `build`, `landfill` (ghost de tuile sur l'eau), `deconstruct`, `upgrade`, `network` (ghosts qui étendent le réseau logistique : roboports) ; un batch n'en fait qu'un (`fill_batch` n'ajoute que des clusters de son mode).
- Phases (`PHASE`) : démontages, puis remblais (un bâtiment à démonter sur le remblai part avant), puis mises à niveau et constructions, enfin `network`. Un batch va chercher ses objets tout de suite (et signale ceux qui manquent) mais ne part vers son chantier qu'une fois plus aucune cible d'une phase antérieure suivie sur sa surface, en batch ou en attente (`is_waiting_for_phase` ; une marque annulée ne compte pas). Il attend alors comme pour des objets manquants (`construction.blocked_since`) ; après `long_delay`, si un cluster d'une phase antérieure attend faute de voiture, le batch retourne dans la liste et la voiture, une fois ses objets déposés, prend ce cluster (`wait_for_phase`). Les clusters en attente sont attribués par phase (`retry_pending_clusters`, `try_assign_pending`).
- Remblai : `go_to_site` ne choisit que les ghosts de tuile voisins d'une terre (`is_next_to_land`, 8 tuiles autour) ; la voiture s'arrête sur la rive et construit tout le cluster de là (`revive` n'a pas de portée). Si aucun ghost du batch n'est voisin d'une terre (`is_stranded`) : alerte et abandon du batch (`abandon` avec son message).
- Besoins et charge : chaque ghost a des besoins (`compute_needs` : l'objet à collecter, pour construire ou pour l'entité de remplacement) et une charge (`compute_load` : les besoins plus le pire cas de ce que le démontage ou le remplacement rend, produits au maximum et contenu des inventaires), qui réserve les slots. Un cluster à démonter n'a rien à collecter (`items_needed` vide) ; `release_unsupplied_clusters` ne compte que les besoins. Démonter = `entity.mine` dans le coffre de la voiture ; un échec (coffre plein) suit le cycle des essais de `revive` ; une marque retirée par le joueur compte comme fait.
- Mise à niveau (`upgrade_entity`) : `LuaEntity.apply_upgrade` remplace l'entité, garde ses réglages et transfère ce que la nouvelle peut contenir, mais détruit le reste ainsi que l'objet de l'ancienne entité (mesuré le 2026-10-10 : 400 plaques de fer et 2 modules disparus, rien au sol ; le paramètre `buffer` de la documentation en ligne, passé avec le coffre d'une voiture, ne change rien en 2.0.77 ; à reprendre si une version l'accepte). La voiture compte donc le contenu avant et après (`count_contents`), consomme l'objet de remplacement et met dans son coffre l'objet de l'ancienne entité et ce qui n'a pas suivi (coffre plus petit, moins de slots de modules), déposés ensuite comme les restes. Les données d'objet autres que la qualité (étiquettes, santé) ne sont pas conservées.
- Qualité : un objet est identifié par son nom et sa qualité ; la clé des tables `[clé] = nombre` (besoins, charge, `items_needed`) est le nom seul en qualité normale et `nom|qualité` sinon (`_utils.make_item_key`, `split_item_key`, `make_stack`, `get_item_count`, `get_contents`). L'objet d'un ghost ou d'une mise à niveau a la qualité de l'entité, ce que rend un démontage ou une mise à niveau celle de l'entité démontée, le garage rend une voiture de la qualité de l'objet rangé. Limites : l'effet de la qualité sur la taille du coffre d'une voiture n'est pas lu (`config.car_inventory_size` sert de plafond, prudent), les demandes d'objets d'un ghost (modules) ne sont pas traitées.
- Batch : plusieurs clusters si le coffre le permet (`fill_batch` ajoute les clusters en attente les plus proches tant que la somme de leurs slots tient dans `config.car_inventory_size`) ; les slots se comptent cluster par cluster (`count_items_slots`), jamais partagés. `construction.ghosts` et `items_needed` fusionnent les clusters ; `construction.clusters` garde, par cluster, ses ghosts (avec leur charge et leurs besoins) et ses objets.
- Décision : `ghost_control.proceed`, point de décision unique rappelé après chaque étape : coffre d'approvisionnement (`collect`), trajet vers le chantier (`go_to_site`), ou attente avec alerte si aucun coffre n'aide (`construction.missing_since`, que `gui.lua` lit). Après `long_delay` d'attente, les clusters dont les objets manquent retournent dans `storage.pending_clusters` si un autre cluster du batch est complet (`release_unsupplied_clusters`). Un cluster quitte un batch par `travel.requeue_cluster` ; un batch retiré à sa voiture (`travel.requeue_construction` : voiture perdue, but inatteignable) retourne dans la liste cluster par cluster, jamais fusionné.
- Chantier : `go_to_site` choisit le ghost prêt le plus proche, quel que soit son cluster, et fait de ce cluster le chantier (`construction.site`) ; il passe par `travel.set_destination`, qui fait recharger la voiture entre deux clusters. Sur place, `building_tick` construit un ghost à la fois, seulement parmi ceux du chantier (sans cette limite la voiture construirait tout le batch depuis son premier arrêt) ; quand plus aucun n'est prêt (`attempt_one_ghost` renvoie `none`), `go_to_site` mène la voiture au cluster suivant, ou la recule (`step_back`) si seuls restent des ghosts en attente de réessai.
- Fin : un ghost du batch qui disparaît sans que la voiture l'ait construit retire ses objets de `items_needed` et de son cluster (`drop_ghost_items`) ; `finish` dépose les restes (`deposit`) puis prend un cluster en attente ou repasse en `waiting`. Le dépôt remplit tout le groupe de coffres, puis le coffre suivant qui a de la place ; sans place, alerte `supply_full`, la voiture garde ses objets et `end_wait` réessaie (une voiture au coffre non vide ne prend ni batch ni garage).

### Carburant

- La voiture brûle un carburant caché, sans slot : la charge est `burner.remaining_burning_fuel`. Un brûleur vide perd son item de carburant et ignore alors toute écriture de la charge : lire et écrire la charge uniquement par `_utils` (`get_fuel`, `get_fuel_ratio`, `set_fuel`), qui remet l'item en place. `charger_data.users` est réservé au départ vers le chargeur.
- Estimation : `charger_control.compute_fuel_to_reach` (aller seul, `find_charger`) et `compute_fuel_needed` = aller + `compute_fuel_reserve` (trajet de la destination au chargeur le plus proche, places libres ignorées, plus `critical_fuel_ratio`). `set_destination` détourne par un chargeur si la charge ne suffit pas (au plus `max_charge_detours` de suite) ; réservoir plein et toujours insuffisant : `mark_unreachable`.
- Recharge d'urgence : `handle_critical_fuel` compare la charge à `compute_fuel_reserve` depuis la position de la voiture. Rien n'est mesuré au-dessus de `critical_check_fuel_ratio` (0,8 : la voiture est forcément près d'un chargeur) ; en dessous, toutes les `slow_check_interval` ticks, ou toutes les `short_delay` tant que la charge dépasse le double du dernier seuil mesuré. Sans chargeur joignable, la voiture s'arrête en `waiting` et cherche de nouveau toutes les `short_delay` ; tant que sa charge est sous le seuil (`travel.is_fuel_critical`), `find_available_car` et `try_assign_pending` ne lui donnent aucun batch.
- Formule d'un trajet de distance `d` en ligne droite (`compute_fuel_for_distance`, `config.fuel_estimate`) : `fixed + near_per_tile × min(d, near_distance) + far_per_tile × le reste` (50 000 J, 2500 J/tile sur les 100 premières tiles, 450 J/tile au-delà) ; une estimation haute, pas le modèle du jeu.
- Mesure (2026-10-12, scénarios `range-*`, 364 trajets de 5 à 11 000 tiles) : la voiture brûle 115 à 129 J par tick en mouvement quel que soit le mode, presque rien à l'arrêt (J/tile = 120 / vitesse). Trajets courts chers (départs, manœuvres, détours, mode lent : médiane 1300 à 1500 J/tile sous 100 tiles, jusqu'à 6800 au 90e centile) ; longs sur terrain dégagé : 250 à 315 J/tile jusqu'à 2500 tiles, 165 à 185 J/tile de 5000 à 11 000 tiles (rapide ≈ 0,47 tile par tick). Les tuiles à friction très différente (sable 1,8, terre 1,4, chemin de pierre 1,1, béton 0,8, mélange changeant tous les 100 tiles) changent peu (± 15 % : la friction des modes compense). La formule couvre environ 90 % des trajets courts des scénarios (pièges compris) et tous les trajets longs mesurés (11 000 tiles : 5,0 MJ estimés pour 1,8 MJ réels). Limites : en ligne droite sans obstacle au-delà de 250 tiles ; sur l'herbe pour les courts.
- Garage : `repair_parked_cars` rend `garage_repair_rate` de santé aux voitures garées toutes les `long_delay`.

## Invariants

- `building.active` n'est vrai qu'une fois la voiture arrêtée sur son chantier ; pendant un trajet c'est `car_data.construction` qui indique un batch en cours. `building` et `construction` ne se confondent pas.
- `moving.destination` peut être une table `{position, valid}` (waypoint de `step_back`) au lieu d'une entité : n'en lire que ces deux champs.
- `stuck` est un état de repli, pas une courte pause.
- `slow_lookahead.start` (1,6) doit rester au-dessus du minimum de `lookahead.start` (vérifié par un `assert`) : `can_place_entity` ne sait pas ignorer la voiture, et le test d'un cap (copie de la boîte tournée vers ce cap) recouvre la vraie voiture si le point est trop près ; la voiture lit alors un obstacle imaginaire, braque et tourne en rond (cause des grands détours et des pertes `u-side` : 386 voitures sur 443 avec 1,2, environ 630 sur 666 avec 1,6). Une correction à la source (un test qui exclut la voiture) a été jugée non rentable.
- Pas de migration : le mod n'est pas publié, un nouveau champ de `car_data` impose une nouvelle sauvegarde (une ancienne peut arrêter le jeu sur une erreur de script : vu avec un batch d'avant le nettoyage de `construction.clusters[].ghosts`, dans `drop_ghost_items`).
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
- Constantes de `config.lua` qui vont ensemble : regroupées dans une table (`speed`, `friction`, `lookahead`, `path`, `maneuver.probe`) plutôt qu'en plusieurs constantes séparées.
- `config.lua` : `*_delay` attente avant de réessayer, `*_duration` durée d'une action, `*_interval` période. « fuel » est la charge de la voiture, « energy » le tampon du chargeur.
- Tout nouveau délai réutilise `short_delay`, `medium_delay`, `idle_delay`, `long_delay` ou `very_long_delay` et s'ajoute à la liste d'usages de son commentaire.

## Réglage du mouvement

Régler un bloc à la fois, un paramètre à la fois, dans cet ordre, en testant en jeu entre chaque :

1. sécurité : `emergency_brake_lookahead`, `arrival_distance`, `braking_duration`
2. manœuvre : `maneuver.*`, `friction.maneuver`
3. densité et mode lent : `fast_density`, `dense_area_threshold`, `built_zone_distance`, `slow_lookahead`
4. vitesse : `friction.*`, `speed.*`
5. `density.radius`, `lookahead.*` et `steering_cost` si le problème persiste

| Symptôme | Constantes à regarder |
|---|---|
| oscille autour de la destination | `arrival_distance`, `emergency_brake_lookahead`, `slow_lookahead`, `dense_area_threshold` |
| manœuvre à tort, ou trop tôt | `short_delay` (recul sur arrêt net) |
| manœuvre qui n'aboutit pas | `idle_delay` (durée maximale de l'essai), `short_delay` (recul, nouveau cap), `maneuver.exit_density`, `maneuver.min_travel`, `maneuver.probe.*`, `friction.maneuver` |
| s'arrête trop souvent en trajet | `density.radius`, `lookahead.length`, `dense_area_threshold`, `emergency_brake_lookahead`, `steering_cost` |
| trop rapide ou trop lente | `friction.*`, `fast_density`, `braking_duration` |

La friction agit sur le symptôme, pas sur la cause : régler d'abord les seuils de décision. Un seuil de densité se choisit en sachant que la voiture se compte elle-même (environ 0,035 dans un disque centré sur elle, 0,024 dans la densité mélangée de `update_mode`). La manœuvre doit rester une exception.

À vérifier en jeu après un réglage : ligne droite sans oscillation, arrêt propre près d'un obstacle, zone dense sans faux `stuck`, cluster construit sans arrêt inutile, recharge puis parking, plusieurs voitures sans blocage mutuel.

## Essais sur le déplacement

Mesures à ne pas refaire : elles justifient les mécanismes gardés ou retirés. Sauf mention : un essai par réglage, départ exact ; `doors` compte les coffres construits (112), `movement` les voitures arrivées (123) ; « contacts » = événements `HEALTH` (aucun point de vie perdu) ; les noms de constantes sont les noms actuels.

### Campagne des portes (2026-10-10 et 2026-10-11, branche `deconstruct-and-replace`)

Scores sur 60 parcours (`gates`, `gate`, `doors-clutter`, `doors-odd`, `doors-traffic`, 9 000 ticks, bruit ± 3). Les essais gardés de cette campagne sont dans le commit `ccc6568` (`git show ccc6568:movement.lua`, `:config.lua`), pas dans `main`.
- Ouvertures d'une tile (1,42 tile entre deux murs, voiture large de 0,7) : la voiture passe une fois sur deux, jamais dans une base (`doors-base-*`, aussi à 18 000 ticks). Elle longe le mur sans s'engager, car elle ne tourne de 90° vers l'ouverture qu'alignée à quelques dixièmes de tile, ce que ses trois caps ne donnent que par hasard. Décision du propriétaire : ouverture minimale de 3 tiles. Avec 3 tiles : `gates` 11/12, `doors-clutter` 6/7, `doors-odd` 10/11, `doors-traffic` 3/3, six bases sur six, `gate` réussi.
- Règle de vitesse près d'un mur (`ccc6568` : pas de mode rapide à moins de 15 tiles d'un mur ou d'une porte, `measure_wall_nearby`) : aucun effet hors du bruit (45 sans, 43 avec ; distances de 0 à 25 tiles équivalentes), un peu mieux avec des ouvertures de 3 tiles encombrées (28 contre 26 sur 30). Intérêt réel : la voiture est plus lente dans une base, les portes ont le temps de s'ouvrir.
- Plafond de friction (`ccc6568`) : `friction_modifier` × friction de la tuile doit rester sous 1000 (le jeu multiplie la vitesse par 1 − friction × 0,002 à chaque tick : au-delà le signe s'inverse et la vitesse croît de 2,2 fois par tick, jusqu'à 53 tiles par tick, vu dans `doors-base-4`). Les réglages actuels plafonnent à 400 (`friction.slow` × `friction.emergency`) : aucun risque sans réglage extrême. Correctif essayé : `friction_limit = 500` et `math.min(modifier, limit / tile_friction)` dans `set_friction` ; à reprendre si une friction augmente.
- Essayés sans gain, retirés : freinage près des portes (`gate_slow` : distance 6 à 25 tiles, friction × 2 à 16, vitesse 0,1 à 0,2 ; 30 à 34 contre 35 à 45 sans, à 18 000 ticks quatre bases sur six échouent) ; `lookahead.side_offset` 0,55 et 0,5 ; waypoints de porte dans le chemin de secours (aucun gain à l'époque ; repris autrement depuis, `add_gate_waypoints`) ; durées de 18 000 ticks (seulement plus de réussites à une tile sur `gates`).
- Le pathfinder du jeu est asynchrone, avec un budget fixe par tick (10 requêtes de tout type, 100 courtes) et un cache de chemins : une requête est coûteuse mais rationnée.

### Campagne des trois modes (2026-10-11 et 2026-10-12, branche `feature/movement-built-environments`)

Scénarios `plain-base`, `gates`, `doors-clutter`, `doors-odd`, `doors-base-3` et `5`, `u-side`, `u-narrow`, `forests`, `maze`, `long-wall`, 4 à 6 variantes de départ et de porte : 666 voitures (444 pour 4 variantes) ; résultat = voitures arrivées.
- Cause des cercles et des détours : la voiture se détectait elle-même (`slow_lookahead.start`, voir « Invariants ») : 1,2 : 386/443 ; 1,4 bon ; 1,6 meilleur ; 2,0 équivalent à 1,6.
- Freinages d'urgence sur obstacle : presque tous en suivi de chemin ou en zone encombrée, 53 sur 86 sous 0,05 de vitesse (voiture déjà calée). Interdits en suivi de chemin : aucun crash (santé perdue ≤ 0,1 par voiture), plus de réussites.
- Totaux : `main` 634 ; 1,6 seul 628 ; **1,6 + `path.pass_radius` 8 + pas de freinage d'urgence en suivi de chemin : 658** (gardé). Temps de trajet moyens (ticks), `main` → gardé : `gates` 1368 → 810, `doors-clutter` 2519 → 1618, `doors-odd` 2187 → 1597, `doors-base-3` 2368 → 1010, `doors-base-5` 3775 → 2643, `maze` 2103 → 955, `u-side` 537 → 365, `u-narrow` 458 → 396, `forests` 2739 → 2665 ; plus lents : `plain-base` 1310 → 1543, `long-wall` 312 → 433 (problème 6).
- Essayés et retirés (neutres ou nuisibles) : limite de vitesse selon le rayon de virage (`turn_limit` : 366 à 374 sur 444, 642 sur 666 adoucie) ; limite avant les coins du chemin (`corner_limit`, `gate_speed` : trajets plus longs) ; `friction.slow` 2, 3, 6 (4 gardé) ; décalage des coins du chemin (`path_offset`) ; vitesse minimale du frein d'urgence (0,05 ; 0,1).
- Les variantes de départ et de porte ne changent pas les résultats de façon significative (`main` varie davantage dans `doors-odd`).

### Voitures qui dérivent du chemin et finissent dans une poche (2026-10-12)

`work` (voiture 21) et `wall-turrets` (4389, 4553) : la voiture ne se coince pas en suivant son chemin mais en dérivant à côté. Le chemin longe l'obstacle à 0,5 tile (rivage, tourelle) ; là les points d'échantillon côté obstacle ne tiennent pas et leur coût (`blocked`, `margin`) écarte la voiture vers une cavité sans issue (pointe de terre remblayée, trou d'une tile entre deux tourelles), où elle ne tourne plus (sous 0,07 de vitesse sur 0,55 tile de course). `turn_stall` (dans `back_off`) y aide un peu.
- **Gardé** : `steering_cost.path_deviation` 1 avec `path.corridor` 2,5. Couloir 0,7 : `work` 4/4 mais `doors` perd (`doors-traffic` 14/20, `doors-odd` 9/13, `doors-clutter` 11/13 : le chemin des portes passe près des murs) ; 1,5 : `doors-traffic` 17/20 ; 2,5 : seulement `doors-clutter` et `doors-odd` à 12/13. Coût 3 : pertes (`maze` 4/6, `huge-wall` 3/6). Campagne complète contre la version sans : `wall-turrets` 6/6 (5/6), `series-3w-sp6-bs`, `series-5w-sp6-bs` et `series-5w-sp6-fs` réussissent (échouaient), `doors-clutter` et `doors-odd` perdent une voiture chacun. Jitter 2 : `u-side` 19/20 (20/20 sans).
- Retirés : `path.margin` 0,5 à 0,8 à l'époque (`wall-turrets` perd une voiture en jitter 2 ; repris à 0,4 le 2026-10-13) ; friction réduite pendant les virages de poche (aucun effet).

### Densité du braquage (2026-10-13)

`plain-base` (voitures 34417 et 4716) : la voiture passe un waypoint et file tout droit jusqu'à 600 tiles alors que le suivant est 4 tiles derrière elle : la densité (disques jusqu'à 33 tiles devant, poids 1,5) rend la plaine vide moins chère que le cap vers la base, et le terme de distance à la cible (environ 2,2 / D) ne compense pas. **Gardé** : disques limités à la cible, `path.density_factor` 0,3, et le demi-tour (voir « Chemin »).
- Ancien code → gardé : `doors` 101 coffres des deux côtés, 1923 → 1788 ticks par parcours, 221 → 172 contacts ; `movement` 123/123, 1573 → 1482 ticks, 689 → 565 contacts ; jitter 2 : `doors` 103 → 102 coffres, 2276 → 1884 ticks, 320 → 167 contacts, `movement` 122/123, 1513 → 1332 ticks. À surveiller : `u-narrow` en jitter 2 (241 contacts contre 116), `doors-clutter` (une voiture de moins).
- Sans effet : facteur 0,15 ou 0,5, poids de densité 1. Facteur 0 : une voiture bloquée contre un mur (`series-5w-sp6-fs`). La limite à la cible seule ne suffit pas. Retirés : sauter les waypoints derrière la voiture (neutre), reculer en ligne droite vers le waypoint (quatre voitures perdues dans `plain-base`), rayon d'atteinte du premier waypoint élargi (`plain-base` 1 voiture sur 6).

### Marge du chemin `path.margin` (2026-10-13)

But : refuser les passages d'une tile (entre deux bâtiments ou obstacles), que le chemin donnait mais que la voiture ne franchit pas. Coffres `doors` à 0,1 / 0,3 / 0,4 / 0,5 (bruit ± 3) : jitter 1 97 / 102 / 99 / 99, jitter 2 102 / 104 / 104 / 103, jitter 3 101 / 103 / 103 / 103, départ exact 101 / 103 / 102 ; `movement` 123/123 de 0,3 à 0,6. Contacts `doors` sur les quatre départs : 0,3 : 924, 0,4 : 578. Moins de chemins trouvés avec la marge (jitter 2 : 273, 259, 254, 217 de 0,1 à 0,4), mais les chemins refusés étaient impraticables. **0,4 gardé** : autant d'arrivées que 0,3 et 0,5, moins de contacts que 0,3, plus de chemins que 0,5.
- Base de référence avec 0,4 (campagne complète, 2026-10-13, sans erreur de script ni `NOSTATE`) : `doors` 102 coffres sur 112, 8 ghosts restants, 1856 ticks par parcours, 187 contacts ; `movement` 123/123, 1452 ticks, 563 contacts ; `construction`, `robustness` (4/4) et `energy` (7/7) sans erreur.

### But intermédiaire du chemin (2026-10-13)

`choose_path_goal` (voir « Chemin »). Coût 0,02 (ancien) : 123/123, 563 contacts, écart moyen but/destination 25° (14 chemins sur 70 à 60° ou plus) ; **0,1, pas de 30°, 3 secteurs (gardé pour l'essai en jeu)** : 123/123, 583 contacts, 17° (10 chemins à 60° ou plus), durée −4 % ; 0,3 perd une voiture ; 0,1 avec un pas de 15° sur ± 90° : 638 contacts, 10° (aucun à 60°), `doors` −3 % de durée ; 1 ou 2 secteurs : équivalents. `doors` identique partout (102/112 : destinations presque dans l'axe). Alternative si des détours restent en jeu : `step` 1/24, `sectors` 6.

### Approche d'une porte le long d'un mur (2026-10-13, branche `feature/gate-approach`)

Vu en jeu : une voiture qui longe un mur arrive presque parallèle à lui au point `near` et doit tourner d'environ 80°. Cause : `add_gate_waypoints` supprimait tous les points du chemin à moins de `near` + 0,5 tile du plan du mur, donc ceux qui le longent. **Gardé** : seuls les points juste devant la porte sont supprimés, les autres sont repoussés jusqu'à `clear` du mur (rampe de `ramp` tiles) où `fits_at` le permet ; `clear` 7. `doors` sur 4 départs (448 coffres) : avant 408 coffres, 578 contacts ; `clear` 5 : 409, 514 (trajets plus longs) ; **7 : 408, 426**, trajets plus courts sauf en départ exact ; `doors-traffic` perd 1 à 2 voitures en départ exact et jitter 2 ; `movement` inchangé.

### Demi-tour sur tout waypoint (2026-10-14)

Vu en jeu : oscillations, puis départ à grande vitesse à l'opposé de la destination, chemin actif. Cause (`plain-base`, voiture 34417) : le premier waypoint (à 1 tile) est franchi aussitôt et le demi-tour ne regardait que lui ; la voiture, cible dans le dos, oscille de ± 0,08 tour avec ses trois caps, reste en mode rapide et file jusqu'à 570 tiles. Base : `doors` 102 coffres, 78 contacts, 1776 ticks / `movement` 123, 583 contacts, 1397 ticks.
- Premier waypoint non franchi : 103, 55, 1494 / 123, 678, 1485 ; pas de mode rapide cible dans le dos : aucun effet sur `movement`, 34417 toujours perdue ; premier ou deuxième waypoint : 103, 47, 1543 / 123, 726, 1497.
- Seuil `path.u_turn_angle` 0,25 : plus de contacts en forêt (442 → 553) et dans `u-narrow` (72 → 121), des virages serrés du chemin déclenchant un recul ; **0,35 gardé** : 102, 44, 1458 / 123, 599, 1448 (34415 et 34417 : de 225 échantillons de fuite à 5) ; 0,4 : 103, 56, 1475 / 123, 639, 1490.
- Ensuite, 34414 venait d'un point d'approche de porte (désormais compris), 34419 d'un chemin qui revient sur lui-même (il faut un deuxième demi-tour). Un demi-tour par chemin : 34419 perdue ; un par waypoint : `forests` 506 contacts contre 404, `doors-odd` 12 ; **un par waypoint, le deuxième seulement hors zone dense (gardé)** : `movement` 580 / `doors` 51 contacts, `forests` 407, `doors-odd` 8, 34414 et 34419 réglées, durées inchangées. Le refus du mode rapide cible dans le dos est resté de côté (+ 11 à 15 contacts sur `doors` pour 5 % de vitesse).

## À faire

Idées et tâches retenues par le propriétaire, pas encore commencées. Chacune a un commentaire `-- TODO` à l'endroit indiqué.

- **Réseaux logistique et logique.** Gérer les réseaux logistique et logique avec nos bâtiments (coffres d'approvisionnement, chargeurs, garages). (`ghost.lua`, `ghost_control.find_supply_chest`)
- **Ne pas stationner sur les rails.** Limiter les collisions avec les trains ; la liste des voisines de `movement.lua` (`refresh_neighbours`) peut accueillir les trains. (`park.lua`, `garage_control.parking_tick`)
- **Points de recharge automatiques.** Construire des chargeurs pour atteindre une destination éloignée, sans modifier le réseau électrique. (`charge.lua`, `charger_control.find_charger`)
- **Kits de réparation.** Slots de kits de réparation dans le garage pour réparer les voitures, en plus de la réparation gratuite (`garage_control.repair_parked_cars`). (`park.lua`)
- **Falaises.** Détruire les falaises marquées en consommant les explosifs de falaise nécessaires, comme les robots natifs. (`ghost.lua`, `ghost_control.is_target`)
- **Recharger une voiture vide.** Ajouter un ou plusieurs moyens ; aujourd'hui il faut la ramasser et la reposer. (`travel.handle_empty`)
- **Réessai sans limite vers un chargeur.** Ne le garder que lorsque la voiture est sur le retour (recharge juste avant le garage, ou après un abandon complet) ; ailleurs, limiter les essais comme pour les autres trajets. Tant que ce réessai est sans limite, `release_charger_slot` dans `stuck_tick` ne libère jamais rien. (`travel.start_stuck`)
- **Technologies.** Des technologies (`TechnologyPrototype`) pour débloquer et améliorer : l'ensemble minimal d'objets nécessaire au fonctionnement du mod (derrière Automobilism et d'autres), la vitesse de charge et de réparation, la réparation dans les garages, la capacité des garages, des chargeurs et des voitures, la vitesse de construction, la vitesse de déplacement (si possible sans perturber les trajets). (`data.lua`)
- **Autres types de robots** (facultatif). Logistique : objets, liquides. (`ghost.lua`, `ghost_control.register_ghost`)
- **Voiture armée.** Pouvoir armer la voiture (petite capacité) pour qu'elle se défende seule. (`prototypes/car.lua`)
- **Véhicule araignée (spidertron modifié).** Soit en remplacement de la voiture (pas forcément nécessaire), soit en amélioration : il passe bien plus facilement dans les espaces denses et ne subit aucune collision. À vérifier : cohérence avec les technologies du jeu (le spidertron est tardif). (`prototypes/car.lua`)
- **Fuite du danger.** La voiture fuit une force ennemie. (`movement.lua`, `movement.update_mode`)
- **Construction automatique d'une mine.** Sans ghosts : le joueur sélectionne un gisement et les voitures posent et optimisent seules les foreuses, le réseau électrique et, quand c'est nécessaire (uranium), les tuyaux ; même chose pour le pétrole et les sources du même genre. Éventuellement une gare à proximité, les liens avec les réseaux électriques et les rails restant au joueur. Demanderait un haut niveau de recherche et peut-être un bâtiment de plus, une tour de contrôle dont la consommation d'énergie dépend de la distance du chantier et de sa taille. (`ghost.lua`, `ghost_control.register_ghost`)
- **Secours d'une voiture coincée.** Envoyer une voiture la récupérer ou la relancer (risque de bloquer toutes les voitures) ; s'associe à « Recharger une voiture vide ». Plus tard, aller chercher un train en panne. (`travel.lua`, `travel.start_stuck`)
- **Limiter la charge par tick.** Si le mod devient trop coûteux, répartir le travail sur plusieurs ticks, sans gêner le joueur : tri des entités à la sélection, construction des clusters et des batchs, répartition aux voitures, départ des voitures. (`control.lua`, `on_area_selected`)
- **Types de batch dans l'annonce du chat.** Distinguer construction, remblai, démontage, mise à niveau et réseau dans le message « N batch(es) assigned » après une sélection. (`control.lua`, `on_area_selected`)
- **Délai d'inactivité avant publication.** Ramener `idle_delay` de 300 à 60-120 ticks (long exprès pendant le développement, pour bien voir les attentes) ; il borne aussi la durée des manœuvres, des dégagements et des demi-tours : à mesurer avant. (`config.lua`)
- **Affichage de débogage éteint par défaut.** Passer `config.debug_view_default` à `false` avant publication (`debug_view.lua`). (`config.lua`)
- **Graphismes provisoires.** Coffre d'approvisionnement, icône du sélecteur, icône du raccourci des objets manquants (`prototypes/missing_items.lua`), restes du garage et du chargeur (leurs images sont déjà dans `graphics/*/remnants`, pas encore utilisées). (`prototypes/`)

## Problèmes connus

### Ouverts

6. **Mode lent plus lent que `main`** (mesuré en test, 2026-10-12). Près d'un bâti la voiture roule en mode lent même en terrain dégagé : `plain-base` et `long-wall` prennent 1,2 à 1,4 fois le temps de `main`. Acceptable tant que le résultat reste robuste. Atténué par le mode normal à côté d'un bâti (voir « Conduite ») : gain faible (`gates` 913 → 881 ticks, `plain-base` 2750 → 2670), car dans `long-wall` et `plain-base` la cible est derrière un mur et le mode lent y est justifié ; le surcoût sur `main` vient surtout du chemin guidé (demandé après environ 5 tiles et 45 ticks) et du suivi de chemin. Cause non vérifiée.

### Limites assumées

Choix et limites que le propriétaire a acceptés, à ne pas « corriger » sans son accord.

- **Ouverture de 3 tiles au moins** dans un mur (conseil à donner au joueur) : une ouverture d'une tile n'est pas une sortie que la voiture sait trouver ni franchir de façon fiable. Un espace trop étroit pour la voiture est toujours bloquant.
- **Portes qui se suivent** (scénarios `series-*`) : portes alignées, la voiture les enchaîne dès 6 tiles entre les murs (à 3 tiles, couloir de 2 tiles : irrégulier, cas « trop étroit ») ; portes décalées, il faut au moins 10 tiles, en dessous la voiture doit faire un S dans un couloir trop étroit, cale et finit en `stuck`. Conseil au joueur : portes alignées, ou murs espacés d'au moins 10 tiles. Piste non essayée : points d'approche plus larges dans `add_gate_waypoints`.
- **Demi-tour contre un mur complexe** (`wall-turrets`, 1 voiture sur 6 en jitter ; décidé le 2026-10-12) : une voiture qui longe une rangée de tourelles collées à un mur peut se glisser contre leur face ou dans le trou d'une tile entre deux tourelles, osciller de 0,6 tile sans pouvoir tourner (une voiture ne tourne que si elle roule) et finir en `stuck`. Le dégagement ne l'aide pas (il ne détruit que des arbres et des rochers). Essayés sans succès : marge de chemin plus large, friction réduite en poche.
- **Bosquet dense collé à la sortie d'une porte** (`doors-clutter`), **porte masquée par un coffre ou voiture dos à la porte** (`doors-odd`) : 1 à 4 échecs par campagne.
- **Départ au milieu d'une forêt dense** : la voiture se dégage en détruisant arbres et rochers (24/24 en scénario), jamais un bâtiment, un mur ni une falaise ; une voiture emmurée reste `stuck`.
- **Portes ouvertes dans toutes les directions** : les portes de la force à portée d'une voiture en mouvement s'ouvrent, quelle que soit sa direction (`open_gates`).
- **Plus de chargeur joignable** : la voiture attend longtemps (`very_long_delay`) avant d'abandonner, pour laisser le monde évoluer.
- **Zone aveugle de la manœuvre** : le coin d'une grande entité peut passer inaperçu ; rattrapé au tick suivant.

### Corrigés, à valider

- **Roboports jamais construits quand toutes les voitures sont au garage** (ancien problème 12, 2026-10-14). `retry_pending_clusters` parcourt maintenant toutes les phases, `network` comprise (elle s'arrêtait à 3). Scénario `network-parked` : voiture garée, roboport sélectionné au tick 3000, batch attribué aussitôt, roboport construit. À valider en jeu : sélectionner seulement des fantômes de roboports, voitures au garage : une voiture sort et les construit.

- **Oscillations et départ rapide à l'opposé de la destination au départ d'un chemin** (observé en jeu, 2026-10-14). Le demi-tour en marche arrière couvre tout waypoint du chemin (points d'approche de porte compris, un par waypoint, le deuxième sur un chemin seulement hors zone dense), avec un seuil de 0,35 tour (voir « Demi-tour sur tout waypoint »). Cela corrige aussi les voitures qui repartaient à grande vitesse après un demi-tour sans suite (`plain-base` 34414 et 34419). À valider en jeu : la voiture se retourne au départ d'un chemin au lieu d'osciller ou de fuir ; pas de recul inutile en forêt ni dans une impasse étroite.

- **Voiture qui s'éloigne de sa destination dans une plaine, ou rate l'entrée d'une base** (observé en jeu, 2026-10-13). Le braquage ne lit plus la densité au-delà de la cible et la pèse moins en suivi de chemin ; un demi-tour en marche arrière quand le waypoint est derrière la voiture ; les points de passage d'une porte suivent son axe réel (confirmé en jeu) et ne coupent plus le long du mur (virage plus doux à l'entrée d'une porte) ; le but intermédiaire d'un chemin s'écarte moins de la ligne droite ; le chemin est effacé à l'arrivée. À valider en jeu : plus de fuite dans la plaine ni de long détour, moins de chocs contre les murs autour d'une porte, un demi-tour lent quand le chemin démarre dans le dos de la voiture. Affichage de débogage (`debug_view`) à valider aussi (raccourci, tracé du chemin, coûts).

- **Voiture qui dérive du chemin et finit dans une poche** (vu en scénario `work`). En suivi de chemin, la voiture est ramenée vers le segment suivi (`steering_cost.path_deviation`), au lieu de s'en écarter vers un cul-de-sac le long d'un rivage ; près d'un bâti elle reste en mode normal quand sa voie est libre. À valider en jeu : une voiture qui longe un étang ou un mur tourne moins en rond et ne finit plus dans une pointe de terre. Cas restant : voir « Limites assumées ».

- **Voiture bloquée dans une forêt dense.** Dernier recours avant `stuck` : la voiture détruit les arbres et les rochers sur son chemin (jamais un bâtiment, un mur ni une falaise) en cherchant un cap vers la destination qui en croise peu (voir « Dégagement »). À valider en jeu : une voiture qui démarre au milieu d'une forêt s'en sort en laissant une trouée ; elle ne détruit rien d'autre ; même chose parmi des rochers (non couvert par un scénario).

- **Carburant non calibré** (ancien problème 3). L'estimation du carburant d'un trajet (détours de recharge, seuil critique) suit maintenant la mesure (voir « Carburant ») : une voiture ne fait plus de détours inutiles par un chargeur sur les trajets longs, et un chargeur reste joignable avec une marge. À vérifier en jeu : une voiture qui part loin se recharge quand il faut, sans tomber en panne ni se recharger trop souvent.

- **Grands détours, cercles et blocages près des murs et des portes** (ancien problème 5, vu en jeu le 2026-10-11). Cause : la voiture se détectait elle-même à `slow_lookahead.start` 1,2 (voir « Invariants ») ; corrigé par 1,6, avec les trois modes de vitesse, la demande de chemin en conduite normale en zone bâtie ou dense, le refaçonnage du chemin aux portes, la règle de passage des waypoints et l'interdiction du freinage d'urgence en suivi de chemin. Mesuré en scénarios (658 voitures sur 666 contre 634 pour `main`, trajets souvent deux fois plus courts). À valider en jeu :
  - en rase campagne la voiture roule vite, ralentit près d'un mur, d'une porte ou d'un bâtiment (moins de 6 tiles) et repart vite ensuite ;
  - plus de cercles ni de grands détours près d'un mur, d'un bâtiment ou d'une porte : la voiture va droit au passage ; ouvertures de 3 tiles franchies, y compris au milieu d'une base ;
  - une voiture dans une impasse en U, ou dos à sa destination, se dégage seule (manœuvre ou chemin) ;
  - sur un chemin (près de murs, d'arbres, d'une forêt) la voiture ne s'arrête plus par à-coups ; elle s'arrête quand même à l'arrivée et ne finit pas contre un obstacle (un choc doit rester sans dégât notable) ;
  - la voiture n'est pas sensiblement plus lente qu'avant en terrain dégagé à proximité d'un bâtiment (voir problème 6) ;
  - plusieurs voitures qui passent la même porte ne se bloquent pas ;
  - le reste (construction, démontage, mise à niveau, remblai, recharge, garage, fenêtre des objets manquants) se comporte comme avant.

- **Coût de la mesure du seuil critique** (ancien problème 11), sans effet visible : plus de mesure au-dessus de 80 % de charge, mesure espacée (`short_delay`) tant que la charge dépasse le double du dernier seuil. À vérifier en jeu qu'une voiture qui passe sous le seuil part toujours se recharger à temps.

- **Sélecteur renommé et descriptions complétées** (2026-10-14). Le sélecteur s'appelle « Sélecteur des voitures autonomes » (objet, raccourci et touche) ; les descriptions du mod, de la voiture, du garage, du coffre et de l'affichage de débogage mentionnent le remblai, le démontage, la mise à niveau, le dégagement des arbres et des rochers, la réparation au garage et ce que le coffre reçoit ; le raccourci du sélecteur a une description. À valider en jeu : noms et infobulles lisibles en anglais et en français.

#### Validation reportée

- **Qualité des objets** (ancien problème 9). Les ghosts, les mises à niveau, la collecte, le dépôt, la fenêtre des objets manquants et le garage tiennent compte de la qualité (un ghost de qualité rare n'est construit qu'avec un objet rare, rien ne devient gratuitement normal ou rare, une voiture rare reste rare au garage). Écrit d'après la documentation, sans l'extension Qualité : ni essayé en jeu ni couvert par un scénario (Factorio refuse tout prototype de qualité sans l'extension : « Quality is disabled and can not be used », essayé le 2026-10-10 ; le jeu de test n'a que la qualité normale, et la qualité normale ne régresse pas). À faire essayer avec l'extension (le propriétaire n'a pas la version du jeu nécessaire à court terme : validation reportée).
