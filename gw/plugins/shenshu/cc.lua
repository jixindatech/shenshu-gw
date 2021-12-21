local type = type
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local require = require
local tab_insert = table.insert
local tab_clear = table.clear

local cjson = require("cjson.safe")
local radix = require("resty.radixtree")
local limit_conn = require("resty.limit.conn")
local limit_req = require("resty.limit.req")
local limit_traffic = require("resty.limit.traffic")
local producer = require("resty.kafka.producer")
local logger = require("resty.logger.socket")
local config = require("gw.core.config")

local ngx = ngx
local ngx_sleep = ngx.sleep

local module = {}
local module_name = "shenshu_cc"
local lua_shared_dict_cc_req = "cc_limit_req_store"
local lua_shared_dict_cc_conn = "cc_limit_conn_store"
local forbidden_code
local broker_list = {}
local kafka_topic = ""

local _M = { version = "0.1"}

_M.name = module_name

local cc_schema = {
    type = "object",
    properties = {
        id = {
            type = "integer",
            minimum = 1
        },
        config = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    action = { type = "string" },
                    duration = { type = "integer" },
                    match = { type = "string" },
                    method = { type = "string" },
                    mode = { type = "string" },
                    threshold = { type = "integer" },
                    uri = { type = "string" }
                }
            }
        }
    }
}

function _M.init_worker(ss_config)
    local options = {
        key = module_name,
        schema = cc_schema,
        automatic = true,
        interval = 10,
    }

    local err
    module, err = config.new(module_name, options)
    if err ~= nil then
        return err
    end

    module.local_config = ss_config

    if module.local_config.log == nil then
        return "gw config log is missing"
    end

    if module.local_config.log.kafka and module.local_config.log.kafka.broker ~= nil then
        for _, item in ipairs(module.local_config.log.kafka.broker) do
            tab_insert(broker_list, item)
        end
        if #broker_list == 0 then
            return "kafka configuration is missing"
        end

        kafka_topic = module.local_config.log.kafka.topic or "gw"
    end

    forbidden_code = module.local_config.deny_code or 401
    return nil
end

local function construct_radix(configs)
    local radix_items = {}
    for _, item in ipairs(configs) do
        local obj = {
            paths = { item.uri},
            methods = { item.method },
            handler = function (ctx)
                ctx.matched_config = item
            end
        }
        tab_insert(radix_items, obj)
    end

    return radix.new(radix_items)
end

local match_opts = {}
function _M.access(ctx)
    local route = ctx.matched_route
    local ccs = module:get(route.id)
    if ccs.value ~= nil then
        if ccs.value.matcher == nil then
            local matcher  = construct_radix(ccs.value)
            if err ~= nil then
                ngx.log(ngx.ERR, "radixtree error:" .. err)
                return false , err
            end
            ccs.value.matcher = matcher
        end

        tab_clear(match_opts)
        match_opts.method = ctx.var.request_method

        local ok = ccs.value.matcher:dispatch(ngx.var.uri, match_opts, ctx)
        if ok ~= true then
            return true, nil
        end

        local cc_config = ctx.matched_config
        ngx.log(ngx.ERR, cjson.encode(cc_config))
        local key
        if cc_config.mode == "ip" then
            key = ctx.var.remote_addr
        end

        local lim1, lim2, err
        lim1, err = limit_req.new(lua_shared_dict_cc_req, cc_config.threshold, cc_config.duration)
        lim2, err = limit_conn.new(lua_shared_dict_cc_conn, cc_config.threshold, 0, cc_config.duration)
        local limiters = { lim1, lim2 }

        local keys = {key, key}
        local states = {}

        local delay
        delay, err = limit_traffic.combine(limiters, keys, states)
        if not delay then
            if err == "rejected" then
                return false, "rejected"
            end
            return false, err
        end

        if lim2:is_committed() then
            ctx.cc_limit_conn = lim2
            ctx.cc_limit_conn_key = key
        end

        if delay >= 0.001 then
            ngx_sleep(delay)
        end

    end

    return true, nil
end

local function file(msg)
    local logstr = cjson.encode(msg)
    ngx.log(ngx.ERR, logstr)

end

local function rsyslog(msg)
    if not logger.initted() then
        local ok, err = logger.init {
            host = module.local_config.log.rsyslog.host,
            port = module.local_config.log.rsyslog.port,
            sock_type = module.local_config.log.rsyslog.type,
            flush_limit = 1,
            --drop_limit = 5678,
            timeout = 10000,
            pool_size = 100
        }
        if not ok then
            ngx.log(ngx.ERR, "failed to initialize the logger: ", err)
            return
        end
    end

    local logstr = cjson.encode(msg)
    local bytes, err = logger.log(logstr.."\n")
    if err then
        ngx.log(ngx.ERR, "failed to log message: ", err)
        return
    end

end

local function kafkalog(msg)
    local message = cjson.encode(msg)
    local bp = producer:new(broker_list, { producer_type = "async" })
    local ok, err = bp:send(kafka_topic, nil, message)
    if not ok then
        ngx.log(ngx.ERR, "kafka send err:", err)
        return
    end
end

function _M.log(ctx)

    local lim = ctx.cc_limit_conn
    if lim then
        local latency = tonumber(ngx.var.request_time)
        local key = ctx.limit_conn_key
        local conn, err = lim:leaving(key, latency)
        if not conn then
            ngx.log(ngx.ERR, "failed to record the connection leaving ", "request: ", err)
        end
    end

    local msg = ctx.gw_msg
    if msg ~= nil then
        if module and module.local_config.log.file then
            file(msg)
        end

        if module and module.local_config.log.rsyslog then
            rsyslog(msg)
        end

        if module and module.local_config.log.kafka then
            kafkalog(msg)
        end
    end
end

return _M

