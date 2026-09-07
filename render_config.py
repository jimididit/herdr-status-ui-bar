#!/usr/bin/env python3
"""layout.toml의 블록들을 herdr config.toml의 [ui].tab_bar_right 배열로 렌더한다.

이 모듈이 tab_bar_right 배열 전체를 소유한다 — 매번 layout.toml에서 처음부터 다시
쓴다. 쓰기 전 tomllib(있으면)으로 결과를 검증하고, 기존 install.sh와 동일하게
바꾸기 전 config.toml을 `*.bak-agent-usage-<timestamp>`로 백업한다.
"""
from __future__ import annotations

import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

import layout as L


class RenderError(Exception):
    pass


def find_array_span(text: str, key: str = "tab_bar_right") -> tuple[int, int, int] | None:
    """`key = [...]`의 (key_start, content_start, content_end) 위치. 못 찾으면 None.

    content_end는 닫는 ']'의 인덱스(그 문자는 포함하지 않는 범위 끝)다.
    괄호 카운터라 항목 문자열 안에 `[`/`]`가 있으면 다루지 못한다 — README에 명시된
    기존 한계 그대로.
    """
    match = re.search(rf"{key}\s*=\s*\[", text)
    if not match:
        return None
    depth, pos = 1, match.end()
    while pos < len(text) and depth:
        if text[pos] == "[":
            depth += 1
        elif text[pos] == "]":
            depth -= 1
        pos += 1
    if depth:
        return None
    return (match.start(), match.end(), pos - 1)


def preserved_entries(text: str, weather_enabled: bool) -> list[str]:
    """기존 tab_bar_right에서 이 플러그인이 관리하지 않는 항목의 원문을 순서대로 반환한다.

    - 이 플러그인이 만든(또는 예전 형식) 항목은 항상 제거 대상(우리가 다시 쓴다).
    - wttr.in을 쓰는 사용자 변형 weather 커맨드는 weather 블록이 켜질 때만 제거 대상
      (그때 정규 weather로 대체) — 꺼져 있으면 사용자 것이므로 그대로 보존한다.
    """
    span = find_array_span(text)
    if span is None:
        return []
    _, content_start, content_end = span
    kept: list[str] = []
    for raw in L.split_array_entries(text[content_start:content_end]):
        parsed = L.parse_inline_table(raw)
        cmd = parsed.get("command", "") if isinstance(parsed, dict) and parsed.get("type") == "command" else None
        if cmd is not None:
            if L.is_managed_strict(cmd):
                continue
            if weather_enabled and L.is_weather_broad(cmd):
                continue
        kept.append(raw)
    return kept


def build_array_body(blocks: list[dict], preserved: list[str] | None = None) -> str:
    """비관리 항목(원문 보존)들을 먼저 두고, 켜진 카탈로그 블록을 그 뒤에 이어 붙인다."""
    preserved = preserved or []
    enabled = [b for b in blocks if b.get("enabled", True)]
    lines = [f"  {raw.rstrip(',').strip()},\n" for raw in preserved]
    lines += [f"  {L.widget_toml(b)},\n" for b in enabled]
    return "".join(lines)


def _validate(new_text: str, body: str) -> None:
    try:
        import tomllib
    except ImportError:
        return
    try:
        tomllib.loads(new_text)
    except tomllib.TOMLDecodeError as exc:
        raise RenderError(
            "could not update tab_bar_right automatically (unusual config.toml layout: "
            f"{exc}).\nYour config.toml was left unchanged. This is the array "
            f"herdr-status-ui-bar wanted to write:\ntab_bar_right = [\n{body}]"
        )


def regenerate(config_path: Path, blocks: list[dict]) -> str:
    """config_path의 [ui].tab_bar_right를 blocks에서 다시 만들어 쓴다.

    관리하지 않는 기존 항목(zoom, 사용자 스크립트 등)은 원문 그대로 앞쪽에 보존하고,
    켜진 카탈로그 블록만 그 뒤에 이어 붙인다.
    """
    blocks = L.canonical_layout(blocks)
    text = config_path.read_text() if config_path.exists() else ""
    weather_enabled = any(b["id"] == "weather" and b.get("enabled", True) for b in blocks)
    preserved = preserved_entries(text, weather_enabled)
    body = build_array_body(blocks, preserved)

    span = find_array_span(text)
    if span is not None:
        _, content_start, content_end = span
        new_text = text[:content_start] + "\n" + body + text[content_end:]
    elif re.search(r"tab_bar_right\s*=\s*\[", text):
        raise RenderError("tab_bar_right array is not closed — fix config.toml first")
    elif re.search(r"^\[ui\]\s*$", text, re.M):
        insert_at = re.search(r"^\[ui\]\s*$", text, re.M).end()
        new_text = text[:insert_at] + f"\ntab_bar_right = [\n{body}]\n" + text[insert_at:]
    elif text.strip():
        new_text = text.rstrip("\n") + f"\n\n[ui]\ntab_bar_right = [\n{body}]\n"
    else:
        new_text = f"[ui]\ntab_bar_right = [\n{body}]\n"

    if new_text == text:
        return "config.toml: tab_bar_right already up to date — skipped"

    _validate(new_text, body)

    if config_path.exists():
        stamp = datetime.now().strftime("%Y%m%d%H%M%S")
        shutil.copy2(config_path, f"{config_path}.bak-agent-usage-{stamp}")
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(new_text)
    return "config.toml: tab_bar_right updated"


def reload_herdr(herdr_bin: str = "herdr") -> bool:
    import subprocess

    try:
        proc = subprocess.run([herdr_bin, "server", "reload-config"], capture_output=True, timeout=5)
        return proc.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: render_config.py CONFIG_TOML LAYOUT_TOML [--reload]", file=sys.stderr)
        return 2
    config_path, layout_path = Path(argv[0]), Path(argv[1])
    blocks = L.load(layout_path)
    try:
        print(regenerate(config_path, blocks))
    except RenderError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if "--reload" in argv[2:]:
        print("herdr: config reloaded" if reload_herdr() else "herdr: reload skipped (server not running?)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
