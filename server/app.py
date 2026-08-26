#!/usr/bin/env python3
"""
template-generator server
Web UI + REST API driving Ansible playbook builds of KVM templates.

Run:   ./run-server.sh          (or: uvicorn server.app:app --port 8080)
Auth:  X-Token header, value from TG_TOKEN env (default "changeme")
"""
import json
import os
import re
import shlex
import sqlite3
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse
import urllib.request

import yaml
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse, PlainTextResponse
from pydantic import BaseModel

BASE = Path(__file__).resolve().parent.parent
CATALOG_PATH = BASE / "config/catalog.yml"
CATALOG = yaml.safe_load(CATALOG_PATH.read_text())
PATCHES_PATH = BASE / "config/patches.yml"
PLAYBOOK = BASE / "ansible/build-template.yml"
LOG_DIR = BASE / "server/logs"
WORK_ROOT = BASE / "server/work"
LOG_DIR.mkdir(parents=True, exist_ok=True)
WORK_ROOT.mkdir(parents=True, exist_ok=True)

DB_PATH = BASE / "server/data.db"
TOKEN = os.environ.get("TG_TOKEN", "changeme")

BUILD_LOCK = threading.Lock()      # one guestfs build at a time
PROCS = {}                          # job_id -> Popen


# ------------------------------------------------------------------ db
def db() -> sqlite3.Connection:
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    return con


def init_db():
    with db() as con:
        con.execute("""CREATE TABLE IF NOT EXISTS builds(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created TEXT NOT NULL,
            distro TEXT NOT NULL,
            version TEXT NOT NULL,
            params TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'queued',
            download_pct INTEGER,
            final_path TEXT DEFAULT '',
            sha256 TEXT DEFAULT '',
            finished TEXT DEFAULT '')""")
        # migrations for dbs created before the download-progress feature
        cols = [r[1] for r in con.execute("PRAGMA table_info(builds)")]
        if "download_pct" not in cols:
            con.execute("ALTER TABLE builds ADD COLUMN download_pct INTEGER")
        if "boottest" not in cols:
            con.execute("ALTER TABLE builds ADD COLUMN boottest TEXT DEFAULT ''")
        con.execute("""CREATE TABLE IF NOT EXISTS audit_log(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            actor TEXT NOT NULL,
            action TEXT NOT NULL,
            details TEXT DEFAULT '')""")


init_db()
app = FastAPI(title="template-generator", docs_url="/api/docs")


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def audit(actor: str, action: str, details: str = ""):
    with db() as con:
        con.execute("INSERT INTO audit_log(ts,actor,action,details) VALUES(?,?,?,?)",
                    (now(), actor, action, details))
    print(f"[audit] {action}: {details}", flush=True)


def save_catalog():
    """Persist the in-memory catalog back to YAML (comments are not preserved)."""
    CATALOG_PATH.write_text(
        "# Managed via Web UI / API - manual comments are not preserved\n"
        + yaml.safe_dump(CATALOG, sort_keys=False, default_flow_style=False))


def require_token(x_token: str = Header(default="")):
    if x_token != TOKEN:
        raise HTTPException(status_code=401, detail="invalid or missing X-Token")


# ------------------------------------------------------- build resolution
def _load_patches() -> dict:
    if PATCHES_PATH.exists():
        try:
            return yaml.safe_load(PATCHES_PATH.read_text()) or {"profiles": {}}
        except Exception:                                        # noqa: BLE001
            return {"profiles": {}}
    return {"profiles": {}}


