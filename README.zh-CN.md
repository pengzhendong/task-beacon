<div align="center">
  <img src="Assets/TaskBeacon.png" width="112" height="112" alt="TaskBeacon icon">
  <h1>TaskBeacon · 任务信标</h1>
  <p><strong>让 AI 和它启动的长任务，持续报告真实进度。</strong></p>
  <p>macOS 菜单栏 · MCP / CLI · 独立后台采集 · 应用内自动更新</p>

  <p>
    <a href="README.md">English</a>
    ·
    <a href="https://github.com/pengzhendong/task-beacon/releases">下载</a>
    ·
    <a href="#快速开始">快速开始</a>
    ·
    <a href="#mcp-接入">MCP 接入</a>
    ·
    <a href="#开发与发布">开发与发布</a>
  </p>

  <p>
    <a href="https://github.com/pengzhendong/task-beacon/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/pengzhendong/task-beacon/actions/workflows/ci.yml/badge.svg"></a>
    <a href="https://github.com/pengzhendong/task-beacon/releases"><img alt="Release" src="https://img.shields.io/github/v/release/pengzhendong/task-beacon?display_name=tag"></a>
    <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple">
    <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
    <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-24292f"></a>
  </p>
</div>

TaskBeacon 是一个本地优先的 macOS AI 任务进度中心。AI 在开始工作时注册任务，在阶段变化时主动上报；对于训练、构建、批处理等长任务，还可以注册一条查询命令，由独立守护进程在模型回合结束后继续采集进度。

## 为什么需要 TaskBeacon？

| 能力 | 说明 |
| --- | --- |
| **统一上报** | MCP 和 CLI 共用同一任务模型，支持注册、更新、完成和取消。 |
| **持续采集** | 后台守护进程按间隔运行日志解析、接口查询或 SSH 命令，不依赖 AI 一直在线。 |
| **如实展示** | 有可靠总量才显示百分比；否则只显示阶段、消息、耗时和最近活动。 |
| **多任务隔离** | 使用 provider、host、session、task 和 parent task 标识不同来源及子任务。 |
| **故障分离** | 采集超时或输出错误只标记采集器异常，不会把业务任务误报为失败。 |
| **可靠恢复** | 事件去重、乱序保护、原子持久化，服务重启后恢复任务和采集器。 |
| **应用内更新** | Sparkle 定期检查签名的 GitHub Release；可一键安装并重新启动，无需重新拖动应用。 |

## 安装

### 从 Release 安装

