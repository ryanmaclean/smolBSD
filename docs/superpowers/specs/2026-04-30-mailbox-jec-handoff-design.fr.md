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
- **Fil de discussion** : `Message-ID` + `In-Reply-To`, exactement comme dans le courrier classique. Les réponses vont toujours `To: coordinator@smolfire.local`.

## 3. Convention d'adressage

```
<rôle>@smolfire.local        # adresse virtuelle basée sur le rôle, résolue par le coordinateur
coordinator@smolfire.local   # boîte de réception de l'orchestrateur
architect@smolfire.local
builder@smolfire.local
reviewer@smolfire.local
researcher@smolfire.local
```

Dans la phase prototype, les « adresses » sont virtuelles — le coordinateur
distribue un sous-agent Claude Code et lui indique quel `Message-ID` lire.
Lorsque nous migrerons vers une vraie instance BSD, chaque adresse obtiendra
une vraie entrée `passwd(5)` et un vrai `/var/mail/<rôle>`.

## 4. Format d'enveloppe (mbox + corps TOML)

### 4.1 Requête (coordinateur → agent)

```
From smolbsd-coord Tue Apr 30 12:50:00 2026
From: coordinator@smolfire.local
To: architect@smolfire.local
Subject: [task-0001] Forge Tiny Baseline — bootstrap FreeBSD amd64 VM
Date: Tue, 30 Apr 2026 12:50:00 -0000
Message-ID: <task-0001.coord@smolfire.local>
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
output_to            = "coordinator@smolfire.local"
output_format        = "mbox+toml-v1"
attestation_required = true
skills_recommended   = ["freebsd", "qemu-fleet", "freebsd-build-vm"]
tools_required       = ["Read", "Write", "Edit", "Bash"]   # §17 : le coord refuse la distribution si le type de sous-agent ne dispose pas de l'un de ces outils
tools_allowed        = ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]
budget_tokens        = 80000
```

### 4.2 Réponse (agent → coordinateur)

```
From smolbsd-architect Tue Apr 30 14:10:00 2026
From: architect@smolfire.local
To: coordinator@smolfire.local
Subject: Re: [task-0001] Forge Tiny Baseline — bootstrap FreeBSD amd64 VM
Date: Tue, 30 Apr 2026 14:10:00 -0000
Message-ID: <task-0001.architect@smolfire.local>
In-Reply-To: <task-0001.coord@smolfire.local>
References: <task-0001.coord@smolfire.local>
X-Project: smolbsd
X-Verdict: pass
Content-Type: text/toml; charset=utf-8

task_id = "task-0001"
verdict = "pass"             # pass | fail | blocked

[[claims]]                   # requis lorsque reply_contract.attestation_required
subject  = "VM boots to login prompt"
expected = "login: prompt within 30s"
probe    = "expect(1) script timed boot"
evidence = "logs/task-0001/boot.log:line 412"
verdict  = "pass"

[[artifacts]]
path = "build/freebsd-15-amd64-tiny.qcow2"
sha  = "sha256:..."
size = "487 MiB"
git  = "abc1234"

next_recommended = ["task-0002: shrink to <256 MiB"]
```

## 5. Profil JEC — `rtk-v1`

`X-JEC-Compression: rtk-v1` déclare le contrat de compression du message. Deux couches :

### 5.1 Sortant (côté coordinateur)

Lorsque le coordinateur intègre quoi que ce soit dans `[brief]` ou développe un
`context_pointer` en ligne (rare ; les pointeurs sont préférés), le contenu est
prétraité via RTK :

| Source                  | Commande RTK           | Objectif de réduction |
|-------------------------|------------------------|------------------|
| `git status`/`diff`/`log` | `rtk git ...`          | -75 % à -92 %     |
| Extrait de fichier      | `rtk read -l aggressive` | -70 % (signatures uniquement) |
| Sortie de test/build    | `rtk test <cmd>`       | -90 %             |
| Sortie de lint          | `rtk lint`/`rtk tsc`   | -80 %             |
| Listage de répertoire   | `rtk ls`/`rtk find`    | -80 %             |

Stratégies (selon la doc RTK) : filtrage intelligent · regroupement · troncature · déduplication.

### 5.2 Entrant (côté agent)

Les agents ayant RTK installé et `rtk init -g` exécuté obtiennent le hook Bash
automatiquement. Leurs propres appels `Read`/`Grep`/`Bash` développant les
`context_pointers` sont filtrés de la même manière. **Le protocole n'exige pas
RTK côté agent** — il se dégrade gracieusement vers la sortie brute si RTK est
absent. L'en-tête `X-JEC-Compression` signale une capacité, pas une exigence.

## 6. Boucle de distribution

```
┌──────────────┐  1. écrit la requête mbox  ┌──────────────────┐
│ coordinateur │ ────────────────────────► │ var/mail/spool   │
└──────────────┘                            └──────────────────┘
       │                                            │
       │ 2. lance le sous-agent                     │
       │    "ton msgid est <task-XXX.coord@..>"     │
       ▼                                            │
┌─────────────┐  3. lit + analyse                  │
│  sous-agent │ ◄─────────────────────────────────┘
│  (à froid)  │
│             │  4. effectue le travail
│             │     (Read, Bash via RTK, Edit, ...)
│             │
│             │  5. ajoute une réponse mbox adressée
│             │     To: coordinator@smolfire.local  ┌──────────────────┐
│             │ ────────────────────────────────► │ var/mail/spool   │
└─────────────┘                                    └──────────────────┘
       │ 6. l'agent se termine                             │
       ▼                                                   │
┌──────────────┐  7. collecte les réponses                 │
│ coordinateur │ ◄────────────────────────────────────────┘
└──────────────┘
```

