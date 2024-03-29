#!/usr/bin/env lua

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function excute_cmd(cmd)
    local t = io.popen(cmd)
    local data = t:read("*all")
    t:close()
    return data
end

excute_cmd("install -d -m 777 /tmp/gw_cores/")

local pkg_cpath_org = package.cpath
local pkg_path_org = package.path

local gw_home = "/usr/local/gw"
local pkg_cpath = gw_home .. "/deps/lib64/lua/5.1/?.so;"
                  .. gw_home .. "/gw/?.so"
                  .. gw_home .. "/deps/lib/lua/5.1/?.so;;"
local pkg_path  = gw_home .. "/deps/share/lua/5.1/gw/lua/?.lua;"
                  .. gw_home .. "/deps/share/lua/5.1/?.lua;;"

-- only for developer, use current folder as working space
local script_path = arg[0]
if script_path:sub(1, 2) == './' then
    gw_home = trim(excute_cmd("pwd"))
    if not gw_home then
        error("failed to fetch current path")
    end

    pkg_cpath = gw_home .. "/deps/lib64/lua/5.1/?.so;"
                .. gw_home .. "/gw/?.so"
                .. gw_home .. "/deps/lib/lua/5.1/?.so;"
    pkg_path  = gw_home .. "/lua/?.lua;"
                .. gw_home .. "/deps/share/lua/5.1/?.lua;;"
end
-- print("gw_home: ", gw_home)

package.cpath = pkg_cpath .. pkg_cpath_org
package.path  = pkg_path .. pkg_path_org

do
    -- skip luajit environment
    local ok = pcall(require, "table.new")
    if not ok then
        local ok, json = pcall(require, "cjson")
        if ok and json then
            io.stderr:write("please remove the cjson library in Lua, it may "
                            .. "conflict with the cjson library in openresty. "
                            .. "\n luarocks remove cjson\n")
            return
        end
    end
end

local yaml = require("tinyyaml")
local template = require("resty.template")

