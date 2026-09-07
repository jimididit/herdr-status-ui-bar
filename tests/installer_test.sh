#!/bin/sh
# install.sh/uninstall.sh 픽스처 테스트 — 실제 HOME을 절대 건드리지 않는다.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

export HOME="$FIX/home"
export HERDR_CONFIG_DIR="$HOME/.config/herdr"
export CLAUDE_SETTINGS="$HOME/.claude/settings.json"
export HERDR_BIN_PATH=/usr/bin/false   # 테스트가 라이브 herdr 서버를 리로드하지 않게 차단
mkdir -p "$HERDR_CONFIG_DIR" "$HOME/.claude"

# 픽스처: 기존 tab_bar_right가 있는 config.toml + statusline이 있는 settings.json
cat > "$HERDR_CONFIG_DIR/config.toml" <<'EOF'
onboarding = false

[ui]
show_agent_labels_on_pane_borders = true
tab_bar_right = [
  { type = "zoom" },
  { type = "command", command = "curl -s 'wttr.in?format=%c'", interval_seconds = 600, timeout_seconds = 3 },
]
tab_bar_right_separator = " · "
EOF
cat > "$CLAUDE_SETTINGS" <<'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "bash -c 'echo \"my custom statusline\"'"
  }
}
EOF

# 1) 설치 — layout.toml엔 항상 카탈로그 3개가 모두 들어가고, 인식 안 되는 기존 항목
#    (zoom, 변형 wttr.in 커맨드)은 관리 대상이 아니므로 config에 원문 그대로 보존된다.
"$REPO/install.sh" > /dev/null
grep -c "agent-usage/agent_usage.py" "$HERDR_CONFIG_DIR/config.toml" | grep -qx 1 || fail "위젯 라인 1개가 아님"
grep -q 'tab_bar_right = \[' "$HERDR_CONFIG_DIR/config.toml" || fail "tab_bar_right 배열 훼손"
grep -q '{ type = "zoom" }' "$HERDR_CONFIG_DIR/config.toml" || fail "무관 위젯(zoom) 유실"
[ -x "$HERDR_CONFIG_DIR/agent-usage/agent_usage.py" ] || fail "스크립트 미설치"
[ -x "$HERDR_CONFIG_DIR/agent-usage/tab_id.py" ] || fail "tab_id.py 미설치"
[ -x "$HERDR_CONFIG_DIR/agent-usage/statusline-wrapper.sh" ] || fail "래퍼 미생성"
[ -f "$HERDR_CONFIG_DIR/agent-usage/layout.toml" ] || fail "layout.toml 미생성"
# layout.toml엔 세 블록이 모두 존재해야 한다 (설정 안 했어도 팝업에서 고를 수 있게).
for bid in agent-status weather herdr-tab-id; do
  grep -q "id = \"$bid\"" "$HERDR_CONFIG_DIR/agent-usage/layout.toml" || fail "layout.toml에 $bid 블록 없음"
done
grep -qx 'id = "custom"' "$HERDR_CONFIG_DIR/agent-usage/layout.toml" && fail "custom 블록이 남아있음 (3개만 있어야 함)" || true
# 변형 wttr.in 커맨드는 정확 일치가 아니므로 weather로 인식되지 않는다 → weather 블록은
# 꺼진 채로 있고, 변형 커맨드는 config에 그대로 보존된다 (원문 유실 방지).
grep -q "wttr.in?format=%c" "$HERDR_CONFIG_DIR/config.toml" || fail "변형 weather 커맨드 유실"
python3 -c "
import json,os,sys
s=json.load(open(os.environ['CLAUDE_SETTINGS']))
cmd=s['statusLine']['command']
sys.exit(0 if cmd.endswith('statusline-wrapper.sh') else 1)
" || fail "statusLine이 래퍼로 교체되지 않음"
grep -q "my custom statusline" "$HERDR_CONFIG_DIR/agent-usage/statusline-original.sh" || fail "원본 커맨드 사이드카 유실"
ls "$HERDR_CONFIG_DIR"/config.toml.bak-agent-usage-* >/dev/null 2>&1 || fail "config 백업 없음"
ls "$HOME/.claude"/settings.json.bak-agent-usage-* >/dev/null 2>&1 || fail "settings 백업 없음"

# 2) 래퍼 동작 — stdin 캡처 + 원본 실행 + publish
out=$(echo '{"rate_limits":{"five_hour":{"used_percentage":7}}}' | "$HERDR_CONFIG_DIR/agent-usage/statusline-wrapper.sh")
[ "$out" = "my custom statusline" ] || fail "래퍼가 원본 statusline을 실행하지 않음: got '$out'"
grep -q '"used_percentage": *7' "$HOME/.claude/.last-statusline.json" || fail "캡처 파일 미생성"

