#!/usr/bin/env python3
"""Screenshots of ctron_pluginv2's screens on a running test cluster, while a command (an E2E run) drives it.

    live.py OUT [--instance e2e-a] [--every 6] -- ./dev test e2e ctronv2.e2e

A camera client (the full Factorio client, on a virtual display like run.sh) joins the instance as player "cam", in
spectator mode, and every few seconds RCON opens the Control Center on one of its tabs, or Job Details for a job on
the tile, with the camera over a busy ctron, and takes a screenshot. The client rejoins after the instance restarts.
Runs against the dev root in V2_DEV_ROOT (the test cluster, never the owner's); the instance needs user verification
off (the camera has no login). Dev tool, not a test.
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

here = os.path.dirname(os.path.abspath(__file__))
repo = os.environ.get("V2_REPO", os.path.abspath(os.path.join(here, "../../..")))
root = os.environ["V2_DEV_ROOT"]
factorio = os.environ.get("FACTORIO", os.path.expanduser("~/factorio_2x"))
L = "__level__/modules/ctron_pluginv2/gui/"

# One /sc per frame. FRAME and TABS are filled in; it prints what it shot, or why not.
LUA = """
local p = game.get_player("cam")
if not (p and p.connected) then rcon.print("noplayer") return end
if p.controller_type ~= defines.controllers.spectator then
	local body = p.character
	p.set_controller({ type = defines.controllers.spectator })
	if body and body.valid then body.destroy() end
end
local gui, center, details = package.loaded["%(L)sgui.lua"], package.loaded["%(L)scenter.lua"],
	package.loaded["%(L)sdetails.lua"]
local f, here = %(FRAME)d, gui.here()
local st = gui.state(p)
for _, rec in pairs(storage.ctron_pluginv2.ctrons) do
	if rec.state == "busy" and rec.entity.valid then p.teleport(rec.entity.position) break end
end
local what
if f %% 4 == 3 then
	local m = gui.mirror(st.wk)
	for k, r in pairs(m and m.rows or {}) do
		if string.sub(k, 1, 2) == "j:" and r.at == here then
			gui.close_screens(p)
			details.open(p, string.sub(k, 3))
			what = "details"
			break
		end
	end
end
if not what then
	if not (st.center and st.center.frame.valid) then
		gui.close_screens(p)
		center.open(p)
	end
	local tab = (f %% 3) + 1
	local pane = gui.state(p).center.refs.pane
	pane.selected_tab_index = tab
	center.on.tab.center_tab(p, pane)
	what = ({ "jobs", "ctrons", "stations" })[tab]
end
game.take_screenshot({ player = p, by_player = p, show_gui = true, path = string.format("live/%%04d-%%s.png", f, what) })
rcon.print("shot " .. what)
"""


# Before the camera joins: no freeplay crash site or intro for it (the wrecks' fires keep repair cells coming, which
# stalls the E2E's reset), and none left from an earlier camera.
PREP = """
if remote.interfaces.freeplay then
	remote.call("freeplay", "set_disable_crashsite", true)
	remote.call("freeplay", "set_skip_intro", true)
end
local s = game.surfaces.nauvis
for _, e in pairs(s.find_entities_filtered({ type = "fire" })) do e.destroy() end
for _, e in pairs(s.find_entities()) do
	if string.find(e.name, "crash-site", 1, true) then e.destroy() end
end
rcon.print("prep")
"""
DEBUG = 'package.loaded["%sgui.lua"].send("ct.settings.set", { patch = { debug = %s } }) rcon.print("debug %s")'


def dev(*args, timeout=60):
	r = subprocess.run([os.path.join(repo, "dev"), *args], cwd=repo, capture_output=True, text=True, timeout=timeout)
	return r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""


def port_of(instance):
	"""The game port from the newest "Hosting game at" line of the instance in the cluster log."""
	logs = sorted(glob.glob(os.path.join(root, "cluster/logs/cluster/cluster-*.log")))
	port = None
	for path in logs[-2:]:
		with open(path, errors="replace") as f:
			for line in f:
				if '"instance_name":"%s"' % instance in line and "Hosting game at" in line:
					m = re.search(r":(\d+)\}\)", line)
					port = m and int(m.group(1)) or port
	return port


def prepare(work):
	"""Write-data, config, player name and the pack's mods (as on the test cluster) for the camera client."""
	data = os.path.join(work, "data")
	os.makedirs(os.path.join(data, "mods"), exist_ok=True)
	with open(os.path.join(root, "cluster/database/mod-packs.json")) as f:
		pack = next(p for p in json.load(f) if p["name"] == "v2-ctronv2")
	builtin = {"base", "space-age", "quality", "elevated-rails", "recycler"}
	for m in pack["mods"]:
		if m["name"] not in builtin:
			shutil.copy(os.path.join(root, "cluster/mods", "%s_%s.zip" % (m["name"], m["version"])),
				os.path.join(data, "mods"))
	with open(os.path.join(data, "mods/mod-list.json"), "w") as f:
		json.dump({"mods": [{"name": m["name"], "enabled": m.get("enabled", True)} for m in pack["mods"]]}, f)
	with open(os.path.join(data, "player-data.json"), "w") as f:
		json.dump({"service-username": "cam"}, f)
	with open(os.path.join(work, "config.ini"), "w") as f:
		f.write("[path]\nread-data=%s/data\nwrite-data=%s\n[other]\ncheck-updates=false\n" % (factorio, data))
	return data


