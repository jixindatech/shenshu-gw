local type = type
local tostring = tostring
local require = require
local ipmatcher = require("resty.ipmatcher")
local schema = require("gw.schema")
local tab_insert = table.insert
local logger = require("gw.plugins.shenshu.log")
local config = require("gw.core.config")

local ngx = ngx

local module = {}
local module_name = "shenshu_ip"
local forbidden_code
local broker_list = {}
local kafka_topic = ""

local _M = { version = "0.1"}

_M.name = module_name

local ip_schema = {
    type = "object",
    properties = {
        id = schema.id_schema,
        timestamp = schema.id_schema,
        config = {
            type = "object",
            properties = {
                accept = {
                    type = "array",
                    items = {
                        type = "string"
                    }
                },
                deny = {
                    type = "array",
                    items = {
                        type = "string"
                    }
                }
            }
        },
        required = {"id", "timestamp", "config"}
    }
}

function _M.init_worker(ss_config)
    local options = {
        key = module_name,
        schema = ip_schema,
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

function _M.access(ctx)
    ctx.ip = ctx.var.remote_addr
    local route = ctx.matched_route
    local ips = module:get(route.id)
    if ips.value.allow ~= nil then
        if ips.value.allow_matcher == nil then
            local matcher, err = ipmatcher.new(ips.value.allow)
            if err ~= nil then
                return false, err
            end
            ips.value.allow_matcher = matcher
        end
        local ok, err = ips.value.allow_matcher:match(ctx.ip)
        if ok then
            ctx.ip_allowed = true
            return true, nil
        end
    end

    if ips.value.deny ~= nil then
        if ips.value.deny_matcher == nil then
            local matcher, err = ipmatcher.new(ips.value.deny)
            if err ~= nil then
                return false, err
            end
            ips.value.deny_matcher = matcher
        end

        local ok, err = ips.value.deny_matcher:match(ctx.ip)
        if ok then
            ctx.ip_denied = true
            return true, nil
        end
    end

    return true, nil
end

function _M.log(ctx)
    local msg = ctx.ip_msg
    if msg ~= nil then
        if module and module.local_config.log.file then
            logger.file(msg)
        end

        if module and module.local_config.log.rsyslog then
            logger.rsyslog(msg, module.local_config.log.rsyslog.host,
                    module.local_config.log.rsyslog.port,
                    module.local_config.log.rsyslog.type)
        end

        if module and module.local_config.log.kafka then
            logger.kafkalog(msg,
                    module.local_config.log.kafka.broker_list,
                    module.local_config.log.kafka.topic)
        end
    end
end

return _M

