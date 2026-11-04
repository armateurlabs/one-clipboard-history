# Préparation Mac App Store

[English](APP_STORE.en.md) · [Projet](../README.md) · [Confidentialité](../PRIVACY.md)

## Deux distributions, un cœur commun

La distribution GitHub conserve toutes les fonctions et l’identité historique
`com.arthur.mcm`. La cible **OneClipboardHistory Store**, dans
`OneClipboardHistory.xcodeproj`, utilise `com.armateurlabs.oneclipboardhistory`
et un conteneur sandbox distinct. Ses sources partagent le même cœur Swift.

Le sandbox est obligatoire pour le Mac App Store. Le collage automatique doit
être éprouvé dans cette cible avec les autorisations réelles : une compilation
sandboxée ne prouve ni le collage dans une autre app ni l’acceptation par Apple.
La version GitHub ne perd aucune fonction si une restriction Store est constatée.

Références Apple : [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox),
[règles de validation](https://developer.apple.com/app-store/review/guidelines/),
[accès aux fichiers](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox),
[envoi d’événements](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess()).

## Compiler et archiver

```sh
# Prototype sandboxé signé localement, sans compte de distribution.
./scripts/archive-store.sh --unsigned

# Archive pour distribution, avec une équipe et les certificats configurés.
OCH_DEVELOPMENT_TEAM=YOURTEAMID ./scripts/archive-store.sh
OCH_DEVELOPMENT_TEAM=YOURTEAMID ./scripts/export-store.sh
```

L’archive est produite dans `build/One Clipboard History Store.xcarchive`.
La signature locale du prototype n’équivaut pas à une signature Apple
Distribution. Aucun de ces scripts ne soumet l’application à l’App Store.
Le bundle ID doit être réservé dans l’équipe Apple avant le premier upload.

## Vérifications de faisabilité

Les résultats exécutés sont consignés dans [VALIDATION.md](VALIDATION.md).
Les vérifications suivantes doivent être faites dans le bundle sandboxé :

- ⌥A global, ouverture/masquage immédiats, capture texte/HTML/RTF/images et
  sélection par chiffre, sans capture clavier générale.
- Autorisation d’envoi d’événements demandée sur action explicite ; collage
  dans TextEdit, Brave, Terminal, Finder, Word et Excel. En cas de refus,
  recopie conservée et récupération manuelle par ⌘V.
- Capture de références de fichiers, miniatures, restitution dans Finder et
  accès après redémarrage via bookmarks de sécurité. Distinguer fichier absent
  et accès non autorisé ; ne pas transformer silencieusement les formats.
- Lancement à la connexion consenti et silencieux ; aucun enregistrement
  automatique pour contourner un choix désactivé dans macOS.
- Persistance, import, suppression et erreurs, sous les droits minimaux.

Le logiciel ne tente pas d’inspecter les champs d’une autre application pour
annoncer que son collage a été accepté. La restauration des octets et le
traitement du raccourci par la destination sont deux vérifications distinctes.

La recette réelle a identifié un cas Excel où les formats, leur ordre et leurs
empreintes sont identiques après restauration, mais les formules deviennent des
valeurs. La copie courante inchangée conserve son propriétaire ; une copie
historique reconnue comme dépendante du contexte Excel exige une confirmation
avant tout changement du presse-papiers. Cette limitation doit rester visible
dans la fiche et les notes de validation jusqu’à sa résolution.

### Import des premières versions

La variante Store propose de sélectionner explicitement un ancien dossier
**History** dans les réglages. Le panneau natif accorde l’accès à ce dossier.
L’import vérifie les données avant de fusionner les entrées, sans modifier la
source ni effacer silencieusement des copies existantes. Les formats et octets
restent intacts. Les anciens chemins de fichiers peuvent nécessiter une
nouvelle autorisation d’accès ; importer leurs octets ne crée pas ce droit.
Les préférences de la variante Store sont distinctes de la distribution directe.

## Fiche App Store proposée

| Champ | Français |
| --- | --- |
| Nom | One Clipboard History |
| Sous-titre | Vos copies, à portée de clavier |
| Catégorie | Productivité |
| Description courte | Retrouvez et réutilisez vos copies avec une palette native et rapide. |
| Support | https://github.com/armateurlabs/one-clipboard-history/issues |
| Confidentialité | https://github.com/armateurlabs/one-clipboard-history/blob/main/PRIVACY.md |
| Copyright | 2026 Armateur Labs |

**Description** : One Clipboard History garde vos copies sur votre Mac.
Affichez l’historique avec un raccourci, choisissez une entrée et retrouvez son
texte, ses mises en forme, ses images ou ses références de fichiers. Réglez la
police, la densité, la position près du pointeur et l’apparence claire ou sombre.
L’historique commence à 20 entrées ; sa conservation entre sessions est
facultative. Aucun compte, publicité, télémétrie ou synchronisation réseau.

Ne publier une promesse de collage automatique ou de fidélité Office que pour
les parcours effectivement validés dans la variante Store. Les captures de
soumission doivent montrer ce bundle réel, pas la distribution GitHub si son
comportement diffère.

## Notes pour App Review

- Aucun compte ou serveur nécessaire. L’app reste dans la barre de menus ;
  ⌥A affiche l’historique. Son engrenage et le menu donnent accès aux réglages.
- L’accès au presse-papiers est la fonction principale. L’accès d’envoi
  d’événements sert uniquement au collage demandé par un chiffre, Entrée ou
  double-clic. Le refus conserve un parcours manuel par ⌘V.
- Persistance et lancement à la connexion sont désactivés initialement.
- Les données copiées restent sur l’appareil. Les liens GitHub ne s’ouvrent que
  sur action de l’utilisateur. Politique accessible dans À propos.
- Fournir des exemples synthétiques de texte enrichi, Python, image et fichiers
  pour la recette. Aucun accès complet au disque ou surveillance clavier
  générale n’est demandé.

## Signature et statut de publication

Le 4 novembre 2026, aucun certificat Apple valide n’était installé sur le Mac de
développement. Préparer la configuration et tester un bundle ad hoc ne valide
pas une archive de distribution. Il reste nécessaire de configurer l’équipe,
Apple Distribution, le provisioning et la fiche App Store Connect, puis de
valider/exporter avec Xcode. La soumission et la décision d’App Review restent
des étapes ultérieures.

Pour la distribution externe, utiliser Developer ID et la notarisation :

```sh
OCH_SIGN_IDENTITY='Developer ID Application: …' ./scripts/build-app.sh
OCH_NOTARY_PROFILE=your-keychain-profile ./scripts/notarize-app.sh 'build/One Clipboard History.app'
```

La notarisation effectue un envoi à Apple uniquement quand cette commande est
exécutée explicitement. Ne jamais placer de certificat, clé ou jeton dans Git.
