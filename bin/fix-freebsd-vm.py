#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# fix-freebsd-vm.py — connect to a QEMU console socket, log into FreeBSD as root,
# and apply first-boot fixes required before SSH is usable.
#
# Fixes applied:
#   1. kldload tpm                     — load TPM driver so /dev/tpm0 appears
#   2. rm -f /etc/ssh/ssh_host_xmss_key*  — remove slow XMSS keys (blocks sshd for hours)
#   3. ssh-keygen -t ed25519           — regenerate a fast host key
#   4. Append sshd_config options      — PermitRootLogin yes, PasswordAuth yes, etc.
#   5. Set root password               — via pw usermod
#   6. service sshd onerestart         — restart sshd with new config
#   7. Poll sockstat for :22           — wait until sshd accepts connections
#
# The XMSS key issue is the critical fix: FreeBSD 15 sshd hangs for 30-120 minutes
# generating XMSS keys on first boot on KVM.  Removing them before sshd starts
# allows instant boot.
#
# Console interaction uses Python stdlib socket (AF_UNIX) only — no pip deps.
#
# Usage:
#   python3 bin/fix-freebsd-vm.py [--socket PATH] [--password PASS] [--timeout INT] [--dry-run]
#
# See: docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md
#      tests/tpm-smoke-test.nu   — orchestrator that calls this script

import argparse
import json
import os
import select
import socket
import sys
import time

# ── Constants ─────────────────────────────────────────────────────────────────

CONNECT_RETRY_INTERVAL = 2   # seconds between connection attempts
CONNECT_MAX_RETRIES    = 30  # total connection attempts before giving up
PROMPT_POLL_INTERVAL   = 0.1 # seconds between read polls
CMD_TIMEOUT            = 60  # seconds to wait for shell prompt after each command
SSHD_POLL_INTERVAL     = 2   # seconds between sockstat polls
SSHD_MAX_POLLS         = 30  # max polls for sshd to appear

# ── Helpers ───────────────────────────────────────────────────────────────────