def compose_custom_patch(req: "BuildRequest", family: str, distro: str) -> tuple[str, str]:
    """Compose a guest shell script for a custom patch build.
    Returns (script, source-description)."""
    prof_key = (req.patch_profile or "").strip()
    if prof_key and prof_key != "__adhoc__":
        p = _load_patches().get("profiles", {}).get(prof_key)
        if not p:
            raise HTTPException(400, f"unknown patch profile '{prof_key}'")
        allowed_fam = p.get("family", "any")
        if allowed_fam not in ("any", family):
            raise HTTPException(400,
                f"profile '{prof_key}' targets '{allowed_fam}' guests, not '{family}'")
        if p.get("distros") and distro not in p["distros"]:
            raise HTTPException(400,
                f"profile '{prof_key}' is restricted to {p['distros']}")
        packages = p.get("packages") or []
        update_globs = p.get("update_globs") or []
        holds = p.get("hold_packages") or []
        commands = p.get("commands") or []
        set_default = p.get("set_default_kernel") or ""
        rm_others = bool(p.get("remove_other_kernels"))
        src = f"profile:{prof_key}"
    else:
        packages = req.patch_packages or []
        update_globs = []
        holds = []
        commands = req.patch_commands or []
        set_default = ""
        rm_others = False
        src = "ad-hoc"
        if not packages and not commands:
            raise HTTPException(400,
                "custom patch requires a profile OR patch_packages/patch_commands")

    parts: list[str] = []
    if family == "deb":
        if packages:
            parts.append("export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; "
                         "apt-get install -yqq " + " ".join(shlex.quote(x) for x in packages))
        if update_globs:
            parts.append("export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; for g in "
                         + " ".join(update_globs)
                         + '; do apt-get install -yqq --only-upgrade "$g" 2>/dev/null '
                           '|| echo "NOTE: $g nothing to upgrade"; done')
    elif family == "suse":
        if packages:
            parts.append("zypper -n install " + " ".join(shlex.quote(x) for x in packages))
        if update_globs:
            parts.append("zypper -n update " + " ".join(update_globs))
    else:
        if packages:
            parts.append("dnf -y install " + " ".join(shlex.quote(x) for x in packages))
        if update_globs:
            parts.append("dnf -y update " + " ".join(update_globs))

    for c in commands:
        c = c.strip().rstrip(";")
        if c:
            parts.append(c)

    if set_default and family == "rpm":
        parts.append(f"grubby --set-default=/boot/vmlinuz-{shlex.quote(set_default)} || true")
    elif set_default and family == "suse":
        # SUSE has no grubby: regenerate grub.cfg, find the matching menu
        # entry and pin it via grub2-set-default
        pat = re.escape(set_default)
        parts.append(
            "grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1; "
            f"entry=$(awk '/menuentry/ && /{pat}/ {{print $2; exit}}' /boot/grub2/grub.cfg); "
            '[ -n "$entry" ] && grub2-set-default "$entry" || true')
    if rm_others:
        if family == "deb":
            keep = re.escape(set_default) if set_default else "NEVERMATCH"
            parts.append("export DEBIAN_FRONTEND=noninteractive; "
                         "dpkg -l | awk '/linux-image-[0-9]/ {print $2}' "
                         f'| grep -vE "{keep}" | xargs -r apt-get -yq purge; update-grub')
        else:
            keep = shlex.quote(set_default) if set_default else '""'
            if family == "suse":
                parts.append(f"rpm -q kernel-default 2>/dev/null | grep -v {keep} | "
                             "xargs -r zypper -n remove || true")
            else:
                parts.append(f"rpm -q kernel kernel-core kernel-modules 2>/dev/null "
                             f"| grep -v {keep} | xargs -r dnf -y remove || true")
    if holds:
        if family == "deb":
            parts.append("apt-mark hold " + " ".join(holds))
        elif family == "suse":
            parts.append("zypper -n addlock " + " ".join(shlex.quote(h) for h in holds))
        else:
            parts.append('dnf -y install "dnf-command(versionlock)" >/dev/null && '
                         + "dnf versionlock add " + " ".join(holds))

    if not parts:
        raise HTTPException(400, "custom patch resolved to an empty step list")
    return "; ".join(parts), src


def _deb_sources(mirror: str, distro: str, codename: str) -> str:
    if distro == "ubuntu":
        comp = "main restricted universe multiverse"
        return (f"deb {mirror}/ubuntu {codename} {comp}\n"
                f"deb {mirror}/ubuntu {codename}-updates {comp}\n"
                f"deb {mirror}/ubuntu {codename}-security {comp}\n"
                f"deb {mirror}/ubuntu {codename}-backports {comp}\n")
    comp = "main contrib non-free non-free-firmware"
    return (f"deb {mirror}/debian {codename} {comp}\n"
            f"deb {mirror}/debian {codename}-updates {comp}\n"
            f"deb {mirror}/debian-security {codename}-security {comp}\n")


