# AGY Mac Control

[English](README.en.md) | 中文

让 **Google Antigravity** 的智能体能看见并操作你 Mac 上的软件（截屏、点鼠标、打字），而且**你能看清它每一步在做什么，随时按 Esc 叫停**。

> 非 Google 官方项目。Antigravity 自带的电脑控制功能目前还没对所有人开放，这个项目是在那之前的一个安全、透明的替代方案。

## 它长什么样

<p align="center"><img src="docs/demo.gif" width="360" alt="演示：智能体在计算器上点 7 × 6 =，屏幕有蓝色边框、顶部状态条和点击圆圈"></p>

<sub>真实录制：智能体通过本工具在计算器上点了 AC、7、×、6、=。为了录下来，演示时提示窗口临时设成了可被截图（正式版不会进截图），背景也换成了纯色。</sub>

智能体操作时，屏幕上会出现：

- 🔵 **屏幕四周的蓝色发光边框**：正在被控制，停止 4 秒后淡出
- 💬 **顶部中间的状态条**：实时显示“🖱 点击 (300, 200)”“⌨️ 输入：你好”等，以及“按 Esc 立即停止”
- ⭕ **点击位置的蓝色圆圈**
- 🖱 **鼠标平滑移动**，不会瞬移

这些提示**不会出现在智能体自己的截图里**（窗口设置了 `sharingType = .none`），不干扰它判断界面；鼠标点击也会直接穿过它们。

## 安全设计

| 设计 | 作用 |
|---|---|
| **权限只给一个小程序** | “屏幕录制”和“辅助功能”权限只授予菜单栏小程序 `AGY Mac Control`，Antigravity 本身不需要这两个权限 |
| **只在本机通信 + 口令** | 小程序只监听 `127.0.0.1:47321`，每个请求都要带随机口令（存在 `~/Library/Application Support/agy-mac-control/token`，权限 600） |
| **Esc 一键暂停** | 全局监听 Esc，按下后拒绝一切操作，直到你在菜单栏点“继续” |
| **防止点错** | 没截过屏不允许点；截屏后前台软件变了（比如你切了窗口）就拒绝操作，要求重新截屏 |
| **敏感软件禁区** | “密码”和“钥匙串访问”在最前面时拒绝点击和输入 |
| **操作留痕** | 每个动作记在 `helper.log` |
| **不自动更新、不联网** | 从源码本地编译，没有任何远程下载或上报 |

## 安装

需要：macOS 14+、Antigravity 桌面版、Xcode 命令行工具（`xcode-select --install`）。

```bash
git clone https://github.com/nishinoya070813-a11y/agy-mac-control.git
cd agy-mac-control
./install.sh
```

然后**你自己**在 系统设置 → 隐私与安全性 里：

1. **辅助功能**：打开「AGY Mac Control」
2. **屏幕与系统录音**：打开「AGY Mac Control」（列表里没有就点“+”从“应用程序”添加）
3. 菜单栏 🖱 AG → 退出，再重新打开 `/Applications/AGY Mac Control.app`
4. 重启 Antigravity

卸载：`./uninstall.sh`

## 使用

在 Antigravity 里直接用大白话说要做的事：

```
打开计算器，帮我算 1234 × 56
打开备忘录，新建一条写“明天 9 点交作业”
```

第一次调用时 Antigravity 会问你是否允许这些工具，可以选“在这个对话里一直允许”。

提供给智能体的工具：`computer_screenshot`、`computer_click`、`computer_move`、`computer_drag`、`computer_scroll`、`computer_type`、`computer_key`、`computer_list_apps`、`computer_open_app`。

## 已知限制

- 只支持主显示器
- 用的是本机临时签名：**每次重新编译后都要重新打开那两个系统权限**（安装脚本会先清掉旧记录）
- 端口固定为 47321
- Antigravity 官方的电脑控制功能开放后，建议优先用官方的

## 风险提示

这个工具能让 AI 操作你的整台电脑。请：

- 只在你看得到屏幕的时候用，别让它无人值守地跑
- 不要让它输入密码、银行卡号，不要让它付款、发消息或删除东西而不先问你
- 发现不对立刻按 **Esc**

## 原理

```
Antigravity 智能体
   │  MCP（stdio）
   ▼
mcp/mcp_server.py   —— 纯 Python 标准库，做安全检查
   │  HTTP 127.0.0.1:47321 + 口令
   ▼
AGY Mac Control.app —— Swift 菜单栏小程序，持有系统权限
   ├─ screencapture 截屏（缩到“点”的尺寸，截图坐标 = 点击坐标）
   ├─ CGEvent 模拟鼠标键盘
   └─ 屏幕提示：边框 / 状态条 / 点击圆圈
```

## 协议

MIT
