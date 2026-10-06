# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Mod Factorio 2.0 (Lua 5.2) « Autonomous Car » : une voiture autonome qui construit des ghosts hors réseau de robots, se recharge et se gare seule. Ce fichier est la seule documentation du projet.

## Règles de travail

- Comprendre la cause d'un bug au niveau du tick avant de corriger ; pas de correctif de symptôme.
- Changements petits et chirurgicaux. Réutiliser les helpers et l'API Factorio existants ; pas de second système d'état.
- Le code fonctionne globalement en jeu : une incohérence vue à la lecture n'est pas un bug tant qu'elle n'est pas confirmée en jeu, par un scénario de test ou par le propriétaire.
- Ne lancer les tests que sur demande du propriétaire.
- Git : `main` ne contient que des versions validées par le propriétaire. Tout travail se fait sur une branche à part (la créer avant la première modification si on est sur `main`). Ne jamais pousser ni fusionner dans `main` sans demande explicite du propriétaire ; proposer de committer, pousser ou fusionner quand cela semble utile (fin d'un changement cohérent, version prête à valider), puis attendre sa réponse.
- Tenir à jour la liste « Problèmes connus » en bas de ce fichier : ajouter tout problème découvert ; un problème corrigé passe dans « Corrigés, à valider » et n'est retiré qu'après validation du propriétaire.
- Code, commentaires et messages en jeu en anglais ; ce fichier en français.

## Commandes

Pas de build ni de linter, pas d'interpréteur Lua. Dépôt git privé (branche `main`) ; `.backup/` (état d'avant le dernier grand renommage) est ignoré par git.

- Le mod est chargé depuis ce dossier, dont le nom doit rester `<name>_<version>` de `info.json`.
- Changement runtime : recharger la sauvegarde. Changement de prototype (`data.lua`, `prototypes/`, valeur de `config.lua` lue par un prototype) : redémarrer Factorio.
- Erreurs : `%APPDATA%\Factorio\factorio-current.log`.

