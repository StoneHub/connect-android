package com.monroestone.connectandroid

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context

/**
 * One-shot content-trigger job on the wireless-debugging setting. It wakes the
 * app only when the setting changes (from Settings, the tile, or Android
 * itself), refreshes the widget and tile, and schedules itself again.
 */
class AdbSettingWatcher : JobService() {

    override fun onStartJob(params: JobParameters): Boolean {
        if (!WirelessDebugging(this).isOn()) {
            PortFinder(this).clearCache()
            KeepAlive.onDebuggingTurnedOff(this)
        }
        Surfaces.refreshAll(this)
        if (Surfaces.widgetIds(this).isNotEmpty() || KeepAlive.isOn(this)) schedule(this)
        return false
    }

    override fun onStopJob(params: JobParameters): Boolean = false

    companion object {
        private const val JOB_ID = 7_301

        fun schedule(context: Context) {
            val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, AdbSettingWatcher::class.java))
                .addTriggerContentUri(JobInfo.TriggerContentUri(WirelessDebugging.enabledUri, 0))
                .setTriggerContentUpdateDelay(0)
                .setTriggerContentMaxDelay(1_000)
                .build()
            runCatching { scheduler.schedule(job) }
        }

        fun cancel(context: Context) {
            context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
        }
    }
}
