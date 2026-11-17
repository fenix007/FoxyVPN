package com.vauth.foxyvpn.vpn

import java.io.IOException
import java.net.SocketTimeoutException
import java.util.Timer
import java.util.TimerTask
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

data class LocationSpeedResult(val receivedBytes: Long, val elapsedMillis: Long) {
    val megabitsPerSecond: Double
        get() = receivedBytes * 8.0 / elapsedMillis.coerceAtLeast(1) / 1_000.0
}

/** A bounded download through the location's existing, authenticated core listener. */
object LocationSpeedTest {
    const val MAXIMUM_BYTES = 5_000_000L
    const val SAMPLE_MILLIS = 5_000L
    private const val REQUEST_MILLIS = 15_000L

    suspend fun measure(
        port: Int,
        username: String = "",
        password: String = "",
    ): LocationSpeedResult = withContext(Dispatchers.IO) {
        val client = localProxyClient(port, username, password, timeoutSeconds = REQUEST_MILLIS / 1_000)
        try {
            measure(client, "https://speed.cloudflare.com/__down?bytes=$MAXIMUM_BYTES&cachebust=${UUID.randomUUID()}")
        } finally {
            client.dispatcher.executorService.shutdown()
            client.connectionPool.evictAll()
        }
    }

    internal suspend fun measure(
        client: OkHttpClient,
        url: String,
        sampleMillis: Long = SAMPLE_MILLIS,
        requestMillis: Long = REQUEST_MILLIS,
    ): LocationSpeedResult = withContext(Dispatchers.IO) {
        val timer = Timer("location-speed-sample", true)
        try {
            suspendCancellableCoroutine { continuation ->
                val request = Request.Builder()
                    .url(url)
                    .header("Cache-Control", "no-cache, no-store")
                    .header("Accept-Encoding", "identity")
                    .build()
                val call = client.newCall(request)
                val requestStart = System.nanoTime()
                continuation.invokeOnCancellation { call.cancel(); timer.cancel() }
                call.enqueue(object : Callback {
                    override fun onFailure(call: Call, e: IOException) {
                        timer.cancel()
                        if (continuation.isActive) continuation.resumeWithException(timeoutError(e))
                    }

                    override fun onResponse(call: Call, response: Response) {
                        val sampleExpired = AtomicBoolean(false)
                        var received = 0L
                        var sampleStart = 0L
                        try {
                            response.use {
                                if (response.code != 200) throw IOException("Speed test failed: HTTP ${response.code}")
                                val encoding = response.header("Content-Encoding").orEmpty()
                                if (encoding.isNotEmpty() && !encoding.equals("identity", true))
                                    throw IOException("Speed test returned compressed data")
                                val body = response.body ?: throw IOException("Speed test returned no data")
                                val task = object : TimerTask() {
                                    override fun run() { sampleExpired.set(true); call.cancel() }
                                }
                                sampleStart = System.nanoTime()
                                timer.schedule(task, sampleMillis)
                                body.byteStream().use { input ->
                                    val buffer = ByteArray(64 * 1024)
                                    while (received < MAXIMUM_BYTES) {
                                        val count = input.read(buffer, 0, minOf(buffer.size.toLong(), MAXIMUM_BYTES - received).toInt())
                                        if (count < 0) throw IOException("Speed test download ended early")
                                        received += count
                                    }
                                }
                            }
                            if (continuation.isActive) continuation.resume(result(received, sampleStart))
                        } catch (error: Exception) {
                            val overallMillis = (System.nanoTime() - requestStart) / 1_000_000
                            if (continuation.isActive) {
                                if (sampleExpired.get() && received > 0 && overallMillis < requestMillis) {
                                    continuation.resume(result(received, sampleStart))
                                } else if (sampleExpired.get() && received == 0L) {
                                    continuation.resumeWithException(SocketTimeoutException("Speed test received no data"))
                                } else if (call.isCanceled() && overallMillis >= requestMillis) {
                                    continuation.resumeWithException(SocketTimeoutException("Speed test timed out").apply { initCause(error) })
                                } else continuation.resumeWithException(timeoutError(error))
                            }
                        } finally {
                            timer.cancel()
                        }
                    }
                })
            }
        } finally {
            timer.cancel()
        }
    }

    private fun result(received: Long, start: Long) =
        LocationSpeedResult(received, ((System.nanoTime() - start) / 1_000_000).coerceAtLeast(1))

    private fun timeoutError(error: Exception): Exception =
        if (error is java.io.InterruptedIOException && error !is SocketTimeoutException) {
            SocketTimeoutException("Speed test timed out").apply { initCause(error) }
        } else error
}
