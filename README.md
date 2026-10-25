# 在 1Panel 上搭建网盘音乐服务器：Rclone、InfiniCloud 与 Navidrome 实战

我想把音乐留在网盘里，用自己的网页和音乐客户端播放，同时尽量少占 VPS 硬盘。这次实际搭建的方案是：Rclone 在服务器上挂载 InfiniCloud 的音乐目录，Navidrome 通过 Docker 读取它，最后由 1Panel 的 OpenResty 提供 HTTPS 入口。

这篇记录整理于 2026 年 10 月 25 日。配置来自实际部署，账号、密码、域名和容器名称均已替换为示例。**不要直接照抄自己的密码到命令、文章或 GitHub。**

## 一键部署脚本

新服务器可使用 [install.sh](install.sh)，详细操作见 [脚本说明](docs/installer.md)。已有 Navidrome 时会停止安装，保护现有实例；当前教程中的服务器无需重装。

```bash
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/SamueruTokeisou/1panel-rclone-navidrome-guide/main/install.sh \
  -o install.sh
bash install.sh help
sudo bash install.sh install
```

需要事先安装 Docker/Compose v2，支持 Debian/Ubuntu + systemd。脚本交互输入凭据，自动配置只读挂载、独立容器、缓存与开机服务，默认只监听本地；域名和 HTTPS 仍通过 1Panel 设置。它创建的容器可在面板查看，但不会登记为应用商店应用。

脚本还提供 `status`、`start`、`add-cloud`。`add-cloud` 仅管理脚本创建的实例。仓库包含自动检查工作流和离线测试；脚本与扩展方案尚未在真实新服务器完成端到端部署测试。

## 后续实战：把 Windows 电脑也接进来

新增 **[Windows 网盘 → FRP → WebDAV → Navidrome 完整记录](docs/windows-cloud.md)**，包含本地目录配置、HTTPS 反向代理、只读挂载、多音乐库和日常维护。令牌能否永久有效、到期怎么换，见 **[令牌期限与更换](docs/token-renewal.md)**。

这部分已接入真实电脑音乐源，扫描 19 首、2 张专辑，并验证浏览器连续播放超过两分钟。一键脚本的范围仍是服务器 Rclone + Navidrome，不包含 Windows 网盘与 FRP。

## 本次完成到哪一步

| 项目 | 本次情况 |
| --- | --- |
| 系统 | Debian GNU/Linux 13.2，amd64 |
| 面板 | 1Panel 社区版 v2.4.1，Docker 已安装 |
| Rclone | 官方安装脚本安装的 v1.75.2 |
| Navidrome | 1Panel 应用商店提供的 v0.64.2 |
| 网盘 | InfiniCloud，WebDAV 连接 |
| 挂载 | 只读，UID/GID 1000:1000，systemd 开机启动 |
| 服务检查 | 容器目录可读，HTTP 返回 200，扫描流程完成 |
| 网页检查 | HTTPS 可访问，管理员创建后能进入音乐库 |
| 恢复检查 | 手动重启挂载服务后，容器恢复读取 |
| 后续电脑音乐源 | 已接入 Windows WebDAV，扫描 19 首、2 张专辑，浏览器播放超过两分钟，详见后续实战 |
| 尚未验证 | 初次 InfiniCloud Music 为空；任意拖动进度、大规模扫描、全部格式、整机重启与断网恢复仍未验证 |

这里的版本是本次部署记录，不代表以后安装时的最新版本。首次安装和更新都应查看自己的应用商店与上游说明。

## 一、这套方案怎么工作

```text
InfiniCloud 的 Music 目录
        │ WebDAV
        ▼
Rclone / systemd
        │ 只读挂载
        ▼
服务器 /mnt/cloud/Music
        │ Docker 只读映射
        ▼
Navidrome 容器 /music
        │ 服务器本地 127.0.0.1:40108
        ▼
1Panel OpenResty → HTTPS 域名 → 浏览器 / 音乐客户端
```

数据库、账号和播放列表保存在服务器的 `/data` 映射目录。音乐来自网盘，Rclone 按读取需要缓存数据。扫描、封面提取和播放都可能产生网络流量与本地缓存，并不是完全不占硬盘。

本次只挂载网盘里的 `Music`，不把其他笔记和文件交给 Navidrome。上传音乐仍使用网盘网页或自己的上传工具。

