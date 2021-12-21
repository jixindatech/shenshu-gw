local type = type
local ipairs = iparis
local require = require

local tab      = require("gw.core.table")
--local libinject = require("resty.libinjection")

local string_find = string.find
local string_sub  = string.sub

local ngx = ngx

local _M = {}

function _M.equals(a, b)
    local equals, value

    if type(a) == "table" then
        for _, v in ipairs(a) do
            equals, value = _M.equals(v, b)
            if equals then
                break
            end
        end
    else
        equals = a == b

        if equals then
            value = a
        end
    end

    return equals, value
end

function _M.greater(a, b)
    local greater, value

    if type(a) == "table" then
        for _, v in ipairs(a) do
            greater, value = _M.greater(v, b)
            if greater then
                break
            end
        end
    else
        greater = a > b

        if greater then
            value = a
        end
    end

    return greater, value
end

function _M.less(a, b)
    local less, value

    if type(a) == "table" then
        for _, v in ipairs(a) do
            less, value = _M.less(v, b)
            if less then
                break
            end
        end
    else
        less = a < b

        if less then
            value = a
        end
    end

    return less, value
end

function _M.greater_equals(a, b)
    local greater_equals, value

    if type(a) == "table" then
        for _, v in ipairs(a) do
            greater_equals, value = _M.greater_equals(v, b)
            if greater_equals then
                break
            end
        end
    else
        greater_equals = a >= b

        if greater_equals then
            value = a
        end
    end

    return greater_equals, value
end

function _M.less_equals(a, b)
    local less_equals, value

    if type(a) == "table" then
        for _, v in ipairs(a) do
            less_equals, value = _M.less_equals(v, b)
            if less_equals then
                break
            end
        end
    else
        less_equals = a <= b

        if less_equals then
            value = a
        end
    end

    return less_equals, value
end

function _M.exists(needle, haystack)
    local exists, value

    if type(needle) == "table" then
        for _, v in ipairs(needle) do
            exists, value = _M.exists(v, haystack)

            if exists then
                break
            end
        end
    else
        exists = tab.table_has_value(needle, haystack)

        if exists then
            value = needle
        end
    end

    return exists, value
end

function _M.contains(haystack, needle)
    local contains, value

    if type(needle) == "table" then
        for _, v in ipairs(needle) do
            contains, value = _M.contains(haystack, v)

            if contains then
                break
            end
        end
    else
        contains = tab.table_has_value(needle, haystack)

        if contains then
            value = needle
        end
    end

    return contains, value
end

function _M.str_find(config, subject, pattern)
    local from, to, match, value

    if type(subject) == "table" then
        for _, v in ipairs(subject) do
            match, value = _M.str_find(config, v, pattern)

            if match then
                break
            end
        end
    else
        from, to = string_find(subject, pattern, 1, true)

        if from then
            match = true
            value = string_sub(subject, from, to)
        end
    end

    return match, value
end

function _M.regex(config, subject, pattern)
    local opts = config._pcre_flags
    local captures, err, match

    if type(subject) == "table" then
        for _, v in ipairs(subject) do
            match, captures = _M.regex(config, v, pattern)

            if match then
                break
            end
        end
    else
        captures, err = ngx.re.match(subject, pattern, opts)

        if err then
            ngx.log(ngx.ERR, "error in ngx.re.match: " .. err)
        end

        if captures then
            match = true
        end
    end

    return match, captures
end

function _M.refind(config, subject, pattern)
    local opts = config._pcre_flags
    local from, to, err, match

    if type(subject) == "table" then
        for _, v in ipairs(subject) do
            match, from = _M.refind(config, v, pattern)

            if match then
                break
            end
        end
    else
        from, to, err = ngx.re.find(subject, pattern, opts)

        if err then
            ngx.log(ngx.ERR, "error in ngx.re.find: " .. err)
        end

        if from then
            match = true
        end
    end

    return match, from
end
--[[
function _M.detect_sqli(input)
    if type(input) == 'table' then
        for _, v in ipairs(input) do
            local match, value = _M.detect_sqli(v)

            if match then
                return match, value
            end
        end
    else
        -- yes this is really just one line
        -- libinjection.sqli has the same return values that lookup.operators expects
        return libinject.sqli(input)
    end

    return false, nil
end

function _M.detect_xss(input)
    if type(input) == 'table' then
        for _, v in ipairs(input) do
            local match, value = _M.detect_xss(v)

            if match then
                return match, value
            end
        end
    else
        -- this function only returns a boolean value
        -- so we'll wrap the return values ourselves
        if libinject.xss(input) then
            return true, input
        else
            return false, nil
        end
    end

    return false, nil
end
]]--
function _M.str_match(input, pattern)
    if type(input) == 'table' then
        for _, v in ipairs(input) do
            local match, value = _M.str_match(v, pattern)

            if match then
                return match, value
            end
        end
    else
        local n, m = #input, #pattern

        if m > n then
            return
        end

        local char = {}

        for k = 0, 255 do char[k] = m end
        for k = 1, m-1 do char[pattern:sub(k, k):byte()] = m - k end

        local k = m
        while k <= n do
            local i, j = k, m

            while j >= 1 and input:sub(i, i) == pattern:sub(j, j) do
                i, j = i - 1, j - 1
            end

            if j == 0 then
                return true, input
            end

            k = k + char[input:sub(k, k):byte()]
        end

        return false, nil
    end

    return false, nil
end

_M.lookup = {
    REGEX        = function(config, collection, pattern) return _M.regex(config, collection, pattern) end,
    REFIND       = function(config, collection, pattern) return _M.refind(config, collection, pattern) end,
    EQUALS       = function(config, collection, pattern) return _M.equals(collection, pattern) end,
    GREATER      = function(config, collection, pattern) return _M.greater(collection, pattern) end,
    LESS         = function(config, collection, pattern) return _M.less(collection, pattern) end,
    GREATER_EQ   = function(config, collection, pattern) return _M.greater_equals(collection, pattern) end,
    LESS_EQ      = function(config, collection, pattern) return _M.less_equals(collection, pattern) end,
    EXISTS       = function(config, collection, pattern) return _M.exists(collection, pattern) end,
    CONTAINS     = function(config, collection, pattern) return _M.contains(collection, pattern) end,
    STR_EXISTS   = function(config, collection, pattern) return _M.str_find(config, pattern, collection) end,
    STR_CONTAINS = function(config, collection, pattern) return _M.str_find(config, collection, pattern) end,
    --DETECT_SQLI  = function(config, collection, pattern) return _M.detect_sqli(collection) end,
    --DETECT_XSS   = function(config, collection, pattern) return _M.detect_xss(collection) end,
    STR_MATCH    = function(config, collection, pattern) return _M.str_match(collection, pattern) end,
}

return _M
