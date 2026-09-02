# Bannerlord Coop: Pelican egg and server image

Pelican egg and Docker image for a **Mount & Blade II: Bannerlord** co-op
campaign server, running the Windows dedicated build under Wine.

No game files are baked in. steamcmd downloads workshop item `3770450698` into
the server volume on boot, so every operator fetches their own entitled copy.

## What is in here

| File | What it is |
| --- | --- |
| [`egg-bannerlord-coop.json`](egg-bannerlord-coop.json) | The egg. Import this in the panel. |
| [`Dockerfile`](Dockerfile) | The yolk, built on the official Pelican wine yolk. |
| [`start.sh`](start.sh) | Boot script: steamcmd, Wine prefix, server config, launch. |
| [`compose.yaml`](compose.yaml) | Runs the same image with no panel. |

Published image `ghcr.io/geofmigliacci/bannerlord-coop:latest`, also tagged per
commit sha. amd64 only.

## Requirements

- A Steam account that owns Bannerlord (app `261550`). Paid apps refuse
  anonymous workshop downloads, so there is no credential-free path.
- Two consecutive UDP allocations. Clients join on the first, the mod also uses
  the second.
- About 9 GB of disk: ~6 GB of game files plus a 1.6 GB Wine prefix, both built
  on first boot.

## Install on Pelican

1. Admin, Eggs, Import Egg: upload `egg-bannerlord-coop.json`.
2. Create a server on it with two consecutive UDP allocations.
3. Set **Steam username**. Leave **Steam password** empty.
4. Start it and watch the console. steamcmd asks for the password, then Steam
   Guard. A mobile authenticator is a push to approve, email codes are typed in.
5. The first start downloads about 6 GB. steamcmd then caches a token for
   months, so later starts are unattended.

## Run without a panel

```sh
cp .env.example .env   # fill in STEAM_USERNAME
docker compose up      # approve the Steam Guard push on your phone
```

`.env` is all you need, compose loads it and wires every variable. With an empty
`STEAM_PASSWORD` the first run needs `docker compose run --rm coop`, so the
prompt reaches your terminal.

`compose.yaml` also sets `STARTUP`, which a panel would send itself. For other
host ports, change the left side of both `ports:` entries.

## Variables

| Variable | Default | What it does |
| --- | --- | --- |
| `STEAM_USERNAME` | | Account that owns Bannerlord. Required. |
| `STEAM_PASSWORD` | | Optional. Prompted in the console if empty, which keeps it out of the panel database. |
| `AUTO_UPDATE` | `1` | Check Steam for a newer mod build on every start. `0` boots what is already there. |
| `SAVE_NAME` | `saveauto1` | World to host. A missing save is created from `default_new_game.sav`. |
| `SERVER_PASSWORD` | | Password players are prompted for. Empty means open. |
| `AUTOSAVE_MINUTES` | `5` | Minutes between autosaves. `0` disables them. |

`DATA_DIR`, `STEAM_DIR` and `WINEPREFIX` are internal and stay hidden in the
panel.

## Ports

Clients join on `port` in `server-config.json`, set from the primary allocation
on every start. The mod uses that port and the one above it.

`-p <n>` is not the join port. It is the engine's internal custom-server port,
default 7210, so pointing it at your allocation gives a server that boots and
never connects.

## Console and stopping

Commands are read from stdin, so they work in the panel console: `status`,
`players`, `save`, `say`, `kick`, `stop`, `help`, plus the game's `campaign.*`
and `coop.*` commands. The server prints its own list as an
`@DS@{"ev":"commands"}` line on boot.

Commands need a tty, since the launcher only submits a line on carriage return
and `start.sh` has the tty translate the newline wings sends.

`stop` writes a shutdown save and exits cleanly, and is what the egg sends. After
a kill instead, the last autosave is the recovery point and two dated backups
are kept.

Everything persistent lives in the server volume:

| Path | Contents |
| --- | --- |
| `data/Game Saves` | Worlds and dated backups. |
| `data/logs` | One log per boot. |
| `data/server-config.json` | Port, save name, password, autosave. Re-applied from the panel on every start. |
| `data/mod-config.json` | Mod settings, written by the launcher. |

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `SERVER_PORT=0 is not in 1-65534` | The server has no primary allocation. Give it two consecutive free UDP ports. |
| `FATAL: server-config.json 'port' must be 1-65535` | The stored config holds `"port": 0`. Assign a primary allocation, the next start rewrites it. |
| Typed commands do nothing | The container has no tty. wings always allocates one, compose needs `tty: true`. |
| Steam Guard on every start | The cached token is not persisting. `STEAM_DIR` must be on the server volume, and the volume must survive a restart. |
| `no game files found and Steam could not be used` | Steam is unreachable and the volume is empty. Set `STEAM_USERNAME`, or point `GAME_DIR` at an existing copy with `AUTO_UPDATE=0`. |

## How it boots

```
tini -g --                          from the yolk: reaps orphans, signals the group
/entrypoint.sh                      from the yolk: Xvfb on :0, stty 250, evals $STARTUP
/usr/local/bin/start.sh             steamcmd, Wine prefix, server-config.json
exec wine BannerlordCoopServer.exe
```

The image adds no `ENTRYPOINT` and no `CMD`, it keeps the yolk's. wings passes
the panel's Startup Command as `$STARTUP` and the yolk entrypoint is what
evaluates it, so that panel field stays live. `exec` keeps the game one hop from
wings' stdin, which is how console commands reach it.

## Development

```sh
docker build -t bannerlord-coop:latest .
sh start.sh --self-test
```

The egg's `~bannerlord-coop:latest` image entry tells wings to use a local build
without pulling. CI runs `shellcheck start.sh` and the self-test on every push,
then builds and pushes `:latest` plus the sha tag.
