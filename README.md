# template-generator

Web UI + Ansible backend that builds minimal, hardened **KVM templates** for
**Proxmox** and **CloudStack** — Ubuntu / Debian / Rocky / AlmaLinux.

```
Browser ──HTTP──> FastAPI server (SQLite: builds + audit log)
                      │ spawns ansible-playbook per job
                      ▼
        ansible/build-template.yml ──> libguestfs on localhost
          ├─ downloads official cloud image (+ checksum verify)
          ├─ virt-resize to target disk size
          ├─ rewrites repos → http://mirror.biznetgio.com
          ├─ installs qemu-guest-agent (+ growpart support)
          ├─ patches kernel* + openssh*  (CVE mode) or full upgrade
          ├─ CloudStack datasource + password-management service
          ├─ serial console ttyS0, timezone, admin user (optional)
          ├─ grub/grub2-install (re-embed bootloader after resize)
          ├─ virt-sysprep: logs, machine-id, host keys, hwaddr
          └─ compact qcow2 + sha256 sidecar in output/
```

Supported distros/versions live in **`config/catalog.yml`** — manage them
from the **Catalog** tab in the dashboard (add/remove image versions, URL
pre-check, audit-logged) or edit the YAML by hand; both are picked up live,
no restart needed.

| Distro | Versions |
|---|---|
| Ubuntu    | 24.04 (minimal), 22.04 (minimal) |
| Debian    | 13, 12, 11 |
| Rocky     | 10, 9 |
| AlmaLinux | 10, 9 |

## Install

```bash
dnf install -y guestfs-tools qemu-img ansible-core   # RHEL-family build host
pip3 install fastapi uvicorn pyyaml
```

Run as root. Nested KVM is *not* required — libguestfs customizes offline
(TCG emulation, slower but works anywhere).

## Install — one click

Copy the project to the target build server and run the installer:

```bash
# copy to target (or git clone / scp the repo)
scp -r template-generator root@buildhost:/opt/
ssh root@buildhost

cd /opt/template-generator
./install.sh                          # port 8080, token changeme
./install.sh --port 8443 --token MySecret --bind 0.0.0.0
```

What it does automatically:

- detects OS (RHEL-family or Debian-family) and installs prerequisites
  (`libguestfs-tools`, `qemu-img`, `ansible-core`, `python3`)
- creates a python venv with `fastapi`/`uvicorn`/`pyyaml`
  (no system-python pollution, bypasses PEP 668)
- deploys to `/opt/template-generator` as a **systemd service**
  (`template-generator.service`, auto-start on boot, auto-restart)
- opens the firewall port (firewalld/ufw) when one is active
- prints the URL, token and a quick-check curl

Flags: `--install-dir` · `--unit-name` · `--port` · `--token` · `--bind` ·
`--no-firewall` · `--skip-packages`

**Re-running the installer = upgrade**: code is refreshed while your
`config/`, `cache/`, `output/` and build history are preserved.

Manual alternative — `TG_TOKEN=your-secret ./run-server.sh` serves on :8080.

## CLI (no server needed)

`build.sh` runs the same pipeline standalone:

```bash
./build.sh --list                          # show supported distros/versions
./build.sh -d ubuntu -v 24.04              # default: 20G disk, CVE patch
./build.sh -d rocky -v 9 --disk-size 20G --test
./build.sh -d debian -v 12 --full-update --no-repo
```

Output lands in `output/` as `<distro>-<version>-kvm-bios-<stamp>.qcow2`
with a `.sha256` sidecar. `--test` boots the result headlessly with qemu
and reports whether it reaches a login prompt.

## Troubleshooting

- **SELinux Enforcing** and `virt-customize` fails: the libguestfs appliance
  may be blocked. `setsebool -P virt_use_execmem 1` or run with SELinux
  permissive/disabled on the build host.
- **No /dev/kvm**: builds run under TCG emulation (slower, still works).
- **`error: no such partition` / grub rescue at boot**: the template was
  built with a version **before** the bootloader-reinstall fix — `virt-resize`
  renumbers GPT partitions and GRUB's embedded core.img keeps pointing at the
  old partition number. Rebuild the template; existing images cannot be
  repaired in place.
- **virt-resize fails with `deficit of ... bytes`**: the target disk size is
  smaller than (or equal to) the base image. Rocky/AlmaLinux GenericCloud
  images are already 10 GiB — use the 20G default or a larger `--disk-size`.

