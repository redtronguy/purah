# wolf-stream — Milestones

Each milestone was tracked as an issue. "Build-gated": don't advance until the verify
step (the VERIFICATION GATE in the runbook) passes. Scope is tight — **Steam-only / LAN-only** for v1.

| # | Milestone | Done when | Status |
|---|---|---|---|
| **M0** | **Storage prep** — free NVMe, `games` pool | NVMe detached from boot mirror, wiped, `games` pool ONLINE + middleware-registered | ✅ **DONE 2026-06-16** |
| **M1** | **Host prep** — datasets + uinput | `games/wolf` + `games/steam` datasets created (middleware); `games/steam` chown 1000:1000; `uinput-init.sh` + `85-wolf-virtual-inputs.rules` staged on `/mnt/games/wolf`; POST INIT script registered (GUI/`initshutdownscript.create`); `lsmod` shows `uinput`; `/dev/uinput`+`/dev/uhid` are `0660 input` | ✅ **DONE 2026-06-17** |
| **M2** | **Wolf app deploy** | Wolf running as a TrueNAS **custom app** (host net, `/dev/dri`+`group_add[44,107,568]`, `/dev`+`run/udev` bind exposing uinput/uhid, `docker.sock`, config on `games/wolf`, `HOST_APPS_STATE_FOLDER=/mnt/games/wolf`, cpu/mem limits); `config.toml` v7 auto-generated; healthcheck green (`/proc/net/tcp` LISTEN on 47989) | ✅ **DONE 2026-06-17** |
| **M3** | **Steam session profile** | the AUTO-GENERATED `config.toml` trimmed to the Steam profile per `config.steam-profile.reference.toml` (library mount + `base_create_json` caps); Wolf spawns `ghcr.io/games-on-whales/steam:edge` (Sway + Big Picture); **Steam logged in** (interactive); Wolf log shows `Selected HEVC encoder: va`; A770 HW **encode** confirmed during a session (`intel_gpu_top`) | ☐ |
| **M4** | **Moonlight LAN stream** | Client **pairs** (PIN); first end-to-end stream; codec (HEVC primary) + bitrate + res/fps **tuned**; gamepad/kbd/mouse input verified (proves uinput) | ☐ |
| **M5** | **Reliability hardening** | Resource limits validated under concurrent **Plex+Tdarr** load (no iSCSI/ARC starvation); image tags pinned to digests; autostart on; healthcheck passing; `games/wolf` **backed up to MinIO**; post-upgrade-restore documented; deploy reproducible from this repo | ☐ |

### Validated facts now baked into the build (was open at draft time)
- **Image tags are rolling**, not semver: pin `ghcr.io/games-on-whales/wolf:stable` and the child
  `ghcr.io/games-on-whales/steam:edge`; capture digests after first good deploy. (Git tags stop at
  v2024.07 — they are NOT deploy versions.)
- **GPU share = Tdarr/Plex recipe**: `devices:[/dev/dri:/dev/dri]` + `group_add:["44","107","568"]`,
  runc, no passthrough. `group_add` is mandatory (render nodes are `root:render` 0660).
- **Virtual input via `/dev` bind + `c 10:* rmw`**, NOT a static `devices:` entry — uinput/uhid are
  misc-major-10 and the module loads only at POST INIT, so a static entry would race the boot. cgroup
  rules: `c 10:*` (uinput/uhid), `c 13:*` (virtual pads), `c 226:*` (DRM).
- **Healthcheck uses `/proc/net/tcp` (no curl in the Wolf image)** — verified by probe; wget present.
- **`:stable` digest at probe**: `sha256:6d2dc982232cf0dc7893b93ef365cb37d2729112c745e2742ae26f00511c0f73`.
- **Encoder = Intel `va` low-power (lp), iHD driver, HEVC-first**; avoid `qsv`; `vapostproc->videoconvert`
  fallback for the DG2 segfault bug. AV1 opt-in only.
- **Two-layer limits**: Wolf controller via `deploy.resources.limits`; the **game** via the Steam
  profile's `base_create_json` `NanoCpus`/`Memory` (a Wolf-container limit does NOT bound the game).
- **`HOST_APPS_STATE_FOLDER=/mnt/games/wolf`** (host path) — the #1 footgun for non-`/etc/wolf` configs.

### Future (out of v1 scope)
- **More app profiles** — GOG/Heroic (Epic+GOG), Lutris, RetroArch + emulators, XFCE desktop; each is
  an additive `[[profiles.apps]]` block, no re-architecture.
- **Multi-session / multi-user** — Wolf supports concurrent Moonlight sessions (one child + virtual
  display each); a later capacity exercise bounded by the shared A770 + host caps.
- **WAN access** — WireGuard/Tailscale only (never raw port-forward) + latency tuning.

### Operational caveat to carry forward
- **Steam updates games only while a Moonlight session is live** (the Steam child is torn down on
  disconnect — `WOLF_STOP_CONTAINER_ON_EXIT=TRUE`). No background/idle updater; leave a session open
  for large updates or accept update-on-launch.

### M0 record (done)
- `boot.detach nvme0n1p3` → boot-pool single-disk `sda3` , still booting off  (`Boot0002`)
- `disk.wipe nvme0n1 QUICK` (job 154) → clean
- `pool.create games` (stripe nvme0n1, job 158) → 928G ONLINE, middleware-registered

> ⚠️ **M0 side effect — boot-pool now has NO redundancy.** Detaching the NVMe left the boot pool on a
> single disk (`sda3`). A boot-disk failure now takes the NAS host (and Plex/Tdarr/arr/iSCSI)
> offline with no boot mirror. This is **done and not re-runnable here**; flagged as a known
> consequence. **Open decision:** restore a boot mirror from a spare disk vs. accept single-disk boot.
