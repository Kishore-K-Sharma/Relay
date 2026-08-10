package dev.kishorek.relay.ble

/**
 * Wire protocol constants. These MUST match `core_protocol` in Dart and
 * `RelayEngine.swift`. The shared vectors in `testvectors/` are the contract.
 */
object Wire {
    const val PROTOCOL_VERSION: Byte = 0x01
    const val HEADER_LENGTH = 20
    const val MAX_TTL = 7
    const val BROADCAST_HASH = 0
    const val FRAGMENT_HEADER_LENGTH = 5
    const val DEDUP_MAX_ENTRIES = 2000
    const val DEDUP_EXPIRY_MS = 600_000L
    const val JITTER_MIN_MS = 20L
    const val JITTER_MAX_MS = 150L
    const val SUPPRESSION_THRESHOLD = 2
    const val WITNESS_EXPIRY_MS = 30_000L
}

enum class FrameType(val wire: Int) {
    ANNOUNCE(0x01),
    HANDSHAKE(0x02),
    MESSAGE(0x03),
    ACK(0x04),
    FRAGMENT(0x05),
    ROOM(0x06),
    VOICE(0x07),
    LEAVE(0x08),

    // Room catch-up and owner claims. Unknown types are dropped rather than
    // relayed, so every type Dart can emit has to be listed here or it stops
    // dead at the first Android hop.
    HISTORY_REQUEST(0x09),
    HISTORY_REPLY(0x0A),
    ROOM_CONTROL(0x0B),
    BATCH(0x0C),

    // Somebody else's mail, handed over in person. Always arrives with ttl 1,
    // so it is recognised here and then dropped by the ordinary ttl rule
    // rather than by a special case.
    COURIER(0x0D);

    companion object {
        fun fromWire(value: Int): FrameType? = entries.firstOrNull { it.wire == value }
    }
}

data class FrameFlags(
    val encrypted: Boolean = false,
    val fragmented: Boolean = false,
    val compressed: Boolean = false,
    val urgent: Boolean = false,
) {
    fun toByte(): Int =
        (if (encrypted) 0x01 else 0) or
            (if (fragmented) 0x02 else 0) or
            (if (compressed) 0x04 else 0) or
            (if (urgent) 0x08 else 0)

    companion object {
        fun fromByte(b: Int) = FrameFlags(
            encrypted = b and 0x01 != 0,
            fragmented = b and 0x02 != 0,
            compressed = b and 0x04 != 0,
            urgent = b and 0x08 != 0,
        )
    }
}

/**
 * One frame on the wire. The relay reads only the header; [payload] stays
 * opaque and is never decrypted here.
 */
data class Frame(
    val version: Int,
    val type: FrameType,
    val ttl: Int,
    val flags: FrameFlags,
    val msgId: ByteArray,
    val srcHash: Int,
    val dstHash: Int,
    val payload: ByteArray,
) {
    val isBroadcast: Boolean get() = dstHash == Wire.BROADCAST_HASH

    fun withDecrementedTtl(): Frame = copy(ttl = ttl - 1)

    fun encode(): ByteArray {
        val out = ByteArray(Wire.HEADER_LENGTH + payload.size)
        out[0] = version.toByte()
        out[1] = type.wire.toByte()
        out[2] = ttl.toByte()
        out[3] = flags.toByte().toByte()
        msgId.copyInto(out, 4)
        writeU32(out, 12, srcHash)
        writeU32(out, 16, dstHash)
        payload.copyInto(out, Wire.HEADER_LENGTH)
        return out
    }

    // ByteArray fields force explicit equals/hashCode.
    override fun equals(other: Any?): Boolean =
        other is Frame && version == other.version && type == other.type &&
            ttl == other.ttl && flags == other.flags &&
            msgId.contentEquals(other.msgId) && srcHash == other.srcHash &&
            dstHash == other.dstHash && payload.contentEquals(other.payload)

    override fun hashCode(): Int {
        var result = version
        result = 31 * result + type.hashCode()
        result = 31 * result + ttl
        result = 31 * result + flags.hashCode()
        result = 31 * result + msgId.contentHashCode()
        result = 31 * result + srcHash
        result = 31 * result + dstHash
        result = 31 * result + payload.contentHashCode()
        return result
    }

    companion object {
        private fun writeU32(out: ByteArray, offset: Int, value: Int) {
            out[offset] = (value ushr 24 and 0xFF).toByte()
            out[offset + 1] = (value ushr 16 and 0xFF).toByte()
            out[offset + 2] = (value ushr 8 and 0xFF).toByte()
            out[offset + 3] = (value and 0xFF).toByte()
        }

        private fun readU32(bytes: ByteArray, offset: Int): Int =
            (bytes[offset].toInt() and 0xFF shl 24) or
                (bytes[offset + 1].toInt() and 0xFF shl 16) or
                (bytes[offset + 2].toInt() and 0xFF shl 8) or
                (bytes[offset + 3].toInt() and 0xFF)

        /** Returns null for anything malformed; callers drop such frames. */
        fun decode(bytes: ByteArray): Frame? {
            if (bytes.size < Wire.HEADER_LENGTH) return null
            if (bytes[0] != Wire.PROTOCOL_VERSION) return null
            val type = FrameType.fromWire(bytes[1].toInt() and 0xFF) ?: return null
            val ttl = bytes[2].toInt() and 0xFF
            if (ttl > Wire.MAX_TTL) return null

            return Frame(
                version = bytes[0].toInt() and 0xFF,
                type = type,
                ttl = ttl,
                flags = FrameFlags.fromByte(bytes[3].toInt() and 0xFF),
                msgId = bytes.copyOfRange(4, 12),
                srcHash = readU32(bytes, 12),
                dstHash = readU32(bytes, 16),
                payload = bytes.copyOfRange(Wire.HEADER_LENGTH, bytes.size),
            )
        }
    }
}

