# 把 Windows 电脑变成网盘，并把音乐接入 Navidrome

这篇是主教程的后续实战：音乐除了来自 InfiniCloud，也可以来自家中 Windows 电脑的一个文件夹。电脑提供 FileBrowser Quantum 网盘，FRP 把它接到 VPS，1Panel 提供 HTTPS，服务器上的 Rclone 再把 WebDAV 目录只读挂载给 Navidrome。

整理日期：2026-10-25。以下域名、IP、令牌和容器名均使用示例；不要把真实凭据写进公开仓库。

## 本次实际验证的结果

| 项目 | 结果 |
| --- | --- |
| Windows 网盘 | FileBrowser Quantum v2.0.2-stable，限定到 `D:\网盘` |
| 内网穿透 | FRP v0.71.1，TLS 服务器身份验证与独立连接令牌 |
| 公网访问 | HTTPS 登录页可访问；用户确认登录、上传、下载小文件成功 |
| WebDAV | 使用 API 令牌，服务器上的 Rclone 成功列出文件 |
| 音乐集成 | 新增“电脑网盘音乐”库，扫描 19 首、2 张专辑 |
| 实际播放 | 浏览器播放一首 M4A 来源的歌曲超过两分钟，播放进度前进、无媒体错误；服务端日志显示转为 FLAC 输出 |
| 原有配置 | 保留 InfiniCloud remote、原 `/music` 映射与 Navidrome 数据 |
| 尚未验证 | 完整整机重启、断网再上线恢复、全曲与所有格式、超大文件压力测试 |

一个额外的独立 FFmpeg 跳转解码测试耗时过长，已结束，不算通过。网页播放通过也不等于所有客户端与任意进度跳转都已验证。

## 一、连接结构

```text
Windows D:\网盘
    ↓
FileBrowser Quantum 127.0.0.1:18081
    ↓ FRP 客户端主动连接 VPS，TLS + 令牌
VPS FRP 127.0.0.1:18080
    ↓
1Panel OpenResty → https://drive.example.com
    ↓ WebDAV /dav/<source>/ + API 令牌
Rclone pccloud: → /mnt/pc-cloud（只读）
    ↓ Docker volume
Navidrome /music-pc → “电脑网盘音乐”
```

FRP 与 WebDAV 使用的是**两枚不同凭据**：FRP 连接令牌只负责电脑与服务器之间的隧道；FileBrowser API 令牌负责 WebDAV 鉴权。网页登录密码是第三种凭据，不要混用。

## 二、Windows 本机网盘先跑通

