#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../install.sh
source "$ROOT/install.sh"
temp=$(mktemp -d)
trap 'rm -rf -- "$temp"' EXIT
STATE="$temp/state"
UNITS="$temp/units"
mkdir -p "$STATE/remotes" "$UNITS"
pass() { printf 'PASS: %s\n' "$1"; }
assert_reject() { if "$@"; then die "Unexpected acceptance: $*"; fi; }

valid_id cloud2
assert_reject valid_id '../escape'
assert_reject valid_id 'cloud;touch-pwned'
assert_reject valid_id $'cloud\ninjected'
assert_reject valid_id 'UPPER'
valid_port 40108
assert_reject valid_port 1023
assert_reject valid_port 65536
assert_reject valid_port '22;id'
valid_size 512M
assert_reject valid_size '0G'
assert_reject valid_size '2G --read-write'
assert_reject one_line $'Music\nExecStart=bad'
pass 'input validation rejects injection, invalid ports and cache sizes'

quoted=$(sd_quote 'cloud:Music $HOME/100% "live"')
[[ $quoted == *'$$HOME'* && $quoted == *'100%%'* && $quoted == *'\"live\"'* ]]
pass 'systemd quotes literal dollars, percent specifiers and quotes'

touch "$STATE/remotes/cloud.conf" "$STATE/remotes/second.conf"
printf 'cloud\tmusic\tMusic\t%s/remotes/cloud.conf\t1G\nsecond\tmusic\tMusic\t%s/remotes/second.conf\t512M\n' "$STATE" "$STATE" > "$STATE/remotes.tsv"
PORT=40108
validate_rows
render_compose > "$temp/compose.yml"
grep -Fq '127.0.0.1:40108:4533' "$temp/compose.yml"
grep -Fq '/mnt/nd-music/cloud:/music:ro' "$temp/compose.yml"
grep -Fq '/mnt/nd-music/second:/music-second:ro' "$temp/compose.yml"
grep -Fq "${STATE}/data:/data" "$temp/compose.yml"
! grep -q 'rclone.conf\|password\|privileged' "$temp/compose.yml"
pass 'additional cloud preserves /data and the original music mapping'

render_app_unit > "$temp/app.service"
grep -Fq 'BindsTo= nd-music-cloud.service nd-music-second.service' "$temp/app.service"
grep -Fq -- '--abort-on-container-exit' "$temp/app.service"
render_mount cloud music 'Music $HOME/100%' "$STATE/remotes/cloud.conf" 1G > "$temp/mount.service"
grep -Fq -- '--read-only' "$temp/mount.service"
grep -Fq 'Music $$HOME/100%%' "$temp/mount.service"
pass 'service binds application lifetime to every mount'

printf 'bad\tmusic\tMusic\t/etc/shadow\t1G\n' > "$STATE/remotes.tsv"
if (validate_rows) >/dev/null 2>&1; then die 'unexpected config path accepted'; fi
pass 'state file cannot redirect the mount to arbitrary credential files'

docker() { printf '%s\n' 'deluan/navidrome:0.64.2 1Panel-existing'; }
if (existing_navidrome) >/dev/null 2>&1; then die 'existing Navidrome not detected'; fi
pass 'existing 1Panel Navidrome blocks installation'

runtime_check() { :; }
if (install_stack) >/dev/null 2>&1; then die 'existing state was overwritten'; fi
pass 'repeat installation refuses existing state before any mutation'

printf '%s\n' 'All offline tests passed. No packages, mounts, containers or host units were changed.'
