m = Map("vpn", "VPN Settings")

local ucicursor = require("luci.model.uci").cursor()

m.on_after_commit = function(self)
    -- When a server is selected from dropdown, set its active=1, all others active=0
    local chosen = ucicursor:get("vpn", "settings", "active_server") or ""
    if chosen ~= "" then
        ucicursor:foreach("vpn", "server", function(sec)
            ucicursor:set("vpn", sec[".name"], "active",
                sec[".name"] == chosen and "1" or "0")
        end)
        ucicursor:commit("vpn")
    end
    os.execute("/etc/init.d/vpn restart >/dev/null 2>&1 &")
end

s = m:section(NamedSection, "settings", "vpn", "Control")
local en = s:option(Flag, "enabled", "Enable VPN")
en.rmempty = false  -- always write 0/1, never delete the option

sub = s:option(Value, "subscription_url", "Subscription URL")
sub.placeholder = "vless://... or https://..."
sub.description = "Paste a vless:// key or subscription URL. Save to refresh the server list."

-- Dynamic dropdown: populated from all server sections in UCI
local srv = s:option(ListValue, "active_server", "Active Server")
srv:value("", "-- not selected --")
ucicursor:foreach("vpn", "server", function(sec)
    srv:value(sec[".name"], sec.alias or sec[".name"])
end)
-- Pre-select whichever server currently has active=1
ucicursor:foreach("vpn", "server", function(sec)
    if sec.active == "1" then
        srv.default = sec[".name"]
    end
end)
srv.description = "Choose the server to use. List updates after saving a subscription URL."

return m
