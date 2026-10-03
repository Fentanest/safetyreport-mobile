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
}
