#!/usr/bin/env bash
# distros/rocky.sh — Rocky Linux GenericCloud (KVM) image
DISTRO_ID=rocky
FAMILY=rpm
SUPPORTED_VERSIONS=("9" "10")
REPO_DIR=rocky
GPG_KEY_ID="RPM-GPG-KEY-Rocky"
UPSTREAM_KEY_URL="https://download.rockylinux.org/pub/rocky"

resolve_image() {
    VER="${1:-${SUPPORTED_VERSIONS[0]}}"
    case "$VER" in 8|9|10) ;; *) die "unsupported rocky version '$VER'" ;; esac
    FILE_NAME="Rocky-${VER}-GenericCloud-Base.latest.x86_64.qcow2"
    IMG_URL="https://download.rockylinux.org/pub/rocky/${VER}/images/x86_64/${FILE_NAME}"
    SUMS_URLS=("https://download.rockylinux.org/pub/rocky/${VER}/images/x86_64/CHECKSUM")
    VER_TAG="$VER"
}

customize_repos() {
    local repo_content
    repo_content=$(build_rhel_repo)
    # Park upstream repo definitions so only the mirror is used
    vc --run-command 'mkdir -p /etc/yum.repos.d.disabled;
mv /etc/yum.repos.d/*.repo /etc/yum.repos.d.disabled/ 2>/dev/null; true'
    vc --write "/etc/yum.repos.d/biznetgio.repo:${repo_content}"
    vc --run-command 'dnf clean all >/dev/null 2>&1; dnf makecache >/dev/null 2>&1'
}

customize_pkgs() {
    vc --run-command 'dnf -y install qemu-guest-agent || exit 1; dnf clean all'
}

customize_patch() {
    vc --run-command 'dnf -y update "kernel*" "openssh*" && dnf clean all'
}

customize_full_update() {
    vc --run-command 'dnf -y update && dnf clean all'
}
