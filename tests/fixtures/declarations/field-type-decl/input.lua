---@class Standalone
---@field a string

---@class OnLocal
local OnLocal = {}

---@enum EnumOnLocal
local EnumOnLocal = { a = "a" }

--- A declaration attached to a table field is a declaration like any other: the
--- name in the tag is self-contained, so nothing about it depends on whether a
--- local, a field assignment, or no code at all sits below it.
---@class Holder
---@field OnField OnField
---@field EnumOnField EnumOnField
local M = {}

---@class OnField
M.OnField = {}

---@enum EnumOnField
M.EnumOnField = { a = "a" }

---@param p1 Standalone
---@param p2 OnLocal
---@param p3 EnumOnLocal
---@param p4 OnField
---@param p5 EnumOnField
---@return string
local function use(p1, p2, p3, p4, p5)
  print(p1, p2, p3, p4, p5)
  return ""
end

--- A name nothing declares still reports, so this file is not passing by being
--- silent about everything.
---@type NeverDeclared
local absent

return { M, OnLocal, EnumOnLocal, use, absent }
