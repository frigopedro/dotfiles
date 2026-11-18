# Settings for the tmux tooling. Source it; don't execute it.
#
# The store is ~/dotfiles/tmux-settings.conf: plain tmux syntax, one
# `set -g @ws-<key> "<value>"` per setting, so tmux can source it and you can
# edit it by hand. Scripts read the file directly (no tmux round-trip, works
# outside tmux, always current); the panel (tmux-settings.sh) is the editor.
# Results come back in $REPLY or the S array, like tmux-common.zsh.

SETTINGS_FILE=${${(%):-%x}:A:h:h:h}/tmux-settings.conf

# key order = panel order. "plugins" is a pseudo-key (the @plugin lines).
typeset -ga WS_KEYS=(projects-dir extra-dirs repos-name
  editor-cmd side-pct term-panes win-dev win-term
  bar-bg bar-fg claude-status clock-format plugins)
typeset -gA WS_DEF WS_TYPE WS_SECT WS_DESC

# _ws_def <key> <section> <type> <default> <description>
# types: text · name · dir · dirs · color · choice:a,b · int:min:max · plugins
_ws_def() { WS_SECT[$1]=$2 WS_TYPE[$1]=$3 WS_DEF[$1]=$4 WS_DESC[$1]=$5 }
_ws_def projects-dir   Roots  dir  '~/Desktop/Projects' 'Folder holding your project categories (<projects-dir>/<Category>/Repos/<repo>).'
_ws_def extra-dirs     Roots  dirs '~/dotfiles:~/Downloads' 'Extra folders always listed in the project switcher.'
_ws_def repos-name     Roots  name 'Repos' 'Name of the folder inside a category that holds the git checkouts.'
_ws_def editor-cmd     Layout text 'nvim .' 'Command typed into the first pane of a new project session. "none" = nothing.'
_ws_def side-pct       Layout int:0:90 '35' 'Width (%) of the side pane next to the editor. 0 = no side pane.'
_ws_def term-panes     Layout int:0:12 '4' 'Panes in the term window (tiled). 0 = no term window.'
_ws_def win-dev        Layout name 'dev' 'Name of the editor window.'
_ws_def win-term       Layout name 'term' 'Name of the terminal window.'
_ws_def bar-bg         Theme  color '#3fb950' 'Status bar background (#rrggbb).'
_ws_def bar-fg         Theme  color '#0d1117' 'Status bar text colour (#rrggbb).'
_ws_def claude-status  Theme  choice:on,off 'on' 'Show Claude session notifications in the status bar and window list.'
_ws_def clock-format   Theme  text '%H:%M %d-%b-%y' 'strftime format of the clock on the right of the status bar.'
_ws_def plugins        Plugins plugins '' 'TPM plugins (the @plugin lines). Add or remove with the panel.'

_ws_unescape() {
  emulate -L zsh; setopt extended_glob
  REPLY=${1//(#b)\\(?)/$match[1]}
}

# _ws_expand_dirs <colon-separated> → REPLY, with a leading ~ in every part expanded
_ws_expand_dirs() {
  local -a parts=("${(@s/:/)1}")
  parts=(${parts:#-})   # "-" = an empty list
  parts=("${(@)parts/#\~/$HOME}")
  REPLY=${(j/:/)parts}
}

# settings_load → fills S[key] for every setting: file value, else default.
# Directory settings come back with ~ expanded.
settings_load() {
  typeset -gA S
  local k line re='^set -g @ws-([a-z-]+) "(.*)"[[:space:]]*$'
  S=()
  for k in $WS_KEYS; do S[$k]=${WS_DEF[$k]}; done
  if [[ -r $SETTINGS_FILE ]]; then
    while IFS= read -r line; do
      if [[ $line =~ $re ]] && (( ${+WS_DEF[$match[1]]} )); then
        k=$match[1]
        _ws_unescape "$match[2]"   # clobbers $match
        [[ -n $REPLY ]] && S[$k]=$REPLY
      fi
    done < "$SETTINGS_FILE"
  fi
  for k in $WS_KEYS; do
    case ${WS_TYPE[$k]} in dir|dirs) _ws_expand_dirs "${S[$k]}"; S[$k]=$REPLY ;; esac
  done
}

# settings_get <key> → REPLY (loads on first use)
settings_get() {
  (( ${+S} )) && (( $#S )) || settings_load
  REPLY=${S[$1]}
}

# ── writing ──────────────────────────────────────────────

# conf_rewrite <prefix> <new-line|""> → in the settings file, replaces the first
# line starting with <prefix> by <new-line> (dropping any later duplicates),
# or appends it; with "" the matching lines are just removed.
conf_rewrite() {
  local prefix=$1 new=$2 line done_= tmp=$SETTINGS_FILE.$$.tmp
  [[ -f $SETTINGS_FILE ]] || : > "$SETTINGS_FILE"
  {
    while IFS= read -r line; do
      if [[ $line == "$prefix"* ]]; then
        [[ -n $new && -z $done_ ]] && print -r -- "$new"
        done_=1
      else
        print -r -- "$line"
      fi
    done < "$SETTINGS_FILE"
    [[ -n $new && -z $done_ ]] && print -r -- "$new"
    :   # the group's status must be 0 or the mv below is skipped
  } > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
}

# settings_set <key> <value> → persists it
settings_set() {
  local esc=${2//\\/\\\\}
  esc=${esc//\"/\\\"}; esc=${esc//\$/\\\$}
  conf_rewrite "set -g @ws-$1 " "set -g @ws-$1 \"$esc\""
  settings_load
}

# settings_reset <key> → back to the default
settings_reset() {
  conf_rewrite "set -g @ws-$1 " ""
  settings_load
}

# plugins_list → reply = plugin names from the @plugin lines
plugins_list() {
  local line re="^set -g @plugin '(.*)'[[:space:]]*\$"
  reply=()
  [[ -r $SETTINGS_FILE ]] || return 0
  while IFS= read -r line; do
    [[ $line =~ $re ]] && reply+=("$match[1]")
  done < "$SETTINGS_FILE"
}

plugins_add() {
  plugins_list
  (( ${reply[(Ie)$1]} )) && return 0
  print -r -- "set -g @plugin '$1'" >> "$SETTINGS_FILE"
}

plugins_remove() { conf_rewrite "set -g @plugin '$1'" "" }
