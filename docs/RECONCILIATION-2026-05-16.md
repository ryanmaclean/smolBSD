# Reconciliation Report — 2026-05-16

Reality-reconciliation pass covering spec, code, docs, translations, and branch model.
Read-only; no code changes, no commits.

---

## 1. WHAT THE SPEC PROMISES

Concrete behavioral assertions from `docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md`:

- **§2** Single shared mbox spool at `var/mail/spool`; coordinator is the only appender; subagents append replies; no locking.
- **§4** Envelope schema: TOML body with `task_id`, `verdict`, `[[claims]]`, `[[artifacts]]`, `[reply_contract]` fields; `tools_required` + `tools_allowed` in every request.
- **§5** `X-JEC-Compression: rtk-v1` header; coordinator pre-processes output through RTK before inlining into `[brief]`.
- **§6** Dispatch loop: coordinator writes N requests, spawns N subagents in parallel; each subagent reads only its own message.
- **§7** Every `verdict="pass"` + `attestation_required=true` reply MUST carry at least one `[[claims]]` block; coordinator cross-checks with `fleet-eval verify`.
- **§11** Secrets never in spool; `var/run/secrets/` mode 0600; coordinator materializes via `bin/secret-materialize.nu` and wipes via `bin/secret-wipe.nu` after harvest.
- **§12** Seven-state retry machine: `DISPATCHED → AWAITING_REPLY → HARVEST → VERIFY → DONE / RETRY_QUEUED / ESCALATE`. Decision table with Fibonacci backoff `[60, 60, 120]`. Retry payload must include `prior_attempt_msgid`, `prior_attempt_count`, etc. No-double-dispatch invariant. `pass` without `[[claims]]` when required → MALFORMED.
- **§13** Escalation: primary channel is in-spool message to `user@smolbsd.local` + `var/mail/HALT` marker. Fallback: one-shot IRC DM to `ryan` on `<irc-host-ip>:6697` TLS, one plain fallback on 6667, then record outcome and continue. HALT marker TOML body must include `fallback_fired` and `fallback_status` fields. Triple-failure path exits code 78 (`EX_CONFIG`).
- **§17** Every request must include `tools_required`. Coordinator refuses dispatch if subagent type's capability set does not cover `tools_required`. Capability mismatch is a routing rejection, not a retry.

---

## 2. WHAT THE CODE ACTUALLY DOES

| Spec promise | Status | Evidence |
|---|---|---|
| §2 Single spool, coordinator appends, subagents append | **DONE** | `coord-tick.nu:135`, `coord-tick.nu:599`, `coord-dispatch.nu:69,137` |
| §4 Envelope schema fields | **PARTIAL** | Request envelopes dispatched by `state-dispatching` (coord-tick:619–629) emit only `task_id` + `action = "dispatch"` — no `[brief]`, `[context_pointers]`, `[acceptance]`. The schema is correct in the spec example and in the `spawn-subagent` prompt, but live dispatch envelopes are stubs. |
| §5 RTK `X-JEC-Compression` header | **MISSING** | No `rtk` invocation anywhere in `bin/`. Dispatched envelopes (coord-tick:618–629) do not include `X-JEC-Compression` header. RTK is referenced only in prose. |
| §6 N-parallel dispatch | **PARTIAL** | `spawn-subagent` (coord-tick:198) launches via `sh -c ... &`; `coord-dispatch.nu:61` uses `job spawn`. True parallel-batch dispatch is not implemented — the harvesting loop dispatches one task per tick and breaks (`has_dispatch = true` exits the for-loop, coord-tick:339). |
| §7 `fleet-eval` cross-check of claims | **MISSING** | Claims are checked for *presence* only (coord-tick:386–387). No `fleet-eval verify` subprocess is invoked anywhere in `bin/`. |
| §11 `bin/secret-materialize.nu`, `bin/secret-wipe.nu` | **DONE** | Both files exist (`bin/secret-materialize.nu`, `bin/secret-wipe.nu`). Also `bin/spool-emit-control.nu` exists. The §11 implementation backlog is satisfied. |
| §12 Retry state machine (DISPATCHED → AWAITING_REPLY → etc.) | **PARTIAL** | The retry decision table is implemented (coord-tick:376–476); Fibonacci backoff is NOT — the code increments `attempt_counts` but does not sleep or schedule future attempts with `[60, 60, 120]` delays. Retry payload fields (`prior_attempt_msgid`, `prior_attempt_count`, `format_violation`) are not written into retry dispatches (coord-tick:619–629 writes only `task_id` + `action`). |
| §12 No-double-dispatch invariant | **MISSING** | No scan for unmatched `<task-XXX.coord*@>` before each dispatch. `state-dispatching` does not check for existing in-flight message with same `task_id`. |
| §13 IRC DM fallback (`try-irc-dm`) | **DONE** | `try-irc-dm` (coord-tick:162–191) implements TLS attempt on 6697 + plain fallback on 6667 with one-shot semantics. |
| §13 `fallback_fired` / `fallback_status` written to HALT marker | **DONE** | coord-tick:187 writes both fields via `insert fallback_fired true \| insert fallback_status $result`. |
| §13 Triple-failure path, exit 78 | **MISSING** | No triple-failure guard in `coord-tick.nu` or `coord-escalate.nu`. `coord-escalate.nu` does not emit exit code 78 or the structured panic JSON on stderr. |
| §17 `tools_required` pre-flight | **DONE** | coord-tick:489–504 checks `tools_required` against `AGENT_CAPABILITIES` and logs `dispatch_capability_mismatch`. |

