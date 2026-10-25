# 添加第二个及更多网盘

这部分是未来扩展方案，依据上游文档整理，尚未在本次服务器上接入第二个真实网盘。操作前先备份已有 Navidrome 数据与应用配置。

建议每个网盘独立挂载，再分别加入 Navidrome 音乐库。现有 `cloud:Music → /mnt/cloud/Music → /music` 保持不变。

## 1. 先确定新网盘怎么连接

| 网盘或存储 | Rclone 连接方式 | 需要准备 |
| --- | --- | --- |
| 提供 WebDAV 的网盘、Nextcloud 等 | `webdav`，vendor 按实际服务选择 | URL、账号、应用密码 |
| Microsoft OneDrive | `onedrive` | 按交互流程完成 OAuth 授权 |
| Google Drive | `drive` | 按交互流程完成 OAuth 授权 |
| S3 兼容对象存储 | `s3` | 服务商、endpoint、bucket 与相应访问凭据 |
| 其他网盘 | 查 Rclone 是否有对应 backend | 以该 backend 官方文档为准 |

不是所有网盘都可以直接填 WebDAV URL。没有原生支持时，第三方中转是否可用、能否读取大文件、是否支持跳转与随机读取，需要另外评估；本教程不保证兼容。先查 [Rclone 支持列表](https://rclone.org/overview/)，再看对应服务说明，如 [OneDrive](https://rclone.org/onedrive/)、[Google Drive](https://rclone.org/drive/)。

## 2. 新建 remote，先验证直连

```bash
rclone config
```

新建名称为 `cloud2` 的 remote，选择实际 backend，完成配置。无浏览器服务器上的 OAuth 按该 backend 的无界面授权流程操作，不要把 token 放进聊天或 GitHub。

```bash
rclone listremotes
rclone lsf cloud2: --dirs-only --max-depth 1
rclone lsf cloud2:Music --max-depth 1
```

示例假设新网盘已有 `Music`。如果实际叫 `音乐` 或位于 `Media/Music`，后面的远程路径也要随之修改。

不要覆盖旧的 `cloud`，不要在连通性未确认前改原有音乐库。

## 3. 独立挂载第二个网盘

```bash
install -d /mnt/cloud2/Music /var/cache/rclone-cloud2
nano /etc/systemd/system/rclone-cloud2.service
```

```ini
[Unit]
Description=Second cloud music read-only mount
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount cloud2:Music /mnt/cloud2/Music --config=/root/.config/rclone/rclone.conf --read-only --allow-other --uid=1000 --gid=1000 --umask=022 --vfs-cache-mode=full --cache-dir=/var/cache/rclone-cloud2 --vfs-cache-max-size=1G --vfs-cache-max-age=24h --vfs-cache-min-free-space=5G --buffer-size=8M --dir-cache-time=5m --poll-interval=0 --log-level=INFO
ExecStop=/usr/bin/fusermount3 -u /mnt/cloud2/Music
Restart=on-failure
RestartSec=10
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
```

这里先用 1G 缓存清理目标作为保守示例，实际根据剩余空间调整。第一个网盘 3G、第二个 1G 会共享同一块系统盘，多个 `min-free-space` 参数不会各自预留独立空间。文件使用中或清理间隔内可能超过目标。不要把每个新网盘都默认设为很大的缓存。

```bash
systemctl daemon-reload
systemctl enable --now rclone-cloud2.service
systemctl is-active rclone-cloud2.service
findmnt /mnt/cloud2/Music
ls -la /mnt/cloud2/Music
```

先确认挂载正常，再修改 Navidrome。

## 4. 在现有应用里追加 Docker 映射

打开 1Panel 已安装的 Navidrome 应用，在该实例的 Compose 配置中，只追加第二个音乐目录；保留全部其他配置，尤其是原来的 `/data`：

```yaml
volumes:
  - ./data/data:/data
  - /mnt/cloud/Music:/music:ro
  - /mnt/cloud2/Music:/music2:ro
```

通过该实例的配置更新功能重建容器，使新映射生效。**仅执行 `docker restart` 不会为容器增加 volume 映射。** 不要卸载应用或删除数据目录来达到重建目的。

若面板版本没有提供现有应用的 Compose 编辑入口，可在服务器应用目录中审慎修改实际 `docker-compose.yml`，但要与面板管理保持一致，避免面板后续操作覆盖。具体入口与应用路径以自己的实例为准。

```bash
docker exec YOUR_NAVIDROME_CONTAINER sh -c 'ls -ld /music /music2; test -r /music2 && echo SECOND_CLOUD_READABLE'
```

不要把 WebDAV URL 填成 Navidrome 音乐库路径；Navidrome 需要容器内可见的文件系统路径。[官方 Docker 多音乐库示例](https://www.navidrome.org/docs/usage/features/multi-library/#docker)

## 5. 添加音乐库

以管理员登录 Navidrome：

1. 进入 **Settings → Libraries**。
2. 添加一个音乐库，名称可以写“第二网盘”。
3. Path 填 **`/music2`**，保存后检查初次扫描。
4. 在 **Settings → Users** 中为普通用户分配此音乐库的访问权限。
5. 上传一首测试曲目，验证扫描、播放、进度拖动和封面。

保留现有默认音乐库 `/music`。不要把第二个库再指到第一个库的子目录，以免路径重叠和重复扫描。支持多音乐库的客户端可以选择可访问的音乐库，实际界面以客户端为准。[Navidrome 多音乐库与权限说明](https://www.navidrome.org/docs/usage/features/multi-library/)

## 6. 补上第二个挂载的恢复处理

第二个挂载重建后，也可能需要重启 Navidrome 才能重新读取。容器已存在时，可以给第二个服务加入与主教程相同的附加配置：

```bash
install -d /etc/systemd/system/rclone-cloud2.service.d
nano /etc/systemd/system/rclone-cloud2.service.d/navidrome.conf
```

```ini
[Unit]
After=docker.service

[Service]
ExecStartPost=-/usr/bin/docker restart YOUR_NAVIDROME_CONTAINER
```

替换容器名后执行 `systemctl daemon-reload`。在维护时间重启第二个挂载，再核对容器里的 **两个目录** 和 HTTP 服务。

多挂载同时恢复时，可能触发多次容器重启。这是少量网盘的简易恢复办法，不保证所有网盘在同一时刻就绪；某个网盘断开时，也不要自动把空目录当正常音乐库继续扫描。网盘较多或需要严格启动顺序时，应另做集中就绪检查和容器启动编排。

## 想在同一个音乐库中看到多个网盘怎么办

还可以规划 Rclone combine/union，或者把多个挂载映射到单个音乐库的不同子目录。这会改变路径布局，并涉及同名文件、重复曲目和故障传播。已有库中的路径改变还可能影响扫描匹配与记录。

对当前环境，优先采用“独立挂载 + 多音乐库”，等实际使用一段时间再决定是否需要合并。Rclone union 是另一种可选方案，并非添加第二个网盘的必需步骤。[Union 官方说明](https://rclone.org/union/)

[返回完整安装文章](../README.md)

