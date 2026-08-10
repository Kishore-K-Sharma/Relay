package dev.kishorek.relay.ble

import android.content.Context
import java.io.File
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Durable native storage for frames.
 *
 * Two queues with hard bounds:
 *
 *  - **inbox** — frames addressed to this device that arrived while the Dart
 *    isolate was not running. Drained on next app launch.
 *  - **store-and-forward** — frames held for peers that were unreachable when
 *    they passed through.
 *
 * The bounds are mandatory rather than defensive: without them any nearby
 * device can fill the disk by transmitting continuously to a phone whose app is
 * never opened.
 *
 * Backed by a simple length-prefixed append file rather than a database: it is
 * written from the BLE callback thread on every frame, and the durability
 * requirement is only "survive process death", not "survive power loss".
 */
class PacketStore(context: Context) {

    private val lock = ReentrantLock()
    private val inboxFile = File(context.filesDir, "relay_inbox.bin")
    private val forwardFile = File(context.filesDir, "relay_forward.bin")

    companion object {
        const val MAX_INBOX_FRAMES = 2000
        const val MAX_INBOX_BYTES = 4 * 1024 * 1024
        const val MAX_FORWARD_FRAMES = 500
        const val MAX_FORWARD_BYTES = 4 * 1024 * 1024
        const val FORWARD_EXPIRY_MS = 24L * 60 * 60 * 1000
    }

    data class Held(val frame: ByteArray, val storedAtMs: Long, val targetHash: Int) {
        override fun equals(other: Any?): Boolean =
            other is Held && frame.contentEquals(other.frame) &&
                storedAtMs == other.storedAtMs && targetHash == other.targetHash

        override fun hashCode(): Int =
            31 * (31 * frame.contentHashCode() + storedAtMs.hashCode()) + targetHash
    }

    // ------------------------------------------------------------------ inbox

    fun appendInbox(frame: ByteArray) = lock.withLock {
        val existing = readAll(inboxFile)
        existing.add(Held(frame, System.currentTimeMillis(), 0))
        writeAll(inboxFile, trim(existing, MAX_INBOX_FRAMES, MAX_INBOX_BYTES))
    }

    /** Returns everything held and clears the queue atomically. */
    fun drainInbox(): List<ByteArray> = lock.withLock {
        val all = readAll(inboxFile)
        inboxFile.delete()
        all.map { it.frame }
    }

    fun inboxDepth(): Int = lock.withLock { readAll(inboxFile).size }

    // ------------------------------------------------------- store and forward

    fun hold(frame: ByteArray, targetHash: Int) = lock.withLock {
        val existing = readAll(forwardFile)
        existing.add(Held(frame, System.currentTimeMillis(), targetHash))
        writeAll(forwardFile, trim(expire(existing), MAX_FORWARD_FRAMES, MAX_FORWARD_BYTES))
    }

    /**
     * Removes and returns frames held for [targetHash]. Called when that peer
     * becomes reachable, so held traffic goes out before anything new.
     */
    fun takeFor(targetHash: Int): List<ByteArray> = lock.withLock {
        val all = expire(readAll(forwardFile))
        val (matching, rest) = all.partition { it.targetHash == targetHash }
        writeAll(forwardFile, rest.toMutableList())
        matching.map { it.frame }
    }

    fun forwardDepth(): Int = lock.withLock { expire(readAll(forwardFile)).size }

    fun wipe() = lock.withLock {
        inboxFile.delete()
        forwardFile.delete()
        Unit
    }

    // ----------------------------------------------------------------- private

    private fun expire(items: MutableList<Held>): MutableList<Held> {
        val cutoff = System.currentTimeMillis() - FORWARD_EXPIRY_MS
        items.removeAll { it.storedAtMs <= cutoff }
        return items
    }

    private fun trim(items: MutableList<Held>, maxFrames: Int, maxBytes: Int): MutableList<Held> {
        while (items.size > maxFrames) items.removeAt(0)
        var total = items.sumOf { it.frame.size }
        while (total > maxBytes && items.isNotEmpty()) {
            total -= items.removeAt(0).frame.size
        }
        return items
    }

    private fun readAll(file: File): MutableList<Held> {
        if (!file.exists()) return mutableListOf()
        val out = mutableListOf<Held>()
        try {
            file.inputStream().buffered().use { input ->
                val header = ByteArray(16)
                while (input.read(header) == 16) {
                    val length = readInt(header, 0)
                    val target = readInt(header, 4)
                    val stored = readLong(header, 8)
                    if (length <= 0 || length > MAX_INBOX_BYTES) break
                    val frame = ByteArray(length)
                    if (input.read(frame) != length) break
                    out.add(Held(frame, stored, target))
                }
            }
        } catch (_: Exception) {
            // A truncated or corrupt store must never prevent the mesh from
            // running. Whatever parsed is kept; the rest is discarded.
        }
        return out
    }

    private fun writeAll(file: File, items: MutableList<Held>) {
        if (items.isEmpty()) { file.delete(); return }
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.outputStream().buffered().use { output ->
            for (item in items) {
                val header = ByteArray(16)
                writeInt(header, 0, item.frame.size)
                writeInt(header, 4, item.targetHash)
                writeLong(header, 8, item.storedAtMs)
                output.write(header)
                output.write(item.frame)
            }
        }
        temp.renameTo(file)
    }

    private fun readInt(b: ByteArray, o: Int) =
        (b[o].toInt() and 0xFF shl 24) or (b[o + 1].toInt() and 0xFF shl 16) or
            (b[o + 2].toInt() and 0xFF shl 8) or (b[o + 3].toInt() and 0xFF)

    private fun writeInt(b: ByteArray, o: Int, v: Int) {
        b[o] = (v ushr 24).toByte(); b[o + 1] = (v ushr 16).toByte()
        b[o + 2] = (v ushr 8).toByte(); b[o + 3] = v.toByte()
    }

    private fun readLong(b: ByteArray, o: Int): Long {
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (b[o + i].toLong() and 0xFF)
        return v
    }

    private fun writeLong(b: ByteArray, o: Int, v: Long) {
        for (i in 0 until 8) b[o + i] = (v ushr (56 - i * 8)).toByte()
    }
}
