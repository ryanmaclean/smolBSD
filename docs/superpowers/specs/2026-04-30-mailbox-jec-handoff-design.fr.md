# Protocole de Transfert Mailbox + JEC — Spécification de Conception v1.2

- **Date** : 2026-04-30
- **Projet** : smolBSD
- **Statut** : v1.2 — réconciliation fb-vm-24/<aarch64-builder>, port 2222, problème de socket screen, mise en garde contexte réseau .local
- **Licence** : BSD-2-Clause (défaut du projet)
- **Historique** : v1 (2026-04-30 13:30 — sections ouvertes différées) ; v1.1 (2026-04-30 14:30 — réponses des agents collectées et intégrées) ; v1.2 (2026-04-30 15:00 — réconciliation fb-vm-24/<aarch64-builder>, port 2222, problème de socket screen, mise en garde contexte réseau .local)

## 1. Objet

Démontrer que **l'état du projet peut être transféré entre des équipes d'agents
Claude Opus 4.7 (contexte 1M)** sans historique de conversation partagé, en
utilisant uniquement :

- un seul fichier de boîte aux lettres BSD comme substrat d'échange, et
- des dépôts Just-Enough-Context (JEC) compressés via RTK et d'autres techniques
  d'ingénierie de contexte.

La première charge de travail de test est **smolBSD** lui-même (chemin TinyOS
selon `plans/tinyos/TINY_OS_VS_RUMPOS_BSD_PLAN.md`). Une fois le protocole
validé sur le prototype, le substrat migre vers une vraie instance (Tiny|Rump)BSD
où `/var/mail/<agent>` est le canal de transfert littéral. Les deux moitiés de
l'expérience convergent là.

## 2. Substrat

- **Format** : mbox (RFC822 + séparateur `From `). Le corps est `Content-Type: text/toml; charset=utf-8`.
- **Topologie** : spool partagé unique, adressé par l'en-tête `To:`. Un seul fichier == état complet du système.
- **Chemin** : `/Users/studio/smolBSD/var/mail/spool` (miroir de `/var/mail/` ; dans l'arbre source afin que le spool lui-même devienne partie de l'état du projet qui survit à un clone frais — c'est tout le point).
- **Concurrence** : seul le coordinateur ajoute des messages. Les sous-agents lisent en filtrant par `To:` et **émettent** des réponses en ajoutant au fichier. Le coordinateur collecte à son prochain cycle. Aucun verrouillage requis à ce stade ; nous reviendrons dessus lorsque plusieurs rédacteurs apparaîtront.
- **Fil de discussion** : `Message-ID` + `In-Reply-To`, exactement comme dans le courrier classique. Les réponses vont toujours `To: coordinator@smolbsd.local`.

## 3. Convention d'adressage

```
<rôle>@smolbsd.local        # adresse virtuelle basée sur le rôle, résolue par le coordinateur
coordinator@smolbsd.local   # boîte de réception de l'orchestrateur
architect@smolbsd.local
builder@smolbsd.local
reviewer@smolbsd.local
researcher@smolbsd.local
```

Dans la phase prototype, les « adresses » sont virtuelles — le coordinateur
distribue un sous-agent Claude Code et lui indique quel `Message-ID` lire.
Lorsque nous migrerons vers une vraie instance BSD, chaque adresse obtiendra
une vraie entrée `passwd(5)` et un vrai `/var/mail/<rôle>`.

## 4. Format d'enveloppe (mbox + corps TOML)

### 4.1 Requête (coordinateur → agent)

```
From smolbsd-coord Tue Apr 30 12:50:00 2026
From: coordinator@smolbsd.local
To: architect@smolbsd.local
Subject: [task-0001] Forge Tiny Baseline — bootstrap FreeBSD amd64 VM
Date: Tue, 30 Apr 2026 12:50:00 -0000
Message-ID: <task-0001.coord@smolbsd.local>
X-Project: smolbsd
X-Phase: tinyos/forge-tiny-baseline
X-JEC-Compression: rtk-v1
Content-Type: text/toml; charset=utf-8

task_id     = "task-0001"
title       = "Bootstrap FreeBSD 15 amd64 VM with smallest stable footprint"
deadline    = "2026-05-14"

[brief]                       # JEC : prose, limite souple 200 mots
summary = """..."""

[context_pointers]            # JEC : chemins/shas/msgids — PAS intégrés
read         = ["docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md", ...]
prior_msgids = []

[acceptance]                  # binaire, testable
must_pass = ["VM boots to login prompt unattended", ...]

[reply_contract]
output_to            = "coordinator@smolbsd.local"
output_format        = "mbox+toml-v1"
attestation_required = true
skills_recommended   = ["freebsd", "qemu-fleet", "freebsd-build-vm"]
tools_required       = ["Read", "Write", "Edit", "Bash"]
tools_allowed        = ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]
budget_tokens        = 80000
```
