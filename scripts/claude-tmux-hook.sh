#!/usr/bin/env zsh
# Claude Code hook handler feeding the tmux Claude session manager
# (scripts/claude-sessions.sh, prefix + a). Registered in ~/.claude/settings.json
# for SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification,
# Stop and SessionEnd.
#
# It writes ~/.cache/claude-tmux/state/<claude-pid>.json with what the
# instance is doing (working / waiting / idle, last prompt, current tool).
# It only adds detail to the list: which sessions appear is decided by
# claude-sessions.sh from live processes and panes.
#
# Rules for a hook: print nothing to stdout (some events feed stdout back into
# Claude's context), stay fast, and always exit 0.

input=$(cat)
[[ -z "$TMUX_PANE" ]] && exit 0
command -v jq >/dev/null || exit 0

STATE_DIR="$HOME/.cache/claude-tmux/state"
[[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# Find the claude process that ran this hook by walking up our parents. The
# chain is short (claude → sh → this script), so a few targeted ps calls are
# much cheaper than listing every process.
zmodload zsh/datetime
claude_pid=""
p=$PPID
for _ in {1..8}; do
  [[ -z "$p" || "$p" -le 1 ]] && break
  info=$(ps -o ppid=,comm= -p "$p" 2>/dev/null) || break
  info=${info## #}
  if [[ "${${info#* }:t}" == claude ]]; then claude_pid=$p; break; fi
  p=${info%% *}
done
[[ -z "$claude_pid" ]] && exit 0

state="$STATE_DIR/$claude_pid.json"
old='{}'
[[ -f "$state" ]] && old=$(<"$state")

new=$(print -r -- "$input" | jq -c -n \
  --arg oldraw "$old" \
  --argjson pid "$claude_pid" \
  --arg pane "$TMUX_PANE" \
  --argjson now "$EPOCHSECONDS" '
  input as $in
  | (try ($oldraw | fromjson) catch {}) as $old
  | def clip($n): tostring | gsub("[\\r\\n\\t]+"; " ") | if length > $n then .[0:$n-1] + "…" else . end;
  def tool_summary:
    ($in.tool_input // {}) as $t
    | ($t.file_path // $t.notebook_path // $t.command // $t.pattern // $t.url
       // $t.query // $t.description // $t.prompt // $t.skill // "") as $arg
    | ($in.tool_name // "tool") + (if ($arg | tostring) == "" then "" else ": " + ($arg | clip(160)) end);

  (if $old.session_id == $in.session_id then $old else {} end) as $base
  | ($base + {
      pid: $pid, pane: $pane, session_id: $in.session_id,
      cwd: ($in.cwd // $base.cwd), transcript_path: ($in.transcript_path // $base.transcript_path),
      updated: $now
    })
  | if   $in.hook_event_name == "SessionEnd"       then "__delete__"
    elif $in.hook_event_name == "SessionStart"     then . + {status: "idle", started: $now, prompt: null, tool: null, message: null}
    elif $in.hook_event_name == "UserPromptSubmit" then . + {status: "working", prompt: ($in.prompt // "" | clip(200)), tool: null, message: null}
    elif $in.hook_event_name == "PreToolUse"       then . + {status: "working", tool: tool_summary, message: null}
    elif $in.hook_event_name == "PostToolUse"      then . + {status: "working", message: null}
    elif $in.hook_event_name == "Notification" then
      if ($in.notification_type // "") == "idle_prompt"
         or (($in.message // "") | test("waiting for your input"; "i"))
      then . + {status: "idle"}
      else . + {status: "waiting", message: ($in.message // "needs attention" | clip(200))}
      end
    elif $in.hook_event_name == "Stop"             then . + {status: "idle", message: null}
    else . end
  ' 2>/dev/null) || exit 0

[[ -z "$new" ]] && exit 0
if [[ "$new" == '"__delete__"' ]]; then
  rm -f "$state"
  exit 0
fi
tmp="$state.$$.tmp"
print -r -- "$new" >| "$tmp" && mv -f "$tmp" "$state"
exit 0
