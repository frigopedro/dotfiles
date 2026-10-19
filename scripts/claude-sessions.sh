#!/usr/bin/env zsh
# Claude session manager popup for tmux (prefix + a / prefix + C-a). Lists
# every running Claude Code instance in any tmux pane, with a live preview,
# and jumps to the chosen pane. See .tmux.conf for the keybinds.
#
# Which sessions appear is decided fresh on every open and reload from live
# state only:
#   ps         → every process named "claude"
#   tmux       → every pane and its shell pid (pane_pid)
#   claude → pane: walk up the claude process's parents until one is a
#              pane_pid. This also finds Claude inside nvim's :terminal, where
#              the tty differs from the pane's.
# Closed panes, exited or killed Claude, moved windows and renamed sessions
# therefore never leave stale rows.
#
# Extra details (never used to decide what is listed):
#   ~/.claude/sessions/<pid>.json        Claude's own registry: task name, busy/idle
#   ~/.cache/claude-tmux/state/<pid>.json  written by claude-tmux-hook.sh: working /
#                                          waiting / idle, last prompt, current tool
#   pane title                           "✳ <conversation title>", set by Claude
#
# Usage:
#   claude-sessions.sh [--origin <pane_id>]    interactive picker (default;
#                                              origin defaults to the active pane)
#   claude-sessions.sh list [--origin <pane>]  rows for fzf: display \t pane_id \t pid
#   claude-sessions.sh preview <pane> <pid>    preview pane contents
#   claude-sessions.sh jump <pane_id>          switch the client to that pane

setopt extended_glob
SELF=${0:A}
source "${0:A:h}/lib/tmux-common.zsh"
zmodload -F zsh/stat b:zstat

REGISTRY_DIR="$HOME/.claude/sessions"
STATE_DIR="$HOME/.cache/claude-tmux/state"
US=$'\x1f'
now=$EPOCHSECONDS

C_RESET=$'\e[0m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m'
C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_MAGENTA=$'\e[35m'

# ── Data collection ──────────────────────────────────────
# scan_all (or scan_one) finds the sessions: CLAUDE_PIDS plus CL_PANE[pid].
# enrich then fills CL_NAME, CL_STATUS, CL_TS, CL_CWD, CL_SID, CL_KIND keyed
# by pid. Pane details live in P_* keyed by pane_id.
typeset -gA ppid_of comm_of pane_of_pid
typeset -gA P_SESS P_WIN_ID P_WIN_IDX P_WIN_NAME P_IDX P_TITLE P_PATH
typeset -gA CL_PANE CL_NAME CL_STATUS CL_TS CL_CWD CL_SID CL_KIND
typeset -ga CLAUDE_PIDS
PANE_FMT=$'#{pane_pid}\t#{pane_id}\t#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}\t#{pane_index}\t#{pane_current_path}\t#{pane_title}'

