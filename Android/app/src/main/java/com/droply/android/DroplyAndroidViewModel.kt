package com.droply.android

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.droply.android.transfer.DroplyClient

class DroplyAndroidViewModel(application: Application) : AndroidViewModel(application) {
    val client: DroplyClient = (application as DroplyApplication).client
}
