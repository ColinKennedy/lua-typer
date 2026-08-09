---@return string
local function use()
  return host.lookup(host.VERSION)
end

---@return string
local function typo()
  return hsot.lookup("x")
end

return { use, typo }
