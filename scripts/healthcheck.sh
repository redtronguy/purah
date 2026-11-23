#!/bin/sh
# Wolf liveness probe — PURE POSIX sh (the wolf image has ONLY /usr/bin/sh: no grep/cat/curl/wget).
# Mounted into the container at /mnt/games/wolf/healthcheck.sh (games/wolf -> SAME path in & out).
# Healthy = a Moonlight TCP control port is LISTEN (st 0A) on tcp/tcp6. Ports in /proc hex:
#   47984 HTTPS = BB70   |   47989 HTTP = BB75   |   48010 RTSP = BB8A
# (NB: 47989 is 0xBB75, NOT 0xBB55 — 0xBB55 = 47957, which nothing binds. That hex error is why
#  the original healthcheck never passed, on top of the image lacking grep.)
# Exit 0 as soon as one is found LISTENing, else 1.
for f in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$f" ] || continue
    while read -r line; do
        case "$line" in
            *:BB70\ *\ 0A\ *) exit 0 ;;
            *:BB75\ *\ 0A\ *) exit 0 ;;
            *:BB8A\ *\ 0A\ *) exit 0 ;;
        esac
    done < "$f"
done
exit 1
