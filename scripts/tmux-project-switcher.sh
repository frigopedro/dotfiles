#!/usr/bin/env zsh
# Project switcher popup for tmux (prefix + C-j). Lists Repos/* dirs and their
# contents, sorted by last time each was opened via this switcher, with
# session/worktree-count/branch/last-used columns. See .tmux.conf for the keybind.
#
# Keys: enter opens/switches to the project's session, or shows its worktrees
# if it has any; ctrl-w shows the worktrees of any git repo (to create the
# first one); ctrl-x kills the selected project's open session (after a y/N
# confirmation) and refreshes.
# The right panel previews the highlighted project and its worktrees (ctrl-/
# toggles it). Pasting a git URL as the query offers "+ Clone <url>": enter
# picks a Repos folder, clones there and opens it.
#
# Worktree level: the main checkout first, then its worktrees, local branches
# and origin/* branches (fetched in the background). Typing filters; enter
# opens a worktree, creates one for a local/remote branch, or "+ Create new
# branch <query>" off the main checkout's current branch. The right panel
# previews the highlighted row (ctrl-/ toggles it). ctrl-x deletes a
# worktree, ctrl-r refetches, esc goes back. Worktrees live in
# <repo>/.worktrees/<slug> and open as their own session, "<repo>/<slug>".
#
# Usage: tmux-project-switcher.sh                          interactive picker
#        tmux-project-switcher.sh list                     rows for fzf
#        tmux-project-switcher.sh list-q <cache> <q>       rows for fzf, plus the clone row
#        tmux-project-switcher.sh preview-project <dir>    project-list preview
#        tmux-project-switcher.sh kill <dir>               kill the session for <dir>
#        tmux-project-switcher.sh rows <repo> <state> [q]  worktree-level rows
#        tmux-project-switcher.sh header <repo> <state>    worktree-level header
#        tmux-project-switcher.sh fetch <repo> <state>     background fetch, then refresh fzf
#        tmux-project-switcher.sh wt-delete <repo> <state> <row>
#        tmux-project-switcher.sh preview <repo> <state> <row>

PROJECTS_DIR="${PROJECTS_DIR:-$HOME/Desktop/Projects}"
HISTORY_FILE="$HOME/.cache/tmux-project-switcher/history.tsv"
mkdir -p "$(dirname "$HISTORY_FILE")"

now=$(date +%s)
SELF=${0:A}

source "${0:A:h}/lib/tmux-common.zsh"
source "${0:A:h}/lib/git-worktree.zsh"

# session_for <dir> → REPLY = the tmux session name used for that project
session_for() { REPLY="${${1:t}//[. ]/_}" }

