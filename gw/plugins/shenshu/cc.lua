local type = type
local tostring = tostring
local require = require
local tab_insert = table.insert
local cjson = require("cjson.safe")
local producer = require "resty.kafka.producer"
local logger = require("resty.logger.socket")
local config = require("gw.core.config")

local ngx = ngx

local module = {}
local module_name = "cc"
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
        for _, item in pairs(module.local_config.log.kafka.broker) do
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

