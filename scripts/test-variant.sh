#!/bin/sh
set -u
# shellcheck source=scripts/variant.sh
. "$(dirname "$0")/variant.sh"
BREW_PREFIX=/brew
LLM_HOME=/home/someone

fails=0
check() {
	if [ "$2" = "$3" ]; then
		printf 'ok    %s\n' "$1"
	else
		printf 'FAIL  %s: got %s\n' "$1" "$2"
		fails=$((fails + 1))
	fi
}

while IFS='|' read -r brand want; do
	got=$(detect_variant "$brand") || got=refused
	check "\"$brand\" -> $want" "$got" "$want"
done <<'CASES'
Apple M1|port
Apple M1 Max|port
Apple M2 Ultra|port
Apple M3 Pro|upstream
Apple M4|upstream
Apple M5 Max|upstream
Apple M6|upstream
Apple M10|upstream
Apple M12 Pro|upstream
Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz|refused
Apple A18 Pro|refused
|refused
CASES

kind() {
	eval "_v=\${$1-} _isset=\${$1+yes}"
	if [ -z "$_isset" ]; then echo unset
	elif [ -z "$_v" ]; then echo empty
	elif printf '%s' "$_v" | grep -Eqx '[0-9a-f]{64}'; then echo sha256
	else echo set
	fi
}

while read -r variant expected; do
	unset SPLASH_VERSION SPLASH_BIN SPLASH_RUN_DIR SPLASH_HOME SPLASH_INSTALLER_URL \
		SPLASH_INSTALLER_SHA256 SPLASH_ARCHIVE_SHA256 SPLASH_BOTTLE_SHA256
	variant_values "$variant"
	for pair in $expected; do
		check "$variant: ${pair%:*} is ${pair#*:}" "$(kind "${pair%:*}")" "${pair#*:}"
	done
done <<'VARIANTS'
port SPLASH_VERSION:set SPLASH_BIN:set SPLASH_RUN_DIR:set SPLASH_HOME:set SPLASH_INSTALLER_URL:set SPLASH_INSTALLER_SHA256:sha256
upstream SPLASH_VERSION:set SPLASH_BIN:set SPLASH_RUN_DIR:set SPLASH_ARCHIVE_SHA256:sha256 SPLASH_BOTTLE_SHA256:sha256
none SPLASH_VERSION:empty SPLASH_BIN:empty SPLASH_RUN_DIR:empty
VARIANTS

[ "$fails" -eq 0 ]
