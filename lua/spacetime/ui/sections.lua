-- The sink the two detail views assemble their lines in.
--
-- `ui/schema.lua` and `ui/reducers.lua` both paint the same shape: a title, a
-- badge under it, then headed sections of aligned rows — or `(none)` where a
-- section is empty — and an `error:` block instead of the lot when something
-- went wrong. That shape was `ui/schema.lua`'s alone until the reducers moved
-- out into a view of their own; it lives here now so the two cannot disagree
-- about an indent, a `(none)` or the arithmetic that moves a grid's spans onto
-- the sink's line numbers.
--
-- This module lives under `ui/` because it calls `ui/grid.lua`, which measures
-- with `vim.fn.strdisplaywidth`; it touches no buffer and no window itself.
--
-- Two things it exists to get right:
--
-- 1. **Nothing is truncated.** `ui/grid.lua` cuts a cell to 40 columns because
--    the row grid has `y` and `K` to recover the rest with; these views have
--    neither, and a type signature cut mid-generic is worse than a long line.
--    The grid is used for its alignment and its byte offsets only, with the
--    width budget effectively lifted.
-- 2. **Errors are buffer text.** A failed request, a table the module does not
--    have, a raise from the layout itself: all three come back through
--    `M.error_lines` as lines, never as a stack trace under the cursor. That one
--    is used beyond the detail views — the row grid and the log view render
--    their errors through it too, so every `error:` block in the content window
--    is the same block.

local M = {}

---Shown in place of an empty section's rows.
M.NONE = "(none)"

---What a section's rows are indented by. Plain ASCII, so a byte offset moves
---along by its length.
M.INDENT = "  "

---What `M.error_lines` says when it is handed nothing usable.
M.UNKNOWN_ERROR = "unknown error"

-- Wide enough that nothing real is ever cut, and a backstop against a
-- pathological generated type name rather than a layout decision. See point 1 of
-- the module header.
M.MAX_WIDTH = 400

---The lines of a view, and the spans to mark on them, as they are assembled.
---@class SpacetimeSectionSink
---@field lines string[]
---@field spans SpacetimeGridSpan[]

---A fresh, empty sink.
---@return SpacetimeSectionSink
function M.new()
	return { lines = {}, spans = {} }
end

---Append one line, optionally marked in full.
---@param sink SpacetimeSectionSink
---@param text string
---@param hl? string
function M.push(sink, text, hl)
	local line = require("spacetime.ui.grid").sanitise(text)
	sink.lines[#sink.lines + 1] = line
	if hl ~= nil and #line > 0 then
		sink.spans[#sink.spans + 1] = {
			line = #sink.lines - 1,
			start_col = 0,
			end_col = #line,
			hl_group = hl,
		}
	end
end

---Append a section: a blank line, a heading, then a grid of rows indented under
---it — or `(none)` when the section is empty.
---
---The grid's spans are byte offsets into its own lines, so they are moved onto
---the sink's line numbers and along by the indent, which is plain ASCII.
---@param sink SpacetimeSectionSink
---@param heading string
---@param columns SpacetimeGridColumn[]
---@param cells SpacetimeGridCell[][]
function M.section(sink, heading, columns, cells)
	M.push(sink, "")
	M.push(sink, heading, "SpacetimeHeader")

	if #cells == 0 then
		M.push(sink, M.INDENT .. M.NONE, "SpacetimeNull")
		return
	end

	local layout = require("spacetime.ui.grid").layout(columns, cells, { header = false, max_width = M.MAX_WIDTH })
	local offset = #sink.lines
	for _, line in ipairs(layout.lines) do
		sink.lines[#sink.lines + 1] = M.INDENT .. line
	end
	for _, span in ipairs(layout.spans) do
		sink.spans[#sink.spans + 1] = {
			line = span.line + offset,
			start_col = span.start_col + #M.INDENT,
			end_col = span.end_col + #M.INDENT,
			hl_group = span.hl_group,
		}
	end
end

---Message text as buffer lines, each marked in full.
---
---Split on newlines first: a server's error is regularly several lines long, and
---folding it onto one would hide the part that says what went wrong.
---@param message any
---@return string[] lines
---@return SpacetimeGridSpan[] spans
function M.error_lines(message)
	local text = (type(message) == "string" and message ~= "") and message or M.UNKNOWN_ERROR

	local sink = M.new()
	for _, raw in ipairs(vim.split("error: " .. text, "\n", { plain = true })) do
		M.push(sink, raw, "SpacetimeError")
	end
	return sink.lines, sink.spans
end

return M