def launch(work, display, port):
	"""The client on the virtual display, never the desktop (see run.sh); None when it picked another driver."""
	run = os.path.join(work, "run")
	os.makedirs(run, mode=0o700, exist_ok=True)
	env = {k: v for k, v in os.environ.items() if k != "WAYLAND_DISPLAY"}
	env.update(XDG_RUNTIME_DIR=run, SDL_VIDEO_DRIVER="x11", SDL_VIDEODRIVER="x11", DISPLAY=display)
	log = os.path.join(work, "data/factorio-current.log")
	if os.path.exists(log):
		os.remove(log)
	game = subprocess.Popen([os.path.join(factorio, "bin/x64/factorio"), "-c", os.path.join(work, "config.ini"),
		"--mp-connect", "127.0.0.1:%d" % port, "--window-size", "1920x1080", "--disable-audio",
		"--force-graphics-preset", "very-low", "--video-memory-usage", "low"], env=env,
		stdout=open(os.path.join(work, "factorio.out"), "w"), stderr=subprocess.STDOUT)
	for _ in range(50):
		text = open(log, errors="replace").read() if os.path.exists(log) else ""
		m = re.search(r"Video driver: (\S+)", text)
		if m:
			if m.group(1) != "x11":
				game.kill()
				sys.exit("camera not on the virtual display (%s); stopped" % m.group(1))
			return game
		time.sleep(0.1)
	game.kill()
	sys.exit("camera: no video driver line; stopped")


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("out")
	ap.add_argument("--instance", default="e2e-a")
	ap.add_argument("--every", type=float, default=6)
	ap.add_argument("--debug", action="store_true", help="ctron debug drawing on for the run, off after it")
	argv = sys.argv[1:]
	split = argv.index("--") if "--" in argv else len(argv)
	a, cmd = ap.parse_args(argv[:split]), argv[split + 1:]
	if not cmd:
		ap.error("no command after --")
	out = os.path.abspath(a.out)
	work = os.path.join(out, ".camera")
	shutil.rmtree(os.path.join(work, "data/script-output"), ignore_errors=True)
	os.makedirs(work, exist_ok=True)
	num = os.environ.get("DISPLAY_NUM", "78")
	if os.path.exists("/tmp/.X%s-lock" % num):
		sys.exit("display :%s is taken (/tmp/.X%s-lock); set DISPLAY_NUM" % (num, num))
	display = ":" + num
	xvfb = subprocess.Popen(["Xvfb", display, "-screen", "0", "1920x1080x24", "-nolisten", "tcp"],
		stderr=subprocess.DEVNULL)
	game, joined_port, frame, data, idle = None, None, 0, None, 0
	try:
		driver = subprocess.Popen(cmd, cwd=repo, stdout=open(os.path.join(out, "command.log"), "w"),
			stderr=subprocess.STDOUT)
		while driver.poll() is None:
			time.sleep(a.every)
			port = port_of(a.instance)
			if port is None:
				continue
			if game is None or game.poll() is not None or port != joined_port or idle >= 10:
				if game and game.poll() is None:
					game.kill()
				idle = 0
				data = data or prepare(work)
				print(dev("rcon", a.instance, "/sc " + " ".join(PREP.split())), flush=True)
				game, joined_port = launch(work, display, port), port
				continue
			try:
				reply = dev("rcon", a.instance, "/sc " + " ".join((LUA % {"L": L, "FRAME": frame}).split()))
			except subprocess.TimeoutExpired:
				reply = "timeout"
			print(time.strftime("%H:%M:%S"), frame, reply, flush=True)
			if reply.startswith("shot"):
				if frame == 0 and a.debug:
					print(dev("rcon", a.instance, "/sc " + DEBUG % (L, "true", "on")), flush=True)
				frame, idle = frame + 1, 0
			else:
				idle += 1  # joining, or dropped at a restart: ten misses in a row rejoin
	finally:
		if a.debug and frame > 0:
			print(dev("rcon", a.instance, "/sc " + DEBUG % (L, "false", "off")), flush=True)
		if game and game.poll() is None:
			game.kill()
		xvfb.kill()
		xvfb.wait()
		for png in sorted(glob.glob(os.path.join(work, "data/script-output/live/*.png"))):
			shutil.copy(png, out)
	print("command exit", driver.returncode, "frames", frame)
	sys.exit(driver.returncode)


main()
