# WebDAV 令牌的期限与更换

适用本次 FileBrowser Quantum v2.0.2-stable + Rclone `pccloud` + Navidrome 组合。

## 能否永不过期

这个版本的创建界面只有“天”和“月”，时长输入最小值为 1，没有“永不过期”选项。365 天是本次主动选择的时长，不代表软件只允许一年；也不要把 0 或负数擅自当作永久令牌。

这是对当前版本界面的确认，不声称所有未来版本或其他实现都不支持永久凭据。[对应版本的创建界面源码](https://github.com/gtsteffaniak/filebrowser/blob/v2.0.2-stable/frontend/src/components/prompts/CreateApi.vue)

Rclone 保存的是静态 WebDAV API 令牌，不会像某些 OAuth remote 一样自动刷新它。接近到期时需要更换。到期会影响电脑 WebDAV 音乐源，不会删除电脑上的音乐或 Navidrome 数据。

## 更换步骤

1. 登录 FileBrowser，进入“设置 → API 标记”，创建新令牌，例如 `navidrome-pc-next`，设置合适时长。
2. **不要勾选“自定义令牌”**；复制完整 minimal 令牌，不要复制网页登录密码。
3. 在 VPS 的 root 终端更新 `pccloud` 的密码。下面的隐藏输入方式避免把令牌直接写进命令历史：

```bash
# 备份包含凭据，应留在服务器 root 私有目录，不能上传 GitHub
umask 077
cp -p /root/.config/rclone/rclone.conf "/root/.config/rclone/rclone.conf.before-token-$(date +%Y%m%d-%H%M%S)"
read -r -s -p '粘贴新令牌后按回车: ' DAV_TOKEN; echo
rclone config update pccloud pass "$DAV_TOKEN" --obscure >/dev/null
unset DAV_TOKEN
chmod 600 /root/.config/rclone/rclone.conf

# 先验证新凭据能列目录，再在没有播放任务时重新挂载
rclone lsf pccloud: --max-depth 1
# 上面的命令成功后，才执行下面的重启
systemctl restart rclone-pc-music.service
systemctl is-active rclone-pc-music.service
docker exec YOUR_NAVIDROME_CONTAINER ls /music-pc
```

替换 `YOUR_NAVIDROME_CONTAINER` 为实际容器名。挂载服务包含容器重启步骤，会短暂中断音乐播放。示例以默认 root Rclone 配置路径为准；使用不同配置文件时，为 Rclone 命令指定正确的 `--config`。

4. 打开 Navidrome，播放一首电脑音乐，确认通过新连接读取成功后，再撤销旧令牌。
5. 记录新到期日。路径、音乐库和数据目录不变时，不需要重新安装，也通常不需要重新扫描整个库。

## 不能忽略的权限区别

默认 API 令牌跟随创建者权限。用 admin 创建的令牌本身并不是只读凭据；`rclone mount --read-only` 和 Docker `:ro` 只限制当前挂载使用方式，不能限制拿到令牌的人另行调用 API。

如需更严格的长期权限，应配置专用账号及文件源的 View + Download 权限，再用该账号创建最小形式令牌。不要仅在名称中写“只读”就认为权限已经限制。[WebDAV 权限与令牌说明](https://filebrowserquantum.com/en/docs/features/webdav/)

忘记日期、令牌被提前撤销或遇到 401 时，先检查 FileBrowser API 标记列表与服务日志，再按上述步骤换新令牌，不要删除数据库重装。

[返回 Windows 网盘实战](windows-cloud.md)
