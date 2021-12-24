local require = require
local lfs   = require("lfs")
local yaml  = require("tinyyaml")
local cjson = require("cjson.safe")

local globalip = require("gw.plugins.shenshu.globalip")
local ip = require("gw.plugins.shenshu.ip")
local cc = require("gw.plugins.shenshu.cc")
local batch_rule = require("gw.plugins.shenshu.batch_rule")
local specific_rule = require("gw.plugins.shenshu.specific_rule")
local rule = require("gw.plugins.shenshu.rule")

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
    local status, err = ip.access(ctx)
    if err ~= nil then
        ngx.log(ngx.ERR, "err:" .. err)
    end

    if ctx.ip_denied then
        ngx.log(ngx.ERR, "ip denied")
    end

    if ctx.ip_allowed then
        ngx.log(ngx.ERR, "ip allowd")
    end

    status, err = cc.access(ctx)
    if err ~= nil then
        ngx.exit(400)
    end

    status = rule.access(ctx)

end

function _M.log(ctx)

end

return _M