从 [官方发布页](https://github.com/gtsteffaniak/filebrowser/releases) 下载 Windows 稳定版，并核对该版本资产的 SHA256。软件放在 `D:\Software\PersonalCloud`，文件放在 `D:\网盘`，两者分开。

在软件目录保存 `config.yaml`，可参考 [Windows 配置示例](../examples/filebrowser.windows.yaml)：

```yaml
http:
  listen: "127.0.0.1"
  port: 18081
server:
  sources:
    - path: 'D:\网盘'
      config:
        defaultEnabled: true
auth:
  methods:
    password:
      enabled: true
      minLength: 12
      signup: false
```

然后在该目录的 PowerShell 执行：

```powershell
cd D:\Software\PersonalCloud
.\filebrowser.exe -c config.yaml
```

日志应显示来源为 `D:\网盘`，地址为 `http://127.0.0.1:18081/`。用首次启动生成的管理员密码登录，按提示立即修改；不要把初始密码贴到文章、截图或仓库。

本次遇到过两个实际错误：

- 在 `D:\网盘` 运行命令，却没有把程序放在那里，因此提示找不到 `filebrowser.exe`。
- 程序放对了，配置文件却在另一个目录。它退回默认设置，把软件目录当文件源，并监听所有接口。应先 Ctrl+C 停止，修正配置，再确认日志中的来源和监听地址。

`ffmpeg unavailable` 不影响基本文件上传下载，但部分视频预览等功能需要另外安装依赖。[Windows 官方说明](https://filebrowserquantum.com/en/docs/getting-started/windows/)

## 三、FRP 把电脑接到服务器

分别使用与系统架构匹配的官方 `frpc`（Windows）和 `frps`（VPS）版本。本次两端均为 v0.71.1，下载后按官方资产 SHA256 核验。

服务端配置见 [frps.example.toml](../examples/frps.example.toml)，客户端见 [frpc.windows.example.toml](../examples/frpc.windows.example.toml)。模板要点：

- VPS 的 TCP 7443 接收 FRP 客户端连接；根据服务器防火墙和服务商安全组按需放行这一个入口。
- 服务端代理绑定 `127.0.0.1`，只允许映射 18080，不把文件服务端口直接开放到公网。
- 客户端转发到电脑 `127.0.0.1:18081`，`loginFailExit=false` 允许初次连接失败后继续重试。
- FRP 令牌放进独立文件，不写在公开配置或命令历史中。
- 服务端强制 TLS；客户端设置匹配的 `serverName` 和可信 CA，不能仅开启加密却不验证对端身份。

本次复用 VPS 上已有的 `panel.example.com` 有效证书作为 FRP 的服务器证书。示例中的证书路径必须替换成自己真实且匹配域名的证书。不要把服务器私钥复制到 Windows。

客户端 `trusted-ca.pem` 应是能验证服务器证书链的可信根 CA 文件，例如从可信官方渠道取得的 CA bundle；不能留一个不存在的路径。服务端证书更新后需重新加载，下面的维护部分说明本次处理方式。

先在 Windows 验证配置：

```powershell
.\frpc.exe verify -c frpc.toml
.\frpc.exe -c frpc.toml
```

看到连接与代理启动成功后，在 VPS 检查：

```bash
curl -I http://127.0.0.1:18080/login
ss -ltn '( sport = :7443 or sport = :18080 )'
```

预期 18080 只监听回环地址，登录页返回 200。使用 systemd 管理 frps，设置网络就绪后启动、失败重试。本次服务名为 `personal-cloud-frps.service`。

[FRP 安装与启动](https://gofrp.org/en/docs/setup/)、[客户端配置](https://gofrp.org/en/docs/reference/client-configures/)、[服务端配置](https://gofrp.org/en/docs/reference/server-configures/)

## 四、1Panel 域名与 HTTPS

1. 在 DNS 服务商添加 `drive.example.com` 的 A 记录，指向 VPS 公网 IPv4。本次采用“仅 DNS”，不经过 Cloudflare 代理，以避免其代理上传限制影响网盘大文件。
2. 在 1Panel“网站 → 创建 → 反向代理”添加域名，代理目标为 `http://127.0.0.1:18080`。
3. 申请匹配的 HTTPS 证书，启用自动续签，保存 HTTP 自动跳转 HTTPS。
4. 用浏览器访问域名，确认有效证书，再用自己的账号登录测试小文件上传下载。

OpenResty 必须能访问服务器回环地址。若采用不同的 Docker 网络布局，先确认代理连通性，再设置合适的内部地址。

本次发现 OpenResty 全局请求体限制为 50m，因此在**网盘专用的代理 location** 内追加：

```nginx
client_max_body_size 0;
proxy_request_buffering off;
proxy_buffering off;
proxy_read_timeout 600s;
proxy_send_timeout 600s;
```

先备份原配置，再执行 Nginx 配置检查，通过后重载。不要为网盘随意改变其他站点的全局设置；以后通过面板重新生成代理配置时，要确认这些参数仍保留。取消请求体限制并不代表任意大文件、任意网络都已验证。

## 五、启用 WebDAV：密码必须用 API 令牌

在本次 v2.0.2-stable 的最小配置中，WebDAV 默认开启，无需额外启动 Rclone WebDAV 服务器。若之前明确禁用过，应按该版本 HTTP 配置恢复，并重启 FileBrowser。

FileBrowser 的 source 名称会出现在网页路径中。本次网页为 `/files/网盘/`，相应 WebDAV 地址为：

```text
https://drive.example.com/dav/%E7%BD%91%E7%9B%98/
```

不要把任意电脑路径直接写成 URL；名称以自己的 FileBrowser 文件源为准。

在“设置 → API 标记”创建专用令牌，例如 `navidrome-pc`。本次选 365 天，**不勾选“自定义令牌”**。完整令牌才是 WebDAV 的 Basic Auth 密码，不能使用网页登录密码；WebDAV 用户名在这个版本被忽略，Rclone 可填 `navidrome` 作为占位值。

默认 minimal 令牌继承创建者权限。本次由 admin 创建，因此它本身不是只读凭据；下游只读挂载不改变令牌的原有权限。若要进一步限制，应单独规划具有 View + Download 权限的专用账号，再用该账号创建令牌，不把 admin 凭据当作长期最小权限方案。

[WebDAV 官方说明](https://filebrowserquantum.com/en/docs/features/webdav/)

## 六、服务器 Rclone 新增电脑远程源

在 VPS 执行 `rclone config`，新建 `pccloud`：

| 选项 | 内容 |
| --- | --- |
| Storage | webdav |
| URL | 上面的完整 WebDAV 地址 |
| Vendor | other |
| User | navidrome（占位值） |
| Password | 完整 API 令牌，通过交互提示输入 |

确认连接：

```bash
rclone lsf pccloud: --max-depth 2
```

不要覆盖已经存在的 `cloud`。确认文件可读后，创建 `/mnt/pc-cloud` 与独立缓存 `/var/cache/rclone-pc`，使用 [电脑只读挂载服务](../examples/rclone-pc-music.service)。替换示例容器名后启用：

```bash
systemctl daemon-reload
systemctl enable --now rclone-pc-music.service
findmnt /mnt/pc-cloud
ls -la /mnt/pc-cloud
```

本次为新挂载设置 1G 缓存清理目标、保留空间目标 5G、目录缓存 1 分钟。缓存目标不是硬配额，还需考虑原 InfiniCloud 缓存和其他容器占用。

## 七、追加 Navidrome 映射与音乐库

先备份 Compose 和 Navidrome 数据。数据库备份在正常停止容器后进行，完成后恢复启动。只给原实例的 volumes **追加**一项：

```yaml
volumes:
  - ./data/data:/data
  - /mnt/cloud/Music:/music:ro
  - /mnt/pc-cloud:/music-pc:ro
```

保留原 `/data` 和 `/music`，通过该实例的 Compose 重建容器。普通 `docker restart` 不会增加新的 volume 映射。若在实际应用目录修改 Compose，先 `docker compose config --quiet` 检查，再按原项目执行 `docker compose up -d`；注意与 1Panel 后续重建保持一致。

检查容器读取，再在 Navidrome“设置 → 媒体库”创建 **电脑网盘音乐**，路径填 `/music-pc`。管理员能访问新库；普通用户需要单独授权。左上角的媒体库选择器也要勾选新库，否则已经扫描的专辑仍可能不显示。

本次扫描 18 个 M4A 与 1 个 FLAC，得到 19 首、2 张专辑。实际播放 M4A 来源歌曲时，Navidrome 服务端进行了 FLAC 转码，浏览器播放超过两分钟，未观察到媒体错误。

当前 `ND_SCANSCHEDULE=1h`。新增文件后，可以等每小时扫描，或手动对电脑音乐库扫描；目录缓存可能有约一分钟延迟。原文件标签会影响曲名、专辑与曲序，本次没有批量修改用户音乐标签。

## 八、日常维护

- **电脑需在线。** 关机、休眠、退出用户会话或隧道停止，都会使未缓存歌曲不可读。缓存不等于完整离线副本。
- **Windows 自动启动。** 本次为当前用户创建 `PersonalCloud-FileBrowser` 和 `PersonalCloud-Tunnel` 两个登录启动任务，以普通用户权限运行，失败后每分钟重试。并未验证开机尚未登录时可用，也没有把 Windows 密码写入任务。
- **首次手动运行的窗口。** 配置时原程序可能仍在 PowerShell 前台运行，不能直接以“任务存在”推断后台已接管。正常停止手动副本后再启动任务，避免端口冲突；整机重启另择维护时段验证。
- **重新挂载。** 电脑挂载服务在就绪后重启 Navidrome，解决容器仍绑定旧 FUSE 挂载的问题，因此会短暂中断两个音乐库的播放。
- **证书续签。** 本次配置 systemd path 单元观察 FRP 所用证书文件变化，再触发 frps 重启读取证书。续签后的实际恢复仍要检查；删除或换掉被复用的面板证书前先调整 FRP。
- **升级与备份。** 备份电脑文件、FileBrowser 配置及停止后的数据库、FRP 配置与令牌、服务器 Rclone 与 Navidrome 数据。凭据加密另存，不上传到 GitHub。

服务器常用检查：

```bash
systemctl status personal-cloud-frps rclone-pc-music --no-pager
journalctl -u rclone-pc-music -n 50 --no-pager
rclone lsf pccloud: --max-depth 1
docker exec YOUR_NAVIDROME_CONTAINER ls /music-pc
df -h /
du -sh /var/cache/rclone-pc
```

WebDAV 令牌更换见 [令牌期限与更换](token-renewal.md)。更多网盘的通用流程见 [多网盘扩展](multiple-clouds.md)。

> 本仓库的一键安装脚本仍面向新服务器上的 Rclone + Navidrome 独立部署，不会自动安装本篇的 Windows 网盘、FRP、DNS 或证书，也不会接管已有 1Panel 应用。

[返回主教程](../README.md)
