--- Minimal JSON encoder/decoder.
---
--- Encoding drives `--json` output; decoding reads `.typer.json` config. Keys
--- are emitted in sorted order so output is byte-stable across runs and Lua
--- versions, which matters for the fixture tests.
---@class typer.json
local M = {}

--- Anything JSON can represent, recursively. This is the exact type of a
--- serialisation boundary -- `any` would be giving up, and `---@generic` would
--- be a lie, since nothing here is passed through unchanged.
---@alias typer.PlainValue nil|boolean|number|string|typer.PlainValue[]|table<string, typer.PlainValue>

---@type table<string, string>
local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

---@param str string
---@return string
local function escape(str)
    return (
        str:gsub('[%c"\\]', function(char)
            return ESCAPES[char] or string.format("\\u%04x", char:byte())
        end)
    )
end

---@param value table<string|integer, typer.PlainValue>
---@return boolean
local function is_array(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" then
            return false
        end
        count = count + 1
    end
    return count == #value
end

---@type fun(value: typer.PlainValue, indent: string, out: string[])
local encode_value

---@param value typer.PlainValue
---@param indent string
---@param out string[]
encode_value = function(value, indent, out)
    local kind = type(value)

    if value == nil or kind == "nil" then
        out[#out + 1] = "null"
    elseif kind == "boolean" then
        out[#out + 1] = tostring(value)
    elseif kind == "number" then
        -- Integers must not print as `1.0`; JSON consumers expect exact line numbers.
        if value == math.floor(value) and value == value and value ~= math.huge and value ~= -math.huge then
            out[#out + 1] = string.format("%d", value)
        else
            out[#out + 1] = string.format("%.14g", value)
        end
    elseif kind == "string" then
        out[#out + 1] = '"' .. escape(value) .. '"'
    elseif kind == "table" then
        local inner = indent .. "  "
        if is_array(value) then
            if #value == 0 then
                out[#out + 1] = "[]"
                return
            end
            out[#out + 1] = "[\n"
            for index, item in ipairs(value) do
                out[#out + 1] = inner
                encode_value(item, inner, out)
                out[#out + 1] = index < #value and ",\n" or "\n"
            end
            out[#out + 1] = indent .. "]"
        else
            ---@type string[]
            local keys = {}
            for key in pairs(value) do
                keys[#keys + 1] = tostring(key)
            end
            if #keys == 0 then
                out[#out + 1] = "{}"
                return
            end
            table.sort(keys)

            out[#out + 1] = "{\n"
            for index, key in ipairs(keys) do
                out[#out + 1] = inner .. '"' .. escape(key) .. '": '
                encode_value(value[key], inner, out)
                out[#out + 1] = index < #keys and ",\n" or "\n"
            end
            out[#out + 1] = indent .. "}"
        end
    else
        out[#out + 1] = "null"
    end
end

---@param value typer.PlainValue
---@return string
function M.encode(value)
    ---@type string[]
    local out = {}
    encode_value(value, "", out)
    return table.concat(out)
end

---@class typer.JsonDecoder
---@field text string
---@field pos integer

---@type fun(decoder: typer.JsonDecoder): typer.PlainValue
local decode_value

---@param decoder typer.JsonDecoder
local function skip_space(decoder)
    local _, stop = decoder.text:find("^[ \t\r\n]*", decoder.pos)
    decoder.pos = stop + 1
end

---@param decoder typer.JsonDecoder
---@return string
local function decode_string(decoder)
    decoder.pos = decoder.pos + 1
    ---@type string[]
    local pieces = {}

    while true do
        local char = decoder.text:sub(decoder.pos, decoder.pos)
        if char == "" then
            error("unterminated string in JSON", 0)
        end
        if char == '"' then
            decoder.pos = decoder.pos + 1
            break
        elseif char == "\\" then
            local escaped = decoder.text:sub(decoder.pos + 1, decoder.pos + 1)
            local simple = ({
                n = "\n",
                t = "\t",
                r = "\r",
                b = "\b",
                f = "\f",
                ['"'] = '"',
                ["\\"] = "\\",
                ["/"] = "/",
            })[escaped]
            if simple then
                pieces[#pieces + 1] = simple
                decoder.pos = decoder.pos + 2
            elseif escaped == "u" then
                local hex = decoder.text:sub(decoder.pos + 2, decoder.pos + 5)
                local code = tonumber(hex, 16) or 63
                pieces[#pieces + 1] = code < 128 and string.char(code) or "?"
                decoder.pos = decoder.pos + 6
            else
                error("invalid escape in JSON string", 0)
            end
        else
            local stop = decoder.text:find('[\\"]', decoder.pos)
            pieces[#pieces + 1] = decoder.text:sub(decoder.pos, (stop or #decoder.text + 1) - 1)
            decoder.pos = stop or #decoder.text + 1
        end
    end

    return table.concat(pieces)
end

---@param decoder typer.JsonDecoder
---@return typer.PlainValue
decode_value = function(decoder)
    skip_space(decoder)
    local char = decoder.text:sub(decoder.pos, decoder.pos)

    if char == "{" then
        decoder.pos = decoder.pos + 1
        ---@type table<string, typer.PlainValue>
        local object = {}
        skip_space(decoder)
        if decoder.text:sub(decoder.pos, decoder.pos) == "}" then
            decoder.pos = decoder.pos + 1
            return object
        end
        while true do
            skip_space(decoder)
            local key = decode_string(decoder)
            skip_space(decoder)
            if decoder.text:sub(decoder.pos, decoder.pos) ~= ":" then
                error("':' expected in JSON object", 0)
            end
            decoder.pos = decoder.pos + 1
            object[key] = decode_value(decoder)
            skip_space(decoder)
            local delimiter = decoder.text:sub(decoder.pos, decoder.pos)
            decoder.pos = decoder.pos + 1
            if delimiter == "}" then
                return object
            end
            if delimiter ~= "," then
                error("',' expected in JSON object", 0)
            end
        end
    elseif char == "[" then
        decoder.pos = decoder.pos + 1
        ---@type typer.PlainValue[]
        local array = {}
        skip_space(decoder)
        if decoder.text:sub(decoder.pos, decoder.pos) == "]" then
            decoder.pos = decoder.pos + 1
            return array
        end
        while true do
            array[#array + 1] = decode_value(decoder)
            skip_space(decoder)
            local delimiter = decoder.text:sub(decoder.pos, decoder.pos)
            decoder.pos = decoder.pos + 1
            if delimiter == "]" then
                return array
            end
            if delimiter ~= "," then
                error("',' expected in JSON array", 0)
            end
        end
    elseif char == '"' then
        return decode_string(decoder)
    elseif decoder.text:find("^true", decoder.pos) then
        decoder.pos = decoder.pos + 4
        return true
    elseif decoder.text:find("^false", decoder.pos) then
        decoder.pos = decoder.pos + 5
        return false
    elseif decoder.text:find("^null", decoder.pos) then
        decoder.pos = decoder.pos + 4
        return nil
    end

    local number = decoder.text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", decoder.pos)
    if number and #number > 0 then
        decoder.pos = decoder.pos + #number
        return tonumber(number)
    end

    error("unexpected character in JSON at offset " .. decoder.pos, 0)
end

---@param text string
---@return typer.PlainValue|nil
---@return string|nil
function M.decode(text)
    local ok, result = pcall(function()
        ---@type typer.JsonDecoder
        local decoder = { text = text, pos = 1 }
        return decode_value(decoder)
    end)
    if not ok then
        return nil, tostring(result)
    end
    return result, nil
end

return M
