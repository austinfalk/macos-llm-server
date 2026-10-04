#!/bin/sh
# Installed by scripts/4-harden.sh as /usr/local/sbin/llm-battery-watchdog.sh.
#
# Laptops only. A server laptop never sleeps on mains, and with
# LLM_DISABLE_SLEEP=yes not on battery either, so after a power cut it could run
# until the battery dies and lose everything in memory. This shuts it down
# cleanly first. Apple documents that Apple Silicon laptops power back on when
# mains power returns (not tested here).
THRESHOLD=@LLM_BATTERY_SHUTDOWN_PCT@

batt=$(/usr/bin/pmset -g batt)
case "$batt" in
	*"'AC Power'"*) exit 0 ;;
esac

pct=$(printf '%s\n' "$batt" | /usr/bin/sed -n 's/.*[^0-9]\([0-9][0-9]*\)%.*/\1/p' | /usr/bin/head -1)
[ -n "$pct" ] || exit 0
[ "$pct" -le "$THRESHOLD" ] || exit 0

/usr/bin/logger -t llm-battery-watchdog "on battery at ${pct}% (<= ${THRESHOLD}%), shutting down"
/sbin/shutdown -h now
