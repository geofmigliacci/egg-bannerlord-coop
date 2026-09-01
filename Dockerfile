FROM debian:bookworm-slim
LABEL org.opencontainers.image.source=https://github.com/geofmigliacci/egg-bannerlord-coop

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
# wineboot creates the prefix in ~10s. Do NOT use `wineserver -w` here: it waits for the
# wineserver to exit, which never happens once xvfb-run tears down the display underneath
# it, and the build hangs forever. `-k` kills it instead, which is all the layer needs.
RUN xvfb-run -a wineboot -i && wineserver -k; test -f /wine/system.reg

# No game files are baked in: steamcmd fetches them at boot into a persistent volume.
COPY entrypoint.sh /usr/local/bin/
# The exec bit is set here rather than inherited from the build context: git on Windows
# stores the script 0644, so a CI checkout produces a non-executable file and the container
# dies with "permission denied" before the entrypoint ever runs.
RUN chmod 755 /usr/local/bin/entrypoint.sh

EXPOSE 4200/udp 4201/udp

CMD ["/usr/local/bin/entrypoint.sh"]
