package com.monroestone.connectandroid

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class WirelessDebuggingTileService : TileService() {

    private var listening = false

    override fun onStartListening() {
        super.onStartListening()
        listening = true
        val debugging = WirelessDebugging(this)
        val finder = PortFinder(this)
        render(debugging.state(finder.cachedEndpoint()))
        if (debugging.isOn()) {
            finder.findAsync { endpoint -> if (listening) render(debugging.state(endpoint)) }
        }
    }

    override fun onStopListening() {
        listening = false
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        val debugging = WirelessDebugging(this)
        when (debugging.state(null)) {
            DebugState.NeedsPermission, DebugState.DeveloperOptionsOff -> openSetup()
            else -> {
                qsTile?.apply {
                    state = Tile.STATE_UNAVAILABLE
                    updateTile()
                }
                Surfaces.toggle(this) {
                    if (listening) render(debugging.state(PortFinder(this).cachedEndpoint()))
                }
            }
        }
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openSetup() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun render(state: DebugState) {
        val tile = qsTile ?: return
        val text = StateText(this)
        tile.state = if (state.isOn) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_label)
        tile.subtitle = text.short(state)
        tile.stateDescription = text.short(state)
        tile.icon = Icon.createWithResource(
            this,
            if (state is DebugState.NeedsPermission || state is DebugState.DeveloperOptionsOff) {
                R.drawable.ic_adb_locked
            } else {
                R.drawable.ic_adb_wifi
            },
        )
        tile.updateTile()
    }
}
