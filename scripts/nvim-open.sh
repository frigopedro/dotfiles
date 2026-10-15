#!/usr/bin/env zsh
# Open a file in nvim inside tmux, using Ghostty as the terminal. Used as the
# backend for the NvimTmux.app default-file handler (see install-nvimtmux-app.sh).

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

file="${1:A}"
dir="${file:h}"
cmd="nvim ${(q)file}"

if [[ -n "$(tmux list-clients 2>/dev/null)" ]]; then
  # a tmux client is already attached: add a window there
  tmux new-window -c "$dir" "$cmd"
else
  # no client: start Ghostty attached to (or creating) an "edit" session
  open -na Ghostty --args -e tmux new-session -A -s edit -c "$dir" "$cmd"
fi
open -a Ghostty