Le coordinateur peut écrire N requêtes en un seul lot et lancer N sous-agents
en parallèle. Chaque sous-agent ne lit que son propre message (filtré par le
`Message-ID` qu'on lui a indiqué). Les sorties sont en ajout seul (append-only)
et naturellement sérialisées par la structure mbox du spool.

## 7. Vérification — réflexe fleet-eval

Selon `~/.claude/CLAUDE.md`, toute réponse avec `verdict = "pass"` et
`attestation_required = true` DOIT contenir au moins un bloc `[[claims]]`. Le
coordinateur effectue une contre-vérification avec `fleet-eval verify` avant de
faire confiance à la réponse. Les réponses non fiables déclenchent un nouvel
essai (politique à définir par D2).

## 8. Rôles et affectations d'agents

| Rôle            | Adresse                       | Type de sous-agent sous-jacent     | Outils requis (écritures ?)      |
|-----------------|-------------------------------|------------------------------------|----------------------------------|
| coordinator     | `coordinator@smolfire.local`   | (cette session Opus 4.7 1M)        | Read+Write+Edit+Bash             |
| architect       | `architect@smolfire.local`     | `feature-dev:code-architect` (RO) **OU** `general-purpose` (RW) | dépend du champ `tools_required` — voir §17 |
| builder         | `builder@smolfire.local`       | `general-purpose` + skill freebsd  | Read+Write+Edit+Bash             |
| reviewer        | `reviewer@smolfire.local`      | `pr-review-toolkit:code-reviewer`  | Lecture principalement           |
| researcher      | `researcher@smolfire.local`    | `general-purpose` + Explore        | Lecture seule acceptable         |
| security        | `security@smolfire.local`      | `general-purpose` + skill redact   | Read+Bash (Write uniquement pour les enveloppes sous `var/run/secrets/`) |
| ops             | `ops@smolfire.local`           | `general-purpose` + skill fleet-irc | Read+Write+Bash                  |

## 9. État qui survit à un transfert

L'équipe d'agents réceptrice démarre à froid et acquiert l'état complet du
projet à partir de ces artefacts sur disque (aucun historique de conversation
nécessaire) :

1. `var/mail/spool` — historique complet des messages, avec fils de discussion
2. `docs/superpowers/specs/*.md` — contrats de conception (ce fichier)
3. `plans/tinyos/*.md` — plan(s) d'origine
4. `.planning/*.md` — backlog, tâches en cours
5. `jj log` — une fois smolBSD converti en dépôt jj (TODO : `jj git init`). Isolation multi-agent ultérieure via `jj workspace add` plutôt que `git worktree`.

C'est la surface AX-first de `~/.claude/CLAUDE.md` : entrées/sorties
structurées, découvrables par manifeste, porteuses d'attestations, composables
par schéma.

## 10. Sections closes — intégrées depuis les réponses des agents

| §  | Question            | Responsable | Msgid de réponse (enregistrement canonique) | Statut |
|----|---------------------|----------|------------------------------------------|--------|
| 11 | Gestion des secrets | security | `<design-d1.security@smolfire.local>` (spool L441–711) | intégré v1.1 |
| 12 | Politique de reprise | reviewer | `<design-d2.reviewer@smolfire.local>` (spool L712–1057) | intégré v1.1 |
| 13 | Canal d'escalade    | ops      | `<design-d3.ops@smolfire.local>` (spool L215–440) | intégré v1.1 |

Le contenu complet des réponses réside dans le spool. Les sections ci-dessous
sont des distillations ; en cas de conflit, la réponse du spool fait foi.

## 11. Gestion des secrets (d'après D1)

**Mécanisme** : fichiers d'enveloppe hors bande sous
`var/run/secrets/<task-id>/<key>` en mode 0600, avec un fichier compagnon
`.meta.toml` contenant l'empreinte `redact`. Le spool ne transporte qu'une
table de pointeurs `[secrets.<key>]` — jamais de valeurs. `var/run/` est dans
`.gitignore`.

**Six règles :**

1. Aucune valeur de secret, en clair ou encodée, n'apparaît jamais dans le spool. Pointeurs uniquement.
2. `var/run/` est dans `.gitignore` à la racine du dépôt. Répertoire en mode 0700, enveloppes en 0600.
3. Les noms de fichiers d'enveloppe portent le *nom de la clé*, jamais une empreinte dérivée de la valeur.
4. Les réponses attestent « j'ai lu $key » via l'empreinte `redact` (p. ex. `fc1dxxxx4439`) — prouve l'identité, sans jamais divulguer la valeur.
5. Les enveloppes sont éphémères — le coordinateur supprime (`unlink`) `var/run/secrets/<task-id>/` après la collecte, quel que soit le verdict.
6. Le magasin sous-jacent est la source de vérité ; les enveloppes sont une couche de matérialisation par tâche, pas un stockage. La rotation s'effectue dans le magasin sous-jacent.

**Table de pointeurs** (le seul contenu lié aux secrets dans le spool) :

```toml
[secrets.gitea_token]
envelope    = "var/run/secrets/task-0042/gitea_token"
fingerprint = "fc1dxxxx4439"
source      = "keychain:gitea-pat"
expires_at  = "2026-04-30T18:00:00Z"
scope       = ["gitea.local:3000/api/v1/repos/*"]   # indicatif
```

**Magasins sous-jacents (licences conformes) :**

- Phase prototype : `/usr/bin/security` (trousseau macOS, livré avec macOS) — présence vérifiée sur cet hôte.
- VM BSD cible : `gopass` (MIT, remplacement direct de `pass`). PAS `pass(1)` — GPL-2.0, interdit.
- ssh-agent pour les identifiants de type clé SSH (BSD-2 + ISC). `SSH_AUTH_SOCK` vérifié actif.
- La CLI 1Password (`op`) est mentionnée dans CLAUDE.md mais **non installée sur cet hôte** (`which op` → introuvable). La conception se dégrade gracieusement ; `op:vault/item` est un ajout d'une ligne au matérialisateur si/quand elle devient disponible.

**Invariance inter-phases** : seul le matérialisateur (étape 1 de l'exemple
détaillé) change entre le prototype et la VM BSD cible. Les étapes 2–5 (le
sous-agent lit l'enveloppe → vérifie l'empreinte → l'utilise en ligne → émet
l'attestation → le coordinateur efface) sont identiques à l'octet près.

**Révocation** : trois exercices — planifié (message de contrôle + drainage),
d'urgence (se compose avec le marqueur HALT de D3, `rm -P` des enveloppes,
`[control] HALT-ALL`), fuite d'enveloppe (effacement par tâche + nouveau
msgid). Piste d'audit = historique jj du spool.

