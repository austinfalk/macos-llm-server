#!/bin/sh
# Fail if a tracked file carries a detail that identifies the owner's machines
# or accounts. The repository is public, so docs and scripts use placeholders
# (`<machine>.<tailnet>.ts.net`, `100.64.0.0/10`, `alice@example.com`).
#
#     sh scripts/check-public.sh
#
# Checks, in tracked text files:
#   - a home directory path, `/Users/` and then a name (`/Users/$VAR` is fine)
#   - a `.ts.net` name other than `<machine>.<tailnet>.ts.net`
#   - an IPv4 address in 100.64.0.0/10 other than that literal range
#   - a Tailscale IPv6 address under fd7a:115c:a1e0: other than the `::/48` range
#   - a private LAN IPv4 address (10/8, 172.16/12, 192.168/16)
#   - an email address other than `*@users.noreply.github.com`,
#     `noreply@anthropic.com` and `*@example.com`. `alice@github`, Tailscale's
#     user form, has no domain and is not an email address.
#
# POSIX sh, and it sources nothing from lib.sh, so it also runs on Linux.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1

out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT

# Reads `file:line:match` lines and appends `FAIL file:line: label match`.
add() {
	awk -F: -v label="$1" '{
		tok = $0
		sub(/^[^:]*:[^:]*:/, "", tok)
		printf "FAIL %s:%s: %s %s\n", $1, $2, label, tok
	}' >>"$out"
}

git grep -I -n -o -E -e '/Users/[A-Za-z0-9][A-Za-z0-9._-]*' | add "home directory path"

git grep -I -n -o -i -E -e '[A-Za-z0-9<>._-]+\.ts\.net' \
	| grep -v ':<machine>\.<tailnet>\.ts\.net$' | add "tailnet name"

# Every dotted quad, optionally with a prefix length, classified by awk.
ipv4=$(git grep -I -n -o -E -e '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?')
printf '%s\n' "$ipv4" | awk -F: '
	{
		n = split($3, p, /[.\/]/)
		if (n < 4 || p[1] > 255 || p[2] > 255 || p[3] > 255 || p[4] > 255) next
		if (p[1] == 100 && p[2] >= 64 && p[2] <= 127 && $3 != "100.64.0.0/10") print
	}' | add "tailnet IPv4 address"
printf '%s\n' "$ipv4" | awk -F: '
	{
		n = split($3, p, /[.\/]/)
		if (n < 4 || p[1] > 255 || p[2] > 255 || p[3] > 255 || p[4] > 255) next
		if (p[1] == 10 || (p[1] == 172 && p[2] >= 16 && p[2] <= 31) || (p[1] == 192 && p[2] == 168)) print
	}' | add "private LAN address"

git grep -I -n -o -i -E -e 'fd7a:115c:a1e0:[0-9a-f]{1,4}:[0-9a-f:]*' | add "tailnet IPv6 address"

git grep -I -n -o -i -E -e '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' \
	| grep -v -i -e '@users\.noreply\.github\.com$' -e ':noreply@anthropic\.com$' -e '@example\.com$' \
	| add "email address"

problems=$(wc -l <"$out" | tr -d ' ')
if [ "$problems" -gt 0 ]; then
	cat "$out"
	printf '\n%s problem(s). Use the placeholders in README.md.\n' "$problems"
	exit 1
fi
printf 'ok   %s tracked files: no identifying details\n' "$(git ls-files | wc -l | tr -d ' ')"
