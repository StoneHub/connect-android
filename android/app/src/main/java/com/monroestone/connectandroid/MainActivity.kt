package com.monroestone.connectandroid

import android.app.StatusBarManager
import android.appwidget.AppWidgetManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Typeface
import android.database.ContentObserver
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import com.google.android.material.materialswitch.MaterialSwitch

class MainActivity : AppCompatActivity() {

    private lateinit var debugging: WirelessDebugging
    private lateinit var finder: PortFinder
    private lateinit var text: StateText

    private lateinit var stateTitle: TextView
    private lateinit var stateDetail: TextView
    private lateinit var toggleButton: Button
    private lateinit var copyButton: Button
    private lateinit var permissionCard: View
    private lateinit var grantCommand: TextView
    private lateinit var devOptionsCard: View
    private lateinit var keepAliveSwitch: MaterialSwitch
    private lateinit var noExpirySwitch: MaterialSwitch
    private lateinit var addStatus: TextView

    private var endpoint: Endpoint? = null

    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) = refresh(lookUpPort = true)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.enableEdgeToEdge(window)
        setContentView(R.layout.activity_main)
        val night = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = !night
            isAppearanceLightNavigationBars = !night
        }
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.content)) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            view.updatePadding(left = bars.left, top = bars.top, right = bars.right, bottom = bars.bottom)
            insets
        }
        debugging = WirelessDebugging(this)
        finder = PortFinder(this)
        text = StateText(this)

        stateTitle = findViewById(R.id.stateTitle)
        stateDetail = findViewById(R.id.stateDetail)
        toggleButton = findViewById(R.id.toggleButton)
        copyButton = findViewById(R.id.copyButton)
        permissionCard = findViewById(R.id.permissionCard)
        grantCommand = findViewById(R.id.grantCommand)
        devOptionsCard = findViewById(R.id.devOptionsCard)
        keepAliveSwitch = findViewById(R.id.keepAliveSwitch)
        noExpirySwitch = findViewById(R.id.noExpirySwitch)
        addStatus = findViewById(R.id.addStatus)

        grantCommand.text = WirelessDebugging.grantCommand(packageName)
        findViewById<Button>(R.id.copyGrantButton).setOnClickListener {
            copy(getString(R.string.clip_grant_label), grantCommand.text.toString())
        }
        findViewById<Button>(R.id.devOptionsButton).setOnClickListener {
            runCatching { startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)) }
        }
        toggleButton.setOnClickListener {
            toggleButton.isEnabled = false
            Surfaces.toggle(this) { refresh(lookUpPort = false) }
            refresh(lookUpPort = false)
        }
        copyButton.setOnClickListener {
            endpoint?.let { copy(getString(R.string.clip_connect_label), it.connectCommand) }
        }
        keepAliveSwitch.setOnCheckedChangeListener { button, checked ->
            if (button.isPressed) {
                KeepAlive.setOn(this, checked)
                refresh(lookUpPort = true)
            }
        }
        noExpirySwitch.setOnCheckedChangeListener { button, checked ->
            if (button.isPressed && !debugging.setPairingsExpire(!checked)) refresh(lookUpPort = false)
        }
        findViewById<Button>(R.id.addTileButton).setOnClickListener { requestTile() }
        findViewById<Button>(R.id.addWidgetButton).setOnClickListener { requestWidget() }
    }

    override fun onResume() {
        super.onResume()
        contentResolver.registerContentObserver(WirelessDebugging.enabledUri, false, observer)
        refresh(lookUpPort = true)
        Surfaces.refreshAll(this)
    }

    override fun onPause() {
        contentResolver.unregisterContentObserver(observer)
        super.onPause()
    }

    private fun refresh(lookUpPort: Boolean) {
        endpoint = if (debugging.isOn()) finder.cachedEndpoint() else null
        render(debugging.state(endpoint))
        if (lookUpPort && debugging.isOn()) {
            finder.findAsync { found ->
                if (isDestroyed) return@findAsync
                endpoint = found
                render(debugging.state(found))
            }
        }
    }

    private fun render(state: DebugState) {
        val canWrite = debugging.canWriteSecureSettings()
        stateTitle.text = getString(
            when (state) {
                is DebugState.On -> R.string.main_state_on
                DebugState.Off -> R.string.main_state_off
                DebugState.NeedsPermission -> R.string.main_state_off
                DebugState.DeveloperOptionsOff -> R.string.main_state_dev_off
            },
        )
        stateDetail.text = when (state) {
            is DebugState.On -> state.endpoint?.connectCommand ?: getString(R.string.state_on_finding_port)
            DebugState.Off -> getString(R.string.main_detail_off)
            DebugState.NeedsPermission -> getString(R.string.main_detail_needs_permission)
            DebugState.DeveloperOptionsOff -> getString(R.string.main_detail_dev_off)
        }
        stateDetail.typeface = if ((state as? DebugState.On)?.endpoint != null) Typeface.MONOSPACE else Typeface.DEFAULT
        toggleButton.isEnabled = canWrite && state != DebugState.DeveloperOptionsOff
        toggleButton.text = getString(if (state.isOn) R.string.action_turn_off else R.string.action_turn_on)
        copyButton.visibility = if ((state as? DebugState.On)?.endpoint != null) View.VISIBLE else View.GONE
        permissionCard.visibility = if (canWrite) View.GONE else View.VISIBLE
        devOptionsCard.visibility = if (state == DebugState.DeveloperOptionsOff) View.VISIBLE else View.GONE
        keepAliveSwitch.isEnabled = canWrite
        keepAliveSwitch.isChecked = KeepAlive.isOn(this)
        noExpirySwitch.isEnabled = canWrite
        noExpirySwitch.isChecked = !debugging.pairingsExpire()
    }

    private fun copy(label: String, value: String) {
        getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText(label, value))
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            Toast.makeText(this, R.string.copied, Toast.LENGTH_SHORT).show()
        }
    }

    private fun requestTile() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            addStatus.setText(R.string.add_tile_manual)
            return
        }
        runCatching {
            getSystemService(StatusBarManager::class.java).requestAddTileService(
                ComponentName(this, WirelessDebuggingTileService::class.java),
                getString(R.string.tile_label),
                Icon.createWithResource(this, R.drawable.ic_adb_wifi),
                mainExecutor,
            ) { addStatus.setText(R.string.add_tile_done) }
        }.onFailure { addStatus.setText(R.string.add_tile_manual) }
    }

    private fun requestWidget() {
        val manager = AppWidgetManager.getInstance(this)
        val requested = manager.isRequestPinAppWidgetSupported && runCatching {
            manager.requestPinAppWidget(ComponentName(this, DebugWidgetProvider::class.java), null, null)
        }.getOrDefault(false)
        addStatus.setText(if (requested) R.string.add_widget_sent else R.string.add_widget_manual)
    }
}
