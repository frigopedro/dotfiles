#!/usr/bin/env zsh
# Make NvimTmux.app the default handler for text-based files, using duti.
# Sets handlers by UTI (covers whole families) and by extension (covers types
# whose UTI is owned by another app, e.g. csv/json/yaml).

command -v duti >/dev/null || { echo "duti not found: brew install duti" >&2; exit 1; }

app_id="local.nvimtmux"

utis=(
  public.plain-text public.text public.source-code public.script
  public.shell-script public.json public.xml public.yaml
  public.comma-separated-values-text public.tab-separated-values-text
  net.daringfireball.markdown public.log
)

exts=(
  md markdown txt text log csv tsv json jsonl yaml yml toml xml ini conf cfg env
  sh zsh bash py js jsx ts tsx mjs cjs go rs rb lua java c h cpp hpp cs sql
  css scss tf tfvars hcl dockerfile gitignore
)

for u in $utis; do duti -s "$app_id" "$u" all; done
for e in $exts; do duti -s "$app_id" ".$e" all; done
echo "Set $app_id as default for ${#utis} UTIs and ${#exts} extensions"

# Keep web links and HTML files in the browser, not nvim.
browser_id="company.thebrowser.Browser"
duti -s "$browser_id" http
duti -s "$browser_id" https
duti -s "$browser_id" public.html all
duti -s "$browser_id" .html all
duti -s "$browser_id" .htm all
