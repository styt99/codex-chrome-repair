# Codex Chrome Repair

这个插件以通用英文发布名 `Codex Chrome Repair` 为 Windows 下的 Codex Desktop 打包 `chrome-xiufu` 技能。

请阅读[英文说明](README.md)或[完整技能说明](skills/chrome-xiufu/SKILL.md)。技能会完整定位 Chrome/Browser 控制链路，只应用精确的已知兼容补丁，动态跟随官方插件版本，并且必须完成真实 Chrome ACK 才能报告恢复完成。

`.codex-plugin/plugin.json` 中的版本是这个公开技能包自身的版本，与官方 `chrome@openai-bundled` 运行时版本相互独立，不会锁定官方插件版本。

## 已验证的修复前后数据

以下数据来自 Selenium 测试页上的真实 Chrome ACK。只有历史导航有修复前的实测基线，其余项目明确写为“修复前无数据”，不做估算。

| 操作 | 修复前 | 修复后 | 状态 | 数据来源 |
| --- | ---: | ---: | --- | --- |
| 冷启动导航 | 修复前无数据 | 6,284 ms | 通过 | Chrome ACK 复核 |
| 热导航 | 修复前无数据 | 6,536 ms | 通过 | Chrome ACK 复核 |
| URL / 标题 | 修复前无数据 | 3 / 3 ms | 通过 | Chrome ACK 复核 |
| 页面评估 | 修复前无数据 | 36 ms | 通过 | Chrome ACK 复核 |
| DOM 快照 | 修复前无数据 | 109 ms | 通过 | Chrome ACK 复核 |
| 截图 | 修复前无数据 | 97 ms，65,970 bytes | 通过 | Chrome ACK 复核 |
| 滚动 | 修复前无数据 | 17 ms | 通过 | Chrome ACK 复核 |
| 填充 / 按键 / 点击 | 修复前无数据 | 52 / 28 / 428 ms | 通过 | 表单 ACK 复核 |
| 提交页 DOM | 修复前无数据 | 37 ms | 通过 | 表单 ACK 复核 |
| `goBack` | 平均 10,048.7 ms | 38–59 ms，3/3 | 通过，约降低 99.5% | 历史基线 + ACK 复核 |
| `goForward` | 平均 10,048.4 ms | 37–44 ms，3/3 | 通过，约降低 99.6% | 历史基线 + ACK 复核 |

冷启动和热导航因为连接和页面挂载发生在导航过程中，仍可能需要数秒，
但这是“成功但较慢”，不是插件故障。历史操作是本次已测量的延迟修复，
每次都到达了正确 URL。

