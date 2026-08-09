--- `-- typer: ignore` suppression comments (spec §4).
---
--- Deliberately a *plain* comment rather than a doc comment: a `---@typer-ignore`
--- tag would show up as an unknown tag to lua-language-server itself.
---
--- There is no baseline file and never will be (spec §5). These per-site,
--- visible-in-source comments are the only suppression mechanism.
---@class typer.suppress
local M = {}

---@class typer.Suppressions
---@field whole_file boolean
---@field ranges table[]              -- { from, to, codes = table|nil }

--- Splits a code list, or nil when the comment suppresses everything.
---@param text string
---@return table<string, boolean>|nil
local function parse_codes(text)
  local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then return nil end

  ---@type table<string, boolean>
  local codes = {}
  for code in trimmed:gmatch("[%w%-]+") do codes[code] = true end
  if next(codes) == nil then return nil end
  return codes
end

--- Finds the statement a suppression comment applies to.
---@param statements table[]
---@param line integer
---@return table|nil
local function statement_after(statements, line)
  ---@type table|nil
  local best = nil
  for _, span in ipairs(statements) do
    if span.l > line and (not best or span.l < best.l) then best = span end
  end
  return best
end

---@param statements table[]
---@param line integer
---@return table|nil
local function statement_on(statements, line)
  ---@type table|nil
  local best = nil
  for _, span in ipairs(statements) do
    if span.l <= line and span.el >= line then
      if not best or span.l > best.l then best = span end
    end
  end
  return best
end

--- Collects suppressions from a chunk's plain comments.
---@param chunk typer.Chunk
---@param model typer.FileModel
---@return typer.Suppressions
function M.collect(chunk, model)
  ---@type typer.Suppressions
  local result = { whole_file = false, ranges = {} }
  local statements = model.statements or {}

  for _, comment in ipairs(chunk.comments) do
    if not comment.doc then
      local body = comment.text:match("^%s*typer%s*:%s*(.*)$")
      if body then
        local file_rest = body:match("^ignore%-file%s*(.*)$")
        if file_rest then
          result.whole_file = true
        else
          local rest = body:match("^ignore%s*(.*)$")
          if rest then
            local codes = parse_codes(rest)
            local on_line = statement_on(statements, comment.l)

            if on_line and model.docs.code_lines[comment.l] then
              -- Trailing form: applies to the statement it shares a line with.
              result.ranges[#result.ranges + 1] =
                { from = on_line.l, to = on_line.el, codes = codes }
            else
              local target = statement_after(statements, comment.l)
              if target then
                result.ranges[#result.ranges + 1] =
                  { from = target.l, to = target.el, codes = codes }
              else
                -- A trailing comment with no statement after it suppresses its
                -- own line, which is the only sensible reading.
                result.ranges[#result.ranges + 1] =
                  { from = comment.l, to = comment.l, codes = codes }
              end
            end
          end
        end
      end
    end
  end

  return result
end

---@param suppressions typer.Suppressions
---@param diag typer.Diagnostic
---@return boolean
function M.is_suppressed(suppressions, diag)
  if suppressions.whole_file then return true end

  for _, range in ipairs(suppressions.ranges) do
    if diag.line >= range.from and diag.line <= range.to then
      if not range.codes or range.codes[diag.code] then return true end
    end
  end

  return false
end

return M
