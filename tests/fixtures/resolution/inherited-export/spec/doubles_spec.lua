local helpers = require("app.helpers")

--- A monkeypatched test double overrides a slot the module already typed.
---@diagnostic disable-next-line: duplicate-set-field
helpers.get_root = function(buffer)
  return "/tmp/" .. tostring(buffer)
end

--- The double contradicts the arity the module declares, which is the one thing
--- an override can still get wrong.
---@diagnostic disable-next-line: duplicate-set-field
helpers.exists_command = function(command)
  return #command > 0, "extra"
end

--- Nothing to inherit, so this is as undeclared as the original.
---@diagnostic disable-next-line: duplicate-set-field
helpers.undocumented = function(value)
  return value
end

--- A field the module never declared at all.
helpers.invented = function(alpha)
  return alpha
end

return helpers
