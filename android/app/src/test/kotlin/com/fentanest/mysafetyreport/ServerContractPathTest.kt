package com.fentanest.mysafetyreport

import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE)
class ServerContractPathTest {
    @Test fun websocketKeepsRestDeploymentPath() {
        for (base in listOf(
            "http://localhost:8080",
            "https://localhost/safetyreport",
            " https://localhost/safetyreport/nested/// ",
            "https://localhost/%ED%95%9C%EA%B8%80/a%2Fb",
            "https://[::1]:8443/safetyreport",
        )) {
            val expected = Uri.parse(ServerContract.apiUrl(base, ServerContract.WS_EVENTS_PATH))
            val actual = Uri.parse(ServerContract.wsEventsUrl(base, "local-path-check"))
            assertEquals(expected.encodedPath, actual.encodedPath)
            assertEquals(expected.host, actual.host)
            assertEquals(expected.port, actual.port)
            assertEquals(if (expected.scheme == "https") "wss" else "ws", actual.scheme)
            assertEquals("local-path-check", actual.getQueryParameter("api_key"))
            assertEquals(ServerContract.TAXONOMY_VERSION, actual.getQueryParameter("taxonomy"))
        }
    }
}
