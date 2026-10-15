package local.shenglin.core

import uniffi.shenglin_core.*

/** Android/Java model adapters only. Rust owns validation, leases and space rules. */
object PeerState {
    private fun checkedTarget(value: Long?): Int? {
        if (value == null) return null
        if (value !in 0L..500L) throw CoreException.InvalidMessage()
        return value.toInt()
    }

    const val LEASE_SECONDS = 20L
    const val RENEWAL_SECONDS = 5L
    class Update(@JvmField val origin: String, @JvmField val revision: Long, @JvmField val quiet: Boolean,
                 @JvmField val known: Boolean, @JvmField val validUntil: Long, @JvmField val targetMilli: Int?, @JvmField val signature: String) {
        internal fun rust() = PeerUpdate(origin, revision.toULong(), quiet, known, validUntil, targetMilli?.toLong(), signature)
        fun valid(key: ByteArray, expectedOrigin: String, now: Long) = validUpdate(rust(), key, expectedOrigin, now)
        companion object {
            internal fun from(value: PeerUpdate) = Update(value.origin, value.revision.toLong(), value.quiet, value.known, value.validUntil, checkedTarget(value.targetMilli), value.signature)
            @JvmStatic fun signed(origin: String, revision: Long, quiet: Boolean, known: Boolean, validUntil: Long, targetMilli: Int?, key: ByteArray) =
                from(signUpdate(origin, revision.toULong(), quiet, known, validUntil, targetMilli?.toLong(), key))
        }
    }
    class Ack(@JvmField val origin: String, @JvmField val revision: Long, @JvmField val quiet: Boolean,
              @JvmField val result: String, @JvmField val targetMilli: Int?, @JvmField val signature: String) {
        internal fun rust() = PeerAck(origin, revision.toULong(), quiet, result, targetMilli?.toLong(), signature)
        fun valid(key: ByteArray, expectedOrigin: String) = validAck(rust(), key, expectedOrigin)
        companion object {
            internal fun from(value: PeerAck) = Ack(value.origin, value.revision.toLong(), value.quiet, value.result, checkedTarget(value.targetMilli), value.signature)
            @JvmStatic fun signed(origin: String, revision: Long, quiet: Boolean, result: String, targetMilli: Int?, key: ByteArray) = from(signAck(origin, revision.toULong(), quiet, result, targetMilli?.toLong(), key))
        }
    }
    class NameClaim(@JvmField val name: String, @JvmField val signature: String) {
        internal fun rust() = RustNameClaim(name, signature)
        fun valid(key: ByteArray) = validName(rust(), key)
        companion object {
            internal fun from(value: RustNameClaim) = NameClaim(value.name, value.signature)
            @JvmStatic fun signed(name: String, key: ByteArray) = from(signName(name, key))
        }
    }
    class SpaceGate {
        private val core = RustSpaceGate()
        fun reset() = core.reset()
        fun allows(requireBoth: Boolean, ble: Boolean, wifi: Boolean, now: Long) = core.allows(requireBoth, ble, wifi, now)
    }
    class Change(value: RustQuietChange) {
        @JvmField val started = value.started
        @JvmField val ended = value.ended
        @JvmField val manualAtEnd = value.manualAtEnd
        @JvmField val activeCount = value.activeCount.toInt()
        @JvmField val accepted = value.accepted
    }
    class Record(@JvmField val revision: Long, @JvmField var validUntil: Long?)
    class Ledger {
        private val core = DemandLedger()
        fun records(): Map<String, Record> = core.snapshot().records.mapValues { Record(it.value.revision.toLong(), it.value.validUntil) }
        fun restoreRecords(saved: Map<String, Record>, manualTakeover: Boolean, now: Long) = Change(core.restore(LedgerSnapshot(saved.mapValues { DemandRecord(it.value.revision.toULong(), it.value.validUntil) }, manualTakeover), now))
        fun manualTakeover() = core.snapshot().manualTakeover
        fun revisions(): Map<String, Long> = core.snapshot().records.mapValues { it.value.revision.toLong() }
        fun restoreRevisions(saved: Map<String, Long>) = core.loadSnapshot(LedgerSnapshot(saved.mapValues { DemandRecord(it.value.toULong(), null) }, false))
        fun activeCount(now: Long) = core.activeCount(now).toInt()
        fun takeOver(now: Long) = core.takeOver(now)
        fun expire(now: Long) = Change(core.expire(now))
        fun accept(update: Update, source: String, expectedOrigin: String, key: ByteArray, now: Long) = Change(core.accept(update.rust(), source, expectedOrigin, key, now))
        fun stopResponding(now: Long) = Change(core.stopResponding(null, now))
        fun stopResponding(source: String, now: Long) = Change(core.stopResponding(source, now))
    }
    class BleProof {
        private val core = LinkProof()
        fun sent(update: Update) = core.sent(update.rust())
        fun accept(ack: Ack, key: ByteArray, remoteOrigin: String, wallSeconds: Long, elapsedMillis: Long) = core.accept(ack.rust(), key, remoteOrigin, wallSeconds, elapsedMillis)
        fun verified(elapsedMillis: Long) = core.verified(elapsedMillis)
        fun clear() = core.clear()
    }
    @JvmStatic fun androidBleCentral(remotePlatform: String, localRole: String) = uniffi.shenglin_core.androidBleCentral(remotePlatform, localRole)
}
