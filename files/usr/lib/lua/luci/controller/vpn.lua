module("luci.controller.vpn", package.seeall)
function index()
    entry({"admin", "vpn"}, firstchild(), "VPN", 60).dependent = false
    entry({"admin", "vpn", "settings"}, cbi("vpn/settings"), "Settings", 1)
    entry({"admin", "vpn", "servers"},  cbi("vpn/servers"),  "Servers",  2)
    entry({"admin", "vpn", "status"},   call("action_status"), "Status", 3)
end

function action_status()
    local running = (os.execute("pgrep -f vpn-runner.sh >/dev/null 2>&1") == 0)
    luci.template.render("vpn/status", {running = running})
end
