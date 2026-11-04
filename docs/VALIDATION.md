# Validation de One Clipboard History 0.8.0 — 4 novembre 2026

Version **0.8.0 (8)**, macOS 27 sur Apple Silicon. Cette mise à jour ajoute les
trois modes de densité et conserve les données du presse-papiers sans changement.
Les contrôles de formats, sandbox, import, permissions et limites Office de la
version précédente restent documentés dans [VALIDATION-0.7.md](VALIDATION-0.7.md).

## Contrôles exécutés

`swift test` : **137 tests réussis**, dont **78 Core** et **59 AppKit/réglages**.

Les contrôles de densité vérifient :

- Compact par défaut pour une nouvelle installation ; migration de l’ancienne
  préférence compacte vers Normal, et de l’ancienne vue espacée vers Large.
- Persistance des trois choix, repli sûr d’une valeur invalide, notifications
  de réglages et conservation des préférences de police, aperçu et taille.
- Une ligne en Compact avec taille facultative, aucun aperçu ni icône ; bloc
  du numéro de même hauteur que le texte pour les polices de 10 à 28 points.
- Métadonnées conservées dans le tooltip et le libellé d’accessibilité.
- Normal et Large conservant la taille des polices et des images d’aperçu.
- Cellules réutilisées après plusieurs changements de mode, retour des aperçus
  et métadonnées, sélection conservée et collage par Entrée sur le même élément.

Dans l’application d’aperçu réelle, les changements Compact → Normal → Large →
Compact ont été effectués avec les huit entrées synthétiques : images et icônes
absentes en Compact, rétablies dans les autres modes. Le sélecteur affiche les
trois choix ; l’option d’aperçu est désactivée en Compact sans effacer sa valeur.
La capture `docs/screenshots/settings.png` montre les nouveaux réglages réels,
sans contenu personnel. Les deux captures d’historique existantes montrent le
mode désormais nommé Normal.

Le mode Compact évite aussi de générer les miniatures en arrière-plan. Le cache
et les tâches d’enrichissement sont invalidés lorsque leur nécessité change.
Les octets originaux et les alertes de capture incomplète ou de contexte Excel
ne sont pas modifiés par le choix d’affichage.

## Compilation et livraison

Le bundle release et l’aperçu sont compilés et vérifiés par
`scripts/validate-app.sh`. La CI [macOS 27 / Apple Silicon](https://github.com/armateurlabs/one-clipboard-history/actions/workflows/ci.yml)
exécute les tests, la compilation release et l’archivage de la cible sandboxée.
Les résultats datés sont disponibles dans ses exécutions.

Le bundle direct est installé dans `/Applications/One Clipboard History.app`.
Il conserve `com.arthur.mcm`, les préférences et l’emplacement des sauvegardes.
La copie précédente est archivée localement sous `build/InstallBackups/`.
Le ZIP de préversion utilise une signature ad hoc ; les préalables de signature
Apple et de notarisation demeurent inchangés.

## Limites et recettes restantes

Les scénarios restant à qualifier dans [la recette 0.7.0](VALIDATION-0.7.md)
restent ouverts : permissions accordées et focus physique, raccourci global sur
clavier réel, VoiceOver complet, Office complexe, ouverture de session,
veille/réveil, écrans et Spaces. La dépendance de certaines formules Excel à
leur contexte source reste protégée par un avertissement.

La mesure d’ouverture précédente concerne le mode désormais nommé Normal ; le
benchmark optionnel le sélectionne explicitement pour conserver sa comparabilité.
Aucun nouveau résultat temporel ni plafond CPU n’est introduit dans cette version.
