# Longview

**See beyond the viewport.**

[English](README.md)

[![CI](https://github.com/kohoj/longview/actions/workflows/ci.yml/badge.svg)](https://github.com/kohoj/longview/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-0b7285.svg)](LICENSE)

面向 AI agent 的无 UI macOS CLI：选择一个 WindowServer 窗口，程序化滚动、逐帧采集并生成 PNG 长图。

产品 binary 不包含窗口、菜单栏、保存面板、OCR、网络、点击、键盘输入或剪贴板能力。采集使用 ScreenCaptureKit；滚动只走公开的 Accessibility 与 Core Graphics API。

## 能力边界

| 场景 | 行为 |
|---|---|
| 窗口仍由 ScreenCaptureKit 暴露 | 可在不前置 App 的情况下采集单帧 |
| App 暴露可操作的 AX scrollbar | 后台滚动、后台采集、精确恢复 scrollbar value |
| App 接受 PID-targeted wheel event | 后台滚动；每步必须经截图验证确有运动 |
| 后台路线无效，窗口仍在当前 Space 可见 | 默认临时激活目标、滚动、恢复视口、鼠标和原前台 App |
| 窗口位于其他 Space | 可以尝试后台采集；前景回退会在抢焦点前拒绝 |
| DRM、受保护内容、游戏、远程桌面或拒绝合成事件的 App | 可能返回不可用；不会伪造成功 |

因此，“任何 App”准确地说是“任何可分享的普通 layer-0 窗口”；后台截图是普遍能力，后台滚动是目标 App 能力。CLI 会在运行时探测，而不是维护虚假的兼容名单。

## 30 秒开始

```bash
xcode-select --install              # 已有 Swift 时跳过
git clone https://github.com/kohoj/longview.git
cd longview
./scripts/install.sh
export PATH="$HOME/.local/bin:$PATH" # 仅当 ~/.local/bin 不在 PATH
longview doctor --pretty
```

安装器只在本机从源码构建，不调用 `sudo`，不修改 shell 配置，并在
`~/.local/share/longview` 写入机器可读的安装凭证。

## Agent 最短调用链

```bash
# 1. 无副作用地诊断安装、系统和权限
longview doctor --pretty

# 2. 无激活地列出可采集窗口
longview windows
longview windows --bundle-id com.tencent.xinWeChat --include-titles

# 3. 用最稳定的 window ID 生成长图
longview --events longshot \
  --output /absolute/path/context.png \
  --window-id 49932 \
  --max-frames 8 \
  --focus-policy background-first \
  --region auto
```

`--window-id` 是最高精度主键，可独立使用；bundle ID 是筛选条件，不是必须身份。未传两者时，`longshot` 使用前台 App 的 bundle ID 并选择其最大有效窗口。

## `longshot` 参数

```text
--output PATH.png                         必填；PNG 不写 stdout
--window-id UINT32                       精确 WindowServer ID
--bundle-id ID                           bundle 筛选或默认窗口选择
--max-frames 1...100                     默认 6
--pulses-per-step 1...240                默认 28
--direction up|down                      默认 up
--focus-policy background-only|
               background-first|foreground
                                           默认 background-first
--region auto|full|profile|x,y,w,h       坐标为 0...1 归一化矩形
--scroll-point x,y                       默认 0.65,0.5
--settle-ms 100...5000                   默认 450
--no-stop-at-end                         不做无运动终止
--force                                  原子替换已有文件
```

焦点策略：

- `background-only`：只允许 AX 与 PID 后台路线，失败返回 69，不触碰焦点或鼠标。
- `background-first`：先后台探测；无效时仅对当前 Space 可见窗口做可恢复的临时前置。
- `foreground`：目标必须已经是前台；CLI 只临时定位并恢复鼠标。

区域策略：

- `auto`：已知 App 使用 profile；通用窗口只保守移除固定顶部/底部 chrome，不猜左右侧栏。
- `full`：字面上的完整窗口，包括窗口 chrome。
- `profile`：当前内置微信聊天区 profile。
- `x,y,w,h`：agent 明确给出滚动内容矩形，适合侧栏、嵌套滚动区和复杂 IDE。

## 稳定协议

- 成功：stdout 恰好一个 schema v2 JSON result。
- 失败：stderr 恰好一个 schema v2 JSON error，并返回非零退出码。
- `--events`：stdout 为 NDJSON progress，最后一行为 result。
- `--pretty`：人工阅读模式，不能与 `--events` 同时使用。
- PNG 只写 `--output`；成功拼接前不提交目标文件。
- `SIGINT` / `SIGTERM` 返回 `canceled` / 130，并仍尝试恢复已修改状态。

关键 result 字段包括：`scrollRoute`、`stopReason`、`captureRegion`、`detectedOverlaps`、`targetWasActivated`、`pointerWasMoved`、`viewportRestorationSucceeded` 与 `environmentRestorationSucceeded`。

退出码：

| 码 | 含义 |
|---:|---|
| 0 | 已生成结果 |
| 64 | 参数错误 |
| 69 | 目标、窗口或可用路线不存在 |
| 73 | 输出路径被拒绝 |
| 74 | 截图、拼接或 I/O 失败 |
| 75 | lease 改变或临时前景事务失败 |
| 77 | 缺少 Accessibility 或 Screen Recording 权限 |
| 130 | 取消 |

## 权限

- `windows` 与单帧 `longshot --max-frames 1`：Screen Recording。
- 多帧 `longshot`：Screen Recording + Accessibility。
- `target` / `scroll`：Accessibility。

macOS 通常把权限归因到启动 CLI 的 Terminal、agent host 或 IDE。CLI 不主动打开系统设置。

## 安装、更新与卸载

```bash
./scripts/install.sh
./scripts/update.sh --check
./scripts/update.sh --to v0.3.1
~/.local/share/longview/uninstall.sh
```

只有源码仓库里的 `update.sh` 会访问网络；`longview` runtime 始终离线。卸载仅删除
安装凭证中记录的文件，不会删除长图、shell 配置或 macOS 权限。

## 安全不变量

- 捕获锁定 PID + WindowServer ID + frame；不会退化成“截当前前台”。
- 每条路线先做一次实际运动探测；截图无运动就换路线或结构化失败。
- 前景滚轮每个 pulse 前重新验证前台 PID、窗口 ID/frame 与鼠标位置。
- 视口恢复后重新截图并和初始帧比对；不是仅凭反向事件数量宣称成功。
- 跨 Space 前景回退在激活前拒绝，避免无法可靠恢复用户工作区。
- `SystemScrollEventPoster` 是唯一 wheel-event 发射边界；产品没有点击或键盘原语。

更深入的设计见 [架构说明](docs/architecture.md) 与 [agent 契约](docs/agent-contract.md)。

## 验证

```bash
swift test
scripts/verify-cli.sh
```

验证覆盖 schema v2、release build、公开 API、fixture 隔离、源码安装生命周期、输出文件
`0600` 权限、公开仓库边界、无 UI/OCR/network/private framework、事件边界及参数契约。

隐私与安全边界见 [PRIVACY.md](PRIVACY.md) 和 [SECURITY.md](SECURITY.md)。Longview 采用
[MIT License](LICENSE)。
