## Purah/Wolf on TrueNAS SCALE — M1→M5 execution runbook

**Access:** `ssh "$NAS_USER@$NAS_HOST"` (key auth). `$NAS_USER` is NOT in the docker group and has NO passwordless sudo — every `midclt`/`docker`/privileged read needs `echo "$SUDO_PW" | sudo -S <cmd>`, and the sudo timestamp does NOT persist across the multiplexed ControlMaster, so feed `-S` per sub-command. **If the host runs fail2ban, rapid SSH reconnects can trip it** — use ONE ControlMaster session and space connects.

**ABSOLUTE GUARDRAILS (do not violate in any step):**
- NEVER run anything that cycles the docker daemon (`systemctl restart docker`, daemon.json edits, `docker system prune`). Wolf deploys via `app.create` which runs a scoped `compose up` for ITS stack only — that is fine; a daemon restart is NOT.
- NEVER touch `app_storage_2`, the democratic-csi iSCSI target, or any pool-disrupting / SAS-HBA op. All Wolf storage is on the `games` pool. The POST INIT `udevadm trigger` is subsystem-filtered to misc/input — never run it unfiltered.
- All `games/*` dataset creation is middleware-first (`pool.dataset.create`), never raw `zfs create`.

Legend: **[SAFE-TO-AUTOMATE]** read-only or games-pool-scoped mutation, runnable on user go. **[SCOPED MUTATION]** a write that is bounded but still a mutation — run on explicit go, verify after. **[INTERACTIVE / USER-ONLY]** must be done by the user (GUI or a TLS/Steam/Moonlight interaction).

---

### M1 — Host prep (datasets + uinput bootstrap + POST INIT)

**M1.0 [SAFE-TO-AUTOMATE] Pre-flight read-only baseline.**
```
ssh "$NAS_USER@$NAS_HOST" 'echo "$SUDO_PW" | sudo -S sh -c "
  ls -l /dev/dri /dev/uinput /dev/uhid;
  lsmod | grep -E \"uinput|uhid\" || echo MODULES-NOT-LOADED;
  getent group video render apps input;
  midclt call pool.dataset.query \"[[\\\"name\\\",\\\"^\\\",\\\"games\\\"]]\" | head -c 400; echo"'
```
**VERIFICATION GATE:** `/dev/dri/{card0,renderD128}` present; video=44 render=107 apps=568; `games` pool exists; `games/wolf` and `games/steam` do NOT yet exist.

**M1.1 [SCOPED MUTATION] Create the two datasets (middleware-first).**
```
ssh "$NAS_USER@$NAS_HOST" 'echo "$SUDO_PW" | sudo -S midclt call pool.dataset.create "{\"name\":\"games/wolf\"}"'
ssh "$NAS_USER@$NAS_HOST" 'echo "$SUDO_PW" | sudo -S midclt call pool.dataset.create "{\"name\":\"games/steam\"}"'
```
**VERIFICATION GATE:** `midclt call pool.dataset.query '[["name","in",["games/wolf","games/steam"]]]'` returns both, each mounted at `/mnt/games/{wolf,steam}`.

