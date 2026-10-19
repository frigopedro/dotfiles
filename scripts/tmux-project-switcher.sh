#!/usr/bin/env zsh
# Project switcher popup for tmux (prefix + C-j). Lists Repos/* dirs and their
# contents, sorted by last time each was opened via this switcher, with
# session/branch/last-used columns. See .tmux.conf for the keybind.
#
# Keys: enter opens/switches to the project's session; ctrl-x kills the
# selected project's open session (after a y/N confirmation) and refreshes.
#
# Usage: tmux-project-switcher.sh            interactive picker
#        tmux-project-switcher.sh list       rows for fzf
#        tmux-project-switcher.sh kill <dir> kill the session for <dir>

PROJECTS_DIR="$HOME/Desktop/Projects"
HISTORY_FILE="$HOME/.cache/tmux-project-switcher/history.tsv"
mkdir -p "$(dirname "$HISTORY_FILE")"

now=$(date +%s)
SELF=${0:A}

source "${0:A:h}/lib/tmux-common.zsh"

# session_for <dir> → REPLY = the tmux session name used for that project
session_for() { REPLY="${${1:t}//[. ]/_}" }

# Kill the session for a project dir, after confirming. Runs inside fzf's
# execute(), so it owns the terminal while it asks.
kill_project_session() {
  local dir=$1 sess current others procs key
  session_for "$dir"; sess=$REPLY
  if ! tmux has-session -t "=$sess" 2>/dev/null; then
    print -r -- "No open session for ${dir:t}."; sleep 1; return
  fi

  # Programs other than shells that would be killed with it.
  procs=(${(u)${(f)"$(tmux list-panes -s -t "=$sess" -F '#{pane_current_command}')"}})
  procs=(${procs:#(zsh|bash|sh|fish|-zsh)})
  local windows=$(tmux list-windows -t "=$sess" 2>/dev/null | wc -l | tr -d ' ')

  print -r -- ""
  print -r -- "  Kill session '$sess' ($windows windows)?"
  (( $#procs )) && print -r -- "  Running: ${(j:, :)procs}"
  print -rn -- "  [y/N] "
  read -k1 -s key </dev/tty
  [[ $key == [yY] ]] || return

  # Killing the session the client is on would detach it, so move the client
  # to another session first. Refuse if it's the only one.
  current=$(tmux display-message -p '#{client_session}' 2>/dev/null)
  if [[ $current == $sess ]]; then
    others=(${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"})
    others=(${others:#$sess})
    if (( ! $#others )); then
      print -r -- ""; print -r -- "  It's the only session; not killing it."; sleep 1.5; return
    fi
    tmux switch-client -l 2>/dev/null
    [[ $(tmux display-message -p '#{client_session}') == $sess ]] && tmux switch-client -t "=${others[1]}"
  fi
  tmux kill-session -t "=$sess"
}

case $1 in
  kill) kill_project_session "$2"; exit 0 ;;
esac

# Prints the fzf rows: display \t path, most recently opened first.
build_list() {
  candidates=("${(f)"$(
    {
      find "$PROJECTS_DIR" -maxdepth 2 -type d -name Repos
      find "$PROJECTS_DIR" -maxdepth 3 -type d -path '*/Repos/*' ! -name '.*'
      print -r -- "$HOME/dotfiles"
      print -r -- "$HOME/Downloads"
    } | sort -u
  )"}")

  typeset -A last_used
  if [[ -f "$HISTORY_FILE" ]]; then
    while IFS=$'\t' read -r ts hist_p; do
      [[ -n "$hist_p" ]] && last_used[$hist_p]=$ts
    done < "$HISTORY_FILE"
  fi

  # One round-trip to the tmux server instead of one has-session call per
  # candidate (see plan: this and the .git/HEAD read below are what make the
  # loop below fork-free and fast).
  typeset -A active_sessions
  for s in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"}; do
    active_sessions[$s]=1
  done

  lines=()
  for p in "${candidates[@]}"; do
    [[ -z "$p" || ! -d "$p" ]] && continue

    case "$p" in
      "$PROJECTS_DIR"/*)
        rel="${p#$PROJECTS_DIR/}"
        category="${rel%%/*}"
        name="$rel"
        ;;
      *)
        name="${p:t}"
        category="-"
        ;;
    esac

    ts="${last_used[$p]:-0}"
    format_relative "$ts"; rel_time=$REPLY

    git_branch "$p"; branch=$REPLY

    session_for "$p"; session_name=$REPLY
    session_mark=" "
    [[ -n "${active_sessions[$session_name]}" ]] && session_mark="●"

    display="$session_mark ${(r:45:)name} ${(r:10:)category} ${(r:9:)rel_time} $branch"
    lines+=("${(l:12::0:)ts}"$'\t'"$display"$'\t'"$p")
  done

  printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1nr | cut -f2-
}

[[ $1 == list ]] && { build_list; exit 0 }

selected=$(
  build_list \
    | fzf --reverse --header='select project · ctrl-x: kill session' --delimiter=$'\t' --with-nth=1 \
        --bind="ctrl-x:execute(${(q)SELF} kill {2})+reload(${(q)SELF} list)"
)

[[ -z "$selected" ]] && exit 0

sel_path=$(print -r -- "$selected" | awk -F'\t' '{print $2}')
[[ -z "$sel_path" || ! -d "$sel_path" ]] && exit 0

tmp_history=$(mktemp)
if [[ -f "$HISTORY_FILE" ]]; then
  awk -F'\t' -v p="$sel_path" '$2 != p' "$HISTORY_FILE" > "$tmp_history"
fi
printf '%s\t%s\n' "$now" "$sel_path" >> "$tmp_history"
mv "$tmp_history" "$HISTORY_FILE"

repo=$(basename "$sel_path")
session_name=$(print -r -- "$repo" | tr '. ' '__')

if ! tmux has-session -t="$session_name" 2>/dev/null; then
  tmux new-session -d -s "$session_name" -c "$sel_path" -n dev
  tmux send-keys -t "${session_name}:dev.0" 'nvim .' C-m
  tmux split-window -h -p 35 -t "${session_name}:dev" -c "$sel_path"
  tmux select-pane -t "${session_name}:dev.0"
  tmux new-window -t "$session_name" -n term -c "$sel_path"
  tmux split-window -t "${session_name}:term" -c "$sel_path"
  tmux split-window -t "${session_name}:term" -c "$sel_path"
  tmux split-window -t "${session_name}:term" -c "$sel_path"
  tmux select-layout -t "${session_name}:term" tiled
  tmux select-pane -t "${session_name}:term.0"
  tmux select-window -t "${session_name}:dev"
fi

tmux switch-client -t "$session_name"