local ngx_tpl = [=[
# Configuration File - Nginx Server Configs
# This is a read-only file, do not try to modify it.

master_process on;
user root;

worker_processes {* worker_processes *};
{% if os_name == "Linux" then %}
worker_cpu_affinity auto;
{% end %}

error_log {* error_log *} {* error_log_level or "error" *};
pid logs/nginx.pid;

worker_rlimit_nofile {* worker_rlimit_nofile *};

events {
    accept_mutex off;
    worker_connections {* event.worker_connections *};
}

worker_rlimit_core  {* worker_rlimit_core *};
working_directory   /usr/local/gw/;

worker_shutdown_timeout 3;

http {
    lua_package_path  "$prefix/gw/?.lua;$prefix/deps/share/lua/5.1/?.lua;/usr/share/lua/5.1/gw/?.lua;]=]
                      .. [=[/usr/local/share/lua/5.1/gw/?.lua;]=]
                      .. [=[$prefix/deps/share/lua/5.1/gw/?.lua;]=]
                      .. [=[{*gw_lua_home*}/gw/?.lua;;{*lua_path*};";
    lua_package_cpath "$prefix/deps/lib64/lua/5.1/?.so;]=]
                      .. [=[$prefix/deps/lib/lua/5.1/?.so;;]=]
                      .. [=[{*lua_cpath*};";

    lua_shared_dict upstream-healthcheck 10m;
    lua_shared_dict worker-events        10m;
    lua_shared_dict cc_limit_req_store   10m;
    lua_shared_dict cc_limit_conn_store  10m;

    lua_ssl_verify_depth 5;
    ssl_session_timeout 86400;

    {% if http.underscores_in_headers then %}
    underscores_in_headers {* http.underscores_in_headers *};
    {%end%}

    lua_socket_log_errors off;

    resolver {% for _, dns_addr in ipairs(dns_resolver or {}) do %} {*dns_addr*} {% end %} ipv6=off;
    resolver_timeout 5;

    lua_http10_buffering off;

    lua_regex_match_limit 100000;
    lua_regex_cache_max_entries 8192;

    log_format main '$remote_addr - $remote_user [$time_local] $http_host "$request" $status $body_bytes_sent $request_time "$http_referer" "$http_user_agent" $upstream_addr $upstream_status $upstream_response_time';

    access_log {* http.access_log *} main buffer=32768 flush=3;
    open_file_cache  max=1000 inactive=60;
    client_max_body_size 0;
    keepalive_timeout {* http.keepalive_timeout *};
    client_header_timeout {* http.client_header_timeout *};
    client_body_timeout {* http.client_body_timeout *};
    send_timeout {* http.send_timeout *};

    server_tokens off;
    more_set_headers 'Server: gw web server';

    include mime.types;

    {% if http.real_ip_header then %}
    real_ip_header {* http.real_ip_header *};
    {% end %}

    {% if http.real_ip_from then %}
    real_ip_recursive on;
    {% for _, real_ip in ipairs(http.real_ip_from) do %}
    set_real_ip_from {*real_ip*};
    {% end %}
    {% end %}

    upstream gw_backend {
        server 0.0.0.1;
        balancer_by_lua_block {
            gw.http_balancer_phase()
        }

        keepalive 320;
    }

    init_by_lua_block {
        require "resty.core"
        gw = require("gw")
        gw.http_init()
    }

    init_worker_by_lua_block {
        gw.http_init_worker()
    }

    server {
        listen {* node_listen *} {% if enable_reuseport then %} reuseport {% end %};
        {% if ssl.enable then %}
        listen {* ssl.listen_port *} ssl {% if ssl.enable_http2 then %} http2 {% end %} {% if enable_reuseport then %} reuseport {% end %};
        {% end %}

        {% if proxy_protocol and proxy_protocol.listen_http_port then %}
        listen {* proxy_protocol.listen_http_port *} proxy_protocol;
        {% end %}
        {% if proxy_protocol and proxy_protocol.listen_https_port then %}
        listen {* proxy_protocol.listen_https_port *} ssl {% if ssl.enable_http2 then %} http2 {% end %} proxy_protocol;
        {% end %}

        {% if enable_ipv6 then %}
        listen [::]:{* node_listen *} {% if enable_reuseport then %} reuseport {% end %};
        {% if ssl.enable then %}
        listen [::]:{* node_ssl_listen *} ssl {% if ssl.enable_http2 then %} http2 {% end %} {% if enable_reuseport then %} reuseport {% end %};
        {% end %}
        {% end %} {% -- if enable_ipv6 %}

        ssl_certificate      cert/gw.crt;
        ssl_certificate_key  cert/gw.key;
        ssl_session_cache    shared:SSL:1m;

        ssl_protocols {* ssl.ssl_protocols *};
        ssl_ciphers {* ssl.ssl_ciphers *};
        ssl_prefer_server_ciphers on;

        {% if with_module_status then %}
        location = /gw/nginx_status {
            allow 127.0.0.0/24;
            deny all;
            access_log off;
            stub_status;
        }
        {% end %}

        ssl_certificate_by_lua_block {
            gw.http_ssl_phase()
        }

        location / {
            set $upstream_scheme             'http';
            set $upstream_host               $host;
            set $upstream_upgrade            '';
            set $upstream_connection         '';
            set $upstream_uri                '';

            access_by_lua_block {
                gw.http_access_phase()
            }

            proxy_http_version 1.1;
            proxy_set_header   Host              $upstream_host;
            proxy_set_header   Upgrade           $upstream_upgrade;
            proxy_set_header   Connection        $upstream_connection;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_pass_header  Server;
            proxy_pass_header  Date;

            set $var_x_forwarded_for        $remote_addr;
            set $var_x_forwarded_proto      $scheme;
            set $var_x_forwarded_host       $host;
            set $var_x_forwarded_port       $server_port;

            if ($http_x_forwarded_for != "") {
                set $var_x_forwarded_for "${http_x_forwarded_for}, ${realip_remote_addr}";
            }
            if ($http_x_forwarded_proto != "") {
                set $var_x_forwarded_proto $http_x_forwarded_proto;
            }
            if ($http_x_forwarded_host != "") {
                set $var_x_forwarded_host $http_x_forwarded_host;
            }
            if ($http_x_forwarded_port != "") {
                set $var_x_forwarded_port $http_x_forwarded_port;
            }

            proxy_set_header   X-Forwarded-For      $var_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto    $var_x_forwarded_proto;
            proxy_set_header   X-Forwarded-Host     $var_x_forwarded_host;
            proxy_set_header   X-Forwarded-Port     $var_x_forwarded_port;

            proxy_pass         $upstream_scheme://gw_backend$upstream_uri;

            header_filter_by_lua_block {
                gw.http_header_filter_phase()
            }

            body_filter_by_lua_block {
                gw.http_body_filter_phase()
            }

            log_by_lua_block {
                gw.http_log_phase()
            }
        }
    }
}
]=]

local function write_file(file_path, data)
    local file = io.open(file_path, "w+")
    if not file then
        return false, "failed to open file: " .. file_path
    end

    file:write(data)
    file:close()
    return true
end

local function read_file(file_path)
    local file = io.open(file_path, "rb")
    if not file then
        return false, "failed to open file: " .. file_path
    end

    local data = file:read("*all")
    file:close()
    return data
end

local function exec(command)
    local t= io.popen(command)
    local res = t:read("*all")
    t:close()
    return trim(res)
end

local function read_yaml_conf()
    local ymal_conf, err = read_file(gw_home .. "/etc/config.yaml")
    if not ymal_conf then
        return nil, err
    end

    return yaml.parse(ymal_conf)
end

local function get_openresty_version()
    local str = "nginx version: openresty/"
    local ret = excute_cmd("openresty -v 2>&1")
    local pos = string.find(ret,str)
    if pos then
        return string.sub(ret, pos + string.len(str))
    end

    str = "nginx version: nginx/"
    ret = excute_cmd("openresty -v 2>&1")
    pos = string.find(ret, str)
    if pos then
        return string.sub(ret, pos + string.len(str))
    end

    return nil
end

local function is_32bit_arch()
    local ok, ffi = pcall(require, "ffi")
    if ok then
        -- LuaJIT
        return ffi.abi("32bit")
    end
    local ret = excute_cmd("getconf LONG_BIT")
    local bits = tonumber(ret)
    return bits <= 32
end

local function split(self, sep)
    local sep, fields = sep or ":", {}
    local pattern = string.format("([^%s]+)", sep)
    self:gsub(pattern, function(c) fields[#fields + 1] = c end)
    return fields
 end

local function check_or_version(cur_ver_s, need_ver_s)
    local cur_vers = split(cur_ver_s, [[.]])
    local need_vers = split(need_ver_s, [[.]])
    local len = math.max(#cur_vers, #need_vers)

    for i = 1, len do
        local cur_ver = tonumber(cur_vers[i]) or 0
        local need_ver = tonumber(need_vers[i]) or 0
        if cur_ver > need_ver then
            return true
        end

        if cur_ver < need_ver then
            return false
        end
    end

    return true
end

local _M = {version = 0.1}

function _M.help()
    print([[
Usage: gw [action] <argument>

help:       show this message, then exit
init:       initialize the local nginx.conf
init_etcd:  initialize the data of etcd
start:      start the gw server
stop:       stop the gw server
restart:    restart the gw server
reload:     reload the gw server
version:    print the version of gw
]])
end

local function init()
    -- read_yaml_conf
    local yaml_conf, err = read_yaml_conf()
    if not yaml_conf then
        error("failed to read local yaml config of gw: " .. err)
    end
    -- print("etcd: ", yaml_conf.etcd.host)

    local or_ver = excute_cmd("openresty -V 2>&1")
    local with_module_status = true
    if or_ver and not or_ver:find("http_stub_status_module", 1, true) then
        io.stderr:write("'http_stub_status_module' module is missing in ",
                        "your openresty, please check it out. Without this ",
                        "module, there will be fewer monitoring indicators.\n")
        with_module_status = false
    end

    -- Using template.render
    local sys_conf = {
        lua_path = pkg_path_org,
        lua_cpath = pkg_cpath_org,
        os_name = exec("uname"),
        gw_lua_home = gw_home,
        with_module_status = with_module_status,
        node_ssl_listen = 9443,     -- default value
        error_log = {level = "warn"},
    }

    if not yaml_conf.gw then
        error("failed to read `gw` field from yaml file")
    end

    if not yaml_conf.nginx_config then
        error("failed to read `nginx_config` field from yaml file")
    end

    if is_32bit_arch() then
        sys_conf["worker_rlimit_core"] = "4G"
    else
        sys_conf["worker_rlimit_core"] = "16G"
    end

    for k,v in pairs(yaml_conf.gw) do
        sys_conf[k] = v
    end
    for k,v in pairs(yaml_conf.nginx_config) do
        sys_conf[k] = v
    end

    local wrn = sys_conf["worker_rlimit_nofile"]
    local wc = sys_conf["event"]["worker_connections"]
    if not wrn or wrn <= wc then
        -- ensure the number of fds is slightly larger than the number of conn
        sys_conf["worker_rlimit_nofile"] = wc + 128
    end

    if(sys_conf["enable_dev_mode"] == true) then
        sys_conf["worker_processes"] = 1
    else
        sys_conf["worker_processes"] = "auto"
    end

    local conf_render = template.compile(ngx_tpl)
    local ngxconf = conf_render(sys_conf)

    local ok, err = write_file(gw_home .. "/conf/nginx.conf", ngxconf)
    if not ok then
        error("failed to update nginx.conf: " .. err)
    end

    local op_ver = get_openresty_version()
    if op_ver == nil then
        io.stderr:write("can not find openresty\n")
        return
    end

    local need_ver = "1.15.8"
    if not check_or_version(op_ver, need_ver) then
        io.stderr:write("openresty version must >=", need_ver, " current ", op_ver, "\n")
        return
    end
end
_M.init = init

local function init_etcd(show_output)
    -- read_yaml_conf
    local yaml_conf, err = read_yaml_conf()
    if not yaml_conf then
        error("failed to read local yaml config of gw: " .. err)
    end

    if not yaml_conf.gw then
        error("failed to read `gw` field from yaml file when init etcd")
    end

    if yaml_conf.gw.config_center ~= "etcd" then
        return true
    end

    if not yaml_conf.etcd then
        error("failed to read `etcd` field from yaml file when init etcd")
    end

    local etcd_conf = yaml_conf.etcd
    local uri = etcd_conf.host .. "/v2/keys" .. (etcd_conf.prefix or "")

    local timeout = etcd_conf.timeout or 3

    for _, dir_name in ipairs({"/routes", "/upstreams", "/services",
                               "/plugins", "/consumers", "/node_status",
                               "/ssl", "/global_rules", "/stream_routes",
                               "/proto"}) do
        local cmd = "curl " .. uri .. dir_name
                    .. "?prev_exist=false -X PUT -d dir=true "
                    .. "--connect-timeout " .. timeout
                    .. " --max-time " .. timeout * 2 .. " --retry 1 2>&1"

        local res = exec(cmd)
        if not res:find("index", 1, true)
           and not res:find("createdIndex", 1, true) then
            error(cmd .. "\n" .. res)
        end

        if show_output then
            print(cmd)
            print(res)
        end
    end
end
_M.init_etcd = init_etcd

local openresty_args = [[openresty  -p ]] .. gw_home .. [[ -c ]]
                       .. gw_home .. [[/conf/nginx.conf]]

function _M.start(...)
    init(...)
    -- init_etcd(...)

    local cmd = openresty_args
    print(cmd)
    os.execute(cmd)
end

function _M.stop()
    local cmd = openresty_args .. [[ -s stop]]
    print(cmd)
    os.execute(cmd)
end

function _M.restart()
  _M.stop()
  _M.start()
end

function _M.reload()
    local test_cmd = openresty_args .. [[ -t -q ]]
    if os.execute((test_cmd)) ~= 0 then
        return
    end

    local cmd = openresty_args .. [[ -s reload]]
    -- print(cmd)
    os.execute(cmd)
end

function _M.version()
    local ver = require("gw.core.version")
    print(ver['VERSION'])
end

local cmd_action = arg[1]
if not cmd_action then
    return _M.help()
end

if not _M[cmd_action] then
    print("invalid argument: ", cmd_action, "\n")
    return
end

_M[cmd_action](arg[2])
