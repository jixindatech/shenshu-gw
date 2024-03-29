local require = require
local math    = math
local error   = error
local ngx     = ngx
local tablepool   = require("tablepool")
local balancer = require("ngx.balancer")

local config      = require("gw.core.config")
local yaml_config = require("gw.core.config_yaml")
local ssl         = require("gw.ssl")
local router      = require("gw.router")
local upstream    = require("gw.upstream")
local plugin      = require("gw.plugin")
local log         = require("gw.log")

local seed = ngx.time()

local _M = {version = 0.1}

local config_path =  ngx.config.prefix() .. "etc/config.yaml"

function _M.http_init()
    require("resty.core")
    math.randomseed(seed)

    local err
    err = config.load_conf(config_path)
    if err ~= nil then
        error(err)
    end
end

function _M.http_init_worker()
    local we = require("resty.worker.events")
    local ok, err = we.configure({shm = "worker-events", interval = 0.1})
    if not ok then
        error("failed to init worker event: " .. err)
    end

    -- yaml type check
    if config.get_config_type() and config.get_config_type() == "yaml" then
        yaml_config.init_worker()
    end

    err = ssl.init_worker()
    if err ~= nil then
        ngx.log(ngx.ERR, "balancer init worker failed:" .. err)
    end

    err = router.init_worker()
    if err ~= nil then
        ngx.log(ngx.ERR, "balancer init worker failed:" .. err)
    end

    err = upstream.init_worker()
    if err ~= nil then
        ngx.log(ngx.ERR, "balancer init worker failed:" .. err)
    end

    ok, err = plugin.init_worker()
    if err ~= nil then
        ngx.log(ngx.ERR, "gw init worker failed:" .. err)
    end

    local rsyslog_config = config.get_config_rsyslog()
    if rsyslog_config == nil then
        ngx.log(ngx.ERR, "rsyslog use default config")
    end

    ok, err = log.init_worker(rsyslog_config)
    if err ~= nil then
        ngx.log(ngx.ERR, "log init worker failed:" .. err)
    end
end

function _M.http_ssl_phase()
    local ngx_ctx = ngx.ctx
    local api_ctx = ngx_ctx.api_ctx

    if api_ctx == nil then
        api_ctx = tablepool.fetch("api_ctx", 0, 32)
        ngx_ctx.api_ctx = api_ctx
    end

    local sni, err = ssl.run(api_ctx)
    if err ~= nil then
        ngx.log(ngx.ERR, 'ssl phase error: ' .. err)
        ngx.exit(ngx.ERROR)
    end
end

function _M.http_access_phase()
    local ngx_ctx = ngx.ctx
    local api_ctx = tablepool.fetch("api_ctx", 0, 32)
    ngx_ctx.api_ctx = api_ctx

    api_ctx.var = ngx.var
    --api_ctx.var.request_method = ngx.var.request_method
    --api_ctx.var.remote_addr = ngx.var.remote_addr
    --api_ctx.var.host = ngx.var.host

    router.match(api_ctx)
    local route = api_ctx.matched_route
    if not route then
        return ngx.exit(404)
    end

    local code, err = plugin.run("access", api_ctx)
    if code then
        ngx.exit(code)
    end

end

function _M.http_balancer_phase()
    local api_ctx = ngx.ctx.api_ctx
    if not api_ctx then
        return ngx.exit(500)
    end

    local host, port, err = upstream.get(api_ctx, api_ctx.matched_route.value.upstream_id)
    if err ~= nil then
        ngx.exit(ngx.ERROR)
    end

    local ok, err = balancer.set_current_peer(host, port)
    if not ok then
        ngx.log(ngx.ERR, "banlancer error:", err)
    end
end

function _M.http_header_filter_phase()
    local ngx_ctx = ngx.ctx
    plugin.run("header_filter", ngx_ctx)
end

function _M.http_body_filter_phase()
    local ngx_ctx = ngx.ctx
    plugin.run("body_filter", ngx_ctx)
end

function _M.http_log_phase()
    local api_ctx = ngx.ctx.api_ctx
    plugin.run("log", api_ctx)

    tablepool.release("api_ctx", api_ctx)
end

return _M
