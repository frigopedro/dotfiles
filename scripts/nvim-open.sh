#!/usr/bin/env zsh
# Open a file in nvim inside tmux, using Ghostty as the terminal. Used as the
# backend for the NvimTmux.app default-file handler (see install-nvimtmux-app.sh).

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

file="${1:A}"
dir="${file:h}"
cmd="nvim ${(q)file}"

# unique session per file; tmux disallows "." and ":" in session names
name="edit-${${file:t}//[.:]/-}-$RANDOM"

if [[ -n "$(tmux list-clients 2>/dev/null)" ]]; then
  # a tmux client is already attached: create a new session and switch to it
  tmux new-session -d -s "$name" -c "$dir" "$cmd"
  tmux switch-client -t "$name"
else
  # no client: start Ghostty with a new session
  open -na Ghostty --args -e tmux new-session -s "$name" -c "$dir" "$cmd"
fi
open -a Ghostty
