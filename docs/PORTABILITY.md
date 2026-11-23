# wolf-stream — Portability boundary

Where this deployment is **host-specific to the reference TrueNAS host** vs **portable**, and what it would take to move
it to another Docker host or to Kubernetes.

## TL;DR

- **Docker host -> Docker host: easy.** Wolf is a normal Docker workload. The compose moves nearly
  verbatim; only a handful of host-bound values change (GPU node, GIDs, dataset paths, the uinput
  host prep).
- **Kubernetes: NOT turnkey.** Wolf is an orchestrator that spawns each game/Steam session as a
  **sibling container via the host `/var/run/docker.sock`**. That model has no clean k8s analogue —
  you would be giving a pod the node's docker socket to create containers *outside* the cluster's
  control. The GPU must be physically on the node Wolf lands on, and host networking + virtual-input
  device access add more node-pinning. See "Kubernetes" below.
- **Do NOT target the Talos cluster.** Talos is API-managed, immutable, and has no docker
  socket to hand Wolf, no Arc GPU on its nodes, and is the wrong place for an interactive
  GPU-streaming workload. The right k8s target — if ever — is a **future GPU-equipped k3s node**
  (mutable host, real dockerd or a containerd-CDI GPU path), not Talos.

---

## Host-specific (must change per host)

| Item | Reference value (TrueNAS + Arc) | Why host-specific | How to find it on a new host |
|---|---|---|---|
| GPU render node | `/dev/dri/renderD128` | enumeration order; a host with >1 GPU may number differently | `ls -l /dev/dri/by-path/` ; pick the Arc's `renderD128` |
| `group_add` GIDs | `44` (video), `107` (render), `568` (apps) | GIDs are assigned per host | `getent group video render` ; match the existing Plex/Tdarr `GroupAdd` on that host |
| `device_cgroup_rules` majors | `c 10:*` (misc=uinput/uhid), `c 13:*` (input), `c 226:*` (DRM) | 226 = DRM on Linux generally; 10 = misc; verify | `stat -c '%t' /dev/dri/renderD128` (hex; `e2` = 226); `ls -l /dev/uinput` (10,223) |
| Dataset paths | `/mnt/games/wolf`, `/mnt/games/steam` | pool/dataset layout | create equivalents; set `HOST_APPS_STATE_FOLDER` to the **host** wolf path |
| `HOST_APPS_STATE_FOLDER` | `/mnt/games/wolf` | Wolf passes this to the **host** docker daemon for child mounts — must be a real host path | = the host path you mount at `/etc/wolf` |
| uinput host prep | `modprobe uinput`/`uhid` + udev rule (POST INIT script) | TrueNAS-immutable-FS specific persistence | on a normal distro: `/etc/modules-load.d/uinput.conf` + the udev rule, both survive reboots |
| Encoder family | Intel `va` (iHD), low-power | Arc/DG2-specific tuning | NVIDIA host -> `nvcodec` + the NVIDIA container runtime; AMD -> `va` too but no lp-vs-qsv dance |
| Deploy mechanism | TrueNAS custom app (`app.create`) | TrueNAS-specific GUI/middleware wrapper | plain `docker compose up -d` on a normal Docker host |

## Portable (moves verbatim)

- The whole `services.wolf` shape: `network_mode: host`, the `volumes:` set (docker.sock, /dev,
  /run/udev, /tmp/sockets, config), `restart`, the curl-free `/proc/net/tcp` healthcheck,
  `deploy.resources.limits`, and the `device_cgroup_rules` (`c 10:*`/`c 13:*`/`c 226:*`).
- `config.toml`: the Steam `[[profiles.apps]]` block, the `base_create_json` caps, the encoder-order
  discipline (only the encoder *family* changes for NVIDIA).
- The "GPU is shared via `/dev/dri`, not passed through" design — works on any host whose other
  containers already share the GPU the same way.

## Moving to another Docker host (the easy path)

1. Recreate the two datasets/dirs; chown the steam library to the in-container UID (1000).
2. Do the host uinput prep for that OS (module load + udev rule, persisted the host's way).
3. Fix the host-bound values: render node, `group_add` GIDs, `HOST_APPS_STATE_FOLDER`, paths,
   and confirm the `c 10:*`/`c 13:*`/`c 226:*` majors match (uinput major can differ on exotic kernels).
4. `docker compose up -d` (or that host's app system). Re-pair Moonlight clients (host identity =
   the new `key.pem`/`cert.pem` Wolf generates, unless you copy the old `games/wolf` over).

## Kubernetes (why it is NOT turnkey)

Wolf's session model is the blocker, not the packaging:

1. **Sibling-container spawn via docker.sock.** Wolf creates the Steam container on the *host* docker
   daemon. In k8s there is no host docker socket to mount (containerd/CRI, not dockerd), and even
   where one exists, handing a pod node-level container-create is a host-root escape that defeats the
   cluster's scheduling/isolation. There is no first-class "Wolf spawns a peer pod" path.
2. **GPU must be on Wolf's node.** Requires the device plugin / CDI for that GPU on that node and
   pinning Wolf there (nodeSelector/affinity). The session container needs the same GPU — so it must
   co-locate, which the docker.sock model already forces but k8s does not express natively.
3. **Host networking + virtual input.** `hostNetwork: true` plus `/dev/uinput` + `/dev/uhid` +
   `/run/udev` access means privileged-ish device mounts and node pinning — workable but it makes the
   pod a node-bound, host-coupled special case, not a portable workload.
4. **State.** `games/wolf` (host identity + pairings) must be a node-local or RWO volume on the GPU
   node; you lose the "reschedule anywhere" benefit of k8s.

**Verdict:** keep Wolf on a **mutable Docker host with the GPU physically attached** (the NAS host today).
If it ever must be "in the cluster", the only sane target is a dedicated **GPU-equipped k3s node**
running real dockerd (so the sibling-spawn model still works), pinned and treated as a pet — **never
Talos**. Until such a node exists, Docker on the NAS host is the correct home.
