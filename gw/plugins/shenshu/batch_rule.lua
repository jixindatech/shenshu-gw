local type = type
local tostring = tostring
local require = require
local tab_insert = table.insert
local luahs = require("luahs")
local schema = require("gw.schema")
local config = require("gw.core.config")

local ngx = ngx

local module = {}
local module_name = "shenshu_batch_rule"
local forbidden_code
local broker_list = {}
local kafka_topic = ""

local _M = { version = "0.1"}

_M.name = module_name

local batchrule_schema = {
    type = "object",
    properties = {
        id = schema.id_schema,
        timestamp = schema.id_schema,
        config = {
            type="object",
            properties = {
                action = schema.id_schema,
                msg = { type = "string" },
                pattern = { type = "string" }
            },
            required={"action", "pattern"}
        },
        required={"id", "timestamp", "config"}
    }
}

function _M.init_worker()
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

    return nil
end

function _M.get_rules(ids)
    local expressions = {}
    for _, v in ipairs(ids) do
        local rule = module:get(v)
        if rule == nil then
            return nil, "not found rule id:" .. tostring(v)
        end

        local expression = {
            id  = tonumber(rule.id),
            expression = rule.value.pattern,
            flags = {
                luahs.pattern_flags.HS_FLAG_CASELESS,
                luahs.pattern_flags.HS_FLAG_DOTALL,
            }
        }
        tab_insert(expressions, expression)
    end

    local db, err = luahs.compile{
        expressions = expressions,
        mode = luahs.compile_mode.HS_MODE_VECTORED,
    }

    if err ~= nil then
        return nil, err
    end

    local scratch = db:makeScratch()

    return {db = db, scratch = scratch}, nil
end

return _M

