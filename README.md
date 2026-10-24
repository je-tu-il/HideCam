# 📹 StealthRecorder (HideCam) — Enregistreur Vidéo Furtif pour iOS

[![Release](https://img.shields.io/github/v/release/je-tu-il/HideCam?color=black&label=Version)](https://github.com/je-tu-il/HideCam/releases/latest)
[![Build iOS](https://github.com/je-tu-il/HideCam/actions/workflows/build.yml/badge.svg)](https://github.com/je-tu-il/HideCam/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform: iOS](https://img.shields.io/badge/Plateforme-iPhone%20%7C%20iPad-black.svg)](https://github.com/je-tu-il/HideCam/releases/latest)

> **StealthRecorder** est une application iOS discrète et sécurisée permettant d'enregistrer des vidéos en toute confidentialité grâce à un écran de camouflage interactif (mini-jeu 2048 ou faux écran de veille) et un coffre-fort de vidéos chiffré.

---

## 📲 Téléchargement Direct & Installation

Retrouvez le binaire sur la page [**Releases GitHub**](https://github.com/je-tu-il/HideCam/releases/latest) :

1. Téléchargez le fichier **`StealthRecorder.ipa`**.
2. Installez-le avec votre outil de sideloading préféré :
   - 🍏 **AltStore / SideStore** : Onglet *My Apps* > bouton `+` > sélectionnez `StealthRecorder.ipa`.
   - 💻 **Sideloadly** : Glissez `StealthRecorder.ipa` et lancez l'installation en USB.
   - ⚡ **TrollStore** : Installation directe sans signature requise.

---

## ✨ Fonctionnalités Clés

- 🎮 **Camouflage 2048 Fonctionnel** : Un véritable jeu 2048 s'affiche à l'écran pendant que la caméra enregistre discrètement en arrière-plan.
- 🖤 **Mode Écran Noir Total** : Simule un smartphone verrouillé/éteint avec un geste secret (double tap / swipe) pour stopper l'enregistrement.
- 🔒 **Galerie Coffre-Fort Sécurisée** : Les vidéos enregistrées ne sont pas ajoutées à la pellicule publique d'Apple Photos mais conservées dans le conteneur privé de l'application.
- ⚙️ **Paramètres Avancés** :
  - Choix de la caméra (avant / arrière).
  - Résolution réglable (720p, 1080p, 4K) et fréquence d'images (30/60 fps).
  - Indicateur discret personnalisable (haptique ou LED d'alerte facultative).

---

## 🛠️ Stack Technique

- **Langage** : Swift / SwiftUI
- **Frameworks** : AVFoundation, CoreMedia, PhotosUI
- **Cible** : iOS 17.0+
- **CI/CD** : GitHub Actions (compilation Release IPA sous macOS)

---

## 📄 Licence

Distribué sous licence **MIT**. Voir le fichier [LICENSE](LICENSE) pour plus de détails.
