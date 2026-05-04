m = Map("vpn", "VPN Settings")

m.on_after_commit = function()
    os.execute("/etc/init.d/vpn restart >/dev/null 2>&1 &")
end

s = m:section(NamedSection, "settings", "vpn", "Control")
local en = s:option(Flag, "enabled", "Enable VPN")
en.rmempty = false  -- always write 0/1, never delete the option
sub = s:option(Value, "subscription_url", "Subscription URL")
sub.placeholder = "vless://... or https://..."
sub.description = "Paste a vless:// key or subscription URL"

return m
