---@meta
--- Standard library tables for Lua 5.4.

---@class stringlib
---@field byte fun(s: string, i?: integer, j?: integer): integer, ...
---@field char fun(...: integer): string
---@field dump fun(f: function, strip?: boolean): string
---@field find fun(s: string, pattern: string, init?: integer, plain?: boolean): integer|nil, integer|nil, ...
---@field format fun(formatstring: string, ...: any): string
---@field gmatch fun(s: string, pattern: string, init?: integer): fun(): string, ...
---@field gsub fun(s: string, pattern: string, repl: string|table|function, n?: integer): string, integer
---@field len fun(s: string): integer
---@field lower fun(s: string): string
---@field match fun(s: string, pattern: string, init?: integer): string|nil, ...
---@field pack fun(fmt: string, ...: any): string
---@field packsize fun(fmt: string): integer
---@field rep fun(s: string, n: integer, sep?: string): string
---@field reverse fun(s: string): string
---@field sub fun(s: string, i: integer, j?: integer): string
---@field unpack fun(fmt: string, s: string, pos?: integer): ...
---@field upper fun(s: string): string
string = {}

---@class tablelib
---@field concat fun(list: table, sep?: string, i?: integer, j?: integer): string
---@field insert fun(list: table, pos: any, value?: any)
---@field move fun(a1: table, f: integer, e: integer, t: integer, a2?: table): table
---@field pack fun(...: any): table
---@field remove fun(list: table, pos?: integer): any
---@field sort fun(list: table, comp?: fun(a: any, b: any): boolean)
---@field unpack fun(list: table, i?: integer, j?: integer): ...
table = {}

---@class mathlib
---@field abs fun(x: number): number
---@field acos fun(x: number): number
---@field asin fun(x: number): number
---@field atan fun(y: number, x?: number): number
---@field ceil fun(x: number): integer
---@field cos fun(x: number): number
---@field deg fun(x: number): number
---@field exp fun(x: number): number
---@field floor fun(x: number): integer
---@field fmod fun(x: number, y: number): number
---@field huge number
---@field log fun(x: number, base?: number): number
---@field max fun(x: number, ...: number): number
---@field maxinteger integer
---@field min fun(x: number, ...: number): number
---@field mininteger integer
---@field modf fun(x: number): number, number
---@field pi number
---@field random fun(m?: integer, n?: integer): number
---@field randomseed fun(x?: integer, y?: integer)
---@field sin fun(x: number): number
---@field sqrt fun(x: number): number
---@field tan fun(x: number): number
---@field tointeger fun(x: any): integer|nil
---@field type fun(x: any): string|nil
---@field ult fun(m: integer, n: integer): boolean
math = {}

---@class iolib
---@field close fun(file?: file*)
---@field flush fun()
---@field input fun(file?: string|file*): file*
---@field lines fun(filename?: string, ...: any): fun(): string|nil
---@field open fun(filename: string, mode?: string): file*|nil, string|nil
---@field output fun(file?: string|file*): file*
---@field popen fun(prog: string, mode?: string): file*|nil, string|nil
---@field read fun(...: any): string|nil, ...
---@field stderr file*
---@field stdin file*
---@field stdout file*
---@field tmpfile fun(): file*
---@field type fun(file: any): string|nil
---@field write fun(...: any): file*
io = {}

---@class file*
---@field close fun(self: file*): boolean|nil
---@field flush fun(self: file*): file*
---@field lines fun(self: file*, ...: any): fun(): string|nil
---@field read fun(self: file*, ...: any): string|nil, ...
---@field seek fun(self: file*, whence?: string, offset?: integer): integer|nil, string|nil
---@field setvbuf fun(self: file*, mode: string, size?: integer): boolean
---@field write fun(self: file*, ...: any): file*

---@class oslib
---@field clock fun(): number
---@field date fun(format?: string, time?: integer): string|table
---@field difftime fun(t2: integer, t1: integer): number
---@field execute fun(command?: string): boolean|nil, string, integer
---@field exit fun(code?: integer|boolean, close?: boolean)
---@field getenv fun(varname: string): string|nil
---@field remove fun(filename: string): boolean|nil, string|nil
---@field rename fun(oldname: string, newname: string): boolean|nil, string|nil
---@field setlocale fun(locale?: string, category?: string): string|nil
---@field time fun(t?: table): integer
---@field tmpname fun(): string
os = {}

---@class coroutinelib
---@field close fun(co: thread): boolean, any
---@field create fun(f: function): thread
---@field isyieldable fun(co?: thread): boolean
---@field resume fun(co: thread, ...: any): boolean, ...
---@field running fun(): thread, boolean
---@field status fun(co: thread): string
---@field wrap fun(f: function): function
---@field yield fun(...: any): ...
coroutine = {}

---@class utf8lib
---@field char fun(...: integer): string
---@field charpattern string
---@field codes fun(s: string, lax?: boolean): fun(s: string, i: integer): integer, integer
---@field codepoint fun(s: string, i?: integer, j?: integer, lax?: boolean): integer, ...
---@field len fun(s: string, i?: integer, j?: integer, lax?: boolean): integer|nil, integer|nil
---@field offset fun(s: string, n: integer, i?: integer): integer|nil
utf8 = {}

---@class debuglib
---@field debug fun()
---@field gethook fun(co?: thread): function, string, integer
---@field getinfo fun(...: any): table|nil
---@field getlocal fun(...: any): string|nil, any
---@field getmetatable fun(value: any): table|nil
---@field getregistry fun(): table
---@field getupvalue fun(f: function, up: integer): string|nil, any
---@field getuservalue fun(u: userdata, n?: integer): any, boolean
---@field sethook fun(...: any)
---@field setlocal fun(...: any): string|nil
---@field setmetatable fun(value: any, table: table|nil): any
---@field setupvalue fun(f: function, up: integer, value: any): string|nil
---@field setuservalue fun(udata: userdata, value: any, n?: integer): userdata
---@field traceback fun(...: any): string
---@field upvalueid fun(f: function, n: integer): userdata
---@field upvaluejoin fun(f1: function, n1: integer, f2: function, n2: integer)
debug = {}

---@class packagelib
---@field config string
---@field cpath string
---@field loaded table<string, any>
---@field loadlib fun(libname: string, funcname: string): function|nil
---@field path string
---@field preload table<string, function>
---@field searchers table
---@field searchpath fun(name: string, path: string, sep?: string, rep?: string): string|nil, string|nil
package = {}
