---@class Animal
local Animal = {}

---@class Dog
local Dog = {}
setmetatable(Dog, { __index = Animal })

---@class Cat : Animal
local Cat = {}
setmetatable(Cat, { __index = Animal })

return { Animal, Dog, Cat }
