#!/bin/sh
# End-to-end checks on the bench (see run.sh), in the same nix shell:
#   SWITCHER_TEST_ROOT=<dir> test/e2e.sh
# Restarts the bench, drives it through the service's "key" IPC (what the
# rcmd binds send) and wtype (plain typing), and checks which window the
# stub niri was asked to focus. Screenshots go to test/screenshots/.
set -u
here=$(cd "$(dirname "$0")" && pwd)
r=$here/run.sh
log=${SWITCHER_TEST_ROOT:?}/stub.log
shots=$here/screenshots
mkdir -p "$shots"
fails=0

key() { $r msg plugin filedesless/switcher:service all key "$1" > /dev/null; }
close() { $r msg panel-close > /dev/null; sleep 0.4; }
reset() { : > "$log"; }
expect() { # name, expected stub.log contents
  got=$(tr '\n' ' ' < "$log" | sed 's/ $//')
  if [ "$got" = "$2" ]; then echo "PASS $1 ($got)"; else echo "FAIL $1: want '$2', got '$got'"; fails=$((fails + 1)); fi
}

$r stop; sleep 1
$r start > /dev/null; sleep 3

reset; key s; sleep 0.8
$r shot "$shots/compact-s.png"
expect "rcmd+s focuses nothing" ""
key p; sleep 0.5
expect "rcmd+s rcmd+p focuses Spotify" "focus 2"
close

reset; key o; sleep 0.8
$r shot "$shots/after-o.png"
expect "rcmd+o focuses Obsidian at once" "focus 7"
close

reset; key z; key d; sleep 1
expect "rcmd+z rcmd+d sent back to back focuses Zed" "focus 4"
close

reset; key space; sleep 0.8
$r shot "$shots/compact.png"
key space; sleep 0.8
$r shot "$shots/full.png"
key space; sleep 0.8
$r shot "$shots/compact-again.png"
$r type st; sleep 0.5
expect "rcmd+Space x3, then typing st focuses Steam" "focus 1"
close

reset; key space; sleep 0.8
$r type " "; sleep 0.8
$r shot "$shots/full-from-space.png"
$r type a; sleep 0.3
key c; sleep 0.5
expect "Space in the list, then a and rcmd+c focuses the second terminal" "focus 6"
close

reset; key x; sleep 0.8
$r shot "$shots/after-x.png"
expect "rcmd+x (no label) does nothing" ""
close

grep -a -E "ERR|error|switcher.*(fail|panic)" "$SWITCHER_TEST_ROOT/noctalia.log" | grep -v secret-store | sed 's/^/LOG /'
echo "$fails failed"
exit "$fails"
