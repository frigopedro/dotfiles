#!/usr/bin/env zsh
# Settings panel for the tmux tooling (prefix + S). Lists every setting from
# lib/tmux-settings.zsh with its current value; enter edits it, ctrl-r resets it
# to the default, ctrl-/ toggles the description. Changes are written to
# tmux-settings.conf and applied at once (the theme is re-applied to the
# running server; layout/root settings are read by the scripts on next use).
#
# Usage: tmux-settings.sh                 interactive panel
#        tmux-settings.sh apply-theme     (re)apply the status bar settings
#        tmux-settings.sh preview <key>   description panel

SELF=${0:A}
source "${0:A:h}/lib/tmux-common.zsh"
source "${0:A:h}/lib/tmux-settings.zsh"

B=$'\e[1m' D=$'\e[2m' Y=$'\e[33m' G=$'\e[32m' N=$'\e[0m'

# ── Status bar ───────────────────────────────────────────
# tmux's status-style doesn't expand options, so the theme settings are applied
# by setting the real options from here (also run from .tmux.conf).
apply_theme() {
  settings_load
  local bg=${S[bar-bg]} fg=${S[bar-fg]} right w
  right="#[fg=$fg]${S[clock-format]}"
  tmux set -g status-style "bg=$bg,fg=$fg"
  tmux set -g status-left "#[bold,fg=$fg] #S #[default] | "
  if [[ ${S[claude-status]} == on ]]; then
    right="#{@claude_status}#(${SELF:h}/claude-sessions.sh publish)$right"
  else
    # No publishing any more: drop what was published.
    tmux set -gu @claude_status
    for w in ${(f)"$(tmux list-windows -a -F '#{window_id}')"}; do tmux set -wu -t "$w" @claude_flag; done
  fi
  tmux set -g status-right "$right"
}

# ── Rows and preview ─────────────────────────────────────

# shown <key> <value> → REPLY, as the panel displays it
shown() {
  local k=$1 v=$2
  case ${WS_TYPE[$k]} in
    dir|dirs) v=${v//:/, }; v=${v//$HOME/\~}; [[ -z $v ]] && v="(none)" ;;
    plugins)  plugins_list; v="${#reply} installed" ;;
  esac
  REPLY=$v
}

# default_of <key> → REPLY, the default as `settings_load` would return it
default_of() {
  REPLY=${WS_DEF[$1]}
  case ${WS_TYPE[$1]} in dir|dirs) _ws_expand_dirs "$REPLY" ;; esac
}

cmd_rows() {
  local k val def
  settings_load
  for k in $WS_KEYS; do
    shown "$k" "${S[$k]}"; val=$REPLY
    default_of "$k"; def=$REPLY
    if [[ ${S[$k]} == "$def" || ${WS_TYPE[$k]} == plugins ]]; then
      print -r -- "${D}${(r:8:)WS_SECT[$k]}${N} ${(r:15:)k} $val"$'\t'"$k"
    else
      print -r -- "${D}${(r:8:)WS_SECT[$k]}${N} ${(r:15:)k} ${Y}${val}${N}  ${D}(default: ${def//$HOME/~})${N}"$'\t'"$k"
    fi
  done
}

cmd_preview() {
  local k=$1 t=${WS_TYPE[$1]} val def
  [[ -n $t ]] || return
  settings_load
  shown "$k" "${S[$k]}"; val=$REPLY
  default_of "$k"; def=${REPLY//$HOME/~}
  print -r -- "$B$k$N  ${D}${WS_SECT[$k]}$N"
  print
  print -r -- "${WS_DESC[$k]}"
  print
  print -r -- "${D}now$N      $val"
  [[ $t == plugins ]] || print -r -- "${D}default$N  $def"
  case $t in
    int:*)    print -r -- "${D}allowed$N  whole number ${${t#int:}%%:*}–${t##*:}" ;;
    color)    print -r -- "${D}allowed$N  #rrggbb" ;;
    choice:*) print -r -- "${D}allowed$N  ${${t#choice:}//,/ | }" ;;
    name)     print -r -- "${D}allowed$N  no spaces, '.' or ':'" ;;
    dir)      print -r -- "${D}allowed$N  an existing folder (~ ok)" ;;
  esac
  if [[ $k == (bar-bg|bar-fg) ]]; then
    print
    print -r -- "${D}sample$N   $(printf '\e[48;2;%d;%d;%dm\e[38;2;%d;%d;%dm  tmux status  \e[0m' \
      $(( 16#${${S[bar-bg]}[2,3]} )) $(( 16#${${S[bar-bg]}[4,5]} )) $(( 16#${${S[bar-bg]}[6,7]} )) \
      $(( 16#${${S[bar-fg]}[2,3]} )) $(( 16#${${S[bar-fg]}[4,5]} )) $(( 16#${${S[bar-fg]}[6,7]} )))"
  fi
}

