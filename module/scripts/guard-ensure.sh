#!/system/bin/sh
# Start the resident guard from either Magisk boot phase. The native flock is
# the sole singleton authority; never wait for zygote readiness in post-fs-data.
MODDIR=${0%/*}
MODDIR=${MODDIR%/*}
DAEMON="$MODDIR/bin/wsa-vfork-guard"
STATE_DIR=/data/adb/wsa_houdini_vfork_scudo
PID_FILE="$STATE_DIR/guard.pid"
READY_FILE="$STATE_DIR/guard.ready"
LOG_FILE="$STATE_DIR/guard.log"
BRIDGE=/vendor/lib64/libhoudini.so
EXPECTED_BRIDGE_SHA256=__EXPECTED_BRIDGE_SHA256__
phase=${1:-unknown}

[ ! -e "$MODDIR/disable" ] && [ ! -e "$MODDIR/remove" ] || exit 0
mkdir -p "$STATE_DIR" || exit 1
chmod 700 "$STATE_DIR" || exit 1
touch "$LOG_FILE" && chmod 600 "$LOG_FILE" || exit 1
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$phase] $*" >> "$LOG_FILE"; }

case "$EXPECTED_BRIDGE_SHA256" in *[!0-9a-f]*|'')
  log "REFUSING to launch: invalid or unreplaced bridge checksum"
  exit 1 ;;
esac
[ "${#EXPECTED_BRIDGE_SHA256}" -eq 64 ] || exit 1
[ -x "$DAEMON" ] || { log "REFUSING to launch: daemon missing or not executable"; exit 1; }

# Preserve all quoting in the PID/executable checks; never treat a foreign PID
# or absent ready file as proof that a guard is active.
guard_pid_of() {
  [ -f "$PID_FILE" ] || return 1
  p="$(cat "$PID_FILE")"
  case "$p" in *[!0-9]*|''|0|1) return 1 ;; esac
  echo "$p"
}
guard_is_ours() {
  [ -d "/proc/$1" ] || return 1
  exe="$(readlink "/proc/$1/exe" 2>/dev/null)"
  exe="${exe% (deleted)}"
  [ "$exe" = "$DAEMON" ]
}
existing="$(guard_pid_of)"
if [ -n "$existing" ] && guard_is_ours "$existing"; then
  log "guard already running: pid=$existing readiness=$(cat "$READY_FILE" 2>/dev/null)"
  exit 0
fi
if [ -n "$existing" ] && [ -d "/proc/$existing" ]; then
  log "REFUSING to launch: guard.pid names a live foreign process ($existing)"
  exit 1
fi

bridge_sha="$(sha256sum "$BRIDGE" 2>/dev/null)"
bridge_sha=${bridge_sha%% *}
if [ "$bridge_sha" != "$EXPECTED_BRIDGE_SHA256" ]; then
  log "REFUSING to launch: original bridge checksum mismatch ($bridge_sha)"
  exit 1
fi

# No code or library overlay. Houdini is preloaded in zygote64: x86 descendants
# can also remain traced, but only its exact clone instruction is intercepted.
log "launching $DAEMON --state-dir $STATE_DIR"
nohup "$DAEMON" --state-dir "$STATE_DIR" >> "$LOG_FILE" 2>&1 &
launcher_child=$!
case "$phase" in early) max_wait=2 ;; *) max_wait=15 ;; esac
waited=0
while [ "$waited" -lt "$max_wait" ]; do
  new_pid="$(guard_pid_of)"
  if [ -n "$new_pid" ] && guard_is_ours "$new_pid"; then
    log "guard process started: pid=$new_pid (readiness is checked separately)"
    exit 0
  fi
  if ! kill -0 "$launcher_child" 2>/dev/null; then
    # Concurrent launch may lose the native flock without harming its owner.
    new_pid="$(guard_pid_of)"
    [ -n "$new_pid" ] && guard_is_ours "$new_pid" && exit 0
    log "guard launch failed; inspect guard.log"
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
log "guard process not confirmed within ${max_wait}s; readiness not established"
exit 1
