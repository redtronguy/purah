# Purah

<p align="center"><img src="assets/purah-icon-512.png" width="180" alt="Purah"></p>

**Purah** is a self-hosted GPU game-streaming setup: Steam Big Picture streamed to
[Moonlight](https://moonlight-stream.org/) clients (Apple TV, phones, PCs) on the LAN.
The engine is [**Wolf**](https://github.com/games-on-whales/wolf) from Games on Whales;
"Purah" is the brand and the packaging around it.

It ships two tested deployments of the **same container shape**:

| Instance | Host | GPU | How it runs |
|---|---|---|---|
| **TrueNAS app** | TrueNAS SCALE 25.10 | Intel Arc A770, *shared* with Plex + Tdarr via `/dev/dri` | TrueNAS custom app (`truenas-app/`) |
| **VM** | Debian 13 VM on Proxmox | AMD Radeon RX 6950 XT, PCIe passthrough | `docker compose` + per-host env (`compose/` + `env/`) |

**v1 scope (deliberately minimal: reliable first, expand later):**
- **Steam-only** (Steam Big Picture in a session container spawned by Wolf)
- **LAN-only** Moonlight clients (see the security note below)
- **Shared GPU** on TrueNAS: no passthrough, so the render node serves Wolf, Plex and Tdarr at the same time
- **Survives TrueNAS upgrades**: uinput/udev set up by a POST INIT script whose master copy lives on a data pool

## Why this shape

| Requirement | Decision |
|---|---|
| GPU must be shared with Plex + Tdarr | Docker `/dev/dri` bind-mount (VM passthrough would lock the GPU to one consumer) |
| Must not starve the NAS or its iSCSI targets | Two layers of CPU/memory limits: the Wolf controller *and* the spawned game container |
| Survive TrueNAS OS upgrades | uinput/udev provisioned by a TrueNAS **POST INIT** script; pinned image; config in git |
| Lightweight | One Wolf container + one Steam session container on demand; no orchestration layer |

## Quick start (any Docker host)

```bash
cp env/EXAMPLE.env .env          # or env/amd-radeon.example.env / env/intel-arc.example.env
$EDITOR .env                     # render node, libva driver, group GIDs, state path
sudo mkdir -p /mnt/games/wolf /mnt/games/steam && sudo chown 1000:1000 /mnt/games/steam
sudo cp scripts/healthcheck.sh /mnt/games/wolf/
# host input prep: load uinput/uhid at boot + install scripts/85-wolf-virtual-inputs.rules
docker compose -f compose/docker-compose.universal.yaml --env-file .env up -d
```

Then open Moonlight, find the host and enter the PIN Wolf shows. On TrueNAS, follow
[`docs/RUNBOOK.md`](docs/RUNBOOK.md) instead; on a Proxmox VM with an AMD card, see
[`docs/DEPLOY-AMD-VM.md`](docs/DEPLOY-AMD-VM.md).

## Layout

```
compose/docker-compose.universal.yaml  one compose for every host, driven by an env file
env/                                   EXAMPLE.env + Intel Arc and AMD Radeon examples
truenas-app/
  docker-compose.yaml                  the Wolf custom-app compose (paste into TrueNAS Custom App)
  config.steam-profile.reference.toml  EDIT REFERENCE ONLY: Steam profile + Arc encoder order.
                                       Never copy it to config.toml; Wolf generates the real one.
scripts/
  uinput-init.sh                       POST INIT: modprobe uinput/uhid + perms + reinstall udev rule
  85-wolf-virtual-inputs.rules         udev rule for Wolf's virtual input devices
  healthcheck.sh                       pure-sh liveness probe (the Wolf image has no grep/curl)
docs/
  DESIGN.md                            architecture + reliability rationale
  RUNBOOK.md                           TrueNAS M1–M5 step-by-step, with verification gates
  DEPLOY-AMD-VM.md                     the Proxmox + AMD Radeon instance
  PORTABILITY.md                       what is host-specific vs portable (Docker: easy; k8s/Talos: no)
  MILESTONES.md                        build log of the v1 milestones
```

## Hard-won notes

- **`HOST_APPS_STATE_FOLDER` must be a real host path, mounted at the same path inside the
  container.** Otherwise Wolf writes its identity and pairings to the container's ephemeral FS
  and you re-pair every client after each recreate.
- **The Wolf `:stable` image has only `/bin/sh`**: no grep, curl or wget. Hence the
  `/proc/net/tcp` healthcheck script. (47989 is `0xBB75`, not `0xBB55`.)
- **Don't list `/dev/uinput` in `devices:`.** It races the module load at boot; expose it through
  the `/dev` bind plus `c 10:* rmw` instead.
- **Intel Arc:** prefer the `va` low-power encoders, avoid `qsv`. Debian cloud kernels lack
  `amdgpu`, so install `linux-image-amd64` + `firmware-amd-graphics` for AMD.

## Security

Wolf mounts `/var/run/docker.sock` to spawn game containers. Anyone who can reach the Moonlight
ports and complete PIN pairing effectively gets **root on the host's Docker engine**. Keep it
LAN-only: never port-forward 47984–48200, and use WireGuard/Tailscale if you need remote access.

Site values (IPs, users, IQNs) live in env files, and secrets come from your own secret manager.
None are committed here.

## Credits

Built on [Wolf / Games on Whales](https://github.com/games-on-whales/wolf). Purah is an
independent packaging and is not affiliated with that project.

## License

[MIT](LICENSE)
