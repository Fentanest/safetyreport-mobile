package com.fentanest.mysafetyreport

import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerCompatibilityTest {
    @Test fun refusalMessagesIdentifyTheProductToUpdate() {
        assertEquals("PC 서버를 v3 이상으로 업데이트하세요.", ServerVersionCompatibility.upgradeMessage("SERVER_UPGRADE_REQUIRED"))
        assertEquals("모바일 앱을 최신 버전으로 업데이트하세요.", ServerVersionCompatibility.upgradeMessage("CLIENT_UPGRADE_REQUIRED"))
        assertTrue(ServerVersionCompatibility.upgradeMessage("CLIENT_PROTOCOL_UNSUPPORTED").contains("protocol 3"))
    }
    @Test fun canonicalServerVectors() {
        val file = listOf(File("../../contracts/selfhost-compat/vectors.json"), File("contracts/selfhost-compat/vectors.json"), File("../contracts/selfhost-compat/vectors.json"))
            .first { it.exists() }
        val cases = JSONObject(file.readText()).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val row = cases.getJSONObject(i)
            assertEquals(row.getString("name"), row.optString("code") != "SERVER_UPGRADE_REQUIRED",
                ServerVersionCompatibility.supports(row.getString("server")))
        }
    }
    @Test fun protocolMetadataIsRequired() {
        assertTrue(ServerVersionCompatibility.supportsPayload(JSONObject("""{"version":"3.0.0.0-dev","protocol_version":3,"supported_client_protocols":[3]}""")))
        for (body in listOf(
            """{"version":"3.0.0.0"}""",
            """{"version":"2.9.0","protocol_version":3,"supported_client_protocols":[3]}""",
            """{"version":"3.0.0.0","protocol_version":2,"supported_client_protocols":[3]}""",
            """{"version":"3.0.0.0","protocol_version":3,"supported_client_protocols":[2]}""",
            """{"version":"3.0.0.0","protocol_version":"3","supported_client_protocols":[3]}"""
        )) assertFalse(ServerVersionCompatibility.supportsPayload(JSONObject(body)))
    }
    @Test fun headersKeepTheActualMobileProductVersion() {
        ServerContract.productVersion="2.0.0+31"
        assertEquals(mapOf("X-API-Key" to "fixture", "X-SafetyReport-Client" to "mobile",
            "X-SafetyReport-Version" to "2.0.0+31", "X-SafetyReport-Protocol" to "3"), ServerContract.headers("fixture"))
    }


    private class TcpFixture : java.io.Closeable {
        private val listener = java.net.ServerSocket(0, 10, java.net.InetAddress.getByName("127.0.0.1"))
        private val workers = java.util.concurrent.Executors.newFixedThreadPool(2)
        val base = "http://127.0.0.1:${listener.localPort}"
        @Volatile var respond: (String) -> Pair<Int, ByteArray> = { 500 to byteArrayOf() }
        private val acceptor = Thread {
            while (!listener.isClosed) {
                try {
                    val socket = listener.accept()
                    workers.execute {
                        socket.use {
                            it.soTimeout = 4000
                            val input = it.getInputStream().bufferedReader()
                            check(input.readLine().contains(ServerContract.SERVER_VERSION_PATH))
                            var key = ""
                            var line = input.readLine()
                            while (!line.isNullOrEmpty()) {
                                if (line.startsWith("X-API-Key:", ignoreCase = true)) key = line.substringAfter(':').trim()
                                line = input.readLine()
                            }
                            val (status, body) = respond(key)
                            try {
                                val output = it.getOutputStream()
                                output.write("HTTP/1.1 $status Fixture\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                                output.write(body); output.flush()
                            } catch (_: java.io.IOException) { /* bounded reader may abort */ }
                        }
                    }
                } catch (_: java.net.SocketException) { if (!listener.isClosed) throw IllegalStateException("fixture socket failed") }
            }
        }.apply { isDaemon = true; start() }
        override fun close() { listener.close(); workers.shutdownNow(); acceptor.join(1000) }
    }

    private fun withServer(body: (String, TcpFixture) -> Unit) {
        ServerVersionCompatibility.reset()
        TcpFixture().use { server ->
            try { body(server.base, server) }
            finally { ServerVersionCompatibility.reset() }
        }
    }

    private val supportedBody = """{"version":"3.0.0.0","protocol_version":3,"supported_client_protocols":[3]}""".toByteArray()

    @Test fun blockedKeyDoesNotBlockAReplacementKeyOnTheSameServer() = withServer { base, server ->
        server.respond = { 200 to supportedBody }
        ServerVersionCompatibility.block(base, "old-key")
        val old = ServerVersionCompatibility.probe(base, "old-key")
        val current = ServerVersionCompatibility.probe(base, "replacement-key")
        assertEquals(ServerVersionCompatibility.Failure.INCOMPATIBLE, old.failure)
        assertTrue(current.accepted)
        assertFalse(old.accepted)
    }

    @Test fun concurrentProbesReturnTheirOwnFailureAndSuccess() = withServer { base, server ->
        val entered = java.util.concurrent.CountDownLatch(2)
        server.respond = { key ->
            entered.countDown()
            check(entered.await(3, java.util.concurrent.TimeUnit.SECONDS))
            if (key == "good-key") 200 to supportedBody
            else 409 to """{"code":"CLIENT_PROTOCOL_UNSUPPORTED"}""".toByteArray()
        }
        val workers = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val good = workers.submit<ServerVersionCompatibility.Probe> { ServerVersionCompatibility.probe(base, "good-key") }
            val bad = workers.submit<ServerVersionCompatibility.Probe> { ServerVersionCompatibility.probe(base, "bad-key") }
            assertTrue(good.get(5, java.util.concurrent.TimeUnit.SECONDS).accepted)
            assertEquals(ServerVersionCompatibility.Failure.INCOMPATIBLE, bad.get(5, java.util.concurrent.TimeUnit.SECONDS).failure)
            assertTrue(good.get().accepted)
        } finally { workers.shutdownNow() }
    }

    @Test fun versionBodyLimitCountsUtf8BytesRatherThanCharacters() = withServer { base, server ->
        server.respond = { 200 to JSONObject().put("version", "3.0.0.0").put("protocol_version",3)
            .put("supported_client_protocols",org.json.JSONArray().put(3)).put("padding","한".repeat(400_000)).toString().toByteArray(Charsets.UTF_8) }
        assertEquals(ServerVersionCompatibility.Failure.NETWORK, ServerVersionCompatibility.probe(base,"fixture-key").failure)
    }
}
