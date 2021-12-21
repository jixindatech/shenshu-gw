local require = require
local cjson = require("cjson.safe")
local config = require("gw.core.config")
local zt = require("gw.plugins.zt")
local shenshu = require("gw.plugins.shenshu")


local _M = {}
-- local plugins = { zt }
local plugins = { shenshu }
local function plugin_init_worker()
    for _, item in ipairs(plugins) do
        if item.init_worker then
            local ok, err = item.init_worker()
            if err ~= nil then
                return nil, err
            end
        end
    end

    return true, nil
end

function _M.init_worker()
    return plugin_init_worker()
end

function _M.run(phase, ctx)
    for _, item in ipairs(plugins) do
        if item[phase] then
            local code ,err = item[phase](ctx)
        end
    end
end

return _M
