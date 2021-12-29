package = "gw"
version = "0.1-1"
supported_platforms = {"linux"}

source = {
    url = "git://github.com/jixindatech/shenshu-gw",
}

description = {
    summary = "shenshu gateway.",
    homepage = "https://github.com/jixindatech/shenshu-gw",
    maintainer = "Fangang Cheng <chengfangang@qq.com>"
}

dependencies = {
    "luarocks-fetch-gitrec",
    "lua-resty-template = 1.9",
    "lua-tinyyaml = 1.0",
    "luafilesystem = 1.7.0-2",
    "lua-resty-radixtree = 1.7",
    "lua-resty-lrucache = 0.09-2",
    "lua-resty-balancer = 0.02rc5",
    "lua-resty-healthcheck = 2.0.0",
    "lua-resty-logger-socket = 2.0",
    "lua-resty-kafka = 0.09",
    "jsonschema = 0.9.5",
    "nxx-lua-resty-cookie = 0.2.0-1",
    "lua-resty-upload = 0.09-2",
    "lua-resty-ipmatcher = 0.6.1-0",
    "lua-typeof = 0.1-0",
    "lua-ffi-libinjection = 1.0-2",
    "lua-resty-jit-uuid = 0.0.7-2",
}

build = {
    type = "make",
    build_variables = {
        CFLAGS="$(CFLAGS)",
        LIBFLAG="$(LIBFLAG)",
        LUA_LIBDIR="$(LUA_LIBDIR)",
        LUA_BINDIR="$(LUA_BINDIR)",
        LUA_INCDIR="$(LUA_INCDIR)",
        LUA="$(LUA)",
    },
    install_variables = {
        INST_PREFIX="$(PREFIX)",
        INST_BINDIR="$(BINDIR)",
        INST_LIBDIR="$(LIBDIR)",
        INST_LUADIR="$(LUADIR)",
        INST_CONFDIR="$(CONFDIR)",
    },
}
