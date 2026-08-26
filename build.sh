#!/usr/bin/env bash
# =====================================================================
# template-generator — build minimal KVM templates for Proxmox & CloudStack
#
# Distros : Ubuntu / Debian / Rocky / AlmaLinux (official cloud images)
# Standard: minimal image + private mirror + CVE patch (kernel/openssh)
#           + qemu-guest-agent + CloudStack password agent + clean logs
#           + BIOS boot + serial console
#
# Method  : libguestfs offline customization (no installer boot needed,
#           works even on hosts without nested KVM)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
template-generator — build KVM templates for Proxmox & CloudStack

Usage:
  ./build.sh -d <distro> [-v <version>] [options]

Required:
  -d, --dist DIST        ubuntu | debian | rocky | almalinux

Options:
  -v, --version VER      distro version (default: latest supported)
      --disk-size SIZE   final disk size          (default: ${DISK_SIZE:-10G})
  -o, --out-dir DIR      output directory         (default: ${OUTPUT_DIR:-./output})
      --cache-dir DIR    image cache directory    (default: ${CACHE_DIR:-./cache})
      --no-patch         skip targeted kernel/openssh CVE patching
      --full-update      full distro upgrade instead of targeted patch
      --no-repo          keep upstream repos (do NOT switch to mirror)
      --test             boot-smoke-test the result with qemu (slow w/o KVM)
      --keep-work        keep temporary working dir for debugging
      --list             show supported distros/versions and exit
  -h, --help             this help
EOF
}

DIST="" VER="" LIST_ONLY=0 NO_PATCH=0 NO_REPO=0 TEST=0 KEEP_WORK=0
OUT_DIR=""; CACHE_DIR=""; DISK_SIZE_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dist)        DIST="$2"; shift 2 ;;
        -v|--version)     VER="$2"; shift 2 ;;
        --disk-size)      DISK_SIZE_ARG="$2"; shift 2 ;;
        -o|--out-dir)     OUT_DIR="$2"; shift 2 ;;
        --cache-dir)      CACHE_DIR="$2"; shift 2 ;;
        --no-patch)       NO_PATCH=1; shift ;;
        --full-update)    FULL_UPDATE=1; shift ;;
        --no-repo)        NO_REPO=1; shift ;;
        --test)           TEST=1; shift ;;
        --keep-work)      KEEP_WORK=1; shift ;;
        --list)           LIST_ONLY=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

# ------------------------------------------------------------------ setup
source "${SCRIPT_DIR}/config/defaults.conf"
source "${SCRIPT_DIR}/lib/common.sh"

[[ $EUID -eq 0 ]] || warn "not running as root — guestfs operations usually require root"

