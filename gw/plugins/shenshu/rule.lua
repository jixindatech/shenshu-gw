local type = type
local typeof = require("typeof")
local ipairs = ipairs
local tostring = tostring
local require = require
local tab_insert = table.insert
local tablepool = require("tablepool")
local cjson = require("cjson.safe")
local schema = require("gw.schema")
local producer = require("resty.kafka.producer")
local logger = require("resty.logger.socket")
local config = require("gw.core.config")
local specific = require("gw.plugins.shenshu.specific_rule")
local operator = require("gw.plugins.shenshu.rule.operator")
local request = require("gw.core.request")
local collections = require("gw.core.collections")
local action = require("gw.plugins.shenshu.rule.action")

local ngx = ngx
local ngx_now = ngx.now

local module = {}
local module_name = "shenshu_rule"
local forbidden_code
local broker_list = {}
local kafka_topic = ""

local _M = { version = "0.1"}

_M.name = module_name

local rule_schema = {
    type = "object",
    properties = {
        id = schema.id_schema,
        timestamp = schema.id_schema,
        config = {
            type = "object",
            properties = {
                action = { type = "integer" },
                decoders = {
                    type = "object",
                    properties = {
                        form = { type = "boolean", default = false},
                        json = { type = "boolean", default = false},
                        multipart = { type = "boolean", default = false}
                    }
                },
                batch = {
                    type = "array",
                    items = schema.id_schema,
                },
                specific = {
                    type = "array",
                    items = schema.id_schema,
                }
            }
        }
    }
}

function _M.init_worker(ss_config)
    local options = {
        key = module_name,
        schema = rule_schema,
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

local function rules_match(rule, variable, opts)
    local ok, text = false, ""
    if typeof.table(rule.variable) then
        for _, v in ipairs(rule.variable) do
            ok, text = rules_match(rule, opts)
            if ok then
                break
            end
        end
    else
        ok, text = operator.lookup[rule.operator](opts, variable, rule.pattern)
    end

    return ok, text
end

function _M.access(ctx)
    local route = ctx.matched_route
    local rules = module:get(route.id)
    if rules.value ~= nil then
        if rules.value.specific_rules == nil then
            local match_rules, err =specific.get_rules(rules.value.specific)
            if err ~= nil then
                return false, err
            end

            rules.value.specific_rules = match_rules
        end

        ctx.rules_matched_events = {}

        local params = tablepool.fetch("rule_collections", 0, 32)
        collections.lookup["access"](rules, request, ctx)

        local config_action = rules.action
        for _, item in ipairs(rules.value.specific_rules) do
            local rule_action = item.action
            local matched = false
            for _, rule in ipairs(item.rules) do
                local text, variable

                if rule.variable == "REQ_HEADER" then
                    variable = params.REQUEST_HEADERS[rule.header]
                elseif rule.variable == "FILE_NAMES" then
                    variable = params.FILES_NAMES
                elseif rule.variable == "FILE" then
                    variable = params.FILES_TMP_CONTENT
                elseif rule.variable == "REQUEST_BODY" then
                    variable = request.get_request_body()
                else
                    variable = params[rule.variable]
                end

                matched, text = rules_match(rule, variable, rules)
                if matched ~= true then
                    break
                end

                local event = {
                    host = ctx.var.host,
                    ip = ctx.var.ip,
                    timestamp = ngx_now(),
                    uri = ctx.var.uri,
                    method = ctx.var.method,
                    id = rule.id,
                    info = rule.msg,
                    text = text,
                }

                tab_insert(ctx.rules_matched_events, event)
            end

            if matched then
                if rule_action == action.ALLOW then
                    ctx.rules_action = action.ALLOW
                    break
                end

                if rule_action == action.LOG then
                    ctx.rules_action = action.LOG
                else
                    ctx.rules_action = action.DENY
                end

                if rules.short_circuit == 1 then
                    ctx.rules_short_circuit = 1
                    break
                end
            end
        end
    end
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
    tablepool.release("rule_collections", ctx)
    if ctx.rules_matched_events and #ctx.rules_matched_events > 0 then
        local msg = ctx.rules_matched_events
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
end

return _M

