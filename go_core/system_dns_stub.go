//go:build !android || !cmfa

package veercore

// Host tests do not use Mihomo's Android-only system resolver.
func applySystemDNS([]string) {}
