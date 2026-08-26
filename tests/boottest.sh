#!/usr/bin/env bash
# =====================================================================
# tests/boottest.sh — boot a finished KVM template headlessly and report
# whether it boots without a kernel panic.
#
# Usage:
#   boottest.sh <image.qcow2> <logfile> [timeout_seconds]
#
# Exit codes (machine-readable):
#   0 = PASS            guest reached login / cloud-init finished, no panic
#   1 = INCONCLUSIVE    timed out before login, but no panic observed
#   2 = FAIL            kernel panic / oops detected
#   3 = NO_QEMU         qemu-system-x86_64 not installed
#
# Notes:
#   - Uses `-snapshot`: the master .qcow2 is NEVER modified.
#   - Uses KVM when /dev/kvm exists, otherwise falls back to TCG (slow).
#   - Monitors the serial log live and exits as soon as login or a panic
#     is detected (does not wait out the whole timeout on success).
# =====================================================================
set -uo pipefail

IMG="${1:?usage: boottest.sh <image.qcow2> <logfile> [timeout_s]}"
LOG="${2:?}"
TIMEOUT_S="${3:-1500}"

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

QEMU=""
for c in qemu-system-x86_64 /usr/libexec/qemu-kvm /usr/bin/qemu-kvm; do
    command -v "$c" >/dev/null 2>&1 && { QEMU="$c"; break; }
done
if [[ -z "$QEMU" ]]; then
    echo "NO_QEMU"
    exit 3
fi

ACCL=tcg; CPU=max
[[ -e /dev/kvm ]] && { ACCL=kvm; CPU=host; }

PANIC_RE='Kernel panic|Oops:|BUG:|general protection fault|KASAN:|Unable to handle kernel'
PASS_RE='login:|Cloud-init .*finished'

panic()  { grep -qiE "$PANIC_RE" "$LOG" 2>/dev/null; }
passed() { grep -qiE "$PASS_RE" "$LOG" 2>/dev/null; }

# run qemu in the background; watch the serial log until we know the answer
rm -f "$LOG"
# shellcheck disable=SC2086
timeout "$TIMEOUT_S" "$QEMU" -machine "pc,accel=${ACCL}" -cpu "$CPU" \
    -m 1024 -smp 2 \
    -snapshot \
    -drive "file=${IMG},format=qcow2,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -serial "file:${LOG}" >/dev/null 2>&1 &
QPID=$!

while kill -0 "$QPID" 2>/dev/null; do
    if panic; then
        kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
        echo "PANIC"; exit 2
    fi
    if passed; then
        kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
        echo "PASS"; exit 0
    fi
    sleep 2
done

# qemu exited on its own (timeout, or graceful shutdown) — final check
if panic; then          echo "PANIC";                  exit 2
elif passed; then       echo "PASS";                   exit 0
else                    echo "TIMEOUT_INCONCLUSIVE";   exit 1
fi