**M1.2 [SCOPED MUTATION] chown the steam library + stage host scripts (ONLY the script + rules — never config).**
```
ssh "$NAS_USER@$NAS_HOST" 'echo "$SUDO_PW" | sudo -S sh -c "chown 1000:1000 /mnt/games/steam && chmod 777 /mnt/games/steam"'
# copy from this repo's scripts/ to the games pool (run from the Mac, via scp over the SAME route):

> **Before running any command below**, set the site values (see `env/EXAMPLE.env`) and pull the sudo password from your secret manager. Never hardcode it:
>
> ```bash
> export NAS_HOST=192.0.2.20 NAS_USER=truenas_admin
> export SUDO_PW="$(your-secret-manager get truenas-sudo-password)"
> ```
>
> (`$NAS_USER` can run `midclt` middleware calls *without* sudo; sudo is only needed for host `docker`/file ops.)

scp scripts/uinput-init.sh scripts/85-wolf-virtual-inputs.rules "$NAS_USER@$NAS_HOST":/tmp/
ssh "$NAS_USER@$NAS_HOST" 'echo "$SUDO_PW" | sudo -S sh -c "install -m0755 /tmp/uinput-init.sh /mnt/games/wolf/uinput-init.sh && install -m0644 /tmp/85-wolf-virtual-inputs.rules /mnt/games/wolf/85-wolf-virtual-inputs.rules && rm -f /tmp/uinput-init.sh /tmp/85-wolf-virtual-inputs.rules"'
```
DO NOT stage `config.steam-profile.reference.toml` or any `config.toml` onto `/mnt/games/wolf` — Wolf must auto-generate `config.toml` itself (M2). Staging a config.toml there would clobber the auto-generated key/cert refs.
**VERIFICATION GATE:** `ls -l /mnt/games/steam` → owner `1000:1000`; `ls -l /mnt/games/wolf` → `uinput-init.sh` (0755) + `85-wolf-virtual-inputs.rules` (0644), and NO `config.toml`.

**M1.3 [INTERACTIVE / USER-ONLY] Register the POST INIT script in the TrueNAS GUI.**
The script survives upgrades only because the registration lives in the config DB. User does: **System Settings → Advanced → Init/Shutdown Scripts → Add** → Type **Script**, When **POST INIT**, Script `/mnt/games/wolf/uinput-init.sh`, Timeout **30**, Enabled **on**, Comment "Wolf uinput bootstrap" → Save. (Equivalent middleware form, only on explicit go: `midclt call initshutdownscript.create '{"type":"SCRIPT","when":"POSTINIT","enabled":true,"timeout":30,"script":"/mnt/games/wolf/uinput-init.sh","comment":"Wolf uinput bootstrap"}'` — register, do NOT reboot to test it.)
**VERIFICATION GATE:** `midclt call initshutdownscript.query` shows the POSTINIT entry, enabled.

