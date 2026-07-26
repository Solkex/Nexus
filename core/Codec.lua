-- Nexus: core/Codec.lua
-- Self-contained base64 + minimal JSON encode/decode, adapted from
-- EbonBuilds' own ExportImport.lua (confirmed via direct inspection of
-- their source, 2026-07-24) -- same standard base64 alphabet, same
-- minimal JSON grammar. No external library dependency either way.
--
-- Used for two things: (1) our own sync wire format (peer-shared posted
-- builds), and (2) decoding a manually-pasted EbonBuilds export string,
-- since their format uses this exact same encoding.

Nexus = Nexus or {}
local Codec = {}
Nexus.Codec = Codec

------------------------------------------------------------------------
-- Base64
------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local MAX_ENCODED_BYTES = 98304
local MAX_DECODED_BYTES = 65536
local BASE64_CHUNK = 2000

function Codec.Base64Encode(data)
    local out = {}
    local len = #data
    for i = 1, len, 3 do
        local a, b, c = data:byte(i, i + 2)
        a, b, c = a or 0, b or 0, c or 0
        local n = a * 65536 + b * 256 + c
        out[#out + 1] = B64:byte(math.floor(n / 262144) + 1)
        out[#out + 1] = B64:byte(math.floor((n % 262144) / 4096) + 1)
        out[#out + 1] = i + 1 <= len and B64:byte(math.floor((n % 4096) / 64) + 1) or 61
        out[#out + 1] = i + 2 <= len and B64:byte(math.floor(n % 64) + 1) or 61
    end
    local chunks = {}
    for i = 1, #out, BASE64_CHUNK do
        chunks[#chunks + 1] = string.char(unpack(out, i, math.min(i + BASE64_CHUNK - 1, #out)))
    end
    return table.concat(chunks)
end

function Codec.Base64Decode(s)
    if type(s) ~= "string" or #s > MAX_ENCODED_BYTES or #s % 4 ~= 0 then return nil end
    if s == "" then return "" end
    if s:find("[^A-Za-z0-9+/=]") then return nil end
    local rev = {}
    for i = 1, #B64 do rev[B64:byte(i)] = i - 1 end
    rev[61] = 0
    local out = {}
    local len = #s
    for i = 1, len, 4 do
        local a = rev[s:byte(i)] or 0
        local b = rev[s:byte(i + 1)] or 0
        local c = rev[s:byte(i + 2)] or 0
        local d = rev[s:byte(i + 3)] or 0
        local n = a * 262144 + b * 4096 + c * 64 + d
        out[#out + 1] = string.char(math.floor(n / 65536))
        if s:byte(i + 2) ~= 61 then
            out[#out + 1] = string.char(math.floor((n % 65536) / 256))
        end
        if s:byte(i + 3) ~= 61 then
            out[#out + 1] = string.char(math.floor(n % 256))
        end
        if #out > MAX_DECODED_BYTES then return nil end
    end
    local decoded = table.concat(out)
    if #decoded > MAX_DECODED_BYTES then return nil end
    return decoded
end

------------------------------------------------------------------------
-- Minimal JSON encoder
------------------------------------------------------------------------

local function IsArray(tbl)
    if type(tbl) ~= "table" then return false end
    local count, maxIdx = 0, 0
    for k in pairs(tbl) do
        if type(k) ~= "number" or k < 1 then return false end
        count = count + 1
        if k > maxIdx then maxIdx = k end
    end
    return count == maxIdx
end

function Codec.JSONEncode(value)
    local t = type(value)
    if t == "nil" then return "null"
    elseif t == "boolean" then return value and "true" or "false"
    elseif t == "number" then
        if value ~= value then return "null" end
        if value == math.huge or value == -math.huge then return "null" end
        return tostring(value)
    elseif t == "string" then
        local parts = {}
        for index = 1, #value do
            local byte = value:byte(index)
            if byte == 34 then parts[#parts + 1] = '\\"'
            elseif byte == 92 then parts[#parts + 1] = "\\\\"
            elseif byte == 8 then parts[#parts + 1] = "\\b"
            elseif byte == 9 then parts[#parts + 1] = "\\t"
            elseif byte == 10 then parts[#parts + 1] = "\\n"
            elseif byte == 12 then parts[#parts + 1] = "\\f"
            elseif byte == 13 then parts[#parts + 1] = "\\r"
            elseif byte < 32 then parts[#parts + 1] = string.format("\\u%04X", byte)
            else parts[#parts + 1] = string.char(byte) end
        end
        return '"' .. table.concat(parts) .. '"'
    elseif t == "table" then
        local parts = {}
        if IsArray(value) then
            for i = 1, #value do parts[#parts + 1] = Codec.JSONEncode(value[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(value) do
                if v ~= nil then
                    parts[#parts + 1] = Codec.JSONEncode(tostring(k)) .. ":" .. Codec.JSONEncode(v)
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

------------------------------------------------------------------------
-- Minimal JSON decoder
------------------------------------------------------------------------

local function SkipWhitespace(s, pos)
    while pos <= #s do
        local c = s:byte(pos)
        if c ~= 32 and c ~= 9 and c ~= 10 and c ~= 13 then break end
        pos = pos + 1
    end
    return pos
end

local function CodepointToUTF8(code)
    if not code then return "" end
    if code <= 0x7F then
        return string.char(code)
    elseif code <= 0x7FF then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
    elseif code <= 0xFFFF then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40)
        )
    end
    return ""
end

local MAX_JSON_DEPTH = 12
local function ParseValue(s, pos, depth)
    depth = depth or 0
    if depth > MAX_JSON_DEPTH then return nil, pos end
    pos = SkipWhitespace(s, pos)
    if pos > #s then return nil, pos end
    local c = s:byte(pos)
    if c == 110 then return nil, pos + 4
    elseif c == 116 then return true, pos + 4
    elseif c == 102 then return false, pos + 5
    elseif c == 34 then
        local out = {}
        pos = pos + 1
        while pos <= #s do
            local cc = s:byte(pos)
            if cc == 34 then
                return table.concat(out), pos + 1
            elseif cc == 92 then
                pos = pos + 1
                local ec = s:byte(pos)
                if ec == 98 then out[#out + 1] = string.char(8)
                elseif ec == 102 then out[#out + 1] = string.char(12)
                elseif ec == 110 then out[#out + 1] = "\n"
                elseif ec == 114 then out[#out + 1] = "\r"
                elseif ec == 116 then out[#out + 1] = "\t"
                elseif ec == 92 then out[#out + 1] = "\\"
                elseif ec == 34 then out[#out + 1] = '"'
                elseif ec == 117 then
                    local hex = s:sub(pos + 1, pos + 4)
                    local code = hex:match("^%x%x%x%x$") and tonumber(hex, 16) or nil
                    if code then
                        out[#out + 1] = CodepointToUTF8(code)
                        pos = pos + 4
                    else
                        out[#out + 1] = "u"
                    end
                else out[#out + 1] = s:sub(pos, pos) end
            else
                out[#out + 1] = s:sub(pos, pos)
            end
            pos = pos + 1
        end
        return table.concat(out), pos
    elseif c == 91 then
        local arr = {}
        pos = pos + 1
        pos = SkipWhitespace(s, pos)
        if s:byte(pos) == 93 then return arr, pos + 1 end
        while true do
            if pos > #s then return arr, pos end
            local val
            val, pos = ParseValue(s, pos, depth + 1)
            arr[#arr + 1] = val
            pos = SkipWhitespace(s, pos)
            if s:byte(pos) == 93 then return arr, pos + 1 end
            pos = pos + 1
        end
    elseif c == 123 then
        local obj = {}
        pos = pos + 1
        pos = SkipWhitespace(s, pos)
        if s:byte(pos) == 125 then return obj, pos + 1 end
        while true do
            if pos > #s then return obj, pos end
            local key
            key, pos = ParseValue(s, pos, depth + 1)
            pos = SkipWhitespace(s, pos)
            pos = pos + 1
            local val
            val, pos = ParseValue(s, pos, depth + 1)
            if key ~= nil then
                if type(key) == "string" and key:match("^%-?%d+$") then
                    obj[tonumber(key)] = val
                else
                    obj[key] = val
                end
            end
            pos = SkipWhitespace(s, pos)
            if s:byte(pos) == 125 then return obj, pos + 1 end
            pos = pos + 1
        end
    else
        local startPos = pos
        if c == 45 then pos = pos + 1 end
        while pos <= #s do
            local nc = s:byte(pos)
            if nc >= 48 and nc <= 57 or nc == 46 or nc == 101 or nc == 69 or nc == 43 then
                pos = pos + 1
            else
                break
            end
        end
        return tonumber(s:sub(startPos, pos - 1)), pos
    end
end

function Codec.JSONDecode(s)
    if not s or s == "" then return nil end
    if #s > MAX_DECODED_BYTES then return nil end
    local ok, val = pcall(ParseValue, s, 1, 0)
    if not ok then return nil end
    return val
end

------------------------------------------------------------------------
-- Safety check for decoded trees (bounded depth/breadth so a malicious
-- or corrupted payload from a peer can't hang the client)
------------------------------------------------------------------------

function Codec.IsSafeTree(root, maxDepth, maxNodes)
    maxDepth = maxDepth or 8
    maxNodes = maxNodes or 5000
    local nodes = 0
    local function Visit(value, depth)
        nodes = nodes + 1
        if nodes > maxNodes or depth > maxDepth then return false end
        local kind = type(value)
        if kind ~= "table" then
            return kind == "nil" or kind == "boolean" or kind == "number" or kind == "string"
        end
        for key, child in pairs(value) do
            if type(key) ~= "number" and type(key) ~= "string" then return false end
            if not Visit(child, depth + 1) then return false end
        end
        return true
    end
    local ok, result = pcall(Visit, root, 0)
    return ok and result
end
