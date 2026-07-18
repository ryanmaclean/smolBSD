#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# setup-runner.sh — Register <kvm-host> as a GitHub Actions self-hosted runner
#                   for ryanmaclean/smolBSD.
#
# Usage (env vars):
#   GITHUB_RUNNER_TOKEN=<token> sh bin/setup-runner.sh
#
# Usage (positional args, all optional — override defaults):
#   sh bin/setup-runner.sh <token> [runner-name] [labels]
#
# Required:
#   GITHUB_RUNNER_TOKEN  — registration token from:
#                          GitHub → repo → Settings → Actions → Runners → New runner
#
# Optional:
#   RUNNER_NAME    — default: <kvm-host>-amd64
#   RUNNER_LABELS  — default: self-hosted,linux,amd64,kvm
#
# Runner version pinned to a known-good release (Apache-2.0 / MIT licensed).
# The actions/runner project is MIT-licensed; see:
#   https://github.com/actions/runner/blob/main/LICENSE

set -eu

RUNNER_VERSION="2.321.0"
RUNNER_ARCHIVE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"
RUNNER_HASH_URL="${RUNNER_URL}.sha256"

REPO_URL="https://github.com/ryanmaclean/smolBSD"

# ── Parse arguments ────────────────────────────────────────────────────────────

TOKEN="${1:-${GITHUB_RUNNER_TOKEN:-}}"
NAME="${2:-${RUNNER_NAME:-smolbsd-kvm-amd64}}"
LABELS="${3:-${RUNNER_LABELS:-self-hosted,linux,amd64,kvm}}"

if [ -z "$TOKEN" ]; then
  echo "ERROR: GITHUB_RUNNER_TOKEN is required." >&2
  echo "" >&2
  echo "Get a token from:" >&2
  echo "  https://github.com/ryanmaclean/smolBSD/settings/actions/runners/new" >&2
  echo "" >&2
  echo "Then run:" >&2
  echo "  GITHUB_RUNNER_TOKEN=<token> sh bin/setup-runner.sh" >&2
  exit 1
fi

# ── Preflight checks ───────────────────────────────────────────────────────────

echo "==> Checking prerequisites ..."

for cmd in curl tar sudo systemctl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
done

if [ ! -c /dev/kvm ]; then
  echo "WARNING: /dev/kvm not found — KVM label will be present but hardware may not support acceleration." >&2
fi

# ── Create runner directory ────────────────────────────────────────────────────

RUNNER_DIR="$HOME/actions-runner"

echo "==> Creating runner directory: $RUNNER_DIR"
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

# ── Download runner ────────────────────────────────────────────────────────────

echo "==> Downloading runner v${RUNNER_VERSION} ..."
curl -fsSL --retry 3 --retry-delay 5 \
  -o "$RUNNER_ARCHIVE" \
  "$RUNNER_URL"

# Verify checksum
echo "==> Verifying checksum ..."
EXPECTED_HASH=$(curl -fsSL "$RUNNER_HASH_URL" | awk '{print $1}')
ACTUAL_HASH=$(sha256sum "$RUNNER_ARCHIVE" | awk '{print $1}')

if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
  echo "ERROR: checksum mismatch!" >&2
  echo "  Expected: $EXPECTED_HASH" >&2
  echo "  Actual:   $ACTUAL_HASH" >&2
  rm -f "$RUNNER_ARCHIVE"
  exit 1
fi
echo "    Checksum OK: $ACTUAL_HASH"

# ── Extract ────────────────────────────────────────────────────────────────────

echo "==> Extracting runner ..."
tar -xzf "$RUNNER_ARCHIVE"
rm -f "$RUNNER_ARCHIVE"

# ── Configure ─────────────────────────────────────────────────────────────────

echo "==> Configuring runner ..."
echo "    URL:    $REPO_URL"
echo "    Name:   $NAME"
echo "    Labels: $LABELS"

./config.sh \
  --url "$REPO_URL" \
  --token "$TOKEN" \
  --name "$NAME" \
  --labels "$LABELS" \
  --work "_work" \
  --unattended

# ── Install as systemd service ─────────────────────────────────────────────────

RUNNER_USER="${SUDO_USER:-$(whoami)}"

echo "==> Installing systemd service (user: $RUNNER_USER) ..."
sudo ./svc.sh install "$RUNNER_USER"

echo "==> Starting runner service ..."
sudo ./svc.sh start

# ── Verify service is running ──────────────────────────────────────────────────

echo "==> Verifying service status ..."
# Service name format from actions/runner: actions.runner.<owner>-<repo>.<name>
SVC_NAME="actions.runner.ryanmaclean-smolBSD.${NAME}"
if systemctl is-active --quiet "$SVC_NAME" 2>/dev/null; then
  echo "    Service active: $SVC_NAME"
else
  # Fall back to showing any actions runner service
  systemctl --no-pager status "actions.runner.*" 2>/dev/null || true
  echo "    (Check 'systemctl status actions.runner.*' if not active)"
fi

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "Runner registered."
echo ""
echo "View at: https://github.com/ryanmaclean/smolBSD/settings/actions/runners"
echo ""
echo "To check logs:  journalctl -u '${SVC_NAME}' -f"
echo "To stop:        sudo systemctl stop '${SVC_NAME}'"
echo "To unregister:  cd $RUNNER_DIR && sudo ./svc.sh stop && sudo ./svc.sh uninstall && ./config.sh remove --token <token>"
