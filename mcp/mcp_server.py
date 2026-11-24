#!/usr/bin/env python3
"""AGY Mac Control v2 · MCP 插件（给 Antigravity 用）。

Antigravity 通过标准输入输出和这个脚本对话（MCP 协议）；脚本再把请求转给本机的
「AGY Mac Control」菜单栏小程序（127.0.0.1:47321，带口令）。真正的操作都由那个小程序做，权限也只给它。
只用 Python 自带的库，不需要安装任何东西。

v2 思路（参考 Codex）：优先读软件的“辅助功能树”（按钮/输入框清单，带编号），按编号直接操作，
大多数时候不动鼠标；读不到再用截图 + 坐标。还能一次做好几步（computer_batch），减少来回。
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

SUPPORT = os.path.expanduser("~/Library/Application Support/agy-mac-control")
URL = "http://127.0.0.1:47321/"
APP = "AGY Mac Control"

APP_ARG = {"type": "string", "description": "软件名或 bundle id，例如 \"计算器\"、\"com.apple.Notes\""}
OPT_APP = {"type": "string", "description": "可选：目标软件。指定后按键/输入直接发给它，不用切到前台"}

TOOLS = [
    {"name": "computer_get_app_state",
     "description": "【首选】读取某个软件的界面：返回它的辅助功能树（按钮、输入框、文字的清单，每个带 [编号]）。"
                    "软件没打开会在后台自动打开。之后用 computer_click_element / computer_set_value 按编号操作，不用猜坐标。"
                    "每做完一两步要重新调用，编号可能会变。screenshot=true 时额外附上这个软件窗口的截图（树不完整时再用）。",
     "inputSchema": {"type": "object", "required": ["app"], "properties": {
         "app": APP_ARG, "screenshot": {"type": "boolean", "description": "是否附上窗口截图，默认 false"}}}},
    {"name": "computer_click_element",
     "description": "按编号点击（按下）某个按钮/菜单项/链接。编号来自最近一次 computer_get_app_state。通常不会移动鼠标。",
     "inputSchema": {"type": "object", "required": ["app", "index"], "properties": {
         "app": APP_ARG, "index": {"type": "integer"}}}},
    {"name": "computer_set_value",
     "description": "按编号直接把输入框的内容设成 value（比一个个打字快）。不要填密码、银行卡号等敏感信息。",
     "inputSchema": {"type": "object", "required": ["app", "index", "value"], "properties": {
         "app": APP_ARG, "index": {"type": "integer"}, "value": {"type": "string"}}}},
    {"name": "computer_element_action",
     "description": "对某个元素执行“其他操作”，例如 ShowMenu、Increment、Decrement、Confirm、Cancel。"
                    "只能用 get_app_state 里这个元素列出的操作名，不要瞎猜。",
     "inputSchema": {"type": "object", "required": ["app", "index", "name"], "properties": {
         "app": APP_ARG, "index": {"type": "integer"}, "name": {"type": "string"}}}},
    {"name": "computer_type",
     "description": "在当前输入焦点处输入文字（支持中文）。注意文字里的换行会当成回车，可能直接发送或提交。",
     "inputSchema": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}, "app": OPT_APP}}},
    {"name": "computer_key",
     "description": "按键或组合键，例如 return、esc、tab、cmd+c、cmd+shift+g、up。",
     "inputSchema": {"type": "object", "required": ["combo"], "properties": {"combo": {"type": "string"}, "app": OPT_APP}}},
    {"name": "computer_screenshot",
     "description": "【后备】截取整个主屏幕。只在辅助功能树读不到需要的东西时使用。"
                    "截图上的像素坐标 = computer_click 用的坐标（不带 app 参数时）。",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "computer_click",
     "description": "【后备】按坐标点击，会移动真的鼠标。带 app 时，x/y 是那个软件窗口截图（get_app_state screenshot=true）里的坐标；"
                    "不带 app 时是整屏截图里的坐标。能用 computer_click_element 就别用这个。",
     "inputSchema": {"type": "object", "required": ["x", "y"], "properties": {
         "x": {"type": "number"}, "y": {"type": "number"}, "app": OPT_APP,
         "button": {"type": "string", "enum": ["left", "right"]}, "count": {"type": "integer"}}}},
    {"name": "computer_drag",
     "description": "【后备】按住左键从 (x1, y1) 拖到 (x2, y2)。坐标规则同 computer_click。",
     "inputSchema": {"type": "object", "required": ["x1", "y1", "x2", "y2"], "properties": {
         "x1": {"type": "number"}, "y1": {"type": "number"}, "x2": {"type": "number"}, "y2": {"type": "number"}, "app": OPT_APP}}},
    {"name": "computer_scroll",
     "description": "在 (x, y) 处滚动。dy 正数往下、负数往上，每单位约一行。坐标规则同 computer_click。",
     "inputSchema": {"type": "object", "properties": {
         "x": {"type": "number"}, "y": {"type": "number"}, "dy": {"type": "integer"}, "dx": {"type": "integer"}, "app": OPT_APP}}},
    {"name": "computer_move",
     "description": "把鼠标移到 (x, y)，不点击（用来触发悬停提示）。",
     "inputSchema": {"type": "object", "required": ["x", "y"], "properties": {
         "x": {"type": "number"}, "y": {"type": "number"}, "app": OPT_APP}}},
    {"name": "computer_list_apps",
     "description": "列出正在运行的软件，标出哪个在最前面。",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "computer_open_app",
     "description": "把某个软件切到最前面（没打开会先打开）。只读界面、按编号操作时不需要切换。",
     "inputSchema": {"type": "object", "required": ["app"], "properties": {"app": APP_ARG}}},
    {"name": "computer_batch",
     "description": "一次连续执行好几步，减少来回。actions 是数组，每项 {\"tool\": 工具名, \"args\": 参数}，"
                    "工具名可用上面任何一个（去掉 computer_ 前缀也行）。遇到失败就停下并报告。"
                    "then_state 填软件名时，做完后顺便返回这个软件的最新界面。"
                    "只把确定的步骤放进来，需要看结果再决定的不要放。",
     "inputSchema": {"type": "object", "required": ["actions"], "properties": {
         "actions": {"type": "array", "items": {"type": "object"}},
         "then_state": {"type": "string"}}}},
]

ACTION = {"computer_get_app_state": "app_state", "computer_click_element": "click_element",
          "computer_set_value": "set_value", "computer_element_action": "element_action",
          "computer_type": "type", "computer_key": "key", "computer_screenshot": "screenshot",
          "computer_click": "click", "computer_drag": "drag", "computer_scroll": "scroll", "computer_move": "move",
          "computer_list_apps": "apps", "computer_open_app": "open_app"}

# 不指定软件、直接按屏幕坐标/前台焦点操作的动作：需要“前台没变”的检查
GLOBAL_ACTIONS = {"computer_click", "computer_drag", "computer_scroll", "computer_move", "computer_type", "computer_key"}
LAST_FRONT = {"name": None}


def token():
    try:
        return open(os.path.join(SUPPORT, "token"), encoding="utf-8").read().strip()
    except OSError:
        return ""


def call_helper(action, args):
    def req():
        body = dict(args, action=action, token=token())
        return urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    for attempt in range(2):
        try:
            with urllib.request.urlopen(req(), timeout=40) as r:
                return json.loads(r.read())
        except OSError:
            if attempt == 0:  # 小程序没开：帮忙打开一次
                subprocess.run(["open", "-a", APP], capture_output=True)
                time.sleep(2.5)
    return {"error": f"连不上「{APP}」小程序。请确认它在运行（菜单栏能看到 🖱 AG）。"}


def front_app():
    """当前最前面的软件名（用系统自带的 lsappinfo，不需要任何权限）。"""
    try:
        asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=3).stdout.strip()
        out = subprocess.run(["lsappinfo", "info", "-only", "name", asn], capture_output=True, text=True, timeout=3).stdout
        m = re.search(r'^\s*"([^"]+)"', out, re.M)  # 第一行形如："计算器" ASN:0x0-0x338338: (in front)
        return m.group(1) if m else None
    except (OSError, subprocess.SubprocessError):
        return None


def text(t, err=False):
    r = {"content": [{"type": "text", "text": t}]}
    if err:
        r["isError"] = True
    return r


def run_tool(name, args):
    """执行一个工具，返回 MCP 结果。"""
    if not name.startswith("computer_"):
        name = "computer_" + name
    if name == "computer_batch":
        return run_batch(args)
    if name not in ACTION:
        return text(f"没有这个工具：{name}", True)

    # 安全检查：不指定软件的坐标/键盘操作，要求截屏之后前台没变（比如用户切了窗口），否则不按旧画面操作
    if name in GLOBAL_ACTIONS and not args.get("app"):
        now = front_app()
        if LAST_FRONT["name"] is None:
            return text("还没看过屏幕。请先 computer_screenshot，或者改用带 app 参数的操作 / computer_get_app_state。", True)
        if now is None:
            return text("暂时查不到最前面是哪个软件，为了不点错，这一步没有执行。请重新截屏后再试。", True)
        if now != LAST_FRONT["name"]:
            prev = LAST_FRONT["name"]
            LAST_FRONT["name"] = None
            return text(f"最前面的软件已经从「{prev}」变成了「{now}」（可能是用户切换了窗口）。"
                        "为了不点错，这一步没有执行。请重新 computer_screenshot，或改用带 app 参数的操作。", True)

    res = call_helper(ACTION[name], args)
    if res.get("error"):
        return text("失败：" + res["error"], True)

    if name == "computer_screenshot":
        LAST_FRONT["name"] = front_app() or res.get("frontmost")
        return {"content": [{"type": "image", "data": res["image"], "mimeType": "image/jpeg"},
                            text(f"整屏截图 {res['width']}×{res['height']}，最前面的软件：{res.get('frontmost', '')}")["content"][0]]}
    if name == "computer_get_app_state":
        # 去掉一些软件自带的“内部操作”（形如 Name:拷贝 Target:0x0 Selector:(null)），对模型没用还占地方
        res["text"] = re.sub(r",?Name:[^\n]*\nTarget:[^\n]*\nSelector:[^\n,]*", "", res.get("text", ""))
        res["text"] = re.sub(r" 其他操作:(?=\n|$)", "", res["text"])
        head = f"「{res.get('app')}」（{res.get('bundle')}）{'在最前面' if res.get('frontmost') else '在后台'}，共 {res.get('count')} 个元素：\n"
        content = [{"type": "text", "text": head + res.get("text", "")}]
        if res.get("image"):
            content.append({"type": "image", "data": res["image"], "mimeType": "image/jpeg"})
            content.append({"type": "text", "text": f"窗口截图 {res['width']}×{res['height']}（窗口左上角在屏幕 ({res['originX']}, {res['originY']})）。"
                                                    "用 computer_click 带 app 时，直接用这张图里的坐标。"})
        elif res.get("screenshotError"):
            content.append({"type": "text", "text": "（窗口截图失败：" + res["screenshotError"] + "）"})
        return {"content": content}
    if name == "computer_list_apps":
        lines = [("★ " if a["frontmost"] else "  ") + f"{a['name']}（{a['bundle']}）" for a in res["apps"]]
        return text("\n".join(lines))
    if name == "computer_open_app":
        LAST_FRONT["name"] = None  # 换了软件，坐标操作前必须重新截屏
    note = ("（" + res["note"] + "）") if res.get("note") else ""
    return text(f"完成{note}。现在最前面的软件：{res.get('frontmost', '')}。")


def run_batch(args):
    acts = args.get("actions") or []
    if not isinstance(acts, list) or not acts:
        return text("actions 不能为空", True)
    if len(acts) > 20:
        return text("一次最多 20 步", True)
    log = []
    for i, a in enumerate(acts, 1):
        tool = (a or {}).get("tool", "")
        if tool in ("batch", "computer_batch"):
            return text("batch 里不能再套 batch", True)
        r = run_tool(tool, (a or {}).get("args") or {})
        msg = " ".join(c.get("text", "") for c in r["content"] if c.get("type") == "text")
        log.append(f"{i}. {tool}：{msg[:200]}")
        if r.get("isError"):
            return text("批量执行在第 %d 步停下：\n" % i + "\n".join(log), True)
    content = [{"type": "text", "text": "全部完成：\n" + "\n".join(log)}]
    if args.get("then_state"):
        st = run_tool("computer_get_app_state", {"app": args["then_state"]})
        content += st["content"]
    return {"content": content}


def send(msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        mid, method = msg.get("id"), msg.get("method")
        if mid is None:
            continue  # 通知类消息不用回复
        if method == "initialize":
            ver = (msg.get("params") or {}).get("protocolVersion", "2025-03-26")
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": ver, "capabilities": {"tools": {}},
                "serverInfo": {"name": "agy-mac-control", "version": "2.0"},
                "instructions": "用这些工具操作用户 Mac 上的软件。优先 computer_get_app_state 读界面，再按编号操作；"
                                "确定的连续步骤用 computer_batch 一次做完。读不到再用截图和坐标。"
                                "用户随时可能暂停，收到“暂停”错误时停止并告诉用户。登录、付款、发消息、删除、提交表单前先问用户。"}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            p = msg.get("params") or {}
            send({"jsonrpc": "2.0", "id": mid, "result": run_tool(p.get("name", ""), p.get("arguments") or {})})
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        else:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"不支持：{method}"}})


if __name__ == "__main__":
    main()
