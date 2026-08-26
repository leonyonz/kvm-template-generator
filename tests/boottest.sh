#!/usr/bin/env bash
# =====================================================================
# tests/boottest.sh — boot a finished KVM template headlessly and report
# whether it boots cleanly.
#
# Usage:
#   boottest.sh <image.qcow2> <logfile> [timeout_seconds]
#
# Exit codes (machine-readable):
#   0 = PASS            guest reached login / cloud-init finished, no panic
#   1 = INCONCLUSIVE    timed out before login, but no failure observed
#   2 = FAIL            kernel panic / oops, OR GRUB bootloader failure
#   3 = NO_QEMU         qemu-system-x86_64 not installed
#
# Notes:
#   - Uses `-snapshot`: the master .qcow2 is NEVER modified.
#   - Uses KVM when /dev/kvm exists, otherwise falls back to TCG (slow).
#   - Uses `-nographic` (not `-display none`): SeaBIOS then mirrors the VGA
#     text console to serial, so GRUB errors ("error: no such partition",
#     grub rescue) become visible in the serial log and are reported as FAIL.
#     With `-display none` those failures were invisible -> inconclusive.
#   - Monitors the serial log live and exits as soon as login, a panic or a
#     bootloader error is detected (does not wait out the whole timeout).
# =====================================================================
set -uo pipefail

IMG="${1:?usage: boottest.sh <image.qcow2> <logfile> [timeout_s]}"
LOG="${2:?}"
TIMEOUT_S="${3:-1500}"

# resolve to absolute paths BEFORE the cd below (relative paths would
# otherwise break once we chdir into the project root)
IMG="$(readlink -f "$IMG")"
LOG="$(readlink -f "$LOG")"

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
# GRUB failures happen BEFORE the kernel starts (no panic on serial) and
# historically were invisible on serial — see -nographic note above.
GRUB_RE='error: no such partition|error: unknown filesystem|error: disk |error: file .* not found|Entering rescue mode|grub rescue>'

panic()  { grep -qiE "$PANIC_RE" "$LOG" 2>/dev/null; }
grubfail() { grep -qiE "$GRUB_RE" "$LOG" 2>/dev/null; }
passed() { grep -qiE "$PASS_RE" "$LOG" 2>/dev/null; }

# run qemu in the background; watch the serial log until we know the answer
rm -f "$LOG"
# -nographic: SeaBIOS mirrors VGA text (SeaBIOS + GRUB messages) to serial;
# -monitor none: keep the QEMU monitor off stdio; serial goes to the log file.
timeout "$TIMEOUT_S" "$QEMU" -machine "pc,accel=${ACCL}" -cpu "$CPU" \
    -m 1024 -smp 2 \
    -snapshot \
    -drive "file=${IMG},format=qcow2,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -nographic -monitor none -serial "file:${LOG}" >/dev/null 2>"${LOG}.qemu.err" &
QPID=$!

while kill -0 "$QPID" 2>/dev/null; do
    if grubfail; then
        kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
        echo "GRUB_FAIL"; exit 2
    fi
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
if grubfail; then       echo "GRUB_FAIL";              exit 2
elif panic; then        echo "PANIC";                  exit 2
elif passed; then       echo "PASS";                   exit 0
else                    echo "TIMEOUT_INCONCLUSIVE";   exit 1
fi
