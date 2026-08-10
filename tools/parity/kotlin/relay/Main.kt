// Standalone parity runner for RelayEngine.kt.
//
//   kotlinc app/android/app/src/main/kotlin/dev/kishorek/relay/ble/RelayEngine.kt \
//           tools/parity/kotlin/relay/Main.kt -include-runtime -d /tmp/relay.jar
//   java -jar /tmp/relay.jar testvectors/relay/decisions.json
//
// It reads the same JSON the Dart and Swift runners read, so all three
// implementations are pinned to one file. A tiny JSON reader is inlined rather
// than pulling a dependency, because this must run with nothing but kotlinc.

import java.io.File
import dev.kishorek.relay.ble.DedupSet
import dev.kishorek.relay.ble.Frame
import dev.kishorek.relay.ble.FrameKey
import dev.kishorek.relay.ble.RelayEngine
import dev.kishorek.relay.ble.Wire

// ----------------------------------------------------------------- minimal JSON

sealed class Json {
    data class Obj(val fields: Map<String, Json>) : Json()
    data class Arr(val items: List<Json>) : Json()
    data class Str(val value: String) : Json()
    data class Num(val value: Double) : Json()
    data class Bool(val value: Boolean) : Json()
    object Null : Json()

    operator fun get(key: String): Json? = (this as? Obj)?.fields?.get(key)
    val asString: String get() = (this as Str).value
    val asInt: Int get() = (this as Num).value.toInt()
    val asLong: Long get() = (this as Num).value.toLong()
    val asBool: Boolean get() = (this as Bool).value
    val asList: List<Json> get() = (this as Arr).items
    val isNull: Boolean get() = this is Null
}

class JsonReader(private val src: String) {
    private var pos = 0

    fun parse(): Json { skip(); return value() }

    private fun skip() { while (pos < src.length && src[pos].isWhitespace()) pos++ }

    private fun value(): Json {
        skip()
        return when (src[pos]) {
            '{' -> obj()
            '[' -> arr()
            '"' -> Json.Str(string())
            't' -> { pos += 4; Json.Bool(true) }
            'f' -> { pos += 5; Json.Bool(false) }
            'n' -> { pos += 4; Json.Null }
            else -> number()
        }
    }

    private fun obj(): Json {
        val out = LinkedHashMap<String, Json>()
        pos++ // {
        skip()
        if (src[pos] == '}') { pos++; return Json.Obj(out) }
        while (true) {
            skip()
            val key = string()
            skip(); pos++ // :
            out[key] = value()
            skip()
            if (src[pos] == ',') { pos++ } else { pos++; break }
        }
        return Json.Obj(out)
    }

    private fun arr(): Json {
        val out = ArrayList<Json>()
        pos++ // [
        skip()
        if (src[pos] == ']') { pos++; return Json.Arr(out) }
        while (true) {
            out.add(value())
            skip()
            if (src[pos] == ',') { pos++ } else { pos++; break }
        }
        return Json.Arr(out)
    }

    private fun string(): String {
        val sb = StringBuilder()
        pos++ // "
        while (src[pos] != '"') {
            if (src[pos] == '\\') {
                pos++
                when (src[pos]) {
                    'n' -> sb.append('\n'); 't' -> sb.append('\t')
                    'r' -> sb.append('\r'); 'b' -> sb.append('\b')
                    'u' -> { sb.append(src.substring(pos + 1, pos + 5).toInt(16).toChar()); pos += 4 }
                    else -> sb.append(src[pos])
                }
            } else {
                sb.append(src[pos])
            }
            pos++
        }
        pos++
        return sb.toString()
    }

    private fun number(): Json {
        val start = pos
        while (pos < src.length && (src[pos].isDigit() || src[pos] in "-+.eE")) pos++
        return Json.Num(src.substring(start, pos).toDouble())
    }
}

// ------------------------------------------------------------------- helpers

fun unhex(hex: String): ByteArray =
    ByteArray(hex.length / 2) {
        ((Character.digit(hex[it * 2], 16) shl 4) + Character.digit(hex[it * 2 + 1], 16)).toByte()
    }

fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

// ---------------------------------------------------------------------- main

fun main(args: Array<String>) {
    val path = if (args.isNotEmpty()) args[0] else "testvectors/relay/decisions.json"
    val root = JsonReader(File(path).readText()).parse()
    val failures = ArrayList<String>()

    fun constant(name: String, actual: Long, expected: Json?) {
        if (expected == null) return
        if (actual != expected.asLong) {
            failures.add("constant $name: kotlin=$actual vectors=${expected.asLong}")
        }
    }

    constant("suppressionThreshold", Wire.SUPPRESSION_THRESHOLD.toLong(), root["suppressionThreshold"])
    constant("jitterMinMs", Wire.JITTER_MIN_MS, root["jitterMinMs"])
    constant("jitterMaxMs", Wire.JITTER_MAX_MS, root["jitterMaxMs"])
    constant("dedupMaxEntries", Wire.DEDUP_MAX_ENTRIES.toLong(), root["dedupMaxEntries"])
    constant("dedupExpirySeconds", Wire.DEDUP_EXPIRY_MS / 1000, root["dedupExpirySeconds"])

    val cases = root["vectors"]!!.asList
    var passed = 0

    for (case in cases) {
        val name = case["name"]!!.asString
        try {
            val localHash = case["localHash"]!!.asInt
            val input = case["input"]!!
            val expect = case["expect"]!!
            val now = 0L

            val dedup = DedupSet(clock = { now })
            for (prior in case["priorSeen"]!!.asList) {
                dedup.addIfNew(
                    FrameKey(
                        unhex(prior["msgId"]!!.asString),
                        prior["fragmentIndex"]!!.asString.toInt(),
                    )
                )
            }

            val engine = RelayEngine(
                localHash = localHash,
                clock = { now },
                jitter = { min, _ -> min },
                seen = dedup,
            )

            val encodedHex = input["encodedHex"]!!.asString
            val frame = Frame.decode(unhex(encodedHex))
                ?: throw AssertionError("frame failed to decode")

            // Round-trip proves the Kotlin codec agrees with Dart's.
            check(hex(frame.encode()) == encodedHex) {
                "re-encode mismatch\n  expected $encodedHex\n  actual   ${hex(frame.encode())}"
            }

            val decision = engine.receive(frame, input["fromPeer"]!!.asString)

            check(decision.deliverLocally == expect["deliverLocally"]!!.asBool) {
                "deliverLocally: got ${decision.deliverLocally}"
            }
            check((decision.relayFrame != null) == expect["relay"]!!.asBool) {
                "relay: got ${decision.relayFrame != null}"
            }
            val expectedDrop = expect["drop"]!!.let { if (it.isNull) null else it.asString }
            check(decision.drop?.name == expectedDrop) {
                "drop: got ${decision.drop?.name}, want $expectedDrop"
            }
            expect["relayTtl"]?.let {
                check(decision.relayFrame!!.ttl == it.asInt) {
                    "relayTtl: got ${decision.relayFrame!!.ttl}, want ${it.asInt}"
                }
            }
            if (decision.drop == null) {
                expect["excludePeer"]?.let {
                    check(decision.excludePeer == it.asString) { "excludePeer mismatch" }
                }
            }

            passed++
        } catch (e: Throwable) {
            failures.add("$name: ${e.message}")
        }
    }

    if (failures.isEmpty()) {
        println("relay parity: $passed/${cases.size} vectors passed")
    } else {
        failures.forEach { println("FAIL $it") }
        println("relay parity: $passed/${cases.size} passed, ${failures.size} failures")
        kotlin.system.exitProcess(1)
    }
}
