#!/usr/bin/env bash
# Screenshots of ctron_pluginv2's screens on sample data: the full Factorio client on a virtual display (Xvfb) runs
# control.lua as a scenario, then the PNGs are copied to OUT. Usage: run.sh OUT [WxH]. Dev tool, not a test.
set -euo pipefail
exec 9<"$0"
flock -w 900 9 # one client at a time: each takes a few GB of RAM
here=$(cd "$(dirname "$0")" && pwd)
module=$here/../../module
factorio=${FACTORIO:-$HOME/factorio_2x}
mods=${MODS:-$factorio/mods}
out=$(realpath -m "$1")
size=${2:-1920x1080}
work=$out/.factorio
sc=$work/data/scenarios/ctronv2-preview

rm -rf "$sc" "$work/data/script-output" "$work/data/factorio-current.log"
mkdir -p "$sc/modules/ctron_pluginv2/gui" "$sc/locale/en" "$work/data/mods"
cp "$here/control.lua" "$sc/"
cp "$here/universal_edges.lua" "$sc/modules/"
cp "$module"/{ct,bridge,status_core}.lua "$sc/modules/ctron_pluginv2/"
cp "$module"/gui/*.lua "$sc/modules/ctron_pluginv2/gui/"
cp "$module"/locale/en/*.cfg "$sc/locale/en/"
cp "$mods"/Constructron-Continued_2.1.1.zip "$mods"/universal_edges_2.1.2.zip "$work/data/mods/"
cat > "$work/data/mods/mod-list.json" <<'EOF'
{"mods": [{"name": "base", "enabled": true}, {"name": "Constructron-Continued", "enabled": true},
 {"name": "universal_edges", "enabled": true}, {"name": "space-age", "enabled": false},
 {"name": "quality", "enabled": false}, {"name": "elevated-rails", "enabled": false}]}
EOF
printf '[path]\nread-data=%s/data\nwrite-data=%s/data\n[other]\ncheck-updates=false\n' "$factorio" "$work" \
	> "$work/config.ini"

display=:${DISPLAY_NUM:-77}
Xvfb "$display" -screen 0 "${size}x24" -nolisten tcp 2>/dev/null &
xvfb=$!
# Never the desktop: SDL would pick the session's Wayland (WAYLAND_DISPLAY, or wayland-0 in XDG_RUNTIME_DIR) over
# DISPLAY, so the socket is hidden and X11 forced.
mkdir -p "$work/run" && chmod 700 "$work/run"
env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$work/run" SDL_VIDEO_DRIVER=x11 SDL_VIDEODRIVER=x11 DISPLAY=$display \
	"$factorio/bin/x64/factorio" -c "$work/config.ini" --load-scenario ctronv2-preview \
	--window-size "$size" --disable-audio --force-graphics-preset very-low --video-memory-usage low > "$work/factorio.out" 2>&1 &
game=$!
# SIGKILL: a client whose display is going away can ignore SIGTERM, and it holds the lock (fd 9) and its RAM.
trap 'kill -9 $game 2>/dev/null; kill $xvfb 2>/dev/null || true' EXIT
for _ in $(seq 50); do
	driver=$(grep -o "Video driver: .*" "$work/data/factorio-current.log" 2>/dev/null || true)
	[ -n "$driver" ] && break
	sleep 0.1
done
[ "$driver" = "Video driver: x11" ] || { echo "not on the virtual display ($driver); stopped" >&2; exit 1; }
for _ in $(seq 180); do
	[ -f "$work/data/script-output/ctronv2/done" ] && break
	if ! kill -0 $game 2>/dev/null || grep -q "non-recoverable error" "$work/data/factorio-current.log" 2>/dev/null; then
		grep -A8 "non-recoverable error" "$work/data/factorio-current.log" >&2 || echo "factorio exited" >&2
		exit 1
	fi
	sleep 1
done
[ -f "$work/data/script-output/ctronv2/done" ] || { echo "timed out; see $work/data/factorio-current.log" >&2; exit 1; }
cp "$work"/data/script-output/ctronv2/*.png "$out/"
ls "$out"/*.png
