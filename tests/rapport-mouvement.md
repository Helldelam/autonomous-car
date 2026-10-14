# Rapport sur la branche `feature/movement-built-environments` (2026-10-12)

Branche issue de `main` (53f134d). Un commit de sauvegarde (97d4250, « pas une version terminée ») est poussé ; le dégagement et les derniers correctifs ne sont pas encore commités.

## 1. Changements faits

### Déplacement
- **Trois modes de vitesse** (`fast`, `normal`, `slow`) : `slow` près d'un bâti, en zone dense, ou après un arrêt d'urgence, une manœuvre ou un chemin.
- **Cause des cercles et grands détours trouvée** : à `slow_lookahead_start` 1,2 la voiture se détectait elle-même et lisait un obstacle imaginaire. Valeur portée à 1,6 (invariant documenté).
- **Chemin guidé** en conduite normale (zone bâtie ou dense, destination hors du cône ou ligne bloquée), en plus du chemin de secours.
- **Portes** : le chemin est refaçonné là où il traverse une porte (`add_gate_waypoints`) ; règle de passage des waypoints (`path_pass_radius` 8).
- **Pas de freinage d'urgence en suivi de chemin** (mesuré sans dégât notable, plus de réussites).
- **Impasse de poche** (problèmes 7 et 8) : quand un virage cale une seconde fois au même endroit et au même angle, `back_off` inverse le sens (`maneuver.turn_stall`).
- **Dégagement** (nouveau, dernier recours avant `stuck`) : la voiture détruit les arbres et les rochers sur sa route, jamais un bâtiment, un mur ni une falaise. Cap choisi vers la destination en croisant le moins d'obstacles. Se relance seul après un arrêt net, 10 fois par trajet au plus. Réglages dans `config.clearing`.

### Carburant
- Estimation par morceaux : 50 000 J fixes, 2500 J/tile sur les 100 premières tiles, 450 J/tile au-delà (`fuel_safety_margin` supprimée). Couvre environ 90 % des 364 trajets mesurés (pièges compris) et tous les trajets longs. Marge large, acceptée par le propriétaire (elle garde une fuite possible).

### Outils de test (dossier `tests/`, temporaire)
- Scénarios `range-open`, `range-trees`, `range-built`, `range-long` (consommation) ; 30 scénarios `series-*` (portes en série) ; variantes `test_jitter`, `test_jitter_size`, `test_door_shift`, `test_tiles`, `test_long`.

## 2. Résultats

| Mesure | Avant | Après |
|---|---|---|
| Campagne des trois modes, 666 voitures | `main` 634 | 658 |
| Temps de trajet moyen, `gates` / `maze` / `doors-base-3` | 1368 / 2103 / 2368 ticks | 810 / 955 / 1010 |
| `forests` (24 parcours) | 17/24 (avec le patch d'impasse), 16/24 avant lui | **24/24**, et 24/24 en `test_jitter` 1, 2 et 3 (96/96) |
| `movement` (autres scénarios) | | inchangé : `u-side` 20/20, `u-narrow` 20/20, `turn-around` 12/12, `maze` 6/6 |
| Carburant, trajets courts | 2100 J/tile partout (4× trop pour les longs) | formule ci-dessus |
| Portes alignées en série | non testé | enchaînées dès 6 tiles d'écart |

Plus lent qu'avant : `plain-base` et `long-wall` (1,2 à 1,4 fois `main`, voir problème 6).

## 3. Reste à faire sur le mouvement

### Problèmes ouverts
- **6. Mode lent plus lent que `main`** près d'un bâti en terrain dégagé. Piste décrite, non réalisée : rester en mode normal en zone bâtie tant que la destination est dans le cône et la ligne droite libre.
- **7. Pointe de remblai** (`work`) : le patch d'impasse fait réussir le départ exact et `test_jitter=3`, mais `test_jitter=2` (0,05) échoue encore.
- **8. Tourelle contre un mur** (`wall-turrets`) : réussit seul, échoue encore dans le groupe `movement` (voiture dans une poche de 0,5 tile, orientation jamais modifiée, même avec le correctif). Piste : aucune solution trouvée ; le dégagement n'aide pas contre une tourelle ou un mur.
- **9. Portes décalées en série** : il faut au moins 10 tiles entre murs ; en dessous, la voiture doit faire un S dans un couloir trop étroit et finit en `stuck`. Conseil au joueur : portes alignées, ou murs espacés d'au moins 10 tiles. Piste non essayée : points d'approche plus larges dans `add_gate_waypoints`.
- Limites acceptées inchangées : `doors-clutter` 36 à 39 sur 42 (bosquet collé à la sortie), `doors-odd` 1 à 4 échecs (porte masquée par un coffre, voiture dos à la porte), espaces trop étroits.

### Développement en cours
- Rien d'appliqué à moitié : le patch d'impasse et le dégagement sont dans le code. Aucune expérience en attente.

### À valider en jeu (« Corrigés, à valider » dans CLAUDE.md)
- Dégagement : une voiture qui démarre au milieu d'une forêt s'en sort en laissant une trouée et ne détruit rien d'autre.
- Les trois modes (liste dans « Réglage du mouvement »), le carburant, le seuil critique.

### Limites de la validation
- Le dégagement n'est testé que sur des arbres (pas de scénario de rochers).
- `construction` et `work` en jitter 2 datent d'avant le dernier réglage du dégagement ; pas relancés.
- Toutes ces mesures sont en scénarios ; rien n'est encore confirmé en jeu.

### Décisions attendues du propriétaire
- Commiter et pousser l'état actuel ?
- Chercher une vraie sortie de poche pour 7 et 8 (campagne coûteuse, mécanismes fragiles) ou les laisser en limite acceptée ?
- Traiter le problème 6 (vitesse) ou le laisser tel quel ?