# 3) 멱등 — 재실행해도 중복·layout 재승격 없음
"$REPO/install.sh" > /dev/null
grep -c "agent-usage/agent_usage.py" "$HERDR_CONFIG_DIR/config.toml" | grep -qx 1 || fail "재실행 시 위젯 라인 중복"
grep -c "statusline-wrapper.sh" "$CLAUDE_SETTINGS" | grep -qx 1 || fail "재실행 시 래퍼 중복 래핑"
grep -c 'id = "agent-status"' "$HERDR_CONFIG_DIR/agent-usage/layout.toml" | grep -qx 1 || fail "재실행 시 layout 블록 중복"

# 4) 제거 — agent-status만 빼고 나머지(zoom, 변형 weather 커맨드)는 유지, statusline 원복
"$REPO/uninstall.sh" > /dev/null
grep -q "agent-usage/agent_usage.py" "$HERDR_CONFIG_DIR/config.toml" && fail "위젯 라인 잔존" || true
grep -q '{ type = "zoom" }' "$HERDR_CONFIG_DIR/config.toml" || fail "제거 후 무관 위젯(zoom) 유실"
grep -q "wttr.in?format=%c" "$HERDR_CONFIG_DIR/config.toml" || fail "제거 후 변형 weather 커맨드 유실"
grep -q "my custom statusline" "$CLAUDE_SETTINGS" || fail "statusLine 원복 실패 (원본 커맨드 부재)"
grep -q "statusline-wrapper.sh" "$CLAUDE_SETTINGS" && fail "statusLine 원복 실패 (래퍼 잔존)" || true
[ ! -f "$HERDR_CONFIG_DIR/agent-usage/agent_usage.py" ] || fail "agent_usage.py 잔존"
# herdr-tab-id 블록이 없었으므로 에셋 디렉토리 전체가 제거되어야 한다.
[ ! -d "$HERDR_CONFIG_DIR/agent-usage" ] || fail "에셋 디렉토리 잔존"

# 5) statusLine 없는 settings — 아무것도 만들지 않음
cat > "$HERDR_CONFIG_DIR/config.toml" <<'EOF'
[ui]
tab_bar_right = [
  { type = "zoom" },
]
EOF
printf '{}' > "$CLAUDE_SETTINGS"
"$REPO/install.sh" > /dev/null
python3 -c "
import json,os,sys
s=json.load(open(os.environ['CLAUDE_SETTINGS']))
sys.exit(0 if 'statusLine' not in s else 1)
" || fail "statusLine 없는 유저에게 statusline을 강제함"
"$REPO/uninstall.sh" > /dev/null

# 6) [ui]는 있는데 tab_bar_right가 없는 config — 배열 신설
cat > "$HERDR_CONFIG_DIR/config.toml" <<'EOF'
[ui]
show_agent_labels_on_pane_borders = true
EOF
"$REPO/install.sh" > /dev/null
grep -q 'tab_bar_right = \[' "$HERDR_CONFIG_DIR/config.toml" || fail "tab_bar_right 신설 실패"
grep -c "agent-usage/agent_usage.py" "$HERDR_CONFIG_DIR/config.toml" | grep -qx 1 || fail "신설 케이스 위젯 라인 이상"
# 아무 위젯도 없던 config: 세 블록 모두 layout.toml에 있되 agent-status만 켜져 있어야 한다.
python3 - "$HERDR_CONFIG_DIR/agent-usage/layout.toml" "$REPO" <<'PY' || fail "신설 케이스 기본 enabled 상태 이상"
import sys
sys.path.insert(0, sys.argv[2])
import layout as L
from pathlib import Path
blocks = {b["id"]: b.get("enabled") for b in L.load(Path(sys.argv[1]))}
assert set(blocks) == set(L.CATALOG_ORDER), blocks
assert blocks["agent-status"] is True, blocks
assert blocks["weather"] is False, blocks
assert blocks["herdr-tab-id"] is False, blocks
PY
python3 -c "
import tomllib,os
tomllib.load(open(os.environ['HERDR_CONFIG_DIR']+'/config.toml','rb'))
" 2>/dev/null || python3 -c "print('tomllib 없음(3.9/3.10) — TOML 파싱 검증 생략')"
"$REPO/uninstall.sh" > /dev/null

# 7) 비정형 config — 기존 위젯 command 문자열 안에 ']'가 있으면 자동 등록을 거부하고 config 무변경
cat > "$HERDR_CONFIG_DIR/config.toml" <<'EOF'
[ui]
tab_bar_right = [
  { type = "command", command = "echo hi] there", interval_seconds = 5, timeout_seconds = 2 },
]
EOF
cp "$HERDR_CONFIG_DIR/config.toml" "$FIX/before-weird.toml"
if "$REPO/install.sh" > "$FIX/weird-out.log" 2>&1; then
  # tomllib 없는 파이썬(3.9/3.10)에선 검증이 생략돼 통과할 수 있다 — tomllib이 있는데 성공했으면 실패
  python3 -c "import tomllib" 2>/dev/null && fail "비정형 config에서 성공 종료 (tomllib 검증 미작동)" || true
else
  cmp -s "$HERDR_CONFIG_DIR/config.toml" "$FIX/before-weird.toml" || fail "등록 실패 시 config가 변경됨 (무변경 보장 위반)"
  grep -q "herdr-status-ui-bar wanted to write" "$FIX/weird-out.log" || fail "수동 등록 안내 부재"
