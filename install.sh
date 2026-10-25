#!/usr/bin/env bash
# Interactive Debian/Ubuntu installer. Never run this with bash -x.
set -Eeuo pipefail
set +x
umask 077

STATE=/opt/nd-music
UNITS=/etc/systemd/system
CONTAINER=nd-music
IMAGE=deluan/navidrome:0.64.2
RCLONE=/usr/bin/rclone
DOCKER=/usr/bin/docker
FUSERMOUNT=/usr/bin/fusermount3
PORT=''
SAVED_IMAGE=''

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
valid_id() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]{2,5}$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); }
valid_size() { [[ $1 =~ ^[1-9][0-9]*[MG]$ ]]; }
one_line() { [[ -n $1 && ! $1 =~ [[:cntrl:]] ]]; }
sd_quote() {
  local value=$1
  value=${value//\\/\\\\}; value=${value//\"/\\\"}; value=${value//%/%%}
  value=${value//\$/\$\$}
  printf '"%s"' "$value"
}
prompt() {
  local label=$1 default=${2:-} value
  printf '%s' "$label" >&2
  [[ -z $default ]] || printf ' [%s]' "$default" >&2
  printf ': ' >&2
  IFS= read -r value </dev/tty || die '无法读取终端输入。请先下载脚本，再使用 bash install.sh。'
  printf '%s' "${value:-$default}"
}
confirm() {
  local answer
  answer=$(prompt "$1，输入 yes 确认")
  [[ $answer == yes ]] || die '已取消，未执行该步骤。'
}
root_only() {
  ((EUID == 0)) || die '请在服务器使用 root 或 sudo bash install.sh。'
}
runtime_check() {
  [[ -d /run/systemd/system ]] || die '需要由 systemd 管理的服务器。'
  command -v docker >/dev/null || die '请先通过 1Panel 安装并启动 Docker。'
  docker info >/dev/null 2>&1 || die 'Docker 未运行。'
  docker compose version >/dev/null 2>&1 || die '需要 Docker Compose v2 插件。'
}
existing_navidrome() {
  local listing
  listing=$(docker ps -a --format '{{.Image}} {{.Names}}') || die '无法读取现有容器。'
  if [[ ${listing,,} == *navidrome* ]]; then
    say "$listing" >&2
    die '检测到已有 Navidrome，停止新安装。请使用 status 检查，并按教程维护原实例；不会接管或覆盖。'
  fi
}
dependencies() {
  local distro
  distro=$(. /etc/os-release; printf '%s' "$ID")
  [[ $distro == debian || $distro == ubuntu ]] || die '第一版仅支持 Debian/Ubuntu。'
  apt-get update
  apt-get install -y curl unzip fuse3 ca-certificates
  if ! command -v rclone >/dev/null; then
    local installer
    installer=$(mktemp)
    curl --fail --show-error --location --proto '=https' --tlsv1.2 https://rclone.org/install.sh -o "$installer"
    bash "$installer"
    rm -f -- "$installer"
  fi
  RCLONE=$(command -v rclone)
  DOCKER=$(command -v docker)
  FUSERMOUNT=$(command -v fusermount3)
  "$RCLONE" mount --help | grep -- '--vfs-cache-min-free-space' >/dev/null || die '当前 Rclone 过旧，请先从官方安装源更新，再重试。'
  [[ -c /dev/fuse ]] || die '没有 /dev/fuse，无法挂载；请联系 VPS 服务商。'
}
load_settings() {
  [[ -f $STATE/settings.tsv && -f $STATE/remotes.tsv ]] || die '尚无脚本管理的实例，请先 install。已有面板实例请用 status。'
  IFS=$'\t' read -r PORT SAVED_IMAGE < "$STATE/settings.tsv"
  valid_port "$PORT" || die 'settings.tsv 中端口无效。'
  [[ $SAVED_IMAGE == "$IMAGE" ]] || die '镜像版本与脚本不匹配，请先人工核对配置。'
  [[ -s $STATE/remotes.tsv ]] || die '没有已登记的网盘。检查失败原因后重新执行 add-cloud。'
  RCLONE=$(command -v rclone)
  DOCKER=$(command -v docker)
  FUSERMOUNT=$(command -v fusermount3)
}
validate_rows() {
  local id remote folder config cache
  while IFS=$'\t' read -r id remote folder config cache; do
    if ! valid_id "$id" || ! valid_id "$remote" || ! one_line "$folder" || ! valid_size "$cache"; then
      die '网盘登记记录无效。'
    fi
    [[ $config == "$STATE/remotes/$id.conf" || $config == /root/.config/rclone/rclone.conf ]] || die '配置文件路径无效。'
    [[ -f $config ]] || die "配置文件不存在：$config"
  done < "$STATE/remotes.tsv"
}
render_mount() {
  local id=$1 remote=$2 folder=$3 config=$4 cache=$5
  cat <<EOF
[Unit]
Description=nd-music cloud $id (read only)
Wants=network-online.target nd-music.service
After=network-online.target

[Service]
Type=notify
ExecStart=$(sd_quote "$RCLONE") mount $(sd_quote "$remote:$folder") /mnt/nd-music/$id --config=$(sd_quote "$config") --read-only --allow-other --uid=1000 --gid=1000 --umask=022 --vfs-cache-mode=full --cache-dir=/var/cache/nd-music/$id --vfs-cache-max-size=$cache --vfs-cache-max-age=24h --vfs-cache-min-free-space=5G --buffer-size=8M --dir-cache-time=5m --poll-interval=0 --log-level=INFO
ExecStop=$(sd_quote "$FUSERMOUNT") -u /mnt/nd-music/$id
Restart=on-failure
RestartSec=10
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF
}
render_compose() {
  local id remote folder config cache target first=yes
  cat <<EOF
services:
  navidrome:
    image: $IMAGE
    container_name: $CONTAINER
    restart: "no"
    user: "1000:1000"
    ports:
      - "127.0.0.1:$PORT:4533"
    environment:
      ND_SCANSCHEDULE: "1h"
      ND_LOGLEVEL: info
      ND_SESSIONTIMEOUT: "24h"
    volumes:
      - "$STATE/data:/data"
EOF
  while IFS=$'\t' read -r id remote folder config cache; do
    if [[ $first == yes ]]; then target=/music; first=no; else target=/music-$id; fi
    printf '      - "/mnt/nd-music/%s:%s:ro"\n' "$id" "$target"
  done < "$STATE/remotes.tsv"
}
render_app_unit() {
  local id remote folder config cache mounts=''
  while IFS=$'\t' read -r id remote folder config cache; do
    mounts+=" nd-music-$id.service"
  done < "$STATE/remotes.tsv"
  cat <<EOF
[Unit]
Description=Navidrome managed by nd-music installer
Requires=docker.service$mounts
After=docker.service$mounts
BindsTo=$mounts

[Service]
Type=simple
WorkingDirectory=$STATE
ExecStart=$(sd_quote "$DOCKER") compose -p nd-music -f $(sd_quote "$STATE/compose.yml") up --no-color --abort-on-container-exit
ExecStop=$(sd_quote "$DOCKER") compose -p nd-music -f $(sd_quote "$STATE/compose.yml") stop --timeout 20
Restart=always
RestartSec=10
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
}
backup_config() {
  local destination
  destination="$STATE/backups/$(date +%Y%m%d-%H%M%S)-$$"
  install -d -m 700 "$destination"
  local file
  for file in settings.tsv remotes.tsv compose.yml; do
    [[ ! -f $STATE/$file ]] || cp -p -- "$STATE/$file" "$destination/"
  done
  say "配置快照：$destination（不包含数据库和音乐备份）"
}
add_remote() {
  local id mode folder cache remote config url user password obscured
  id=$(prompt '新挂载名称，仅小写字母、数字、下划线、横线' cloud)
  valid_id "$id" || die '名称必须以小写字母开头，最长 32 字符。'
  ! cut -f1 "$STATE/remotes.tsv" | grep -Fxq "$id" || die '这个挂载名称已登记，不会覆盖。'
  [[ ! -e $UNITS/nd-music-$id.service ]] || die '同名服务已存在，不会覆盖。'
  folder=$(prompt '网盘内的目录（必须已存在；根目录填 /）' Music)
  one_line "$folder" || die '目录不能是空值或包含控制字符。'
  cache=$(prompt '此挂载缓存清理目标（不是硬配额）' 1G)
  valid_size "$cache" || die '请填写正整数和 M/G，例如 512M 或 1G。'
  mode=$(prompt '连接方式：1=新建 WebDAV；2=复用 root 已配置的 Rclone remote' 1)
  if [[ $mode == 1 ]]; then
    config="$STATE/remotes/$id.conf"
    [[ ! -e $config ]] || die "已有未登记配置 $config。请核查后改用另一名称，不会覆盖凭据。"
    url=$(prompt 'WebDAV 完整 HTTPS URL（不能包含账号密码）')
    if [[ $url != https://* || $url == *'@'* ]] || ! one_line "$url"; then
      die '需要不内嵌凭据的 HTTPS URL。'
    fi
    user=$(prompt 'WebDAV Connection ID / 用户名')
    one_line "$user" || die '用户名不能为空或包含控制字符。'
    printf 'Apps Password（输入不回显）: ' >&2
    IFS= read -rs password </dev/tty || die '无法读取密码。'
    printf '\n' >&2
    [[ -n $password ]] || die '密码不能为空。'
    obscured=$(printf '%s\n' "$password" | "$RCLONE" obscure -)
    unset password
    printf '[music]\ntype = webdav\nurl = %s\nvendor = other\nuser = %s\npass = %s\n' "$url" "$user" "$obscured" > "$config"
    unset obscured
    chmod 600 "$config"
    remote=music
  elif [[ $mode == 2 ]]; then
    config=/root/.config/rclone/rclone.conf
    [[ -f $config ]] || die '请先以 root 运行 rclone config，完成其他网盘授权。'
    ! grep -q '^RCLONE_ENCRYPT_V' "$config" || die '第一版不支持需要交互解密的 Rclone 配置。'
    remote=$(prompt '已有 remote 名称（不带冒号）')
    valid_id "$remote" || die '第一版要求 remote 名称为小写安全名称，请先在 rclone 中调整。'
    "$RCLONE" listremotes --config "$config" | grep -Fx "$remote:" >/dev/null || die '未找到该 remote。'
  else
    die '连接方式只能是 1 或 2。'
  fi
  say '正在验证远程目录；不会自动创建或修改网盘文件。'
  "$RCLONE" lsf "$remote:$folder" --config "$config" --max-depth 1 --contimeout 15s --timeout 30s --retries 1 >/dev/null
  install -d "/mnt/nd-music/$id" "/var/cache/nd-music/$id"
  mountpoint -q "/mnt/nd-music/$id" && die '目标已经挂载，不会接管。'
  [[ -z $(find "/mnt/nd-music/$id" -mindepth 1 -maxdepth 1 -print -quit) ]] || die '挂载目录非空。'
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$remote" "$folder" "$config" "$cache" >> "$STATE/remotes.tsv"
  say "已登记：$id。若后续启动失败，保留现场，用 status 查看原因。"
}
write_services() {
  validate_rows
  local id remote folder config cache
  render_compose > "$STATE/compose.yml.new"
  "$DOCKER" compose -p nd-music -f "$STATE/compose.yml.new" config --quiet
  mv -- "$STATE/compose.yml.new" "$STATE/compose.yml"
  while IFS=$'\t' read -r id remote folder config cache; do
    render_mount "$id" "$remote" "$folder" "$config" "$cache" > "$UNITS/nd-music-$id.service"
  done < "$STATE/remotes.tsv"
  render_app_unit > "$UNITS/nd-music.service"
  systemctl daemon-reload
}
start_stack() {
  load_settings
  write_services
  "$DOCKER" compose -p nd-music -f "$STATE/compose.yml" pull
  local id remote folder config cache
  while IFS=$'\t' read -r id remote folder config cache; do
    systemctl enable --now "nd-music-$id.service"
    mountpoint -q "/mnt/nd-music/$id" || die "挂载未就绪：$id"
  done < "$STATE/remotes.tsv"
  systemctl enable nd-music.service
  systemctl restart nd-music.service
  local attempt
  for ((attempt=1; attempt<=30; attempt++)); do
    if curl --fail --silent --max-time 2 "http://127.0.0.1:$PORT/ping" >/dev/null; then
      say "成功：本地 HTTP 检查通过。1Panel 反向代理目标：http://127.0.0.1:$PORT"
      say '服务由 systemd 管理，可在 1Panel 容器列表看到；不会注册为应用商店应用。'
      say '下一步配置 HTTPS 域名，立即创建管理员，上传音乐并验证播放。'
      return
    fi
    sleep 2
  done
  die 'HTTP 尚未就绪。请运行 status 检查；没有删除任何数据。'
}
install_stack() {
  runtime_check
  [[ ! -e $STATE ]] || die "已有 $STATE，停止重复安装。使用 status、start 或 add-cloud。"
  [[ ! -e $UNITS/nd-music.service ]] || die '已有同名 systemd 服务，不会覆盖。'
  ! docker inspect "$CONTAINER" >/dev/null 2>&1 || die '容器名 nd-music 已被使用。'
  existing_navidrome
  local port used
  port=$(prompt '本地监听端口（不开放公网）' 40108)
  valid_port "$port" || die '端口须在 1024–65535 之间。'
  command -v ss >/dev/null || die '缺少 ss，请先安装 iproute2。'
  used=$(ss -H -ltn "sport = :$port")
  [[ -z $used ]] || die '端口已经使用，请换一个。'
  say '将安装 Rclone/FUSE、创建独立目录、只读挂载网盘并拉取 Navidrome。不会安装 Docker、修改防火墙或配置域名。'
  confirm '开始安装'
  dependencies
  install -d -m 700 "$STATE" "$STATE/remotes"
  install -d -o 1000 -g 1000 -m 750 "$STATE/data"
  printf '%s\t%s\n' "$port" "$IMAGE" > "$STATE/settings.tsv"
  : > "$STATE/remotes.tsv"
  add_remote
  start_stack
}
add_cloud() {
  runtime_check
  [[ -f $STATE/settings.tsv && -f $STATE/remotes.tsv ]] || die '仅支持给本脚本部署的实例添加。现有 1Panel 应用请按 docs/multiple-clouds.md 操作。'
  RCLONE=$(command -v rclone)
  backup_config
  confirm '新增挂载并重建本脚本容器，播放会短暂中断'
  add_remote
  start_stack
  say '新增路径为 /music-挂载名称（首个挂载为 /music）。请到 Settings → Libraries 添加对应音乐库。'
}
status_stack() {
  say '=== Navidrome 容器（包括非本脚本管理的实例）==='
  if command -v docker >/dev/null; then
    docker ps -a --format '{{.Names}} {{.Image}} {{.Status}} {{.Ports}}' | grep -i navidrome || true
  fi
  if [[ ! -f $STATE/remotes.tsv ]]; then
    say '没有本脚本管理的实例。你已有的 1Panel 安装不会被改动。'
    return
  fi
  systemctl --no-pager --full status nd-music.service || true
  local id remote folder config cache
  while IFS=$'\t' read -r id remote folder config cache; do
    valid_id "$id" || continue
    systemctl is-active "nd-music-$id.service" || true
    findmnt "/mnt/nd-music/$id" || true
  done < "$STATE/remotes.tsv"
  df -h / "$STATE"
  say '日志：journalctl -u nd-music.service -n 80 --no-pager'
  say '挂载日志：journalctl -u nd-music-挂载名称.service -n 80 --no-pager'
}
usage() {
  cat <<'EOF'
用法：sudo bash install.sh [install|add-cloud|start|status|help]
  install    新服务器交互安装（默认）；发现已有 Navidrome 就停止
  add-cloud  给本脚本管理的实例添加网盘
  start      按保存的配置重建/恢复本脚本实例（会短暂中断播放）
  status     只读检查；也可用于已有 1Panel 服务器
  help       显示帮助
不含卸载、自动迁移、自动升级、自动域名/证书配置。
EOF
}
main() {
  local action=${1:-install}
  [[ $# -le 1 ]] || die '只接受一个命令，不接受密码等命令行参数。'
  case "$action" in help|-h|--help) usage; return;; esac
  root_only
  command -v flock >/dev/null || die '缺少 flock，请安装 util-linux。'
  exec 9>/run/lock/nd-music.lock
  flock -n 9 || die '另一个脚本正在运行。'
  trap 'printf "执行失败（行 %s）。未自动清理数据，请运行 status 检查。\n" "$LINENO" >&2' ERR
  case "$action" in
    install) install_stack;;
    add-cloud) add_cloud;;
    start) runtime_check; confirm '按已保存配置恢复/重建服务'; backup_config; start_stack;;
    status) status_stack;;
    *) usage; die '未知命令。';;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
