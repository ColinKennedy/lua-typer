---@param url string
---@return http.Response
local function fetch(url)
  return { status = 200, headers = {}, body = url }
end

---@param url string
---@return http.Missing
local function broken(url)
  return { url }
end

return { fetch = fetch, broken = broken }
