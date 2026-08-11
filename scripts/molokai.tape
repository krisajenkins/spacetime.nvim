# molokai / monokai palette for VHS, as a Source-able tape fragment.
#
# Kept out of record-demo.tape so the theme lives in one reusable place. It is a
# .tape fragment (a lone `Set Theme` line) rather than a .json because VHS's
# `Set Theme` only accepts a built-in theme name or inline JSON, not a path to a
# JSON file -- so tapes include it with `Source scripts/molokai.tape`.
#
# With termguicolors on, Neovim emits truecolor for everything it draws, so this
# mainly fixes the terminal's default background (the padding colour) and the
# cursor. `background` is molokai's *Normal* background rather than the classic
# #272822, so the padding and the editor are the same colour and the frame has no
# visible border.

Set Theme { "background": "#1b1d1e", "foreground": "#f8f8f2", "cursor": "#f8f8f2", "black": "#272822", "red": "#f92672", "green": "#a6e22e", "yellow": "#f4bf75", "blue": "#66d9ef", "magenta": "#ae81ff", "cyan": "#a1efe4", "white": "#f8f8f2", "brightBlack": "#75715e", "brightRed": "#f92672", "brightGreen": "#a6e22e", "brightYellow": "#f4bf75", "brightBlue": "#66d9ef", "brightMagenta": "#ae81ff", "brightCyan": "#a1efe4", "brightWhite": "#f9f8f5" }
