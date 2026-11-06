# iPhone 手机提醒：Bark 配置指南

Mac 负责查询库存，Bark 负责把提醒发送到 iPhone。iPhone 可以离开 Mac、通过互联网接收通知；Mac 仍须保持运行和联网。

## 1. 在 iPhone 准备 Bark

1. 安装 [Bark – Custom Notifications](https://apps.apple.com/au/app/bark-custom-notifications/id1403753865)，打开应用并允许通知。
2. 在 Bark 首页复制你自己的推送地址。格式示例：`https://api.day.app/YOUR_DEVICE_KEY/`，其中 `YOUR_DEVICE_KEY` 必须换成 App 给出的真实设备密钥。
3. 示例中的 `YOUR_KEY` 占位符无法使用。不要在 GitHub、Issue、截图或 README 中公开真实地址；持有它的人可以向你的手机发送推送。

## 2. 在 Mac 连接手机

1. 运行库存监控，点击 **Duo → iPhone 推送设置**（状态窗口也有“iPhone 推送”按钮）。
2. 粘贴真实地址，也可粘贴 Bark 复制出的 `curl` 示例；程序仅解析地址，不执行命令。
3. 选择是否开启“强提醒”。
4. 点击 **保存并发送测试**。
5. 在 iPhone 确认收到“iPhone 库存提醒测试（不是补货）”，并检查声音及实际延迟。测试不会修改真实库存。

**“Bark 已接受”只表示服务器接受请求，不表示手机已收到，也不表示当前库存查询成功。** 只有手机上的实际通知才能确认送达。

## 3. 开启声音和强提醒

在 iPhone 的 **设置 → 通知 → Bark**（具体入口名称可能随 iOS 版本变化）中：

- 开启“允许通知”、锁定屏幕、横幅和“声音”。
- 如存在“时效性通知”选项，允许它；如启用了定时摘要，将 Bark 改为立即递送或移出摘要。
- 使用 Mac 上“强提醒”时，需授权 Bark 的 **重要警告 / Critical Alerts**。若找不到，先打开 Bark，检查其设置里的重要警告授权入口、完成系统授权，再回到 iOS 通知设置检查。

强提醒参数是 `level=critical`、`call=1`、`volume=8`、`sound=alarm`：在获得重要警告权限时可在静音下响铃，目标是约 30 秒循环铃声，音量 8/10。未获得权限时会降级；实际声音和专注模式下行为应以锁屏测试确认。开启后可能在夜间响铃。

取消 Mac 的“强提醒”勾选并保存，可恢复普通时效性通知；普通提醒的声音受 iPhone 系统设置控制。

参数含义参考 [Bark 官方参数文档](https://github.com/Finb/Bark/blob/master/docs/en-us/params.md)，重要警告仍需手机端授权。

## 4. 没收到、没声音或有延迟

| 现象 | 检查方法 |
| --- | --- |
| Mac 显示推送失败 | 确认地址来自当前手机，Mac 可联网；网络或服务器故障最多尝试 3 次，两次重试分别等待 5 秒、15 秒 |
| 服务器接受，手机无消息 | 打开 Bark 历史消息，确认手机联网、通知权限和该消息组是否被静音；历史是否保存也受 Bark 设置影响 |
| 历史里有消息，但无声音 | 检查声音、专注模式、定时摘要；强提醒还需重要警告权限；锁屏后重新发送明确的测试消息 |
| 手机收到较晚 | 分开核对库存检测时间、Bark 接受时间和手机到达时间；当前没有手机送达回执，不能承诺零延迟 |
| 无任何真实补货提醒 | 查看库存窗口最近成功时间；HTTP 541 时查询中断，即便推送链路正常也无法发现新库存 |

正常库存检测间隔约 150 秒，此外还有网络和推送耗时。HTTP 541 冷却期间可能漏过短暂补货，强提醒不会修复库存查询故障。

## 5. 换手机或停用

换手机后重新复制新手机 Bark 地址，覆盖 Mac 设置并发送测试。点击 **停用 iPhone 推送** 会删除本工具保存的设备配置；Mac 库存查询仍继续。

设备密钥保存在 `~/Library/Application Support/iPhoneDuoStockMonitor/iphone-push.json`，权限 `0600`；不应复制到项目目录或提交到 Git。当前客户端仅支持 `https://api.day.app/`，不支持自建 Bark 服务地址。

开发资料：[Bark 项目](https://github.com/Finb/Bark)、[参数文档](https://github.com/Finb/Bark/blob/master/docs/en-us/params.md)。
