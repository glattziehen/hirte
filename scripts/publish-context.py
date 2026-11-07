#!/usr/bin/env python3
"""Publish allowlisted host context for selected local Herdr terminals.

Run on the core machine: python3 scripts/publish-context.py --terminal t7 --watch
Only display metadata is published. Provider credentials never leave this process.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time

AGENTS = {"codex", "claude", "claude-code", "grok", "muse", "kimi", "opencode", "pi"}


def run(args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          text=True, timeout=5, check=False)


def clean(value):
    if not isinstance(value, str):
        return ""
    return "".join(c for c in value if c.isprintable()).strip()[:512]


def profile_name(value):
    name = Path(value.rstrip("/")).name
    for prefix in (".claude-", ".codex-"):
        if name.startswith(prefix):
            return clean(name[len(prefix):])
    return "Personal" if name in (".claude", ".codex") else clean(name.lstrip("."))


def account_for(pid, agent):
    profile_key = "CODEX_HOME" if agent == "codex" else "CLAUDE_CONFIG_DIR" if agent in ("claude", "claude-code") else None
    if type(pid) is not int or pid <= 0 or profile_key is None:
        return ""
    try:
        environ = Path("/proc") / str(pid) / "environ"
        if environ.is_file():
            # Read locally, retain only the two non-secret profile paths.
            entries = environ.read_bytes().decode("utf-8", errors="replace").split("\0")
            for entry in entries:
                key, _, value = entry.partition("=")
                if key == profile_key and value:
                    return profile_name(value)
            return "Personal"
        result = run(["/bin/ps", "eww", "-o", "command=", "-p", str(pid)])
        if result.returncode != 0 or not result.stdout.strip():
            return ""
        match = re.search(r"(?:^|\s)" + profile_key + r"=(\S+)", result.stdout)
        return profile_name(match[1]) if match else "Personal"
    except (OSError, subprocess.SubprocessError):
        return ""


def branch_for(directory):
    if not directory:
        return ""
    try:
        got = run(["git", "-C", directory, "symbolic-ref", "--quiet", "--short", "HEAD"])
        if got.returncode == 0:
            return clean(got.stdout)
        got = run(["git", "-C", directory, "rev-parse", "--short", "HEAD"])
        return "Detached " + clean(got.stdout) if got.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def context_for(terminal):
    foreground = terminal.get("foreground") or {}
    directory = clean(foreground.get("cwd") or terminal.get("cwd"))
    labels = terminal.get("labels") or {}
    agent = clean((terminal.get("status") or {}).get("app"))
    if not agent:
        candidate = clean(foreground.get("name"))
        agent = candidate if candidate in AGENTS else ""
    where = clean(labels.get("where"))
    project = where.split(" / ", 1)[0] if where else Path(directory).name
    return {
        "context.directory": directory,
        "context.project": project,
        "context.branch": branch_for(directory),
        "context.agent": agent,
        "context.account": account_for(foreground.get("pid"), agent),
        "context.created_ms": str(terminal.get("created_ms", 0)),
    }


def publish(address):
    if not re.fullmatch(r"t[0-9a-z]+", address):
        raise ValueError("Use a local terminal address; run this publisher on its core machine.")
    got = run(["hc", "get", address, "--json"])
    if got.returncode:
        return False
    terminal = json.loads(got.stdout)
    if terminal.get("state") != "live":
        return False
    values = context_for(terminal)
    existing = terminal.get("labels") or {}
    if all(existing.get(key, "") == value for key, value in values.items()):
        return True
    # argv, not shell interpolation: directories and labels cannot execute commands.
    result = run(["hc", "label", address] + [key + "=" + value for key, value in values.items()])
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--terminal", action="append", required=True,
                        help="Local terminal to update; repeat for multiple terminals.")
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--interval", type=float, default=15)
    args = parser.parse_args()
    if args.interval < 5:
        parser.error("--interval must be at least 5 seconds")
    while True:
        ok = True
        for address in args.terminal:
            try:
                ok = publish(address) and ok
            except (ValueError, json.JSONDecodeError, OSError, subprocess.SubprocessError):
                # No command output/environment is logged, including on failure.
                print("Could not update context for the selected terminal.", file=sys.stderr)
                ok = False
        if not args.watch:
            return 0 if ok else 1
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
