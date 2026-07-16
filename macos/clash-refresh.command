#!/bin/zsh

set -u

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
LOG_FILE="${TMPDIR:-/tmp}/clash-refresh-node.log"

find_node() {
  local candidate
  for candidate in "${NODE_BINARY:-}" /opt/homebrew/bin/node /usr/local/bin/node "$(command -v node 2>/dev/null)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

NODE="$(find_node)" || {
  osascript -e 'display notification "请先安装 Node.js 18 或更高版本" with title "Clash 节点切换失败"'
  exit 1
}

cd "$PROJECT_DIR" || exit 1
"$NODE" index.js "$@" >"$LOG_FILE" 2>&1
STATUS=$?

if [[ "${CLASH_REFRESH_NO_NOTIFY:-0}" == "1" ]]; then
  exit $STATUS
elif [[ $STATUS -eq 0 ]]; then
  MESSAGE="$(tail -n 1 "$LOG_FILE" | cut -c 1-180)"
  osascript - "$MESSAGE" <<'APPLESCRIPT'
on run argv
  display notification (item 1 of argv) with title "Clash 节点已刷新"
end run
APPLESCRIPT
else
  MESSAGE="$(tail -n 1 "$LOG_FILE" | cut -c 1-180)"
  osascript - "$MESSAGE" <<'APPLESCRIPT'
on run argv
  display notification (item 1 of argv) with title "Clash 节点切换失败"
end run
APPLESCRIPT
fi

exit $STATUS
