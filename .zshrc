# Q pre block. Keep at the top of this file.
# Q post block. Keep at the bottom of this file.
[ -f "$HOME/dotfiles/.zsh_secrets" ] && source "$HOME/dotfiles/.zsh_secrets"
[ -f "$HOME/dotfiles/.zsh_osm" ] && source "$HOME/dotfiles/.zsh_osm"

alias proj="cd ~/Desktop/Projects"
alias gs="git status"
alias gc="git commit -m"
alias gac="git add . && git commit -m"
alias ga="git add"
alias gp="git push"
alias nvim-config="cd ~/.config/nvim"
alias aliases="nvim ~/.zshrc"
alias config="cd ~/.config"
alias sz="source ~/.zshrc"

export PATH="$HOME/.local/bin:$PATH"

stringify() {
  if [ -t 0 ]; then
    printf '%s' "$1" | jq -Rs .
  else
    jq -Rs .
  fi
}

unstringify() {
  local input

  if [ -t 0 ]; then
    input="$1"
  else
    input="$(cat)"
  fi

  printf '%s' "$input" | jq -Rr '
    def try_parse:
      fromjson?
      // (gsub("\\\\n"; "\n") | gsub("\\\\t"; "\t") | gsub("\\\\r"; "\r") | fromjson?);

    try_parse
    | if type == "string" then
        fromjson? // .
      else
        .
      end
  '
}
dotfiles() {
  cd ~/dotfiles || return
  nvim .
}