is_claude_comm() { [[ ${1:t} == claude || $1 == */claude/versions/* ]] }

# store_pane <tab-separated PANE_FMT line> → REPLY=pane_id
store_pane() {
  local -a f
  f=("${(@ps:\t:)1}")
  REPLY=$f[2]
  pane_of_pid[$f[1]]=$REPLY
  P_SESS[$REPLY]=$f[3]; P_WIN_ID[$REPLY]=$f[4]; P_WIN_IDX[$REPLY]=$f[5]
  P_WIN_NAME[$REPLY]=$f[6]; P_IDX[$REPLY]=$f[7]; P_PATH[$REPLY]=$f[8]; P_TITLE[$REPLY]=${(j:\t:)f[9,-1]}
}

# Every claude process in every pane. Also removes hook state left behind by
# claude processes that are gone (kill -9, closed pane, …).
scan_all() {
  local line pid pp c p pane i

  # One process listing for the whole run.
  local -a claude_candidates
  for line in ${(f)"$(ps -A -o pid=,ppid=,comm=)"}; do
    line=${line## #}
    pid=${line%% *}; line=${${line#* }## #}
    pp=${line%% *};  c=${${line#* }## #}
    ppid_of[$pid]=$pp
    # The native binary lives at ~/.local/share/claude/versions/<ver>, so it
    # shows as "claude" (argv0) or as a version number when run by full path.
    if is_claude_comm "$c"; then
      comm_of[$pid]=claude
      claude_candidates+=($pid)
    else
      comm_of[$pid]=${c:t}
    fi
  done

  # One pane listing. Tab-separated: tmux escapes control characters such as
  # \x1f in its output.
  for line in ${(f)"$(tmux list-panes -a -F "$PANE_FMT" 2>/dev/null)"}; do
    store_pane "$line"
  done

  # Link each claude process to its pane.
  CLAUDE_PIDS=()
  for pid in $claude_candidates; do
    p=$pid pane=""
    for i in {1..40}; do
      if [[ -n ${pane_of_pid[$p]} ]]; then pane=${pane_of_pid[$p]}; break; fi
      p=${ppid_of[$p]}
      [[ -z $p || $p -le 1 ]] && break
      # A claude started by another claude (e.g. `claude -p` from a tool call)
      # is part of the outer session, not a session of its own.
      [[ ${comm_of[$p]} == claude ]] && { pane=""; break }
    done
    [[ -z $pane ]] && continue
    CLAUDE_PIDS+=($pid)
    CL_PANE[$pid]=$pane
  done

  # Remove state files whose claude is gone (kill -9, closed pane, …).
  local sf spid
  for sf in $STATE_DIR/*.json(N); do
    spid=${${sf:t}%.json}
    [[ ${comm_of[$spid]} == claude ]] || rm -f $sf
  done

}

# Just one session, for the preview (refreshed every second, so it skips the
# full process scan). The list already linked this pid to this pane.
scan_one() {
  local pid=$1 pane=$2 line
  CLAUDE_PIDS=()
  is_claude_comm "$(ps -o comm= -p $pid 2>/dev/null)" || return 1
  line=$(tmux display-message -p -t "$pane" "$PANE_FMT" 2>/dev/null) || return 1
  store_pane "$line"
  CLAUDE_PIDS=($pid)
  CL_PANE[$pid]=$pane
}

enrich() {
  local line pid pane
  local -a f

  # Claude's registry, read with one jq call.
  local -a reg_files hook_files
  for pid in $CLAUDE_PIDS; do
    [[ -f $REGISTRY_DIR/$pid.json ]] && reg_files+=($REGISTRY_DIR/$pid.json)
  done
  typeset -gA R_NAME R_NAMESRC R_STATUS R_TS
  if (( $#reg_files )); then
    for line in ${(f)"$(jq -r '[.pid, (.name // ""), (.nameSource // ""), (.status // ""),
          ((.statusUpdatedAt // .updatedAt // 0) / 1000 | floor), (.sessionId // ""),
          (.cwd // ""), (.kind // "")] | map(tostring) | join("\u001f")' $reg_files 2>/dev/null)"}; do
      f=("${(@ps:\x1f:)line}")
      pid=$f[1]
      R_NAME[$pid]=$f[2]; R_NAMESRC[$pid]=$f[3]; R_STATUS[$pid]=$f[4]; R_TS[$pid]=$f[5]
      CL_SID[$pid]=$f[6]; CL_CWD[$pid]=$f[7]; CL_KIND[$pid]=$f[8]
    done
  fi

  # Hook state, read with one jq call.
  for pid in $CLAUDE_PIDS; do
    [[ -f $STATE_DIR/$pid.json ]] && hook_files+=($STATE_DIR/$pid.json)
  done
  typeset -gA H_STATUS H_TS
  if (( $#hook_files )); then
    for line in ${(f)"$(jq -r '[.pid, (.status // ""), (.updated // 0), (.session_id // ""), (.cwd // "")]
          | map(tostring) | join("\u001f")' $hook_files 2>/dev/null)"}; do
      f=("${(@ps:\x1f:)line}")
      pid=$f[1]
      # A state file left by a dead claude whose pid got reused: ignore it.
      [[ -n ${CL_SID[$pid]} && -n $f[4] && $f[4] != ${CL_SID[$pid]} ]] && continue
      H_STATUS[$pid]=$f[2]; H_TS[$pid]=$f[3]
      [[ -z ${CL_CWD[$pid]} ]] && CL_CWD[$pid]=$f[5]
      [[ -z ${CL_SID[$pid]} ]] && CL_SID[$pid]=$f[4]
    done
  fi

  # Work out each session's name, status and cwd.
  local title t rs
  for pid in $CLAUDE_PIDS; do
    pane=${CL_PANE[$pid]}
    [[ -z ${CL_CWD[$pid]} ]] && CL_CWD[$pid]=${P_PATH[$pane]}

    # Name: Claude's task name → conversation title from the pane title →
    # Claude's derived name → repo/dir name.
    title=${P_TITLE[$pane]}
    t=""
    if [[ $title == [^[:alnum:][:space:]]##[[:space:]]##?* ]]; then
      t=${title##[^[:alnum:][:space:]]##[[:space:]]##}
      [[ $t == "Claude Code" ]] && t=""
    fi
    if [[ -n ${R_NAME[$pid]} && ${R_NAMESRC[$pid]} != derived ]]; then
      CL_NAME[$pid]=${R_NAME[$pid]}
    elif [[ -n $t ]]; then
      CL_NAME[$pid]=$t
    elif [[ -n ${R_NAME[$pid]} ]]; then
      CL_NAME[$pid]=${R_NAME[$pid]}
    else
      CL_NAME[$pid]=${CL_CWD[$pid]:t}
    fi

    # Status: whichever of hook state / registry changed most recently.
    rs=${R_STATUS[$pid]}
    [[ $rs == busy ]] && rs=working
    if [[ -n ${H_STATUS[$pid]} ]] && (( ${H_TS[$pid]:-0} >= ${R_TS[$pid]:-0} )); then
      CL_STATUS[$pid]=${H_STATUS[$pid]}; CL_TS[$pid]=${H_TS[$pid]}
    elif [[ -n $rs ]]; then
      CL_STATUS[$pid]=$rs; CL_TS[$pid]=${R_TS[$pid]}
    elif [[ $title == [⠀-⣿]* ]]; then
      CL_STATUS[$pid]=working; CL_TS[$pid]=0   # braille spinner in the title
    else
      CL_STATUS[$pid]=idle; CL_TS[$pid]=0
    fi
  done
}

# repo_label <cwd> → REPLY="repo@branch[/subdir]" or a ~-shortened dir
repo_label() {
  local cwd=$1 root branch sub
  if repo_root "$cwd"; then
    root=$REPLY
    git_branch "$root"; branch=$REPLY
    sub=${cwd#$root}
    REPLY="${root:t}@${branch}${sub}"
  else
    REPLY=${cwd/#$HOME/\~}
  fi
}

status_glyph() {
  case $1 in
    waiting) REPLY="${C_YELLOW}!${C_RESET}" ;;
    working) REPLY="${C_GREEN}●${C_RESET}" ;;
    *)       REPLY="${C_DIM}○${C_RESET}" ;;
  esac
}

# ── list ────────────────────────────────────────────────
cmd_list() {
  local origin=$1 pid pane rank mark name repo loc st age
  scan_all; enrich
  local -a rows
  for pid in $CLAUDE_PIDS; do
    [[ -n ${CL_KIND[$pid]} && ${CL_KIND[$pid]} != interactive ]] && continue
    pane=${CL_PANE[$pid]}
    st=${CL_STATUS[$pid]}
    case $st in waiting) rank=0 ;; working) rank=1 ;; *) rank=2 ;; esac

    mark=" "; [[ $pane == $origin ]] && mark="${C_CYAN}▸${C_RESET}"
    status_glyph $st; local glyph=$REPLY
    truncate_to 34 "${CL_NAME[$pid]}"; name=$REPLY
    repo_label "${CL_CWD[$pid]}"; truncate_to 36 "$REPLY"; repo=$REPLY
    loc=":${P_WIN_IDX[$pane]}.${P_IDX[$pane]}"
    truncate_to $(( 28 - $#loc )) "${P_SESS[$pane]}"; loc=$REPLY$loc
    format_age ${CL_TS[$pid]}; age=$REPLY
    [[ $age == - ]] && age=""
    [[ $age == *s ]] && age="<1m"   # keep rows stable between refreshes

    rows+=("${rank}$(( 9999999999 - ${CL_TS[$pid]:-0} ))${US}${mark}${glyph} ${(r:34:)name}  ${C_MAGENTA}${(r:36:)repo}${C_RESET}  ${C_DIM}${(r:28:)loc}${C_RESET}  ${(r:7:)st} ${C_DIM}${age}${C_RESET}"$'\t'"${pane}"$'\t'"${pid}")
  done
  print -r -- "   ${(r:34:)${:-SESSION}}  ${(r:36:)${:-REPO}}  ${(r:28:)${:-LOCATION}}  STATUS"
  (( $#rows )) || return 0
  print -rl -- ${(o)rows} | cut -d"$US" -f2-
}

# ── preview ─────────────────────────────────────────────
cmd_preview() {
  local pane=$1 pid=$2
  local cols=${FZF_PREVIEW_COLUMNS:-$COLUMNS} lines=${FZF_PREVIEW_LINES:-30}
  if ! scan_one $pid $pane; then
    print -r -- "${C_DIM}This Claude session has exited.${C_RESET}"
    return
  fi
  enrich

  local prompt tool message transcript started
  if [[ -f $STATE_DIR/$pid.json ]]; then
    local -a h
    h=("${(@ps:\x1f:)$(jq -r '[(.prompt // ""), (.tool // ""), (.message // ""), (.transcript_path // ""), (.started // 0), (.session_id // "")]
         | map(tostring) | join("\u001f")' $STATE_DIR/$pid.json 2>/dev/null)}")
    if [[ -z ${CL_SID[$pid]} || $h[6] == ${CL_SID[$pid]} ]]; then
      prompt=$h[1] tool=$h[2] message=$h[3] transcript=$h[4] started=$h[5]
    fi
  fi

  # Sessions started before the hooks were installed: get the last prompt and
  # tool from the end of the transcript instead.
  if [[ -z $prompt && -n ${CL_SID[$pid]} ]]; then
    [[ -z $transcript ]] && transcript=$HOME/.claude/projects/${CL_CWD[$pid]//[^[:alnum:]]/-}/${CL_SID[$pid]}.jsonl
    if [[ -f $transcript ]]; then
      # Cached by transcript size so the 1s refresh only re-parses on change.
      local -a tr st_size
      local cache_dir="${TMPDIR:-/tmp}/claude-sessions-cache"
      local cache="$cache_dir/${CL_SID[$pid]}"
      zstat -A st_size +size -- $transcript 2>/dev/null
      if [[ -f $cache ]] && [[ "$(<$cache)" == ${st_size[1]}$'\x1f'* ]]; then
        tr=("${(@ps:\x1f:)$(<$cache)}")
        tr=("${(@)tr[2,-1]}")
      else
        tr=("${(@ps:\x1f:)$(tail -c 400000 $transcript | jq -rRn '
          [inputs | try fromjson catch empty] as $e
          | ([$e[] | select(.type == "user" and (.isMeta | not))
               | .message.content
               | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join(" ")) end
               | select(length > 0 and (startswith("<") | not))] | last // "") as $p
          | ([$e[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
               | .name + ": " + ((.input.file_path // .input.command // .input.pattern // .input.description // "") | tostring)]
             | last // "") as $t
          | [$p, $t] | map(gsub("[\\r\\n\\t]+"; " ") | .[0:200]) | join("\u001f")' 2>/dev/null)}")
        mkdir -p $cache_dir 2>/dev/null
        print -rn -- "${st_size[1]}"$'\x1f'"${(pj:\x1f:)tr}" >| $cache 2>/dev/null
      fi
      prompt=$tr[1]; tool=$tr[2]
    fi
  fi

  local st=${CL_STATUS[$pid]} st_color
  case $st in waiting) st_color=$C_YELLOW ;; working) st_color=$C_GREEN ;; *) st_color=$C_DIM ;; esac
  local since=""
  (( ${CL_TS[$pid]:-0} > 0 )) && { format_relative ${CL_TS[$pid]}; since=$REPLY }
  repo_label "${CL_CWD[$pid]}"; local repo=$REPLY

  local -a header
  header=(
    "${C_BOLD}${CL_NAME[$pid]}${C_RESET}"
    "${C_MAGENTA}${repo}${C_RESET}  ${C_DIM}${CL_CWD[$pid]/#$HOME/~}${C_RESET}"
    "${C_DIM}pane${C_RESET} ${P_SESS[$pane]}:${P_WIN_IDX[$pane]}.${P_IDX[$pane]} (${P_WIN_NAME[$pane]}) ${pane}   ${C_DIM}status${C_RESET} ${st_color}${st}${C_RESET} ${C_DIM}${since}${C_RESET}"
  )
  [[ -n $message ]] && header+=("${C_YELLOW}⚠ ${message}${C_RESET}")
  [[ -n $prompt ]]  && header+=("${C_DIM}prompt${C_RESET} ${prompt}")
  [[ -n $tool ]]    && header+=("${C_DIM}tool${C_RESET}   ${tool}")

  local line
  for line in $header; do
    # Cut header lines to the preview width (ignoring color codes).
    local plain=${line//$'\e'\[[0-9;]#m/}
    if (( ${#plain} > cols )); then truncate_to $cols "$plain"; line=$REPLY; fi
    print -r -- "$line"
  done
  print -r -- "${C_DIM}${(l:$cols::─:)}${C_RESET}"

  # The pane's visible screen with colors, minus trailing blank lines, cut to
  # whatever height is left.
  local room=$(( lines - $#header - 1 ))
  (( room < 1 )) && return
  local -a screen
  screen=("${(@f)$(tmux capture-pane -ep -t $pane 2>/dev/null)}")
  while (( $#screen )) && [[ -z ${screen[-1]//$'\e'\[[0-9;]#m/} || ${screen[-1]//$'\e'\[[0-9;]#m/} == [[:space:]]## ]]; do
    screen[-1]=()
  done
  (( $#screen > room )) && screen=("${(@)screen[-room,-1]}")
  print -rl -- "${(@)screen}"
}

# ── jump ────────────────────────────────────────────────
cmd_jump() {
  local pane=$1 info sess win
  info=$(tmux display-message -p -t "$pane" $'#{session_name}\t#{window_id}' 2>/dev/null)
  if [[ -z $info ]]; then
    tmux display-message "claude-sessions: pane $pane no longer exists"
    return 1
  fi
  sess=${info%%$'\t'*}; win=${info#*$'\t'}
  tmux switch-client -t "=$sess" \; select-window -t "$win" \; select-pane -Z -t "$pane"
}

# ── picker ──────────────────────────────────────────────
# Keeps the list and preview current while the popup is open: refreshes the
# preview every second and the list every 3 seconds, keeping the cursor on the
# same session. Stops as soon as fzf is gone.
ticker() {
  local sock=$1 origin=$2 tmp=$3 i=0 state query cur_pane n idx line
  while sleep 1; do
    [[ -S $sock ]] || return
    if (( ++i % 3 )); then
      curl -sf --unix-socket "$sock" http -d 'refresh-preview' >/dev/null || return
      continue
    fi
    state=$(curl -sf --unix-socket "$sock" http) || return
    query=$(print -r -- "$state" | jq -r '.query')
    if [[ -n $query ]]; then
      # While searching, only refresh the preview; positions mean something
      # else in a filtered list.
      curl -sf --unix-socket "$sock" http -d 'refresh-preview' >/dev/null || return
      continue
    fi
    cur_pane=$(print -r -- "$state" | jq -r '.current.text // "" | split("\t")[1] // ""')
    "$SELF" list --origin "$origin" >| "$tmp"
    n=0 idx=1
    for line in "${(@f)$(<$tmp)}"; do
      (( n++ == 0 )) && continue   # column header
      [[ ${${line#*$'\t'}%%$'\t'*} == $cur_pane ]] && { idx=$(( n - 1 )); break }
    done
    curl -sf --unix-socket "$sock" http -d "reload-sync(cat ${(q)tmp})+pos($idx)+refresh-preview" >/dev/null || return
  done
}

cmd_pick() {
  # Inside a popup, the client's active pane is the one we were opened from.
  local origin=${1:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}
  command -v fzf >/dev/null || { print "fzf not found"; sleep 2; return 1 }

  local sock="${TMPDIR:-/tmp}/claude-sessions-$$.sock"
  local tmp="${TMPDIR:-/tmp}/claude-sessions-$$.list"
  [[ ${#sock} -gt 100 ]] && sock="/tmp/claude-sessions-$$.sock"

  "$SELF" list --origin "$origin" >| "$tmp"
  ticker "$sock" "$origin" "$tmp" &!
  local ticker_pid=$!
  trap "kill $ticker_pid 2>/dev/null; rm -f ${(q)tmp} ${(q)sock}" EXIT INT TERM

  local selected
  selected=$(fzf < "$tmp" \
      --ansi --reverse --header-lines=1 \
      --header='claude sessions · enter: jump · ctrl-r: refresh · ctrl-/: preview · esc: close' \
      --delimiter=$'\t' --with-nth=1 \
      --no-sort --cycle --info=inline-right \
      --listen="$sock" \
      --preview="${(q)SELF} preview {2} {3}" \
      --preview-window='down,60%,nowrap,border-top' \
      --bind="ctrl-r:reload(${(q)SELF} list --origin ${(q)origin})" \
      --bind='ctrl-/:toggle-preview')

  kill $ticker_pid 2>/dev/null
  [[ -z $selected ]] && return 0
  local pane=${${selected#*$'\t'}%%$'\t'*}
  [[ -n $pane ]] && cmd_jump "$pane"
}

# ── main ────────────────────────────────────────────────
sub=pick
case $1 in
  list|preview|jump|pick) sub=$1; shift ;;
esac
origin=""
if [[ $1 == --origin ]]; then origin=$2; shift 2; fi

case $sub in
  list)    cmd_list "$origin" ;;
  preview) cmd_preview "$1" "$2" ;;
  jump)    cmd_jump "$1" ;;
  pick)    cmd_pick "$origin" ;;
esac
