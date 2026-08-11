#!/usr/bin/env bash
#
# Prepare an isolated spacetime.nvim demo environment for the VHS tape
# (scripts/record-demo.tape).
#
# This is the environment-setup half of the recording, factored out so the tape
# can stay a declarative list of keystrokes. It checks the local SpacetimeDB is
# up and serving the demo database, writes a demo `cli.toml`, a cosmetic
# `init.lua` and the isolated XDG dirs, then prints ONLY the work dir on stdout
# (progress goes to stderr) so the tape can do:
#
#   DEMO=$(scripts/record-demo-setup.sh)
#
# Nothing here touches your real config: the plugin is read-only, and the demo
# runs against a throwaway XDG_CONFIG_HOME rather than ~/.config/spacetime.
set -euo pipefail

# What the demo browses. The tape's searches (`/medium`, `/item_template`) name
# these too -- change one and change the other.
DEMO_SERVER="http://127.0.0.1:3000"
DEMO_DATABASE="medium-epic-events"

# Match the user's colorscheme.
COLORSCHEME="molokai"
COLORSCHEME_RTP="$HOME/.local/share/nvim/site/pack/core/opt/molokai"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_CLI_TOML="${XDG_CONFIG_HOME:-$HOME/.config}/spacetime/cli.toml"

# --- Preconditions -----------------------------------------------------------
# Fail loudly here rather than recording thirty seconds of error text: the
# plugin renders an unreachable server as a message in the buffer, which would
# make a broken demo look like a successful one.
if ! curl -sf -m 5 "$DEMO_SERVER/v1/ping" >/dev/null; then
  echo "error: no SpacetimeDB at $DEMO_SERVER -- start one with 'spacetime start'" >&2
  exit 1
fi

if [ ! -r "$REAL_CLI_TOML" ]; then
  echo "error: $REAL_CLI_TOML not found -- run 'spacetime login' first" >&2
  exit 1
fi

# The plugin reads the top-level `spacetimedb_token`; lift it into the demo's
# own cli.toml so the recording never reads your real one.
TOKEN="$(sed -n 's/^spacetimedb_token *= *"\(.*\)"/\1/p' "$REAL_CLI_TOML" | head -1)"
if [ -z "$TOKEN" ]; then
  echo "error: no spacetimedb_token in $REAL_CLI_TOML -- run 'spacetime login'" >&2
  exit 1
fi

if ! curl -sf -m 5 -H "Authorization: Bearer $TOKEN" \
  "$DEMO_SERVER/v1/database/$DEMO_DATABASE/schema?version=9" >/dev/null; then
  echo "error: $DEMO_SERVER has no database '$DEMO_DATABASE' for this identity" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spacetime-nvim-demo.XXXXXX")"

# --- The demo's cli.toml -----------------------------------------------------
# `local` is the default server, so `:Spacetime` resolves to it without the tape
# having to switch on camera. `maincloud` is listed but never selected, and only
# the local token is here, so nothing the demo does leaves the machine. Put a
# `:SpacetimeConnect local` beat back in the tape and this becomes the switch it
# demonstrates -- flip the default to `maincloud` if you do.
mkdir -p "$WORK/xdg-config/spacetime"
cat > "$WORK/xdg-config/spacetime/cli.toml" <<EOF
default_server = "local"
spacetimedb_token = "$TOKEN"

[[server_configs]]
nickname = "maincloud"
host = "maincloud.spacetimedb.com"
protocol = "https"

[[server_configs]]
nickname = "local"
host = "127.0.0.1:3000"
protocol = "http"
EOF
chmod 600 "$WORK/xdg-config/spacetime/cli.toml"

# --- Cosmetic init that loads the plugin from this working copy ---------------
COLORLINE="vim.cmd('colorscheme $COLORSCHEME')"
if [ -d "$COLORSCHEME_RTP" ]; then
  COLORLINE="vim.opt.runtimepath:prepend('$COLORSCHEME_RTP'); $COLORLINE"
else
  echo "note: $COLORSCHEME_RTP not found; using builtin 'habamax'" >&2
  COLORLINE="vim.cmd('colorscheme habamax')"
fi
cat > "$WORK/init.lua" <<EOF
vim.opt.runtimepath:prepend('$REPO_ROOT')
vim.opt.number = false
vim.opt.signcolumn = 'no'
vim.opt.laststatus = 0
vim.opt.showmode = false
vim.opt.ruler = false
vim.opt.hlsearch = false
vim.opt.incsearch = true
vim.opt.shortmess:append('I')
vim.opt.fillchars = { eob = ' ' }
vim.o.termguicolors = true
$COLORLINE
require('spacetime').setup()
EOF

# Isolated XDG dirs so no user config, plugins or ftplugins load. The config dir
# already holds the demo cli.toml written above.
mkdir -p "$WORK/xdg-data" "$WORK/xdg-state"

# --- Semicolon-form truecolor ------------------------------------------------
# VHS's terminal (ttyd/xterm.js) misparses Neovim's default *colon*-delimited
# truecolor SGR (ESC[38:2::r:g:b m), which mangles the blue channel -- molokai
# comes out dim with blue crushed to ~0. Neovim has no colon/semicolon switch,
# but it honours setrgbf/setrgbb from terminfo, so compile an xterm-256color
# variant that spells them with semicolons and point the demo's nvim at it (see
# record-demo.tape's TERMINFO export).
TIDIR="$WORK/terminfo"
mkdir -p "$TIDIR"
cat > "$WORK/truecolor.src" <<'SRC'
xterm-256color-semi|xterm 256 color with semicolon truecolor,
    use=xterm-256color,
    setrgbf=\E[38;2;%p1%d;%p2%d;%p3%dm,
    setrgbb=\E[48;2;%p1%d;%p2%d;%p3%dm,
SRC
tic -x -o "$TIDIR" "$WORK/truecolor.src" >&2

echo "$WORK"
