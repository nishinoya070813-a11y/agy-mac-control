#!/usr/bin/env python3
"""AGY Mac Control · MCP 插件（给 Antigravity 用）。

Antigravity 通过标准输入输出和这个脚本对话（MCP 协议）；脚本再把请求转给本机的
「AGY Mac Control」菜单栏小程序（127.0.0.1:47321，带口令）。截屏、点击等真正的操作都由那个小程序做，
权限也只给它。只用 Python 自带的库，不需要安装任何东西。
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

SUPPORT = os.path.expanduser("~/Library/Application Support/agy-mac-control")
URL = "http://127.0.0.1:47321/"
APP = "AGY Mac Control"

GUIDE = ("坐标说明：x、y 是最近一次 computer_screenshot 图片里的像素坐标（左上角是 0,0），和屏幕的“点”一一对应。"
         "每做一两步就重新截屏确认结果，不要凭记忆点。")

TOOLS = [
    {"name": "computer_screenshot",
     "description": "截取 Mac 主屏幕，返回图片和当前最前面的软件。操作任何软件前先调用它看清界面。" + GUIDE,
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "computer_click",
     "description": "在屏幕坐标 (x, y) 点击。button 可选 left/right，count 可选 1/2/3（双击、三击）。" + GUIDE,
     "inputSchema": {"type": "object", "required": ["x", "y"], "properties": {
         "x": {"type": "number"}, "y": {"type": "number"},
         "button": {"type": "string", "enum": ["left", "right"]}, "count": {"type": "integer"}}}},
    {"name": "computer_move",
     "description": "把鼠标移到 (x, y)，不点击（用来触发悬停提示）。",
     "inputSchema": {"type": "object", "required": ["x", "y"], "properties": {
         "x": {"type": "number"}, "y": {"type": "number"}}}},
    {"name": "computer_drag",
     "description": "按住左键从 (x1, y1) 拖到 (x2, y2)。",
     "inputSchema": {"type": "object", "required": ["x1", "y1", "x2", "y2"], "properties": {
         "x1": {"type": "number"}, "y1": {"type": "number"}, "x2": {"type": "number"}, "y2": {"type": "number"}}}},
    {"name": "computer_scroll",
     "description": "在 (x, y) 处滚动。dy 正数往下、负数往上；dx 正数往右。每单位约一行。",
     "inputSchema": {"type": "object", "required": ["x", "y"], "properties": {
         "x": {"type": "number"}, "y": {"type": "number"}, "dy": {"type": "integer"}, "dx": {"type": "integer"}}}},
    {"name": "computer_type",
     "description": "在当前输入焦点处输入文字（支持中文）。先用 computer_click 点中输入框。不要输入密码、银行卡号等敏感信息。",
     "inputSchema": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}},
    {"name": "computer_key",
     "description": "按键或组合键，例如 return、esc、tab、cmd+c、cmd+shift+g、up。用 + 连接修饰键。",
     "inputSchema": {"type": "object", "required": ["combo"], "properties": {"combo": {"type": "string"}}}},
    {"name": "computer_list_apps",
     "description": "列出正在运行的软件，标出哪个在最前面。",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "computer_open_app",
     "description": "打开或切换到某个软件，name 用软件名（例如 \"备忘录\"、\"Safari浏览器\"）。",
     "inputSchema": {"type": "object", "required": ["name"], "properties": {"name": {"type": "string"}}}},
]

ACTION = {"computer_screenshot": "screenshot", "computer_click": "click", "computer_move": "move",
          "computer_drag": "drag", "computer_scroll": "scroll", "computer_type": "type",
          "computer_key": "key", "computer_list_apps": "apps", "computer_open_app": "open_app"}


def token():
    try:
        return open(os.path.join(SUPPORT, "token"), encoding="utf-8").read().strip()
    except OSError:
        return ""


def call_helper(action, args):
    body = dict(args, action=action, token=token())
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    for attempt in range(2):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except OSError:
            if attempt == 0:
                # 小程序没开：帮忙打开一次（口令文件也是它第一次启动时生成的）
                subprocess.run(["open", "-a", APP], capture_output=True)
                time.sleep(2.5)
                body["token"] = token()
                req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                             headers={"Content-Type": "application/json"})
    return {"error": f"连不上「{APP}」小程序。请确认它在运行（菜单栏能看到 🖱 AG）。"}


def fit_to_points(b64, w, h):
    """确保图片像素 = 屏幕“点”的尺寸（Retina 屏截出来是 2 倍），这样图上坐标可以直接拿去点击。"""
    import base64
    import re
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as f:
        f.write(base64.b64decode(b64))
        path = f.name
    try:
        info = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                              capture_output=True, text=True).stdout
        pw = int(re.search(r"pixelWidth: (\d+)", info).group(1))
        ph = int(re.search(r"pixelHeight: (\d+)", info).group(1))
        if (pw, ph) != (w, h):
            subprocess.run(["sips", "-z", str(h), str(w), path], capture_output=True)
            return base64.b64encode(open(path, "rb").read()).decode()
        return b64
    except (AttributeError, OSError, ValueError):
        return b64
    finally:
        os.remove(path)


LAST_FRONT = {"name": None}   # 最近一次截屏时最前面的软件
MUTATING = {"computer_click", "computer_drag", "computer_scroll", "computer_type", "computer_key", "computer_move"}


def front_app():
    """当前最前面的软件名（用系统自带的 lsappinfo，不需要任何权限）。"""
    try:
        asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=3).stdout.strip()
        out = subprocess.run(["lsappinfo", "info", "-only", "name", asn], capture_output=True, text=True, timeout=3).stdout
        # 输出第一行形如："Antigravity" ASN:0x0-0x338338: (in front)
        m = __import__("re").search(r'^\s*"([^"]+)"', out, __import__("re").M)
        return m.group(1) if m else None
    except (OSError, subprocess.SubprocessError):
        return None


def tool_result(name, args):
    # 安全检查：上次截屏之后前台软件变了（比如用户切了窗口），就不按旧截图去点，先重新看
    if name in MUTATING:
        now = front_app()
        if LAST_FRONT["name"] is None:
            return {"content": [{"type": "text", "text": "还没截过屏。请先调用 computer_screenshot 看清界面再操作。"}],
                    "isError": True}
        if now is None:   # 查不到前台软件时宁可不点
            return {"content": [{"type": "text", "text": "暂时查不到最前面是哪个软件，为了不点错，这一步没有执行。请重新截屏后再试。"}],
                    "isError": True}
        if now != LAST_FRONT["name"]:
            LAST_FRONT["name"] = None
            return {"content": [{"type": "text", "text": f"最前面的软件已经从「{LAST_FRONT.get('prev') or '截屏时的软件'}」"
                                 f"变成了「{now}」（可能是用户切换了窗口）。为了不点错，这一步没有执行。"
                                 "请先重新 computer_screenshot，必要时用 computer_open_app 切回目标软件。"}],
                    "isError": True}
    res = call_helper(ACTION[name], args)
    if name == "computer_screenshot" and not res.get("error"):
        LAST_FRONT["name"] = front_app() or res.get("frontmost")
        LAST_FRONT["prev"] = LAST_FRONT["name"]
    elif name == "computer_open_app" and not res.get("error"):
        LAST_FRONT["name"] = None  # 换了软件，必须重新截屏
    if res.get("error"):
        return {"content": [{"type": "text", "text": "失败：" + res["error"]}], "isError": True}
    if name == "computer_screenshot":
        res["image"] = fit_to_points(res["image"], res["width"], res["height"])
        info = f"截图 {res['width']}×{res['height']}，最前面的软件：{res.get('frontmost', '')}"
        return {"content": [{"type": "image", "data": res["image"], "mimeType": "image/jpeg"},
                            {"type": "text", "text": info}]}
    if name == "computer_list_apps":
        lines = [("★ " if a["frontmost"] else "  ") + f"{a['name']}（{a['bundle']}）" for a in res["apps"]]
        return {"content": [{"type": "text", "text": "\n".join(lines)}]}
    return {"content": [{"type": "text", "text": f"完成。现在最前面的软件：{res.get('frontmost', '')}。建议重新截屏确认。"}]}


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
                "serverInfo": {"name": "agy-mac-control", "version": "1.0"},
                "instructions": "用这些工具操作用户 Mac 上的软件。先截屏再操作；用户按 Esc 会立即暂停，"
                                "收到“暂停”错误时停止并告诉用户。登录、付款、发消息、删除前先问用户。"}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            p = msg.get("params") or {}
            name = p.get("name")
            if name not in ACTION:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": f"没有这个工具：{name}"}})
                continue
            send({"jsonrpc": "2.0", "id": mid, "result": tool_result(name, p.get("arguments") or {})})
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        else:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"不支持：{method}"}})


if __name__ == "__main__":
    main()
