#!/usr/bin/env zsh
# Project switcher popup for tmux (prefix + C-j). Lists Repos/* dirs and their
# contents, sorted by last time each was opened via this switcher, with
# session/branch/last-used columns. See .tmux.conf for the keybind.

PROJECTS_DIR="$HOME/Desktop/Projects"
HISTORY_FILE="$HOME/.cache/tmux-project-switcher/history.tsv"
mkdir -p "$(dirname "$HISTORY_FILE")"

now=$(date +%s)

format_relative() {
  local ts=$1 diff
  if [[ -z "$ts" || "$ts" == "0" ]]; then
    print -r -- "never"
    return
  fi
  diff=$(( now - ts ))
  if (( diff < 60 )); then print -r -- "just now"
  elif (( diff < 3600 )); then print -r -- "$(( diff / 60 ))m ago"
  elif (( diff < 86400 )); then print -r -- "$(( diff / 3600 ))h ago"
  else print -r -- "$(( diff / 86400 ))d ago"
  fi
}

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
  rel_time=$(format_relative "$ts")

  branch="-"
  if [[ -f "$p/.git/HEAD" ]]; then
    head_content=$(<"$p/.git/HEAD")
    b="${head_content#ref: refs/heads/}"
    [[ -n "$b" && "$b" != "$head_content" ]] && branch="$b"
  fi

  session_name="${${p:t}//[. ]/_}"
  session_mark=" "
  [[ -n "${active_sessions[$session_name]}" ]] && session_mark="●"

  display="$session_mark ${(r:45:)name} ${(r:10:)category} ${(r:9:)rel_time} $branch"
  lines+=("${(l:12::0:)ts}"$'\t'"$display"$'\t'"$p")
done

selected=$(
  printf '%s\n' "${lines[@]}" \
    | sort -t $'\t' -k1,1nr \
    | cut -f2- \
    | fzf --reverse --header='select project' --delimiter=$'\t' --with-nth=1
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
