package dev.kishorek.relay.ble

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Verifies [RelayEngine] against the shared vectors that also pin the Dart and
 * Swift implementations. A failure here means the three relay implementations
 * have diverged, which would show up in the field as messages that propagate on
 * one platform and vanish on another.
 *
 * Run with: ./gradlew :app:testDebugUnitTest
 */
class RelayVectorTest {

    private fun unhex(hex: String): ByteArray =
        ByteArray(hex.length / 2) {
            ((Character.digit(hex[it * 2], 16) shl 4) +
                Character.digit(hex[it * 2 + 1], 16)).toByte()
        }

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    private fun repoRoot(): File {
        var dir = File(System.getProperty("user.dir")!!)
        repeat(6) {
            if (File(dir, "testvectors").isDirectory) return dir
            dir = dir.parentFile ?: return@repeat
        }
        error("cannot locate testvectors/ from ${System.getProperty("user.dir")}")
    }

    private fun vectors(): JSONObject =
        JSONObject(File(repoRoot(), "testvectors/relay/decisions.json").readText())

    @Test
    fun `constants match the shared vector file`() {
        val root = vectors()
        assertEquals(root.getInt("suppressionThreshold"), Wire.SUPPRESSION_THRESHOLD)
        assertEquals(root.getLong("jitterMinMs"), Wire.JITTER_MIN_MS)
        assertEquals(root.getLong("jitterMaxMs"), Wire.JITTER_MAX_MS)
        assertEquals(root.getInt("dedupMaxEntries"), Wire.DEDUP_MAX_ENTRIES)
        assertEquals(root.getLong("dedupExpirySeconds") * 1000, Wire.DEDUP_EXPIRY_MS)
    }

    @Test
    fun `every relay decision matches the shared vectors`() {
        val root = vectors()
        val cases = root.getJSONArray("vectors")

        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val name = case.getString("name")
            val input = case.getJSONObject("input")
            val expect = case.getJSONObject("expect")
            val localHash = case.getInt("localHash")

            val now = 0L
            val dedup = DedupSet(clock = { now })
            val prior = case.getJSONArray("priorSeen")
            for (p in 0 until prior.length()) {
                val entry = prior.getJSONObject(p)
                dedup.addIfNew(
                    FrameKey(
                        unhex(entry.getString("msgId")),
                        entry.getString("fragmentIndex").toInt(),
                    )
                )
            }

            val engine = RelayEngine(
                localHash = localHash,
                clock = { now },
                jitter = { min, _ -> min },
                seen = dedup,
            )

            val encodedHex = input.getString("encodedHex")
            val frame = Frame.decode(unhex(encodedHex))
            assertNotNull("$name: frame failed to decode", frame)

            // Round-tripping proves the Kotlin codec agrees with Dart's.
            assertEquals("$name: re-encode mismatch", encodedHex, hex(frame!!.encode()))

            val decision = engine.receive(frame, input.getString("fromPeer"))

            assertEquals(
                "$name: deliverLocally",
                expect.getBoolean("deliverLocally"),
                decision.deliverLocally,
            )
            assertEquals(
                "$name: relay",
                expect.getBoolean("relay"),
                decision.relayFrame != null,
            )
            assertEquals(
                "$name: drop",
                if (expect.isNull("drop")) null else expect.getString("drop"),
                decision.drop?.name,
            )
            if (expect.has("relayTtl")) {
                assertEquals(
                    "$name: relayTtl",
                    expect.getInt("relayTtl"),
                    decision.relayFrame!!.ttl,
                )
            }
            if (decision.drop == null && expect.has("excludePeer")) {
                assertEquals(
                    "$name: excludePeer",
                    expect.getString("excludePeer"),
                    decision.excludePeer,
                )
            }
        }

        assertTrue("vector file must not be empty", cases.length() > 0)
    }
}