def _rhel_repo(mirror: str, dmeta: dict, major: str) -> str:
    key = f"{dmeta['gpg_key_id']}-{major}"
    up = dmeta["upstream_key_url"]
    base = f"{mirror}/{dmeta['repo_dir']}/{major}"
    kline = f"gpgkey=file:///etc/pki/rpm-gpg/{key} {up}/{key}"
    epel_key = f"{mirror}/epel/RPM-GPG-KEY-EPEL-{major}"
    return f"""# Generated by template-generator — private mirror: {mirror}
[biznetgio-baseos]
name=BiznetGio Mirror - BaseOS
baseurl={base}/BaseOS/x86_64/os/
enabled=1
gpgcheck=1
{kline}

[biznetgio-appstream]
name=BiznetGio Mirror - AppStream
baseurl={base}/AppStream/x86_64/os/
enabled=1
gpgcheck=1
{kline}

[biznetgio-crb]
name=BiznetGio Mirror - CRB
baseurl={base}/CRB/x86_64/os/
enabled=0
gpgcheck=1
{kline}

[biznetgio-epel]
name=BiznetGio Mirror - EPEL
baseurl={mirror}/epel/{major}/Everything/x86_64/
enabled=0
gpgcheck=1
gpgkey={epel_key}
"""


def _suse_repo(mirror: str, repo_dir: str, leap: str) -> str:
    base = f"{mirror}/{repo_dir}/distribution/leap/{leap}/repo"
    return f"""# Generated by template-generator — private mirror: {mirror}
[biznetgio-oss]
name=BiznetGio Mirror - Leap {leap} OSS
baseurl={base}/oss
enabled=1
gpgcheck=1

[biznetgio-non-oss]
name=BiznetGio Mirror - Leap {leap} Non-OSS
baseurl={base}/non-oss
enabled=1
gpgcheck=1
"""


DEB_GRUB = ('grep -qs console=ttyS0 /etc/default/grub || { '
            'sed -ri "s|^GRUB_CMDLINE_LINUX=\\"(.*)\\"|GRUB_CMDLINE_LINUX=\\"\\1 console=tty0 console=ttyS0,115200n8\\"|; '
            's|^GRUB_CMDLINE_LINUX=$|GRUB_CMDLINE_LINUX=\\"console=tty0 console=ttyS0,115200n8\\"|" /etc/default/grub; '
            'update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg; }')
RPM_GRUB = ('command -v grubby >/dev/null && '
            'grubby --update-kernel=ALL --args="console=ttyS0,115200n8"; true')

# openSUSE: no grubby/update-grub — regenerate grub2 config instead
SUSE_GRUB = ('grep -qs console=ttyS0 /etc/default/grub || { '
             'sed -ri "s|^GRUB_CMDLINE_LINUX=\\"(.*)\\"|GRUB_CMDLINE_LINUX=\\"\\1 console=tty0 console=ttyS0,115200n8\\"|; '
             's|^GRUB_CMDLINE_LINUX=$|GRUB_CMDLINE_LINUX=\\"console=tty0 console=ttyS0,115200n8\\"|" /etc/default/grub; '
             'grub2-mkconfig -o /boot/grub2/grub.cfg; }')

CLEANUP_CMDS = ["--run-command",
                "rm -rf /var/log/journal/* /var/log/audit/* 2>/dev/null; "
                "find /var/log -type f -size +5M -delete 2>/dev/null; true"]

# virt-resize renumbers GPT partitions (physical order); GRUB's core.img
# keeps a prefix pointing at the OLD partition number, so the bootloader
# must be reinstalled after resizing or the template dies in grub rescue.
GRUB_INSTALL = {"deb": "grub-install --no-floppy /dev/sda",
                "rpm": "grub2-install --no-floppy /dev/sda",
                "suse": "grub2-install --no-floppy /dev/sda"}


