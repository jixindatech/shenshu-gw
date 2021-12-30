local require = require
local cjson = require("cjson.safe")
local producer = require("resty.kafka.producer")
local logger = require("resty.logger.socket")
local _M = {}

function _M.file(msg)
    local logstr = cjson.encode(msg)
    ngx.log(ngx.ERR, logstr)
end

function _M.rsyslog(name, msg, host, port, type)
    if not logger.initted() then
        local ok, err = logger.init {
            host = host,
            port = port,
            sock_type = type,
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

function _M.kafkalog(msg, broker_list, kafka_topic)
    local message = cjson.encode(msg)
    local bp = producer:new(broker_list, { producer_type = "async" })
    local ok, err = bp:send(kafka_topic, nil, message)
    if not ok then
        ngx.log(ngx.ERR, "kafka send err:", err)
        return
    end
end

return _M