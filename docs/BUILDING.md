# Building smolBSD

One command builds the complete smolBSD qcow2 image from a clean FreeBSD source tree.

## Prerequisites

- FreeBSD 15 aarch64 host (the `fbuild` VM on `minim4-24`, or any FreeBSD aarch64 box)
- At least 50 GiB free in `/usr/obj` (buildworld fills ~18–40 GiB; allow headroom)
- At least 3 GiB free after buildworld completes (vm-image needs room for artifacts)
- Root access — `make release` and `make vm-image` both require a chroot
- `/usr/src` checked out at `releng/15.0`:
  ```sh
  git clone -b releng/15.0 https://git.freebsd.org/src.git /usr/src
  ```
- Nushell 0.111.0 or later: `pkg install nushell`

## Step 0 — Preflight check (no writes, no builds)

Run this first. It checks root, disk space, source tree, kernel config, and
`/etc/src.conf` without making any changes:

```sh
sudo nu bin/build-smolbsd.nu --check
```

Fix any reported ERRORs before proceeding. WARNINGs about missing kernel configs
or `/etc/src.conf` are auto-resolved by the setup phase.

## Step 1 — Full build

```sh
sudo nu bin/build-smolbsd.nu
```

This runs the complete pipeline in order:

1. Setup — writes `/etc/src.conf`, sets git `safe.directory`, installs kernel
   configs and release conf into `/usr/src` if missing
2. `buildworld` (the long step — 1–3 h depending on hardware)
3. `buildkernel KERNCONF=SMOLBSD`
4. Kernel obj cleanup — frees 4–6 GiB before vm-image
5. `make vm-image` — produces the qcow2 artifact

Build output streams to `/var/tmp/smolbsd-build.log`. Watch progress with:

```sh
tail -f /var/tmp/smolbsd-build.log
```

## Step 2 — Where the qcow2 ends up

```
/usr/obj/usr/src/arm64.aarch64/release/vm/FreeBSD-15*SMOLBSD*.qcow2
```

The script prints the exact path, size, sha256, and elapsed time on completion.

## Partial runs

If buildworld already completed and the obj tree is intact:

```sh
sudo nu bin/build-smolbsd.nu --skip-buildworld
```

If you only want buildworld + buildkernel and not the image yet:

```sh
sudo nu bin/build-smolbsd.nu --skip-release
```

## amd64 cross-compile

On an aarch64 host, build the amd64 image with:

```sh
sudo nu bin/build-smolbsd.nu --arch amd64
```

This sets `TARGET=amd64 TARGET_ARCH=amd64` for all make invocations.

## Testing the image

After a successful build, run the acceptance suite:

```sh
# Boot timing gate (aarch64 — expects HVF on Apple Silicon)
expect tests/time-to-ready-arm64.exp

# Full test runner
nu tests/run-tests.nu --suite e2e
```

## Hard-won fixes encoded in the pipeline

These are the Phase I lessons that silently break a naive build:

| Fix | What breaks without it |
|-----|------------------------|
| `/etc/src.conf` with `WITHOUT_SENDMAIL=yes` | `freebsd.cf` install fails, cascades through 8 make levels |
| `WITHOUT_DEPEND_FILES=yes` | Bad substitution from `bsd.dep.mk` in LLVM builds |
| Run `vm-image` as root | Empty pkgbase produced silently |
| `VMSIZE=2g` | 4g default needs 4+ GiB of free disk |
| Kernel obj cleanup before `vm-image` | May exhaust disk mid-release |
| `git config safe.directory /usr/src` | Release make fails on git version check |
| Disk check before starting | Late failure after hours of build time |
| Gated pipeline (abort on any stage failure) | Release starts after failed buildworld |
