# Validation de mcm — 4 novembre 2026

État de validation de la version personnelle 0.2.0, destinée à macOS 27 sur Apple Silicon. La compilation release et la vérification de signature locale ont réussi. La suite complète passe : **59 tests**, dont 40 sur les données, la persistance et la localisation et 19 sur AppKit, les réglages et le routage Carbon du raccourci. Ce document distingue ces vérifications des interactions qui demandent encore une recette dans les applications réelles.

## Contrôles automatisés

Commande de vérification :

```sh
swift test
```

Les contrôles implémentés et exercés couvrent :

- Historique initial de 20 entrées et budget de 256 Mio ; rang le plus récent, promotion, suppression, dédoublonnage strict et éviction d’entrées entières.
- Conservation des octets, des représentations multiples et de l’ordre des éléments, y compris les formats privés simulés, les métadonnées de source et du Python avec Unicode, tabulations et retours CRLF.
- Matérialisation des représentations différées avant changement de propriétaire du presse-papiers, notamment depuis un fournisseur dans un autre processus avec lecture sur la file de travail.
- Conversion d’une exception Objective-C de fournisseur en échec récupérable ; une capture incomplète ou un fichier manquant ne remplace pas le presse-papiers existant.
- Miniatures bornées sans modification des données d’image originales ; distinction entre taille des fichiers référencés et taille de leurs représentations.
- Persistance activable après capture en mémoire, restitution des octets après réouverture, suppression de la sauvegarde à la désactivation et absence d’écriture de contenu lorsque la persistance est désactivée.
- Détection des blobs absents ou endommagés, nettoyage des fichiers orphelins et conservation d’un historique mémoire utilisable si SQLite est endommagé.
- Clavier de la palette : numéros/AZERTY, sélection après changement des rangs, absence de collage d’une sélection périmée et ouverture des réglages par ⌘,.
- Routage des événements Carbon vers mcm, rejet des signatures étrangères et suppression du gestionnaire lors de l’arrêt.
- Préférences initiales, restauration de la fenêtre et des réglages, normalisation des limites numériques avant calcul et repli après un raccourci enregistré invalide.
- Police de 10 à 28 points, taille et hauteur des lignes cohérentes, valeurs non finies normalisées et préférences conservées au redémarrage.
- Animations désactivées par défaut, activables puis désactivables, sans transparence résiduelle.
- Catalogues français/anglais complets, arguments de formatage, langue système et changement de langue sans transformation des données originales.

Ces fixtures ne prouvent pas que Word ou Excel interpréteront toutes leurs représentations privées exactement comme lors d’un collage direct.

## Vérification visuelle déjà effectuée

L’application de démonstration a été ouverte par pilotage de l’interface macOS. La palette, les numéros, la promotion d’une entrée après sélection numérique et l’accès aux réglages ont été examinés ; la valeur initiale de 20 entrées et la persistance désactivée ont été vérifiées. Le menu natif permet de quitter proprement l’application. Cette vérification utilise un presse-papiers privé ; aucune autorisation de lecture ou de collage n’a été accordée à mcm à la place de l’utilisateur.

Pour la version 0.2.0, le passage en direct de la langue système à français puis retour a été vérifié, y compris les menus, le titre, les commentaires des entrées et les tailles en octets. Le curseur de police a été testé à 24 puis 14 points ; les lignes s’adaptent sans couper verticalement le texte. Le réglage des animations a été activé puis désactivé. Les préférences de démonstration ont été remises à 14 points, langue système et animations désactivées.

Deux fixtures de fournisseurs différés internes au processus de test produisent un avertissement AppKit d’affinité de thread. Le fournisseur différé testé dans un processus distinct remplit sa promesse sur son propre fil principal, sans cet avertissement ; la récupération des octets et la gestion d’une exception sont vérifiées.

## Recette manuelle restant à effectuer

| Scénario | Résultat attendu |
| --- | --- |
| Raccourci global sur le clavier réel, y compris conflit avec Quicksilver | ⌥A ouvre et masque mcm ; un conflit est signalé et un autre raccourci peut être enregistré. |
| Collage automatique avec autorisations accordées | Un numéro ou Entrée colle une seule fois dans l’application précédente ; l’entrée remonte en tête. |
| Autorisations refusées ou révoquées | Une indication est affichée ; le collage manuel reste possible pour une entrée recopiée. |
| Brave, TextEdit, Terminal et Finder | Le bon destinataire reçoit le contenu et les formats qu’il prend en charge. |
| Word : styles, listes, tableaux et images | Comparer le collage direct et le collage via mcm, puis refaire le test après fermeture de la source. |
| Excel : plages, formules, formats numériques, bordures et cellules fusionnées | Comparer au collage direct dans Excel et vérifier les formats privés effectivement exposés. |
| Persistance avec de vrais contenus Word/Excel et images | Retrouver les mêmes résultats après redémarrage de mcm ; ne pas confondre réussite d’un test d’octets et fidélité fonctionnelle d’Office. |
| Plusieurs écrans, Spaces, plein écran et déconnexion d’écran | La palette reste accessible ; le déplacement la fixe et le mode pointeur peut être réactivé. |
| Veille puis réveil | La capture reprend et le raccourci continue de fonctionner. |
| Quitter juste après une copie ou une désactivation de persistance | Les opérations en cours sont terminées et aucune sauvegarde supprimée n’est recréée. |
| Fichiers multiples, fichiers déplacés/supprimés et volumes indisponibles | Les références utilisables sont collables ; une indisponibilité est signalée. |
| Copies rapides et images volumineuses | L’interface répond pendant les traitements ; aucune copie n’est présentée comme complète après perte d’un format. |

## Mesures à recueillir

Lancer le bundle avec `--measure`, ouvrir plusieurs fois une palette déjà chargée et relever les durées du chemin d’ouverture AppKit. Compléter par une observation de l’affichage et du collage réel, ainsi que du CPU et de la mémoire, avec du texte, des images volumineuses et un historique augmenté dans les réglages.

L’objectif de 50 ms à chaud au 95e percentile **n’est pas encore validé**. Aucun plafond CPU n’est un critère de réception. La fréquence de lecture de 200 ms implique une limite connue : les copies intermédiaires remplacées entre deux lectures peuvent échapper à l’historique.
