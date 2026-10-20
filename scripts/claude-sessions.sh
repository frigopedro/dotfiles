#!/usr/bin/env zsh
# Claude session manager popup for tmux (prefix + a / prefix + C-a). Lists
# every running Claude Code instance in any tmux pane, grouped by repo, with a
# live preview on the right, and jumps to the chosen pane. Also publishes the
# tmux status bar summary and window flags. See .tmux.conf for the keybinds.
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
#                                          waiting / idle, unseen, last prompt, tool
#   pane title                           "✳ <conversation title>", set by Claude
#
# Statuses, most urgent first:
#   waiting  ⚠  blocked on a permission prompt or question
#   review   ✓  finished a turn you haven't looked at yet (hook state "unseen")
#   working  ●
#   idle     ○
#
# Usage:
#   claude-sessions.sh [--origin <pane_id>]    interactive picker (default;
#                                              origin defaults to the active pane)
#   claude-sessions.sh list [--origin <pane>]  rows for fzf:
#                                              display \t repo|agent \t pane_id \t pid \t group
#   claude-sessions.sh preview <kind> <pane> <pid> <group>   preview contents
#   claude-sessions.sh jump <pane_id>          switch the client to that pane
#   claude-sessions.sh publish                 update @claude_status / @claude_flag
#   claude-sessions.sh seen <pane_id>          clear "review" for that pane

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
C_BLUE=$'\e[34m'

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
  typeset -gA H_STATUS H_TS H_UNSEEN
  if (( $#hook_files )); then
    for line in ${(f)"$(jq -r '[.pid, (.status // ""), (.updated // 0), (.session_id // ""), (.cwd // ""),
          (.unseen // false), (.pane // "")]
          | map(tostring) | join("\u001f")' $hook_files 2>/dev/null)"}; do
      f=("${(@ps:\x1f:)line}")
      pid=$f[1]
      # A state file left by a dead claude whose pid got reused: ignore it.
      [[ -n ${CL_SID[$pid]} && -n $f[4] && $f[4] != ${CL_SID[$pid]} ]] && continue
      H_STATUS[$pid]=$f[2]; H_TS[$pid]=$f[3]; H_UNSEEN[$pid]=$f[6]
      [[ -z ${CL_PANE[$pid]} ]] && CL_PANE[$pid]=$f[7]
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
    # Finished while you were looking elsewhere.
    [[ ${CL_STATUS[$pid]} == idle && ${H_UNSEEN[$pid]} == true ]] && CL_STATUS[$pid]=review
  done
}

# group_info <cwd> → G_KEY (main repo root, or the dir itself outside a repo;
# a linked worktree resolves to the repo it belongs to), G_WT (the checkout
# the cwd is in: the worktree root, or G_KEY for the main checkout), G_LABEL
# (repo name or ~-shortened dir), G_BRANCH, G_SUB ("/subdir" inside the
# checkout) and G_DETAIL ("branch[/subdir]" in a repo)
group_info() {
  local cwd=$1 root gd
  if repo_root "$cwd"; then
    root=$REPLY G_WT=$REPLY
    # A linked worktree's .git file points at <main>/.git/worktrees/<name>.
    if [[ -f $root/.git ]]; then
      gd=$(<"$root/.git"); gd=${gd#gitdir: }
      [[ $gd != /* ]] && gd=$root/$gd
      [[ $gd == */.git/worktrees/* ]] && root=${gd%%/.git/worktrees/*}
    fi
    G_KEY=$root G_LABEL=${root:t}
    git_branch "$G_WT"; G_BRANCH=$REPLY G_SUB=${cwd#$G_WT}
    G_DETAIL="${G_BRANCH}${G_SUB}"
  else
    G_KEY=$cwd G_WT=$cwd G_LABEL=${cwd/#$HOME/\~} G_BRANCH="" G_SUB="" G_DETAIL=""
  fi
}

status_rank() {
  case $1 in waiting) REPLY=0 ;; review) REPLY=1 ;; working) REPLY=2 ;; *) REPLY=3 ;; esac
}

status_glyph() {
  case $1 in
    waiting) REPLY="${C_YELLOW}${C_BOLD}⚠${C_RESET}" ;;
    review)  REPLY="${C_CYAN}${C_BOLD}✓${C_RESET}" ;;
    working) REPLY="${C_GREEN}●${C_RESET}" ;;
    *)       REPLY="${C_DIM}○${C_RESET}" ;;
  esac
}

status_color() {
  case $1 in
    waiting) REPLY="${C_YELLOW}${C_BOLD}" ;;
    review)  REPLY="${C_CYAN}${C_BOLD}" ;;
    working) REPLY=$C_GREEN ;;
    *)       REPLY=$C_DIM ;;
  esac
}

# collect: after scan + enrich, the interactive sessions in display order in
# SORTED (pids): groups by their most urgent session, then sessions within a
# group by urgency and recency. Fills A_GROUP / A_DETAIL per pid, G_LABELS and
# G_COUNT ("<group or worktree>:<status>" → n). Sessions in a repo's linked
# worktrees nest under it: A_WT / W_LABELS / W_BEST per worktree, and
# G_NESTED[group] is set for repos that have any session in a linked worktree.
typeset -gA A_GROUP A_DETAIL A_SUB A_WT G_LABELS G_BEST G_COUNT W_LABELS W_BEST G_NESTED
typeset -ga SORTED
collect() {
  local pid key
  local -a keyed
  local -A akey
  for pid in $CLAUDE_PIDS; do
    [[ -n ${CL_KIND[$pid]} && ${CL_KIND[$pid]} != interactive ]] && continue
    group_info "${CL_CWD[$pid]}"
    A_GROUP[$pid]=$G_KEY A_WT[$pid]=$G_WT A_DETAIL[$pid]=$G_DETAIL A_SUB[$pid]=$G_SUB
    G_LABELS[$G_KEY]=$G_LABEL W_LABELS[$G_WT]=${G_BRANCH:-${G_WT:t}}
    [[ $G_WT != $G_KEY ]] && G_NESTED[$G_KEY]=1
    (( G_COUNT[$G_KEY:${CL_STATUS[$pid]}]++ ))
    (( G_COUNT[wt:$G_WT:${CL_STATUS[$pid]}]++ ))
    status_rank ${CL_STATUS[$pid]}
    key="${REPLY}$(( 9999999999 - ${CL_TS[$pid]:-0} ))"
    akey[$pid]=$key
    [[ -z ${G_BEST[$G_KEY]} || $key < ${G_BEST[$G_KEY]} ]] && G_BEST[$G_KEY]=$key
    [[ -z ${W_BEST[$G_WT]} || $key < ${W_BEST[$G_WT]} ]] && W_BEST[$G_WT]=$key
  done
  for pid in ${(k)akey}; do
    keyed+=("${G_BEST[${A_GROUP[$pid]}]}${US}${A_GROUP[$pid]}${US}${W_BEST[${A_WT[$pid]}]}${US}${A_WT[$pid]}${US}${akey[$pid]}${US}${pid}")
  done
  SORTED=(${${(o)keyed}##*$US})
}

# group_counts <group> → REPLY = "⚠1 ✓2 ●1 ○3" for the statuses present
group_counts() {
  local s n
  local out=""
  for s in waiting review working idle; do
    n=${G_COUNT[$1:$s]:-0}
    (( n )) || continue
    status_glyph $s
    out+="${REPLY}${C_DIM}${n}${C_RESET} "
  done
  REPLY=$out
}

# ── list ────────────────────────────────────────────────
# A tree: one row per repo (bold, with status counts), its sessions under it.
# A repo with sessions in linked worktrees gets a row per worktree between the
# two, and its sessions hang off those.
cmd_list() {
  local origin=$1 pid pane grp wt prev="" prevwt="" st name detail age mark conn glyph i
  local nested wconn vline pad nw=28 next
  # Width of the picker's list pane (set by cmd_pick); spare room goes to the
  # session name so rows fill the pane.
  local extra=$(( ${CLAUDE_SESSIONS_WIDTH:-0} - 54 ))
  (( extra < 0 )) && extra=0
  scan_all; enrich; collect
  publish_tmux   # keep the status bar in step with what the picker shows

  for (( i = 1; i <= $#SORTED; i++ )); do
    pid=$SORTED[i] grp=${A_GROUP[$SORTED[i]]}
    pane=${CL_PANE[$pid]}
    if [[ $grp != $prev ]]; then
      # Repo row: enter / preview use its most urgent session (the first).
      truncate_to 30 "${G_LABELS[$grp]}"; name=$REPLY
      group_counts $grp
      print -r -- " ${C_MAGENTA}${C_BOLD}${(r:30:)name}${C_RESET}  ${REPLY}"$'\t'repo$'\t'$pane$'\t'$pid$'\t'$grp
      prev=$grp prevwt=""
    fi

    wt=${A_WT[$pid]} nested=${G_NESTED[$grp]} pad="" vline="" nw=$(( 28 + extra ))
    next=$SORTED[i+1]
    if [[ -n $nested ]]; then
      # Does this worktree have a following sibling in the repo?
      local j=$i
      while (( ++j <= $#SORTED )) && [[ ${A_GROUP[$SORTED[j]]} == $grp && ${A_WT[$SORTED[j]]} == $wt ]]; do :; done
      if (( j <= $#SORTED )) && [[ ${A_GROUP[$SORTED[j]]} == $grp ]]; then wconn="├" vline="│"; else wconn="└" vline=" "; fi
      if [[ $wt != $prevwt ]]; then
        truncate_to 27 "${W_LABELS[$wt]}"; name=$REPLY
        group_counts "wt:$wt"
        print -r -- " ${C_DIM}${wconn}${C_RESET} ${C_BLUE}${C_BOLD}${(r:27:)name}${C_RESET}  ${REPLY}"$'\t'worktree$'\t'$pane$'\t'$pid$'\t'$grp
        prevwt=$wt
      fi
      pad="${C_DIM}${vline}${C_RESET} " nw=$(( 25 + extra ))
    fi

    if (( i == $#SORTED )) || [[ ${A_GROUP[$next]} != $grp || ${A_WT[$next]} != $wt ]]; then conn="└"; else conn="├"; fi
    mark=" "; [[ $pane == $origin ]] && mark="${C_CYAN}▸${C_RESET}"
    st=${CL_STATUS[$pid]}
    status_glyph $st; glyph=$REPLY
    truncate_to $nw "${CL_NAME[$pid]}"; name=${(r:$nw:)REPLY}
    # Sessions that need you get a colored name too, not just the glyph.
    case $st in waiting|review) status_color $st; name="${REPLY}${name}${C_RESET}" ;; esac
    if [[ -n $nested ]]; then detail=${A_SUB[$pid]#/}; else detail=${A_DETAIL[$pid]}; fi
    truncate_to 16 "$detail"; detail=$REPLY
    format_age ${CL_TS[$pid]}; age=$REPLY
    [[ $age == - ]] && age=""
    [[ $age == *s ]] && age="<1m"   # keep rows stable between refreshes

    print -r -- "${mark}${pad}${C_DIM}${conn}${C_RESET} ${glyph} ${name} ${C_DIM}${(r:16:)detail} ${(l:3:)age}${C_RESET}"$'\t'agent$'\t'$pane$'\t'$pid$'\t'$grp
  done
}

# ── preview ─────────────────────────────────────────────
# agent_details <pid> → D_PROMPT, D_TOOL, D_MESSAGE: from the hook state, or
# from the end of the transcript for sessions started before the hooks.
agent_details() {
  local pid=$1 transcript=""
  D_PROMPT="" D_TOOL="" D_MESSAGE=""
  if [[ -f $STATE_DIR/$pid.json ]]; then
    local -a h
    h=("${(@ps:\x1f:)$(jq -r '[(.prompt // ""), (.tool // ""), (.message // ""), (.transcript_path // ""), (.session_id // "")]
         | map(tostring) | join("\u001f")' $STATE_DIR/$pid.json 2>/dev/null)}")
    if [[ -z ${CL_SID[$pid]} || $h[5] == ${CL_SID[$pid]} ]]; then
      D_PROMPT=$h[1] D_TOOL=$h[2] D_MESSAGE=$h[3] transcript=$h[4]
    fi
  fi

  [[ -n $D_PROMPT || -z ${CL_SID[$pid]} ]] && return
  [[ -z $transcript ]] && transcript=$HOME/.claude/projects/${CL_CWD[$pid]//[^[:alnum:]]/-}/${CL_SID[$pid]}.jsonl
  [[ -f $transcript ]] || return
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
  D_PROMPT=$tr[1] D_TOOL=$tr[2]
}

# print_fit <cols> <lines...>: print each line cut to the preview width
# (ignoring color codes).
print_fit() {
  local cols=$1 line plain
  shift
  for line in "$@"; do
    plain=${line//$'\e'\[[0-9;]#m/}
    if (( ${#plain} > cols )); then truncate_to $cols "$plain"; line=$REPLY; fi
    print -r -- "$line"
  done
}

# print_capture <pane> <room>: the pane's visible screen with colors, minus
# trailing blank lines, cut to the last <room> lines.
print_capture() {
  local pane=$1 room=$2
  (( room < 1 )) && return
  local -a screen
  screen=("${(@f)$(tmux capture-pane -ep -t $pane 2>/dev/null)}")
  while (( $#screen )) && [[ -z ${screen[-1]//$'\e'\[[0-9;]#m/} || ${screen[-1]//$'\e'\[[0-9;]#m/} == [[:space:]]## ]]; do
    screen[-1]=()
  done
  (( $#screen > room )) && screen=("${(@)screen[-room,-1]}")
  print -rl -- "${(@)screen}"
}

# status_line <pid> → REPLY = colored "status · since"
status_line() {
  local pid=$1 st=${CL_STATUS[$1]} since=""
  (( ${CL_TS[$pid]:-0} > 0 )) && { format_relative ${CL_TS[$pid]}; since=" · $REPLY" }
  status_color $st
  REPLY="${REPLY}${st}${C_RESET}${C_DIM}${since}${C_RESET}"
}

cmd_preview() {
  local kind=$1 pane=$2 pid=$3 grp=$4
  local cols=${FZF_PREVIEW_COLUMNS:-$COLUMNS} lines=${FZF_PREVIEW_LINES:-30}
  local rule="${C_DIM}${(l:$cols::─:)}${C_RESET}"
  [[ $kind == repo ]] && { preview_repo "$grp" "$pid" $cols $lines "$rule"; return }

  if ! scan_one $pid $pane; then
    print -r -- "${C_DIM}This Claude session has exited.${C_RESET}"
    return
  fi
  enrich
  agent_details $pid
  group_info "${CL_CWD[$pid]}"
  local st=${CL_STATUS[$pid]}

  local -a header
  case $st in
    waiting) header+=("${C_YELLOW}${C_BOLD}⚠ WAITING ON YOU${C_RESET}  ${C_YELLOW}${D_MESSAGE}${C_RESET}") ;;
    review)  header+=("${C_CYAN}${C_BOLD}✓ FINISHED — NOT REVIEWED YET${C_RESET}") ;;
  esac
  status_line $pid
  header+=(
    "${C_BOLD}${CL_NAME[$pid]}${C_RESET}   ${REPLY}"
    "${C_MAGENTA}${G_LABEL}${C_RESET}${G_DETAIL:+${C_DIM}@${C_RESET}${G_DETAIL}}  ${C_DIM}${CL_CWD[$pid]/#$HOME/~}${C_RESET}"
    "${C_DIM}pane${C_RESET} ${P_SESS[$pane]}:${P_WIN_IDX[$pane]}.${P_IDX[$pane]} (${P_WIN_NAME[$pane]}) ${pane}"
  )
  [[ -n $D_PROMPT ]] && header+=("${C_DIM}prompt${C_RESET} ${D_PROMPT}")
  [[ -n $D_TOOL ]]   && header+=("${C_DIM}tool${C_RESET}   ${D_TOOL}")

  print_fit $cols "${(@)header}"
  print -r -- "$rule"
  print_capture $pane $(( lines - $#header - 1 ))
}

# Repo row: every session in the repo, then the screen of the most urgent one.
preview_repo() {
  local grp=$1 top=$2 cols=$3 lines=$4 rule=$5 pid pane
  scan_all; enrich; collect
  local -a out
  group_counts $grp
  out=("${C_MAGENTA}${C_BOLD}${G_LABELS[$grp]:-${grp:t}}${C_RESET}  ${REPLY}  ${C_DIM}${grp/#$HOME/~}${C_RESET}" "$rule")
  for pid in $SORTED; do
    [[ ${A_GROUP[$pid]} == $grp ]] || continue
    pane=${CL_PANE[$pid]}
    agent_details $pid
    status_glyph ${CL_STATUS[$pid]}; local glyph=$REPLY
    status_line $pid
    out+=("${glyph} ${C_BOLD}${CL_NAME[$pid]}${C_RESET}   ${REPLY}"
          "  ${C_DIM}${A_DETAIL[$pid]:+@${A_DETAIL[$pid]} · }${P_SESS[$pane]}:${P_WIN_IDX[$pane]}.${P_IDX[$pane]} (${P_WIN_NAME[$pane]})${C_RESET}")
    [[ ${CL_STATUS[$pid]} == waiting ]] && out+=("  ${C_YELLOW}⚠ ${D_MESSAGE:-needs attention}${C_RESET}")
    [[ -n $D_PROMPT ]] && out+=("  ${C_DIM}prompt${C_RESET} ${D_PROMPT}")
    [[ -n $D_TOOL ]]   && out+=("  ${C_DIM}tool${C_RESET}   ${D_TOOL}")
    out+=("")
  done
  (( $#out > lines )) && out=("${(@)out[1,lines]}")
  print_fit $cols "${(@)out}"

  # Whatever room is left: the most urgent session's screen.
  local room=$(( lines - $#out - 2 ))
  [[ -n ${CL_PANE[$top]} ]] && (( room > 3 )) || return
  local fill=$(( cols - ${#CL_NAME[$top]} - 4 ))
  (( fill < 0 )) && fill=0
  print -r -- "${C_DIM}── ${CL_NAME[$top]} ${(l:$fill::─:)}${C_RESET}"
  print_capture ${CL_PANE[$top]} $room
}

# ── status bar ──────────────────────────────────────────
# publish_tmux: after scan + enrich, set the global @claude_status (summary
# for status-right) and the per-window @claude_flag (most urgent session in
# that window) for .tmux.conf to show. tmux redraws every client when an
# option changes.
FLAG_waiting='#[bg=red,fg=white,bold] ⚠ #[default]'
FLAG_review='#[bg=blue,fg=white,bold] ✓ #[default]'
FLAG_working='#[fg=#0d1117]●#[default]'
publish_tmux() {
  local pid st w line flag
  local -a f cmd
  local -A win_of cur_flag want
  local -i nw=0 nr=0 nk=0

  for line in ${(f)"$(tmux list-panes -a -F $'#{pane_id}\t#{window_id}\t#{@claude_flag}' 2>/dev/null)"}; do
    f=("${(@ps:\t:)line}")
    win_of[$f[1]]=$f[2] cur_flag[$f[2]]=$f[3]
  done

  for pid in $CLAUDE_PIDS; do
    [[ -n ${CL_KIND[$pid]} && ${CL_KIND[$pid]} != interactive ]] && continue
    st=${CL_STATUS[$pid]}
    case $st in waiting) nw+=1 ;; review) nr+=1 ;; working) nk+=1 ;; *) continue ;; esac
    w=${win_of[${CL_PANE[$pid]}]}
    [[ -z $w ]] && continue
    status_rank $st
    if [[ -z ${want[$w]} ]] || (( REPLY < ${want[$w]} )); then want[$w]=$REPLY; fi
  done

  local summary=""
  (( nw )) && summary+="#[bg=red,fg=white,bold] ⚠ $nw waiting #[default] "
  (( nr )) && summary+="#[bg=blue,fg=white,bold] ✓ $nr review #[default] "
  (( nk )) && summary+="#[fg=#0d1117]● $nk working#[default] "
  cmd=(set -g @claude_status "$summary")

  for w in ${(k)cur_flag}; do
    case ${want[$w]} in
      0) flag=$FLAG_waiting ;; 1) flag=$FLAG_review ;; 2) flag=$FLAG_working ;; *) flag="" ;;
    esac
    [[ $flag == ${cur_flag[$w]} ]] && continue
    if [[ -n $flag ]]; then cmd+=(\; set -w -t $w @claude_flag "$flag")
    else cmd+=(\; set -wu -t $w @claude_flag)
    fi
  done
  tmux "${cmd[@]}" 2>/dev/null
}

cmd_publish() {
  scan_all; enrich; publish_tmux
}

# seen <pane>: you're looking at that pane now, so its finished turn is no
# longer up for review. Run on every pane focus (.tmux.conf), so it only forks
# when there is something to clear.
cmd_seen() {
  local pane=$1 sf tmp content changed=0
  [[ -z $pane ]] && return 0
  for sf in $STATE_DIR/*.json(N); do
    content=$(<$sf)
    [[ $content == *\"pane\":\"$pane\"* && $content == *\"unseen\":true* ]] || continue
    tmp="$sf.$$.tmp"
    if jq -c '.unseen = false' $sf >| $tmp 2>/dev/null; then
      mv -f $tmp $sf && changed=1
    else
      rm -f $tmp
    fi
  done
  (( changed )) && cmd_publish
  return 0   # a tmux hook runs this: a nonzero exit opens an error view
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
  cmd_seen "$pane"
}

# ── picker ──────────────────────────────────────────────
# Keeps the list and preview current while the popup is open: refreshes the
# preview every second and the list every 3 seconds, keeping the cursor on the
# same row. Stops as soon as fzf is gone.
ticker() {
  local sock=$1 origin=$2 tmp=$3 i=0 state query cur n idx line
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
    # The row is identified by its kind and pane (a repo row and its first
    # session share the pane).
    cur=$(print -r -- "$state" | jq -r '.current.text // "" | split("\t") | (.[1] // "") + "\t" + (.[2] // "")')
    "$SELF" list --origin "$origin" >| "$tmp"
    n=0 idx=1
    for line in "${(@f)$(<$tmp)}"; do
      (( n++ ))
      [[ ${${line#*$'\t'}%$'\t'*$'\t'*} == $cur ]] && { idx=$n; break }
    done
    curl -sf --unix-socket "$sock" http -d "reload-sync(cat ${(q)tmp})+pos($idx)+refresh-preview" >/dev/null || return
  done
}

cmd_pick() {
  # Inside a popup, the client's active pane is the one we were opened from.
  local origin=${1:-$(tmux display-message -p '#{pane_id}' 2>/dev/null)}
  command -v fzf >/dev/null || { print "fzf not found"; sleep 2; return 1 }

  # List pane = 40% of the popup, less pointer, border and scrollbar.
  local cols=${COLUMNS:-0}
  (( cols > 0 )) || cols=$(stty size 2>/dev/null </dev/tty | awk '{print $2}')
  export CLAUDE_SESSIONS_WIDTH=$(( ${cols:-0} * 40 / 100 - 4 ))

  local sock="${TMPDIR:-/tmp}/claude-sessions-$$.sock"
  local tmp="${TMPDIR:-/tmp}/claude-sessions-$$.list"
  [[ ${#sock} -gt 100 ]] && sock="/tmp/claude-sessions-$$.sock"

  "$SELF" list --origin "$origin" >| "$tmp"
  ticker "$sock" "$origin" "$tmp" &!
  local ticker_pid=$!
  trap "kill $ticker_pid 2>/dev/null; rm -f ${(q)tmp} ${(q)sock}" EXIT INT TERM

  local selected
  selected=$(fzf < "$tmp" \
      --ansi --reverse \
      --header='claude sessions · ⚠ waiting  ✓ review  ● working  ○ idle · enter: jump · ctrl-r: refresh · ctrl-/: preview' \
      --delimiter=$'\t' --with-nth=1 \
      --no-sort --cycle --info=inline-right \
      --listen="$sock" \
      --preview="${(q)SELF} preview {2} {3} {4} {5}" \
      --preview-window='right,60%,nowrap,border-left' \
      --bind="ctrl-r:reload(${(q)SELF} list --origin ${(q)origin})" \
      --bind='ctrl-/:toggle-preview')

  kill $ticker_pid 2>/dev/null
  [[ -z $selected ]] && return 0
  local -a f
  f=("${(@ps:\t:)selected}")
  [[ -n $f[3] ]] && cmd_jump "$f[3]"
}

# ── main ────────────────────────────────────────────────
sub=pick
case $1 in
  list|preview|jump|pick|publish|seen) sub=$1; shift ;;
esac
origin=""
if [[ $1 == --origin ]]; then origin=$2; shift 2; fi

case $sub in
  list)    cmd_list "$origin" ;;
  preview) cmd_preview "$@" ;;
  jump)    cmd_jump "$1" ;;
  pick)    cmd_pick "$origin" ;;
  publish) cmd_publish ;;
  seen)    cmd_seen "$1" ;;
esac
