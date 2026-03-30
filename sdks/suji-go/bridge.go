package suji

/*
#include <stdlib.h>
*/
import "C"
import "unsafe"

//export goEventBridge
func goEventBridge(event *C.char, data *C.char, arg unsafe.Pointer) {
	id := uint64(uintptr(arg))
	goListenerMu.RLock()
	cb, ok := goListeners[id]
	goListenerMu.RUnlock()
	if ok {
		cb(C.GoString(event), C.GoString(data))
	}
}
