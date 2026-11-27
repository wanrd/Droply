package com.droply.android

import android.app.Application
import com.droply.android.transfer.DroplyClient

class DroplyApplication : Application() {
    val client: DroplyClient by lazy {
        DroplyClient().also { it.bindApplicationContext(this) }
    }
}
