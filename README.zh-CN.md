# goodtouchbar

**版本 0.3.1 · build 4 · 实验预览版**

goodtouchbar 是面向 Intel 与 Apple 芯片 Mac 的实验性 macOS 工具，将 AI 活动、部分系统指标和常用控制放入可配置的菜单与受支持硬件上的 Touch Bar。Touch Bar 是否存在取决于具体机型，不能只根据 Intel 或 Apple 芯片架构判断。源码在公开仓库维护，预览安装包通过 GitHub Releases 分发。

[GitHub 仓库](https://github.com/yihuirui/goodtouchbar) · [Release 页面](https://github.com/yihuirui/goodtouchbar/releases) · [English](README.md) · [硬件兼容性](docs/COMPATIBILITY.md) · [构建与 CI](docs/BUILDING.md) · [安装与卸载](docs/INSTALLATION.md) · [隐私说明](docs/PRIVACY.md) · [预设说明](docs/PRESETS.md) · [设计参考](docs/PROJECT-INFLUENCES.md)

## 功能

- **状态详情：**左键点击主状态项，查看清晰分组的额度、今日 Token、AI 状态和系统概览；健康额度使用中性文字，低额度保留明确警告；WorkBuddy 操作按当前监控状态突出可用操作；底部工具栏保持可见，正文可滚动；右键或面板中的“更多”打开完整操作菜单。重试和硬件操作沿用既有确认与机型能力检查。

- **系统控制：**轻点 Touch Bar 项目打开原生控制面板；长按可直接切换静音。面板提供主输出音量滑块、静音、播放/暂停和正在运行的应用列表。播放/暂停发送 macOS 系统定义的媒体事件。点击该按钮需要“辅助功能”权限；macOS 会请求授权，未授权时面板提供打开辅助功能设置的入口。播放器可能不响应该事件，且尚未在实体目标 Mac 上验收播放控制效果。
- **AI 活动：**显示从本地近期 rollout 记录读取的 Codex 额度、通过 OpenToken 获取的可选 Token 总量、从近期本地会话事件估算的 AI 输出速度，以及 WorkBuddy 活动状态。Codex rollout 更新可能延迟，因此额度数据可能过时。
- **可选 WorkBuddy 监控：**可以绑定一个明确的国际版 WorkBuddy 聊天，并在识别到可重试错误时发起重试。重试会通过 WorkBuddy 客户端发送操作，可能产生服务用量。建立本机调试通道时，监控可能重新启动 WorkBuddy。
- **Touch Bar 模式：**可选 **Auto**、**On**、**Off**。没有已保存设置时默认 Auto：仅在识别到受支持机型时启用 Touch Bar，已知不支持或未知机型使用仅菜单模式。On 不能在没有 Touch Bar 的设备上生成硬件；Off 使用仅菜单模式。更改后需重启应用生效。新偏好键 `touchBarMode` 优先；旧版 0.1 的 `touchBarEnabled=true` 映射为 On，`false` 映射为 Off。
- **系统状态：**显示 CPU、内存、压力和可读取的温度。Apple 芯片上的 CPU 温度来自系统 thermal zone 读数，不是物理 CPU 核心温度；部分设备可能没有可用读数。
- **风扇控制：**可选的特权辅助服务为实验性功能，仅在 goodtouchbar 确认以原生 Intel 架构运行时可用。真实目标设备上的风扇写入尚未验证。Apple 芯片仅在可用时读取风扇状态；arm64 包不包含或安装风扇辅助服务。
- **AI 与 System 布局：**内置预设使用 `goodtouchbar-layout` schema v2，分别保存 Touch Bar 和菜单布局。仍支持导入 v1 仅含栏布局的预设，并将布局迁移到两处。预设不能执行脚本、启动自动重试或更改风扇设置。
- **仅菜单模式：**保留菜单栏应用、受支持的 AI 集成和系统监控；默认不启动或显示番茄钟。

全局 Touch Bar 呈现和硬件传感器使用 macOS 私有接口，行为可能随 macOS 版本及设备变化。本项目不是稳定、功能齐全的 BetterTouchTool（BTT）替代品。我们研究过 HapticKey 的思路，但**没有集成**其触觉 API；goodtouchbar 不承诺 Touch Bar 或触控板触觉反馈。

### 布局文字示意

以下只是可能出现的项目类型，**不是截图，也不保证实际顺序或实时数值**：

```text
[AI 额度] [Token 用量] [WorkBuddy 状态] [CPU / 内存] [温度] [系统控制]
```

## 系统要求

- 采用 Intel `x86_64` 或 Apple 芯片 `arm64` 的 Mac。
- macOS 13 或更高版本。
- Touch Bar 呈现需要被识别且受支持的 Mac 机型。部分 Apple 芯片机型确实带 Touch Bar：Apple 规格列出 [13 英寸 M1 MacBook Pro（2020）](https://support.apple.com/en-us/111893) 和 [13 英寸 M2 MacBook Pro（2022）](https://support.apple.com/en-us/111869)。这不等于所有 Apple 芯片机型均受支持或已完成真机验证。详见[硬件兼容性](docs/COMPATIBILITY.md)。
- 本地构建需要 Xcode Command Line Tools 和 Swift 5.9 或更新工具链。
- 基础应用不需要 Node.js。WorkBuddy 后台监控和 `scripts/test-public.sh` 中的 JavaScript 检查需要 Node.js 22+；OpenToken 本身可选，用于 Token 总量显示，其安装也可能要求 Node.js。

## 从源码构建

在 macOS 的仓库根目录运行：

```sh
TEST_ARCH=arm64 /bin/zsh scripts/test-public.sh
/bin/zsh build-app.sh --arch arm64 --no-open
```

Intel 构建请使用 `TEST_ARCH=x86_64` 和 `--arch x86_64`。本机原生构建请选择与 Mac 匹配的架构。未显式指定时测试与构建采用本机架构；CI 会在匹配架构的 runner 上分别构建。产物位于 `dist/` 下的架构专属路径。本地默认使用临时签名，不是 Developer ID 签名或公证包。产物路径与 runner 说明见[构建与 CI](docs/BUILDING.md)；安装可选辅助服务前，请阅读[安装与卸载说明](docs/INSTALLATION.md)。

## 隐私与安全

默认不启用 goodtouchbar 自有遥测服务，也不会把数据发送到 goodtouchbar 自有服务器。**这不表示应用完全离线：**集成会读取本机应用数据、启动或连接本地客户端，而客户端可能连接自己的 AI 服务。WorkBuddy 调试协议在本机 loopback 上监听且没有认证；随机本机端口和聊天绑定可以减少误连接，但不能消除协议风险。自动重试可能向当前绑定的 AI 服务再次发送请求。

请阅读完整的[隐私与数据处理说明](docs/PRIVACY.md)及[安全报告政策](SECURITY.md)。分享诊断日志或本地状态文件前，请先检查内容。

## 项目状态

0.3.1 / build 4 已在这台 Apple 芯片开发机上通过原生 arm64 和 Rosetta x86_64 公共测试，并通过详情状态、操作路由、无障碍及布局检查。截图预览使用示例数据，离屏布局预览不验证系统毛玻璃合成效果。此前 0.2.0 的 M1 Pro 只读采样获得了 CPU/内存数据、M1 CPU 热区温度及两个风扇 RPM 读数；这不等于原生 Intel 硬件已验收。0.1.0 / build 1 的准备记录保留在 [CHANGELOG.md](CHANGELOG.md)。本地检查和 GitHub 发布是不同状态，自动化检查也不能证明实体 Touch Bar 呈现、播放器响应、传感器覆盖或风扇写入效果。M1/M2 Touch Bar 机型举例来自 Apple 技术规格，不代表本应用已在这些设备验收。安装包为 ad-hoc 签名，尚未公证；请查看 [Release 页面](https://github.com/yihuirui/goodtouchbar/releases)了解发布状态。

## 参与贡献

欢迎提交问题、范围明确的改进和文档更新。请先阅读[贡献指南](CONTRIBUTING.md)。不要在公开 issue 中附上私有会话数据、凭据或未经脱敏的日志。安全问题请按 [SECURITY.md](SECURITY.md) 报告。

## 许可证

goodtouchbar 原创贡献按 MIT License 提供，见 [LICENSE](LICENSE)。源自 Stats 的 AppleSMC 代码保留独立 MIT 归属，见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) 和 [Licenses/Stats-MIT.txt](Licenses/Stats-MIT.txt)。项目许可证不会自动重新许可第三方材料。
