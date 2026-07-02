#!/usr/bin/env bash
# Reflect Claude Code state: iTerm2 tab color + session state file.
state="${1:-}"
TTY=/dev/tty
SESSIONS_DIR="$HOME/.claude/cc-sessions"
ts=$(date +%s)

# 2>/dev/null must come before >"$TTY": redirections apply left to right, so a failed
# tty open is silenced instead of spamming stderr when there is no controlling terminal.
set_tab() {
  [ -w "$TTY" ] || return 0
  printf '\033]6;1;bg;red;brightness;%s\a'   "$1" 2>/dev/null >"$TTY" || true
  printf '\033]6;1;bg;green;brightness;%s\a' "$2" 2>/dev/null >"$TTY" || true
  printf '\033]6;1;bg;blue;brightness;%s\a'  "$3" 2>/dev/null >"$TTY" || true
}

reset_tab() {
  [ -w "$TTY" ] || return 0
  printf '\033]6;1;bg;*;default\a' 2>/dev/null >"$TTY" || true
}

json=$(cat 2>/dev/null || echo "{}")

# Values reach Python via the environment (not shell interpolation), so paths or hook
# fields containing quotes cannot break or inject into the Python source.
# Python prints the effective state ("" when the write was skipped); the shell then
# colors the tab to match what was actually recorded.
effective=$(printf '%s' "$json" | CCB_STATE="$state" CCB_TS="$ts" CCB_DIR="$SESSIONS_DIR" python3 -c '
import sys, json, os, fcntl

hook = {}
try:
    hook = json.load(sys.stdin)
except Exception:
    pass

state           = os.environ.get("CCB_STATE", "")
ts              = int(os.environ.get("CCB_TS", "0") or 0)
sessions_dir    = os.environ.get("CCB_DIR", "")
event           = hook.get("hook_event_name", "")
session_id      = str(hook.get("session_id", "default")).replace("/", "_")
cwd             = hook.get("cwd", "")
transcript_path = hook.get("transcript_path", "")

# Walk the process tree to find the Claude PID, hosting terminal app, and TTY device.
# TTY is read from "ps -o tty=" for the Claude process -- the hook process itself has
# all fds redirected (stdin piped, stderr to /dev/null), so its own tty is useless.
def _find_session_info():
    import subprocess as _sp
    pid = os.getppid()
    seen = set()
    claude_pid = 0
    terminal = ""
    tty_device = ""
    for _ in range(12):
        if pid <= 1 or pid in seen:
            break
        seen.add(pid)
        try:
            out = _sp.check_output(["ps", "-o", "ppid=,tty=,comm=", "-p", str(pid)],
                                   stderr=_sp.DEVNULL, text=True).strip()
            if not out:
                break
            parts = out.split(None, 2)
            ppid  = int(parts[0]) if parts else 0
            tty   = parts[1] if len(parts) > 1 else ""
            comm  = (parts[2] if len(parts) > 2 else "").lower().strip()
            if not claude_pid and ("node" in comm or comm.startswith("claude")):
                claude_pid = pid
                if tty and tty != "??":
                    if tty.startswith("/dev/"):
                        tty_device = tty
                    elif tty.startswith("ttys"):
                        tty_device = "/dev/" + tty
                    else:
                        tty_device = "/dev/tty" + tty
            if not terminal:
                if "iterm2" in comm:     terminal = "iTerm2"
                elif comm == "terminal": terminal = "Terminal"
            pid = ppid
        except Exception:
            break
    return claude_pid, terminal, tty_device

claude_pid, terminal_app, tty_device = _find_session_info()

os.makedirs(sessions_dir, exist_ok=True)
session_file = os.path.join(sessions_dir, f"{session_id}.json")
lock_path    = session_file + ".lock"

# Serialize concurrent hook scripts (Notification and Stop can run simultaneously).
# flock ensures the read-check-write is atomic so a stale state can never win the race.
with open(lock_path, "w") as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)

    # SessionEnd means the session is over (quit, not finished): remove the state file
    # so the app drops the session immediately and never chimes "finished" for a quit.
    if event == "SessionEnd":
        for p in (session_file, lock_path):
            try:
                os.remove(p)
            except OSError:
                pass
        print("ended")
        sys.exit(0)

    skip = False
    prev_state = ""
    try:
        with open(session_file) as f:
            prev = json.load(f)
            prev_state = prev.get("state", "")
            if claude_pid == 0:       claude_pid    = prev.get("claude_pid", 0)
            if not tty_device:        tty_device    = prev.get("tty", "")
            if not terminal_app:      terminal_app  = prev.get("terminal", "")
    except Exception:
        pass

    if state == "waiting":
        if prev_state == "done":
            skip = True
    elif state == "idle":
        if prev_state in ("working", "waiting"):
            skip = True

    if not skip:
        # Write to a temp file and rename: the rename is atomic, so the app (which reads
        # without the lock) never sees a truncated file, and the directory watcher gets
        # an event for every state change.
        tmp = session_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"state": state, "ts": ts, "session_id": session_id,
                       "cwd": cwd, "transcript_path": transcript_path,
                       "claude_pid": claude_pid, "tty": tty_device,
                       "terminal": terminal_app}, f)
        os.replace(tmp, session_file)
        print(state)
' 2>/dev/null)

case "$effective" in
  working) set_tab 240 180 0 ;;
  waiting) set_tab 220 40 40 ;;
  done)    set_tab 40 160 80 ;;
  idle)    reset_tab ;;
  ended)   reset_tab ;;
esac
