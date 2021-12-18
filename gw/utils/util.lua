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
local table_concat  = table.concat

local logger = require "gw.core.log"

-- duplicate a table using recursion if necessary for multi-dimensional tables
-- useful for getting a local copy of a table
function _M.table_copy(orig)
    local orig_type = type(orig)
    local copy

    if orig_type == 'table' then
        copy = {}

        for orig_key, orig_value in next, orig, nil do
            copy[_M.table_copy(orig_key)] = _M.table_copy(orig_value)
        end

        setmetatable(copy, _M.table_copy(getmetatable(orig)))
    else
        copy = orig
    end
    return copy
end

-- return a table containing the keys of the provided table
function _M.table_keys(table)
    if type(table) ~= "table" then
        logger.fatal_fail(type(table) .. " was given to table_keys!")
    end

    local t = {}
    local n = 0

    for key, _ in pairs(table) do
        n = n + 1
        t[n] = tostring(key)
    end

    return t
end

-- return a table containing the values of the provided table
function _M.table_values(table)
    if type(table) ~= "table" then
        logger.fatal_fail(type(table) .. " was given to table_values!")
    end

    local t = {}
    local n = 0

    for _, value in pairs(table) do
        -- if a table as a table of values, we need to break them out and add them individually
        -- request_url_args is an example of this, e.g. ?foo=bar&foo=bar2
        if type(value) == "table" then
            for _, values in pairs(value) do
                n = n + 1
                t[n] = tostring(values)
            end
        else
            n = n + 1
            t[n] = tostring(value)
        end
    end

    return t
end

-- return true if the table key exists
function _M.table_has_key(needle, haystack)
    if type(haystack) ~= "table" then
        logger.fatal_fail("Cannot search for a needle when haystack is type " .. type(haystack))
    end

    return haystack[needle] ~= nil
end

-- determine if the haystack table has a needle for a key
function _M.table_has_value(needle, haystack)
    if type(haystack) ~= "table" then
        logger.fatal_fail("Cannot search for a needle when haystack is type " .. type(haystack))
    end

    for _, value in pairs(haystack) do
        if value == needle then
            return true
        end
    end

    return false
end

-- append the contents of (array-like) table b into table a
function _M.table_append(a, b)
    -- handle some ugliness
    local c = type(b) == 'table' and b or { b }

    local a_count = #a

    for i = 1, #c do
        a_count = a_count + 1
        a[a_count] = c[i]
    end
end

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

-- parse collection elements based on a given directive
_M.parse_collection = {
    specific = function(waf, collection, value)
        --_LOG_"Parse collection is getting a specific value: " .. value
        return collection[value]
    end,
    regex = function(waf, collection, value)
        --_LOG_"Parse collection is geting the regex: " .. value
        local v
        local n = 0
        local _collection = {}
        for k, _ in pairs(collection) do
            --_LOG_"checking " .. k
            if ngx.re.find(k, value, waf._pcre_flags) then
                v = collection[k]
                if type(v) == "table" then
                    for __, _v in pairs(v) do
                        n = n + 1
                        _collection[n] = _v
                    end
                else
                    n = n + 1
                    _collection[n] = v
                end
            end
        end
        return _collection
    end,
    keys = function(waf, collection)
        --_LOG_"Parse collection is getting the keys"
        return _M.table_keys(collection)
    end,
    values = function(waf, collection)
        --_LOG_"Parse collection is getting the values"
        return _M.table_values(collection)
    end,
    all = function(waf, collection)
        local n = 0
        local _collection = {}
        for _, key in ipairs(_M.table_keys(collection)) do
            n = n + 1
            _collection[n] = key
        end
        for _, value in ipairs(_M.table_values(collection)) do
            n = n + 1
            _collection[n] = value
        end
        return _collection
    end
}

_M.sieve_collection = {
    ignore = function(waf, collection, value)
        --_LOG_"Sieveing specific value " .. value
        collection[value] = nil
    end,
    regex = function(waf, collection, value)
        --_LOG_"Sieveing regex value " .. value
        for k, _ in pairs(collection) do
            --_LOG_"Checking " .. k
            if ngx.re.find(k, value, waf._pcre_flags) then
                --_LOG_"Removing " .. k
                collection[k] = nil
            end
        end
    end,
}

return _M
