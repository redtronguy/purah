# wolf-stream — Design (v1)

Status: **build-ready.** Compose + config validated against the live host probe (2026-06-16) and
the upstream Wolf `stable` requirements. Probed host facts are in `README.md`; the host-vs-portable
boundary is in `docs/PORTABILITY.md`.

## 1. Architecture

```
NAS host (TrueNAS SCALE 25.10.3.1, host Docker 28.3.1, kernel 6.12.33, runc)
 ├─ NAS: media pool + app_storage_2 (apps + democratic-csi iSCSI) ──► k8s PVCs
 │     (PROTECTED — Wolf must never starve the iSCSI path; see §4)
 ├─ Plex / Tdarr  ── /dev/dri (Arc A770) + group_add[44,107,568] ─┐
 └─ wolf (custom app) ── /dev/dri + group_add[44,107,568] ────────┤  Arc render node = concurrent share
        │  network_mode: host                                     │  (no exclusivity, no passthrough)
        │  /var/run/docker.sock  ─────────────────────────────────┘
        │  uinput/uhid via /dev bind + c 10:* cgroup (virtual gamepad/kbd/mouse/HID)
        │  config: /mnt/games/wolf   (HOST_APPS_STATE_FOLDER)
        └─ spawns on demand ─► ghcr.io/games-on-whales/steam:edge  (Sway + Steam Big Picture)
                                  library: /mnt/games/steam  (chown 1000:1000)
                                  game cpu/mem cap: base_create_json NanoCpus+Memory

  Moonlight client ── LAN ──► the NAS host ($NAS_HOST) :
        47984/tcp(HTTPS) 47989/tcp(HTTP) 47999/udp(ctrl) 48010/tcp(RTSP) 48100/udp(video) 48200/udp(audio)
        + mDNS 5353/udp for discovery
```

Wolf is a **session broker**: it runs persistently, advertises to Moonlight, and on launch spins up
a *child* Steam container (over the host docker socket) wired to the GPU + virtual input. That
docker.sock dependency is the central design fact (drives both the security posture and the
non-portability to Talos — see PORTABILITY.md).

## 2. GPU sharing (the deciding constraint) — mirror Tdarr/Plex EXACTLY

The A770 stays on the host. The **proven recipe** (verbatim from the live `ix-tdarr-tdarr-1` and
`ix-plaza-plex-1` `docker inspect`) is:

```
devices:    [ /dev/dri:/dev/dri ]          # whole dir, card0 + renderD128
group_add:  [ "44", "107", "568" ]         # video, render, apps GIDs — REQUIRED to open the 226:* nodes
runtime:    runc                           # NO nvidia runtime, NO vfio/passthrough
```

`group_add` is **not optional**: the render nodes are `crw-rw---- root:render`, so without the
container UID being in the `render`/`video` groups it cannot open them. Plex + Tdarr already hold the
single A770 concurrently this way; Wolf becomes the third consumer identically.

**Virtual input is exposed via the `/dev` bind, not a static `devices:` entry.** `/dev/uinput`
(misc 10,223) and `/dev/uhid` (misc 10,239) are misc-major-**10** nodes whose kernel module is loaded
only by the POST INIT script. Listing them in `devices:` would (a) hard-fail container-create if the
node were ever absent and (b) race the boot — the app can autostart before the POST INIT runs. So
they are reached through the broad `/dev:/dev:rw` mount plus the cgroup allow `c 10:* rmw` (the misc
major). Without that `c 10:*` rule the cgroup controller returns EPERM on `open()` and virtual input
silently dies — so the three cgroup rules are `c 10:*` (uinput/uhid), `c 13:*` (the virtual input
pads), `c 226:*` (DRM /dev/dri). Both nodes already exist as static nodes on the NAS host even pre-modprobe
(probe 2026-06-16), but the module must be loaded for them to **function**.

`WOLF_RENDER_NODE=/dev/dri/renderD128` pins Wolf's own compositor/encode to the Arc. The Plex/Tdarr
`NVIDIA_*` env vars are **inert image leftovers** (runtime=runc ignores them) and are deliberately
NOT copied into Wolf.

## 3. Encode — Intel Arc A770 (DG2/Alchemist), `va` low-power, HEVC-first

- Driver: `i915` (bound; `xe` also present but i915 is correct for Alchemist HuC). VA-API via
  `intel-media-driver` (iHD) — `LIBVA_DRIVER_NAME=iHD`. Proven live: Tdarr `vainfo` shows iHD 26.2.0,
  HW decode + low-power encode for H.264/HEVC/HEVC-10/VP9.
- Encoder selection: Wolf walks the `config.toml` encoder lists and picks the first that inits. With
  no NVIDIA it lands on **`va`**. We force the **low-power (lp)** variants first
  (`vah265lpenc`/`vah264lpenc`/`vaav1lpenc`) — Arc A-series uses LP encode by default and it's the
  validated path. **Avoid `qsv`** (MFX_ERR_UNSUPPORTED / grey-frame class on this Arc).
- Codec priority (Moonlight LAN): **HEVC primary -> H264 fallback -> AV1 opt-in only** (Arc AV1 is the
  most unstable path; comment out the AV1 blocks if it misbehaves).
