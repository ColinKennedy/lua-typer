---@meta

--- A host-injected global: nothing ever assigns `host` itself -- the embedding
--- program creates it -- so a field assignment is the only declaration there is.
--- This is exactly the shape of Neovim's `vim`.
host.VERSION = ""

---@param name string
---@return string
function host.lookup(name) end
