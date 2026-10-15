#!/usr/bin/env zsh
# Build ~/Applications/NvimTmux.app, an AppleScript applet that forwards opened
# files to scripts/nvim-open.sh. Then set it as the default handler in Finder
# (Get Info > Open with > Change All) or with `duti -s <bundle id> .ext all`.

script_dir="${0:A:h}"
src=$(mktemp -t nvimtmux).applescript

cat > "$src" <<APPLESCRIPT
on open theFiles
  repeat with f in theFiles
    do shell script "${script_dir}/nvim-open.sh " & quoted form of POSIX path of f
  end repeat
end open
APPLESCRIPT

mkdir -p "$HOME/Applications"
osacompile -o "$HOME/Applications/NvimTmux.app" "$src" && rm -f "$src"
app="$HOME/Applications/NvimTmux.app"
# osacompile leaves no bundle id; add one so duti/Launch Services can target it
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.nvimtmux" "$app/Contents/Info.plist" 2>/dev/null
codesign --force --deep --sign - "$app" 2>/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Built $app (bundle id: local.nvimtmux)"