def resolve_build(req: "BuildRequest") -> dict:
    """Turn a UI request into ansible extra-vars."""
    distros = CATALOG["distros"]
    if req.distro not in distros:
        raise HTTPException(400, f"unknown distro '{req.distro}'")
    d = distros[req.distro]
    if req.version not in d["versions"]:
        raise HTTPException(400, f"'{req.distro}' has no version '{req.version}' "
                                 f"(available: {', '.join(d['versions'])})")
    if req.patch_mode not in ("targeted", "full", "custom", "none"):
        raise HTTPException(400, "patch_mode must be targeted|full|custom|none")

    v = d["versions"][req.version]
    fam = d["family"]
    mirror = req.mirror_url or CATALOG["defaults"]["mirror_url"]
    disk_size = req.disk_size or CATALOG["defaults"]["disk_size"]
    stamp = time.strftime("%Y%m%d-%H%M")

    ev = {
        "distro": req.distro,
        "version": req.version,
        "family": fam,
        "grub_install_cmd": GRUB_INSTALL[fam],
        "filename": v["filename"],
        "image_url": v["image_url"],
        "sums_algo": v.get("sums_algo", "sha256"),
        "sums_url": v["sums_url"],
        "disk_size": disk_size,
        "patch_mode": req.patch_mode,
        "switch_repo": bool(req.switch_repo),
        "boot_test": bool(req.boot_test),
        "timezone": req.timezone or "",
        "admin_user": req.admin_user or "",
        "admin_ssh_key": req.admin_ssh_key or "",
        "root_password": req.root_password or "",
        "cache_dir": str(BASE / "cache"),
        "output_dir": str(BASE / "output"),
        "work_dir": str(WORK_ROOT / f"{req.distro}-{req.version}-{stamp}"),
        "final_name": f"{req.distro}-{req.version}-kvm-bios-{stamp}.qcow2",
        "cleanup_cmds": CLEANUP_CMDS,
    }
    ev["final_path"] = f'{ev["output_dir"]}/{ev["final_name"]}'

    # custom patch stage: compose the guest script from profile / ad-hoc input
    if req.patch_mode == "custom":
        ev["patch_cmd"], patch_src = compose_custom_patch(req, fam, req.distro)
        ev["patch_desc"] = patch_src

    if fam == "deb":
        cn = v["codename"]
        kp = v.get("kernel_pkg", "linux-image-amd64")
        ev.update(
            repo_file_content=_deb_sources(mirror, req.distro, cn),
            repo_upload_target="/etc/apt/sources.list",
            pre_repo_cmds=["--run-command",
                           f"rm -f /etc/apt/sources.list.d/{req.distro}*.sources"],
            post_repo_cmds=[],
            pkg_install_cmd=("export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; "
                             "apt-get install -yqq qemu-guest-agent cloud-guest-utils || exit 1; "
                             "apt-get clean"),
            patch_cmd=(f'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; '
                       f'for p in openssh-client openssh-server {kp}; do '
                       f'apt-get install -yqq --only-upgrade "$p" 2>/dev/null '
                       f'|| echo "NOTE: $p nothing to upgrade"; done; apt-get clean'),
            full_update_cmd=("export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && "
                             "apt-get -yqq dist-upgrade && apt-get -yqq autoremove; apt-get clean"),
            grub_cmd=DEB_GRUB,
        )
    elif fam == "suse":
        leap = req.version if "." in req.version else f"{req.version}.0"
        ev.update(
            repo_file_content=_suse_repo(mirror, d.get("repo_dir", "opensuse/opensuse"), leap),
            repo_upload_target="/etc/zypp/repos.d/biznetgio.repo",
            # Leap 16 generates repos via a zypp SERVICE (not static .repo
            # files) — park services too or upstream repos stay active
            pre_repo_cmds=["--run-command",
                           "mkdir -p /etc/zypp/repos.d.disabled /etc/zypp/services.d.disabled; "
                           "mv /etc/zypp/repos.d/*.repo /etc/zypp/repos.d.disabled/ 2>/dev/null; "
                           "mv /etc/zypp/services.d/*.service /etc/zypp/services.d.disabled/ 2>/dev/null; true"],
            post_repo_cmds=["--run-command",
                            "zypper --gpg-auto-import-keys --non-interactive refresh || true"],
            pkg_install_cmd=("zypper -n --gpg-auto-import-keys install qemu-guest-agent || exit 1; "
                             "zypper -n clean || true"),
            # Leap 16 has no separate update repo — updates land in oss itself
            patch_cmd='zypper -n update "kernel*" "openssh*" && zypper -n clean || true',
            full_update_cmd="zypper -n dup --auto-agree-with-licenses && zypper -n clean || true",
            grub_cmd=SUSE_GRUB,
        )
    else:
        major = req.version.split(".")[0]
        ev.update(
            repo_file_content=_rhel_repo(mirror, d, major),
            repo_upload_target="/etc/yum.repos.d/biznetgio.repo",
            pre_repo_cmds=["--run-command",
                           "mkdir -p /etc/yum.repos.d.disabled; "
                           "mv /etc/yum.repos.d/*.repo /etc/yum.repos.d.disabled/ 2>/dev/null; true"],
            post_repo_cmds=["--run-command", "dnf clean all >/dev/null 2>&1; dnf makecache >/dev/null 2>&1"],
            pkg_install_cmd="dnf -y install qemu-guest-agent || exit 1; dnf clean all",
            patch_cmd='dnf -y update "kernel*" "openssh*" && dnf clean all',
            full_update_cmd="dnf -y update && dnf clean all",
            grub_cmd=RPM_GRUB,
        )

    grp = "sudo" if fam == "deb" else "wheel"      # suse + rpm use wheel
    u = req.admin_user or ""
    ev["admin_setup_cmd"] = (
        f"id -u {u} >/dev/null 2>&1 || useradd -m -U -s /bin/bash {u}; "
        f"usermod -aG {grp} {u}; "
        f"echo '{u} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-{u}; "
        f"chmod 440 /etc/sudoers.d/90-{u}")
    return ev


