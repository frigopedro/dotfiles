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
export EDITOR='nvim'

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
jwt() {
  local token header payload signature

  if [ -t 0 ]; then
    token="$1"
  else
    token="$(cat)"
  fi

  IFS='.' read -r header payload signature <<< "$token"

  if [ -z "$header" ] || [ -z "$payload" ]; then
    echo "Invalid JWT format" >&2
    return 1
  fi

  decode_base64url() {
    local input="$1"
    input="${input//-/+}"
    input="${input//_//}"

    case $((${#input} % 4)) in
      2) input="${input}==" ;;
      3) input="${input}=" ;;
      1) echo "Invalid base64 string" >&2; return 1 ;;
    esac

    printf '%s' "$input" | base64 --decode 2>/dev/null
  }

  echo "Header:"
  decode_base64url "$header" | jq .

  echo
  echo "Payload:"
  decode_base64url "$payload" | jq .
}

formatter() {
  if [ -t 0 ]; then
    printf '%s\n' "$1" | jq .
  else
    jq .
  fi
}
