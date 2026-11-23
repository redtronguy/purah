#!/bin/sh
# wolf-stream host init — load uinput + set perms for Wolf virtual input, reinstall the udev rule.
# =============================================================================
# WHY: On NAS host (TrueNAS SCALE 25.10) uinput.ko is present but NOT auto-loaded, and the /dev/uinput
# node exists at 0600 root:root with NO module bound — so Wolf gamepad/kbd/mouse input silently
# fails until `modprobe uinput` runs. TrueNAS OS upgrades REIMAGE the root FS, wiping /etc/udev,
# /etc/modules-load.d, and any hand-placed module config — so this must run at EVERY boot and is
# registered in the TrueNAS config DB (which survives upgrades), with its master copy on the games
# DATA POOL (which the reimage does not touch).
#
# REGISTER (interactive, user-only — M1):
#   GUI:  System Settings -> Advanced -> Init/Shutdown Scripts -> Add
#         Type: Script   When: POST INIT   Script: /mnt/games/wolf/uinput-init.sh   Timeout: 30   Enabled
#   OR middleware:
#     midclt call initshutdownscript.create '{"type":"SCRIPT","when":"POSTINIT","enabled":true,
#       "timeout":30,"script":"/mnt/games/wolf/uinput-init.sh","comment":"Wolf uinput bootstrap"}'
#
# STAGE FIRST:  copy this file + 85-wolf-virtual-inputs.rules to /mnt/games/wolf/ and chmod +x.
# RE-VERIFY after every TrueNAS upgrade:  lsmod | grep uinput ; ls -l /dev/uinput /dev/uhid
# =============================================================================
set -u

RULES_SRC="/mnt/games/wolf/85-wolf-virtual-inputs.rules"
RULES_DST="/etc/udev/rules.d/85-wolf-virtual-inputs.rules"

# 1. Load the in-tree uinput module (follows kernel bumps automatically across upgrades).
modprobe uinput 2>/dev/null || true
modprobe uhid   2>/dev/null || true

# 2. Ensure the 'input' group exists (Wolf's udev rule + perms target it).
getent group input >/dev/null 2>&1 || groupadd -r input 2>/dev/null || true

# 3. Reinstall the udev rule that an OS upgrade wipes from /etc (master lives on the games pool).
#    SCOPED TRIGGER ONLY: --subsystem-match=misc/input. An UNFILTERED `udevadm trigger` replays
#    add/change uevents for EVERY device on the host — including the storage / SAS / iSCSI-backing
#    block devices. On the NAS host, app_storage_2 backs the democratic-csi iSCSI target for the
#    k8s/database cluster, and the rule here is that SAS/HBA-adjacent non-read ops need
#    explicit confirmation. We therefore trigger ONLY the misc (uinput/uhid) + input (virtual pads)
#    subsystems — never block/SAS. Do NOT remove the --subsystem-match filters.
if [ -f "$RULES_SRC" ]; then
    install -m 0644 "$RULES_SRC" "$RULES_DST" 2>/dev/null || cp -f "$RULES_SRC" "$RULES_DST" 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=misc --subsystem-match=input 2>/dev/null || true
fi

# 4. Direct perms as a belt-and-suspenders (in case udev hasn't re-tagged the nodes yet).
for node in /dev/uinput /dev/uhid; do
    if [ -e "$node" ]; then
        chgrp input "$node" 2>/dev/null || true
        chmod 0660 "$node" 2>/dev/null || true
    fi
done

# 5. The Arc A770 render node is shared with Plex/Tdarr via group_add (video/render); do NOT chmod
#    it world-accessible. Just log its presence so a missing GPU is visible in the boot log.
DRI_STATE="MISSING"
[ -e /dev/dri/renderD128 ] && DRI_STATE="present"
UINPUT_STATE="MISSING"
lsmod 2>/dev/null | grep -q '^uinput' && UINPUT_STATE="loaded"

logger -t wolf-stream "uinput-init: module=$UINPUT_STATE uinput_node=$( [ -e /dev/uinput ] && echo present || echo MISSING ) uhid_node=$( [ -e /dev/uhid ] && echo present || echo MISSING ) dri=$DRI_STATE" 2>/dev/null || true

exit 0