# ------------------------------------------------------------ job runner
def _set_phase(job_id: int, phase: str, pct: int | None = None):
    with db() as con:
        con.execute("UPDATE builds SET status=?, download_pct=? WHERE id=?",
                    (phase, pct, job_id))


# --------------------------------------------------------- boot testing
def _boottest_worker(job_id: int, img: str):
    """Boot the finished image headlessly; update the boottest status.
    Caller is responsible for holding/releasing BUILD_LOCK."""
    log_path = LOG_DIR / f"{job_id}.boottest.log"
    timeout = os.environ.get("TG_BOOTTEST_TIMEOUT", "1500")
    with db() as con:
        con.execute("UPDATE builds SET boottest='running' WHERE id=?", (job_id,))
    audit("system", "boottest.started", f"job={job_id} {Path(img).name}")
    try:
        r = subprocess.run(
            ["bash", str(BASE / "tests/boottest.sh"), img, str(log_path), timeout],
            capture_output=True, text=True)
        out = r.stdout.strip().splitlines()
        desc = out[-1] if out else ""
        code = r.returncode
    except Exception as exc:                                    # noqa: BLE001
        code, desc = 3, str(exc)
    status = {0: "pass", 1: "inconclusive", 2: "fail", 3: "error"}.get(code, "error")
    with db() as con:
        con.execute("UPDATE builds SET boottest=? WHERE id=?", (status, job_id))
    audit("system", f"boottest.{status}",
          f"job={job_id} {Path(img).name} ({desc})")


def run_boottest_manual(job_id: int, img: str):
    if not BUILD_LOCK.acquire(blocking=False):
        raise HTTPException(409, "a build/boot test is already running — wait for it to finish")
    try:
        _boottest_worker(job_id, img)
    finally:
        BUILD_LOCK.release()


def _content_length(url: str) -> int:
    try:
        req = urllib.request.Request(url, method="HEAD",
                                     headers={"User-Agent": "template-generator"})
        with urllib.request.urlopen(req, timeout=20) as r:
            return int(r.headers.get("Content-Length") or 0)
    except Exception:                                           # noqa: BLE001
        return 0


def _download_base_image(job_id: int, ev: dict) -> bool:
    """Phase 1: ensure the base image is in cache, with live progress."""
    dest = Path(ev["cache_dir"]) / ev["filename"]
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        audit("system", "image.cached",
              f"job={job_id} {ev['filename']} ({dest.stat().st_size // 1048576}MB)")
        _set_phase(job_id, "building")
        return True

    _set_phase(job_id, "downloading", 0)
    total = _content_length(ev["image_url"])
    part = f"{dest}.part"
    audit("system", "image.download_started", f"job={job_id} {ev['image_url']}")
    log_path = LOG_DIR / f"{job_id}.log"
    with open(log_path, "w") as fh:
        fh.write(f"[server] downloading base image\n[server]   url : {ev['image_url']}\n"
                 f"[server]   dest: {dest}\n[server]   size: "
                 f"{total // 1048576}MB\n\n")
        fh.flush()
        proc = subprocess.Popen(
            ["curl", "-fL", "--retry", "3", "--retry-delay", "3",
             "--connect-timeout", "20", "-o", part, ev["image_url"]],
            stdout=fh, stderr=subprocess.STDOUT)
        PROCS[job_id] = proc
        last_pct = -1
        while proc.poll() is None:
            try:
                have = os.path.getsize(part)
            except OSError:
                have = 0
            pct = min(99, int(have * 100 / total)) if total else 0
            if pct != last_pct:
                _set_phase(job_id, "downloading", pct)
                last_pct = pct
            time.sleep(1)
        rc = proc.wait()
    PROCS.pop(job_id, None)

    if rc != 0:
        Path(part).unlink(missing_ok=True)
        return False
    os.replace(part, dest)
    mb = dest.stat().st_size // 1048576
    audit("system", "image.downloaded", f"job={job_id} {ev['filename']} {mb}MB")
    _set_phase(job_id, "building")
    return True


