# iPhone 库存监控

macOS 菜单栏工具，查询 Apple 澳洲指定 iPhone 配置的门店自提库存；发现任一目标门店可自提时，显示 Mac 弹窗、播放提示音，并可通过 Bark 向 iPhone 推送通知。

> **当前源码基线：v1.5.1。Apple 库存接口会反复返回 HTTP 541，持续监控问题尚未解决。** 失败时库存显示“未知”，自动冷却重试。不能保证全天连续查询或第一时间发现补货。手机推送配置成功也不代表库存查询正常。详见 [已知限制与验证边界](docs/LIMITATIONS.md)。

## 默认监控对象

| 项目 | 配置 |
| --- | --- |
| 地区 | Apple Australia |
| 机型 / 颜色 / 容量 | iPhone Duo / Star White 白色 / 512GB |
| 商品编号 | `MK2F4X/A` |
| 邮编 | `2007` |
| 门店 | Broadway、Sydney、Bondi、Chatswood Chase、Miranda、Castle Towers、Penrith、Charlestown、Canberra，共 9 家 |

这是一份针对上述配置的专用工具，不是任意机型的通用库存查询器。商品链接、SKU、门店与接口来自 2026 年 10 月的项目配置，使用前请在 [Apple 购买页面](https://www.apple.com/au/shop/buy-iphone/iphone-duo/7.6-inch-display-512gb-star-white)重新核对；接口和商品可能发生变化。

## 从源码构建

需要 macOS 13 或更新版本，以及 Xcode Command Line Tools。当前构建在 Apple Silicon Mac 验证；未验证 Intel 实机兼容性。没有第三方 Swift 依赖。

首次安装开发工具：

```sh
xcode-select --install
```

在仓库根目录运行：

```sh
./scripts/build.sh
./scripts/test.sh
./开启持续监控.command
```

产物位于 `dist/iPhone库存监控.zip`，包含采用本机临时签名的 App，没有 Developer ID 签名或 Apple 公证。仓库不包含预编译程序。构建和签名在系统临时目录完成，再导出 ZIP，避免 iCloud / FileProvider 自动添加的 Finder 元数据破坏签名。`--self-test` 只运行离线合成测试，不查询 Apple、不发送手机通知；通过测试不等于真实服务稳定。

## 持续运行与停止

双击仓库根目录的 **开启持续监控.command**，或运行：

```sh
./开启持续监控.command
```

脚本会把构建产物复制到本机 Application Support，启动后台监控并配置当前用户登录后自动运行。更新源码后重新构建、再运行开启脚本。此安装方式会替换同一用户已安装的本工具，保留本地 Bark 配置和调度文件。

菜单栏的 **Duo → 查看监控状态** 可查看最近成功时间、下一次尝试、门店状态以及手机推送状态。关闭窗口后仍继续运行；“退出本次监控”仅退出当前进程。

停止并停用登录自启：

```sh
./停止持续监控.command
```

Mac 必须开机、用户已登录并保持联网。运行期间程序阻止空闲自动睡眠；关机、手动睡眠、合盖休眠、断网或退出登录期间无法查询。

## 配置 iPhone 手机提醒

1. iPhone 安装 [Bark](https://apps.apple.com/au/app/bark-custom-notifications/id1403753865)，允许通知和声音。
2. 在 Bark 首页复制自己的真实推送地址，形如 `https://api.day.app/YOUR_DEVICE_KEY/`。这是格式示例，不能直接使用。
3. Mac 菜单栏 **Duo → iPhone 推送设置**，粘贴地址。
4. 如需静音时响铃，勾选“强提醒”，并在 iPhone 为 Bark 开启“重要警告”权限。
5. 点击 **保存并发送测试**，锁屏后检查 iPhone 是否实际收到测试消息、是否有声音。

完整步骤、权限设置和延迟排查见 **[Bark 手机提醒配置指南](docs/BARK.md)**。程序当前只支持 Bark 公共服务 `api.day.app`，不支持自建服务器地址。

## 提醒规则与查询频率

- 任一目标门店首次观察到可自提时提醒；同一进程内持续有货不重复提醒，观察到无货后再次有货会重新提醒。重启后已有库存可能再次提醒。
- 查询错误不视为无货，不触发补货提醒，也不重置已观察到的提醒状态。其他颜色、容量及配送日期不触发提醒。不自动下单。
- 正常成功后约 150 秒再查询；每滚动小时最多 24 次，定时、手动、唤醒和重启共用持久化预算。
- HTTP 403 / 429 / 541 至少冷却 15 分钟；如服务返回更晚的 `Retry-After`，按更晚时间等待。冷却不保证恢复，受限期间存在监控盲区。
- 菜单中的测试提醒明确标注“不是补货”，不修改真实库存状态。

## 本地数据与隐私

运行文件位于 `~/Library/Application Support/iPhoneDuoStockMonitor/`：

| 文件 | 用途 |
| --- | --- |
| `iphone-push.json` | Bark 设备密钥和强提醒选项；保存时设置权限 `0600` |
| `status.json` | 上次查询状态和门店结果 |
| `query-schedule.json` | 请求记录、冷却和预算，跨重启保留 |
| `monitor.log` / `monitor.previous.log` | 有大小上限的运行日志 |
| `monitor.lock` | 单进程锁 |

登录自启位于 `~/Library/LaunchAgents/com.local.iphoneduostock.plist`。密钥不硬编码到源码，也不写入应用日志；不要将本地配置、真实推送地址、日志或截图提交到 GitHub。推送使用 HTTPS POST，设备密钥放在请求体中；通知正文会经 Bark 服务及 Apple 推送链路传递。当前没有使用 Bark 的端到端内容加密功能。

## 源码结构

```text
Sources/
  StockCore.swift      # 精确 SKU、九店响应校验、查询和库存变化判断
  QuerySchedule.swift  # 持久化查询间隔、请求预算和错误冷却
  BarkPush.swift       # 本地配置、Bark POST 推送和有限重试
  main.swift           # AppKit 菜单栏、窗口、提示音及监控生命周期
Resources/Info.plist
scripts/build.sh       # 从稳定源码快照构建并打包本机 App
scripts/test.sh        # 运行现有离线回归测试
```

更换机型或地区需要同步修改源码中的 SKU、购买链接、查询邮编、目标门店以及界面文案，并重新核对接口响应；目前没有图形化配置这些字段的功能。

## 故障排查

- **HTTP 541 / 当前库存未知**：查看 [已知限制](docs/LIMITATIONS.md)，等待自动重试；不能把未知当成无货，也不能通过重启刷新冷却预算。
- **Bark 已接受，但手机没收到或无声音**：按 [手机提醒指南](docs/BARK.md)检查实际历史消息、通知权限、专注模式和递送设置。服务接受不是手机送达回执。
- **调度状态无法读取**：先停止监控，备份本地文件并检查文件权限和 JSON 内容；不要通过删除调度文件绕过服务限制。
- **重新打开窗口显示旧结果**：以最近成功时间和错误状态为准；新查询失败时当前库存未知。

本项目与 Apple、Bark 无隶属关系。仓库保存可构建源码和已知问题说明；上传 GitHub 本身不代表长期稳定性问题已修复。
