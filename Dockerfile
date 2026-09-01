FROM debian:bookworm-slim

# WineHQ staging + Xvfb. i386 is required by the winehq packages, not by steamcmd.
RUN dpkg --add-architecture i386 \
 && apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget gnupg xvfb xauth winbind \
      lib32gcc-s1 lib32stdc++6 \
 && mkdir -p /etc/apt/keyrings \
 && wget -qO /etc/apt/keyrings/winehq.key https://dl.winehq.org/wine-builds/winehq.key \
 && echo "deb [signed-by=/etc/apt/keyrings/winehq.key] https://dl.winehq.org/wine-builds/debian/ bookworm main" \
      > /etc/apt/sources.list.d/winehq.list \
 && apt-get update && apt-get install -y --install-recommends winehq-staging \
 && rm -rf /var/lib/apt/lists/*

ENV WINEPREFIX=/wine WINEARCH=win64 WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml=" LANG=C.UTF-8
# mscoree/mshtml disabled = no Mono/Gecko download prompt when the prefix is created.

# Smoke test only, deleted in the same layer: the real prefix is per-server in the volume.
# Do NOT use `wineserver -w` here, it never returns under xvfb-run and hangs the build.
RUN xvfb-run -a wineboot -i && wineserver -k; test -f /wine/system.reg && rm -rf /wine

# No game files are baked in: steamcmd fetches them at boot into a persistent volume.
COPY entrypoint.sh /usr/local/bin/
# git on Windows stores the script 0644, so set the exec bit here or the container cannot start.
RUN chmod 755 /usr/local/bin/entrypoint.sh

# Below the heavy layers: a metadata edit up top would invalidate the wine install.
LABEL org.opencontainers.image.source=https://github.com/geofmigliacci/egg-bannerlord-coop

EXPOSE 4200/udp 4201/udp

CMD ["/usr/local/bin/entrypoint.sh"]
