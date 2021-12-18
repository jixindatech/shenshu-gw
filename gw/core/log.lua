local _M = {}

local cjson         = require "cjson.safe"

local function split(source, delimiter)
    local elements = {}
    local pattern = '([^'..delimiter..']+)'
    string.gsub(source, pattern, function(value)
        elements[#elements + 1] = value
    end)
    return elements
end

-- warn logger
function _M.warn(waf, msg)
    ngx.log(ngx.WARN, '[', waf.transaction_id, '] ', msg)
end

-- deprecation logger
function _M.deprecate(waf, msg, ver)
    _M.warn(waf, 'DEPRECATED: ' .. msg)

    if not ver then return end

    local ver_tab = split(ver, "%.")
    local my_ver  = split(base.version, "%.")

    for i = 1, #ver_tab do
        local m = tonumber(ver_tab[i]) or 0
        local n = tonumber(my_ver[i]) or 0

        if n > m then
            _M.fatal_fail("fatal deprecation version passed", 1)
        end
    end
end

-- fatal failure logger
function _M.fatal_fail(msg, level)
    level = tonumber(level) or 0
    ngx.log(ngx.ERR, error(msg, level + 2))
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

return _M