**M1.4 [SCOPED MUTATION] Load uinput now (run the script once, manually — no reboot).** The script's `udevadm trigger` is subsystem-filtered to misc/input; it does NOT touch storage/SAS. This is a bounded mutation, NOT blanket safe-to-automate — run on explicit go.
```
ssh "$NAS_USER@$NAS_HOST" 'echo "$SUDO_PW" | sudo -S sh /mnt/games/wolf/uinput-init.sh; echo "$SUDO_PW" | sudo -S sh -c "lsmod | grep -E \"^uinput|^uhid\"; ls -l /dev/uinput /dev/uhid"'
```
**VERIFICATION GATE:** `lsmod` shows `uinput` (and `uhid`) loaded; `/dev/uinput` + `/dev/uhid` are `crw-rw---- root:input` (0660). If `uhid` won't load on this kernel, that's tolerated (GOW globs it; /dev/input/* carries the pads) — note it but proceed.

---

### M2 — Deploy the Wolf custom app

**M2.1 [SAFE-TO-AUTOMATE] Pre-pull the images (avoids a long first-launch stall; no daemon impact).**
```
ssh "$NAS_USER@$NAS_HOST" 'echo "$SUDO_PW" | sudo -S sh -c "docker pull ghcr.io/games-on-whales/wolf:stable && docker pull ghcr.io/games-on-whales/steam:edge && docker image inspect ghcr.io/games-on-whales/wolf:stable --format \"{{index .RepoDigests 0}}\""'
```
**VERIFICATION GATE:** both images present; capture the wolf `:stable` digest (compare to the probed `sha256:6d2dc982…`; if it moved, that's fine — pin the new one at M5).

**M2.2 [INTERACTIVE / USER-ONLY] Create the custom app via the GUI (the dashboard-visible path).**
User does: **Apps → Discover Apps → (three-dot) → Install via YAML → Add Custom App**, Name `wolf`, paste the full contents of `truenas-app/docker-compose.yaml`, Save. The GUI runs `docker compose config` to validate, then `compose up -d` for this stack only.
(The GUI editor reserializes — keep this repo's file as the source of truth.)
**VERIFICATION GATE:** app `wolf` appears in the Apps list as DEPLOYING→RUNNING. Then:
```
ssh "$NAS_USER@$NAS_HOST" 'echo "$SUDO_PW" | sudo -S sh -c "docker ps --filter name=^/wolf$ --format \"{{.Names}} {{.Status}}\"; docker inspect --format \"{{json .State.Health}}\" wolf"'
```
Status `Up … (healthy)` (allow up to ~90s start_period). If `unhealthy`, check `docker logs wolf` — but the healthcheck is a pure `/proc/net/tcp` LISTEN probe on 47989, so unhealthy here means Wolf isn't binding, not a missing-binary artifact.

**M2.3 [SAFE-TO-AUTOMATE] Confirm Wolf auto-generated its config + identity, and the GPU/encoder probe.**
```
ssh "$NAS_USER@$NAS_HOST" 'echo "$SUDO_PW" | sudo -S sh -c "ls -l /mnt/games/wolf/; docker logs wolf 2>&1 | grep -iE \"encoder|render|gstreamer|listening\" | tail -30"'
```
**VERIFICATION GATE:** `/mnt/games/wolf/config.toml`, `key.pem`, `cert.pem` now exist (Wolf-generated). Logs show the encoder probe landing on `va` and the render node = renderD128.

---

### M3 — Steam profile + login + verify Arc encode

**M3.1 [INTERACTIVE / USER-ONLY] Trim the AUTO-GENERATED config to the Steam profile.** Stop the `wolf` app (GUI Stop). Edit `/mnt/games/wolf/config.toml` (the generated file — NOT the reference file) to match `truenas-app/config.steam-profile.reference.toml`: delete the non-Steam `[[profiles.apps]]` blocks, replace the Steam runner with the reference one (games/steam mount + `base_create_json` NanoCpus/Memory caps), and reorder the encoder lists lp-first / va-over-qsv. Do NOT hand-edit `paired_clients`/`key.pem`/`cert.pem`. Start the `wolf` app.
**VERIFICATION GATE:** `docker logs wolf | grep -i "Selected .* encoder"` shows `Selected HEVC encoder: va` (and H264 `va`). Any `qsv` ⇒ encoder order still wrong; fix and restart the app.

**M3.2 [INTERACTIVE / USER-ONLY] Steam Guard login.** From a paired Moonlight client (after M4 pairing, or a local test client) launch the Steam app; Steam login + Steam Guard 2FA + Big Picture first-run are interactive over the stream (budget a hands-on session, like the tracearr/wizarr first-run pattern).

**M3.3 [SAFE-TO-AUTOMATE] Verify the A770 is actually HW-encoding during a live session.**
```
ssh "$NAS_USER@$NAS_HOST" 'echo "$SUDO_PW" | sudo -S sh -c "docker ps --filter name=WolfSteam --format \"{{.Names}} {{.Status}}\"; timeout 5 intel_gpu_top -o - 2>/dev/null | head -20 || docker exec ix-tdarr-tdarr-1 sh -c \"timeout 5 intel_gpu_top -o -\" 2>/dev/null | head -20"'
```
**VERIFICATION GATE:** during an active stream the `WolfSteam` child container is Up and the Video/VideoEnhance engines on the A770 show load (confirms HW encode, shared with Plex/Tdarr, no passthrough).

---

### M4 — Moonlight LAN pair + stream + tune

**M4.1 [INTERACTIVE / USER-ONLY] Pair a Moonlight client (PIN flow).** On the LAN, open Moonlight → it discovers `Purah` via mDNS → enter the PIN Wolf shows. (Pairing writes to `paired_clients` in `/mnt/games/wolf/config.toml`.) Keep strictly LAN-only — do NOT port-forward 4798x/481xx or route them off-LAN (docker.sock = host-root for any paired client).
**VERIFICATION GATE:** client lists the Steam app; `grep -c paired_clients /mnt/games/wolf/config.toml` reflects the new pairing (read-only check).

**M4.2 [INTERACTIVE / USER-ONLY] First stream + quality tuning.** Launch Steam → Big Picture. In Moonlight set codec **HEVC** (primary), tune bitrate/resolution/fps for the LAN. Verify keyboard/mouse/gamepad input works in-stream (this is the real-world proof that uinput is loaded + reachable). If the picture is grey/corrupt or pinned ~30fps, apply the `vapostproc → videoconvert` fallback from the reference config and restart the app.
**VERIFICATION GATE:** clean end-to-end stream at the chosen codec/bitrate; input confirmed working.

---

### M5 — Harden

**M5.1 [INTERACTIVE / USER-ONLY] Validate limits under real concurrent load.** With a Plex transcode AND a Tdarr job running, start a Wolf game session; watch `intel_gpu_top` (GPU engines) and host RAM/CPU. Confirm the Wolf controller stays within `cpus 12 / mem 20G` and the game child within its `base_create_json` caps, and that ZFS ARC + the iSCSI target keep headroom (no PVC read-only flips on the cluster side). Tune the two caps down if contention threatens the NAS.
**VERIFICATION GATE:** under triple load, `docker stats wolf WolfSteam` stays within caps; no iSCSI disruption observed.

**M5.2 [SCOPED MUTATION] Pin image digests for reproducibility (edit the repo compose + GUI YAML, re-deploy via the app's Edit/Upgrade — never a daemon cycle).** Replace `image: ghcr.io/games-on-whales/wolf:stable` with `…:stable@sha256:<digest from M2.1>` and pin `steam:edge` similarly in `config.toml`. Apply via the app's Edit-YAML (which does a scoped compose up), not a daemon restart.
**VERIFICATION GATE:** `docker inspect --format '{{.Image}}' wolf` matches the pinned digest; app still RUNNING + healthy.

**M5.3 [INTERACTIVE / USER-ONLY] Enable autostart** for the `wolf` app in the GUI (so it comes back after a the NAS host reboot — the POST INIT loads uinput first; the app does not hard-depend on uinput/uhid at create time, so the boot-order race is already mitigated).
**VERIFICATION GATE:** app shows autostart/`RUNNING` policy enabled.

**M5.4 [SCOPED MUTATION] Back up `games/wolf` to MinIO** (the only irreplaceable state — pairings + config + host identity). Use S3/MinIO credentials from your secret manager; a periodic `tar`+`mc cp` of `/mnt/games/wolf` (excluding the re-pullable nothing-else) to the `backups` bucket. games/steam is re-downloadable — do NOT back it up.
**VERIFICATION GATE:** a `games/wolf` snapshot object exists in the MinIO `backups` bucket; a test restore lists `config.toml`+`key.pem`+`cert.pem`.

**M5.5 [SAFE-TO-AUTOMATE] Document post-upgrade restore.** After ANY TrueNAS upgrade, re-verify: `lsmod | grep uinput` (POST INIT loaded it), `ls -l /dev/uinput /dev/uhid` (0660 input), `ls /etc/udev/rules.d/85-wolf-virtual-inputs.rules` (reinstalled by the script), and that `/dev/dri` still binds into wolf/Plex/Tdarr. The app definition + POST INIT registration survive in the config DB; the masters survive on `games`.
**VERIFICATION GATE:** all four post-upgrade checks pass; Wolf RUNNING + healthy after the next upgrade.

---
**Separately tracked (not a Wolf step):** decide whether to restore the NAS host's boot-pool mirror (M0 left it single-disk, no redundancy). Independent of this deploy; record the decision.