**Points d'accroche inter-conceptions :**

- La politique de reprise de D2 traite un désaccord d'empreinte d'identifiant comme une **escalade immédiate, sans reprise automatique** (un prédicat supplémentaire avant la table de reprise).
- Le marqueur HALT de D3 accepte `X-Halt-Reason: credential-fingerprint-mismatch` comme cause d'arrêt reconnue.

**Backlog d'implémentation** (affecté en aval) :

- ops : créer `.gitignore` avec `var/run/` et `var/mail/spool.lock` avant la première distribution.
- coordinator : `bin/secret-materialize.nu` (Nushell selon CLAUDE.md), `bin/secret-wipe.nu`, `bin/spool-emit-control.nu`.

## 12. Politique de reprise (d'après D2)

Le coordinateur est un **interpréteur de machine à états, pas un
planificateur**. Chaque catégorie de réponse correspond à exactement une
transition. Mécanique, sans jugement au cas par cas.

**Machine à états :**

```
[DISPATCHED] -> [AWAITING_REPLY] -> [HARVEST] -> [VERIFY] -> [DONE]
                                       |             |
                                       +-> [RETRY_QUEUED] -+
                                       |                   |
                                       +-> [ESCALATE]      |
                                                           |
                            (after fib backoff) <----------+
```

Sept états : `DISPATCHED`, `AWAITING_REPLY`, `HARVEST`, `VERIFY`,
`RETRY_QUEUED`, `DONE`, `ESCALATE`. (Digraphe DOT complet dans le corps de
`<design-d2.reviewer@…>`.)

**Table de décision** (une ligne par catégorie de réponse, schéma = catégorie, prédicat, next_state, max_retries) :

| Catégorie                 | Prédicat                                                          | État suivant  | Reprises max |
|---------------------------|-------------------------------------------------------------------|---------------|-------------|
| `pass+verified`           | `verdict='pass'` ET chaque re-sondage `[[claims]]` passe          | `DONE`        | 0           |
| `pass+probe-failed`       | `verdict='pass'` ET un re-sondage `[[claims]]` échoue/est non concluant | `RETRY_QUEUED` | **1** (demi-budget) |
| `fail`                    | `verdict='fail'`                                                  | `RETRY_QUEUED` | 3           |
| `blocked+unblocker-named` | `verdict='blocked'` + champ `blocked_by` actionnable              | `RETRY_QUEUED` | 3           |
| `blocked+no-unblocker`    | `verdict='blocked'` + pas de `blocked_by`                         | `ESCALATE`    | 0 (immédiat) |
| `no-reply`                | aucun message correspondant au Message-ID distribué après expiration (30 min par défaut) | `RETRY_QUEUED` | 3           |
| `malformed`               | échec d'analyse mbox / TOML invalide / champs requis manquants / pass-sans-claims-quand-requis | `RETRY_QUEUED` | 3 |

**Backoff : Fibonacci** `[60, 60, 120]` plafonné à 300 s.

**Pourquoi Fibonacci et pas exponentiel** : chaque reprise coûte 60–100k tokens
de budget agent. L'exponentiel `(60→120→240→480)` grille le TTL du cache de
prompt (5 min, selon les consignes ScheduleWakeup de CLAUDE.md) à chaque pas.
Fibonacci croît plus lentement ; le 60 doublé permet à un aléa transitoire de
se résoudre dans une fenêtre où le cache est chaud. Le plafond s'aligne sur le
TTL de 5 min.

**Pourquoi `max_attempts = 3`** : règle de trois. (1) la ligne de base établit
le mode de défaillance ; (2) prouve qu'il n'est pas transitoire, avec le résumé
de l'échec précédent intégré en ligne ; (3) dernière chance, avec l'instruction
explicite « si tu ne peux pas passer, renvoie blocked-avec-débloqueur-nommé
plutôt qu'un nouvel échec ». Au-delà de 3 = muri (effort déraisonnable) →
escalade.

