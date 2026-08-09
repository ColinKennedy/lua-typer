-- With `missing-param-placeholder` switched on, the exemption goes away and
-- every placeholder has to be annotated like anything else.
---@param callback fun(count: integer): nil
local function discarded(_, callback)
  callback(20)
end

---@param _ string
---@param callback fun(count: integer): nil
local function documented(_, callback)
  callback(20)
end

return { discarded, documented }
