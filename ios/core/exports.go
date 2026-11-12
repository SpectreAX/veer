package main

/*
#include <stdlib.h>
*/
import "C"

import "unsafe"

// C API, declared for Swift in include/MihomoCore.h. Strings are UTF-8. Every non-NULL char*
// returned here is malloc'd and must be released with VeerCoreFree.

//export VeerCoreStart
func VeerCoreStart(homeDir *C.char, configPath *C.char) *C.char {
	return errString(start(goString(homeDir), goString(configPath)))
}

//export VeerCoreStop
func VeerCoreStop() {
	stop()
}

//export VeerCoreSetMode
func VeerCoreSetMode(mode *C.char) *C.char {
	return errString(setMode(goString(mode)))
}

//export VeerCoreReload
func VeerCoreReload(configPath *C.char) *C.char {
	return errString(reload(goString(configPath)))
}

//export VeerCoreValidate
func VeerCoreValidate(yaml *C.char) *C.char {
	if yaml == nil {
		return C.CString("configuration is empty")
	}
	return errString(validate([]byte(C.GoString(yaml))))
}

//export VeerCoreVersion
func VeerCoreVersion() *C.char {
	return C.CString(coreVersion())
}

//export VeerCoreFree
func VeerCoreFree(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

func goString(p *C.char) string {
	if p == nil {
		return ""
	}
	return C.GoString(p)
}

func errString(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

// Required by -buildmode=c-archive; never called.
func main() {}