**Pourquoi le désaccord de sondage n'obtient qu'une seule reprise** : des
reprises d'agent supplémentaires ne peuvent pas départager l'agent et la sonde.
Soit la sonde est fausse (correction par l'opérateur), soit l'agent hallucine
(ajustement par l'opérateur). Les deux exigent une intervention humaine →
escalade rapide.

**Contrat de charge utile de reprise** — chaque reprise DOIT modifier la charge
utile de la requête (les renvois purs sont interdits — pur muda) :

- `prior_attempt_msgid` — Message-ID de la réponse échouée (ou NIL pour no-reply)
- `prior_attempt_failure` — verdict + les 500 premiers caractères de la preuve d'échec
- `prior_attempt_count` — 1 ou 2
- `format_violation` — erreur d'analyse (si `category=malformed`)
- `probe_disagreement` — sortie de la sonde fleet-eval (si `category=pass+probe-failed`)
- Nouveau Message-ID par reprise : `<task-XXX.coord.r{N}@smolfire.local>`
- En-tête `X-Attempt: <N>` (indexé à partir de 1 ; l'état du coord est reconstructible depuis le spool seul)
- Pour `no-reply` uniquement : `budget_tokens` double à chaque reprise, plafonné à 200000

**Prédicat inter-conceptions (vérification avant table) :**

- Désaccord entre `reply.secrets_consumed[*].fingerprint` et l'empreinte enregistrée par le matérialisateur → contourner la table, forcer l'escalade avec `X-Halt-Reason: credential-fingerprint-mismatch`. Mécanique, pas un jugement (selon D1).

**Invariant de non-double-distribution** : le coordinateur NE DOIT PAS avoir
deux messages en vol avec le même `task_id`. Appliqué en balayant le spool à
la recherche de `<task-XXX.coord*@>` sans correspondance avant chaque nouvelle
distribution.

**Cas limites qui méritent d'être nommés explicitement :**

- `pass` sans `[[claims]]` alors que `attestation_required=true` → MALFORMED, pas pass+verified.
- Sonde `INCONCLUSIVE` (p. ex. expiration SSH) → probe-failed, pas pass+verified.
- Plusieurs `[[claims]]` avec un mélange PASS/FAIL → la catégorie est `pass+probe-failed`.
- Réponse tardive après une reprise déclenchée par expiration → journalisée, ignorée ; la reprise en vol fait autorité.
- Deux réponses avec le même `In-Reply-To` → la première gagne ; la seconde est journalisée comme violation de protocole.
- Crash du coordinateur en pleine reprise → au redémarrage, balayer le spool à la recherche de messages distribués sans réponse plus anciens que l'expiration ; les traiter comme no-reply avec le compteur d'essais tiré de l'en-tête `X-Attempt`.

## 13. Canal d'escalade (d'après D3)

**Primaire** : message dans le spool vers `user@smolfire.local` + fichier
marqueur `var/mail/HALT`. Le spool *est* le substrat — le réutiliser ne coûte
aucun outillage nouveau, s'insère correctement dans les fils de discussion,
survit à un clone frais, et l'utilisateur dispose déjà des outils mbox
standards (`mailx`, `less`, `grep`).

**Repli** : DM IRC Ergo en un coup vers `ryan` sur `<irc-host-ip>:6697` (TLS)
via `openssl s_client`. Signal en émission seule, PAS le chemin de réponse
canonique. Respecte la consigne CLAUDE.md « pas de boucles de sondage sur les
serveurs LAN » et les protections anti-blocage automatique d'Ergo — exactement
une tentative TLS, optionnellement une en clair sur 6667 si la poignée de main
TLS échoue, puis consignation du résultat dans le marqueur HALT et poursuite.

**Marqueur de pause** : `var/mail/HALT` — un seul `stat()` par cycle du
coordinateur constitue l'intégralité de la vérification de pause. Le spool
n'est ré-analysé qu'une fois la présence de HALT confirmée, pour trouver la
réponse de reprise.

**Forme du message HALT :**

```
From: coordinator@smolfire.local
To: user@smolfire.local
Subject: [HALT] <task-id> — <one-line cause>
Message-ID: <halt-<task-id>.coord@smolfire.local>
In-Reply-To: <task-id.coord@smolfire.local>
References: <all retry msgids, space-separated>
X-Priority: 1
X-Halt-Reason: retry-exhausted | claim-verification-failed | malformed-reply
             | no-reply | blocked-no-unblocker | credential-fingerprint-mismatch
X-Resume-Tag: resume-<task-id>
```

Le corps (TOML) porte la catégorie, la liste des essais
(msgid+verdict+preuve+résultat-de-sonde par essai), le résumé last_failure,
proposed_actions = [retry, retry-as-<role>, abort, edit], et les demandes (ce
que le coordinateur attend de l'humain/de D3).

**Marqueur HALT (corps TOML)** : `halted_at`, `task_id`, `halt_msgid`,
`resume_tag`, `reason`, `fallback_fired`, `fallback_status`.

**Protocole de réponse utilisateur** : ajouter un message mbox de reprise
(`Subject: Re: [HALT]`, `Message-ID: <resume-<task-id>.user@…>`,
`X-Resume-Action: retry | retry-as-<role> | abort | edit`), puis
`rm var/mail/HALT`. Un simple `rm var/mail/HALT` seul = abandon, aucune
redistribution. Latence de détection = prochain cycle du coord (60 s suggérées
quand HALT est présent).

**Chemin de triple défaillance** (l'écriture dans le spool échoue ET l'IRC
échoue ET l'écriture du marqueur HALT échoue) :

1. Tenter inconditionnellement l'écriture de `var/mail/HALT` — une seule opération sur le système de fichiers.
2. Si même cela échoue, imprimer une panique structurée sur stderr : `{"event":"smolbsd-coord-panic","task_id":"…","spool_writable":false,"irc_reachable":false,"halt_writable":false,"ts":"…"}`. Code de sortie 78 (`EX_CONFIG`).
3. La terminaison du processus coord est elle-même l'escalade finale. Le journal de session du harnais Claude Code porte le signal jusqu'à l'utilisateur au prochain engagement. La contrainte asynchrone est satisfaite via la frontière du harnais.

La triple défaillance est un événement d'intégrité du substrat, pas de niveau
tâche. La récupération est humaine ; aucune reprise automatique.

**Isolation par tâche** : le marqueur HALT est indexé par `task_id`, pas
global. Les autres tâches continuent d'être distribuées même quand une tâche
est arrêtée. (D2 confirme : la tâche escaladée passe à `status=escalated` ; la
boucle de distribution continue pour le travail sans rapport.)

## 17. Application capacité/intention (leçon du round 1)

**Mode de défaillance découvert** : dans la vague de distribution du round 1,
l'architecte (`feature-dev:code-architect`) s'est vu affecter une tâche dont
l'`acceptance` exigeait l'écriture d'un fichier
(`plans/tinyos/PHASE-1-FORGE-TINY-BASELINE.md`). Ce type de sous-agent est en
**lecture seule** — il dispose de Read/Glob/Grep/WebFetch/TodoWrite mais pas de
Write/Edit/Bash. L'agent a produit le contenu du plan dans sa réponse mais n'a
pas pu le matérialiser ; le coordinateur a dû effectuer cette étape. Le
protocole a laissé cela se produire silencieusement parce que rien ne
pré-validait les capacités outillées de l'agent par rapport aux besoins réels
de la tâche.

**Règle** : chaque enveloppe de requête DOIT inclure un champ `tools_required`
(en plus du champ `tools_allowed` existant). Le coordinateur DOIT refuser de
distribuer une tâche à un type de sous-agent dont le jeu d'outils ne couvre pas
`tools_required`.

**Ajout au schéma** (à insérer dans le `[reply_contract]` de chaque requête, voir §4.1) :

```toml
[reply_contract]
tools_required = ["Read", "Write", "Edit", "Bash"]   # DOIT être un sous-ensemble du jeu d'outils réel du sous-agent
tools_allowed  = ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]   # autorisés en supplément
```

**Vérification pré-vol du coordinateur** (mécanique) :

```
for tool in tools_required:
    assert tool in subagent_type.available_tools
        or refuse_dispatch("capability mismatch", task_id, subagent_type, missing=tool)
```

**Registre de capacités** (intégré au coordinateur, dérivé des outils
documentés de chaque type de sous-agent) :

| Type de sous-agent             | A Write ? | A Bash ? | Adapté à |
|--------------------------------|-----------|-----------|--------------|
| `general-purpose`              | oui       | oui       | construction, ops, travail général |
| `feature-dev:code-architect`   | **non**   | non       | recherche, conception, planification **uniquement** |
| `feature-dev:code-explorer`    | non       | non       | exploration de base de code |
| `feature-dev:code-reviewer`    | non       | non       | tâches de revue uniquement |
| `pr-review-toolkit:code-reviewer` | oui (\*) | oui      | revue avec action |
| `Explore`                      | non       | oui       | exploration à forte composante de recherche |

(\*) selon la liste d'outils documentée

**Traitement de l'échec** : le refus pour désaccord de capacités est un rejet
au niveau du coordinateur, PAS une reprise. Le coordinateur soit (a) réachemine
vers un type de sous-agent capable, soit (b) découpe la tâche en une étape de
recherche seule (sous-agent RO) + une étape de matérialisation (sous-agent RW).
Le motif architecte+coordinateur du round 1 est la forme canonique de (b) :
l'architecte produit le contenu, le coordinateur le matérialise.

**Pourquoi cela mérite sa propre section** : le mode de défaillance se
généralise — tout protocole qui découple l'*intention* (le brief de la tâche)
de la *capacité* (l'exécutant) a besoin de cette vérification. Le transfert
mbox+TOML n'a fait que rendre l'écart visible.

## 18. Notes opérationnelles — VM <aarch64-builder>, contexte réseau, dérive de skill (v1.2)

Cette section consigne trois réalités opérationnelles découvertes pendant les
tests d'accessibilité du round 2. Aucune ne change le contrat du protocole ;
toutes changent ce qu'un agent démarré à froid doit savoir pour utiliser
réellement le substrat.

### 18.1 Identité de la VM <aarch64-builder> (la dérive « fb-vm-24 »)

La VM de build FreeBSD aarch64 sur `<hypervisor-host>` s'appelle canoniquement
**`<aarch64-builder>`** dans la réalité : c'est le nom de la session screen,
l'argument qemu `-name`, et le nom de base de l'image disque
(`/Users/studio/vms/freebsd-15-build.qcow2`, lancée via
`screen -dmS <aarch64-builder> ...`). Le **skill freebsd-build-vm** situé à
`/Users/studio/.claude/skills/freebsd-build-vm/SKILL.md` l'appelle
**`fb-vm-24`** partout — le « 24 » était un suffixe d'hôte
(`<hypervisor-host>`) qui a été promu dans le nom de la VM au fil de la prose
du skill. **Le skill est périmé sur ce point et nécessite une PR de mise à
jour séparée** (hors du périmètre de ce dépôt ; le skill réside globalement
sous `~/.claude/`).

**Règle opérationnelle** : en lisant le skill freebsd-build-vm, substituer
mentalement `<aarch64-builder>` à `fb-vm-24` pour les identifiants de niveau
VM (session screen, `-name` qemu, nom de fichier d'image). Lorsque le nom de
skill `fb-vm-24` est référencé comme symbole dans ce dépôt, il est marqué
« nom canonique du skill (dérive ; la VM réelle est `<aarch64-builder>`) ».

### 18.2 Port SSH hostfwd (2225 → 2222)

Le skill freebsd-build-vm documente `hostfwd=tcp::2225-:22`. La vérité terrain
sur <hypervisor-host> (vérifiée le 2026-04-30T21:33:39Z via `lsof` sur le pid
qemu 29210) : `hostfwd=tcp::2222-:22`. **Utiliser le port 2222 pour le SSH
vers <aarch64-builder>**.

```
ssh -J <hypervisor-host> -p 2222 builder@localhost      # correct (réalité actuelle)
ssh -J studio@<lan-gw-ip> -p 2225 builder@localhost  # prose de skill périmée ; ne pas utiliser
```

### 18.3 Chemin du partage virtfs (bug de wrapper au préfixe doublé)

La ligne de commande qemu de <aarch64-builder> comporte
`-virtfs local,path=/Users/studio/Users/studio/share/<aarch64-builder>,...`. Le
`/Users/studio/Users/studio/` doublé est un **bug du wrapper de lancement** :
un `~` littéral a été préfixé à un chemin déjà absolu dans
`run-fb-vm-24.sh` (le modèle fleet-ops), produisant le préfixe doublé lorsque
le shell a développé `~` en `/Users/studio` avant la concaténation de chaînes.

**Statut** : documenté comme un bug de wrapper à corriger séparément dans
fleet-ops (`vm-templates/run-freebsd-vm.sh.template`). D'ici là, l'entrée des
sources / la sortie des artefacts doit utiliser le chemin doublé côté hôte :

```
# côté hôte (<hypervisor-host>) — déposer les sources ici :
~/Users/studio/share/<aarch64-builder>/source/        # FAUX (prose du skill)
/Users/studio/Users/studio/share/<aarch64-builder>/source/  # RÉALITÉ ACTUELLE
```

À l'intérieur de la VM, le tag de montage (`host0`) et le point de montage
(`/mnt/host`) sont inchangés — le bug ne concerne que le chemin côté hôte.

### 18.4 Piège du socket screen perdu (qemu vivant, `screen -r` échoue)

**Détecté via** : sur <hypervisor-host>, `pgrep -f qemu-system-aarch64`
renvoie le pid 29210 (qemu en cours d'exécution) mais `screen -ls` renvoie
`No Sockets found in /var/folders/.../screen`. La VM <aarch64-builder> est
joignable en ssh:2222, mais le chemin de récupération canonique
(`screen -r <aarch64-builder>` → console) est **inerte** — la session screen
qui a lancé qemu a perdu son fichier socket. Le processus qemu a hérité des
descripteurs de fichiers et a survécu ; le wrapper screen, non.

**Procédure de récupération** (selon le skill freebsd-build-vm, section
« Launching the VM (canonical) ») :

```
# 1. Confirmer les deux moitiés du diagnostic sur <hypervisor-host> :
ssh <hypervisor-host> 'pgrep -f qemu-system-aarch64; screen -ls'
#  -> pid qemu présent
#  -> "No Sockets found"  --> socket perdu

# 2. Tuer le qemu orphelin (il n'a de toute façon plus de console) :
ssh <hypervisor-host> 'pkill -f "qemu-system-aarch64.*-name <aarch64-builder>"'

# 3. Relancer via le wrapper canonique (rétablit screen + socket) :
ansible <hypervisor-host> -m raw -a "~/vms/run-fb-vm-24.sh"
ansible <hypervisor-host> -m raw -a "screen -ls; pgrep -f qemu-system-aarch64"
```

**Quand NE PAS faire cela** : pendant qu'un long build est en cours à
l'intérieur de la VM (via une session screen interne lancée en ssh,
`screen -dmS smolkernel` ou similaire). Tuer qemu tue le build. Vérifier
qu'aucun build n'est en vol avant la récupération —
`ssh -p 2222 builder@... screen -ls` depuis <hypervisor-host> listera toute
session screen interne à la VM.

### 18.5 Les noms d'hôtes `.local` du parc sont limités au LAN (mise en garde contexte réseau)

Les noms d'hôtes `.local` du parc (`qnas.local`, `ergo.local`,
`searxng.local`, `gitea.local`, etc., selon les entrées `/etc/hosts` gérées
par ansible avec des IP `10.0.3.x` — voir la section « Search » de CLAUDE.md)
**ne se résolvent que lorsque l'agent est attaché au LAN** (l'hôte est sur le
LAN QNAS <lan-subnet>). Depuis un coordinateur non attaché au LAN (p. ex. un
Mac sur un autre réseau utilisant Tailscale pour joindre
<hypervisor-host>), ils échouent à se résoudre / router.

Tailscale résout les noms des nœuds attachés à Tailscale
(<hypervisor-host> est lui-même membre du tailnet) mais ne fait **pas** de
proxy vers les hôtes hors tailnet à l'intérieur d'un invité QEMU imbriqué
(<aarch64-builder> atteint le LAN via le NAT SLIRP uniquement ; le LAN ne voit
pas <aarch64-builder> comme un pair du tailnet).

**Implication pour le repli d'escalade D3** (§13) : le DM IRC de repli
`openssl s_client <irc-host-ip>:6697` est **inerte depuis un coordinateur non
attaché au LAN** — il n'existe aucune route vers `<irc-host-ip>` depuis un Mac
qui ne voit <hypervisor-host> que via Tailscale. Le chemin primaire marqueur
HALT + message dans le spool (§13) fonctionne toujours (il est local au
système de fichiers), donc la conception n'est pas cassée. Le repli est en
« meilleur effort » et se dégrade en « consigné dans le marqueur HALT,
fallback_status = 'no-route' » lorsqu'il est déclenché hors LAN.

**Aucun changement de conception** : le chemin de triple défaillance de D3
(§13) couvre déjà ce cas — l'échec du repli est journalisé, pas fatal. Cette
mise en garde n'est que l'hypothèse explicite de contexte réseau qu'un agent
démarré à froid doit reconnaître avant de déboguer « pourquoi le repli IRC a
silencieusement échoué sans effet ».

### 18.6 L'hôte Gitea est <gitea-host>:3001, pas gitea.local:3000

`gitea.local` (selon le DNS du parc dans CLAUDE.md) se résout en `<nas-ip>`
(QNAS) mais Gitea tourne en réalité sur `<gitea-host>` à `<internal-ip>:3001`.
Le port 3000 sur cet hôte est TensorZero. La table des noms d'hôtes du parc de
CLAUDE.md est périmée pour cette entrée.

**Tunnel depuis Tailscale (conférence / distant) :**
```sh
ssh -fN -L 3001:<internal-ip>:3001 home@<tailscale-ip>   # rebond via <internal-host>
# puis : jj git remote add gitea http://localhost:3001/studio/smolBSD.git
```

**Direct depuis le LAN :** `http://<internal-ip>:3001/`

## 14. Mises en garde et limites connues

1. **Aucun serveur MCP `sequential-thinking` n'est chargé** dans cette instance Claude Code. Le raisonnement pas à pas se fait dans le prompt, pas via ce MCP. Si l'utilisateur l'installe plus tard, le protocole ne change pas — c'est une affaire interne au coordinateur.
2. **smolBSD est désormais un dépôt jj** depuis la v1.1 (`jj git init` exécuté ; le commit `24b600c3` a enregistré le round 1). Isolation multi-agent ultérieure via `jj workspace add ../smolBSD-<role>`.
3. **La mémoire existe mais est clairsemée**. `~/.claude/projects/-Users-studio-smolBSD/memory/MEMORY.md` indexe trois entrées (contexte Knox/TrustZone, décision BRAP L1, préférence VCS jj-plutôt-que-git). La spécification, le plan et le spool restent l'état durable primaire.
4. **L'hypothèse de rédacteur unique** pour le spool ne tient que tant que le coordinateur est le seul producteur. Les scénarios multi-coordinateurs nécessitent un verrouillage — hors du périmètre de la v1.
5. **Fuite de contexte des sous-agents** : quand cette session Opus utilise l'outil `Agent`, le sous-agent hérite effectivement d'un certain contexte implicite du harnais (index des skills, CLAUDE.md). Un véritable « aucun contexte partagé » exige de passer à une invocation `claude` séparée ou à un autre harnais — voir §15.
6. **RTK est optionnel côté agent et pas encore installé sur cet hôte** (`which rtk` → introuvable). La compression sortante (côté A) est honorée par le pré-inlining du coordinateur ; l'entrante (côté B) devient active une fois `brew install rtk && rtk init -g` exécuté. Les agents sans RTK se dégradent gracieusement mais produisent des sorties plus volumineuses.
7. **Frontière de confiance** : le coordinateur doit vérifier les `[[claims]]` indépendamment. Un sous-agent mal aligné pourrait fabriquer des affirmations ; `fleet-eval` est la porte du réflexe d'évaluation. **Les affirmations du round 1 n'ont pas encore été re-sondées** — suivi en suspens.
8. **RTK est Apache-2.0** — licence sur la liste d'autorisation de l'utilisateur. Si elle change en amont, nous réévaluons.
9. **L'écart capacité/intention** existait en v1 ; clos par le §17 en v1.1. Les requêtes préexistantes dans le spool n'ont pas de champ `tools_required` — elles bénéficient d'une clause d'antériorité pour le round 1 uniquement.
10. **Risque d'hallucination de citation** : l'architecte du round 1 a cité un « billet de blog vermaden 2026-02 » non vérifié indépendamment. Traiter les citations introduites par les agents comme de faible confiance jusqu'à contre-vérification. Le contenu technique substantiel (oci-image-runtime.conf, config MINIMAL, Makefile.vm) est vérifiable contre [cgit.freebsd.org](https://cgit.freebsd.org/src/tree/sys/amd64/conf/).
11. **`.gitignore` pas encore écrit** — la conception des secrets D1 exige que `var/run/` soit ignoré par jj/git avant la première distribution d'identifiants. Suivi ops.
12. **`pass(1)` est GPL-2.0** — interdit par la règle de licence de l'utilisateur. La conception des secrets utilise `gopass` (MIT) à la place. Ne pas glisser accidentellement `pass` dans une dépendance future.
13. **Le skill freebsd-build-vm est périmé sur le nom de VM et le port SSH** (v1.2). Le skill global à `/Users/studio/.claude/skills/freebsd-build-vm/SKILL.md` appelle la VM `fb-vm-24` (réel : `<aarch64-builder>`) et indique le port hostfwd `2225` (réel : `2222`). La mise à jour du skill est une PR séparée hors de ce dépôt ; le §18 est la réconciliation faisant foi pour l'instant. Substituer mentalement à la lecture du skill.
14. **Les noms d'hôtes `.local` sont limités au LAN** (v1.2 — voir §18.5). Depuis un coordinateur n'atteignant <hypervisor-host> que via Tailscale, le repli IRC de D3 vers `<irc-host-ip>:6697` est inerte — la conception se dégrade gracieusement (le marqueur HALT + le chemin du spool sont locaux au système de fichiers), mais les agents doivent s'attendre à `fallback_status = 'no-route'` hors LAN.
15. **La perte du socket screen est un danger connu de <aarch64-builder>** (v1.2 — voir §18.4). qemu peut survivre à la session screen qui l'a lancé ; `screen -r <aarch64-builder>` échoue alors même que la VM est joignable en ssh:2222. La récupération est `pkill qemu` + relance via `~/vms/run-fb-vm-24.sh`. Vérifier d'abord qu'aucun build interne à la VM n'est en vol.

## 15. Travaux futurs

- Migrer le spool vers une vraie instance (Tiny|Rump)BSD maintenant que les §§11–13 sont remplis — le protocole est portable par construction.
- Committer le spool + la spécification à chaque boucle du coordinateur (`jj describe -m "..." && jj new`). Isolation par agent via `jj workspace add ../smolBSD-<role>`.
- Implémenter les binaires du coordinateur :
  - `bin/coord-tick.nu` — interpréteur de machine à états piloté par table, lisant le §12 mot pour mot
  - `bin/coord-escalate.nu` — point d'entrée du protocole D3
  - `bin/secret-materialize.nu` / `bin/secret-wipe.nu` — cycle de vie des enveloppes D1
  - `bin/spool-emit-control.nu` — messages de contrôle (rotate-key, halt, resume)
  - `bin/spool-tail.nu` — visionneuse façon `mailx -f spool` avec impression TOML formatée
  - `bin/spool-archive.nu` — rotation du spool au-delà de N messages vers `var/mail/spool.YYYY-MM-DD`
- Transfert inter-harnais : prouver que le protocole fonctionne coordinateur-Claude → builder-Codex.
- Point de découverte `Manifest:` selon AX-first.
- Intégration TrustZone (perspective, vu le passé Knox de l'utilisateur + la décision BRAP L1) : les réponses pourraient porter des blocs `[[attestations]]` aux côtés des `[[claims]]`, où l'attestation est une citation signée par TA produite par la VM de build. Candidat pour la spec v2.

## 16. Liste de contrôle d'auto-revue (v1.2)

- [x] Aucun « TBD » dans aucune section — §§11/12/13 entièrement intégrés ; §17 entièrement spécifié ; §18 (notes opérationnelles) ajouté en v1.2
- [x] Sections cohérentes entre elles — le schéma du §4.1 inclut le nouveau champ `tools_required` selon le §17 ; la table des rôles du §8 a une colonne Outils-requis ; renvois croisés §11/§12 (surcharge D1+D2 pour désaccord d'empreinte) ; renvois croisés §12/§13 (ESCALATE → protocole HALT) ; renvois croisés §13/§18.5 (repli IRC inerte hors LAN, par conception — retombe sur le chemin primaire local au système de fichiers)
- [x] Périmètre : concentré sur un seul substrat (mbox+TOML+spool) avec un contrat clos — prêt à implémenter
- [x] Ambiguïtés résolues :
  - chemin mbox explicite (`var/mail/spool`)
  - RTK côté A et côté B distingués
  - frontière de confiance nommée (sondes fleet-eval ; le coordinateur ne fait jamais confiance à la seule auto-déclaration)
  - séparation capacité/intention (§17) — types de sous-agents lecture seule vs lecture-écriture
  - pass+probe-failed dispose d'un demi-budget de reprise (§12)
  - blocked a deux sous-catégories (avec/sans débloqueur) avec des transitions différentes
  - identité de la VM <aarch64-builder> et primitives d'accessibilité (§18) — nom de VM `<aarch64-builder>` (pas `fb-vm-24`), port SSH 2222 (pas 2225), chemin virtfs `/Users/studio/Users/studio/share/<aarch64-builder>` (bug de wrapper au préfixe doublé, documenté pour correction séparée)
- [x] Plancher de licences vérifié : openssl Apache-2.0, Ergo MIT, Nushell MIT, mbox = simple RFC822 (aucune bibliothèque), gopass MIT, ssh-agent BSD-2+ISC, RTK Apache-2.0. Aucun GPL/LGPL/AGPL.
- [x] Composition inter-conceptions explicite : D1↔D2 (chemin du désaccord d'empreinte), D2↔D3 (transfert d'escalade), D1↔D3 (le marqueur HALT accepte X-Halt-Reason de D1), §18.5↔§13 (le repli IRC hors LAN se dégrade en no-route journalisé, chemin primaire non affecté)
- [x] Références en aval nommées : la vérification de capacités du §17 est mécanique, pas un jugement ; les réconciliations du §18 sont des consultations mécaniques (sans jugement) jusqu'à la mise à jour du skill en amont
- [x] Dérive mise au jour et réconciliée (v1.2) : le skill freebsd-build-vm est périmé sur le nom de VM + le port SSH ; le §18 + la mise en garde §14.13 sont la réconciliation faisant foi dans l'arbre ; le skill nécessite une PR de mise à jour séparée
