# 一键脚本：使用说明与边界

脚本用于在 **Debian/Ubuntu + systemd + 已运行的 Docker / Compose v2** 服务器上新建一套独立音乐服务。可从 1Panel 终端运行，创建的容器会出现在面板容器列表，**不会登记成应用商店应用**。

现有教程中的 1Panel Navidrome 已经正常运行，不需要再安装。脚本检测到现有 Navidrome、同名服务、容器或自己的安装目录时会停止，不自动迁移、接管或清理它们。

## 下载并运行

```bash
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/SamueruTokeisou/1panel-rclone-navidrome-guide/main/install.sh \
  -o install.sh
# 建议先查看文件；使用固定 commit 地址可锁定版本
bash install.sh help
sudo bash install.sh install
```

请先下载到文件，再运行，不使用 `curl | bash`，也不要开启 `bash -x`。密码在交互终端隐藏输入，不接受命令行密码参数。

脚本会确认端口、新网盘名称、远程目录、缓存目标和连接方式，展示安装影响后要求输入 `yes`。首次依赖安装可能需要等待。

WebDAV 模式支持 InfiniCloud 及兼容 `vendor=other` 的 HTTPS WebDAV 服务；请填写服务商给出的 URL、Connection ID 和 Apps Password。远程目录须已存在，脚本不会创建、删除或上传网盘文件。其他 backend 可先用 root 的 `rclone config` 完成授权，再选择“复用已有 remote”。第一版不支持交互解密的 Rclone 配置，也不自动处理 OAuth 浏览器授权。

## 默认行为

- 安装缺少的 Rclone 与 FUSE 依赖；Docker/Compose 必须已有，不自动安装或重启 Docker。
- 独立文件位于 `/opt/nd-music`，数据目录是 `/opt/nd-music/data`。
- 容器名称 `nd-music`，镜像固定 `deluan/navidrome:0.64.2`。
- 默认 `127.0.0.1:40108`，不开放防火墙，不修改现有网站。
- 网盘只读；每个挂载独立缓存，默认清理目标 1G，保留空间目标 5G。两者都不是硬配额，仍须监控磁盘。
- 每小时扫描；UID/GID 1000:1000；数据库保留在本地。
- 容器前台运行由 `nd-music.service` 管理，Compose 的 restart 设置为 `no`，避免 Docker 在网盘就绪前自行启动扫描。
- 应用服务依赖所有挂载；挂载服务失效时应用停止，挂载恢复时通过 systemd 重新拉起应用。真实断网、FUSE 故障与整机重启恢复仍需在目标环境验证。

脚本专用目录设置为 root 可访问。WebDAV 凭据只保存于 root 配置文件，Rclone 的密码混淆不等于加密。不要上传 `/opt/nd-music/remotes` 或 root 的 Rclone 配置。

## 域名与管理员

安装完成会给出本地代理地址。进入 1Panel“网站 → 创建 → 反向代理”，配置自己的域名，代理目标填 `http://127.0.0.1:40108`（自定义过端口则相应调整），再申请和启用 HTTPS。

此方式要求 OpenResty 能访问宿主机回环地址，常见 1Panel 默认部署可用；其他网络布局须调整代理目标，不要直接开放未初始化服务来绕过网络问题。

浏览器确认 HTTPS 正常后，立即亲自创建管理员。脚本不会替你生成 Navidrome 管理员密码，也不会配置 DNS、证书或公开访问。

## 添加网盘

```bash
sudo bash install.sh add-cloud
```

仅适用于本脚本管理的实例。它会先保留配置快照，再追加挂载和 Compose 映射，重建容器，保留 `/data` 与原有音乐映射。此操作短暂中断播放。

第一块网盘在容器里是 `/music`，之后的路径是 `/music-挂载名称`。例如挂载名填 `second`，就在 Navidrome“Settings → Libraries”添加 `/music-second`，并按需给普通用户授权。

已有的 1Panel 应用商店实例，请使用 [手动扩展步骤](multiple-clouds.md)，不要运行安装来覆盖。

## 检查与恢复

```bash
sudo bash install.sh status
sudo bash install.sh start
```

`status` 只读检查，也会显示非脚本管理的 Navidrome 容器。`start` 会按保存配置重新生成服务与 Compose 并启动；会拉取固定版本镜像、短暂中断播放，不是只读命令。

如果新网盘已写入配置但启动失败，先排查挂载日志、账号权限和网络，再执行 `start`。如果在登记前失败，只留下未登记的凭据文件，脚本会拒绝覆盖同名文件；核对后换一个挂载名称重试，旧文件由管理员自行处理。

```bash
journalctl -u nd-music.service -n 80 --no-pager
journalctl -u nd-music-cloud.service -n 80 --no-pager
findmnt /mnt/nd-music/cloud
df -h /
```

配置快照存于 `/opt/nd-music/backups`，不包含数据库、所有凭据或音乐，不能代替完整备份。升级或迁移前另行备份数据并验证恢复。

## 测试范围

仓库工作流执行 Bash 语法检查、ShellCheck 和不触碰真实系统的离线行为测试，覆盖输入验证、systemd 转义、已有实例保护和多网盘配置生成。

这些测试不等于新服务器部署实测。安装依赖、真实 WebDAV 授权、FUSE 挂载、Docker 播放、断网和整机重启，需要在目标服务器继续验证。脚本尚未在原服务器执行，以保护已有运行环境。
