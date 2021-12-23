local getmetatable = getmetatable
local setmetatable = setmetatable
local select       = select
local new_tab      = require("table.new")
local nkeys        = require("table.nkeys")
local logger       = require("gw.core.log")
local pairs        = pairs
local type         = type


local _M = {
    version = 0.1,
    new     = new_tab,
    clear   = require("table.clear"),
    nkeys   = nkeys,
    insert  = table.insert,
    concat  = table.concat,
    clone   = require("table.clone"),
}


setmetatable(_M, {__index = table})


function _M.insert_tail(tab, ...)
    local idx = #tab
    for i = 1, select('#', ...) do
        idx = idx + 1
        tab[idx] = select(i, ...)
    end

    return idx
end


function _M.set(tab, ...)
    for i = 1, select('#', ...) do
        tab[i] = select(i, ...)
    end
end

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
    if table == nil then
        return {}
    end

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
return _M
