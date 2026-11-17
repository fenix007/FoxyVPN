package com.vauth.foxyvpn.vpn

import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LocationSpeedTestTest {
    @Test fun convertsBytesToMegabitsPerSecond() {
        assertEquals(4.0, LocationSpeedResult(1_000_000, 2_000).megabitsPerSecond, 0.00001)
    }

    @Test fun capsDownloadsAtFiveMegabytes() = runBlocking {
        LocalServer { socket ->
            headers(socket, LocationSpeedTest.MAXIMUM_BYTES + 100_000)
            val chunk = ByteArray(64 * 1024)
            repeat(80) { socket.getOutputStream().write(chunk) }
        }.use { server ->
            withClient { client ->
                val result = LocationSpeedTest.measure(client, server.url)
                assertEquals(LocationSpeedTest.MAXIMUM_BYTES, result.receivedBytes)
                assertTrue(result.elapsedMillis > 0)
                assertTrue(result.megabitsPerSecond.isFinite())
            }
        }
    }

    @Test fun rejectsEmptyAndTruncatedBodies() = runBlocking {
        for (length in listOf(0L, 100_000L)) {
            LocalServer { socket ->
                headers(socket, length)
                if (length > 0) socket.getOutputStream().write(ByteArray(1024))
            }.use { server ->
                withClient { client -> expectFailure<IOException> { LocationSpeedTest.measure(client, server.url) } }
            }
        }
    }

    @Test fun rejectsHttpErrorsAndCompressedResponses() = runBlocking {
        for (status in listOf("403 Forbidden", "302 Found", "200 OK")) {
            LocalServer { socket ->
                headers(socket, 0, status, if (status == "200 OK") "Content-Encoding: gzip\r\n" else "")
            }.use { server ->
                withClient { client -> expectFailure<IOException> { LocationSpeedTest.measure(client, server.url) } }
            }
        }
    }

    @Test fun reportsACompletedTimedSample() = runBlocking {
        LocalServer { socket ->
            headers(socket, LocationSpeedTest.MAXIMUM_BYTES)
            socket.getOutputStream().write(ByteArray(8192))
            socket.getOutputStream().flush()
            Thread.sleep(10_000)
        }.use { server ->
            withClient { client ->
                val result = LocationSpeedTest.measure(client, server.url, sampleMillis = 100)
                assertEquals(8192L, result.receivedBytes)
                assertTrue(result.elapsedMillis >= 50)
            }
        }
    }

    @Test fun failsWhenSamplingReceivesNoData() = runBlocking {
        LocalServer { socket -> headers(socket, LocationSpeedTest.MAXIMUM_BYTES); Thread.sleep(10_000) }.use { server ->
            withClient { client ->
                expectFailure<SocketTimeoutException> { LocationSpeedTest.measure(client, server.url, sampleMillis = 100) }
            }
        }
    }

    @Test fun doesNotTreatNetworkResetAsSuccessfulSample() = runBlocking {
        LocalServer { socket ->
            headers(socket, LocationSpeedTest.MAXIMUM_BYTES)
            socket.getOutputStream().write(ByteArray(8192))
            socket.getOutputStream().flush()
            socket.setSoLinger(true, 0)
        }.use { server ->
            withClient { client -> expectFailure<IOException> { LocationSpeedTest.measure(client, server.url) } }
        }
    }

    @Test fun cancellationInterruptsAnActiveDownload() = runBlocking {
        val bodySent = CountDownLatch(1)
        LocalServer { socket ->
            headers(socket, LocationSpeedTest.MAXIMUM_BYTES)
            socket.getOutputStream().write(ByteArray(8192))
            socket.getOutputStream().flush()
            bodySent.countDown()
            Thread.sleep(10_000)
        }.use { server ->
            withClient { client ->
                val download = async(Dispatchers.IO) { LocationSpeedTest.measure(client, server.url) }
                assertTrue(withContext(Dispatchers.IO) { bodySent.await(2, TimeUnit.SECONDS) })
                download.cancelAndJoin()
                assertTrue(download.isCancelled)
            }
        }
    }

    @Test fun overallTimeoutAfterDataIsAnError() = runBlocking {
        LocalServer { socket ->
            headers(socket, LocationSpeedTest.MAXIMUM_BYTES)
            socket.getOutputStream().write(ByteArray(8192))
            socket.getOutputStream().flush()
            Thread.sleep(10_000)
        }.use { server ->
            withClient(timeoutMillis = 100) { client ->
                expectFailure<SocketTimeoutException> {
                    LocationSpeedTest.measure(client, server.url, sampleMillis = 2_000, requestMillis = 100)
                }
            }
        }
    }

    @Test fun usesExplicitLoopbackProxyWithoutDirectFallback() = runBlocking {
        LocalServer { socket -> headers(socket, 0, "403 Forbidden") }.use { server ->
            expectFailure<IOException> { LocationSpeedTest.measure(server.port) }
            assertTrue(server.requestHeader.get().orEmpty().startsWith("CONNECT speed.cloudflare.com:443 HTTP/1.1\r\n"))
        }
    }

    private suspend inline fun <reified T : Exception> expectFailure(crossinline block: suspend () -> Unit) {
        try { block() } catch (error: Exception) {
            if (error is T) return
            throw error
        }
        throw AssertionError("Expected ${T::class.simpleName}")
    }

    private suspend fun withClient(timeoutMillis: Long = 3_000, block: suspend (OkHttpClient) -> Unit) {
        val client = OkHttpClient.Builder()
            .followRedirects(false)
            .retryOnConnectionFailure(false)
            .callTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
            .build()
        try { block(client) } finally {
            client.connectionPool.evictAll()
            client.dispatcher.executorService.shutdown()
        }
    }

    private fun headers(socket: Socket, length: Long, status: String = "200 OK", extra: String = "") {
        socket.getOutputStream().write(
            "HTTP/1.1 $status\r\nContent-Length: $length\r\nConnection: close\r\n$extra\r\n".toByteArray(Charsets.US_ASCII)
        )
        socket.getOutputStream().flush()
    }

    private class LocalServer(private val respond: (Socket) -> Unit) : Closeable {
        private val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        private val connection = AtomicReference<Socket?>()
        val requestHeader = AtomicReference<String?>()
        val port = listener.localPort
        val url = "http://127.0.0.1:${listener.localPort}/download"
        private val worker = Thread {
            try {
                listener.accept().use { socket ->
                    connection.set(socket)
                    socket.soTimeout = 3_000
                    var header = ""
                    while (!header.endsWith("\r\n\r\n") && header.length < 16_384) {
                        val byte = socket.getInputStream().read()
                        if (byte < 0) throw IOException("Request ended before headers")
                        header += byte.toChar()
                    }
                    requestHeader.set(header)
                    respond(socket)
                }
            } catch (_: SocketException) {
                // The measurement intentionally closes at its byte/time limit.
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            } catch (_: IOException) {
                // Closing a fixture during cancellation interrupts its socket.
            }
        }.apply { isDaemon = true; start() }

        override fun close() {
            connection.get()?.close()
            listener.close()
            worker.interrupt()
            worker.join(1_000)
        }
    }
}
