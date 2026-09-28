#!/bin/bash
# Linux: install kbstrip to ~/.local/bin and add the Claude Code hooks (same hook plan as the macOS
# install.sh, minus the keyboard). Idempotent. --uninstall removes the hooks and the binary.
set -euo pipefail
cd "$(dirname "$0")"
BIN="$HOME/.local/bin/kbstrip"
SETTINGS="$HOME/.claude/settings.json"
CFG="$HOME/.config/kbstatus/config.json"

if [[ "${1:-}" == "--uninstall" ]]; then
  "$BIN" stop 2>/dev/null || true
  python3 - "$SETTINGS" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p))
for ev,lst in list(s.get('hooks',{}).items()):
    s['hooks'][ev]=[e for e in lst if not any('kbstrip' in h.get('command','') for h in e.get('hooks',[]))]
    if not s['hooks'][ev]: del s['hooks'][ev]
json.dump(s,open(p,'w'),indent=2); open(p,'a').write('\n'); print("hooks removed")
PY
  rm -f "$BIN"; echo "binary removed; config left in $CFG"; exit 0
fi

command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }
mkdir -p "$HOME/.local/bin" "$(dirname "$CFG")"
cp kbstrip.py "$BIN.new" && chmod +x "$BIN.new" && mv -f "$BIN.new" "$BIN"; echo "installed $BIN"
"$BIN" stop 2>/dev/null || true   # the next hook call starts the new daemon
[[ -f "$CFG" ]] || { cp config.example.json "$CFG"; echo "seeded $CFG — set strip.host and strip.leds"; }

mkdir -p "$HOME/.claude"; [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-kbstrip"
python3 - "$SETTINGS" "$BIN" <<'PY'
import json,sys
p,K=sys.argv[1],sys.argv[2]; s=json.load(open(p)); hooks=s.setdefault('hooks',{})
plan=[("UserPromptSubmit","working",None),("PostToolUse","working",None),("Stop","done",None),
      ("Notification","attention","permission_prompt"),("PreToolUse","attention","AskUserQuestion"),("SessionEnd","end",None)]
for ev,state,m in plan:
    lst=hooks.setdefault(ev,[])
    if any('kbstrip' in h.get('command','') for e in lst if e.get('matcher')==m for h in e.get('hooks',[])): continue
    e={"hooks":[{"type":"command","command":f"'{K}' {state}","timeout":5}]}
    if m: e["matcher"]=m
    lst.append(e); print(f"hook added: {ev}{' ['+m+']' if m else ''} -> kbstrip {state}")
json.dump(s,open(p,'w'),indent=2); open(p,'a').write('\n')
PY

cat <<EOT

Done. Next:
  1. Edit $CFG: strip.host = the WLED board's IP, strip.leds = LED count.
  2. Test:  $BIN strip-test        (red, green, blue sweep, then off)
  3. Open a new Claude Code session (existing ones need /hooks opened once to reload).
     $BIN status shows the daemon; log: ~/.cache/kbstrip/daemon.log
EOT
