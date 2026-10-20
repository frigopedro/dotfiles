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
# It also drives the notifications: "unseen" is set when a turn finishes while
# you're looking elsewhere (cleared by claude-sessions.sh seen on pane focus),
# every status change republishes the tmux status bar / window flags, and a
# session that starts waiting on you while unfocused raises a macOS
# notification.
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

# Whether you're looking at this pane right now: no "review" mark and no
# desktop notification then.
focused=false
[[ $(tmux display-message -p -t "$TMUX_PANE" '#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}' 2>/dev/null) == 1 ]] && focused=true

state="$STATE_DIR/$claude_pid.json"
old='{}'
[[ -f "$state" ]] && old=$(<"$state")

new=$(print -r -- "$input" | jq -r -n \
  --arg oldraw "$old" \
  --argjson pid "$claude_pid" \
  --arg pane "$TMUX_PANE" \
  --argjson focused "$focused" \
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
    elif $in.hook_event_name == "SessionStart"     then . + {status: "idle", started: $now, prompt: null, tool: null, message: null, unseen: false}
    elif $in.hook_event_name == "UserPromptSubmit" then . + {status: "working", prompt: ($in.prompt // "" | clip(200)), tool: null, message: null, unseen: false}
    elif $in.hook_event_name == "PreToolUse"       then . + {status: "working", tool: tool_summary, message: null}
    elif $in.hook_event_name == "PostToolUse"      then . + {status: "working", message: null}
    elif $in.hook_event_name == "Notification" then
      if ($in.notification_type // "") == "idle_prompt"
         or (($in.message // "") | test("waiting for your input"; "i"))
      then . + {status: "idle"}
      else . + {status: "waiting", message: ($in.message // "needs attention" | clip(200))}
      end
    elif $in.hook_event_name == "Stop"             then . + {status: "idle", message: null, unseen: ($focused | not)}
    else . end
  # Three lines: did the status bar change (1/0), the desktop notification
  # text (empty for none), the new state (or "__delete__").
  | . as $new
  | (if $new == "__delete__" then true
     else ($new.status != $old.status or ($new.unseen // false) != ($old.unseen // false)) end) as $changed
  | (if $new != "__delete__" and $new.status == "waiting" and $old.status != "waiting" and ($focused | not)
     then $new.message else "" end) as $notify
  | "\(if $changed then 1 else 0 end)\n\($notify)\n\(if $new == "__delete__" then $new else ($new | tojson) end)"
  ' 2>/dev/null) || exit 0

[[ -z "$new" ]] && exit 0
out=("${(@f)new}")
changed=$out[1] notify=$out[2] new=$out[3]
[[ -z "$new" ]] && exit 0
if [[ "$new" == __delete__ ]]; then
  rm -f "$state"
else
  tmp="$state.$$.tmp"
  print -r -- "$new" >| "$tmp" && mv -f "$tmp" "$state"
fi

# Both in the background so the hook returns right away.
if [[ "$changed" == 1 ]]; then
  "${0:A:h}/claude-sessions.sh" publish >/dev/null 2>&1 </dev/null &!
fi
if [[ -n "$notify" ]]; then
  source "${0:A:h}/lib/tmux-common.zsh"
  cwd=$(print -r -- "$input" | jq -r '.cwd // ""' 2>/dev/null)
  if repo_root "$cwd"; then repo=${REPLY:t}; else repo=${cwd:t}; fi
  osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' -e 'end run' \
    "Claude · ${repo:-session}" "$notify" >/dev/null 2>&1 </dev/null &!
fi
exit 0
