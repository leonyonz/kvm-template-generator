#!/usr/bin/env bash
# distros/debian.sh — Debian generic cloud image via cdimage.debian.org
DISTRO_ID=debian
FAMILY=deb
SUPPORTED_VERSIONS=("13" "12" "11")

codename_of() {
    case "$1" in
        13|trixie)   echo trixie ;;
        12|bookworm) echo bookworm ;;
        11|bullseye) echo bullseye ;;
        *) die "unsupported debian version '$1' (supported: ${SUPPORTED_VERSIONS[*]})" ;;
    esac
}

resolve_image() {
    VER="${1:-${SUPPORTED_VERSIONS[0]}}"
    CODENAME=$(codename_of "$VER")
    FILE_NAME="debian-${VER}-generic-amd64.qcow2"
    IMG_URL="https://cdimage.debian.org/cdimage/cloud/${CODENAME}/latest/${FILE_NAME}"
    SUMS_URLS=("https://cdimage.debian.org/cdimage/cloud/${CODENAME}/latest/SHA512SUMS")
    VER_TAG="$VER"
}

customize_repos() {
    local list
    list=$(cat <<LIST
deb ${MIRROR_URL}/debian ${CODENAME} main contrib non-free non-free-firmware
deb ${MIRROR_URL}/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb ${MIRROR_URL}/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
LIST
)
    vc --run-command 'rm -f /etc/apt/sources.list.d/debian.sources'
    vc --write "/etc/apt/sources.list:${list}"
}

customize_pkgs() {
    vc --run-command 'export DEBIAN_FRONTEND=noninteractive;
apt-get update -qq;
apt-get install -yqq qemu-guest-agent cloud-initramfs-growpart || exit 1;
apt-get clean; rm -rf /var/lib/apt/lists/*'
}

customize_patch() {
    vc --run-command 'export DEBIAN_FRONTEND=noninteractive;
apt-get update -qq;
for p in openssh-client openssh-server linux-image-amd64; do
    apt-get install -yqq --only-upgrade "$p" 2>/dev/null || echo "NOTE: $p nothing to upgrade";
done;
apt-get clean'
}

customize_full_update() {
    vc --run-command 'export DEBIAN_FRONTEND=noninteractive;
apt-get update -qq && apt-get -yqq dist-upgrade && apt-get -yqq autoremove;
apt-get clean; rm -rf /var/lib/apt/lists/*'
}
