# Security Incident Report — 2026-05-16

## WHAT LEAKED

`var/mail/spool` was committed to git history across **51 commits** spanning all branches on the public GitHub repo `github.com/ryanmaclean/smolBSD`.

### Specific exposed data (all now redacted from rewritten history):

| Type | Value | Exposure |
|---|---|---|
| Vultr instance UUID | `0c7c4607-e05c-4d6e-864d-6b846b9703cc` | Instance with `terminate_cmd` in spool |
| Vultr instance UUID | `171abe56-fd68-4041-9376-9f235d9b9775` | Second instance ID |
| Vultr SSH key UUID | `5518413b-0d1c-4d16-a858-40e172586380` | `mbp-m1-ed25519` key |
| Public IP | `107.191.39.47` | Vultr amd64 instance main IP |
| Tailscale IP | `<tailscale-ip>` | `minim4-16` jump host |
| Tailscale IP | `<jump-host>` | SSH jump host in harvest commands |
| Vultr API key | `REDACTED-VULTR-API-KEY` | Found in live spool on disk — **ROTATE IMMEDIATELY** |

Additional files in committed history also contained the above UUIDs/IPs:
- `bin/vultr-bhyve-provision.nu` — hardcoded SSH key UUID `5518413b`
- `docs/PROJECT-LOG.md` — instance UUIDs and IPs in run log entries
- `docs/PRIVACY-CI-AUDIT.md` — security audit listing all leaked values
- `README.md` — instance UUIDs/IPs in build log sections

All of these were scrubbed in the rewrite.

---

## ACTIONS TAKEN

All times UTC 2026-05-16.

**~20:33** — Safety snapshot created:
- Tags: `pre-filter-repo-backup-20260516T203326Z`, `pre-filter-repo-backup-main-20260516T203326Z`, `pre-filter-repo-backup-branch-20260516T203326Z`
- Snapshot file: `/tmp/smolBSD-rewrite-snapshot.txt`
- Pre-rewrite HEAD: `9dfe02339acfd935710e0a05b501c847c6f17bab`
- Pre-rewrite `main`: `533fdd54b7df1a696443476d1f4f554167debaa5`
- Pre-rewrite `claude/stoic-pascal-u6y3T`: `0d98a4c6d7095b7338812ab9f9ffec3d365947e0`

**~20:33** — Scope verified: `git log --all --oneline -- var/mail/spool` returned 51 commits. File currently gitignored (`.gitignore:6`) but present on disk.

**~20:36** — Mirror clone created: `git clone --no-local --mirror /Users/studio/smolBSD /tmp/smolBSD-rewrite-mirror`

**~20:37** — `git filter-repo` run on copy of mirror:
```
git filter-repo --path var/mail/spool --invert-paths \
  --replace-text /tmp/replacements.txt --force
```
Replacements applied:
- `0c7c4607-e05c-4d6e-864d-6b846b9703cc` → `REDACTED-VULTR-UUID-1`
- `171abe56-fd68-4041-9376-9f235d9b9775` → `REDACTED-VULTR-UUID-2`
- `5518413b-0d1c-4d16-a858-40e172586380` → `REDACTED-VULTR-SSH-KEY-UUID`
- `5518413b` (short prefix) → `REDACTED-VULTR-SSH-KEY-UUID-PREFIX`
- `107.191.39.47` → `REDACTED-VULTR-IP`

**~20:38** — Verification: `git log --all --oneline -- var/mail/spool` returned 0; `git grep` for all UUIDs/IPs returned 0 matches.

**~20:40** — Force-pushed all 6 GitHub branches:
- `main`: `533fdd54` → `2bf062b6`
- `claude/stoic-pascal-u6y3T`: `0d98a4c6` → `d0c76684`
- `claude/blissful-shockley-eeb73b`: `28a35848` → `27a4ddf8`
- `dd/4gOFnWWqEYmR`: `b0a6f560` → `ec9b0b0d`
- `dd/PbasTmmCTFkL`: `ba36d52f` → `b2ed0c0e`
- `dd/init-prd-and-progress-tracking`: `88751f08` → `582e778e`

All pushes used `--force-with-lease`.