def run_job(job_id: int, extra_vars: dict):
    log_path = LOG_DIR / f"{job_id}.log"
    audit("system", "build.started", f"job={job_id} {extra_vars['distro']} {extra_vars['version']}")
    rc = -1
    try:
        if not _download_base_image(job_id, extra_vars):
            raise RuntimeError("base image download failed (see log)")

        cmd = ["ansible-playbook", "-i", "localhost,", str(PLAYBOOK),
               "--extra-vars", json.dumps(extra_vars)]
        env = os.environ | {"LIBGUESTFS_BACKEND": "direct",
                            "ANSIBLE_HOST_KEY_CHECKING": "false"}
        with open(log_path, "a") as fh:
            fh.write("\n[server] base image ready - starting ansible build\n\n")
            fh.flush()
            proc = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT,
                                    cwd=str(BASE), env=env)
            PROCS[job_id] = proc
            rc = proc.wait()
    except Exception as exc:                                   # noqa: BLE001
        rc = -1
        with open(log_path, "a") as fh:
            fh.write(f"\nRUNNER ERROR: {exc}\n")
    finally:
        PROCS.pop(job_id, None)
        BUILD_LOCK.release()

    status = "success" if rc == 0 else "failed"
    sha = ""
    if rc == 0 and Path(extra_vars["final_path"]).exists():
        import hashlib
        h = hashlib.sha256(Path(extra_vars["final_path"]).read_bytes())
        sha = h.hexdigest()
        Path(f'{extra_vars["final_path"]}.sha256').write_text(f"{sha}  {extra_vars['final_name']}\n")
    with db() as con:
        con.execute("UPDATE builds SET status=?, final_path=?, sha256=?, finished=? WHERE id=?",
                    (status, extra_vars.get("final_path", ""), sha, now(), job_id))
    audit("system", f"build.{status}", f"job={job_id} rc={rc}")

    # optional auto boot-test on successful build (lock is still held here)
    if rc == 0 and extra_vars.get("boot_test"):
        _boottest_worker(job_id, extra_vars["final_path"])



class BuildRequest(BaseModel):
    distro: str
    version: str
    disk_size: str | None = None
    patch_mode: str = "targeted"       # targeted | full | custom | none
    patch_profile: str | None = None   # key from config/patches.yml (custom mode)
    patch_packages: list[str] | None = None   # ad-hoc exact packages (pkg=ver)
    patch_commands: list[str] | None = None   # ad-hoc shell snippets
    switch_repo: bool = True
    boot_test: bool = False      # run a boot test after the build succeeds
    admin_user: str | None = None
    admin_ssh_key: str | None = None
    root_password: str | None = None
    timezone: str | None = None
    mirror_url: str | None = None


@app.get("/api/patches", dependencies=[Depends(require_token)])
def list_patches():
    profs = _load_patches().get("profiles", {})
    return [{"key": k, "label": v.get("label", k), "family": v.get("family", "any"),
             "distros": v.get("distros", [])}
            for k, v in profs.items()]