Open `http://<buildhost>:8080`, paste the token, fill the form:

- distro / version / disk size
- patch mode: **kernel+openssh (CVE)** · full update · **custom** · none
- custom = named profile from `config/patches.yml` (exact kernel/kmod
  versions, holds, workarounds) or ad-hoc packages/commands typed per build
- **Run boot test after build**: boots the finished image headlessly and
  checks it reaches a login prompt without a kernel panic (guards against
  bad pinned kernels / kmods from the custom stage)

### Boot testing

Every ready template has a **Boot** column with a `test` button, and you can
tick "Run boot test after build" to do it automatically. The test boots the
`.qcow2` with `-snapshot` (never modifies the master), captures the serial
console, and reports `pass` / `fail` (panic) / `inconclusive` (timed out
before login, usually slow TCG). KVM is used automatically when `/dev/kvm`
exists; otherwise it falls back to TCG (much slower).

View the serial boot log via the `log` link next to the result.
- repo switch on/off (private mirror)
- optional: timezone, admin user + SSH key, emergency root password

Watch live ansible output in the log pane; every action lands in the
**Audit Log** tab (build created / started / success / failed, who & when).

## Custom patch profiles

`config/patches.yml` defines reusable profiles for provider-specific requests:
exact kernel versions (`linux-image-virtual=5.15.0-107.117`), kmod pins,
module blacklists, default-kernel selection, package holds and arbitrary
workaround commands. The dashboard exposes them under
*Patch mode → custom*, together with ad-hoc packages/commands fields.
Every use is recorded in the audit log (`patch=custom/profile:<name>`).

## API

```bash
curl -H 'X-Token: ...' http://localhost:8080/api/catalog       # list options
curl -H 'X-Token: ...' -X POST http://localhost:8080/api/builds \
  -H 'Content-Type: application/json' \
  -d '{"distro":"rocky","version":"9","patch_mode":"targeted"}'
curl -H 'X-Token: ...' http://localhost:8080/api/builds         # queue/status
curl -H 'X-Token: ...' http://localhost:8080/api/builds/1/log   # ansible log
curl -H 'X-Token: ...' http://localhost:8080/api/audit          # audit trail
```

One build runs at a time (guestfs is heavy); extra requests get HTTP 409.

## Deploying templates

### Proxmox
```bash
qm create 9000 --name tpl-debian-12 --bios seabios --ostype l26 \
  --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci --serial0 socket --agent enabled=1 --vga std
qm importdisk 9000 output/debian-12-kvm-bios-*.qcow2 local-lvm
qm set 9000 --scsi0 local-lvm:vm-9000-disk-0,iothread=1,discard=on
qm set 9000 --boot order=scsi0 && qm template 9000
# cloud-init seed: attach cidata ISO as ide2 if you need custom user-data
```

### CloudStack
Register the qcow2: Hypervisor **KVM**, format **QCOW2**, BIOS boot,
tick **Password Enabled** (the baked-in `set-guest-password` service pulls the
password from the virtual router on first boot).

## Layout

```
run-server.sh              start web server
config/catalog.yml         distro/version/image catalog (UI reads this)
ansible/build-template.yml the actual build logic
server/app.py              FastAPI: jobs, audit log, build resolution
server/static/index.html   single-file Web UI
assets/cloudstack/         password agent + systemd unit
assets/cloud/              cloud-init datasource config (NoCloud+CloudStack)
build.sh                   legacy CLI (same pipeline, no server needed)
cache/ output/             base images & finished templates
```

## Notes

- Root partition grows to the requested disk size via cloud-init growpart on
  first boot (standard cloud-image behaviour).
- The bootloader (grub/grub2-install) is re-run after `virt-resize`: resizing
  renumbers GPT partitions (Ubuntu images number them 14/15/16/1), which
  would otherwise leave GRUB's embedded core.img pointing at a partition that
  no longer exists (`error: no such partition` → grub rescue).
- The default disk size is 20G; Rocky/AlmaLinux GenericCloud base images are
  already 10 GiB, so a 10G target cannot fit them.
- Rocky/Alma upstream `.repo` files are moved aside into
  `/etc/yum.repos.d.disabled/` (not deleted).
- EPEL from your mirror is pre-configured but disabled.
