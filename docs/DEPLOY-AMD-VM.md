# Purah on a Proxmox VM — AMD Radeon RX 6950 XT (second instance)

The second Purah instance, proving the **universal container + per-host env** model
([PORTABILITY.md](PORTABILITY.md)). Reference host = Intel Arc (TrueNAS app); **this one = AMD Radeon** (Proxmox VM).
Same `compose/docker-compose.universal.yaml`; only `env/amd-radeon.example.env` differs.

## Host
- **Proxmox node** (`$PVE_HOST`). GPUs: **AMD Radeon RX 6950 XT** (Navi 21, `03:00.0`,
  dedicated) + Intel UHD 750 iGPU (host display).
- VFIO was already prepared: `/etc/modprobe.d/vfio.conf` binds `1002:73a5,1002:ab28` to vfio-pci,
  amdgpu/radeon blacklisted, IOMMU active (groups 20/21, isolated). **No host reboot needed.**

## VM (`purah`, `$STREAM_HOST`)
- q35 / OVMF, cpu host, 12 cores, 24 GB RAM, **40 GB boot** on local-lvm (small base).
- `hostpci0: 0000:03:00,pcie=1` — the whole Radeon (GPU + HDMI-audio fn) passed through.
- Debian 13 cloud-init image. **Purge the `-cloud` kernel and install `linux-image-amd64`** — the
  slim cloud kernel lacks the `amdgpu` module, so `/dev/dri` never appears until you boot the full
  kernel. Also enable `non-free-firmware` apt component and install `firmware-amd-graphics` (Navi 21
  firmware) — without it amdgpu won't init. After reboot: `amdgpu` loads, `/dev/dri/renderD128`
  (→ amdgpu), VCN encode rings up.
- Docker via get.docker.com; your user in the `docker` group; qemu-guest-agent for IP discovery.

## Storage — 3 TB iSCSI from a TrueNAS iSCSI target (`$ISCSI_PORTAL`)
- TrueNAS (`$ISCSI_PORTAL`): sparse 3 TiB zvol `<pool>/gaming/purah` + iSCSI extent/target
  `$ISCSI_TARGET_IQN`.
- VM is the **initiator** (`/etc/iscsi/initiatorname.iscsi` = `$ISCSI_INITIATOR_IQN`, added
  to the target's initiator group). Login `node.startup=automatic`, xfs, mounted `/mnt/games` (`_netdev,nofail`),
  with `wolf/` + `steam/` (steam chowned 1000:1000).

## Host input prep (Debian — simpler than TrueNAS)
- `/etc/modules-load.d/wolf-uinput.conf` = `uinput`,`uhid`; `input` group; udev rule
  `85-wolf-virtual-inputs.rules` in `/etc/udev/rules.d/`. (No POST-INIT dance — Debian doesn't
  reimage root on upgrade.)

## Deploy
```
cp env/amd-radeon.example.env .env   # then edit for your host
docker compose -f compose/docker-compose.universal.yaml --env-file .env up -d
```
Verified live: `h264/h265 encoder: va` (VAAPI on the Radeon), **"zero copy pipeline on AMD
(/dev/dri/renderD128)"**, Moonlight ports 47984/47989/47999/48010 listening, container healthy.
AV1 falls back to software (Navi 21 has no AV1 *encode*) — HEVC/H264 hardware is the stream path.
Wolf auto-generated `config.toml` with Steam/Firefox/RetroArch apps.

## Remaining (interactive, user)
- **Pair Moonlight**: point a Moonlight client at `$STREAM_HOST`, enter the PIN at the Wolf UI /
  `https://$STREAM_HOST:47984`. LAN-only (no WAN/tunnel), same as the TrueNAS instance.
