---@param opts table
---@param cb function
---@return any
local function loose(opts, cb)
  return cb(opts)
end

---@param opts table<string, integer>
---@param cb fun(o: table<string, integer>): boolean
---@return boolean
local function tight(opts, cb)
  return cb(opts)
end

---@type unknown
local mystery

return { loose, tight, mystery }
