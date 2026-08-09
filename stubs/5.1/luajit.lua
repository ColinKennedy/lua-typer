---@meta
--- LuaJIT-only globals. Harmless on plain 5.1: they simply declare names that a
--- PUC interpreter never provides, and typer does not check that a global is
--- actually reachable at runtime.

---@class bitlib
---@field arshift fun(x: integer, n: integer): integer
---@field band fun(x: integer, ...: integer): integer
---@field bnot fun(x: integer): integer
---@field bor fun(x: integer, ...: integer): integer
---@field bswap fun(x: integer): integer
---@field bxor fun(x: integer, ...: integer): integer
---@field lshift fun(x: integer, n: integer): integer
---@field rol fun(x: integer, n: integer): integer
---@field ror fun(x: integer, n: integer): integer
---@field rshift fun(x: integer, n: integer): integer
---@field tobit fun(x: number): integer
---@field tohex fun(x: integer, n?: integer): string
bit = {}

---@class jitlib
---@field arch string
---@field flush fun(...: any)
---@field off fun(...: any)
---@field on fun(...: any)
---@field opt table
---@field os string
---@field status fun(): boolean, ...
---@field version string
---@field version_num integer
jit = {}

---@class ffilib
---@field C table
---@field abi fun(param: string): boolean
---@field alignof fun(ct: any): integer
---@field cast fun(ct: any, init: any): any
---@field cdef fun(def: string)
---@field copy fun(dst: any, src: any, len?: integer)
---@field errno fun(newerr?: integer): integer
---@field fill fun(dst: any, len: integer, c?: integer)
---@field gc fun(cdata: any, finalizer: function|nil): any
---@field istype fun(ct: any, obj: any): boolean
---@field load fun(name: string, global?: boolean): table
---@field metatype fun(ct: any, metatable: table): any
---@field new fun(ct: any, ...: any): any
---@field offsetof fun(ct: any, field: string): integer
---@field os string
---@field sizeof fun(ct: any, nelem?: integer): integer
---@field string fun(ptr: any, len?: integer): string
---@field typeof fun(ct: any, ...: any): any
ffi = {}
