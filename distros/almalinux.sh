#!/usr/bin/env bash
# distros/almalinux.sh — AlmaLinux GenericCloud image
DISTRO_ID=almalinux
FAMILY=rpm
SUPPORTED_VERSIONS=("9" "10")
REPO_DIR=almalinux
GPG_KEY_ID="RPM-GPG-KEY-AlmaLinux"
UPSTREAM_KEY_URL="https://repo.almalinux.org/almalinux"

resolve_image() {
    VER="${1:-${SUPPORTED_VERSIONS[0]}}"
    case "$VER" in 8|9|10) ;; *) die "unsupported almalinux version '$VER'" ;; esac
    FILE_NAME="AlmaLinux-${VER}-GenericCloud-latest.x86_64.qcow2"
    IMG_URL="https://repo.almalinux.org/almalinux/${VER}/cloud/x86_64/images/${FILE_NAME}"
    SUMS_URLS=("https://repo.almalinux.org/almalinux/${VER}/cloud/x86_64/images/CHECKSUM"
               "https://repo.almalinux.org/almalinux/${VER}/images/x86_64/CHECKSUM")
    VER_TAG="$VER"
}

customize_repos() {
    local repo_content
    repo_content=$(build_rhel_repo)
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
