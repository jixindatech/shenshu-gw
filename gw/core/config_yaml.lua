local require      = require
local yaml         = require("tinyyaml")
local lfs          = require("lfs")
local cjson        = require("cjson.safe")
local new_tab      = table.new
local tab_insert   = table.insert
local setmetatable = setmetatable
local pcall        = pcall
local type         = type
local ipairs       = ipairs
local tostring     = tostring
local ngx          = ngx
local process      = require("ngx.process")
local ngx_sleep    = ngx.sleep
local ngx_timer_at = ngx.timer.at
local ngx_time     = ngx.time
local exiting      = ngx.worker.exiting

local json = require("cjson")
local schema       = require("gw.schema")
local created_obj  = {}

local _M = { version= 0.1 }

local mt = {
    __index = _M,
    __tostring = function(self)
        return " gw.yaml key: " .. self.key
    end
}

local gw_yaml
local gw_yaml_ctime
local gw_yaml_path  = ngx.config.prefix() .. "etc/gw.yaml"

local function read_gw_yaml(pre_mtime)
    local attributes, err = lfs.attributes(gw_yaml_path)
    if not attributes then
        ngx.log(ngx.ERR, "failed to fetch ", gw_yaml_path, " attributes: ", err)
        return
    end

    -- log.info("change: ", json.encode(attributes))
    local last_change_time = attributes.change
    if gw_yaml_ctime == last_change_time then
        return
    end

    local f
    f, err = io.open(gw_yaml_path, "r")
    if not f then
        ngx.log(ngx.ERR, "failed to open file ", gw_yaml_path, " : ", err)
        return
    end

    local found_end_flag
    for i = 1, 10 do
        f:seek('end', -i)

        local end_flag = f:read("*a")
        if ngx.re.find(end_flag, [[#END\s*]], "jo") then
            found_end_flag = true
            break
        end
    end

    if not found_end_flag then
        f:close()
        ngx.log(ngx.WARN, "missing valid end flag in file ", gw_yaml_path)
        return
    end

    f:seek('set')
    local yaml_config = f:read("*a")
    f:close()

    local gw_yaml_new = yaml.parse(yaml_config)
    if not gw_yaml_new then
        ngx.log(ngx.ERR, "failed to parse the content of file conf/gw.yaml")
        return
    end

    gw_yaml = gw_yaml_new
    gw_yaml_ctime = last_change_time
end


local function sync_data(self)
    if not self.key then
        return nil, "missing 'key' arguments"
    end

    if not gw_yaml_ctime then
        ngx.log(ngx.WARN, "wait for more time")
        return nil, "failed to read local file conf/gw.yaml"
    end

    if self.conf_version == gw_yaml_ctime then
        return true
    end


    local items = gw_yaml[self.key] or {}
    local values = new_tab(#items, 0)
    local values_hash = new_tab(0, #items)

    local err
    for _, item in ipairs(items) do
        local id = item.id
        if id == nil then
            ngx.log(ngx.ERR, "invalid data format, missing id")
            return
        end

        local data_valid = true
        if type(item) ~= "table" then
            data_valid = false
            ngx.log(ngx.ERR, "invalid item data of [", self.key .. "/" .. id,
                    "], val: ", json.delay_encode(item),
                    ", it shoud be a object")
            return
        end

        if data_valid and self.schema then
            data_valid, err = schema.check(self.schema, item)
            if not data_valid then
                ngx.log(ngx.ERR, "failed to check item data of [", self.key, "] err:", err, " ,val: ", json.encode(item.value))
            end
        end

        local key = "/" .. self.key .. "/" .. id
        local origin_item = _M.get(self, id)
        if origin_item ~= nil then
            if origin_item.modifiedIndex == item.timestamp then
                tab_insert(values, origin_item)
                values_hash[key] = #values
                goto CONTINUE
            else
                origin_item.release = true
            end
        end

        local conf_item = {value = item.config, modifiedIndex = item.timestamp, key = key}

        if data_valid then
            tab_insert(values, conf_item)
            values_hash[key] = #values
            conf_item.id = tostring(item.id)
            conf_item.clean_handlers = {}

            if self.init_func then
                self.init_func(conf_item)
            end
        end

        --ngx.log(ngx.ERR, cjson.encode(conf_item))

        ::CONTINUE::
    end

    if self.values then
        for _, item in ipairs(self.values) do
            if item.value and item.release then
                if item.clean_handlers then
                    for _, clean_handler in ipairs(item.clean_handlers) do
                        clean_handler(item)
                    end
                    item.value.clean_handlers = nil
                end
            end
        end
        self.values = nil
    end

    self.values = values
    self.values_hash = values_hash

    self.timestamp = ngx_time()
    self.conf_version = gw_yaml_ctime

    return true
end

local function _automatic_fetch(premature, self)
    if premature then
        return
    end

    local i = 0
    while not exiting() and self.running and i <= 32 do
        i = i + 1
        local ok, ok2, err = pcall(sync_data, self)
        if not ok then
            err = ok2
            ngx.log(ngx.ERR, "failed to fetch data from gw.yaml: ", err, ", ", tostring(self))
            ngx_sleep(3)
            break

        elseif not ok2 and err then
            if err ~= "timeout" and err ~= "Key not found"
                    and self.last_err ~= err then
                ngx.log(ngx.ERR, "failed to fetch data from gw.yaml: ", err, ", ", tostring(self))
            end

            if err ~= self.last_err then
                self.last_err = err
                self.last_err_time = ngx_time()
            else
                if ngx_time() - self.last_err_time >= 30 then
                    self.last_err = nil
                end
            end

            ngx_sleep(0.5)

        elseif not ok2 then
            ngx_sleep(0.05)
        else
            ngx.sleep(1)
        end
    end

    if not exiting() and self.running then
        ngx_timer_at(0, _automatic_fetch, self)
    end
end

function _M.fetch_created_obj(key)
    return created_obj[key]
end

function _M.get(self, id)
    if not self.values_hash then
        return
    end

    local key = "/" .. self.key .. "/" .. id
    local arr_idx = self.values_hash[key]
    if not arr_idx then
        return nil
    end

    return self.values[arr_idx]
end

function _M.new(name, config, options)
    local automatic = options and options.automatic
    local interval = options and options.interval
    local init_func = options and options.init_func
    local module_schema = options and options.schema
    local conf_version = options and options.conf_version
    ngx.log(ngx.ERR, "module name:" .. name)
    local module = setmetatable({
        name = name,
        key = name,
        config = config,
        options = options,
        automatic = automatic,
        interval = interval,
        timestamp = nil,
        running = true,
        conf_version = conf_version,
        value = nil,
        schema = module_schema,
        init_func = init_func,
        last_err = nil,
        last_err_time = nil,
    }, mt)

    if automatic then
        ngx_timer_at(0, _automatic_fetch, module)
    end

    if key then
        created_obj[key] = obj
    end

    return module, nil
end

function _M.close(self)
    self.running = false
end

function _M.init_worker()
    if process.type() ~= "worker" and process.type() ~= "single" then
        return
    end

    read_gw_yaml()
    ngx.timer.every(1, read_gw_yaml)
end

return _M