**~20:42** — Working repo synced:
- Stashed dirty state (`pre-rewrite-stash`)
- `git fetch origin --tags` + `git reset --hard origin/claude/stoic-pascal-u6y3T`
- Stash popped; `docs/PRIVACY-CI-AUDIT.md` merge conflict resolved by keeping rewritten (redacted) version

**~20:45** — Pre-push hook installed:
- `.git/hooks/pre-push` (mode 0755) — runs `nu bin/pre-push-check.nu`
- `bin/pre-push-check.nu` fixed (pre-existing Nushell `find` bug replaced with `=~` regex operator)
- `bin/setup-hooks.nu` created — installs hook for future clones
- `CLAUDE.md` updated with hook installation instructions (§9)

**~20:47** — GitHub verification: `curl -sI https://raw.githubusercontent.com/ryanmaclean/smolBSD/main/var/mail/spool` → **HTTP 404**

---

## CURRENT STATE

| Item | Status |
|---|---|
| GitHub `main` branch | Clean — spool absent, UUIDs/IPs redacted |
| GitHub `claude/stoic-pascal-u6y3T` | Clean |
| GitHub `claude/blissful-shockley-eeb73b` | Clean |
| GitHub `dd/*` branches (3) | Clean |
| Working repo (`/Users/studio/smolBSD`) | Synced to rewritten history; live spool on disk still contains original data (gitignored) |
| Pre-push hook | Installed and verified working |
| Gitea (`gitea/main`, `gitea/claude/blissful-shockley-eeb73b`) | **NOT yet force-pushed** — private Gitea at `i9-zfs-pop:3001`; lower urgency than public GitHub but should be updated |

### Residual exposure — GitHub PR refs

GitHub stores PR head refs (`refs/pull/*/head`) that still point to pre-rewrite commit objects. These objects remain reachable via GitHub's internal object store until GitHub GC purges them. Affected PRs: #1–#17.

**Required follow-up:** Contact GitHub Support at https://support.github.com and request a git garbage collection / object cache flush for `ryanmaclean/smolBSD`. Reference the force-push timestamps (~20:40 UTC 2026-05-16). Until this is done, someone who knows the old commit SHAs could still retrieve the spool content from GitHub's API.

### Vultr API key in live spool

The live `var/mail/spool` on disk (gitignored) contains a Vultr API key at line 3114:
```
VULTR_API_KEY found in /root/.dd_keys (BTA56PEJBU6CIDUTVAAYTS64HB4SGFZ7FQ6Q)
```
This key was captured during a harvest command and recorded in a claims block. **This key must be rotated in the Vultr dashboard regardless of instance termination.** The key controls the entire Vultr account.

---

## PREVENTION

1. **Pre-push hook** — `.git/hooks/pre-push` now blocks any push that would include spool content with public IPs or UUIDs. The hook fires before bytes leave the machine.

2. **`bin/setup-hooks.nu`** — one-command hook installer for fresh clones. Documented in `CLAUDE.md §9`.

3. **`.gitignore`** — `var/mail/spool` has been gitignored since commit `1e5cee9` (already in place before this incident). The pre-push hook adds a second enforcement layer.

4. **`bin/pre-push-check.nu`** — fixed Nushell compatibility bug (replaced `find --regex` with `=~` operator); now correctly scans the spool for public IPs, UUIDs, and API keys.

---

## FOLLOW-UPS

| Action | Owner | Status |
|---|---|---|
| Rotate Vultr SSH key `5518413b` (mbp-m1-ed25519) | Ryan MacLean | Rotation confirmed out-of-band per task brief |
| Terminate Vultr instances `171abe56`, `0c7c4607` | Ryan MacLean | Termination confirmed out-of-band per task brief |
| **Rotate Vultr API key `BTA56PEJBU6CIDUTVAAYTS64HB4SGFZ7FQ6Q`** | Ryan MacLean | **OUTSTANDING** — key found in live spool, not mentioned in original brief |
| Contact GitHub Support to flush object cache / PR refs | Ryan MacLean | Outstanding |
| Force-push rewritten history to Gitea (`i9-zfs-pop:3001`) | Ryan MacLean | Outstanding |
| Clear or redact live `var/mail/spool` on disk | Ryan MacLean | Outstanding — spool is gitignored but still contains raw secrets |
