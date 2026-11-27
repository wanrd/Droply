package com.droply.android

import com.droply.android.transfer.DroplyClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundTransferStateTest {

    @Test
    fun backgroundServiceOnlyStopsWhenDisconnectedAndIdle() {
        val client = DroplyClient()
        // Disconnected and idle should not hold a notification when no connection or transfer is active.
        assertFalse(client.shouldKeepServiceRunning())
        assertTrue(client.requireIncomingConfirmation.value)

        client.setDeviceName("Pixel 9")
        client.setRequireIncomingConfirmation(false)
        assertEquals("Pixel 9", client.deviceName.value)
        assertFalse(client.requireIncomingConfirmation.value)

        client.shutdown()
    }
}
