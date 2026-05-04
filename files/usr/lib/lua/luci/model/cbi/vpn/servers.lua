m = Map("vpn", "VPN Servers")

m.on_after_commit = function()
    os.execute("/etc/init.d/vpn restart >/dev/null 2>&1 &")
end

s = m:section(TypedSection, "server", "VLESS Servers")
s.addremove = true
s.anonymous = false
s.template  = "cbi/tblsection"

s:option(Value, "alias",  "Name")
s:option(Flag,  "active", "Active")
s:option(Value, "server", "Server")
s:option(Value, "port",   "Port")
s:option(Value, "uuid",   "UUID")

t = s:option(ListValue, "transport", "Transport")
t:value("xhttp", "XHTTP / Split-HTTP")
t:value("tcp",   "TCP + XTLS-Vision")
t.default = "xhttp"

s:option(Value, "sni", "SNI")
s:option(Value, "pbk", "Public Key")
s:option(Value, "sid", "Short ID")

return m
