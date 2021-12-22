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
function _M.warn(msg)
    ngx.log(ngx.WARN, msg)
end

-- fatal failure logger
function _M.fatal_fail(msg, level)
    level = tonumber(level) or 0
    ngx.log(ngx.ERR, error(msg, level + 2))
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

return _M
