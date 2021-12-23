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
local batch = require("gw.plugins.shenshu.batch_rule")
local operator = require("gw.plugins.shenshu.rule.operator")
local request = require("gw.core.request")
local collections = require("gw.core.collections")
local action = require("gw.plugins.shenshu.rule.action")
local tab = require("gw.core.table")

local ngx = ngx
local ngx_now = ngx.now

local module = {}
local module_name = "shenshu_rule"
local forbidden_code
local specific_broker_list = {}
local specific_kafka_topic = ""
local batch_broker_list = {}
local batch_kafka_topic = ""

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

    if module.local_config.specific_log == nil or module.local_config.batch_log == nil then
        return "shenshu config log is missing"
    end

    if module.local_config.specific_log.kafka and module.local_config.specific_log.kafka.broker ~= nil then
        for _, item in pairs(module.local_config.specific_log.kafka.broker) do
            tab_insert(specific_broker_list, item)
        end
        if #specific_broker_list == 0 then
            return "kafka configuration is missing"
        end

        specific_kafka_topic = module.local_config.specific_log.kafka.topic or "shenshu_speicifc"
    end

    if module.local_config.batch_log.kafka and module.local_config.batch_log.kafka.broker ~= nil then
        for _, item in pairs(module.local_config.batch_log.kafka.broker) do
            tab_insert(batch_broker_list, item)
        end
        if #batch_broker_list == 0 then
            return "kafka configuration is missing"
        end

        batch_kafka_topic = module.local_config.batch_log.kafka.topic or "shenshu_batch"
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
    local matched = false
    local config_action = rules.action

    if rules.value ~= nil then
        if rules.value.specific_rules == nil then
            local specific_rules, err =specific.get_rules(rules.value.specific)
            if err ~= nil then
                return false, err
            end

            rules.value.specific_rules = specific_rules
        end

        ctx.specific_matched_events = tab.new(0, 20)

        local params = tablepool.fetch("rule_collections", 0, 32)
        collections.lookup["access"](rules, params, ctx)

        for _, item in ipairs(rules.value.specific_rules) do
            local rule_action = item.value.action
            for _, rule in ipairs(item.value.rules) do
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
                    id = item.id,
                    info = rule.msg,
                    text = text,
                }

                tab_insert(ctx.specific_matched_events, event)
            end

            if matched then
                if rule_action == action.ALLOW then
                    ctx.rules_action = action.ALLOW
                    --[[ Allow first privilege ]]--
                    return true, nil
                end

                if rule_action == action.LOG or config_action == action.LOG then
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

        if matched and rules.short_circuit == 1 then
            return true, nil
        end

        if rules.value.batch_rules == nil then
            local batch_rules, err =batch.get_rules(rules.value.batch)
            if err ~= nil then
                return false, err
            end

            rules.value.batch_rules = batch_rules
        end

        ctx.batch_matched_events = tab.new(0, 20)

        local uri_args = tab.table_values(params.URI_ARGS)
        if #uri_args > 0 then
            local hits = rules.value.batch_rules.db:scan(uri_args, rules.value.batch_rules.scratch)
            if #hits > 0 then
                matched = true
                local events = {
                    id = hits,
                    text = params.URI_ARGS
                }
                tab_insert(ctx.batch_matched_events, events)

                if config_action == action.LOG then
                    ctx.rules_action = action.LOG
                else
                    ctx.rules_action = action.DENY
                end
            end
        end

        if matched and rules.short_circuit == 1 then
            return true, nil
        end

        local body_args = tab.table_values(params.BODY_ARGS)
        if #body_args > 0 then
            local hits = rules.value.batch_rules.db:scan(body_args, rules.value.batch_rules.scratch)
            if #hits > 0 then
                local events = {
                    id = hits,
                    text = params.BODY_ARGS
                }
                tab_insert(ctx.batch_matched_events, events)

                if config_action == action.LOG then
                    ctx.rules_action = action.LOG
                else
                    ctx.rules_action = action.DENY
                end
            end
        end

        return true, nil
    end
end


function _M.log(ctx)
    tablepool.release("rule_collections", ctx)
    if ctx.specific_matched_events and #ctx.specific_matched_events > 0 then
        if module and module.local_config.specific_log.file then
            logger.file(ctx.specific_matched_events)
        end

        if module and module.local_config.specific_log.rsyslog then
            logger.rsyslog(ctx.specific_matched_events,
                    module.local_config.specific_log.rsyslog.host,
                    module.local_config.specific_log.rsyslog.port,
                    module.local_config.specific_log.rsyslog.type)
        end

        if module and module.local_config.specific_log.kafka then
            logger.kafkalog(ctx.specific_matched_events,
                    specific_broker_list,
                    specific_kafka_topic)
        end

        ctx.specific_matched_events = nil
    end

    if ctx.batch_matched_events and #ctx.batch_matched_events > 0 then
       if module and module.local_config.batch_log.file then
          logger.file(ctx.batch_matched_events)
       end

       if module and module.local_config.specific_log.rsyslog then
          logger.rsyslog(ctx.batch_matched_events, module.local_config.specific_log.rsyslog.host,
                  module.local_config.batch_log.rsyslog.port,
                  module.local_config.batch_log.rsyslog.type)
        end

       if module and module.local_config.specific_log.kafka then
          logger.kafkalog(ctx.batch_matched_events,
                  batch_broker_list,
                  batch_kafka_topic)
       end

       ctx.batch_matched_events = nil
    end

end

return _M