# wt_session_for <repo> <worktree> → REPLY = "<repo session>/<slug>". tmux
# doesn't allow ':' or '.' in session names, hence '/' and the '_' swaps.
wt_session_for() {
  local slug
  if [[ $2 == "$1/$WT_DIR/"* ]]; then slug=${2#"$1/$WT_DIR/"}; else slug=${2:t}; fi
  session_for "$1"
  REPLY="$REPLY/${slug//[.: ]/_}"
}

# load_history → last_used[path] = epoch of the last time it was opened
load_history() {
  typeset -gA last_used
  local ts hist_p
  if [[ -f "$HISTORY_FILE" ]]; then
    while IFS=$'\t' read -r ts hist_p; do
      [[ -n "$hist_p" ]] && last_used[$hist_p]=$ts
    done < "$HISTORY_FILE"
  fi
}

# load_sessions → active_sessions[name] = 1 for every open session, in one
# round-trip to the tmux server instead of one has-session call per row.
load_sessions() {
  typeset -gA active_sessions
  local s
  for s in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"}; do
    active_sessions[$s]=1
  done
}

# touch_history <path>... → marks each path as opened now
touch_history() {
  local line p
  local -a keep
  local -A drop
  for p in "$@"; do drop[$p]=1; done
  if [[ -f "$HISTORY_FILE" ]]; then
    for line in "${(@f)$(<"$HISTORY_FILE")}"; do
      [[ -n $line && -z ${drop[${line#*$'\t'}]} ]] && keep+=("$line")
    done
  fi
  for p in "$@"; do keep+=("$now"$'\t'"$p"); done
  print -rl -- "${keep[@]}" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
}

# open_session <dir> <session> → creates the dev/term layout unless the
# session already exists, then switches the client to it.
open_session() {
  local dir=$1 s=$2
  if ! tmux has-session -t "=$s" 2>/dev/null; then
    tmux new-session -d -s "$s" -c "$dir" -n dev
    tmux send-keys -t "=${s}:dev.0" 'nvim .' C-m
    tmux split-window -h -p 35 -t "=${s}:dev" -c "$dir"
    tmux select-pane -t "=${s}:dev.0"
    tmux new-window -t "=${s}:" -n term -c "$dir"
    tmux split-window -t "=${s}:term" -c "$dir"
    tmux split-window -t "=${s}:term" -c "$dir"
    tmux split-window -t "=${s}:term" -c "$dir"
    tmux select-layout -t "=${s}:term" tiled
    tmux select-pane -t "=${s}:term.0"
    tmux select-window -t "=${s}:dev"
  fi
  tmux switch-client -t "=$s"
}

open_project() {
  touch_history "$1"
  session_for "$1"
  open_session "$1" "$REPLY"
}

open_worktree() {
  touch_history "$1" "$2"
  wt_session_for "$1" "$2"
  open_session "$2" "$REPLY"
}

# session_summary <session> → prints the window count and the programs other
# than shells that would be killed with it.
session_summary() {
  local -a procs
  procs=(${(u)${(f)"$(tmux list-panes -s -t "=$1" -F '#{pane_current_command}')"}})
  procs=(${procs:#(zsh|bash|sh|fish|-zsh)})
  local windows=$(tmux list-windows -t "=$1" 2>/dev/null | wc -l | tr -d ' ')
  print -r -- "  Session '$1' is open ($windows windows)."
  (( $#procs )) && print -r -- "  Running: ${(j:, :)procs}"
}

# leave_and_kill_session <session> → kills it. Killing the session the client
# is on would detach it, so move the client to another session first. Refuses
# (returns 1) if it's the only one.
leave_and_kill_session() {
  local sess=$1 current
  local -a others
  current=$(tmux display-message -p '#{client_session}' 2>/dev/null)
  if [[ $current == $sess ]]; then
    others=(${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null)"})
    others=(${others:#$sess})
    if (( ! $#others )); then
      print -r -- ""; print -r -- "  It's the only session; not killing it."; sleep 1.5; return 1
    fi
    tmux switch-client -l 2>/dev/null
    [[ $(tmux display-message -p '#{client_session}') == $sess ]] && tmux switch-client -t "=${others[1]}"
  fi
  tmux kill-session -t "=$sess"
}

# Kill the session for a project dir, after confirming. Runs inside fzf's
# execute(), so it owns the terminal while it asks.
kill_project_session() {
  local dir=$1 sess key
  session_for "$dir"; sess=$REPLY
  if ! tmux has-session -t "=$sess" 2>/dev/null; then
    print -r -- "No open session for ${dir:t}."; sleep 1; return
  fi

  print -r -- ""
  session_summary "$sess"
  print -rn -- "  Kill it? [y/N] "
  read -k1 -s key </dev/tty
  [[ $key == [yY] ]] || return
  leave_and_kill_session "$sess"
}

# fail <message...> → shows an error and waits for a key
fail() {
  print -r -- ""
  print -r -- "  ✗ ${(pj:\n    :)@}"
  print -rn -- "  press any key "
  read -k1 -s </dev/tty
  return 1
}

# ── Worktree level ───────────────────────────────────────
# Per-popup state lives in a temp dir: status (fetching / ok / unreachable /
# noorigin), base (main checkout's branch, "" if detached), and the rows and
# branches caches. The caches keep change:reload (one run per keystroke)
# cheap; anything that changes branches or worktrees deletes them.

# label <text> → REPLY = text padded to the label column. Never truncates:
# fzf only searches this field, so a cut-off name would stop matching.
label() { REPLY=${(r:46:)1}; (( ${#1} > 46 )) && REPLY=$1 }

# build_rows <repo> <state> → writes $state/rows and $state/branches. Rows are
# label \t info \t type \t data; fzf only searches the label, so a query
# doesn't fuzzy-match worktree paths or the local/remote tags.
build_rows() {
  local repo=$1 state=$2 st base name b p i ref lbl mark when
  local -a rows wts branches
  local -A owned locals
  [[ -r $state/status ]] && st=$(<"$state/status")
  name=${repo:t}
  load_history; load_sessions
  wt_list "$repo"

  # The main checkout, always first.
  b=${wt_branches[1]}
  [[ -n $b ]] && owned[$b]=1
  session_for "$repo"; mark=" "; [[ -n ${active_sessions[$REPLY]} ]] && mark="●"
  label "$mark ★ $name (${b:-detached ${wt_heads[1][1,8]}})"
  rows+=("$REPLY"$'\t'"main checkout"$'\t'main$'\t'"$repo")

  # Worktrees, most recently opened first. The zero-padded timestamp prefix
  # makes a reverse string sort a numeric one.
  for (( i = 2; i <= $#wt_paths; i++ )); do
    p=${wt_paths[i]} b=${wt_branches[i]}
    [[ -n $b ]] && owned[$b]=1
    lbl="$name:${b:-detached ${wt_heads[i][1,8]}}"
    wt_session_for "$repo" "$p"; mark=" "; [[ -n ${active_sessions[$REPLY]} ]] && mark="●"
    format_relative "${last_used[$p]:-0}"; when=$REPLY
    label "$mark   $lbl"
    wts+=("${(l:12::0:)${last_used[$p]:-0}}"$'\t'"$REPLY"$'\t'"${(r:9:)when} ${p#"$repo/"}"$'\t'wt$'\t'"$p")
  done
  wts=(${(O)wts})
  rows+=("${(@)wts#*$'\t'}")

  for ref in ${(f)"$(git -C "$repo" for-each-ref --format='%(refname)' refs/heads)"}; do
    b=${ref#refs/heads/}
    locals[$b]=1
    (( ${+owned[$b]} )) && continue
    label "    $b"
    rows+=("$REPLY"$'\t'"local branch"$'\t'local$'\t'"$b")
  done

  # Remote-tracking refs are from the last successful fetch; hide them when
  # this one failed so the list really is local-only.
  if [[ $st != (unreachable|noorigin) ]]; then
    for ref in ${(f)"$(git -C "$repo" for-each-ref --format='%(refname)' refs/remotes/origin)"}; do
      b=${ref#refs/remotes/origin/}
      [[ $b == HEAD ]] && continue
      branches+=("$b")
      (( ${+owned[$b]} || ${+locals[$b]} )) && continue
      label "    origin/$b"
      rows+=("$REPLY"$'\t'"remote branch"$'\t'remote$'\t'"$b")
    done
  fi

  branches+=(${(k)owned} ${(k)locals})
  print -rl -- "${rows[@]}" > "$state/rows.tmp" && mv "$state/rows.tmp" "$state/rows"
  print -rl -- "${branches[@]}" > "$state/branches.tmp" && mv "$state/branches.tmp" "$state/branches"
}

# print_rows <repo> <state> [query] → cached rows plus "+ Create new branch"
# when the query isn't already a branch name.
print_rows() {
  local repo=$1 state=$2 q=${3// /} base
  [[ -f $state/rows && -f $state/branches ]] || build_rows "$repo" "$state"
  print -r -- "$(<"$state/rows")"
  [[ -z $q ]] && return
  (( ${${(f)"$(<"$state/branches")"}[(Ie)$q]} )) && return
  base=$(<"$state/base")
  label "  + Create new branch $q"
  print -r -- "$REPLY"$'\t'"from ${base:-… (detached, pick a base)}"$'\t'create$'\t'"$q"
}

print_header() {
  local st base s
  st=$(<"$2/status") base=$(<"$2/base")
  case $st in
    fetching)    s="⟳ fetching origin…" ;;
    ok)          s="✓ origin fetched" ;;
    unreachable) s="⚠ origin unreachable — local branches only" ;;
    noorigin)    s="no origin remote — local branches only" ;;
  esac
  print -r -- "${1:t} · default: ${base:-⚠ detached HEAD} · $s"
  print -r -- "enter: open/create · ctrl-x: delete · ctrl-r: fetch · ctrl-/: preview · esc: back"
}

# preview_row <repo> <state> <row> → the right-hand panel: what the row is,
# how it compares to its upstream (checkouts) or to the default branch
# (branches), uncommitted changes, and recent commits.
preview_row() {
  local repo=$1 state=$2 type data dir ref b base
  local B=$'\e[1m' D=$'\e[2m' Y=$'\e[33m' G=$'\e[32m' Rd=$'\e[31m' N=$'\e[0m'
  local -a f=("${(@ps:\t:)3}") counts
  type=${f[3]} data=${f[4]}
  base=$(<"$state/base")
  dir=$repo ref=HEAD

  case $type in
    main|wt)
      dir=$data
      b=$(git -C "$dir" branch --show-current 2>/dev/null)
      print -r -- "$B${b:-detached HEAD}$N  ${D}(${${type:/main/main checkout}:/wt/worktree})$N"
      print -r -- "${D}path$N     ${dir/#$HOME/~}"
      if [[ $type == main ]]; then session_for "$repo"; else wt_session_for "$repo" "$dir"; fi
      if tmux has-session -t "=$REPLY" 2>/dev/null; then
        print -r -- "${D}session$N  $G● $REPLY$N"
      else
        print -r -- "${D}session$N  $REPLY ${D}(not open)$N"
      fi
      checkout_state "$dir" 15
      ;;
    local|remote)
      if [[ $type == local ]]; then ref=refs/heads/$data; else ref=refs/remotes/origin/$data; fi
      print -r -- "$B$data$N  ${D}($type branch, no worktree yet)$N"
      wt_path_for "$repo" "$data"
      print -r -- "${D}enter$N    creates ${REPLY#"$repo/"}"
      [[ $type == remote ]] && print -r -- "${D}tracks$N   origin/$data"
      if [[ -n $base && $base != $data ]]; then
        counts=(${=$(git -C "$repo" rev-list --left-right --count "$ref...refs/heads/$base" 2>/dev/null)})
        (( $#counts )) && print -r -- "${D}vs $base$N  ↑${counts[1]} ↓${counts[2]}"
      fi
      ;;
    create)
      print -r -- "$B$data$N  ${D}(new branch)$N"
      if ! git -C "$repo" check-ref-format --branch "$data" &>/dev/null; then
        print -r -- "$Rd⚠ not a valid branch name$N"; return
      fi
      wt_path_for "$repo" "$data"
      print -r -- "${D}enter$N    creates ${REPLY#"$repo/"}"
      if [[ -n $base ]]; then
        print -r -- "${D}from$N     $base ${D}(local, the main checkout's branch)$N"
        ref=refs/heads/$base
      else
        print -r -- "$Y⚠ main checkout is detached; you'll pick the base after enter$N"
      fi
      ;;
    *) return ;;
  esac

  print
  print -r -- "${B}Recent commits$N ${D}($ref)$N"
  git -C "$dir" log --color=always -n 20 \
    --format='%C(yellow)%h%C(reset) %s %C(dim)%cr · %an%C(reset)' "$ref" 2>/dev/null
}

# checkout_state <dir> <max> → prints the upstream line and up to <max>
# uncommitted changes of a checkout (shared by both previews).
checkout_state() {
  local dir=$1 max=$2 up
  local B=$'\e[1m' D=$'\e[2m' Y=$'\e[33m' G=$'\e[32m' N=$'\e[0m'
  local -a counts changes
  if up=$(git -C "$dir" rev-parse -q --abbrev-ref '@{u}' 2>/dev/null); then
    counts=(${=$(git -C "$dir" rev-list --left-right --count 'HEAD...@{u}' 2>/dev/null)})
    print -r -- "${D}upstream$N $up  ↑${counts[1]} ↓${counts[2]}"
  else
    print -r -- "${D}upstream$N ${D}none$N"
  fi
  changes=(${(f)"$(git -C "$dir" -c color.status=always status --short 2>/dev/null)"})
  print
  if (( $#changes )); then
    print -r -- "$Y$B${#changes} uncommitted change(s)$N"
    print -rl -- "${(@)changes[1,max]}"
    (( $#changes > max )) && print -r -- "${D}… $(( $#changes - max )) more$N"
  else
    print -r -- "$G✓ clean$N"
  fi
}

# preview_project <dir> → the project list's right-hand panel: the checkout's
# state, its worktrees (session ● and uncommitted changes for each), and recent
# commits. Also describes the "+ Clone <url>" row.
preview_project() {
  local dir=$1 b p i n mark st
  local B=$'\e[1m' D=$'\e[2m' Y=$'\e[33m' G=$'\e[32m' N=$'\e[0m'
  if [[ $dir == clone:* ]]; then
    clone_name "${dir#clone:}"
    print -r -- "${B}Clone$N ${dir#clone:}"
    print -r -- "${D}folder$N   ${REPLY:-?}"
    print
    print -r -- "enter: pick the Repos folder to clone into, then open it"
    return
  fi
  if [[ ! -e $dir/.git ]]; then
    print -r -- "$B${dir/#$HOME/~}$N  ${D}(not a git repo)$N"
    print
    ls -1p "$dir" 2>/dev/null | head -40
    return
  fi

  git_branch "$dir"
  print -r -- "$B${dir:t}$N  ${D}$REPLY$N"
  print -r -- "${D}path$N     ${dir/#$HOME/~}"
  load_sessions
  session_for "$dir"
  if [[ -n ${active_sessions[$REPLY]} ]]; then
    print -r -- "${D}session$N  $G● $REPLY$N"
  else
    print -r -- "${D}session$N  $REPLY ${D}(not open)$N"
  fi
  checkout_state "$dir" 8

  print
  wt_list "$dir"
  if (( $#wt_paths > 1 )); then
    print -r -- "${B}Worktrees ($(( $#wt_paths - 1 )))$N  ${D}enter to pick one$N"
    for (( i = 2; i <= $#wt_paths; i++ )); do
      p=${wt_paths[i]} b=${wt_branches[i]:-detached ${wt_heads[i][1,8]}}
      (( ${#b} < 32 )) && b=${(r:32:)b}
      wt_session_for "$dir" "$p"; mark=" "; [[ -n ${active_sessions[$REPLY]} ]] && mark="$G●$N"
      wt_dirty "$p"; n=$REPLY
      if (( n )); then st="$Y${(r:10:):-$n changed}$N"; else st="$G${(r:10:):-✓ clean}$N"; fi
      print -r -- " $mark $b $st ${D}${p#"$dir/"}$N"
    done
  else
    print -r -- "${D}No worktrees · ctrl-w to create one$N"
  fi

  print
  print -r -- "${B}Recent commits$N"
  git -C "$dir" log --color=always -n 10 \
    --format='%C(yellow)%h%C(reset) %s %C(dim)%cr · %an%C(reset)' 2>/dev/null
}

# ── Cloning ──────────────────────────────────────────────

# is_git_url <text> → true for anything git clone takes as a remote URL
is_git_url() { [[ $1 == (https://|http://|ssh://|git://|file://|git@)?* ]] }

# clone_name <url> → REPLY = the folder git would clone into:
# git@github.com:foo/bar.git → bar
clone_name() { REPLY=${${${1%/}%.git}##*[/:]} }

# pick_repos_dir <name> → REPLY = the Repos folder chosen to clone into,
# most recently used category first.
pick_repos_dir() {
  local name=$1 d p ts sel note
  local -a dirs rows
  load_history
  dirs=(${(f)"$(find "$PROJECTS_DIR" -maxdepth 2 -type d -name Repos 2>/dev/null | sort)"})
  (( $#dirs )) || { fail "No Repos folders under $PROJECTS_DIR."; return 1 }
  for d in $dirs; do
    ts=0
    for p in ${(k)last_used}; do
      [[ $p == "$d/"* ]] && (( last_used[$p] > ts )) && ts=${last_used[$p]}
    done
    note=""; [[ -e $d/$name ]] && note="  (already exists)"
    rows+=("${(l:12::0:)ts}"$'\t'"${d#"$PROJECTS_DIR/"}/$name$note"$'\t'"$d")
  done
  rows=(${(O)rows})
  sel=$(
    print -rl -- "${(@)rows#*$'\t'}" \
      | fzf --reverse --delimiter=$'\t' --with-nth=1 --header='Clone into which folder? (esc: back)'
  ) || return 1
  REPLY=${sel##*$'\t'}
}

# clone_repo <url> → REPLY = the cloned checkout. If the folder already holds
# a clone of the same URL it's reused instead (so repeat runs just open it).
clone_repo() {
  local url=$1 name dest
  clone_name "$url"; name=$REPLY
  [[ -n $name && $name != (.|..) ]] || { fail "Can't work out a folder name from '$url'."; return 1 }
  pick_repos_dir "$name" || return 1
  dest=$REPLY/$name
  if [[ -e $dest ]]; then
    [[ $(git -C "$dest" remote get-url origin 2>/dev/null) == "$url" ]] && { REPLY=$dest; return 0 }
    fail "${dest#"$PROJECTS_DIR/"} already exists (and isn't a clone of that URL)."
    return 1
  fi
  print -r -- ""
  print -r -- "  Cloning $url"
  print -r -- "     into ${dest#"$PROJECTS_DIR/"}"
  print -r -- ""
  git clone -- "$url" "$dest" || { fail "git clone failed."; return 1 }
  REPLY=$dest
}

# refresh_action <repo> <state> → the fzf actions that re-read rows and header
refresh_action() {
  REPLY="reload(${(q)SELF} rows ${(q)1} ${(q)2} {q})+transform-header(${(q)SELF} header ${(q)1} ${(q)2})"
}

# fetch_in_background <repo> <state> → marks the state as fetching and returns
# at once; when the fetch ends, tells fzf (via its --listen port) to refresh.
fetch_in_background() {
  local repo=$1 state=$2
  if ! git -C "$repo" remote get-url origin &>/dev/null; then
    print noorigin > "$state/status"; return
  fi
  print fetching > "$state/status"
  {
    wt_fetch "$repo"
    [[ -d $state ]] || exit
    print -r -- "$REPLY" > "$state/status"
    rm -f "$state/rows"
    refresh_action "$repo" "$state"
    [[ -n $FZF_PORT ]] && curl -fsS -XPOST "localhost:$FZF_PORT" -d "$REPLY"
  } &>/dev/null &!
}

# pick_base <repo> → REPLY = the start point for a new branch when the main
# checkout is detached.
pick_base() {
  local repo=$1 head sel
  head=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
  sel=$(
    {
      print -r -- "HEAD ($head, detached)"$'\t'HEAD
      git -C "$repo" for-each-ref --format=$'%(refname:short)\t%(refname:short)' refs/heads refs/remotes/origin \
        | grep -v $'^origin\t'
    } | fzf --reverse --delimiter=$'\t' --with-nth=1 \
          --header=$'⚠ The main checkout is in detached HEAD.\nPick the base for the new branch (esc: cancel)'
  ) || return 1
  REPLY=${sel##*$'\t'}
}

# add_worktree <repo> <branch> <local|remote|new> [base] → REPLY = the path of
# the checkout for <branch>: an existing one if it's already checked out
# somewhere (main checkout included), otherwise a new .worktrees/<slug>.
add_worktree() {
  local repo=$1 branch=$2 mode=$3 base=$4 dir err
  wt_owner "$repo" "$branch" && return 0
  wt_path_for "$repo" "$branch"; dir=$REPLY
  wt_ensure_gitignore "$repo"
  git -C "$repo" worktree prune
  case $mode in
    local)  err=$(git -C "$repo" worktree add --quiet "$dir" "$branch" 2>&1) ;;
    remote) err=$(git -C "$repo" worktree add --quiet --track -b "$branch" "$dir" "origin/$branch" 2>&1) ;;
    new)    err=$(git -C "$repo" worktree add --quiet --no-track -b "$branch" "$dir" "$base" 2>&1) ;;
  esac || { fail "Couldn't create the worktree for '$branch':" "${(@f)err}"; return 1 }
  REPLY=$dir
}

# create_branch <repo> <name> → REPLY = worktree path for a branch typed in
# the query. Falls back to the existing local/remote branch if one appeared
# since the rows were built.
create_branch() {
  local repo=$1 name=$2 base
  git -C "$repo" check-ref-format --branch "$name" &>/dev/null \
    || { fail "'$name' isn't a valid branch name."; return 1 }
  if git -C "$repo" show-ref -q --verify "refs/heads/$name"; then
    add_worktree "$repo" "$name" local
  elif git -C "$repo" show-ref -q --verify "refs/remotes/origin/$name"; then
    add_worktree "$repo" "$name" remote
  else
    base=$(git -C "$repo" symbolic-ref -q --short HEAD)
    if [[ -z $base ]]; then pick_base "$repo" || return 1; base=$REPLY; fi
    add_worktree "$repo" "$name" new "$base"
  fi
}

# delete_worktree <repo> <state> <row> → confirms, kills the worktree's
# session and removes it (the branch is kept). Runs inside fzf's execute().
delete_worktree() {
  local repo=$1 state=$2 type dir sess key dirty unpushed force=
  local -a f=("${(@ps:\t:)3}")
  type=${f[3]} dir=${f[4]}
  if [[ $type != wt ]]; then
    print -r -- "  Only worktrees can be deleted here."; sleep 1; return
  fi
  wt_session_for "$repo" "$dir"; sess=$REPLY
  wt_dirty "$dir"; dirty=$REPLY
  wt_unpushed "$dir"; unpushed=$REPLY

  print -r -- ""
  print -r -- "  Delete worktree '${dir#"$repo/"}' (${$(git -C "$dir" branch --show-current 2>/dev/null):-detached})?"
  (( dirty )) && print -r -- "  ⚠ $dirty uncommitted change(s) will be lost"
  (( unpushed )) && print -r -- "  ⚠ $unpushed unpushed commit(s) (kept on the branch)"
  tmux has-session -t "=$sess" 2>/dev/null && session_summary "$sess"
  print -r -- "  The branch itself is kept."
  print -rn -- "  [y/N] "
  read -k1 -s key </dev/tty
  [[ $key == [yY] ]] || return

  if tmux has-session -t "=$sess" 2>/dev/null; then
    leave_and_kill_session "$sess" || return
  fi
  (( dirty )) && force=--force
  git -C "$repo" worktree remove $force "$dir" 2>&1 || { fail "git worktree remove failed."; return }
  rm -f "$state/rows" "$state/branches"
}

# worktree_menu <repo> → returns 0 once something was opened, 1 on esc (back
# to the project list).
worktree_menu() {
  local repo=${1:A} state sel rc dir
  local -a f
  state=$(mktemp -d "${TMPDIR:-/tmp}/tmux-wt.XXXXXX")
  print -r -- "$(git -C "$repo" symbolic-ref -q --short HEAD)" > "$state/base"
  # Placeholder status for the first header; the real fetch starts from fzf's
  # start event so it inherits $FZF_PORT.
  if git -C "$repo" remote get-url origin &>/dev/null; then
    print fetching > "$state/status"
  else
    print noorigin > "$state/status"
  fi

  local self=${(q)SELF} r=${(q)repo} s=${(q)state}
  refresh_action "$repo" "$state"; local refresh=$REPLY
  while true; do
    sel=$(
      print_rows "$repo" "$state" \
        | fzf --listen --reverse --no-sort --delimiter=$'\t' --with-nth=1,2 --nth=1 \
            --prompt='branch> ' --header="$(print_header "$repo" "$state")" \
            --bind="start:execute-silent($self fetch $r $s)" \
            --bind="change:reload($self rows $r $s {q})" \
            --bind="ctrl-r:execute-silent($self fetch $r $s)+$refresh" \
            --preview="$self preview $r $s {}" --preview-window=right,55%,wrap,border-left \
            --bind="ctrl-/:toggle-preview" \
            --bind="ctrl-x:execute($self wt-delete $r $s {})+$refresh"
    )
    rc=$?
    (( rc == 130 )) && { rm -rf "$state"; return 1 }
    [[ -z $sel ]] && continue

    f=("${(@ps:\t:)sel}")
    case ${f[3]} in
      main)   open_project "$repo"; break ;;
      wt)     open_worktree "$repo" "${f[4]}"; break ;;
      local)  add_worktree "$repo" "${f[4]}" local || continue ;;
      remote) add_worktree "$repo" "${f[4]}" remote || continue ;;
      create) create_branch "$repo" "${f[4]}" || continue ;;
      *)      continue ;;
    esac
    dir=$REPLY
    if [[ $dir == "$repo" ]]; then open_project "$repo"; else open_worktree "$repo" "$dir"; fi
    break
  done
  rm -rf "$state"
  return 0
}

case $1 in
  kill)      kill_project_session "$2"; exit 0 ;;
  rows)      print_rows "$2" "$3" "$4"; exit 0 ;;
  header)    print_header "$2" "$3"; exit 0 ;;
  fetch)     fetch_in_background "$2" "$3"; exit 0 ;;
  wt-delete) delete_worktree "$2" "$3" "$4"; exit 0 ;;
  preview)   preview_row "$2" "$3" "$4"; exit 0 ;;
  preview-project) preview_project "$2"; exit 0 ;;
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

  load_history
  load_sessions

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

    # Worktree count, without forking git: one admin dir per worktree.
    wt_mark=""
    wts=($p/.git/worktrees/*(N/))
    (( $#wts )) && wt_mark="⎇${#wts}"

    display="$session_mark ${(r:45:)name} ${(r:10:)category} ${(r:9:)rel_time} ${(r:4:)wt_mark}$branch"
    lines+=("${(l:12::0:)ts}"$'\t'"$display"$'\t'"$p")
  done

  printf '%s\n' "${lines[@]}" | sort -t $'\t' -k1,1nr | cut -f2-
}

[[ $1 == list ]] && { build_list; exit 0 }

# list-q <cache> <query> → the project rows (cached for the popup's lifetime,
# since this runs on every keystroke) plus "+ Clone <url>" when the query is a
# git URL.
if [[ $1 == list-q ]]; then
  [[ -s $2 ]] || build_list > "$2"
  print -r -- "$(<"$2")"
  q=${3// /}
  is_git_url "$q" && print -r -- "+ Clone $q"$'\t'"clone:$q"
  exit 0
fi

# Level-1 cache; worktree_menu returns here on esc, so it's rebuilt each lap.
L1_CACHE=$(mktemp "${TMPDIR:-/tmp}/tmux-projects.XXXXXX")
trap 'rm -f "$L1_CACHE"' EXIT
self=${(q)SELF} c=${(q)L1_CACHE}

while true; do
  build_list > "$L1_CACHE"
  out=$(
    print -r -- "$(<"$L1_CACHE")" \
      | fzf --reverse --delimiter=$'\t' --with-nth=1 --expect=ctrl-w \
          --header='select project · paste a git URL to clone · ctrl-w: worktrees · ctrl-x: kill session' \
          --preview="$self preview-project {2}" --preview-window=right,45%,wrap,border-left \
          --bind="ctrl-/:toggle-preview" \
          --bind="change:reload($self list-q $c {q})" \
          --bind="ctrl-x:execute($self kill {2})+reload(rm -f $c; $self list-q $c {q})"
  ) || exit 0
  key=${out%%$'\n'*}
  selected=${out#*$'\n'}
  sel_path=${selected##*$'\t'}

  if [[ $sel_path == clone:* ]]; then
    clone_repo "${sel_path#clone:}" && { open_project "$REPLY"; exit 0 }
    continue
  fi
  [[ -z "$sel_path" || ! -d "$sel_path" ]] && exit 0

  # Main checkouts only (.git is a dir): worktree level on ctrl-w, or on enter
  # when the repo already has worktrees.
  wts=($sel_path/.git/worktrees/*(N/))
  if [[ -d $sel_path/.git ]] && { [[ $key == ctrl-w ]] || (( $#wts )) }; then
    worktree_menu "$sel_path" && exit 0
    continue
  fi

  open_project "$sel_path"
  exit 0
done
