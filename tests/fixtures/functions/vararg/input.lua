local function varargs_only(...)
  print(...)
end

---@param ... string
local function annotated_varargs(...)
  print(...)
end

---@param a integer
local function mixed(a, ...)
  print(a, ...)
end

return { varargs_only, annotated_varargs, mixed }
