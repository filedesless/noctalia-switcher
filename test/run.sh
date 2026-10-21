#!/bin/sh
# A bench for the switcher that leaves the real session alone: headless sway
# on its own Wayland display, a second Noctalia on its own session bus, with
# its own HOME, XDG dirs and XDG_RUNTIME_DIR (so `noctalia msg` here reaches
# only it), and a stub niri (stub/niri) that plays back events.jsonl and logs
# focus-window calls to $SWITCHER_TEST_ROOT/stub.log.
#
# Run inside: nix shell nixpkgs#sway nixpkgs#grim nixpkgs#wtype
#
#   SWITCHER_TEST_ROOT=<empty dir> test/run.sh start   # bench in the background
#   SWITCHER_TEST_ROOT=... test/run.sh msg <args>      # noctalia msg, to the bench
#   SWITCHER_TEST_ROOT=... test/run.sh type <text>     # wtype, to the bench
#   SWITCHER_TEST_ROOT=... test/run.sh shot <file>     # grim, of the bench
#   SWITCHER_TEST_ROOT=... test/run.sh stop
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
root=${SWITCHER_TEST_ROOT:?set SWITCHER_TEST_ROOT to a scratch dir}

export HOME="$root/home"
# Short: a socket's path must fit in 108 bytes.
export XDG_RUNTIME_DIR="${SWITCHER_TEST_RUN:-/tmp/claude-$(id -u)/switcher-bench}"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
unset NIRI_SOCKET WAYLAND_DISPLAY DISPLAY SWAYSOCK DBUS_SESSION_BUS_ADDRESS
export PATH="$here/stub:$PATH" STUB_LOG="$root/stub.log"

case "${1:-}" in
start)
  mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/noctalia" "$XDG_DATA_HOME/noctalia/plugins" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
  chmod 700 "$XDG_RUNTIME_DIR"
  ln -sfn "$repo" "$XDG_DATA_HOME/noctalia/plugins/switcher"
  : > "$STUB_LOG"
  cat > "$XDG_CONFIG_HOME/noctalia/config.toml" <<EOF
[plugins]
enabled = ["filedesless/switcher"]

[plugin_settings."filedesless/switcher"]
previews = false
EOF
  cat > "$root/sway.conf" <<EOF
output HEADLESS-1 resolution 1920x1080 position 0 0
output HEADLESS-2 resolution 1920x1080 position 1920 0
EOF
  # wlroots picks its own wayland-N (in our runtime dir): read it back and
  # hand it to Noctalia.
  setsid dbus-run-session -- sh -c '
    WAYLAND_DISPLAY= WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 WLR_LIBINPUT_NO_DEVICES=1 \
      sway -c "$1/sway.conf" > "$1/sway.log" 2>&1 &
    for i in $(seq 50); do
      sock=$(ls "$XDG_RUNTIME_DIR" | grep -E "^wayland-[0-9]+$" | head -1) && [ -n "$sock" ] && break
      sleep 0.1
    done
    echo "$sock" > "$1/display"
    WAYLAND_DISPLAY=$sock noctalia > "$1/noctalia.log" 2>&1 &
    wait
  ' sh "$root" > "$root/bench.log" 2>&1 &
  echo $! > "$root/pgid"
  for i in $(seq 100); do
    [ -s "$root/display" ] && [ -S "$XDG_RUNTIME_DIR/noctalia-$(cat "$root/display").sock" ] && break
    sleep 0.1
  done
  echo "bench up: display $(cat "$root/display"), pgid $(cat "$root/pgid")"
  ;;
msg)
  shift
  WAYLAND_DISPLAY=$(cat "$root/display") noctalia msg "$@"
  ;;
type)
  shift
  WAYLAND_DISPLAY=$(cat "$root/display") wtype "$@"
  ;;
shot)
  WAYLAND_DISPLAY=$(cat "$root/display") grim "$2"
  ;;
stop)
  kill -TERM -- "-$(cat "$root/pgid")" 2>/dev/null || true
  ;;
*)
  sed -n '2,15p' "$0"
  exit 2
  ;;
esac
