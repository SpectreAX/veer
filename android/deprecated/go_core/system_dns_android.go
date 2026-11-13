//go:build android && cmfa

package veercore

import "github.com/metacubex/mihomo/dns"

func applySystemDNS(servers []string) {
	dns.UpdateSystemDNS(servers)
}
