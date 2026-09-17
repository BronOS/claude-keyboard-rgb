#!/bin/bash
# Build kbstatus, install it to ~/.local/bin, and add the Claude Code hooks.
# Idempotent: safe to re-run after pulling changes. Pass --uninstall to remove hooks + binary.
set -euo pipefail
cd "$(dirname "$0")"
BIN="$HOME/.local/bin/kbstatus"
SETTINGS="$HOME/.claude/settings.json"

if [[ "${1:-}" == "--uninstall" ]]; then
  "$BIN" stop 2>/dev/null || true
  python3 - "$SETTINGS" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p))
for ev,lst in list(s.get('hooks',{}).items()):
    s['hooks'][ev]=[e for e in lst if not any('kbstatus' in h.get('command','') for h in e.get('hooks',[]))]
    if not s['hooks'][ev]: del s['hooks'][ev]
json.dump(s,open(p,'w'),indent=2); open(p,'a').write('\n'); print("hooks removed")
PY
  rm -f "$BIN"; echo "binary removed; config left in ~/.config/kbstatus"; exit 0
fi

command -v xcrun >/dev/null && xcrun swiftc --version >/dev/null 2>&1 || { echo "swiftc missing: run 'xcode-select --install' first"; exit 1; }
echo "building..."; (cd kbstatus && xcrun swiftc -O -o kbstatus core.swift main.swift)
mkdir -p "$HOME/.local/bin" "$HOME/.config/kbstatus"
# replace by rename: overwriting a running signed binary in place gets new invocations killed by macOS
cp kbstatus/kbstatus "$BIN.new" && mv -f "$BIN.new" "$BIN"; echo "installed $BIN"
[[ -f "$HOME/.config/kbstatus/config.hex" ]] || { cp kbstatus/config.hex.example "$HOME/.config/kbstatus/config.hex"; echo "seeded keyboard config cache (F87 Pro); the daemon re-reads it from the keyboard if it doesn't match"; }
"$BIN" stop 2>/dev/null || true   # restart the daemon on the next hook call

mkdir -p "$HOME/.claude"; [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-kbstatus"
python3 - "$SETTINGS" "$BIN" <<'PY'
import json,sys
p,K=sys.argv[1],sys.argv[2]; s=json.load(open(p)); hooks=s.setdefault('hooks',{})
plan=[("UserPromptSubmit","working",None),("PostToolUse","working",None),("Stop","done",None),
      ("Notification","attention","permission_prompt"),("PreToolUse","attention","AskUserQuestion"),("SessionEnd","end",None)]
for ev,state,m in plan:
    lst=hooks.setdefault(ev,[])
    if any('kbstatus' in h.get('command','') for e in lst if e.get('matcher')==m for h in e.get('hooks',[])): continue
    e={"hooks":[{"type":"command","command":f"'{K}' {state}","timeout":5}]}
    if m: e["matcher"]=m
    lst.append(e); print(f"hook added: {ev}{' ['+m+']' if m else ''} -> kbstatus {state}")
json.dump(s,open(p,'w'),indent=2); open(p,'a').write('\n')
PY

cat <<EOT

Done. Next:
  1. Pair the keyboard over Bluetooth (or plug in its dongle) and make sure it's connected.
  2. Run:  $BIN working --session test
     macOS will ask for Input Monitoring permission for your terminal app; allow it, then re-run.
     Esc + F-row should pulse blue.  Then:  $BIN end --session test
  3. Open a new Claude Code session (existing ones need /hooks opened once to reload).
Config: ~/.config/kbstatus/config.json (see README)   Log: ~/.cache/kbstatus/daemon.log
EOT
