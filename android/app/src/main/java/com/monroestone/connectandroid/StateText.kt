package com.monroestone.connectandroid

import android.content.Context

/** Human-readable labels for [DebugState], shared by the tile, widget, and setup screen. */
class StateText(private val context: Context) {

    fun short(state: DebugState): String = when (state) {
        DebugState.NeedsPermission -> context.getString(R.string.state_needs_permission)
        DebugState.DeveloperOptionsOff -> context.getString(R.string.state_dev_options_off)
        DebugState.Off -> context.getString(R.string.state_off)
        is DebugState.On -> state.endpoint?.let { context.getString(R.string.state_on_port, it.port) }
            ?: context.getString(R.string.state_on)
    }

    fun detail(state: DebugState): String = when (state) {
        is DebugState.On -> state.endpoint?.address ?: context.getString(R.string.state_on_finding_port)
        else -> short(state)
    }
}
