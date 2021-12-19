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
local module_name = "batch_rule"
local forbidden_code
local broker_list = {}
local kafka_topic = ""

local _M = { version = "0.1"}

_M.name = module_name

local batchrule_schema = {
    type = "object",
    properties = {
    }
}

function _M.init_worker(ss_config)
    local options = {
        key = module_name,
        schema = batchrule_schema,
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

function _M.log(ctx)

end

return _M