@app.post("/api/builds", dependencies=[Depends(require_token)])
def create_build(req: BuildRequest):
    if not BUILD_LOCK.acquire(blocking=False):
        raise HTTPException(409, "another build is already running — wait for it to finish")
    try:
        ev = resolve_build(req)
    except Exception:
        BUILD_LOCK.release()
        raise
    safe_params = req.model_dump()
    if safe_params.get("root_password"):
        safe_params["root_password"] = "***masked***"
    if safe_params.get("admin_ssh_key"):
        safe_params["admin_ssh_key"] = safe_params["admin_ssh_key"][:20] + "..."

    with db() as con:
        cur = con.execute(
            "INSERT INTO builds(created,distro,version,params,status) VALUES(?,?,?,?,'queued')",
            (now(), req.distro, req.version, json.dumps(safe_params)))
        job_id = cur.lastrowid
    audit("api-client", "build.created",
          f"job={job_id} {req.distro} {req.version} disk={ev['disk_size']} "
          f"patch={req.patch_mode}{('/' + ev['patch_desc']) if 'patch_desc' in ev else ''} "
          f"repo_switch={req.switch_repo}")
    threading.Thread(target=run_job, args=(job_id, ev), daemon=True).start()
    return {"job_id": job_id, "status": "queued"}


@app.get("/api/builds", dependencies=[Depends(require_token)])
def list_builds():
    with db() as con:
        rows = con.execute("SELECT * FROM builds ORDER BY id DESC LIMIT 100").fetchall()
    return [dict(r) for r in rows]


@app.get("/api/builds/{job_id}", dependencies=[Depends(require_token)])
def get_build(job_id: int):
    with db() as con:
        row = con.execute("SELECT * FROM builds WHERE id=?", (job_id,)).fetchone()
    if not row:
        raise HTTPException(404, "no such build")
    return dict(row)


@app.get("/api/builds/{job_id}/log", dependencies=[Depends(require_token)],
         response_class=PlainTextResponse)
def get_log(job_id: int, tail: int = 0):
    p = LOG_DIR / f"{job_id}.log"
    if not p.exists():
        return "(no log yet)"
    data = p.read_text(errors="replace")
    if tail:
        return "\n".join(data.splitlines()[-tail:])
    return data


@app.get("/api/builds/{job_id}/boottestlog", dependencies=[Depends(require_token)],
         response_class=PlainTextResponse)
def get_boottest_log(job_id: int, tail: int = 0):
    p = LOG_DIR / f"{job_id}.boottest.log"
    if not p.exists():
        return "(no boot test log yet)"
    data = p.read_text(errors="replace")
    if tail:
        return "\n".join(data.splitlines()[-tail:])
    return data


@app.post("/api/builds/{job_id}/boottest", dependencies=[Depends(require_token)])
def boottest_build(job_id: int):
    with db() as con:
        row = con.execute("SELECT * FROM builds WHERE id=?", (job_id,)).fetchone()
    if not row:
        raise HTTPException(404, "no such build")
    img = row["final_path"]
    if not img or not Path(img).exists():
        raise HTTPException(400, "build has no final template image to boot")
    threading.Thread(target=run_boottest_manual, args=(job_id, img), daemon=True).start()
    return {"job_id": job_id, "status": "boottest_running"}



