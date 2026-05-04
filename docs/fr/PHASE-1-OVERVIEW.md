# smolBSD — Phase I : Vue d'ensemble

> **Traduction automatique** — résumé synthétique des documents sources :
> - `plans/tinyos/PHASE-1-FORGE-TINY-BASELINE.md`
> - `plans/tinyos/PHASE-1-AARCH64-TINY-BASELINE.md`
> - `plans/tinyos/PHASE-1-ARCH-DECISION.md`

---

## 1. Mission

smolBSD vise à construire la plus petite VM FreeBSD 15 stable qui démarre
sans intervention jusqu'à l'invite de connexion, exécute `sh`, `vi`/`ed`,
`rc.d` et `pkg`, utilise UFS, et tient dans 512 Mio sur disque. La cible
aspirationnelle est un artefact qcow2 inférieur à 128 Mio.

Le projet produit deux variantes architecturales dans la même Phase I :
une image aarch64 (bras principal) et une image amd64 (bras secondaire),
toutes deux construites à partir du même outillage FreeBSD officiel
`release/Makefile.vm`.

---

## 2. Décision architecturale : aarch64 en premier, les deux branches

La décision est consignée dans `PHASE-1-ARCH-DECISION.md` (option C).

**Raison principale — asymétrie HVF.** Sur l'hôte de build `minim4-24`
(Apple Silicon), l'accélérateur matériel HVF ne fonctionne qu'avec l'ISA
native — aarch64. Une VM aarch64 sous HVF démarre en 10–30 s et passe
aisément la porte d'acceptation ≤ 30 s. Une VM amd64 sous TCG (émulation
logicielle) prendrait 60–180 s et échouerait à la même porte sur le même
hôte. Construire une image dont les portes d'acceptation échouent sur
l'hôte de build lui-même est inacceptable.

**Raisons complémentaires.** La totalité du parc matériel existant est en
aarch64 (nœuds fbrpi, Pi 5, RK3588, VM fbuild). Les chaînes d'outils
(`freebsd-build-vm`, `zig-cc`, `freebsd-pi`) visent toutes aarch64. Une
image amd64 isolée dans ce parc n'a pas d'autre consommateur pour partager
le coût de débogage.

**La branche amd64 n'est pas abandonnée.** Elle se construit par
compilation croisée depuis fbuild (`TARGET=amd64 TARGET_ARCH=amd64`) et
est testée sur un hôte x86 KVM (instance Vultr ou machine Linux x86 de la
flotte). Le plan de base existant est réutilisé tel quel.

---

## 3. Sélection des paquets et budget de taille

Les deux variantes partagent exactement le même ensemble de paquets
(les noms pkgbase sont indépendants de l'ISA).

**Socle minimal** (depuis `release/tools/oci-image-runtime.conf`) :
`FreeBSD-runtime`, `FreeBSD-rc`, `FreeBSD-fetch`, `FreeBSD-certctl`,
`FreeBSD-kerberos-lib`, `FreeBSD-libarchive`, `FreeBSD-libexecinfo`,
`FreeBSD-libucl`, `FreeBSD-pkg-bootstrap`, `FreeBSD-mtree`.

**Ajouts spécifiques à smolBSD** : `FreeBSD-kernel-generic` (remplacé par
le noyau SMOLBSD compilé sur mesure), `FreeBSD-utilities`, `FreeBSD-clibs`,
`FreeBSD-openssl-lib`, `FreeBSD-ee`.

**Exclusions explicites** (via `vm_extra_filter_base_packages()`) :
tous les paquets `-dbg`, `-lib32`, `FreeBSD-tests*`, `FreeBSD-lldb*`,
`FreeBSD-devel*`, `FreeBSD-src*`.

**Budget de taille par couche :**

| Couche | Budget |
|--------|--------|
| Noyau binaire (`/boot/kernel/kernel`, sans -dbg) | 19–20 Mio |
| Modules noyau (`/boot/kernel/*.ko`, ensemble minimal) | 7–8 Mio |
| Espace utilisateur de base (`FreeBSD-runtime` + `FreeBSD-clibs`) | 35 Mio |
| Utilitaires (`FreeBSD-utilities`) | 48 Mio |
| Framework rc.d (`FreeBSD-rc`) | 3 Mio |
| Runtime pkg (libarchive + openssl-lib + libucl + fetch + pkg-bootstrap) | 18 Mio |
| Paquets auxiliaires (certctl, kerberos-lib, libexecinfo, mtree, ee) | 6 Mio |
| Chargeur `/boot` + fichiers EFI | 5 Mio |
| `/etc` par défaut + squelette `/var` + `/tmp` | 2 Mio |
| **Total sur disque** | **~143–145 Mio** |
| **Artefact qcow2** (allocation sparse) | **~128 Mio** |
| **Plafond absolu** | **512 Mio** |

---

## 4. Portes d'acceptation — les cinq reliques mesurées

Chaque variante doit passer cinq mesures avant validation de Phase I :

1. **Taux de succès de construction** — le fichier qcow2 existe et
   `qemu-img info` renvoie les champs attendus.
2. **Temps jusqu'à l'état prêt** — la VM affiche l'invite `login:` en
   ≤ 30 s (HVF pour aarch64 ; KVM sur hôte x86 pour amd64).
3. **Mémoire au pic** — RSS hôte < 300 Mio ; mémoire libre en VM
   ≥ 150 Mio dans une VM de 256 Mio.
4. **Mémoire au repos** — même seuils, mesurés à t+60 s.
5. **Taille de l'artefact** — `actual-size` < 134 217 728 octets
   (128 Mio aspirationnel) ; < 536 870 912 octets (512 Mio, plafond dur).
6. **Temps de récupération après crash** — redémarrage de la VM après
   `kill -9` et SSH disponible en ≤ 60 s (chemin fsck UFS soft-updates).

---

## 5. État actuel

- **Phase I aarch64** : conception complète (`PHASE-1-AARCH64-TINY-BASELINE.md`
  statut `design-complete`). Build natif dans fbuild sans compilation
  croisée. Test sur `minim4-24` avec HVF. Cette branche est la priorité.
- **Phase I amd64** : conception complète (`PHASE-1-FORGE-TINY-BASELINE.md`
  statut `design-complete`). Compilation croisée depuis fbuild
  (`TARGET=amd64 TARGET_ARCH=amd64`). En attente d'un hôte de test
  KVM x86.

Aucune commande de build n'a encore été exécutée — les deux documents
sont en phase de conception uniquement.

---

*Résumé produit le 2026-05-04 à partir des documents de planification smolBSD Phase I.*
