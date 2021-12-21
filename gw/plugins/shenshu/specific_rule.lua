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
local module_name = "shenshu_specific_rule"

local _M = { version = "0.1"}

_M.name = module_name

local specific_schema = {
    type = "object",
    properties = {
    }
}

function _M.init_worker(ss_config)
    local options = {
        key = module_name,
        schema = specific_schema,
        automatic = true,
        interval = 10,
    }

    local err
    module, err = config.new(module_name, options)
    if err ~= nil then
        return err
    end

    return nil
end

function _M.get_rules(ids)
    local rules = {}
    for _, v in ipairs(ids) do
        local rule = module:get(v)
        if rule == nil then
            return nil, "not found rule id:" .. tostring(v)
        end
        tab_insert(rules, rule)
    end

    return rules, nil
end

return _M

