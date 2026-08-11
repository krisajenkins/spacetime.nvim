# The spacetime.nvim README demo, as a VHS tape
# (https://github.com/charmbracelet/vhs).
#
# VHS runs its own PTY, executes the real commands and renders straight to a
# GIF, so the recording is a program rather than a take. Run it from the repo
# root:
#
#   make demo                                     # -> demo.gif
#   nix develop -c vhs scripts/record-demo.tape   # the same thing, longhand
#
# It records against the SpacetimeDB running on 127.0.0.1:3000, browsing the
# `medium-epic-events` database. The environment prep (demo cli.toml, cosmetic
# init.lua, XDG isolation, terminfo) lives in scripts/record-demo-setup.sh so
# this file stays a plain list of keystrokes; that script fails loudly if the
# server or the database is missing, rather than letting the tape record thirty
# seconds of error text.

Output demo.gif

# --- Terminal geometry & look -------------------------------------------------
# VHS sizes the grid from pixels and font metrics, so Width/Height are the knobs,
# not cols/rows. Wider than a plain terminal demo needs: the sidebar takes 30
# columns before item_template's nine start, and all nine have to fit or the
# last column renders as a truncated header and looks like a bug.
Set Shell bash
Set FontSize 14
Set LineHeight 1.2
Set Width 1220
Set Height 700
Set Padding 20
Set TypingSpeed 90ms

# molokai / monokai terminal palette. Lives in its own file so it is reusable
# across tapes.
Source scripts/molokai.tape

# --- Setup (hidden): isolate the environment and launch Neovim ----------------
Hide
Type "DEMO=$(scripts/record-demo-setup.sh)"                               Enter
Type "export XDG_CONFIG_HOME=$DEMO/xdg-config XDG_DATA_HOME=$DEMO/xdg-data XDG_STATE_HOME=$DEMO/xdg-state" Enter
# Force semicolon-form truecolor so molokai's blue channel survives VHS's
# terminal (see the terminfo build in record-demo-setup.sh).
Type "export TERMINFO=$DEMO/terminfo TERM=xterm-256color-semi"            Enter
# Start somewhere with no spacetime.json, so the sidebar opens on the whole
# database list rather than jumping straight into a project's database.
Type "cd $DEMO && clear"                                                  Enter
Type "nvim --clean -u $DEMO/init.lua"                                     Enter
Sleep 3.5s
Show

Sleep 800ms                       # empty editor

# --- Open the browser ---------------------------------------------------------
Type ":Spacetime"
Sleep 300ms
Enter
Sleep 2.5s                        # sidebar: the databases this identity owns

# Walked to with `j` rather than found with `/`: a search leaves its pattern and
# a `[1/1]` count on the last line for the rest of the recording, and the demo
# database is one line down anyway.
Type "j"                          # onto medium-epic-events
Sleep 800ms
Enter                             # <CR> expands it, fetching its schema once
Sleep 2.8s                        # its tables, views and st_* tables

# --- Browse a table's rows ----------------------------------------------------
Type "jjjjjj"                     # down the tables to item_template
Sleep 800ms
Enter                             # <CR> -> SELECT * ... LIMIT 100, as a grid
Sleep 2.8s

# --- Sort ---------------------------------------------------------------------
Tab                               # cross into the content window
Sleep 900ms
Type "jj"                         # onto the first data row
Sleep 500ms
Type "w"                          # into the `name` column
Sleep 700ms
Type "s"                          # sort by it — no refetch, only the paint order
Sleep 2.4s
Type "s"                          # again reverses
Sleep 2.4s

# --- Schema -------------------------------------------------------------------
Tab                               # back to the sidebar, cursor still on the table
Sleep 700ms
Type "s"                          # the same `s`, a different buffer: describe it
Sleep 3.4s

# --- Reducers -----------------------------------------------------------------
Type "R"                          # the reducers of the database the cursor is in
Sleep 3.6s

# --- Close --------------------------------------------------------------------
Type "q"                          # closes the layout, cancelling anything in flight
Sleep 1.2s
