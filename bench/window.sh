#!/bin/sh
# A measuring window: stop the production server, run each step in turn on
# :8001, then start production again, even when a step fails.
#
#   sh bench/window.sh NAME STEP...            in this shell
#   sh bench/window.sh --detach NAME STEP...   as a launchd job, so it
#                                              survives the terminal closing
#
# A STEP is a config (a speed run), or CMD:CONFIG with CMD one of gates,
# longgates, refuse, kld, or kldref alone. Example, a candidate between two
# controls:
#
#   sh bench/window.sh --detach kv4 configs/control.json \
#       configs/kv4.json configs/control.json
#
# The log is bench/out/logs/window-NAME.log. If the window dies with the
# server stopped, start it again with: sh scripts/3-services.sh
cd "$(dirname "$0")" || exit 1
H=$(pwd)
mkdir -p out/logs

if [ "${1:-}" = --detach ]; then
	shift
	name=$1
	L=com.llmserver.bench-window
	P=$H/out/logs/$L.plist
	launchctl bootout "gui/$(id -u)/$L" 2>/dev/null
	sleep 1
	{
		printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
		printf '<plist version="1.0"><dict><key>Label</key><string>%s</string><key>ProgramArguments</key><array>' "$L"
		printf '<string>/bin/sh</string><string>%s/window.sh</string>' "$H"
		for a in "$@"; do printf '<string>%s</string>' "$a"; done
		# Interactive, like production's LaunchAgent: launchd throttles other jobs.
		printf '</array><key>WorkingDirectory</key><string>%s</string><key>RunAtLoad</key><true/><key>ProcessType</key><string>Interactive</string>' "$H"
		printf '<key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>'
		printf '<key>StandardOutPath</key><string>%s/out/logs/window-%s.log</string><key>StandardErrorPath</key><string>%s/out/logs/window-%s.log</string>' "$H" "$name" "$H" "$name"
		printf '</dict></plist>\n'
	} >"$P"
	launchctl bootstrap "gui/$(id -u)" "$P" && echo "started $name; log bench/out/logs/window-$name.log"
	exit
fi

name=$1
shift
D=gui/$(id -u)
L=com.llmserver.mlx-serve
P=$HOME/Library/LaunchAgents/$L.plist
mkdir out/window.lock 2>/dev/null || {
	echo "another window holds bench/out/window.lock"
	exit 1
}
restore() {
	rmdir out/window.lock
	python3 bench.py stop
	launchctl bootstrap "$D" "$P" 2>/dev/null || {
		sleep 3
		launchctl bootstrap "$D" "$P"
	}
	n=0
	until curl -fsS -o /dev/null http://127.0.0.1:8000/health || [ $n -gt 120 ]; do
		sleep 1
		n=$((n + 1))
	done
	echo "$(date +%T) production restored, health after ${n}s"
}
trap restore EXIT
trap 'exit 1' INT TERM HUP

echo "$(date +%T) window $name: stopping production"
launchctl bootout "$D/$L" 2>/dev/null
n=0
while launchctl print "$D/$L" >/dev/null 2>&1 && [ $n -lt 60 ]; do
	sleep 0.5
	n=$((n + 1))
done
while pgrep -x mlx-serve >/dev/null; do sleep 1; done
sleep 5
for s in "$@"; do
	echo "$(date +%T) step $s"
	case $s in
	kldref) python3 bench.py kldref ;;
	gates:* | longgates:* | refuse:* | kld:*) python3 bench.py "${s%%:*}" "${s#*:}" ;;
	*) python3 bench.py run "$s" ;;
	esac || echo "$(date +%T) FAIL $s"
	sleep 10
done
echo "$(date +%T) WINDOW_DONE $name"
