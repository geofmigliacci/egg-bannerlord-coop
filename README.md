# Bannerlord Coop: Pelican egg + server image

Pelican / Pterodactyl egg and Docker image for a **Mount & Blade II: Bannerlord** co-op
campaign server, running the Windows dedicated server build under Wine.

No game files are baked in: steamcmd downloads workshop item `3770450698` into the server
volume on boot, so every operator fetches their own entitled copy.

- Image `ghcr.io/geofmigliacci/bannerlord-coop:latest`, also tagged per commit sha.
- Egg [`egg-bannerlord-coop.json`](egg-bannerlord-coop.json).
- amd64 only, Wine plus steamcmd's 32-bit runtime.

## Requirements

- A Steam account that owns Bannerlord (app `261550`). Paid apps refuse anonymous
  workshop downloads, so there is no credential-free path.
- Two consecutive UDP allocations: clients join on the first, the mod uses first+1 too.
- ~9 GB of disk: ~6 GB game files plus a 1.6 GB Wine prefix, both built on first boot.

## Install (Pelican)

1. Admin, Eggs, Import Egg: upload `egg-bannerlord-coop.json`.
2. Create a server on it with two consecutive UDP allocations.
3. Set **Steam username**, leave **Steam password** empty.
4. Start it and watch the console: steamcmd prompts for the password, then Steam Guard.
   Mobile authenticator is a push to approve, email codes are typed in.
5. The first start downloads ~6 GB. steamcmd then caches a token for months, so later
   starts are unattended.

## Ports

Clients join on `port` in `server-config.json`, set from Pelican's primary allocation on
every start. The mod uses that port and the one above it.

`-p <n>` is not the join port. It is the engine's internal custom-server port (default
7210), so pointing it at your allocation gives a server that boots and never connects.

## Variables

| Variable | Default | What it does |
| --- | --- | --- |
| `STEAM_USERNAME` | | Account that owns Bannerlord. Required. |
| `STEAM_PASSWORD` | | Optional. Prompted in the console if empty, which keeps it out of the panel database. |
| `AUTO_UPDATE` | `1` | Check Steam for a newer mod build on every start. `0` boots what is already there. |
| `SAVE_NAME` | `saveauto1` | World to host. Missing saves come from `default_new_game.sav`. |
| `SERVER_PASSWORD` | | Password players are prompted for. Empty means open. |
| `AUTOSAVE_MINUTES` | `5` | Minutes between autosaves, `0` disables. |

Saves, configs, logs and dated backups live in `data/` in the server volume. Port, save
name, password and autosave interval are re-applied from the panel on every start.

## Console commands and stopping

Commands are read from stdin, so they work in the Pelican console: `status`, `players`,
`save`, `say`, `kick`, `stop`, `help`, plus the game's `campaign.*` and `coop.*` commands.

`stop` writes a shutdown save and exits cleanly, which is what the egg sends. After a kill
instead, the last autosave is the recovery point and two dated backups are kept.

## Running without a panel

```sh
cp .env.example .env   # fill in STEAM_USERNAME and STEAM_PASSWORD
docker compose up      # approve the Steam Guard push on your phone
```

`.env` is all you need: compose loads it and every variable is wired in `compose.yaml`.
With an empty `STEAM_PASSWORD` the first run needs `docker compose run --rm coop` so the
prompt reaches your terminal. For other host ports, change the left side of both `ports:`
entries.

## Building locally

```sh
docker build -t bannerlord-coop:latest .
```

The egg's `~bannerlord-coop:latest` entry tells wings to use it without pulling.