---

## 3. SPEC §13 IRC FALLBACK STATUS

The previous escalate-test agent report was **incorrect**. IRC code and `fallback_fired`/`fallback_status` writes are present in `bin/coord-tick.nu`.

Spec text mandating the fields (§13, "HALT marker (TOML body)"):

> `halted_at`, `task_id`, `halt_msgid`, `resume_tag`, `reason`, **`fallback_fired`**, **`fallback_status`**.

The `write-halt-marker` function (coord-tick:91–106) does NOT write `fallback_fired` or `fallback_status` — it writes `task_id`, `verdict`, `message_id`, `halted_at`, `reason`, `attempts`, `halt_msgid`, `resume_tag`. The `fallback_fired`/`fallback_status` fields are added only afterwards by `try-irc-dm` (coord-tick:184–189), which reads the existing HALT file and inserts those two fields. So the fields ARE written, but only when `try-irc-dm` is called. The `coord-escalate.nu` standalone script (98 lines) writes a HALT marker at lines 79–91 that does NOT include `fallback_fired` or `fallback_status` at all, and does not call `try-irc-dm`. **This is a real divergence: the standalone escalation path omits the mandatory fields.**

---

## 4. TRANSLATION DRIFT

Both `.fr.md` and `.ja.md` translations are **severely truncated** relative to the English source:

| File | Lines | English source lines |
|---|---|---|
| `.md` (English) | 570 | — |
| `.fr.md` | 87 | 570 |
| `.ja.md` | 85 | 570 |

The French and Japanese files cover only through the `[reply_contract]` block in §4.1 — they end abruptly after line ~87, cutting off the agent reply schema (§4.2), JEC profile (§5), dispatch loop diagram (§6), all of §7–§13, §17, and §18.

Spot-check of covered sections:

- **§4 envelope schema**: FR and JA match English exactly for the covered portion. Code blocks are untranslated (correct); TOML comments are translated in FR (`# JEC : prose, limite souple 200 mots`) and JA (`# JEC：散文、ソフト上限200語`).
- **§12 FSM / §15 future work / §13 escalation**: not present in either translation — the files end before these sections begin.
- **Version header**: all three files claim `v1.2` with matching history lines. The translations are not stale on the covered text; they are simply incomplete.

**Verdict**: FR and JA are translations of an intermediate draft (approximately the §4.1 request envelope only), not of the final v1.2 English spec. They need to be extended to cover §4.2 through §18.

---

## 5. STALE CLAIMS IN DOCS

### README.md
- "Runs three Nu suites: `mbox-parse-test.nu`, `coord-tick-test.nu`, and `spawn-subagent-test.nu`" (line 98–99). **Stale**: `tests/run-all.sh` runs all `tests/*-test.nu` files; as of today that is 8 suites: the three listed plus `coord-escalate-test.nu`, `spool-archive-test.nu`, `spool-compact-test.nu`, `spool-tail-test.nu`, and `tpm-seal-test.nu`. The `coord-fsm-tests.nu` file also exists (300 lines, 5 tests) but does not match the `*-test.nu` glob — it is not invoked by `run-all.sh`.

