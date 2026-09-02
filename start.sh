#!/bin/sh
# Bannerlord Coop dedicated server launcher. steamcmd fetches the game at boot, none is baked in.
set -u

APP_ID=261550
ITEM_ID=3770450698

STEAM_DIR=${STEAM_DIR:-/home/container/.steamcmd}
# Run straight out of the steamcmd download; left empty, the path is discovered below.
GAME_DIR=${GAME_DIR:-}
DATA_DIR=${DATA_DIR:-/home/container/data}
WINEPREFIX=${WINEPREFIX:-/home/container/.wine}
AUTO_UPDATE=${AUTO_UPDATE:-1}
export WINEPREFIX

log()  { echo "[coop] $*"; }
warn() { echo "[coop] WARNING: $*" >&2; }
die()  { echo "[coop] ERROR: $*" >&2; exit 1; }

# Docker Desktop's 9p mount can return EEXIST for a missing dir, so test the result.
ensure_dir() { mkdir -p "$1" 2>/dev/null; [ -d "$1" ] || die "cannot create $1"; }

# server-config.json is JSONC, so sed, not a parser. esc() prefixes & \ | for sed.
esc() { printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'; }
set_cfg() {
  grep -qE "\"$1\"[[:space:]]*:" "$cfg" 2>/dev/null || return 0
  sed -i -E "s|(\"$1\"[[:space:]]*:[[:space:]]*)[^,}]*|\1$(esc "$2")|" "$cfg"
}

# wings sends its primary allocation here, and 0 when the server has none. The
# launcher FATALs on a bad port, so check before downloading 6 GB to find out.
check_port() {
  # 1-65534, since the mod also uses port+1. awk compares without overflowing on a
  # long digit string, and [1-9] first means no leading zero and no need for a
  # lower-bound test.
  awk -v p="${1:-}" 'BEGIN{exit !(p ~ /^[1-9][0-9]*$/ && p+0<=65534)}' ||
    die "SERVER_PORT=${1:-} is not a port in 1-65534. Pelican sends 0 when the
server has no primary allocation: give it two consecutive free UDP ports."
}

# `sh start.sh --self-test` checks both round trips. CI runs it.
if [ "${1:-}" = "--self-test" ]; then
  cfg=$(mktemp) || exit 1
  printf '{\n  "port": 4200, // trailing comment\n  "password": "old",\n}\n' > "$cfg"
  set_cfg password '"a|b&c\d"'
  want='  "password": "a|b&c\d",'
  got=$(grep password "$cfg"); rm -f "$cfg"
  [ "$got" = "$want" ] || die "self-test: got [$got] want [$want]"
  for bad in "" 0 abc 04200 65535 99999999999999999999; do
    ( check_port "$bad" ) 2>/dev/null && die "self-test: check_port took [$bad]"
  done
  check_port 4200 || die "self-test: check_port rejected 4200"
  echo "self-test ok"; exit 0
fi

[ -z "${SERVER_PORT:-}" ] || check_port "$SERVER_PORT"

# --- 1. game files ----------------------------------------------------------
# steamcmd puts content under $HOME/Steam, so HOME points at STEAM_DIR; roots vary, hence the list.
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

run_steamcmd() {
  HOME=$STEAM_DIR "$STEAM_DIR/steamcmd.sh" "$@" \
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

  log "steamcmd: checking workshop item $ITEM_ID for updates"
  # Cached token first: passing the password re-authenticates and pushes Guard every boot.
  # NoPromptForPassword makes that attempt fail fast instead of waiting at a password prompt.
  if [ -f "$STEAM_DIR/Steam/config/config.vdf" ]; then
    log "steamcmd: trying cached token"
    run_steamcmd +@NoPromptForPassword 1 +login "$STEAM_USERNAME" && return 0
    log "steamcmd: cached token rejected, using password"
  fi
  # An empty password means steamcmd prompts for it, and for the Guard code, on the console.
  # shellcheck disable=SC2086
  run_steamcmd +login "$STEAM_USERNAME" ${STEAM_PASSWORD:+"$STEAM_PASSWORD"} ||
    { warn "steamcmd failed"; return 1; }
}

if ! update_game; then
  # A Steam outage or an expired credential must never brick a server that already works.
  if ! resolve_game_dir; then
    # Steam rate-limits repeated failed logins, so slow the wings restart loop to one a minute.
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
if [ ! -f "$WINEPREFIX/system.reg" ]; then
  log "creating wine prefix at $WINEPREFIX (~2 min)"
  ensure_dir "$WINEPREFIX"
  xvfb-run -a wineboot -i >/dev/null 2>&1
  wineserver -k 2>/dev/null
  [ -f "$WINEPREFIX/system.reg" ] || die "could not create a wine prefix at $WINEPREFIX"
fi

# --- 3. mod-config.json must land in the data dir ---------------------------
# The launcher writes it to Wine's Documents; the uid has no passwd entry, so glob the user dir.
for docs in "$WINEPREFIX"/drive_c/users/*/Documents; do
  [ -d "$docs" ] || continue
  ensure_dir "$docs/Mount and Blade II Bannerlord"
  link="$docs/Mount and Blade II Bannerlord/CoopData"
  [ -L "$link" ] && rm -f "$link"
  [ -e "$link" ] || ln -s "$DATA_DIR" "$link"
done

# --- 4. server-config.json --------------------------------------------------
# Seeded before launch, or the launcher writes its own with port 4200.
cfg=$DATA_DIR/server-config.json

if [ ! -f "$cfg" ]; then
  log "seeding $cfg"
  cat > "$cfg" <<CFG
{
  "port": ${SERVER_PORT:-4200},
  "saveName": "${SAVE_NAME:-saveauto1}",
  "password": "${SERVER_PASSWORD:-}",
  "autosaveMinutes": ${AUTOSAVE_MINUTES:-5},
  "logFile": true,
  "steam": false
}
CFG
else
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

# The launcher only submits a command line on CR, and wings sends LF. Needs a tty,
# which wings always allocates and compose.yaml sets.
stty inlcr 2>/dev/null || true

# Xvfb is already on $DISPLAY. exec puts wine one hop from wings' stdin and signals.
# --no-tui: on wings' tty the launcher truncates the ready line wings matches.
exec wine BannerlordCoopServer.exe --no-tui --data-dir "$win_data" "$@"
