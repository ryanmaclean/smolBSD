# Phase I — Référence Minimale aarch64 : FreeBSD 15 arm64 VM Minimale

- **Phase** : I sur IV — Forge de la Référence Minimale (branche aarch64 ; PRIMAIRE selon REPLAN)
- **Campagne** : smolBSD — Le Petit Royaume contre la Citadelle Rump
- **Cible** : FreeBSD 15.0-RELEASE arm64, VM d'abord, sans interface graphique
- **Rédigé par** : planner@smolbsd.local (task-0005)
- **Date** : 2026-04-30
- **Statut** : conception terminée — NE PAS COMPILER avant acceptation de ce fichier
- **Décision REPLAN** : `plans/tinyos/PHASE-1-ARCH-DECISION.md` — Option C, aarch64 en premier

---

## 1. Énoncé de mission

Construire la plus petite VM QEMU FreeBSD 15 arm64 stable qui démarre sans
intervention jusqu'à l'invite de connexion en **≤ 30 secondes** (accélérée par
HVF sur `minim4-24`), exécute sh, vi/ed, rc.d et pkg, utilise UFS, et tient
dans 512 Mio sur disque (objectif aspirationnel : artefact qcow2 < 128 Mio).

**Il s'agit de la branche principale de la Phase I.** L'accélérateur HVF sur
Apple Silicon (`minim4-24`) est natif à l'ISA uniquement : un invité aarch64
sous HVF s'exécute à une vitesse proche du bare-metal, tandis qu'un invité amd64
bascule sur TCG (émulation logicielle, 5 à 10 fois plus lent). La porte
d'acceptation de ≤ 30 secondes avant connexion ne peut être franchie sur l'hôte
de compilation qu'avec une image aarch64 ; la branche amd64 nécessite un hôte
x86 compatible KVM pour sa porte de mesure temporelle.

Ce fichier définit le contrat de compilation. Aucune commande de compilation
n'est exécutée ici.

---

## 2. Hôte de compilation et mode de compilation

### 2.1 Hôte de compilation : `fbuild` (FreeBSD 15 aarch64 sur `minim4-24`)

La VM fbuild est FreeBSD 15.0-RELEASE **aarch64** — la même ISA que la cible.
Cela signifie **qu'aucune compilation croisée n'est nécessaire** : le système de
compilation utilise sa chaîne d'outils native de bout en bout.

**Notes opérationnelles de fbuild** (voir §18 de la spécification de conception pour les détails complets) :

- Le nom canonique de skill `fb-vm-24` est obsolète — le nom réel de la VM est `fbuild`.
- Port SSH : `ssh -J minim4-24 -p 2222 builder@localhost` (pas le 2225 obsolète du skill).
- Partage virtfs côté hôte : `/Users/studio/Users/studio/share/fbuild/` (bogue de préfixe doublé, documenté séparément).
- Risque de perte de socket screen : `pgrep qemu` et `screen -ls` peuvent diverger ; voir §18.4 de la spécification pour la récupération.

### 2.2 Mode de compilation : arm64 natif — sans compilation croisée

Sur un hôte arm64 compilant pour arm64, `TARGET` et `TARGET_ARCH` peuvent être
omis ou déclarés explicitement (les deux sont équivalents) :

```sh
# Compilation native (recommandée — plus simple, moins de modes d'échec) :
make -j4 -C /usr/src buildworld buildkernel KERNCONF=SMOLBSD

# Ou avec l'architecture explicite (résultat identique sur hôte arm64) :
make -j4 -C /usr/src buildworld buildkernel \
    KERNCONF=SMOLBSD \
    TARGET=arm64 \
    TARGET_ARCH=aarch64
```

À comparer avec la branche amd64, qui doit être compilée en croisé depuis l'hôte
fbuild arm64 en utilisant `TARGET=amd64 TARGET_ARCH=amd64`. Le chemin natif
supprime l'étape de la chaîne d'outils croisée, réduisant le temps de
compilation et les modes d'échec.
