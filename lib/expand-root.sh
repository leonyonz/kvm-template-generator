#!/usr/bin/env bash
# =====================================================================
# expand-root.sh — make the root filesystem actually USE the enlarged
# disk after virt-resize.
#
# Why: newer virt-resize fills leftover space with an EMPTY trailing
# partition instead of leaving it unallocated. Templates therefore rely
# on cloud-init growpart at deploy time — which can never work, because
# that filler partition occupies every byte behind the root partition
# ("NOCHANGE: partition N ... cannot be grown"). Deployed VMs stay at
# the base image's tiny root fs (~2GB) forever.
#
# What this does (offline, via libguestfs):
#   1. find the root filesystem (inspection)
#   2. delete EMPTY partitions located strictly AFTER the root partition
#   3. grow the root PARTITION into the freed/unallocated space
#      (only when nothing real lives behind it)
#   4. grow ext* filesystems offline (e2fsck + resize2fs);
#      other fs types (xfs/btrfs) are left to cloud-init resizefs,
#      which now succeeds because the partition is already full-size
#
# Usage: expand-root.sh <image.qcow2>
# Exit codes: 0 = ok (or nothing to do), 1 = hard error
# =====================================================================
set -euo pipefail

IMG="${1:?usage: expand-root.sh <image.qcow2>}"
export LIBGUESTFS_BACKEND=direct

command -v guestfish >/dev/null || { echo "expand-root: guestfish not found" >&2; exit 1; }
[[ -f "$IMG" ]] || { echo "expand-root: no such image: $IMG" >&2; exit 1; }

# ---- one persistent appliance for all calls -----------------------
eval "$(guestfish --listen -a "$IMG")"
G="guestfish --remote"
cleanup() { guestfish --remote exit >/dev/null 2>&1 || true; }
trap cleanup EXIT

$G run >/dev/null

# ---- locate the root filesystem ----------------------------------
root_fs="$($G inspect-os | head -n1)"
[[ -n "$root_fs" ]] || { echo "expand-root: no OS found in $IMG — skipping"; exit 0; }

# mountpoint list lines look like:  "/: /dev/sda4"
root_part="$($G inspect-get-mountpoints "$root_fs" \
    | awk -F': ' '$1=="/" {print $2}')"
[[ -n "$root_part" ]] || { echo "expand-root: cannot resolve / device — skipping"; exit 0; }

case "$root_part" in
    /dev/sd[a-z]*[0-9]|/dev/vd[a-z]*[0-9]) ;;          # plain partition: proceed
    *) echo "expand-root: root ($root_part) is not a plain partition (LVM?) — skipping"; exit 0 ;;
esac

disk="${root_part%[0-9]*}"
root_num="${root_part##*[!0-9]}"
sectsize="$($G blockdev-getss "$disk")"
total_sect=$(( $($G blockdev-getsize64 "$disk") / sectsize ))

# ---- inventory partitions from part-list --------------------------
# output blocks: "part_num: N" / "part_size: S"
declare -a AFTER_EMPTY=() AFTER_REAL=()
while read -r num size; do
    [[ -n "$num" ]] || continue
    if (( num > root_num )); then
        fstype="$($G vfs-type "${disk}${num}" 2>/dev/null | head -n1 || true)"
        if [[ -z "$fstype" ]]; then
            AFTER_EMPTY+=("$num")
        else
            AFTER_REAL+=("${num}:${fstype}")
        fi
    fi
done < <($G part-list "$disk" | awk '/part_num:/ {gsub(",",""); n=$2} /part_size:/ {print n, $2}')

echo "expand-root: disk=$disk root=$root_part total=${total_sect} sectors"

# ---- delete empty filler partitions after root --------------------
if ((${#AFTER_EMPTY[@]})); then
    echo "expand-root: deleting empty filler partition(s): ${AFTER_EMPTY[*]}"
    for p in "${AFTER_EMPTY[@]}"; do          # descending not required, but tidy
        $G part-del "$disk" "$p"
    done
fi

# ---- grow root partition (only if nothing real behind it) ---------
if ((${#AFTER_REAL[@]} == 0)); then
    # keep the GPT backup header area clear (33 sectors) + margin
    end_sect=$(( total_sect - 34 ))
    old_size="$($G part-list "$disk" | awk -v n="$root_num" '
        /part_num:/ {gsub(",",""); cur=($2==n)} cur && /part_size:/ {gsub(",",""); print $2}')"
    $G part-resize "$disk" "$root_num" "$end_sect"
    new_size=$(( (end_sect+1) * sectsize ))
    echo "expand-root: root partition grown: ${old_size} -> ${new_size} bytes"
else
    echo "expand-root: real partitions behind root (${AFTER_REAL[*]}) — partition left for deploy-time growpart"
fi

# ---- grow the filesystem itself -----------------------------------
fstype="$($G vfs-type "$root_part" 2>/dev/null | head -n1 || true)"
case "$fstype" in
    ext*)
        $G e2fsck-f "$root_part"
        $G resize2fs "$root_part"
        echo "expand-root: grew $fstype on $root_part to fill partition"
        ;;
    "")
        echo "expand-root: no filesystem signature on $root_part?! — skipping fs grow" >&2
        exit 1
        ;;
    *)
        echo "expand-root: $fstype on $root_part — left for cloud-init resizefs (partition already full size)"
        ;;
esac

exit 0
