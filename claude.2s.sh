#!/usr/bin/env bash
# <swiftbar.title>Claude Code</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.desc>Shows Claude Code task status</swiftbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>

STATE_FILE="$HOME/.claude/cc-state"
now=$(date +%s)

fmt_elapsed() {
  local s=$1
  if   (( s < 60 ));   then echo "${s}s"
  elif (( s < 3600 )); then echo "$(( s / 60 ))m"
  else                      echo "$(( s / 3600 ))h$(( (s % 3600) / 60 ))m"
  fi
}

if [[ ! -f "$STATE_FILE" ]]; then
  echo "claude | color=#666666 size=11 font=Menlo"
  exit 0
fi

read -r state ts < "$STATE_FILE"
ts=${ts:-$now}
elapsed=$(( now - ts ))

case "$state" in
  working)
    echo "⟳ $(fmt_elapsed $elapsed) | color=#F0B429 size=11 font=Menlo"
    echo "---"
    echo "Working… $(fmt_elapsed $elapsed) | color=#F0B429"
    ;;
  waiting)
    echo "✏️ input? | color=#FF5555 size=11 font=Menlo"
    echo "---"
    echo "Waiting for your input | color=#FF5555"
    echo "Since $(fmt_elapsed $elapsed) ago"
    ;;
  done)
    echo "✓ done | color=#50FA7B size=11 font=Menlo"
    echo "---"
    echo "Finished $(fmt_elapsed $elapsed) ago | color=#50FA7B"
    ;;
  *)
    echo "claude | color=#666666 size=11 font=Menlo"
    ;;
esac
