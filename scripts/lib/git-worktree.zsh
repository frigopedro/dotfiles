# Git worktree helpers for the project switcher. Source it; don't execute it.
# Worktrees live in <repo>/.worktrees/<slug>. Like tmux-common.zsh, results
# come back in $REPLY (or in the wt_* arrays for wt_list).

WT_DIR=.worktrees

# wt_slug <branch> → REPLY = folder-safe name: feature/foo → feature-foo
wt_slug() { REPLY=${1//[^A-Za-z0-9._-]/-} }

# wt_list <repo> → wt_paths / wt_branches / wt_heads, main checkout first.
# wt_branches[i] is "" when that worktree is detached. Prunable entries (the
# folder was deleted by hand) are skipped.
wt_list() {
  local line p= b= h= skip=
  wt_paths=() wt_branches=() wt_heads=()
  # The trailing "worktree " sentinel flushes the last record.
  for line in "${(@f)$(git -C "$1" worktree list --porcelain 2>/dev/null)}" "worktree "; do
    case $line in
      worktree\ *)
        [[ -n $p && -z $skip ]] && { wt_paths+=("$p"); wt_branches+=("$b"); wt_heads+=("$h") }
        p=${line#worktree } b= h= skip= ;;
      HEAD\ *)   h=${line#HEAD } ;;
      branch\ *) b=${line#branch refs/heads/} ;;
      prunable*|bare) skip=1 ;;
    esac
  done
}

# wt_owner <repo> <branch> → REPLY = path of the checkout (main or worktree)
# that has <branch> checked out; returns 1 if none does.
wt_owner() {
  local i
  wt_list "$1"
  for (( i = 1; i <= $#wt_paths; i++ )); do
    [[ ${wt_branches[i]} == "$2" ]] && { REPLY=${wt_paths[i]}; return 0 }
  done
  REPLY=""; return 1
}

# wt_path_for <repo> <branch> → REPLY = a free <repo>/.worktrees/<slug>[-N]
# path. The -N suffix only kicks in when another branch's folder (feature/foo
# vs feature-foo) or leftover junk already sits there.
wt_path_for() {
  local base n=2
  wt_slug "$2"; base="$1/$WT_DIR/$REPLY"
  REPLY=$base
  while [[ -e $REPLY ]]; do REPLY="$base-$n"; (( n++ )); done
}

# wt_ensure_gitignore <repo> → appends ".worktrees/" to <repo>/.gitignore
# unless git already ignores it (from any ignore source), so repeat runs never
# add a second entry.
wt_ensure_gitignore() {
  local repo=$1 gi=$1/.gitignore
  mkdir -p "$repo/$WT_DIR"
  git -C "$repo" check-ignore -q "$WT_DIR" && return 0
  [[ -s $gi && -n $(tail -c1 "$gi") ]] && print >> "$gi"
  print -r -- "$WT_DIR/" >> "$gi"
}

# wt_dirty <worktree> → REPLY = number of changed/untracked files
wt_dirty() {
  local -a lines=(${(f)"$(git -C "$1" status --porcelain 2>/dev/null)"})
  REPLY=$#lines
}

# wt_unpushed <worktree> → REPLY = commits not on the upstream (or, with no
# upstream, not on any remote branch). "" when the repo has no remotes at all,
# where "unpushed" means nothing.
wt_unpushed() {
  if git -C "$1" rev-parse -q --verify '@{u}' &>/dev/null; then
    REPLY=$(git -C "$1" rev-list --count '@{u}..HEAD' 2>/dev/null)
  elif [[ -n $(git -C "$1" remote 2>/dev/null) ]]; then
    REPLY=$(git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null)
  else
    REPLY=""
  fi
}

# wt_fetch <repo> → REPLY = ok / unreachable / noorigin. Never prompts for
# credentials and gives up after ~10s (macOS has no timeout(1)), so a dead
# remote can't hang the popup.
wt_fetch() {
  local pid i
  git -C "$1" remote get-url origin &>/dev/null || { REPLY=noorigin; return 1 }
  GIT_TERMINAL_PROMPT=0 \
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o ConnectTimeout=5 -o BatchMode=yes" \
    git -C "$1" fetch --prune --quiet origin &>/dev/null &
  pid=$!
  for i in {1..100}; do
    kill -0 $pid 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 $pid 2>/dev/null; then
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    REPLY=unreachable; return 1
  fi
  wait $pid && { REPLY=ok; return 0 }
  REPLY=unreachable; return 1
}
