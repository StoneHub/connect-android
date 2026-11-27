package com.monroestone.connectandroid

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DebugStateTest {

    @Test
    fun shouldReportDeveloperOptionsOff_beforeAnythingElse() {
        assertEquals(
            DebugState.DeveloperOptionsOff,
            DebugState.from(canWriteSecureSettings = false, developerOptionsOn = false, wirelessDebuggingOn = true, endpoint = null),
        )
    }

    @Test
    fun shouldShowOn_evenWithoutPermission_whenTurnedOnInSettings() {
        val endpoint = Endpoint("100.118.229.7", 40763)
        assertEquals(
            DebugState.On(endpoint),
            DebugState.from(canWriteSecureSettings = false, developerOptionsOn = true, wirelessDebuggingOn = true, endpoint = endpoint),
        )
    }

    @Test
    fun shouldNeedPermission_whenOffAndNotGranted() {
        assertEquals(
            DebugState.NeedsPermission,
            DebugState.from(canWriteSecureSettings = false, developerOptionsOn = true, wirelessDebuggingOn = false, endpoint = null),
        )
    }

    @Test
    fun shouldBeOff_whenGrantedAndOff() {
        assertEquals(
            DebugState.Off,
            DebugState.from(canWriteSecureSettings = true, developerOptionsOn = true, wirelessDebuggingOn = false, endpoint = null),
        )
    }

    @Test
    fun shouldBuildConnectCommand() {
        assertEquals("adb connect 192.168.50.239:37001", Endpoint("192.168.50.239", 37001).connectCommand)
    }

    @Test
    fun shouldPreferTailscaleAddress_overWifi() {
        assertEquals(
            Endpoint("100.118.229.7", 41000),
            EndpointChooser.choose(listOf("192.168.50.239", "100.118.229.7"), 41000),
        )
    }

    @Test
    fun shouldFallBackToPrivateLan_whenNoTailscale() {
        assertEquals(
            Endpoint("192.168.50.239", 41000),
            EndpointChooser.choose(listOf("192.0.0.4", "192.168.50.239"), 41000),
        )
    }

    @Test
    fun shouldReturnNull_whenPortMissingOrInvalid() {
        assertNull(EndpointChooser.choose(listOf("192.168.50.239"), null))
        assertNull(EndpointChooser.choose(listOf("192.168.50.239"), 0))
        assertNull(EndpointChooser.choose(emptyList(), 41000))
    }

    @Test
    fun shouldRecognizeTailscaleRange() {
        assertTrue(EndpointChooser.isTailscale("100.64.0.1"))
        assertTrue(EndpointChooser.isTailscale("100.127.255.254"))
        assertFalse(EndpointChooser.isTailscale("100.128.0.1"))
        assertFalse(EndpointChooser.isTailscale("10.0.0.1"))
        assertFalse(EndpointChooser.isTailscale("not.an.ip.addr"))
    }
}