Scénarios de test (dossier `tests/`, temporaire : à retirer avant publication, le mod n'en charge rien) :

```powershell
tests\run.ps1                                  # tous les scénarios, quelques minutes
tests\run.ps1 construction -Ticks 8000         # un scénario, plus court
tests\run.ps1 -Reference <dossier ou zip>      # compare les traces avec une autre version du mod
tests\show.ps1 construction -Car 132           # changements d'état d'une voiture dans une trace
```

`run.ps1` lance Factorio sans fenêtre ni joueur sur une copie du mod dans `%TEMP%\autonomous-car-tests` ; rien n'est écrit dans le dossier Factorio et le jeu peut rester ouvert. Il affiche pour chaque scénario l'erreur de script éventuelle, les événements et le dernier résumé. `-Reference` sert à vérifier qu'un refactoring ne change aucun comportement : Factorio est déterministe, deux versions équivalentes donnent des traces identiques. Les scénarios sont décrits dans `tests/harness.lua`, qui est greffé à la fin de `control.lua` et utilise ses locales : renommer l'une d'elles impose de le mettre à jour.

## Architecture

### Modules

`config` → `_utils` → `charge`, `park` → `travel` → `ghost` → `control`, et `movement` à côté (il ne dépend que de `config` et `_utils`). Ce graphe doit rester acyclique : c'est pourquoi `requeue_construction` vit dans `travel.lua` et pourquoi l'arrivée d'une voiture passe par un événement plutôt que par un appel à `control.lua`.

| Fichier | Module | Rôle |
|---|---|---|
| `control.lua` | | événements, suivi des entités, tick |
| `movement.lua` | `movement` | mode de conduite, accélération, direction |
| `travel.lua` | `travel` | trajets, détours de recharge, stuck, abandon |
| `ghost.lua` | `ghost_control` | ghosts, clusters, assignation, construction |
| `charge.lua` | `charger_control` | chargeurs |
| `park.lua` | `garage_control` | garages |
| `_utils.lua` | `_utils` | carburant, deque, alertes, libération d'entités |
| `config.lua`, `colors.lua` | | constantes, partagées avec les prototypes |

### État

`storage.cars[id]` est l'entité, `storage.car_data[id]` son état (créé par `new_car_data` dans `control.lua`) ; même schéma pour chargeurs et garages. Les tables sont créées par `init_storage` au premier tick ; il n'y a ni `on_init` ni migration, donc un champ ajouté à `car_data` n'existe pas pour les voitures déjà posées.

Toute entité devenue invalide est libérée par `_utils.release_entity(kind, id)`. Les ghosts sont suivis par `on_object_destroyed`, pas par les événements died/mined.

### Tick

`on_tick` appelle `update_car` pour chaque voiture, qui exécute la première branche vraie, dans cet ordre :

1. batterie vide (`travel.handle_empty`), puis carburant critique (`travel.handle_critical_fuel`)
2. `moving` : `movement.update_mode`, puis `movement.maneuver` si une manœuvre est active, sinon `movement.drive`, puis `travel.stuck_reason`
3. `charging`
4. `parking`
5. `building` : un ghost toutes les `config.build_interval` ticks
6. `stuck` : `travel.update_stuck` (réessai, ou abandon via `ghost_control.abandon`)
7. `waiting` : `end_wait` choisit la suite (reprise du batch, cluster en attente, garage)

`update_mode` fixe `precision_mode`, `emergency_brake`, `high_speed` et `friction_modifier` (recalculé chaque tick, jamais incrémenté), et peut démarrer une manœuvre ; `drive` lit `emergency_brake` et `precision_mode` dans le même tick, l'ordre ne doit pas changer.

### Manœuvre, stuck, batterie vide

La manœuvre (`car_data.maneuver`) est un sous-mode de `moving` : même destination, conduite lente (friction), avant ou arrière. Toutes les `maneuver_arc_duration`, elle mesure l'espace libre sur six caps (avant/arrière × gauche/droit/droit devant) et règle le braquage via `riding_state`, jamais l'orientation. Un mur en pierre n'a que 0,58 tile d'épaisseur : les sondes sont donc espacées de 0,5 tile, et la zone entre la voiture et le premier point (`maneuver_probe_start`) est sondée à part par `find_entities_filtered` (la voiture se détecterait elle-même avec `can_place_entity`). Elle démarre sur `rear_turn` (cible derrière), `blocked` (arrêt net) ou `no_progress` (peu de déplacement sur `medium_delay`) ; une durée de trajet dépassée (`timeout`) va directement en `stuck`. Elle finit quand la densité est basse et le devant libre (plus l'angle pour `rear_turn`, plus `maneuver_min_travel` sinon) ; au-delà de `maneuver_duration` elle échoue, et après `max_maneuver_attempts` échecs la voiture est `stuck`.

`stuck` : arrêt, alerte, attente `long_delay`, puis nouvel essai du même trajet (`stuck.destination`, sa tâche est restée en tête de file). Après `max_stuck_retries` essais, ou sans carburant pour le trajet, attente `give_up_delay` puis abandon : les ghosts du batch sont libérés (le joueur doit les resélectionner) et la voiture rentre par les tâches existantes (dépôt, charge, garage). Un trajet vers un chargeur est réessayé sans limite. `stuck_retry_count` est remis à zéro à l'arrivée, pas dans `begin_leg`.

`empty` : batterie à 0, la voiture ne fait que surveiller `critical_fuel_ratio` (alerte `battery_empty`), puis reprend son batch par `waiting`. Rien dans le mod ne recharge une voiture vide : le joueur la ramasse et la repose, ce qui crée une nouvelle voiture.

### Trajets et tâches

`travel.begin_leg(car, destination, next_task)` démarre un trajet et pousse `next_task` en tête de `car_data.tasks`. `travel.set_destination` fait de même après avoir vérifié le carburant, avec un détour par un chargeur si besoin : c'est la variante par défaut.

Une voiture est arrivée quand elle est à l'arrêt à moins de `config.arrival_distance` ; elle peut alors agir sur sa destination. `movement.drive` lève l'événement `autonomous_car_next_task` et `on_next_task` dépile la tâche : `charging`, `parking`, `building`, `collect` ou `deposit`. La fin de charge lève le même événement. Cet événement est synchrone : `on_next_task` s'exécute à l'intérieur de `drive`.

Un nouveau type d'étape est une tâche de plus dans `on_next_task`, pas un nouvel état.

### Construction

Sélection du joueur → `on_area_selected` → `register_ghost` (ignore les ghosts couverts par un réseau logistique) → `build_clusters` → `find_available_car` (voiture en `waiting`, sinon sortie d'un garage) → `assign_cluster`, qui crée `car_data.construction`.

`ghost_control.proceed` est le point de décision unique, rappelé après chaque étape : coffre d'approvisionnement (`collect`), trajet vers le chantier (`go_to_site`), ou attente avec alerte si aucun coffre n'aide. Sur place, `build_tick` construit un ghost à la fois ; `finish` dépose les restes (`deposit`) puis prend un cluster en attente ou repasse en `waiting`. Les clusters sans voiture attendent dans `storage.pending_clusters`.

### Carburant

La voiture brûle un carburant caché, sans slot : la charge est `burner.remaining_burning_fuel`. Un brûleur vide perd son item de carburant et ignore alors toute écriture de la charge ; `_utils.fuel_capacity` le remet en place, il faut donc l'appeler avant d'écrire. `charger_data.users` est réservé au départ vers le chargeur.

## Invariants

- `building.active` n'est vrai qu'une fois la voiture arrêtée sur son chantier ; pendant un trajet c'est `car_data.construction` qui indique un batch en cours. `building` et `construction` ne se confondent pas.
- `moving.destination` peut être une table `{position, valid}` (waypoint de `step_back`) au lieu d'une entité : n'en lire que ces deux champs.
- `stuck` est un état de repli, pas une courte pause.
- Le mode précision est inachevé (actif en zone dense seulement) ; le propriétaire compte le reprendre, ne pas le traiter comme du code mort.
- `emergency_brake` ne s'applique qu'en `drive`, jamais en manœuvre.
- Pas de migration : le mod n'est pas publié, les nouveaux champs de `car_data` (`maneuver`, `empty`, `stuck.*`) imposent une nouvelle sauvegarde.
- Le script ne règle jamais l'orientation de la voiture, seulement `riding_state`. Hypothèse non vérifiée en jeu : le braquage n'est pas inversé en marche arrière (`REVERSE_STEERING_INVERTED` dans `movement.lua`).
- Les noms de prototypes (`autonomous_car`, `autonomouscar_charging_station`, `autonomous_car_garage`, `autonomous_car_chest`, `electric_cars_fuel`) sont enregistrés dans les sauvegardes : ne pas les renommer sans accord.

## Conventions de nommage

- État : `car_data.<état>.active`, avec `since` pour le tick de début.
- Entités : `car`, `charger`, `garage`, `chest`, `ghost`, sans suffixe ; leurs données en `<entité>_data`. `destination` est l'entité ou le waypoint visé, `target` sa position.
- Fonctions : verbe en premier ; `find_*` pour une recherche, `alert_*` pour une alerte. Une alerte répétable passe par `_utils.alert_once` / `alert_reset`.
- `config.lua` : `*_delay` attente avant de réessayer, `*_duration` durée d'une action, `*_interval` période. « fuel » est la charge de la voiture, « energy » le tampon du chargeur.
- Tout nouveau délai réutilise `short_delay`, `medium_delay`, `idle_delay` ou `long_delay` et s'ajoute à la liste d'usages de son commentaire.

## Réglage du mouvement

Régler un bloc à la fois, un paramètre à la fois, dans cet ordre, en testant en jeu entre chaque :

1. sécurité : `emergency_brake_lookahead`, `arrival_distance`
2. manœuvre : `rear_turn_min_angle`, `rear_turn_max_speed`, `maneuver_*`, `friction_maneuver_factor`
3. densité et précision : `dense_area_threshold`, `precision_*`
4. friction : `friction_*`
5. `density_radius` et `lookahead_*` si le problème persiste

| Symptôme | Constantes à regarder |
|---|---|
| oscille autour de la destination | `arrival_distance`, `emergency_brake_lookahead`, `precision_*`, `dense_area_threshold` |
| manœuvre à tort, ou trop tôt | `rear_turn_min_angle` (à augmenter), `rear_turn_max_speed`, `short_delay` (déclencheur `blocked`) |
| manœuvre qui n'aboutit pas | `maneuver_duration`, `maneuver_exit_density`, `maneuver_exit_angle`, `maneuver_min_travel`, `maneuver_probe_*`, `friction_maneuver_factor` |
| s'arrête trop souvent en trajet | `density_radius`, `lookahead_length`, `dense_area_threshold`, `emergency_brake_lookahead` |
| trop rapide ou trop lente | `friction_*` |

La friction agit sur le symptôme, pas sur la cause : régler d'abord les seuils de décision. La manœuvre doit rester une exception.

À vérifier en jeu après un réglage : ligne droite sans oscillation, cible derrière sans demi-tour inutile, arrêt propre près d'un obstacle, zone dense sans faux `stuck`, cluster construit sans arrêt inutile, recharge puis parking, plusieurs voitures sans blocage mutuel.

## Problèmes connus

### Ouverts

Observés dans les scénarios de test.

1. **Erreur de script dans `charge.lua`** (`attempt to compare number with nil`). Une voiture en route vers un chargeur garde `waiting.active`, donc `find_available_car` lui donne un batch ; sa tâche `charging` reste dans la file et `on_next_task` l'exécute à l'arrivée d'un `step_back`, dont la destination n'est pas un chargeur. Scénario `stale-task`.
2. **Places de chargeur pas toujours libérées.** `users` est réservé au départ vers le chargeur et rendu en fin de charge, ou quand la batterie tombe à zéro (`release_charger_slot`) ; un trajet vers un chargeur interrompu ou remplacé autrement laisse la place prise. Scénarios `basics` et `stale-task`.
3. **Garage rempli pendant le trajet.** `garage_control.park` désactive `parking` sans activer `waiting` : la voiture n'a plus aucun état actif. Scénario `failures`.
4. **`charge_detour_count` ne compte pas les détours.** `begin_leg` le remet à zéro, donc des détours réussis ne s'accumulent jamais ; il ne monte que lorsqu'aucun chargeur n'est trouvé, et c'est ce cas qui déclenche `mark_unreachable` après `max_charge_detours` essais. Scénario `failures`.
5. **Surfaces multiples.** Les recherches de chargeur, garage, coffre et voiture comparent des positions sans vérifier la surface : une voiture peut viser une entité d'une autre surface.
6. **Manœuvre dans un espace très étroit.** Dans une pièce de 5×5 murée, la voiture met jusqu'à ~3 cycles de manœuvre pour retrouver une ouverture d'une tile (le choix du cap ne vise pas l'ouverture, seulement l'espace libre). Scénario `sealed`.
7. **Tâche en file après un `reset_to_waiting`.** Une tâche restée dans `car_data.tasks` laisse `end_wait` sans état actif (branche « tasks still queued »).
8. **Les portes (`gate`) ne s'ouvrent pas pour la voiture.** Scénario `gate-manual` : un personnage franchit une porte, la voiture conduite droit dessus reste bloquée contre elle comme contre un mur. Une voiture ne peut donc pas passer un mur par une porte, et sa conduite (`sample_cost`, `can_place_entity`) traite une porte fermée comme un mur. Le scénario `gate` le confirme : la voiture longe le mur sans viser la porte.

### Corrigés, à valider

- **Voiture bloquée à la sortie du garage.** `release_car` la pose contre le garage ; quand sa cible était derrière elle, elle reculait dans le garage. Le mode manœuvre est censé le résoudre : à valider avec les scénarios `garage-exit` et `construction`.
- **`stuck_retry_count` jamais atteint.** Il est maintenant remis à zéro à l'arrivée et non dans `begin_leg`, donc `max_stuck_retries` peut se déclencher : à valider en test (le scénario `sealed` passe par ce compteur).
- **`moving` restait actif après un `step_back`.** `on_next_task` le désactive quand la file est vide, et le scénario `blocked-ghost` construit maintenant son ghost : à valider en jeu.