@app.get("/api/audit", dependencies=[Depends(require_token)])
def list_audit(limit: int = 200):
    limit = max(1, min(limit, 1000))
    with db() as con:
        rows = con.execute("SELECT * FROM audit_log ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    return [dict(r) for r in rows]


@app.get("/")
def index():
    return FileResponse(BASE / "server/static/index.html")


# --------------------------------------------------- catalog management
class CatalogEntryIn(BaseModel):
    distro: str                      # id: lowercase letters/digits/-/_ ; may be NEW
    family: str | None = None       # required when creating a new distro: deb | rpm
    label: str | None = None        # display name for a new distro
    version: str                     # e.g. "24.04", "9"
    image_url: str
    sums_url: str
    sums_algo: str = "sha256"        # sha256 | sha512 (deb family is auto-verified)
    filename: str | None = None     # default: basename of image_url
    # deb-family, per version:
    codename: str | None = None
    kernel_pkg: str | None = None
    # rpm-family, per DISTRO (only needed when creating a new distro):
    repo_dir: str | None = None
    gpg_key_id: str | None = None
    upstream_key_url: str | None = None


@app.get("/api/catalog", dependencies=[Depends(require_token)])
def get_catalog():
    return {
        "defaults": CATALOG["defaults"],
        "distros": {
            k: {"label": d.get("label", k), "family": d["family"],
                "repo_dir": d.get("repo_dir", ""),
                "gpg_key_id": d.get("gpg_key_id", ""),
                "upstream_key_url": d.get("upstream_key_url", ""),
                "versions": sorted(d["versions"], reverse=True)}
            for k, d in CATALOG["distros"].items()
        },
    }


@app.post("/api/catalog/entries", dependencies=[Depends(require_token)])
def add_catalog_entry(v: CatalogEntryIn):
    d_id = v.distro.strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", d_id):
        raise HTTPException(400, "distro id must be lowercase letters/digits/-/_")
    ver = str(v.version).strip()
    if not ver:
        raise HTTPException(400, "version is required")
    if not v.image_url.startswith(("http://", "https://")):
        raise HTTPException(400, "image_url must be http(s)")

    distros = CATALOG["distros"]
    new_distro = d_id not in distros
    fam = (v.family or (distros[d_id]["family"] if not new_distro else "")).strip()
    if fam not in ("deb", "rpm", "suse"):
        raise HTTPException(400, "family must be 'deb', 'rpm' or 'suse' (required for new distros)")

    if new_distro:
        entry = {"label": (v.label or d_id.title()), "family": fam, "versions": {}}
        if fam == "rpm":
            if not (v.repo_dir and v.gpg_key_id and v.upstream_key_url):
                raise HTTPException(400,
                    "new rpm distro requires repo_dir, gpg_key_id and upstream_key_url")
            entry.update(repo_dir=v.repo_dir.strip(), gpg_key_id=v.gpg_key_id.strip(),
                         upstream_key_url=v.upstream_key_url.strip().rstrip("/"))
        distros[d_id] = entry
    else:
        if distros[d_id]["family"] != fam:
            raise HTTPException(400, f"'{d_id}' is a '{distros[d_id]['family']}' distro")
        if ver in distros[d_id]["versions"]:
            raise HTTPException(409, f"{d_id} {ver} already exists")

    vent = {
        "image_url": v.image_url.strip(),
        "sums_url": v.sums_url.strip(),
        "sums_algo": (v.sums_algo or "sha256").strip(),
        "filename": (v.filename or Path(urlparse(v.image_url).path).name).strip(),
    }
    if fam == "deb":
        vent["codename"] = (v.codename or ver).strip()
        vent["kernel_pkg"] = (v.kernel_pkg or (
            "linux-image-virtual" if d_id == "ubuntu" else "linux-image-amd64")).strip()
    distros[d_id]["versions"][ver] = vent
    save_catalog()

    action = "catalog.distro_added" if new_distro else "catalog.version_added"
    audit("api-client", action, f"{d_id} {ver} ({fam})")
    return {"ok": True, "distro": d_id, "version": ver, "new_distro": new_distro}


@app.delete("/api/catalog/entries/{d_id}/{ver}", dependencies=[Depends(require_token)])
def delete_catalog_entry(d_id: str, ver: str):
    distros = CATALOG["distros"]
    if d_id not in distros or ver not in distros[d_id]["versions"]:
        raise HTTPException(404, "no such catalog entry")
    del distros[d_id]["versions"][ver]
    removed_distro = False
    if not distros[d_id]["versions"]:
        del distros[d_id]
        removed_distro = True
    save_catalog()
    audit("api-client", "catalog.entry_deleted",
          f"{d_id} {ver}" + (" (distro removed: no versions left)" if removed_distro else ""))
    return {"ok": True, "removed_distro": removed_distro}


@app.post("/api/catalog/verify", dependencies=[Depends(require_token)])
def verify_catalog_urls(payload: dict):
    """HEAD-check image/checksum URLs so bad entries are caught before building."""
    out = {}
    for key in ("image_url", "sums_url"):
        u = (payload.get(key) or "").strip()
        if not u:
            continue
        try:
            req = urllib.request.Request(u, method="HEAD",
                                         headers={"User-Agent": "template-generator"})
            with urllib.request.urlopen(req, timeout=20) as resp:
                out[key] = {"status": resp.status, "length": resp.headers.get("Content-Length", "?")}
        except Exception as exc:                                # noqa: BLE001
            out[key] = {"status": "error", "error": str(exc)[:200]}
    return out


@app.get("/")
def index():
    return FileResponse(BASE / "server/static/index.html")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("TG_PORT", "8080")))
