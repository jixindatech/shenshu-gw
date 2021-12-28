local require = require
local lfs   = require("lfs")
local yaml  = require("tinyyaml")
local cjson = require("cjson.safe")
local uuid = require("resty.jit-uuid")

local globalip = require("gw.plugins.shenshu.globalip")
local ip = require("gw.plugins.shenshu.ip")
local cc = require("gw.plugins.shenshu.cc")
local batch_rule = require("gw.plugins.shenshu.batch_rule")
local specific_rule = require("gw.plugins.shenshu.specific_rule")
local rule = require("gw.plugins.shenshu.rule")
local action = require("gw.plugins.shenshu.rule.action")

local ngx = ngx
local conf_file = ngx.config.prefix() .. "etc/ss.yaml"
local module = {}
local module_name = "shenshu"

local _M = { version = "0.1"}

_M.name = module_name

function _M.init_worker()
    local attributes, err
    attributes, err = lfs.attributes(conf_file)
    if not attributes then
        ngx.log(ngx.ERR, "failed to fetch ", conf_file, " attributes: ", err)
        return false, err
    end

    local f
    f, err = io.open(conf_file, "r")
    if not f then
        ngx.log(ngx.ERR, "failed to open file ", conf_file, " : ", err)
        return false, err
    end

    local yaml_data = f:read("*a")
    f:close()

    local yaml_config = yaml.parse(yaml_data)
    if not yaml_config then
        return false, err
    end

    module.local_config = yaml_config

    uuid.seed()

    err = globalip.init_worker(yaml_config.ip_log)
    if err ~= nil then
        return false, err
    end

    err = ip.init_worker(yaml_config.ip_log)
    if err ~= nil then
        return false, err
    end

    err = cc.init_worker(yaml_config.cc_log)
    if err ~= nil then
        return false, err
    end

    err = rule.init_worker(yaml_config)
    if err ~= nil then
        return false, err
    end

    err = specific_rule.init_worker()
    if err ~= nil then
        return false, err
    end

    err = batch_rule.init_worker()
    if err ~= nil then
        return false, err
    end
end

function _M.access(ctx)
    ctx.shenshu_ip = ctx.var.remote_addr
    ctx.shenshu_uuid =  uuid.generate_v4()

    local status, err = globalip.access(ctx)
    if err ~= nil then
        ngx.log(ngx.ERR, "err:" .. err)
    end

    if ctx.ip_allowed then
        return
    end

    if ctx.ip_denied then
        ngx.exit(400)
    end

    status, err = ip.access(ctx)
    if err ~= nil then
        ngx.log(ngx.ERR, "err:" .. err)
    end

    if ctx.ip_allowed then
        return
    end

    if ctx.ip_denied then
        ngx.exit(400)
    end

    status, err = cc.access(ctx)
    if err == "rejected" then
        ngx.exit(400)
    end

    if err ~= nil then
        ngx.log(ngx.ERR, err)
    end

    status, err = rule.access(ctx)
    if err ~= nil then
        ngx.log(ngx.ERR, err)
    end

    if ctx.shenshu_rule_action == action.DENY then
        ngx.exit(400)
    end
end

function _M.log(ctx)
    local err = globalip.log(ctx)
    if err ~= nil then
        ngx.log(ngx.ERR, err)
    end

    err = ip.log(ctx)
    if err ~= nil then
        ngx.log(ngx.ERR, err)
    end

    err = cc.log(ctx)
    if err ~= nil then
        ngx.log(ngx.ERR, err)
    end

    err = rule.log(ctx)
    if err ~= nil then
        ngx.log(ngx.ERR, err)
    end
end

return _M

