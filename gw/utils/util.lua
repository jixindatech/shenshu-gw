local _M = {}
local require = require
local pairs = pairs
local type  = type
local tostring = tostring
local setmetatable = setmetatable
local getmetatable = getmetatable

local re_find       = ngx.re.find
local string_byte   = string.byte
local string_char   = string.char
local string_format = string.format

-- encode a given string as hex
function _M.hex_encode(str)
    return (str:gsub('.', function (c)
        return string_format('%02x', string_byte(c))
    end))
end

-- decode a given hex string
function _M.hex_decode(str)
    local value

    if (pcall(function()
        value = str:gsub('..', function (cc)
            return string_char(tonumber(cc, 16))
        end)
    end)) then
        return value
    else
        return str
    end
end

return _M
