package com.yamax.veer.core_mihomo.ipc;

import android.os.Bundle;

/** Explicit same-UID IPC contract for the independent :veercore process. */
interface IVeercoreControl {
    Bundle call(String method, in Bundle extras);
}
