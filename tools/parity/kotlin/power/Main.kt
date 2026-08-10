import java.io.File
import dev.kishorek.relay.ble.PowerModes

/**
 * Verifies PowerPolicy.kt against the shared power contract.
 *
 *   kotlinc app/android/app/src/main/kotlin/dev/kishorek/relay/ble/PowerModes.kt \
 *           tools/parity/kotlin/power/Main.kt -include-runtime -d power_kt.jar
 *   java -jar power_kt.jar testvectors/power/modes.json
 *
 * Only the cross-platform numbers are checked. The scan and advertise
 * constants are Android enums with no counterpart elsewhere; the battery
 * figure is printed on screen in Settings, so a drift between it and the duty
 * cycle native actually runs is the app misquoting its own cost.
 *
 * Exits non-zero on any mismatch so CI can gate on it.
 */

/** Minimal JSON reader. Adding a dependency to a CI-only harness is not worth it. */
private fun numberField(source: String, key: String, from: Int): Pair<Double, Int>? {
    val marker = "\"$key\""
    val at = source.indexOf(marker, from)
    if (at < 0) return null
    var i = source.indexOf(':', at) + 1
    while (i < source.length && source[i].isWhitespace()) i++
    val start = i
    while (i < source.length && (source[i].isDigit() || source[i] == '.' || source[i] == '-')) i++
    return source.substring(start, i).toDouble() to i
}

private fun stringField(source: String, key: String, from: Int): Pair<String, Int>? {
    val marker = "\"$key\""
    val at = source.indexOf(marker, from)
    if (at < 0) return null
    val open = source.indexOf('"', source.indexOf(':', at) + 1)
    val close = source.indexOf('"', open + 1)
    return source.substring(open + 1, close) to close
}

fun main(args: Array<String>) {
    val path = args.firstOrNull() ?: "testvectors/power/modes.json"
    val source = File(path).readText()

    // Skip the leading comment block, which also contains the word "name".
    var cursor = source.indexOf("\"modes\"")
    if (cursor < 0) {
        System.err.println("no modes array in $path")
        kotlin.system.exitProcess(2)
    }

    val failures = mutableListOf<String>()
    var checked = 0

    while (true) {
        val (name, afterName) = stringField(source, "name", cursor) ?: break
        val (drain, afterDrain) =
            numberField(source, "estimatedDrainPercentPerHour", afterName) ?: break
        val (interval, afterInterval) =
            numberField(source, "announceIntervalMs", afterDrain) ?: break
        cursor = afterInterval
        checked++

        val actualDrain = PowerModes.estimatedDrainPercentPerHour(name)
        val actualInterval = PowerModes.announceIntervalMs(name)

        if (actualDrain != drain) {
            failures += "$name drain: got $actualDrain, want $drain"
        }
        if (actualInterval != interval.toLong()) {
            failures += "$name announce: got $actualInterval, want ${interval.toLong()}"
        }

        // An unknown mode name falls through to the balanced branch in every
        // `when`, so a typo would silently give balanced behaviour under
        // another label. Comparing against balanced catches that.
        if (name != PowerModes.BALANCED &&
            actualDrain == PowerModes.estimatedDrainPercentPerHour(PowerModes.BALANCED)
        ) {
            failures += "$name is indistinguishable from balanced — unknown mode name?"
        }
    }

    if (checked == 0) {
        System.err.println("no modes parsed from $path")
        kotlin.system.exitProcess(2)
    }

    if (failures.isEmpty()) {
        println("power parity: $checked/$checked modes passed")
    } else {
        failures.forEach { System.err.println("FAIL $it") }
        kotlin.system.exitProcess(1)
    }
}