if [[ $LIST_ONLY == 1 ]]; then
    echo "Supported distros/versions:"
    for f in "${SCRIPT_DIR}"/distros/*.sh; do
        # shellcheck disable=SC1090
        source "$f"
        printf '  %-10s %s\n' "$DISTRO_ID" "${SUPPORTED_VERSIONS[*]}"
    done
    exit 0
fi

[[ -n "$DIST" ]] || { usage >&2; echo; die "--dist is required"; }
MODULE="${SCRIPT_DIR}/distros/${DIST}.sh"
[[ -f "$MODULE" ]] || die "unknown distro '$DIST' — run ./build.sh --list"

DISK_SIZE="${DISK_SIZE_ARG:-$DISK_SIZE}"
OUT_DIR="${OUT_DIR:-$OUTPUT_DIR}"
CACHE_DIR="${CACHE_DIR:-$CACHE_DIR}"

require_cmds curl qemu-img virt-resize virt-customize virt-sysprep awk

# shellcheck disable=SC1090
source "$MODULE"   # provides resolve_image, customize_repos/pkgs/patch/full_update

export LIBGUESTFS_BACKEND=direct

VC_ARGS=()
STAMP="$(date +%Y%m%d-%H%M)"
WORK_DIR=""
cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" && $KEEP_WORK == 0 ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# ------------------------------------------------------- base customization
base_customize() {
    local A="${SCRIPT_DIR}/assets"

    # CloudStack compatibility (datasource + password management)
    vc --upload "${A}/cloud/99-cloudstack.cfg:/etc/cloud/cloud.cfg.d/99-cloudstack.cfg"
    vc --upload "${A}/cloudstack/set-guest-password:/usr/local/bin/cloudstack-set-guest-password"
    vc --upload "${A}/cloudstack/cloudstack-password.service:/etc/systemd/system/cloudstack-password.service"
    vc --run-command 'chmod 755 /usr/local/bin/cloudstack-set-guest-password'
    vc --run-command 'systemctl enable cloudstack-password.service qemu-guest-agent'

    # Serial console (Proxmox "serial terminal" + CS console)
    if [[ "$FAMILY" == "deb" ]]; then
        vc --run-command 'grep -qs console=ttyS0 /etc/default/grub || {
sed -ri "s|^GRUB_CMDLINE_LINUX=\"(.*)\"|GRUB_CMDLINE_LINUX=\"\1 console=tty0 console=ttyS0,115200n8\"|;
s|^GRUB_CMDLINE_LINUX=$|GRUB_CMDLINE_LINUX=\"console=tty0 console=ttyS0,115200n8\"|" /etc/default/grub;
update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg; }'
    else
        vc --run-command 'command -v grubby >/dev/null && grubby --update-kernel=ALL --args="console=ttyS0,115200n8"; true'
    fi

    # Reinstall the bootloader. virt-resize rebuilds the GPT and renumbers
    # partitions in physical order (e.g. Ubuntu's 14/15/16/1 -> 1/2/3/4).
    # GRUB's core.img embeds a prefix pointing at the OLD partition number,
    # so without this the template dies with "error: no such partition" and
    # drops into a grub rescue prompt.
    if [[ "$FAMILY" == "deb" ]]; then
        vc --run-command 'grub-install --no-floppy /dev/sda'
    else
        vc --run-command 'grub2-install --no-floppy /dev/sda'
    fi

    # Timezone
    [[ -n "$TIMEZONE" ]] && vc --timezone "$TIMEZONE"

    # Emergency root password (optional)
    [[ -n "$ROOT_PASSWORD" ]] && vc --root-password "password:${ROOT_PASSWORD}"

    # Admin user + SSH key (optional)
    if [[ -n "$ADMIN_USER" ]]; then
        local sudo_grp="sudo"; [[ "$FAMILY" == "rpm" ]] && sudo_grp="wheel"
        vc --run-command "id -u ${ADMIN_USER} >/dev/null 2>&1 || useradd -m -U -s /bin/bash ${ADMIN_USER};
usermod -aG ${sudo_grp} ${ADMIN_USER};
echo '${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${ADMIN_USER};
chmod 440 /etc/sudoers.d/90-${ADMIN_USER}"
        if [[ -n "$ADMIN_SSH_KEY_FILE" && -f "$ADMIN_SSH_KEY_FILE" ]]; then
            local pub; pub="$(tr -d '\n' < "$ADMIN_SSH_KEY_FILE")"
            vc --ssh-inject "${ADMIN_USER}:string:${pub}"
        else
            warn "ADMIN_USER set but ADMIN_SSH_KEY_FILE missing/empty — no key injected"
        fi
    fi

    # Log hygiene before sysprep
    vc --run-command 'rm -rf /var/log/journal/* /var/log/audit/* 2>/dev/null;
find /var/log -type f -size +5M -delete 2>/dev/null; true'
}

SYSPREP_OPS="bash-history,dhcp-client-state,logfiles,machine-id,mail-spool,\
net-hwaddr,package-manager-cache,pam-data,rpm-db,ssh-hostkeys,ssh-userdir,\
tmp-files,udev-persistent-net,utmp,yum-uuid"

print_report() {
    local img=$1 sha=$2 size_gb
    size_gb=$(du -h "$img" | cut -f1)
    cat <<EOF

=====================================================================
 Template ready:  ${img}
 Disk size:       ${DISK_SIZE} (virtual) / ${size_gb} on disk
 SHA256:          ${sha}
---------------------------------------------------------------------
 PROXMOX import (adjust VMID/storage):
   qm create 9000 --name tpl-${NAME} --bios seabios --ostype l26 \\
     --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0 \\
     --scsihw virtio-scsi-pci --serial0 socket --agent enabled=1 --vga std
   qm importdisk 9000 ${img} local-lvm
   qm set 9000 --scsi0 local-lvm:vm-9000-disk-0,iothread=1,discard=on
   qm set 9000 --boot order=scsi0 && qm template 9000

 CLOUDSTACK register:
   Hypervisor: KVM | Format: QCOW2 | BIOS boot
   OS Type: $( [[ $DIST == ubuntu ]] && echo "Ubuntu $(echo $VER_TAG | cut -d. -f1).04 (64-bit)" || echo "$DIST ${VER_TAG} (64-bit)" )
   [x] Password Enabled   (our set-guest-password service handles it)
=====================================================================
EOF
}

run_boot_test() {
    local img=$1 logfile="$OUT_DIR/${NAME}-boottest.log"
    command -v qemu-system-x86_64 >/dev/null 2>&1 \
        || { warn "--test needs qemu-system-x86_64 (dnf install qemu-kvm)"; return 0; }
    log "boot smoke test (up to 7 min; TCG fallback if no /dev/kvm)"
    if timeout 420 qemu-system-x86_64 \
            -machine pc,accel=kvm:tcg -cpu max -m 1024 -smp 2 \
            -drive "file=${img},format=qcow2,if=virtio" \
            -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
            -display none -serial "file:${logfile}" ; then
        info "qemu exited cleanly"
    fi
    if grep -qE 'login:|Cloud-init.*finished' "$logfile" 2>/dev/null; then
        log "BOOT TEST PASSED — guest reached login/cloud-init-finished"
    else
        warn "BOOT TEST inconclusive — inspect ${logfile}"
    fi
}

# ------------------------------------------------------------------- main
log "building template for '${DIST}'"
resolve_image "$VER"          # sets IMG_URL SUMS_URLS FILE_NAME VER_TAG (+VER/CODENAME)
NAME="${DIST}-${VER_TAG}"
FINAL="${OUT_DIR}/${NAME}-kvm-bios-${STAMP}.qcow2"
mkdir -p "$OUT_DIR" "$CACHE_DIR"
WORK_DIR="$(mktemp -d "/tmp/tplgen-${NAME}.XXXXXX")"

# 1. download + verify
IMG_CACHE="${CACHE_DIR}/${FILE_NAME}"
SUMS_CACHE="${CACHE_DIR}/${FILE_NAME}.SUMS"
[[ -f "$IMG_CACHE" ]] || fetch "$IMG_URL" "$IMG_CACHE"
if [[ ! -f "$SUMS_CACHE" ]]; then
    ok=0
    for u in "${SUMS_URLS[@]}"; do
        curl -fsSL --retry 3 --connect-timeout 20 -o "$SUMS_CACHE" "$u" && { ok=1; break; }
    done
    if [[ $ok != 1 ]]; then
        rm -f "$SUMS_CACHE"
        warn "could not fetch checksum list — skipping verification!"
    fi
fi
if [[ -f "$SUMS_CACHE" ]]; then
    verify_checksum "$SUMS_CACHE" "$FILE_NAME" "$IMG_CACHE"
fi

# 2. resize to target size
# NOTE: the target disk must be pre-created (virt-resize copies into an
# existing, larger image); partitions keep their original size and the
# root fs is grown on first boot via cloud-init growpart.
log "resizing image to ${DISK_SIZE}"
RESIZED="${WORK_DIR}/root.qcow2"
qemu-img create -f qcow2 "$RESIZED" "$DISK_SIZE"
virt-resize "$IMG_CACHE" "$RESIZED"

# 3. customization plan
vc -a "$RESIZED" --network

if [[ $NO_REPO == 0 ]]; then
    log "switching repos to private mirror: ${MIRROR_URL}"
    customize_repos
else
    warn "keeping upstream repositories (--no-repo)"
fi

log "installing qemu-guest-agent + growpart support"
customize_pkgs

if [[ $FULL_UPDATE == 1 ]]; then
    log "applying FULL distribution update"
    customize_full_update
elif [[ $NO_PATCH == 0 ]]; then
    log "patching kernel + openssh (CVE hardening) from mirror"
    customize_patch
else
    warn "skipping CVE patching (--no-patch)"
fi

base_customize
[[ "$FAMILY" == "rpm" ]] && vc --selinux-relabel

# 4. run guestfs appliance once
log "customizing guest offline (single appliance boot)"
virt-customize "${VC_ARGS[@]}"

# 5. sysprep cleanup: logs, machine-id, host keys, hwaddr...
log "sysprep cleanup (${SYSPREP_OPS})"
virt-sysprep -a "$RESIZED" --operations "$SYSPREP_OPS"

# 6. compact & finalize
log "compacting image -> ${FINAL}"
qemu-img convert -O qcow2 "$RESIZED" "$FINAL.tmp"
mv "$FINAL.tmp" "$FINAL"
SHA=$(sha256sum "$FINAL" | awk '{print $1}')
printf '%s  %s\n' "$SHA" "$(basename "$FINAL")" > "${FINAL}.sha256"

print_report "$FINAL" "$SHA"

[[ $TEST == 1 ]] && run_boot_test "$FINAL"

log "done."
