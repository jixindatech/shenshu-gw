local setmetatable = setmetatable
local require      = require
local pcall        = pcall
local ipairs       = ipairs
local new_tab      = table.new
local tab_insert   = table.insert
local type         = type
local tostring     = tostring
local sub_str      = string.sub
local ngx          = ngx
local ngx_sleep    = ngx.sleep
local ngx_timer_at = ngx.timer.at
local ngx_time     = ngx.time
local exiting      = ngx.worker.exiting
local schema       = require("gw.schema")

local cjson = require("cjson.safe")
local redis = require("resty.redis")

local key_prefix = "/admin/"

local _M = { version= 0.1 }

local mt = {
    __index = _M,
    __tostring = function(self)
        return " redis key: " .. self.key
    end
}

local function short_key(self, str)
    return sub_str(str, #self.key + 2)
end

local function get_redis_cli(config)
    local redis_cli = redis:new()
    local timeout = config.timeout or 5000
    redis_cli:set_timeout(timeout)

    local ok, err = redis_cli:connect(config.host, config.port)
    if not ok then
        return nil, err
    end

    if config.password then
        local count
        count, err = redis_cli:get_reused_times()
        if count == 0 then
            ok, err = redis_cli:auth(config.password)
            if not ok then
                return nil, err
            end
        elseif err then
            return nil, err
        end
    end

    if config.db then
        redis_cli:select(config.db)
    end

    return redis_cli, nil
end

local function sync_data(self)
    local redis_config = self.config.redis
    local redis_cli, err = get_redis_cli(redis_config)
    if err ~= nil then
        ngx.log(ngx.ERR, "get redis failed:" .. err)
        return err
    end

    local res
    res, err = redis_cli:get(self.key)
    if not res then
        ngx.log(ngx.ERR, "failed to get:" .. self.key .." from redis")
        return err
    end

    if res == ngx.null then
        ngx.log(ngx.ERR, "get invalid data by key:", self.key)
        return
    end

    local timeout = redis_config.timeout or 5000
    local pool_num = redis_config.size or 100
    local ok
    ok, err = redis_cli:set_keepalive(timeout, pool_num)
    if not ok then
        return nil, err
    end

    local data = cjson.decode(res)
    if data.timestamp == self.timestamp then
        return
    end

    local items = data.values or {}
    local values = new_tab(#items, 0)
    local values_hash = new_tab(0, #items)

    local changed = false
    for i, item in ipairs(items) do
        --[[primary key is id or name, must be unique]]--
        local id = item.id or item.name
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
                changed = true
                tab_insert(values, origin_item)
                values_hash[key] = #values
                goto CONTINUE
            else
                origin_item.release = true
            end
        end

        local conf_item = {value = item.config, modifiedIndex = item.timestamp, key = key}

        if data_valid then
            changed = true
            tab_insert(values, conf_item)
            values_hash[key] = #values
            conf_item.id = tostring(item.id)
            conf_item.clean_handlers = {}

            if self.init_func then
                self.init_func(conf_item)
            end
        end

        ngx.log(ngx.ERR, "key:" .. key .. " data:" .. cjson.encode(conf_item))

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

    if changed then
        self.timestamp = data.timestamp or ngx_time()
        self.conf_version = self.conf_version + 1
    end
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
            ngx.log(ngx.ERR, "failed to fetch data from redis: ", err, ", ", tostring(self))
            ngx_sleep(3)
            break

        elseif not ok2 and err then
            if err ~= "timeout" and err ~= "Key not found"
                    and self.last_err ~= err then
                ngx.log(ngx.ERR, "failed to fetch data from etcd: ", err, ", ", tostring(self))
            end

            ngx_sleep(0.5)

        elseif not ok2 then
            ngx_sleep(0.05)
        end

        ngx.sleep(self.interval)
    end

    if not exiting() and self.running then
        ngx_timer_at(0, _automatic_fetch, self)
    end
end

function _M.get(self, id)
    if not self.values_hash then
        return
    end

    local key = "/" .. self.key .. "/" .. id
    local arr_idx = self.values_hash[tostring(key)]
    if not arr_idx then
        return nil
    end

    return self.values[arr_idx]
end

function _M.new(name, config, options)
    local automatic = options and options.automatic
    local interval = options and options.interval
    local filter_fun = options and options.filter
    local module_schema = options and options.schema

    local key = key_prefix .. name

    local module = setmetatable({
        name = name,
        key = key,
        config = config,
        options = options,
        automatic = automatic,
        interval = interval,
        timestamp = nil,
        running = true,
        conf_version = 0,
        value = nil,
        schema = module_schema,
        filter = filter_fun,
    }, mt)

    if automatic then
        ngx_timer_at(0, _automatic_fetch, module)
    end

    return module, nil
end

return _M