fi
rm -rf "$HERDR_CONFIG_DIR/agent-usage"

# 8) 경로 문자열이 든 무관한 주석 — 설치는 정상 진행되고, 제거는 주석을 안 건드린다
cat > "$HERDR_CONFIG_DIR/config.toml" <<'EOF'
[ui]
# NOTE: agent-usage/agent_usage.py is documented here — do not remove
tab_bar_right = [
  { type = "zoom" },
]
EOF
"$REPO/install.sh" > /dev/null
grep -c 'command = "~/.config/herdr/agent-usage/agent_usage.py"' "$HERDR_CONFIG_DIR/config.toml" | grep -qx 1 || fail "주석 존재 시 설치 안 됨 (거짓 멱등)"
"$REPO/uninstall.sh" > /dev/null
grep -q "# NOTE: agent-usage/agent_usage.py is documented here" "$HERDR_CONFIG_DIR/config.toml" || fail "무관 주석 오삭제"
grep -q 'command = "~/.config/herdr/agent-usage/agent_usage.py"' "$HERDR_CONFIG_DIR/config.toml" && fail "위젯 라인 잔존" || true

# 9) 옛 경로 + 새 경로 agent_usage.py 중복 — 하나로 합쳐진다(레이아웃 승격 시 dedup)
cat > "$HERDR_CONFIG_DIR/config.toml" <<'EOF'
[ui]
tab_bar_right = [
  { type = "zoom" },
  { type = "command", command = "~/.config/herdr/agent_usage.py", interval_seconds = 300, timeout_seconds = 5 },
  { type = "command", command = "~/.config/herdr/agent-usage/agent_usage.py", interval_seconds = 300, timeout_seconds = 5 },
]
EOF
AGENT_USAGE_SKIP_CLAUDE=1 "$REPO/install.sh" > /dev/null
grep -c "agent_usage.py" "$HERDR_CONFIG_DIR/config.toml" | grep -qx 1 || fail "중복/옛 경로가 하나로 정리되지 않음"
grep -q 'command = "~/.config/herdr/agent-usage/agent_usage.py"' "$HERDR_CONFIG_DIR/config.toml" || fail "정규(새 경로) 위젯으로 대체되지 않음"
grep -q 'command = "~/.config/herdr/agent_usage.py"' "$HERDR_CONFIG_DIR/config.toml" && fail "옛 경로 항목 잔존" || true
grep -q '{ type = "zoom" }' "$HERDR_CONFIG_DIR/config.toml" || fail "무관 위젯(zoom) 오삭제"
python3 -c "import tomllib" 2>/dev/null && python3 -c "
import tomllib,os
tomllib.load(open(os.environ['HERDR_CONFIG_DIR']+'/config.toml','rb'))
" || true
# 재실행 멱등 — 이미 정규화됐으면 변화 없음
AGENT_USAGE_SKIP_CLAUDE=1 "$REPO/install.sh" > /dev/null
grep -c "agent_usage.py" "$HERDR_CONFIG_DIR/config.toml" | grep -qx 1 || fail "정규화 후 재실행이 중복을 만듦"

# 10) 옛 jq 기반 herdr-tab-id 위젯이 있으면 승격되고, 이후 tab_bar_right는 jq 없는
#     tab_id.py를 가리킨다 — 그리고 uninstall 후에도 그 블록이 켜져 있으면 tab_id.py가 남는다
rm -rf "$HERDR_CONFIG_DIR/agent-usage"
cat > "$HERDR_CONFIG_DIR/config.toml" <<'EOF'
[ui]
tab_bar_right = [
  { type = "command", command = "herdr api snapshot 2>/dev/null | jq -r '.result.snapshot.focused_pane_id'", interval_seconds = 2, timeout_seconds = 2 },
]
EOF
AGENT_USAGE_SKIP_CLAUDE=1 "$REPO/install.sh" > /dev/null
grep -q 'id = "herdr-tab-id"' "$HERDR_CONFIG_DIR/agent-usage/layout.toml" || fail "herdr-tab-id 승격 실패"
grep -q "agent-usage/tab_id.py" "$HERDR_CONFIG_DIR/config.toml" || fail "jq 위젯이 tab_id.py로 대체되지 않음"
grep -q "jq" "$HERDR_CONFIG_DIR/config.toml" && fail "jq 의존 커맨드가 config.toml에 남음" || true
"$REPO/uninstall.sh" > /dev/null
[ -f "$HERDR_CONFIG_DIR/agent-usage/tab_id.py" ] || fail "herdr-tab-id가 켜져 있는데 tab_id.py가 삭제됨"
[ ! -f "$HERDR_CONFIG_DIR/agent-usage/agent_usage.py" ] || fail "uninstall 후 agent_usage.py 잔존"
grep -q "agent-usage/tab_id.py" "$HERDR_CONFIG_DIR/config.toml" || fail "uninstall 후 herdr-tab-id 위젯 라인 유실"

echo "PASS (10/10)"
