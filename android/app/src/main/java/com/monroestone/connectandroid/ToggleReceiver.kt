package com.monroestone.connectandroid

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Not exported: only this app's widget can toggle wireless debugging. */
class ToggleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Surfaces.toggle(context) { pending.finish() }
    }
}