# ── Editing ──────────────────────────────────────────────

# fail <message> → shows it and waits for a key
fail() {
  print -r -- ""
  print -r -- "  ✗ $*"
  print -rn -- "  press any key "
  read -k1 -s </dev/tty
  return 1
}

# input_value <label> <current> [hint] → REPLY = the edited text, 1 on esc.
# fzf as a pre-filled line editor: no items, so enter returns the query.
input_value() {
  local out rc
  out=$(: | fzf --print-query --query="$2" --prompt="$1> " --reverse --info=hidden \
        --header="${3:-enter: save · esc: cancel}" --no-separator)
  rc=$?
  (( rc == 130 )) && return 1
  REPLY=${out%%$'\n'*}
  return 0
}

# valid <key-or-type> <value> → 0 if ok, else prints why and returns 1
valid() {
  local t=${WS_TYPE[$1]:-$1} v=$2 lo hi
  case $t in
    int:*)
      lo=${${t#int:}%%:*} hi=${t##*:}
      [[ $v == <-> ]] && (( v >= lo && v <= hi )) || { fail "Enter a whole number from $lo to $hi."; return 1 } ;;
    color)
      [[ $v =~ '^#[0-9a-fA-F]{6}$' ]] || { fail "Use a colour like #3fb950."; return 1 } ;;
    name)
      [[ -n $v && $v != *[.:\ ]* ]] || { fail "A name can't be empty or contain spaces, '.' or ':'."; return 1 } ;;
    dir)
      [[ -d ${v/#\~/$HOME} ]] || { fail "$v isn't an existing folder."; return 1 } ;;
    text)
      [[ -n $v ]] || { fail "Can't be empty (use Ctrl-R in the list to reset it)."; return 1 } ;;
    plugin)
      [[ $v == */* && $v =~ '^[A-Za-z0-9@:/._-]+$' ]] || { fail "Use user/repo (or a git URL)."; return 1 } ;;
  esac
}

# fzf_list <header> [fzf args...] ← rows on stdin → OUT = key line + selection
fzf_list() {
  local hdr=$1; shift
  OUT=$(fzf --ansi --reverse --delimiter=$'\t' --with-nth=1 --header="$hdr" "$@") || return 1
}

# tpm <install_plugins|clean_plugins|update_plugins> → runs it with the output visible
tpm() {
  local root=${TMUX_PLUGIN_MANAGER_PATH:-$HOME/.tmux/plugins/}
  export TMUX_PLUGIN_MANAGER_PATH=${root%/}/
  print -r -- ""
  "${root%/}/tpm/bin/$1"
  [[ $1 == install_plugins ]] && "${root%/}/tpm/scripts/source_plugins.sh" &>/dev/null
  print -rn -- "  press any key "
  read -k1 -s </dev/tty
}

dirs_menu() {
  local k=$1 sel p key
  local -a parts rows
  while true; do
    settings_load
    parts=("${(@s/:/)S[$k]}"); parts=(${parts:#(-|)})
    parts=("${(@)parts/#$HOME/~}")
    rows=("+ Add a folder…"$'\t'add)
    for p in $parts; do rows+=("  $p"$'\t'dir$'\t'"$p"); done
    print -rl -- "$rows[@]" | fzf_list "${WS_DESC[$k]}"$'\nenter on "+ Add": add · ctrl-x: remove the highlighted folder · esc: back' \
      --expect=ctrl-x --prompt="$k> " || return 0
    key=${OUT%%$'\n'*} sel=${OUT#*$'\n'}
    local -a f=("${(@ps:\t:)sel}")
    if [[ $f[2] == add ]]; then
      input_value "folder" "~/" "type a path (~ ok) · enter: add · esc: cancel" || continue
      [[ -z $REPLY || $REPLY == '~/' ]] && continue
      valid dir "$REPLY" || continue
      p=${REPLY%/}
      (( ${parts[(Ie)$p]} )) || parts+=("$p")
    elif [[ $key == ctrl-x && $f[2] == dir ]]; then
      parts=(${parts:#$f[3]})
    else
      continue
    fi
    settings_set "$k" "${(j/:/)parts:--}"
  done
}

plugins_menu() {
  local sel key p
  local -a rows f
  while true; do
    plugins_list
    rows=("+ Add a plugin…"$'\t'add)
    for p in $reply; do rows+=("  $p"$'\t'plugin$'\t'"$p"); done
    print -rl -- "$rows[@]" | fzf_list $'TPM plugins\nenter on "+ Add": add · ctrl-x: remove · ctrl-u: update all · esc: back' \
      --expect=ctrl-x,ctrl-u --prompt='plugins> ' || return 0
    key=${OUT%%$'\n'*} sel=${OUT#*$'\n'}
    f=("${(@ps:\t:)sel}")
    if [[ $key == ctrl-u ]]; then
      tpm update_plugins
    elif [[ $f[2] == add ]]; then
      input_value "plugin" "" "user/repo, e.g. tmux-plugins/tmux-yank · enter: install · esc: cancel" || continue
      [[ -z $REPLY ]] && continue
      valid plugin "$REPLY" || continue
      plugins_add "$REPLY"; tpm install_plugins
    elif [[ $key == ctrl-x && $f[2] == plugin ]]; then
      [[ $f[3] == tmux-plugins/tpm ]] && { fail "tpm is the plugin manager itself; it stays."; continue }
      plugins_remove "$f[3]"; tpm clean_plugins
    fi
  done
}

edit_setting() {
  local k=$1 t=${WS_TYPE[$1]} cur sel
  case $t in
    plugins) plugins_menu; return ;;
    dirs)    dirs_menu "$k"; return ;;
    choice:*)
      sel=$(print -rl -- ${(s:,:)${t#choice:}} | fzf --reverse --header="$k (esc: cancel)" --prompt="$k> ") || return
      settings_set "$k" "$sel" ;;
    *)
      cur=${S[$k]}
      [[ $t == dir ]] && cur=${cur/#$HOME/~}
      input_value "$k" "$cur" || return
      valid "$k" "$REPLY" || return
      settings_set "$k" "${REPLY%/}" ;;
  esac
  apply_theme
}

cmd_panel() {
  command -v fzf >/dev/null || { print "fzf not found"; sleep 2; return 1 }
  local out sel pos=1 i
  while true; do
    out=$(cmd_rows | fzf --ansi --reverse --no-sort --delimiter=$'\t' --with-nth=1 \
            --expect=ctrl-r --bind="load:pos($pos)" \
            --header=$'tmux settings · enter: edit · ctrl-r: reset to default · ctrl-/: description\nyellow = changed from the default · saved to tmux-settings.conf' \
            --preview="${(q)SELF} preview {2}" --preview-window=right,45%,wrap,border-left \
            --bind="ctrl-/:toggle-preview") || return 0
    sel=${out#*$'\n'}; sel=${sel##*$'\t'}
    [[ -n $sel ]] || continue
    i=${WS_KEYS[(Ie)$sel]}; (( i )) && pos=$i
    if [[ ${out%%$'\n'*} == ctrl-r ]]; then
      [[ ${WS_TYPE[$sel]} == plugins ]] && continue
      settings_reset "$sel"; apply_theme
    else
      edit_setting "$sel"
    fi
  done
}

settings_load
case $1 in
  apply-theme) apply_theme ;;
  rows)        cmd_rows ;;
  preview)     cmd_preview "$2" ;;
  *)           cmd_panel ;;
esac
