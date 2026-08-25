# Chrome Xiufu

`chrome-xiufu` 是面向 Windows 的 Codex Desktop Chrome 控制链路修复技能，适用于 Codex 能连接 Chrome，但导航、DOM 快照、截图、滚动或历史前进/回退不稳定的情况。

## 技能作用

- 在写入前完整检查 Chrome 和 Browser 两套插件目录。
- 从 `latest/.codex-plugin/plugin.json` 动态读取当前插件版本，不绑定版本号。
- 检查缓存、marketplace、Browser 服务、原生主机、扩展和运行时可信服务配置。
- 只在检测到精确已知破损模式时应用对应补丁。
- 覆盖 ARIA 快照回退、site-status 超时、缓存 CDP 表达式、focus/OOPIF 等待、导航超时、鼠标滚轮滚动、历史导航和只读响应元数据延迟。
- 每次写入后回读验证，并对所有目标文件执行 `node --check`。
- 必须完成真实 Chrome 冒烟/ACK 后才能报告完全恢复。

## 安全边界

这是一个仅修改代码的修复流程，不会安装、添加、同步、替换、降级或固定插件版本，也不会修改 Chrome profile、Cookie、密码、用户数据或 `C:\Program Files\WindowsApps`。

如果当前 manifest 缺失、格式错误，或候选副本版本不一致，版本门禁会停止并且不写入。如果运行时可信服务配置缺失或过期，技能会报告“运行时路径未知”，只使用明确通过版本门禁的候选副本，不会根据目录时间猜测路径。

## 使用方式

在 PowerShell 中运行默认的“检查后修复”流程：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1"
```

只检查不修改：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\chrome-xiufu\scripts\repair-chrome-xiufu.ps1" -VerifyOnly
```

只有需要逐文件排查失败原因时才使用 `-Detailed`。默认输出会主动隐藏缓存路径、哈希、重复副本和备份路径等无用噪音。

## 强制流程

1. 检查环境、插件 manifest、扩展、原生主机、所有版本匹配的缓存/marketplace 副本，以及运行时可信服务配置。
2. 将问题分类为能力失败、成功但较慢、首次连接冷启动，或目标网站瞬态问题。
3. 只有在现有模式无法解释、问题间歇性出现、上游代码结构变化，或可能存在更稳定的官方机制时，才调研 OpenAI/Codex 官方文档和公开 GitHub 页面。
4. 完成完整诊断和版本门禁后，只应用精确匹配的补丁。
5. 任何文件写入后都要重置 Node 运行时或 extension-host。
6. 按独立操作执行真实 Chrome 冒烟/全量 ACK，记录耗时、证据和修复前后对比。

## ACK 门禁

报告状态必须按以下顺序推进：

`PATCH_READY -> RECONNECT_REQUIRED -> ACK_REQUIRED -> ACK_PASSED`

静态检查不是实时 ACK。只有导航、页面读取、DOM 快照、截图、滚动、交互，以及重复的历史回退/前进检查全部成功并且页面证据正确，才能进入 `ACK_PASSED`。缺少实时证据时必须停留在 `ACK_REQUIRED`，不能伪造结果。

## 包含内容

- `SKILL.md`：完整的操作流程和诊断规则。
- `scripts/repair-chrome-xiufu.ps1`：检查、补丁、版本门禁和语法验证脚本。
- `agents/openai.yaml`：Codex 技能元数据。
- `README.md`：英文说明。
- `README.zh-CN.md`：中文说明。

## 已验证基线

历史导航补丁在 Selenium 测试页上已将 `goBack` 和 `goForward` 从每次约十秒降低到 100 ms 以内。其他补丁没有通用的修复前耗时数据，报告必须写明“修复前无数据”，不能估算。

## 回滚

实际修复时，脚本会在每个被修改文件旁创建带时间戳的备份。回滚时将对应备份恢复到原路径，然后重启 Codex/extension-host 并重新执行冒烟测试。备份属于运行时操作产物，不会发布到 GitHub 技能包中。

