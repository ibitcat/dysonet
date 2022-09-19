-- http gate service

local skynet = require "skynet"
local socket = require "skynet.socket"
local crypt = require "skynet.crypt"
local protobuf = require "protobuf"
local urllib = require "http.url"
local httpd = require "http.httpd"
local sockethelper = require "http.sockethelper"

local watchdog
local gateIp
local gatePort
local gateNode
local gateAddr
local gates = {}

local balance = 1
local function accept(fd, addr)
    -- 负载均衡
    local gate = gates[balance]
    skynet.send(gate, "lua", "connect", fd, addr)
    balance = balance + 1
    if balance > #gates then
        balance = 1
    end
end

local function response(id, write, ...)
    local ok, err = httpd.write_response(write, ...)
    if not ok then
        -- if err == sockethelper.socket_error , that means socket closed.
        skynet.error(string.format("fd = %d, %s", id, err))
    end
end

local LUA = {}
function LUA.open(conf)
    gateIp = conf.ip or "::"
    gatePort = conf.port
    watchdog = conf.watchdog
    gateNode = skynet.getenv("name")
    gateAddr = skynet.self()

    if not conf.isSlave then
        table.insert(gates, skynet.self())
        local id = assert(socket.listen(gateIp, gatePort))
        skynet.error(string.format("Listen http gate at %s:%s", gateIp, gatePort))

        -- slave gates
        conf.isSlave = true
        local slaveNum = conf.slaveNum or 0
        for i = 1, slaveNum, 1 do
            local slaveGate = skynet.newservice("gate_http")
            skynet.call(slaveGate, "lua", "open", conf)
            table.insert(gates, slaveGate)
        end

        socket.start(id, function(fd, addr)
            skynet.error(string.format("%s accept as %d", addr, fd))
            accept(fd, addr)
        end)
    end
    skynet.retpack()
end

function LUA.connect(fd, addr)
    socket.start(fd)

    -- limit request body size to 8192 (you can pass nil to unlimit)
    local readfunc = sockethelper.readfunc(fd)
    local writefunc =  sockethelper.writefunc(fd)
    local code, url, method, header, body = httpd.read_request(readfunc, 8192)
    if code then
        if code ~= 200 then
            response(fd, writefunc, code)
        else
            local query
            local path, querystr = urllib.parse(url)
            if querystr then
                query = urllib.parse_query(querystr)
            end

            local linkobj = {
                gateNode = gateNode,
                gateAddr = gateAddr,
                fd = fd,
                addr = addr,
                realIp = header["x-real-ip"] -- for nginx
            }
            local repcode, repbody, repheader = skynet.call(watchdog, "lua", "Http", "onMessage", linkobj, path, method
                , query, header, body)
            -- fd,writefunc,code, bodyfunc, header
            response(fd, writefunc, repcode, repbody, repheader)
        end
    else
        if url == sockethelper.socket_error then
            skynet.error("socket closed")
        else
            skynet.error(url)
        end
    end
    socket.close(fd)
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local func = LUA[cmd]
        func(...)
    end)
end)
