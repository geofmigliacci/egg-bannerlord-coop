#!/bin/sh
# Bannerlord Coop dedicated server launcher.
#
# The image ships no game files: steamcmd fetches the workshop item into a persistent
# directory at boot, so nothing copyrighted is ever redistributed in the image and each
# operator pulls their own entitled copy.
set -u

APP_ID=261550
ITEM_ID=3770450698

STEAM_DIR=${STEAM_DIR:-/steam}
# Run straight out of the steamcmd download - copying it elsewhere would double the disk
# (6 GB downloaded + 5.6 GB copied) for no benefit. Left empty, the path is discovered below
# rather than assumed: steamcmd decides where workshop content lands, not us.
GAME_DIR=${GAME_DIR:-}
DATA_DIR=${DATA_DIR:-/server-data}
WINEPREFIX=${WINEPREFIX:-/wine}
AUTO_UPDATE=${AUTO_UPDATE:-1}
STEAM_GUARD_CODE=${STEAM_GUARD_CODE:-}
export WINEPREFIX

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] WARNING: $*" >&2; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# Docker Desktop's 9p mount can return EEXIST for a directory that is not there, so the
# exit code is not trustworthy - test the result instead.
ensure_dir() { mkdir -p "$1" 2>/dev/null; [ -d "$1" ] || die "cannot create $1"; }

# --- 1. game files ----------------------------------------------------------
# steamcmd puts workshop content under its own Steam data root, which is $HOME/Steam - NOT the
# directory steamcmd.sh lives in. So HOME is pointed at STEAM_DIR when it runs, or the 6 GB lands
# outside the volume and dies with the container. A download made before that was fixed still
# sits under the real $HOME, so every plausible root is checked and GAME_DIR is set from
# whichever one actually holds the exe.
WORKSHOP=steamapps/workshop/content/$APP_ID/$ITEM_ID/DedicatedServer
GAME_ROOTS="$STEAM_DIR/Steam $STEAM_DIR ${HOME:-/root}/Steam"
resolve_game_dir() {
  [ -n "$GAME_DIR" ] && [ -f "$GAME_DIR/BannerlordCoopServer.exe" ] && return 0
  for root in $GAME_ROOTS; do
    if [ -f "$root/$WORKSHOP/BannerlordCoopServer.exe" ]; then
      GAME_DIR=$root/$WORKSHOP
      return 0
    fi
  done
  return 1
}

# No password argument makes steamcmd prompt on the console; that is the reliable way to answer
# Steam Guard, since the code is then typed at the moment it is needed.
run_steamcmd() {
  HOME=$STEAM_DIR "$STEAM_DIR/steamcmd.sh" +login "$STEAM_USERNAME" "$@" \
      +workshop_download_item "$APP_ID" "$ITEM_ID" +quit
}

update_game() {
  if [ "$AUTO_UPDATE" != 1 ]; then
    log "AUTO_UPDATE=0 - not contacting Steam"
    return 1
  fi
  if [ -z "${STEAM_USERNAME:-}" ]; then
    log "STEAM_USERNAME unset - not contacting Steam"
    return 1
  fi

  ensure_dir "$STEAM_DIR"
  if [ ! -x "$STEAM_DIR/steamcmd.sh" ]; then
    log "installing steamcmd into $STEAM_DIR"
    wget -qO- https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz |
      tar zx -C "$STEAM_DIR" || { warn "could not install steamcmd"; return 1; }
  fi

  # An empty password makes steamcmd prompt on the console - which is how Steam Guard is
  # answered on first run. The refresh token steamcmd caches in $STEAM_DIR/Steam/config/config.vdf
  # is good for months, so later runs are silent. STEAM_GUARD_CODE only exists to make that very
  # first login non-interactive, and steamcmd takes it as the third positional argument - useless
  # on accounts using the mobile authenticator, where the login is a push to be approved instead.
  log "steamcmd: checking workshop item $ITEM_ID for updates"
  # shellcheck disable=SC2086
  if ! run_steamcmd ${STEAM_PASSWORD:+"$STEAM_PASSWORD"} ${STEAM_GUARD_CODE:+"$STEAM_GUARD_CODE"}; then
    # A supplied Guard code is usually just stale - they expire in about 30 seconds and the
    # steamcmd install above eats some of that. Fall back to prompting on the console rather
    # than failing the boot, so one bad code is not a crash loop.
    [ -n "$STEAM_GUARD_CODE" ] || { warn "steamcmd failed"; return 1; }
    warn "login with STEAM_GUARD_CODE failed - codes expire in ~30s. Retrying with a"
    warn "console prompt: type the password and a fresh code into the console."
    run_steamcmd || { warn "steamcmd failed"; return 1; }
  fi
}

