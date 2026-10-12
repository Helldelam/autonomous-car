# Rapport (2026-10-12)

## Carburant
- Consommation mesurée : ~115–129 J par tick en mouvement, ~0 à l'arrêt, indépendante du mode. J/tile ≈ 120 / vitesse (rapide 600–750, lent 980–1500 J par tile de chemin).
- Actuel : 2100 J/tile → surestime ~4× les longs trajets.
- Candidats : fuel ≈ a·d + b, a 2000–3000 J/tile, b 40 000–60 000 J (couverture 87–91 %, 90–95 % pour d ≥ 60).
- Limites : peu de trajets > 250 tiles, seule la tuile grass-1.
- Mesure à la main (si souhaité) : scénarios `range-open`, `range-trees`, `range-built` (catégorie `energy`), colonne 7 de la trace.

## Échecs de construction
- `work` : ~2 lancements sur 10 (départ exact, jitter 0,05 seed 2). Cause : impasse de manœuvre à la pointe du remblai (la voiture ne tourne que si elle roule ; 0,55 tile de course ; `back_off` repart dans le même sens après un arc calé).
- `wall-turrets` : 1 sur 6 (départ exact), même famille.
- Correction envisagée : inverser le sens quand un arc qui braque a calé sans avancer ; campagne nécessaire.

## Problème 6 (mode lent)
- Condition de demande de chemin : zone bâtie/dense, pas de chemin actif, distance > 10, `next_tick` atteint, et (hors du cône de 0,2 tour ou ligne bloquée).
- Piste : rester normal en zone si destination dans le cône et ligne libre ; mode lent gardé dans tous les autres cas.

## Problème 4 (ouvertures d'une tile)
- Rien d'autre à faire ; retiré. Option : mentionner le minimum de 3 tiles dans la description du mod.
