local _M = {}

local request   = require "gw.core.request"
local tab      = require "gw.core.table"

local string_format = string.format
local string_match  = string.match
local table_concat  = table.concat

_M.lookup = {
    access = function(config, collections, ctx)
        local request_headers     = ngx.req.get_headers()
        local request_var         = ngx.var.request
        local request_method      = ngx.req.get_method()
        local request_uri_args    = ngx.req.get_uri_args()
        local request_uri         = request.request_uri()
        local request_uri_raw     = request.request_uri_raw(request_var, request_method)
        local request_basename    = request.basename(config, ngx.var.uri)
        local request_body        = request.parse_request_body(config, request_headers, collections)
        local request_cookies     = request.cookies() or {}
        local request_common_args = request.common_args({ request_uri_args, request_body, request_cookies })
        local query_string        = ngx.var.query_string

        local query_str_size = query_string and #query_string or 0
        local body_size = ngx.var.http_content_length and tonumber(ngx.var.http_content_length) or 0

        collections.REMOTE_ADDR       = ngx.var.remote_addr
        collections.HTTP_VERSION      = ngx.req.http_version()
        collections.METHOD            = request_method
        collections.URI               = ngx.var.uri
        collections.URI_ARGS          = request_uri_args
        collections.QUERY_STRING      = query_string
        collections.REQUEST_URI       = request_uri
        collections.REQUEST_URI_RAW   = request_uri_raw
        collections.REQUEST_BASENAME  = request_basename
        collections.REQUEST_HEADERS   = request_headers
        collections.COOKIES           = request_cookies
        collections.REQUEST_BODY      = request_body
        collections.REQUEST_ARGS      = request_common_args
        collections.REQUEST_LINE      = request_var
        collections.PROTOCOL          = ngx.var.server_protocol
        collections.TX                = ctx.storage["TX"]
        collections.NGX_VAR           = ngx.var
        collections.MATCHED_VARS      = {}
        collections.MATCHED_VAR_NAMES = {}
        collections.SCORE_THRESHOLD   = config._score_threshold

        collections.ARGS_COMBINED_SIZE = query_str_size + body_size

        local year, month, day, hour, minute, second = string_match(ngx.localtime(),
                "(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)")

        collections.TIME              = string_format("%d:%d:%d", hour, minute, second)
        collections.TIME_DAY          = day
        collections.TIME_EPOCH        = ngx.time()
        collections.TIME_HOUR         = hour
        collections.TIME_MIN          = minute
        collections.TIME_MON          = month
        collections.TIME_SEC          = second
        collections.TIME_YEAR         = year
    end,
    header_filter = function(config, collections)
        local response_headers = ngx.resp.get_headers()

        collections.RESPONSE_HEADERS = response_headers
        collections.STATUS           = ngx.status
    end,
    body_filter = function(config, collections, ctx)
        if ctx.buffers == nil then
            ctx.buffers  = {}
            ctx.nbuffers = 0
        end

        local data  = ngx.arg[1]
        local eof   = ngx.arg[2]
        local index = ctx.nbuffers + 1

        local res_length = tonumber(collections.RESPONSE_HEADERS["content-length"])
        local res_type   = collections.RESPONSE_HEADERS["content-type"]

        if not res_length or res_length > config._res_body_max_size then
            ctx.short_circuit = not eof
            return
        end

        if not res_type or not tab.table_has_key(res_type, config._res_body_mime_types) then
            ctx.short_circuit = not eof
            return
        end

        if data then
            ctx.buffers[index] = data
            ctx.nbuffers = index
        end

        if not eof then
            -- Send nothing to the client yet.
            ngx.arg[1] = nil

            -- no need to process further at this point
            ctx.short_circuit = true
            return
        else
            collections.RESPONSE_BODY = table_concat(ctx.buffers, '')
            ngx.arg[1] = collections.RESPONSE_BODY
        end
    end,
    log = function() end
}

-- parse collection elements based on a given directive
_M.parse = {
    specific = function(config, collection, value)
        --_LOG_"Parse collection is getting a specific value: " .. value
        return collection[value]
    end,
    regex = function(config, collection, value)
        --_LOG_"Parse collection is geting the regex: " .. value
        local v
        local n = 0
        local _collection = {}
        for k, _ in pairs(collection) do
            --_LOG_"checking " .. k
            if ngx.re.find(k, value, config._pcre_flags) then
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
    keys = function(config, collection)
        --_LOG_"Parse collection is getting the keys"
        return _M.table_keys(collection)
    end,
    values = function(config, collection)
        --_LOG_"Parse collection is getting the values"
        return _M.table_values(collection)
    end,
    all = function(config, collection)
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

return _M
