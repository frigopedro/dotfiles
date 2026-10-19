# Shared helpers for the tmux popup scripts (project switcher, Claude session
# manager). Source it; don't execute it. Every function here runs without
# forking: results come back in $REPLY (not on stdout), so callers don't need
# a $(...) subshell and the helpers are cheap to call in a loop.

zmodload zsh/datetime   # $EPOCHSECONDS

# format_relative <epoch-seconds> → "just now" / "5m ago" / "3h ago" / "2d ago" / "never"
# Uses $now if the caller set it, otherwise the current time.
format_relative() {
  local ts=$1 diff
  if [[ -z "$ts" || "$ts" == "0" ]]; then
    REPLY="never"
    return
  fi
  diff=$(( ${now:-$EPOCHSECONDS} - ts ))
  (( diff < 0 )) && diff=0
  if (( diff < 60 )); then REPLY="just now"
  elif (( diff < 3600 )); then REPLY="$(( diff / 60 ))m ago"
  elif (( diff < 86400 )); then REPLY="$(( diff / 3600 ))h ago"
  else REPLY="$(( diff / 86400 ))d ago"
  fi
}

# format_age <epoch-seconds> → "12s" / "5m" / "3h" / "2d" (compact, for list columns)
format_age() {
  local ts=$1 diff
  [[ -z "$ts" || "$ts" == "0" ]] && { REPLY="-"; return }
  diff=$(( ${now:-$EPOCHSECONDS} - ts ))
  (( diff < 0 )) && diff=0
  if (( diff < 60 )); then REPLY="${diff}s"
  elif (( diff < 3600 )); then REPLY="$(( diff / 60 ))m"
  elif (( diff < 86400 )); then REPLY="$(( diff / 3600 ))h"
  else REPLY="$(( diff / 86400 ))d"
  fi
}

# repo_root <dir> → REPLY = the closest ancestor (or the dir itself) holding .git, or nothing
repo_root() {
  local d=${1:A}
  REPLY=""
  while [[ -n "$d" && "$d" != "/" ]]; do
    [[ -e "$d/.git" ]] && { REPLY="$d"; return 0 }
    d=${d:h}
  done
  return 1
}

# git_branch <repo-dir> → current branch, short sha when detached, or "-".
# Handles worktrees/submodules, where .git is a file saying "gitdir: <path>".
git_branch() {
  local p=$1 gitdir head_content b
  gitdir="$p/.git"
  if [[ -f "$gitdir" ]]; then
    gitdir=$(<"$gitdir")
    gitdir=${gitdir#gitdir: }
    [[ "$gitdir" != /* ]] && gitdir="$p/$gitdir"
  fi
  if [[ -f "$gitdir/HEAD" ]]; then
    head_content=$(<"$gitdir/HEAD")
    b="${head_content#ref: refs/heads/}"
    if [[ -n "$b" && "$b" != "$head_content" ]]; then
      REPLY="$b"
    else
      REPLY="${head_content[1,8]}"
    fi
    return
  fi
  REPLY="-"
}

# truncate_to <width> <text> → text cut to width with a trailing "…"
truncate_to() {
  local w=$1 s=$2
  if (( ${#s} > w )); then
    REPLY="${s[1,w-1]}…"
  else
    REPLY="$s"
  fi
}