if ! update_game; then
  # A Steam outage or an expired credential must never brick a server that already works.
  if ! resolve_game_dir; then
    # Wings restarts a crashed server immediately, and Steam rate-limits repeated failed
    # logins for about half an hour - so exiting straight away turns one bad credential into
    # a login storm that deepens the lockout. Slow the restart loop to one attempt a minute.
    sleep 60
    die "no game files found and Steam could not be used. Looked in:$(for r in $GAME_ROOTS; do printf '\n  %s' "$r/$WORKSHOP"; done)
Set STEAM_USERNAME (and STEAM_PASSWORD), or point GAME_DIR at an existing copy with AUTO_UPDATE=0."
  fi
  warn "continuing with the game files already present"
fi
resolve_game_dir || die "BannerlordCoopServer.exe is missing after the update step. Looked in:$(for r in $GAME_ROOTS; do printf '\n  %s' "$r/$WORKSHOP"; done)"
log "game files: $GAME_DIR"

ensure_dir "$DATA_DIR"

# --- 2. wine prefix ---------------------------------------------------------
# Created at runtime when it is missing, which is what lets this run as Pelican's
# non-root uid: the baked /wine prefix is root-owned and unwritable to uid 988.
if [ ! -f "$WINEPREFIX/system.reg" ]; then
  log "creating wine prefix at $WINEPREFIX (~10s)"
  ensure_dir "$WINEPREFIX"
  xvfb-run -a wineboot -i >/dev/null 2>&1
  wineserver -k 2>/dev/null
  [ -f "$WINEPREFIX/system.reg" ] || die "could not create a wine prefix at $WINEPREFIX"
fi

# --- 3. mod-config.json must land in the data dir ---------------------------
# The launcher writes it to Wine's Documents folder, not beside --data-dir. Glob the user
# folder: Wings runs an arbitrary uid with no /etc/passwd entry, so it is not users/root.
for docs in "$WINEPREFIX"/drive_c/users/*/Documents; do
  [ -d "$docs" ] || continue
  ensure_dir "$docs/Mount and Blade II Bannerlord"
  link="$docs/Mount and Blade II Bannerlord/CoopData"
  [ -L "$link" ] && rm -f "$link"
  [ -e "$link" ] || ln -s "$DATA_DIR" "$link"
done

# --- 4. server-config.json --------------------------------------------------
# Written before launch: left alone, the launcher creates it with port 4200 and would bind
# the wrong port. The file is JSONC (comments, trailing commas) so this is sed, not a parser.
cfg=$DATA_DIR/server-config.json
esc() { printf '%s' "$1" | sed -e 's/[\&|]/\&/g'; }
set_cfg() {
  grep -qE "\"$1\"[[:space:]]*:" "$cfg" 2>/dev/null || return 0
  sed -i -E "s|(\"$1\"[[:space:]]*:[[:space:]]*)[^,}]*|\1$(esc "$2")|" "$cfg"
}

if [ ! -f "$cfg" ] && [ -n "${SERVER_PORT:-}" ]; then
  log "seeding $cfg"
  cat > "$cfg" <<CFG
{
  "port": ${SERVER_PORT},
  "saveName": "${SAVE_NAME:-saveauto1}",
  "password": "${SERVER_PASSWORD:-}",
  "autosaveMinutes": ${AUTOSAVE_MINUTES:-5},
  "logFile": true,
  "steam": false
}
CFG
elif [ -f "$cfg" ]; then
  [ -n "${SERVER_PORT:-}" ]       && set_cfg port "$SERVER_PORT"
  [ -n "${SAVE_NAME:-}" ]         && set_cfg saveName "\"$SAVE_NAME\""
  [ -n "${SERVER_PASSWORD+x}" ]   && set_cfg password "\"$SERVER_PASSWORD\""
  [ -n "${AUTOSAVE_MINUTES:-}" ]  && set_cfg autosaveMinutes "$AUTOSAVE_MINUTES"
fi

# --- 5. go -------------------------------------------------------------------
win_data=$(winepath -w "$DATA_DIR" 2>/dev/null)
[ -n "$win_data" ] || die "winepath could not map $DATA_DIR to a Windows path"
log "starting: $GAME_DIR  ->  --data-dir $win_data"
cd "$GAME_DIR" || die "cannot enter $GAME_DIR"

# No `exec`: making xvfb-run PID 1 makes wine exit instantly and silently.
#
# --no-tui is not cosmetic here. Wings always creates the container with `Tty: true`, and on a tty
# the launcher draws full-screen panes that truncate every line to the pane width - so Wings, which
# marks a server online by matching "coop server up, waiting for clients", would only ever see
# "coop server up, wa" and would eventually give up and kill the server.
xvfb-run -a wine BannerlordCoopServer.exe --no-tui --data-dir "$win_data"