从 [Releases](https://github.com/pengzhendong/task-beacon/releases) 下载最新的 `TaskBeacon-v*.zip`，解压后将 `TaskBeacon.app` 放入 Applications 并打开。目前预构建版本面向 Apple Silicon Mac（M 系列），Intel Mac 可自行从源码构建。首次安装完成后，后续版本可在应用内完成：菜单栏选择 **检查更新…**，或等待每天一次的后台检查；下载后选择安装并重新启动，由更新器完成替换和重启，无需重新拖动应用。

> [!NOTE]
> 在尚未配置 Apple Developer ID 的早期 Release 中，macOS 可能提示应用来自未识别开发者。自动更新包仍会使用项目独立的 Ed25519 密钥验证；正式分发建议同时配置 Developer ID 签名和公证。

### 从源码运行

```bash
git clone https://github.com/pengzhendong/task-beacon.git
cd task-beacon
make app
open dist/TaskBeacon.app
```

需要 macOS 13+ 和 Swift 6；本地生成的应用使用临时签名，不需要 Apple Developer 账号。

## 快速开始

菜单栏应用会自动启动随包的本地服务。内置 CLI 位于：

```bash
/Applications/TaskBeacon.app/Contents/Resources/bin/taskbeacon
```

注册、更新并完成一个任务：

```bash
taskbeacon=/Applications/TaskBeacon.app/Contents/Resources/bin/taskbeacon

"$taskbeacon" register \
  --id demo \
  --title "示例任务" \
  --project task-beacon \
  --stage "准备中"

"$taskbeacon" update demo \
  --stage "处理中" \
  --completed 3 \
  --total 10 \
  --unit 项

"$taskbeacon" complete demo \
  --result "处理完成" \
  --target "https://github.com/pengzhendong/task-beacon"
```

也可以将 CLI 链接到现有的 `PATH` 目录，之后直接使用 `taskbeacon`。运行 `"$taskbeacon" --help` 查看完整命令入口。

## MCP 接入

MCP stdio server 位于：

```text
/Applications/TaskBeacon.app/Contents/Resources/bin/taskbeacon-mcp
```

将这个绝对路径添加到支持 MCP 的 AI 客户端。Server 提供以下工具：

- `task_register`
- `task_update`
- `task_complete`
- `task_cancel`
- `task_list`
- `collector_register`

所有更新支持 `event_id` 去重；提供 `sequence` 时，旧序号不会覆盖新状态。没有 sequence 的事件按 `observed_at` 保护，旧观测同样不会覆盖新状态。

## 后台采集器

采集命令每次运行应向标准输出写入一个 JSON 对象。只有总量可靠且单位一致时才提供 `progress`：

```json
{
  "status": "running",
  "stage": "训练中",
  "message": "loss 0.42",
  "progress": {
    "completed": 3200,
    "total": 10000,
    "unit": "step"
  }
}
```

达到完成条件时返回 `"done": true`，还可以附带 `result` 和 `target`。注册示例：

```bash
taskbeacon collector add \
  --id training-log \
  --task training-2026-09-08 \
  --interval 30 \
  --timeout 5 \
  --cwd /path/to/project \
  --command './scripts/read-progress.sh'
```

管理采集器：

```bash
taskbeacon collector list
taskbeacon collector pause training-log
taskbeacon collector resume training-log
taskbeacon collector remove training-log
```

同一个采集器始终只会运行一个实例。如果命令耗时超过轮询间隔，TaskBeacon 会等待本轮结束，再从结束时间起计算下一次间隔。暂停、删除或同 ID 替换采集器时，仍在运行的旧结果会失效，并尽可能终止对应的采集子进程。

采集命令由当前用户的 `/bin/zsh` 执行，应当只做观察，不应修改或重启业务任务。不要把凭据写入进度消息或命令文本；优先从 Keychain、受限环境变量或已有 CLI 登录状态读取。

## 架构

| 组件 | 职责 |
| --- | --- |
| `TaskBeaconMenu` | SwiftUI 菜单栏、任务分组、进度、采集器健康、系统通知和更新入口 |
| `taskbeacond` | Unix Socket 服务、事件处理、JSON 持久化和独立采集调度 |
| `taskbeacon` | 人工、脚本及 Agent 可调用的命令行接口 |
| `taskbeacon-mcp` | JSON-RPC stdio MCP server |
| `TaskBeaconCore` | 任务模型、协议、客户端和存储 |

默认状态文件为 `~/Library/Application Support/TaskBeacon/state.json`，Socket 为 `/tmp/taskbeacon-$UID.sock`。测试或多实例运行时可使用 `TASKBEACON_DATA_DIR` 和 `TASKBEACON_SOCKET` 覆盖。

## 开发与发布

要求 macOS 13+ 和 Swift 6。无需完整 Xcode 即可进行普通构建：

```bash
swift build
swift run taskbeacon-selftest
make app
```

`make app` 会在 `dist/TaskBeacon.app` 生成本地临时签名的应用包，并嵌入守护进程、CLI、MCP server 和 Sparkle framework。

正式图标采用白色叠卡、命令符和鼠尾草绿进度条；菜单栏使用同图案的白色单色透明版，软件图标保持白底。原始图稿在 `Assets/TaskBeacon.source.png`；执行 `make icons` 可重新导出应用图标和菜单栏透明资源，生成方式见 [图标说明](Assets/ICON.md)。

发布由 GitHub Actions 完成。先同步 `Resources/Info.plist` 中的版本，然后推送匹配的 tag：

```bash
git tag v0.1.0
git push origin v0.1.0
```

Release workflow 会验证版本、运行构建、打包应用、用 `SPARKLE_PRIVATE_KEY` 签名更新、生成 `appcast.xml` 和 `SHA256SUMS.txt`，最后发布 GitHub Release。仓库已经配置 Sparkle 私钥 Secret；如需 Developer ID 签名与公证，再配置：

- `MACOS_CERTIFICATE`：Base64 编码的 Developer ID Application `.p12`
- `MACOS_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

## 安全边界

- 本地 API 只监听当前用户的 Unix Socket，不开放 TCP 端口。
- 更新 feed 和更新归档均使用项目独立的 Ed25519 密钥验证。
- 任务事件最多保留 10,000 条；持久化使用临时文件和原子替换。
- TaskBeacon 不替 Agent 管理业务凭据，也不会自动唤醒任意 MCP 客户端。
- 注册采集命令等同于授权当前用户执行该命令，只应接受可信 Agent 或脚本的输入。

## 当前范围

MVP 已覆盖本机主动上报、长任务采集、多任务/子任务、重启恢复、系统通知和应用内自动更新。远端常驻采集、各 AI 客户端 hooks 适配和复杂任务分析仍在后续范围。

## License

TaskBeacon is licensed under the [Apache License 2.0](LICENSE).
