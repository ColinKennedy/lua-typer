local foo

if _G.thing then
  foo = "123123"
else
  foo = 123132
end

local explicit = nil

---@type string | integer
local annotated

return { foo, explicit, annotated }
