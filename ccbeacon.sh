#!/usr/bin/env bash
# Reflect Claude Code state: iTerm2 tab color + minimal session state file.
# Token parsing happens in the notifier app (cached by transcript mtime).
# Daily totals are updated here on Stop only (once per session).
state="${1:-}"
TTY=/dev/tty
SESSIONS_DIR="$HOME/.claude/cc-sessions"
DAILY_FILE="$HOME/.claude/cc-daily.json"
ts=$(date +%s)

set_tab() {
  [ -w "$TTY" ] || return 0
  printf '\033]6;1;bg;red;brightness;%s\a'   "$1" >"$TTY" 2>/dev/null || true
  printf '\033]6;1;bg;green;brightness;%s\a' "$2" >"$TTY" 2>/dev/null || true
  printf '\033]6;1;bg;blue;brightness;%s\a'  "$3" >"$TTY" 2>/dev/null || true
}

json=$(cat 2>/dev/null || echo "{}")
echo "$json" | python3 -c "
import sys, json, os, fcntl

hook = {}
try:
    hook = json.load(sys.stdin)
except Exception:
    pass

state           = '$state'
ts              = $ts
sessions_dir    = '$SESSIONS_DIR'
session_id      = hook.get('session_id', 'default').replace('/', '_')
cwd             = hook.get('cwd', '')
transcript_path = hook.get('transcript_path', '')

# Walk up the parent chain to find the Claude Code (node/claude) process PID.
# Stored so the notifier can detect killed sessions via kill(pid, 0) instead of
# waiting for the 30-minute transcript-mtime stale timeout.
def _find_claude_pid():
    import subprocess as _sp
    pid = os.getppid()
    seen = set()
    for _ in range(8):
        if pid <= 1 or pid in seen:
            return 0
        seen.add(pid)
        try:
            out = _sp.check_output(['ps', '-o', 'ppid=,comm=', '-p', str(pid)],
                                   stderr=_sp.DEVNULL, text=True).strip()
            if not out:
                return 0
            parts = out.split(None, 1)
            ppid  = int(parts[0]) if parts else 0
            comm  = (parts[1] if len(parts) > 1 else '').lower().strip()
            if 'node' in comm or comm.startswith('claude'):
                return pid
            pid = ppid
        except Exception:
            return 0
    return 0

claude_pid = _find_claude_pid()

# Minimal state file — token details are read directly from the transcript by the notifier app
os.makedirs(sessions_dir, exist_ok=True)
session_file = os.path.join(sessions_dir, f'{session_id}.json')
lock_path    = session_file + '.lock'

# Serialize concurrent hook scripts (Notification and Stop can run simultaneously).
# flock ensures the read-check-write is atomic so 'done' can never be overwritten by 'waiting'.
with open(lock_path, 'w') as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)

    skip = False
    if state == 'waiting':
        try:
            with open(session_file) as f:
                prev = json.load(f)
            if prev.get('state') == 'done':
                skip = True
        except Exception:
            pass

    if not skip:
        with open(session_file, 'w') as f:
            json.dump({'state': state, 'ts': ts, 'session_id': session_id,
                       'cwd': cwd, 'transcript_path': transcript_path,
                       'claude_pid': claude_pid}, f)

# Daily totals: parse transcript once at Stop to avoid doing it on every prompt
if state == 'done':
    from datetime import date
    input_t = output_t = cache_c = cache_r = 0
    if transcript_path and os.path.exists(transcript_path):
        try:
            with open(transcript_path) as f:
                for line in f:
                    try:
                        e = json.loads(line)
                        if e.get('type') == 'assistant':
                            u = e.get('message', {}).get('usage', {})
                            input_t += u.get('input_tokens', 0)
                            output_t += u.get('output_tokens', 0)
                            cache_c  += u.get('cache_creation_input_tokens', 0)
                            cache_r  += u.get('cache_read_input_tokens', 0)
                    except Exception:
                        continue
        except Exception:
            pass

    total = input_t + output_t + cache_c + cache_r
    cost  = hook.get('total_cost_usd', 0.0)
    today = date.today().isoformat()

    try:
        with open('$DAILY_FILE') as f:
            daily = json.load(f)
    except Exception:
        daily = {}

    if daily.get('date') != today:
        daily = {'date': today, 'total_tokens': 0, 'total_cost': 0.0,
                 'input_tokens': 0, 'output_tokens': 0, 'cache_tokens': 0,
                 'sessions': 0, 'counted': []}

    if session_id not in daily.get('counted', []):
        daily['total_tokens']  = daily.get('total_tokens', 0)  + total
        daily['input_tokens']  = daily.get('input_tokens', 0)  + input_t
        daily['output_tokens'] = daily.get('output_tokens', 0) + output_t
        daily['cache_tokens']  = daily.get('cache_tokens', 0)  + cache_c + cache_r
        daily['total_cost']    = daily.get('total_cost', 0.0)  + cost
        daily['sessions']      = daily.get('sessions', 0)      + 1
        daily.setdefault('counted', []).append(session_id)
        daily['counted'] = daily['counted'][-500:]

    with open('$DAILY_FILE', 'w') as f:
        json.dump(daily, f)
" 2>/dev/null

case "$state" in
  working) set_tab 240 180 0 ;;
  waiting) set_tab 220 40 40 ;;
  done)    set_tab 40 160 80 ;;
esac