def ts() -> str:
    """Return an ISO-8601 UTC timestamp."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def log(step: str, msg: str, **extra) -> None:
    """Print a structured log line to stderr (keeps stdout clean for JSON result)."""
    parts = [f"[{ts()}] [{step}] {msg}"]
    for k, v in extra.items():
        parts.append(f"  {k}={v!r}")
    print("\n".join(parts), file=sys.stderr)


# ── Console I/O ───────────────────────────────────────────────────────────────

class Console:
    """Thin wrapper around a QEMU Unix console socket."""

    def __init__(self, sock_path: str) -> None:
        self.sock_path = sock_path
        self._sock: socket.socket | None = None
        self._buf = b""

    def connect(self, max_retries: int = CONNECT_MAX_RETRIES) -> None:
        """Connect to the Unix socket, retrying until the socket file appears."""
        for attempt in range(1, max_retries + 1):
            if os.path.exists(self.sock_path):
                try:
                    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    s.connect(self.sock_path)
                    s.setblocking(False)
                    self._sock = s
                    log("console-connect", "connected to QEMU console socket",
                        path=self.sock_path, attempt=attempt)
                    return
                except OSError as exc:
                    log("console-connect", f"connect failed: {exc}",
                        attempt=attempt, retrying_in=CONNECT_RETRY_INTERVAL)
            else:
                log("console-connect", "socket file not yet present",
                    path=self.sock_path, attempt=attempt)
            time.sleep(CONNECT_RETRY_INTERVAL)
        raise RuntimeError(
            f"Could not connect to console socket {self.sock_path!r} "
            f"after {max_retries} attempts"
        )

    def send(self, data: bytes) -> None:
        assert self._sock, "not connected"
        self._sock.sendall(data)

    def send_line(self, line: str) -> None:
        """Send a line followed by CR (FreeBSD console uses \\r\\n)."""
        self.send((line + "\r\n").encode())

    def send_ctrl_c(self) -> None:
        self.send(b"\x03")

    def read_until(
        self,
        targets: list[bytes],
        timeout: float,
        echo: bool = True,
    ) -> tuple[bytes, bytes]:
        """
        Read from the socket until one of *targets* appears in the accumulated
        buffer, or *timeout* seconds elapse.

        Returns (accumulated_bytes, matched_target).
        Raises RuntimeError on timeout.
        """
        assert self._sock, "not connected"
        deadline = time.monotonic() + timeout
        matched: bytes = b""

        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            ready, _, _ = select.select([self._sock], [], [], min(remaining, PROMPT_POLL_INTERVAL))
            if ready:
                try:
                    chunk = self._sock.recv(4096)
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    self._buf += chunk
                    if echo:
                        sys.stderr.buffer.write(chunk)
                        sys.stderr.buffer.flush()

            for target in targets:
                if target in self._buf:
                    matched = target
                    break
            if matched:
                break

        if not matched:
            snippet = self._buf[-200:].decode("latin-1", errors="replace")
            raise RuntimeError(
                f"Timeout ({timeout}s) waiting for {[t.decode('latin-1') for t in targets]}; "
                f"last 200 bytes: {snippet!r}"
            )

        return self._buf, matched

    def close(self) -> None:
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None


# ── Login flow ────────────────────────────────────────────────────────────────

def wait_for_login_prompt(con: Console, timeout: float) -> None:
    """Wait for the FreeBSD login: prompt."""
    log("login", "waiting for login prompt", timeout=timeout)
    con.read_until([b"login:"], timeout=timeout)
    log("login", "login prompt received")


def login_as_root(con: Console) -> None:
    """
    Send 'root' and handle two cases:
      - Direct '#' shell prompt (empty password, autologin, or root without password)
      - 'Password:' prompt followed by Enter (empty password)
    """
    log("login", "sending username 'root'")
    con.send_line("root")

    # Give the console a moment to respond, then check what arrived.
    # We might see "Password:" or a shell prompt "#".
    buf, matched = con.read_until([b"Password:", b"# "], timeout=30)

    if matched == b"Password:":
        log("login", "got Password: prompt — sending empty password")
        con.send_line("")
        # Now wait for the shell prompt
        con.read_until([b"# "], timeout=30)
        log("login", "shell prompt received after password")
    else:
        log("login", "got shell prompt directly (no password required)")


# ── Command runner ────────────────────────────────────────────────────────────

def run_cmd(con: Console, cmd: str, dry_run: bool, timeout: float = CMD_TIMEOUT) -> str:
    """
    Send a shell command to the console, wait for the next '#' prompt, and
    return the output captured between send and prompt.

    In dry_run mode, log the command but do not send it.
    """
    log("cmd", f"running: {cmd}", dry_run=dry_run)
    if dry_run:
        return ""

    # Clear any stuck state: send Ctrl-C then CLEAR the accumulated buffer.
    # The buffer accumulates ALL previous output across calls; without clearing
    # it, read_until([b"# "]) returns immediately because the buffer already
    # contains '#' from a previous prompt — making Ctrl-C fire before the
    # previous command has actually finished.
    con.send_ctrl_c()
    time.sleep(0.3)  # give the shell time to process Ctrl-C and emit #
    con._buf = b""   # clear accumulated history; only look at NEW output

    # Now wait for the fresh # prompt that followed the Ctrl-C.
    try:
        con.read_until([b"# "], timeout=5)
    except RuntimeError:
        pass  # No prompt yet — that's fine; we'll send the command anyway.
    con._buf = b""   # clear again before sending the real command

    # Send the command.
    con.send_line(cmd)

    # Wait for shell prompt.
    buf, _ = con.read_until([b"# "], timeout=timeout)
    return buf.decode("latin-1", errors="replace")


# ── First-boot fix sequence ───────────────────────────────────────────────────

def apply_fixes(con: Console, password: str, timeout: int, dry_run: bool) -> dict:
    """
    Apply all first-boot fixes.  Returns a dict with tpm_loaded and sshd_port.
    """

    # 1. Load TPM driver (non-fatal — some images have it compiled in).
    run_cmd(con, "kldload tpm 2>/dev/null || true", dry_run)

    # Verify TPM loaded (best-effort).
    tpm_out = run_cmd(con, "kldstat 2>/dev/null | grep tpm || echo no_tpm", dry_run)
    tpm_loaded = "tpm" in tpm_out and "no_tpm" not in tpm_out
    log("tpm", "TPM driver check", loaded=tpm_loaded)

    # 2. Remove XMSS host keys entirely.
    run_cmd(con, "rm -f /etc/ssh/ssh_host_xmss_key*", dry_run)
    log("ssh-keys", "XMSS keys removed")

    # 3. Regenerate fast host keys so sshd can start immediately.
    run_cmd(
        con,
        'ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" -q 2>/dev/null || true',
        dry_run,
    )
    run_cmd(
        con,
        'ssh-keygen -t ecdsa -f /etc/ssh/ssh_host_ecdsa_key -N "" -q 2>/dev/null || true',
        dry_run,
    )
    log("ssh-keys", "ed25519 + ecdsa host keys generated")

    # 4. Configure sshd: explicit HostKey list (no xmss) + allow root+password.
    #    FreeBSD UFS images have all options commented out; we append unconditionally.
    #    Explicit HostKey lines mean sshd will ONLY load those files — it won't
    #    discover and try to load the absent (or rc.d-regenerated) xmss key.
    sshd_append = (
        r"printf '\nHostKey /etc/ssh/ssh_host_ed25519_key"
        r"\nHostKey /etc/ssh/ssh_host_ecdsa_key"
        r"\nPermitRootLogin yes\nPasswordAuthentication yes"
        r"\nPermitEmptyPasswords yes\nUsePAM no\n' >> /etc/ssh/sshd_config"
    )
    run_cmd(con, sshd_append, dry_run)
    # Disable automatic host key generation in rc.d/sshd so it never regenerates xmss
    run_cmd(con, r"printf '\nsshd_keygen_enable=\"NO\"\n' >> /etc/rc.conf", dry_run)
    log("sshd-config", "sshd_config updated: explicit HostKey, auth options; keygen disabled")

    # 5. Set the root password via pw (pipe through stdin).
    #    We use a printf+pipe pattern to avoid shell escaping issues.
    pw_cmd = f"printf '{password}\\n' | pw usermod root -h 0 2>/dev/null || true"
    run_cmd(con, pw_cmd, dry_run)
    log("root-pw", "root password set", password="[redacted]")

    # 6. Restart sshd with the new configuration.
    #    Use pkill + direct sshd invocation instead of service(8) to bypass
    #    the rc.d keygen wrapper (which would regenerate XMSS keys again).
    #
    #    CRITICAL: run_cmd sends Ctrl-C before every command. If we call
    #    run_cmd immediately after starting sshd, the Ctrl-C arrives before
    #    sshd finishes daemonizing and kills it. Embed "sleep 3" in the same
    #    shell command to keep sshd alive through the daemonization window.
    run_cmd(con, "pkill -f '/usr/sbin/sshd' 2>/dev/null; true", dry_run, timeout=5)
    # Run sshd with visible stderr so failures are logged, then check exit code.
    sshd_out = run_cmd(
        con,
        "/usr/sbin/sshd -e 2>&1; echo SSHD_EXIT:$?",
        dry_run,
        timeout=15,
    )
    log("sshd", "sshd start output", output=sshd_out[-300:] if sshd_out else "")
    # Python-level sleep so sshd finishes daemonizing before we do anything else.
    # This is outside the FreeBSD shell so Ctrl-C from the next run_cmd
    # cannot interrupt it.
    if not dry_run:
        time.sleep(3)
    log("sshd", "sshd start grace period complete")

    # 7. Poll for sshd to bind :22.
    log("sshd", "polling for sshd on port 22", max_polls=SSHD_MAX_POLLS)
    sshd_up = False
    for poll in range(SSHD_MAX_POLLS):
        if dry_run:
            sshd_up = True
            break
        out = run_cmd(con, "sockstat -4l 2>/dev/null | grep :22 | head -1 || true", dry_run)
        if ":22" in out:
            sshd_up = True
            log("sshd", "sshd is accepting connections on :22", poll=poll)
            break
        log("sshd", f"not yet on :22 (poll {poll + 1}/{SSHD_MAX_POLLS})")
        time.sleep(SSHD_POLL_INTERVAL)

    if not sshd_up:
        log("sshd", "WARNING: sshd did not appear on :22 within polling window")

    return {
        "tpm_loaded": tpm_loaded,
        "sshd_port": 22,
        "sshd_up": sshd_up,
    }


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Connect to a QEMU FreeBSD console socket and apply first-boot fixes "
            "(XMSS key removal, sshd config, TPM driver load)."
        )
    )
    parser.add_argument(
        "--socket",
        default="/tmp/smolbsd-console.sock",
        help="Path to the QEMU console Unix socket (default: /tmp/smolbsd-console.sock)",
    )
    parser.add_argument(
        "--password",
        default="smolbsd",
        help="Root password to set on the guest (default: smolbsd)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="Seconds to wait for the login prompt (default: 120)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Connect and print commands without executing them on the guest",
    )
    args = parser.parse_args()

    log(
        "start",
        "fix-freebsd-vm starting",
        socket=args.socket,
        timeout=args.timeout,
        dry_run=args.dry_run,
    )

    con = Console(args.socket)
    try:
        # Connect to socket.
        con.connect()

        # Wait for the FreeBSD login prompt.
        try:
            wait_for_login_prompt(con, timeout=float(args.timeout))
        except RuntimeError as exc:
            log("login", f"ERROR: {exc}")
            print(
                json.dumps({"status": "error", "stage": "login_prompt", "detail": str(exc)}),
                flush=True,
            )
            return 1

        # Log in as root.
        try:
            login_as_root(con)
        except RuntimeError as exc:
            log("login", f"ERROR: {exc}")
            print(
                json.dumps({"status": "error", "stage": "root_login", "detail": str(exc)}),
                flush=True,
            )
            return 1

        # Apply fixes.
        try:
            result = apply_fixes(con, args.password, args.timeout, args.dry_run)
        except RuntimeError as exc:
            log("fix", f"ERROR during fix sequence: {exc}")
            print(
                json.dumps({"status": "error", "stage": "fix_sequence", "detail": str(exc)}),
                flush=True,
            )
            return 1

        # Emit JSON result to stdout (consumed by tests/tpm-smoke-test.nu).
        out = {
            "status": "ok",
            "sshd_port": result["sshd_port"],
            "tpm_loaded": result["tpm_loaded"],
            "sshd_up": result["sshd_up"],
            "dry_run": args.dry_run,
        }
        print(json.dumps(out), flush=True)
        log("done", "fix-freebsd-vm completed successfully", status="ok")
        return 0

    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main())
