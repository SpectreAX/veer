// C API of the in-process Mihomo core (ios/core). Built by ios/scripts/build-mihomo-ios.sh.
// Prototype only: this links GPL-3.0 Mihomo into the app; never distribute a build with it.
//
// Strings are UTF-8. Every non-NULL char* returned is malloc'd; release it with VeerCoreFree.
// Calls are serialised inside the core; call them off the main thread (Start waits up to ~5 s
// for the external-controller, Stop up to ~3 s for it to close).
#ifndef MIHOMO_CORE_H
#define MIHOMO_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Sets the Mihomo home dir and config path (both absolute), parses the config file and applies
// it: listeners and the external-controller (address and secret from the YAML) start in-process.
// Returns once the controller answers. NULL on success, else an error message.
// TUN is always forced off. Fails if the core is already running.
char *VeerCoreStart(const char *homeDir, const char *configPath);

// Closes connections, listeners, DNS server and the controller. Start may be called again.
// No-op when not running.
void VeerCoreStop(void);

// Switches the running core's mode ("rule", "global" or "direct"). NULL on success.
// (The embedded controller has no PUT/PATCH /configs.)
char *VeerCoreSetMode(const char *mode);
// Re-reads the config file and applies it like PUT /configs, keeping unchanged listeners.
// The external-controller address must stay the same. NULL on success, else the error.
char *VeerCoreReload(const char *configPath);
// Parses a config without applying it (equivalent of `mihomo -t`).
// NULL when it parses, else the error message.
char *VeerCoreValidate(const char *yaml);

// Mihomo version this core was built from, e.g. "v1.19.29".
char *VeerCoreVersion(void);

void VeerCoreFree(char *p);

#ifdef __cplusplus
}
#endif

#endif
