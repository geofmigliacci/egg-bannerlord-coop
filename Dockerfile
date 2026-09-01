FROM debian:bookworm-slim

# WineHQ staging + Xvfb, plus the 32-bit runtime steamcmd needs. The i386 architecture is
# required by the winehq packages anyway, so steamcmd's deps are nearly free here.
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

# Build-time smoke test, not a shipped prefix: a wine install that cannot create one must fail
# the build rather than every server at boot. Deleted in the same layer so the 1.7 GB never
# enters the image - the real prefix is per-server inside the volume (entrypoint.sh), because
# Pelican overrides WINEPREFIX and runs a non-root uid that cannot write a root-owned /wine.
# Do NOT use `wineserver -w` here: it waits for the wineserver to exit, which never happens
# once xvfb-run tears down the display underneath it, and the build hangs forever. `-k` kills
# it instead, which is all the check needs.
RUN xvfb-run -a wineboot -i && wineserver -k; test -f /wine/system.reg && rm -rf /wine

# No game files are baked in: steamcmd fetches them at boot into a persistent volume.
COPY entrypoint.sh /usr/local/bin/
# The exec bit is set here rather than inherited from the build context: git on Windows
# stores the script 0644, so a CI checkout produces a non-executable file and the container
# dies with "permission denied" before the entrypoint ever runs.
RUN chmod 755 /usr/local/bin/entrypoint.sh

# Below the heavy layers on purpose: a metadata edit up top would invalidate the wine install.
LABEL org.opencontainers.image.source=https://github.com/geofmigliacci/egg-bannerlord-coop

EXPOSE 4200/udp 4201/udp

CMD ["/usr/local/bin/entrypoint.sh"]