## 二、准备工作与安装

下文在服务器 root 终端执行，可以使用 1Panel 的“终端”。已有 Navidrome 时，先备份应用数据并核对路径；不要删除旧容器的数据目录来“重新安装”。

先检查：

```bash
cat /etc/os-release
docker ps -a
df -h /
free -h
command -v rclone
ls -l /dev/fuse
```

需要可用的 FUSE 设备。某些容器型 VPS 不提供 `/dev/fuse`，应先向服务商确认。

安装依赖，再从 [Rclone 官方安装源](https://rclone.org/install/) 安装：

```bash
apt-get update
apt-get install -y curl unzip fuse3
curl -fsSL https://rclone.org/install.sh -o /tmp/rclone-install.sh
# 可以先查看脚本内容，再执行
bash /tmp/rclone-install.sh
rclone version
command -v rclone
```

本次实际服务器还通过 apt 安装过 Rclone，但仓库提供的是 1.60.1，之后才更新到 1.75.2。新环境不必为了重复这个过程先装旧版本。

## 三、连接 InfiniCloud

在 InfiniCloud 的 Apps Connection 页面启用连接，记下自己的 WebDAV Connection URL、Connection ID 和 Apps Password。连接密码应使用该页面生成的 Apps Password。

```bash
install -d -m 700 /root/.config/rclone
rclone config
```

按名称选择选项，避免照抄会随版本变化的菜单编号：

| 配置项 | 填写方式 |
| --- | --- |
| New remote | 新建，名称填 `cloud` |
| Storage | `webdav` |
| URL | 自己页面给出的完整 WebDAV 地址，例如 `https://YOUR-SERVER.teracloud.jp/dav/` |
| Vendor | `other` |
| User | Connection ID |
| Password | Apps Password，使用交互式输入 |
| Bearer token | 无此需求则留空 |
| Advanced config | 本文不需要，保存后退出 |

```bash
chmod 600 /root/.config/rclone/rclone.conf
rclone lsf cloud: --dirs-only --max-depth 1
```

先确认根目录能列出，再检查音乐目录。如果没有 Music，可在网盘网页创建，或者明确执行：

```bash
rclone mkdir cloud:Music
rclone lsf cloud:Music --max-depth 1
```

空目录没有文件输出是正常情况，命令报错才需要排查。路径大小写要一致。

Rclone 配置中的密码混淆值可以还原，OAuth token 也属于凭据。`rclone.conf` 应仅由受信任的管理员读取，不要上传到仓库。[WebDAV 配置参考](https://rclone.org/webdav/)

## 四、配置持久只读挂载

```bash
install -d /mnt/cloud/Music /var/cache/rclone
nano /etc/systemd/system/rclone-mount.service
```

填入以下内容，也可参考仓库内的 [服务示例](examples/rclone-mount.service)：

```ini
[Unit]
Description=InfiniCloud Music read-only mount
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount cloud:Music /mnt/cloud/Music --config=/root/.config/rclone/rclone.conf --read-only --allow-other --uid=1000 --gid=1000 --umask=022 --vfs-cache-mode=full --cache-dir=/var/cache/rclone --vfs-cache-max-size=3G --vfs-cache-max-age=24h --vfs-cache-min-free-space=5G --buffer-size=8M --dir-cache-time=5m --poll-interval=0 --log-level=INFO
ExecStop=/usr/bin/fusermount3 -u /mnt/cloud/Music
Restart=on-failure
RestartSec=10
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
```

`ExecStart` 必须是一整行。若 `command -v rclone` 返回的不是 `/usr/bin/rclone`，相应修改绝对路径；也要检查 `fusermount3` 的路径。

```bash
systemctl daemon-reload
systemctl enable --now rclone-mount.service
systemctl is-active rclone-mount.service
findmnt /mnt/cloud/Music
ls -la /mnt/cloud/Music
```

本次选择这些参数的原因：

- `--read-only` 防止通过挂载修改网盘；`--allow-other` 让其他服务器用户进程（包括容器）能够读取。
- UID/GID 1000:1000 与本次 Navidrome 容器一致，`umask=022` 提供可读权限。
- `full` 缓存支持文件读取与随机访问；3G、24h 和保留 5G 空间用于控制缓存清理。
- 目录缓存设为 5 分钟，WebDAV 不依赖变更轮询；刚上传的文件可能不会立刻出现在挂载中。
- 日志写入 systemd journal，日常用 INFO，避免长期 DEBUG 日志大量增长。

**3G 是缓存清理目标，不是硬盘配额。** 缓存清理由后台执行，仍在使用的文件可能无法立刻回收；保留 5G 也不是绝对空间保证。应同时观察 `df -h /` 和 `du -sh /var/cache/rclone`。详见 [Rclone VFS 缓存说明](https://rclone.org/commands/rclone_mount/#vfs-file-caching)。

这里不使用 `--allow-non-empty`；挂载点应是新建的空目录，也不要在只读网盘目录上递归运行 `chown`、`chmod`。

## 五、在 1Panel 安装 Navidrome

进入“应用商店 → Navidrome → 安装”。本次使用端口 `40108`，镜像固定为 `deluan/navidrome:0.64.2`。

先关闭“端口外部访问”，启用“编辑 compose 文件”。保留 1Panel 生成的容器名称变量、网络与标签，重点修改端口和音乐映射：

```yaml
services:
  navidrome:
    image: deluan/navidrome:0.64.2
    container_name: ${CONTAINER_NAME}
    restart: always
    networks:
      - 1panel-network
    ports:
      - "127.0.0.1:${PANEL_APP_PORT_HTTP}:4533"
    volumes:
      - ./data/data:/data
      - /mnt/cloud/Music:/music:ro
    user: 1000:1000
    environment:
      ND_SCANSCHEDULE: "1h"
      ND_LOGLEVEL: info
      ND_SESSIONTIMEOUT: "24h"
      ND_BASEURL: ""
    labels:
      createdBy: "Apps"
networks:
  1panel-network:
    external: true
```

这是 **1Panel 安装表单使用的模板**，其中环境变量由面板提供，不能脱离面板直接照抄运行。`./data/data` 是应用目录内的数据路径；已有实例应保留原来的 `/data` 映射。

本地监听避免直接把 40108 暴露到公网。HTTPS 访问通过下一节的网站入口完成。

安装后，在 1Panel 查看实际容器名。下面的 `YOUR_NAVIDROME_CONTAINER` 都要替换为自己的名称：

```bash
docker ps --filter name=navidrome
docker logs --tail 50 YOUR_NAVIDROME_CONTAINER
docker exec YOUR_NAVIDROME_CONTAINER sh -c 'id; ls -ld /music /data; test -r /music && echo MUSIC_READABLE'
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:40108/ping
```

本次返回 `MUSIC_READABLE` 和 `HTTP 200`，日志显示扫描完成。空音乐目录也能完成扫描，这不等于已经验证歌曲播放。[Navidrome Docker 文档](https://www.navidrome.org/docs/installation/docker/)

## 六、挂载恢复后，让容器重新连接

Docker 绑定的 FUSE 挂载在重建后可能仍指向旧挂载。只重启 Rclone，有时会看到服务器目录恢复了，容器却仍不可读。

本次处理方式是在挂载就绪后重启 Navidrome。先确认容器已经安装且名称正确，再创建附加配置：

```bash
install -d /etc/systemd/system/rclone-mount.service.d
nano /etc/systemd/system/rclone-mount.service.d/navidrome.conf
```

```ini
[Unit]
After=docker.service

[Service]
ExecStartPost=-/usr/bin/docker restart YOUR_NAVIDROME_CONTAINER
```

```bash
systemctl daemon-reload
# 此操作会短暂中断音乐服务，请在没有播放任务时测试
systemctl restart rclone-mount.service
systemctl is-active rclone-mount.service
docker exec YOUR_NAVIDROME_CONTAINER ls -ld /music
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:40108/ping
```

前面的 `-` 表示容器重启失败不让挂载服务跟着失败，因此仍须检查容器和日志。这个办法在本次手动重启挂载测试中通过，整机重启后的恢复应另选维护时段验证。以后容器名称变化，也要更新这里。

## 七、域名、HTTPS 与首次使用

下面统一使用 `music.example.com` 作为示例域名：

1. 在 DNS 服务商处添加解析，指向 VPS。已有同机子域名时，也可根据自己的 DNS 配置添加合适的 CNAME。
2. 进入“1Panel → 网站 → 创建 → 一键部署”，选择已安装的 Navidrome，填写域名。
3. 在“网站 → 证书”申请匹配的证书。本次使用已有 Cloudflare DNS 账户完成 DNS 验证，并开启自动续签。
4. 打开该网站的“配置 → HTTPS”，选择匹配的 ACME 账户和证书，保存，并启用 HTTP 自动跳转 HTTPS。
5. 浏览器打开自己的域名，确认没有证书错误，再立即创建首个管理员。

初次管理员创建页面不要长期对外开放。管理员密码由自己设置，不要复用网盘 Apps Password。

最后进行真实歌曲验证：上传一首自己有权使用的音乐到网盘 `Music`，等目录缓存更新，在 Navidrome 发起扫描，然后检查曲目信息、播放、拖动进度和封面。每小时扫描已通过 `ND_SCANSCHEDULE` 配置，不需要再新增未被读取的 toml 文件。

## 八、以后添加其他网盘

推荐保留现在的 `cloud` 和 `/music`，给每个新网盘分配独立 remote、挂载目录和服务：

```text
cloud:Music  → /mnt/cloud/Music   → 容器 /music   → InfiniCloud 音乐库
cloud2:Music → /mnt/cloud2/Music  → 容器 /music2  → 第二网盘音乐库
```

Navidrome 已支持多音乐库。先让新网盘在宿主机和容器内都可读，再去“Settings → Libraries”添加 `/music2`，并为普通用户分配权限。这种方式便于判断是哪一个网盘出故障，也不用合并同名路径。[官方多音乐库说明](https://www.navidrome.org/docs/usage/features/multi-library/)

通用命令、服务模板和不同网盘的选择方法见 **[添加第二个及更多网盘](docs/multiple-clouds.md)**。其中 Windows FileBrowser WebDAV 已实际接入，见 **[电脑网盘实战](docs/windows-cloud.md)**；其他后端示例仍需自行验证。

## 九、维护与排错

```bash
systemctl status rclone-mount.service --no-pager
journalctl -u rclone-mount.service -n 80 --no-pager
findmnt /mnt/cloud/Music
docker logs --tail 80 YOUR_NAVIDROME_CONTAINER
df -h /
du -sh /var/cache/rclone
```

| 现象 | 优先检查 |
| --- | --- |
| 网盘连接失败 | URL、Connection ID、Apps Password、账号连接权限与服务器网络 |
| Music 为空 | 是否上传到了准确目录；大小写；目录缓存是否已更新 |
| 容器 permission denied | UID/GID、`--allow-other`、挂载是否成功；不要用 `chmod -R 777` 代替排查 |
| 宿主机可读，容器不可读 | 是否刚重新挂载；确认挂载正常后重启 Navidrome |
| HTTP 200，但歌曲不能播放 | 真实文件读取、网络速度、网盘限流和缓存空间；HTTP 200 只证明接口响应 |
| HTTPS 错误或 502 | DNS、证书匹配、OpenResty 代理目标、Navidrome 是否运行 |
| 上传后没有新增曲目 | 先确认挂载能看到文件，再在 Navidrome 扫描；WebDAV 不保证实时刷新 |

升级、改路径和改网盘前，备份 Navidrome 的完整数据目录、Compose、systemd 服务与附加配置。数据库备份可在暂停 Navidrome 后复制数据目录，完成再启动；网盘凭据另行加密保存。不要把运行中的数据库随便复制后当作已验证备份，也不要把缓存当备份。

恢复时应保留已有 `/data`，先检查网盘连接和挂载，再启动 Navidrome。卸载或迁移前区分音乐源文件、数据库与缓存，避免删除错误目录。

## 相关文件与参考

- [Rclone 挂载服务](examples/rclone-mount.service)
- [Navidrome 的 1Panel Compose 模板](examples/navidrome.1panel.compose.yml)
- [挂载后的容器重启配置](examples/navidrome-drop-in.conf)
- [添加第二个及更多网盘](docs/multiple-clouds.md)
- [Rclone 安装](https://rclone.org/install/)、[WebDAV](https://rclone.org/webdav/)、[mount](https://rclone.org/commands/rclone_mount/)
- [Navidrome Docker 安装](https://www.navidrome.org/docs/installation/docker/)、[多音乐库](https://www.navidrome.org/docs/usage/features/multi-library/)

本文由实际部署过程整理，并使用 AI 协助成文。已验证范围以开头的记录为准；后续网盘扩展需要在自己的环境中逐项检查。
