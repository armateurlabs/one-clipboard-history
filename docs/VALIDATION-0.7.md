# Validation de One Clipboard History — 4 novembre 2026

Version **0.7.0 (7)**, macOS 27, Apple Silicon, Xcode 27.1.
Ce relevé distingue les contrôles exécutés des validations qui nécessitent encore
des permissions, du matériel ou une signature de distribution. La validation
historique de mcm 0.6.0 est conservée dans [VALIDATION-0.6.md](VALIDATION-0.6.md).

## Tests automatisés

`swift test` : **134 tests réussis**, dont **78 Core** et **56 AppKit/réglages**.
La mesure d’ouverture est un test supplémentaire, désactivé par défaut.

La suite couvre les octets et représentations multiples, l’ordre des éléments et
des formats, la déduplication stricte, les formats différés, le Python avec
Unicode/tabulations/CRLF, la persistance et ses corruptions, les limites par
entrée entière, les réglages, le clavier de la palette, le placement, les
apparences, les traductions et les événements de lancement silencieux.

La [CI GitHub macOS 27 / Apple Silicon](https://github.com/armateurlabs/one-clipboard-history/actions/runs/41824814530)
a également réussi : tests, compilation release, validation du bundle, archive
Store sandboxée et conservation des artefacts ZIP. Le code exécuté est celui de
`c38f1fe` ; le correctif de publication suivant réencode seulement les captures
en PNG et complète ce relevé.

Les ajouts de cette version vérifient notamment :

- Compatibilité des anciennes sauvegardes sans bookmarks, métadonnées d’accès
  séparées des données originales et du contenu utilisé pour dédupliquer.
- Refus d’accès, fichier disparu/déplacé, bookmark invalide ou périmé,
  renouvellement et libération équilibrée des scopes de sécurité.
- Import en lecture seule, fusion sans écrasement, rejet anticipé des limites,
  lecture d’un seul blob à la fois, doublons, corruption, traversée de chemin,
  rollback et nettoyage après transaction.
- Préservation du propriétaire du presse-papiers lorsqu’ordre et octets sont
  encore identiques, y compris face à une donnée modifiée sans nouveau compteur.
- Refus d’une restauration Excel dépendante du contexte avant toute modification
  du presse-papiers ; accord explicite permettant de restituer tous les formats,
  sans retirer le marqueur OLE ni modifier les données.
- Licence, confidentialité et liens du panneau À propos ; aperçu isolé avec
  texte, Python, contenu enrichi, image originale et fichiers synthétiques.

## Contrôles réels de l’application

| Contrôle | Résultat exécuté |
| --- | --- |
| Compilation release directe et aperçu | Réussite ; signature locale, version, ressources, traductions, icône, licence et politique de confidentialité vérifiées. |
| Archive Xcode Store | Archive native produite avec sandbox, lecture des fichiers sélectionnés et bookmarks applicatifs ; aucun droit d’Accessibilité ou exception temporaire. Signature ad hoc de faisabilité. |
| Import natif sandbox | Sélection explicite du dossier de test dans NSOpenPanel, puis import de trois entrées d’ancien schéma sans bookmarks : texte Unicode, Python et copie Excel. Les quatre fichiers source restent identiques selon SHA-256. |
| Protection Excel dans le sandbox | Entrée importée signalée, avertissement natif présenté au double-clic ; Annuler ferme l’avertissement et conserve l’historique visible sans lancer la restauration. |
| À propos et licence | Nom, version/build, Armateur Labs, liens GitHub/MIT/confidentialité inspectés dans le panneau natif ; licence lisible dans une fenêtre locale non modifiable. |
| Français, clair et sombre | Vérifiés dans l’application d’aperçu ; trois captures réelles dans `docs/screenshots/`, uniquement avec données synthétiques. |
| Saisie numérique et classement | Entrée Python recopiée sur le presse-papiers privé de l’aperçu, puis retrouvée au rang 1. |
| TextEdit | Capture d’une fixture Unicode et restitution dans un document temporaire par récupération manuelle ⌘V. |
| Word | Texte et gras restitués via les commandes natives de copie/collage ; vérification du style d’un caractère sélectionné, pas seulement du style du curseur final. Texte simple retrouvé après fermeture du document source. |
| Excel | Plage multicolonne, texte et gras restitués. Perte fonctionnelle des formules sur rejeu historique reproduite et protégée comme décrit ci-dessous. |
| Retour automatique à l’application cible | Autorisation d’envoi d’événements absente pendant l’essai : message de récupération manuelle vérifié. Aucun droit macOS accordé par l’agent. |
| Lancement à la connexion existant | Ancienne installation relevée désactivée ; aucune activation ou inscription automatique effectuée pendant la migration. |
| Installation finale | `/Applications/One Clipboard History.app` validée et ouverte ; À propos affiche 0.7.0 (7), MIT et GitHub. L’ancien `mcm.app` est déplacé dans `build/Legacy/`, sans supprimer préférences ni données. La variante Store de test a été retirée d’Applications. |

Les commandes clavier dirigées par le pilote UI ne constituent pas une preuve
du raccourci global sur un clavier physique. Les tests Carbon vérifient le
routage et les conflits ; la recette physique demeure distincte. De même,
l’inspection de l’arbre d’accessibilité ne remplace pas un parcours VoiceOver.

## Cas Excel reproduit

Une plage synthétique contenant deux formules a été copiée depuis Excel par sa
commande native. Le collage direct conserve les formules relatives. Après
restauration de l’historique, Excel peut insérer leurs valeurs calculées.

La comparaison porte sur **18 types canoniques**, leurs tailles, leur ordre,
leurs empreintes SHA-256 et les alias du presse-papiers : ils sont identiques
avant et après restitution. Le conteneur `com.microsoft.Embed-Source` contient
bien un paquet OOXML avec **deux éléments de formule**. Aucune donnée de formule
n’a donc été supprimée lors de la capture.

Deux expériences sur cette seule fixture n’ont pas corrigé le comportement :
publication différée à la manière de Quicksilver, et retrait expérimental du seul
marqueur de propriétaire OLE. Ces expériences restent dans le dossier de build,
hors du logiciel livré ; aucun format n’est supprimé en production.

Le logiciel applique les protections suivantes :

1. Une copie encore identique au presse-papiers courant conserve son propriétaire
   et son contexte : aucune réécriture n’est nécessaire.
2. La signature Excel observée est signalée dans le commentaire de l’entrée.
3. Si une reconstitution est nécessaire, une confirmation explique que les
   formules peuvent devenir des valeurs ; **Annuler est le choix par défaut**.
4. Un changement de presse-papiers entre préflight et écriture est revérifié ;
   le refus conserve le presse-papiers existant. Une restauration autorisée
   restitue tous les types et octets originaux.

L’égalité des octets n’établit pas que le contexte privé vivant de l’application
source peut être reconstruit. La fidélité de toute copie Excel historique, de ses
cellules fusionnées, bordures, liens et formats complexes reste à qualifier.

## Réactivité

Commande :

```sh
OCH_RUN_BENCHMARKS=1 swift test --filter OpeningPerformanceTests
```

Mesure locale : 10 ouvertures de chauffe, puis 100 ouvertures avec 20 entrées
texte préchargées, police 12 points, vue compacte et animations désactivées.

| Mesure | Millisecondes |
| --- | ---: |
| p50 | 4,400 |
| p95 | 7,210 |
| Maximum | 7,730 |

Cette mesure couvre l’ouverture, la mise en page et la soumission d’affichage
AppKit. Elle ne mesure pas le premier cadre complet effectivement présenté par
le compositeur, ni le collage dans une application tierce. L’objectif de 50 ms
pour cet affichage complet reste à vérifier. **Aucun plafond CPU n’est imposé.**

Après fermeture des fenêtres d’information, un relevé ponctuel de l’application
installée donne **0,0 % CPU** et **126 960 Kio RSS** (environ 124 Mio), après
43 secondes d’exécution. Ce point de mesure au repos n’est ni une moyenne ni
une limite de consommation, et ne caractérise pas le traitement d’images lourdes.

## Livraison GitHub

Les sources et leur historique sont publiés sur la branche `main` du
[dépôt public](https://github.com/armateurlabs/one-clipboard-history).
Les trois captures sont de véritables fichiers PNG, issus de l’application
d’aperçu avec données synthétiques.

Le ZIP `one-clipboard-history-0.7.0-macos-arm64.zip` contient le bundle direct
arm64, sa licence, ses traductions et sa politique de confidentialité. Une
extraction neuve a été validée avec `scripts/validate-app.sh`. Il utilise une
signature ad hoc, sans notarisation, et est livré comme préversion de validation.

SHA-256 du ZIP :

```text
10dc8e7234db2ac3031b6818e2fa358ea7564f01e5aa86e5d59ea7ac13d992f2
```

## Préalables et recette restante

- Signature Developer ID, notarisation et validation Gatekeeper de distribution :
  aucun certificat Apple valide installé au moment de la recette.
- Signature Apple Distribution, provisioning, export final et App Review :
  préparation fournie, aucune soumission effectuée.
- Collage automatique avec permission accordée dans Brave, TextEdit, Terminal,
  Finder, Word et Excel ; révocation des permissions et changement de focus réel.
- Word : listes, tableaux, images, champs et liens ; fermeture complète de Word
  et redémarrage avec persistance. Le contrôle simple du gras ne reçoit pas ces cas.
- Excel : fidélité fonctionnelle historique complète malgré les formats privés ;
  conserver l’avertissement tant que le cas reproduit n’est pas résolu.
- Fichiers externes et bookmarks après relancement dans la distribution Store,
  avec les vraies autorisations ; les tests simulés ne prouvent pas l’acceptation
  de l’ensemble du parcours par le sandbox et App Review.
- Ouverture de session réelle, veille/réveil, plusieurs écrans, Spaces, plein
  écran et navigation VoiceOver complète, sans perturber la session de travail.

La lecture toutes les 200 ms conserve sa limite connue : une copie remplacée
entre deux lectures peut ne pas être capturée.
