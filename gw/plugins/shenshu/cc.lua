local type = type
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local require = require
local tab_insert = table.insert
local tab_clear = table.clear
local schema = require("gw.schema")
local cjson = require("cjson.safe")
local radix = require("resty.radixtree")
local limit_conn = require("resty.limit.conn")
local limit_req = require("resty.limit.req")
local limit_traffic = require("resty.limit.traffic")
local logger = require("gw.plugins.shenshu.log")
local config = require("gw.core.config")
local tab = require("gw.core.table")

local ngx = ngx
local ngx_sleep = ngx.sleep
local ngx_time = ngx.time

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
        id = schema.id_schema,
        timestamp = schema.id_schema,
        config = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    id = schema.id_shema,
                    action = { type = "string" },
                    method = { type = "string" },
                    mode = { type = "string" },
                    threshold = { type = "integer" },
                    uri = { type = "string" }
                }
            }
        },
        required = {"id", "timestamp", "config"}
    }
}

function _M.init_worker(cc_config)
    local options = {
        key = module_name,
        schema = cc_schema,
        automatic = true,
        interval = 10,
    }

    if cc_config == nil then
        return "cc config is missing"
    end

    local err
    module, err = config.new(module_name, options)
    if err ~= nil then
        return err
    end

    module.local_config = cc_config

    if module.local_config.kafka and module.local_config.kafka.broker ~= nil then
        for _, item in ipairs(module.local_config.kafka.broker) do
            tab_insert(broker_list, item)
        end
        if #broker_list == 0 then
            return "kafka configuration is missing"
        end

        kafka_topic = module.local_config.kafka.topic or "shenshu_cc"
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
                ctx.shenshu_cc_matched_config = item
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
    if #ccs.value > 0 then
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

        local cc_config = ctx.shenshu_cc_matched_config
        local key
        if cc_config.mode == "ip" then
            key = ctx.var.remote_addr
        end

        local lim1, lim2, err
        lim1, err = limit_req.new(lua_shared_dict_cc_req, cc_config.threshold, 0)
        lim2, err = limit_conn.new(lua_shared_dict_cc_conn, cc_config.threshold, 0, 0.5)
        local limiters = { lim1, lim2 }

        local keys = {key, key}
        local states = {}

        local delay
        delay, err = limit_traffic.combine(limiters, keys, states)
        if not delay then
            if err == "rejected" then
                local msg = tab.new(20, 10)
                msg = {
                    host = ctx.var.host,
                    ip = ctx.shenshu_ip,
                    timestamp = ngx_time(),
                    uri = ctx.var.uri,
                    method = ngx.req.get_method(),
                    id = cc_config.id,
                }
                ctx.shenshu_cc_msg = msg
                return false, "rejected"
            end
            return false, err
        end

        if lim2:is_committed() then
            ctx.shenshu_cc_limit_conn = lim2
            ctx.shenshu_cc_limit_conn_key = key
        end

        if delay >= 0.001 then
            ngx_sleep(delay)
        end

    end

    return true, nil
end

function _M.log(ctx)
    local lim = ctx.shenshu_cc_limit_conn
    if lim then
        local latency = tonumber(ngx.var.request_time)
        local key = ctx.shenshu_cc_limit_conn_key
        local conn, err = lim:leaving(key, latency)
        if not conn then
            ngx.log(ngx.ERR, "failed to record the connection leaving ", "request: ", err)
        end
    end

    local msg = ctx.shenshu_cc_msg
    if msg ~= nil then
        ngx.log(ngx.ERR, cjson.encode(msg))
        if module and module.local_config.file then
            logger.file(msg)
        end

        if module and module.local_config.rsyslog then
            logger.rsyslog(msg,
                    module.local_config.rsyslog.host,
                    module.local_config.rsyslog.port,
                    module.local_config.rsyslog.type)
        end

        if module and module.local_config.kafka then
            logger.kafkalog(msg,
                    module.local_config.kafka.broker_list,
                    module.local_config.kafka.topic)
        end

        ctx.shenshu_cc_msg = nil
    end
end

return _M