- Known Arc bug: `vapostproc` segfault/30fps-pin on DG2 (intel media-driver #1800). If the stream is
  grey/corrupt or stuck at 30fps, swap `vapostproc -> videoconvert` in the encoder `video_params`
  (loses zero-copy, gains stability). Full guidance inline in `config.steam-profile.reference.toml`.

## 4. Reliability — protecting the NAS / its iSCSI targets

app_storage_2 backs the democratic-csi iSCSI target for the k8s cluster, including **critical
Postgres** (rebooting/overloading the NAS host can flip those PVCs read-only). A runaway game must
never contend it to death.

- **Two-layer Docker limits** (BOTH required — they cap different containers):
  - Wolf controller: `deploy.resources.limits` `cpus '12.0'` / `memory 20G` in the compose.
  - The game itself runs in a **separate** sibling container, so its cap lives in the Steam profile's
    `base_create_json` → `HostConfig.NanoCpus 12000000000` (12 CPU) / `Memory 21474836480` (20 GiB).
    A limit on the Wolf container alone does **not** bound the game.
- Memory kept well under 31G so ZFS ARC + iSCSI always have headroom.
- Wolf config (`games/wolf`) and the Steam library (`games/steam`) live on the **dedicated `games`
  NVMe pool**, never on app_storage_2 — no shared dataset with the iSCSI path.
- **No `:latest`** — pin `wolf:stable` (then its digest after first good deploy) and `steam:edge`
  (then its digest). Upgrades are deliberate (the n8n lesson).
- `restart: unless-stopped` + healthcheck via a pure-shell `/proc/net/tcp` LISTEN check on 47989
  (the Wolf `:stable` image has **no curl** — verified by probe; it ships wget + /proc/net/tcp, so the
  healthcheck depends on no external binary); autostart via the TrueNAS app system.

## 5. Storage

`games` pool (928G single NVMe stripe, **no redundancy** — created M0). Datasets (middleware-first):

> **Known consequence of M0 (boot-pool redundancy loss).** M0 freed the NVMe by detaching it from the
> boot **mirror** (`boot.detach nvme0n1p3`) before wiping it into `games`. the NAS host's **boot pool is now
> a single disk (`sda3`, no redundancy)** — a latent boot-resilience regression on the same
> host that serves the iSCSI path. Not a Wolf-deploy blocker, but it should be tracked: a
> boot-disk failure now takes the NAS host (and thus Plex/Tdarr/arr/iSCSI) offline with no boot-pool
> redundancy. **Decision pending:** restore a boot mirror from a spare disk, or accept single-disk
> boot. Recorded here so it is not silent.

- `games/wolf`  → Wolf config/state: `config.toml` (v7), `key.pem`/`cert.pem` (Moonlight host
  identity), paired-client certs, per-app `profile_data/`. Also holds the `uinput-init.sh` +
  `85-wolf-virtual-inputs.rules` masters.
- `games/steam` → Steam library (`steamapps`, `compatdata`), **chown 1000:1000, perms 777** so the
  in-container user (UID 1000) can write.

No redundancy by design — the Steam library is re-downloadable; the only irreplaceable bit is
`games/wolf` (pairings + config), which is small and **backed up to MinIO at M5**. Losing it = re-pair
every client + re-login Steam.

## 6. Networking (LAN-only, v1)

`network_mode: host` (required for Moonlight mDNS discovery + fixed UDP/TCP ports; bridge breaks
discovery/streaming and is unsupported upstream). With host net the compose `ports:` block is ignored;
Wolf binds directly on the NAS host ($NAS_HOST): `47984/tcp 47989/tcp 47999/udp 48010/tcp 48100/udp 48200/udp`.
No collision with TrueNAS-owned ports (80/443 UI, 5353 avahi).

**LAN-only is enforced at the network layer, not by Wolf** (Moonlight pairing is PIN-based with no
built-in LAN restriction). Do NOT port-forward the 4798x/481xx range; no CF tunnel, no WAN. This is
load-bearing because `docker.sock` access makes a paired client effectively host-root on the NAS host.

## 7. Security posture (inherent to Wolf's design)

Mounting `/var/run/docker.sock:rw` gives the Wolf container — and, transitively, anyone who reaches a
Moonlight port and completes the PIN flow + launches an app — **root-equivalent control of the NAS host's
docker engine** (Plex, the arr stack, everything). Mitigation = strictly LAN-only,
trusted clients only, never expose the ports. This is structural, not a misconfiguration.

## 8. Future (out of v1 scope)

- **More app profiles**: GOG / Heroic (Epic+GOG), Lutris, RetroArch + emulators, a desktop (XFCE)
  profile. Each is another `[[profiles.apps]]` block with its own child image — additive, no
  re-architecture. (Wolf auto-generates a full catalog; v1 just trims it to Steam.)
- **Multi-session / multi-user**: Wolf supports multiple concurrent Moonlight sessions (each its own
  child container + virtual display). Bounded by the A770's shared media/render engines + 16GB VRAM
  and the host CPU/RAM caps — a later capacity exercise, not a v1 goal.
- **WAN access**: WireGuard/Tailscale **only** (never raw port-forward), with latency tuning.

## 9. Known caveats carried into operation

- **Steam auto-update only while a session runs.** The Steam child container exists only for the
  duration of a Moonlight session (`WOLF_STOP_CONTAINER_ON_EXIT=TRUE`). Steam therefore updates games
  **only while you're connected** — there is no background/idle updater. Expect to leave a session
  open for large updates, or accept update-on-launch.
- **uinput is the one host prereq not already satisfied** by the Plex/Tdarr reference (they don't use
  it). Module load + perms are handled by the POST INIT `uinput-init.sh`; without it, input is dead.
  It is exposed via the `/dev` bind + `c 10:* rmw` (not a static `devices:` entry) to avoid a
  boot-order race with the POST INIT module load.
- **GPU is shared, not isolated.** Heavy Plex transcode + Tdarr encode + a game stream contend the
  one A770 (dual MFX engines help, but VRAM + render engine are shared). Expect contention/frame
  drops under triple load, not a crash. No hard QoS without SR-IOV/VFIO (not viable while Plex/Tdarr
  need the same card).
- **Boot pool has no redundancy** since M0 (see §5) — a host-resilience item to decide on, independent
  of Wolf.
