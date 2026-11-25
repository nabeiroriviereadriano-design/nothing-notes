# Journal des versions

## 3.0.0

Mise à jour **sans perte de données** : sauvegarde vérifiée avant migration,
contrôle complet après, remise en place automatique en cas d'écart (voir
[MIGRATION-3.0.md](MIGRATION-3.0.md)). Mode d'emploi : [GUIDE.md](GUIDE.md).

**Nouveau**
- Pages et sous-pages : arborescence, fil d'Ariane, récents, déplacement,
  duplication et corbeille en cascade, icône de page.
- Éditeur : Titre 3, blocs repliables, menu d'insertion `/` (grands boutons sur
  téléphone), glisser-déposer des blocs, `Ctrl+Maj+↑/↓`.
- Liens entre pages avec `@`, section « Mentionnée dans » (rétroliens), ouverture
  rapide `Ctrl+P`.
- Tâches : une case à cocher peut être suivie (statut, échéance, priorité) sans
  être dupliquée ; vue Tâches avec filtres (à faire, en cours, terminées, en
  retard).
- Bases de données légères : propriétés texte, nombre, date, case à cocher,
  statut, sélection et lien ; vues tableau, liste et calendrier ; tri, filtres,
  recherche ; modèles d'entrée ; lisibles sur téléphone.
- Modèles : note rapide, cours, réunion, projet, liste de tâches, journal, fiche
  de révision, et vos propres modèles. Un modèle ne remplace jamais le contenu
  existant.
- Import de fichiers Markdown ; partage Android entrant et sortant.
- Export TXT / Markdown / HTML / PDF des nouveaux blocs, des propriétés et des
  bases.
- Sauvegardes : création manuelle, liste, restauration (l'état remplacé est
  lui-même sauvegardé).
- Accents rouges, utilisés avec parcimonie : bouton +, élément actif, priorités,
  tâches en retard, alertes. Textes rouges éclaircis en thème sombre pour rester
  lisibles.
- Calendrier et sélecteurs de date en français.

**Sécurité des données**
- Les champs inconnus (version future) sont conservés partout.
- L'éditeur ouvert ne peut plus réécrire un champ modifié ailleurs (menu, autre
  appareil).
- La synchronisation refuse un appareil 2.0, qui effacerait les nouveaux champs,
  et affiche un message clair. Il faut mettre à jour les deux appareils.
- Le compteur du journal de synchronisation ne recule jamais, même après une
  restauration.

## 2.0.0

Synchronisation directe entre appareils sur le réseau local, par code à 6
chiffres, chiffrée ; plus de compte ni de serveur.

## 1.0.0

Première version.