/**
 * Deduplication key.
 *
 * Keying on `msgId` alone is wrong: all fragments of one message share a
 * `msgId` by design, so a msgId-only table drops every fragment after the
 * first and no multi-fragment message ever crosses a relay.
 */
class FrameKey(val msgId: ByteArray, val fragmentIndex: Int) {
    override fun equals(other: Any?): Boolean =
        other is FrameKey && fragmentIndex == other.fragmentIndex &&
            msgId.contentEquals(other.msgId)

    override fun hashCode(): Int = 31 * msgId.contentHashCode() + fragmentIndex

    companion object {
        fun of(frame: Frame): FrameKey {
            if (!frame.flags.fragmented || frame.payload.size < Wire.FRAGMENT_HEADER_LENGTH) {
                return FrameKey(frame.msgId, -1)
            }
            val index = (frame.payload[0].toInt() and 0xFF shl 8) or
                (frame.payload[1].toInt() and 0xFF)
            val total = (frame.payload[2].toInt() and 0xFF shl 8) or
                (frame.payload[3].toInt() and 0xFF)
            val valid = total != 0 && index < total
            return FrameKey(frame.msgId, if (valid) index else -1)
        }
    }
}

enum class RelayDrop { duplicate, ownFrame, hopLimitReached }

data class RelayDecision(
    val deliverLocally: Boolean = false,
    val relayFrame: Frame? = null,
    val jitterMs: Long = 0,
    val excludePeer: String? = null,
    val drop: RelayDrop? = null,
)

/**
 * Bounded, expiring set of frame keys.
 *
 * A repeated key deliberately does not refresh its position, or a peer
 * flooding one id could pin the table and evict everything else.
 */
class DedupSet(
    private val maxEntries: Int = Wire.DEDUP_MAX_ENTRIES,
    private val expiryMs: Long = Wire.DEDUP_EXPIRY_MS,
    private val clock: () -> Long,
) {
    private val entries = LinkedHashMap<FrameKey, Long>()

    val size: Int get() { sweep(); return entries.size }

    fun contains(key: FrameKey): Boolean { sweep(); return entries.containsKey(key) }

    fun addIfNew(key: FrameKey): Boolean {
        sweep()
        if (entries.containsKey(key)) return false
        entries[key] = clock()
        while (entries.size > maxEntries) {
            entries.remove(entries.keys.first())
        }
        return true
    }

    fun clear() = entries.clear()

    private fun sweep() {
        val cutoff = clock() - expiryMs
        val iterator = entries.entries.iterator()
        while (iterator.hasNext()) {
            if (iterator.next().value <= cutoff) iterator.remove() else break
        }
    }
}

/**
 * Native relay. Mirrors `RelayEngine` in Dart and Swift exactly; all three are
 * pinned by `testvectors/relay/decisions.json`.
 *
 * Runs inside the foreground service even when the Flutter engine is not
 * alive, which is the whole reason it exists in native code. It never
 * decrypts a payload.
 */
class RelayEngine(
    private val localHash: Int,
    private val clock: () -> Long,
    private val jitter: (Long, Long) -> Long = { min, max ->
        min + (Math.random() * (max - min + 1)).toLong()
    },
    private val seen: DedupSet = DedupSet(clock = clock),
) {
    private val witnesses = HashMap<FrameKey, MutableMap<String, Long>>()

    var relayedCount = 0
        private set
    var droppedCount = 0
        private set

    fun receive(frame: Frame, fromPeer: String): RelayDecision {
        sweepWitnesses()

        if (frame.srcHash == localHash) {
            droppedCount++
            return RelayDecision(drop = RelayDrop.ownFrame)
        }

        val key = FrameKey.of(frame)

        if (!seen.addIfNew(key)) {
            recordWitness(key, fromPeer)
            droppedCount++
            return RelayDecision(drop = RelayDrop.duplicate)
        }
        recordWitness(key, fromPeer)

        val isForUs = frame.dstHash == localHash
        val deliverLocally = isForUs || frame.isBroadcast

        if (isForUs) {
            return RelayDecision(deliverLocally = true, excludePeer = fromPeer)
        }

        if (frame.ttl == 0) {
            droppedCount++
            return RelayDecision(
                deliverLocally = deliverLocally,
                excludePeer = fromPeer,
                drop = if (deliverLocally) null else RelayDrop.hopLimitReached,
            )
        }

        relayedCount++
        return RelayDecision(
            deliverLocally = deliverLocally,
            relayFrame = frame.withDecrementedTtl(),
            jitterMs = jitter(Wire.JITTER_MIN_MS, Wire.JITTER_MAX_MS),
            excludePeer = fromPeer,
        )
    }

    fun witness(key: FrameKey, fromPeer: String) = recordWitness(key, fromPeer)

    /**
     * Whether a pending relay should be abandoned because enough *other* peers
     * were heard carrying the same frame during the jitter window.
     */
    fun shouldSuppress(key: FrameKey, origin: String): Boolean {
        sweepWitnesses()
        val heard = witnesses[key] ?: return false
        return heard.keys.count { it != origin } >= Wire.SUPPRESSION_THRESHOLD
    }

    fun clear() {
        seen.clear()
        witnesses.clear()
    }

    private fun recordWitness(key: FrameKey, peer: String) {
        witnesses.getOrPut(key) { HashMap() }[peer] = clock()
    }

    private fun sweepWitnesses() {
        val cutoff = clock() - Wire.WITNESS_EXPIRY_MS
        val iterator = witnesses.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            entry.value.entries.removeAll { it.value <= cutoff }
            if (entry.value.isEmpty()) iterator.remove()
        }
    }
}
