#!/bin/sh
# install-claude-desktop.sh -- register a Wantzel MCP server with Claude Desktop
# on Windows, from inside WSL.
#
#   ./install-claude-desktop.sh /home/you/project
#       Claude starts the server itself, over stdio.  Simplest, and what you
#       want unless you have a reason not to.
#
#   ./install-claude-desktop.sh --service /home/you/project [port]
#       Runs the server as a background systemd user service on that port and
#       registers the stdio->HTTP bridge with Claude.  The server then keeps
#       running between Claude sessions and other clients can share it.
#
# Why the bridge: Claude Desktop refuses http:// custom connector URLs even on
# localhost, and claude_desktop_config.json only accepts stdio servers.  The
# bridge is a stdio program, so Claude is happy, and it forwards to the HTTP
# server over one keep-alive connection.
set -e
cd "$(dirname "$0")"
HERE=$(pwd)

MODE=stdio
if [ "$1" = "--service" ]; then MODE=service; shift; fi

ROOT=${1:-$HERE}
PORT=${2:-8099}
NAME=wantzel-files

case "$ROOT" in
    /*) ;;
    *) echo "give the root as an absolute path, e.g. /home/$USER/project" >&2; exit 1 ;;
esac
[ -d "$ROOT" ] || { echo "no such directory: $ROOT" >&2; exit 1; }

# 1. build
[ -x ./bin/wantzel ] || ./build.sh >/dev/null
./bin/wantzel examples/mcpfiles.wz bin/mcpfiles
./bin/wantzel examples/mcpbridge.wz bin/mcpbridge
echo "built mcpfiles and mcpbridge"

# 2. prove the server speaks MCP before touching any configuration
REPLY=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
        | ./mcpfiles "$ROOT" | head -1)
case "$REPLY" in
    *'"serverInfo"'*) echo "handshake ok" ;;
    *) echo "the server did not answer an initialize; not touching the config" >&2
       echo "got: $REPLY" >&2; exit 1 ;;
esac

# 3. in service mode, run the HTTP server under systemd and use the bridge
if [ "$MODE" = service ]; then
    UNIT="$HOME/.config/systemd/user/wantzel-mcp.service"
    mkdir -p "$(dirname "$UNIT")"
    cat > "$UNIT" <<UNITEOF
[Unit]
Description=Wantzel MCP file server
After=default.target

[Service]
ExecStart=$HERE/mcpfiles $ROOT $PORT
Restart=on-failure
RestartSec=1

[Install]
WantedBy=default.target
UNITEOF
    if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
        systemctl --user daemon-reload
        systemctl --user enable --now wantzel-mcp.service
        sleep 1
        if systemctl --user is-active --quiet wantzel-mcp.service; then
            echo "service wantzel-mcp running on port $PORT (serving $ROOT)"
        else
            echo "the service did not start; check: systemctl --user status wantzel-mcp" >&2
            exit 1
        fi
    else
        echo "systemd user services are not available here." >&2
        echo "start the server yourself instead:  $HERE/mcpfiles $ROOT $PORT &" >&2
        exit 1
    fi
    CMDBIN="$HERE/mcpbridge"
    CMDARG="$PORT"
else
    CMDBIN="$HERE/mcpfiles"
    CMDARG="$ROOT"
fi

# 4. find the Windows-side configuration
WINUSER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')
CFG="/mnt/c/Users/$WINUSER/AppData/Roaming/Claude/claude_desktop_config.json"
if [ ! -d "$(dirname "$CFG")" ]; then
    echo "cannot find Claude Desktop's configuration directory:" >&2
    echo "  $(dirname "$CFG")" >&2
    exit 1
fi

DISTRO=${WSL_DISTRO_NAME:-Ubuntu}

# 5. merge the entry in, keeping everything else untouched
python3 - "$CFG" "$NAME" "$DISTRO" "$CMDBIN" "$CMDARG" <<'PY'
import json, os, shutil, sys, datetime
cfg, name, distro, binary, arg = sys.argv[1:6]
data = {}
if os.path.exists(cfg):
    backup = cfg + "." + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + ".bak"
    shutil.copy2(cfg, backup)
    print("backed up to", os.path.basename(backup))
    with open(cfg, encoding="utf-8") as f:
        text = f.read().strip()
    if text:
        data = json.loads(text)
data.setdefault("mcpServers", {})[name] = {
    "command": r"C:\Windows\System32\wsl.exe",
    "args": ["-d", distro, "-e", binary, arg],
}
with open(cfg, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("registered '%s' -> %s %s" % (name, binary, arg))
PY

echo
echo "Restart Claude Desktop, then ask it something like:"
echo "  \"list the directory\"  or  \"search for epoll in my files\""
echo
echo "To remove it again, delete the \"$NAME\" entry from:"
echo "  $CFG"
if [ "$MODE" = service ]; then
    echo "and stop the server with:  systemctl --user disable --now wantzel-mcp"
fi