### CLAUDE.md (project)
- §8 "Active development branch: `claude/stoic-pascal-u6y3T`". **Stale**: that branch has been merged to `main` (PR #7). The current HEAD (detached) is at `9dfe023`, which is on the `claude/stoic-pascal-u6y3T` remote branch and is 4 commits behind `origin/main`. Active work is on `origin/main`.
- CLAUDE.md §3 env-var table omits `SMOLBSD_CLAUDE_MODEL` (present in coord-tick:237 and coord-dispatch:60). The git diff shows `CLAUDE.md` on HEAD is missing this row vs `origin/main`. **Stale on HEAD**.

### docs/PROJECT-LOG.md
- "What Is Running Now (as of 2026-05-04): aarch64 Screen session PID 15999" and "amd64 on Vultr provisioned (attempt 3); buildworld running". Both builds completed; `docs/PHASE-1-RESULTS.md` records results from 2026-05-07. The "running now" section is 12 days stale.
- "37 messages, tasks 0001–0014 + design D1–D3" — spool has likely grown since the log was written.

### docs/PHASE-1-RESULTS.md
- aarch64 qcow2 size is 1.41 GiB vs the ≤512 MiB gate. The report correctly marks this as a gap ("INVESTIGATING vs 512 MiB target") but `README.md` status table still lists "1.41 GiB (INVESTIGATING)" as of 2026-05-08 without resolution.
- amd64 gate: `CONDITIONAL_PASS` — login not reached within 480s. Result is recorded accurately but README says "KVM gate pending" implying work is still in flight when actually the attempt was made and the result was CONDITIONAL_PASS.

### docs/BUILDING.md
- No stale content found; all paths and commands match the current `bin/` tree.

---

## 6. CLAUDE.md FRESHNESS

Reading `CLAUDE.md` as a cold agent:

**Accurate**: §1 project description, §3 env-var table (on `main`; HEAD is missing `SMOLBSD_CLAUDE_MODEL`), §6 spool protocol, §7 HALT flow, §9 license.

**Misleading**:
- §2 Key files table omits `bin/coord-dispatch.nu`, `bin/coord-escalate.nu`, and the 20+ other `bin/` scripts added since the original write. A cold agent will not know these exist.
- §4 How to test: lists only `mbox-parse-test.nu` and `coord-tick-test.nu`. Does not mention `coord-escalate-test.nu`, `spool-*-test.nu`, `tpm-seal-test.nu`, or the FSM integration suite `coord-fsm-tests.nu` (which is NOT picked up by `run-all.sh` at all — orphaned test file).
- §8 Branch: says `claude/stoic-pascal-u6y3T` is active. PR #7 merged it to `main`; subsequent PRs (#8, #9, #10) also merged to `main`. The canonical branch is `main`.

---

## 7. THE BRANCH MODEL

- **`main`** (`origin/main`): current canonical branch. Latest commit: `533fdd5 fix(ci): wire tpm-vm-test to real scripts`. Includes merges from PRs #6–#10; most recent work is TPM CI/CD pipeline and spool tooling.
- **`claude/stoic-pascal-u6y3T`**: 4 commits behind `origin/main` (HEAD is on this branch detached). PR #7 merged it; it exists on the remote but is not the tip of `main`.
- **`HEAD` (detached at `9dfe023`)**: working tree. Two files modified vs `claude/stoic-pascal-u6y3T`: `bin/coord-tick.nu` (M) and `tests/coord-fsm-tests.nu` (M). These changes are NOT committed or on any branch.
- **No release tags** exist (`git tag` returns empty).
- **New contributor clone**: `git clone` gets `main` which is the correct state. However, a contributor reading `CLAUDE.md` is told `claude/stoic-pascal-u6y3T` is the active branch, which is wrong. There is no contributor guide beyond `CLAUDE.md` and `README.md`.
- **PRs after #7**: PRs #8 (blissful-shockley), #9 (dd/retry-as-role), #10 (blissful-shockley again) all merged to `main`. Multiple feature streams were developed in worktrees and merged. No tracking of open PRs from `git` commands alone; project appears to be in maintenance mode post-Phase-I rather than active feature development.

---

## 8. RECOMMENDED ACTIONS, RANKED

**1. Commit or stash the two uncommitted files on HEAD (immediate)**
`bin/coord-tick.nu` and `tests/coord-fsm-tests.nu` have local modifications that are not on any branch. If the working tree is cleared these changes are lost. Either commit to a branch or document that HEAD is intentionally floating. This is the only action with data-loss risk.
Files: `bin/coord-tick.nu`, `tests/coord-fsm-tests.nu`

**2. Fix `coord-escalate.nu` HALT marker to include `fallback_fired`/`fallback_status`** (correctness — §13 violation)
The standalone `coord-escalate.nu` writes a HALT marker without the two spec-required fields and does not invoke `try-irc-dm`. Add those fields (defaulting to `false`/`"not-attempted"`) and optionally call the IRC helper.
File: `bin/coord-escalate.nu:79–91`

**3. Update `CLAUDE.md` §8 branch and §4 test list** (misleads every cold agent)
Change §8 from `claude/stoic-pascal-u6y3T` to `main`. Add `SMOLBSD_CLAUDE_MODEL` to the env-var table (already on `main`, missing on HEAD). Expand §4 to list all 8 test suites. Note that `coord-fsm-tests.nu` exists but is not invoked by `run-all.sh`.
File: `CLAUDE.md`

**4. Extend FR and JA spec translations** (translation drift — covers 15% of the spec)
Both `mailbox-jec-handoff-design.fr.md` and `.ja.md` terminate after §4.1. They need §4.2 through §18 translated. Until then, a French- or Japanese-primary agent reading the spec will miss the entire retry policy, escalation protocol, and capability check sections.
Files: `docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.fr.md`, `.ja.md`

**5. Delete or annotate the three spec promises that have no implementation path** (spec debt)
The following spec text describes behavior that has no code and no near-term plan:
- §5 RTK: no `rtk` binary exists in the fleet; the compression layer is entirely notional.
- §7 `fleet-eval verify`: subagent claim verification is presence-only; `fleet-eval` subprocess is never invoked.
- §12 Fibonacci backoff scheduling: the decision table is implemented but the delay mechanism is not (no sleep between retries, no scheduled retry queue).

These should either be moved to a "future work" section (like §15 in the English spec) or struck with a `[NOT IMPLEMENTED]` annotation so a cold agent does not assume the behavior is live. Leaving them as asserted spec text causes agents to reason incorrectly about system behavior.
File: `docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md` §5, §7, §12 backoff paragraph

---

*End of reconciliation — 2026-05-16*
