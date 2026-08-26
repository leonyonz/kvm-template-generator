#!/usr/bin/env bash
# distros/ubuntu.sh — Ubuntu minimal cloud image via cloud-images.ubuntu.com
DISTRO_ID=ubuntu
FAMILY=deb
SUPPORTED_VERSIONS=("24.04" "22.04")

codename_of() {
    case "$1" in
        24.04|noble) echo noble ;;
        22.04|jammy) echo jammy ;;
        *) die "unsupported ubuntu version '$1' (supported: ${SUPPORTED_VERSIONS[*]})" ;;
    esac
}

resolve_image() {
    VER="${1:-${SUPPORTED_VERSIONS[0]}}"
    CODENAME=$(codename_of "$VER")
    FILE_NAME="ubuntu-${VER}-minimal-cloudimg-amd64.img"
    IMG_URL="https://cloud-images.ubuntu.com/minimal/releases/${CODENAME}/release/${FILE_NAME}"
    SUMS_URLS=("https://cloud-images.ubuntu.com/minimal/releases/${CODENAME}/release/SHA256SUMS")
    VER_TAG="$VER"
}

customize_repos() {
    local list
    list=$(cat <<LIST
deb ${MIRROR_URL}/ubuntu ${CODENAME} main restricted universe multiverse
deb ${MIRROR_URL}/ubuntu ${CODENAME}-updates main restricted universe multiverse
deb ${MIRROR_URL}/ubuntu ${CODENAME}-security main restricted universe multiverse
deb ${MIRROR_URL}/ubuntu ${CODENAME}-backports main restricted universe multiverse
LIST
)
    vc --run-command 'rm -f /etc/apt/sources.list.d/ubuntu*.sources'
    vc --write "/etc/apt/sources.list:${list}"
}

customize_pkgs() {
    vc --run-command 'export DEBIAN_FRONTEND=noninteractive;
apt-get update -qq;
apt-get install -yqq qemu-guest-agent cloud-initramfs-growpart || exit 1;
apt-get clean; rm -rf /var/lib/apt/lists/*'
}

# Targeted CVE patch: kernel + OpenSSH only (from private mirror)
customize_patch() {
    vc --run-command 'export DEBIAN_FRONTEND=noninteractive;
apt-get update -qq;
for p in openssh-client openssh-server linux-image-virtual linux-virtual; do
    apt-get install -yqq --only-upgrade "$p" 2>/dev/null || echo "NOTE: $p nothing to upgrade";
done;
apt-get clean'
}

customize_full_update() {
    vc --run-command 'export DEBIAN_FRONTEND=noninteractive;
apt-get update -qq && apt-get -yqq dist-upgrade && apt-get -yqq autoremove;
apt-get clean; rm -rf /var/lib/apt/lists/*'
}
