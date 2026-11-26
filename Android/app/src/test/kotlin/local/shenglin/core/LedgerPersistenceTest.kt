package local.shenglin.core

import org.junit.Assert.*
import org.junit.Test

class LedgerPersistenceTest {
    @Test fun writeFailureKeepsTheDurableRevisionLeaseAndManualTakeover() {
        val ledger = PeerState.Ledger()
        val key = ByteArray(32)
        val quiet = PeerState.Update.signed("initiator", 1, true, true, 120, null, key)
        val release = PeerState.Update.signed("initiator", 2, false, true, 120, null, key)
        assertTrue(ledger.acceptPersisted(quiet, "peer", "initiator", key, 100) { true }!!.accepted)
        ledger.takeOver(100)

        assertNull(ledger.acceptPersisted(release, "peer", "initiator", key, 100) { false })
        assertEquals(1L, ledger.records().getValue("peer").revision)
        assertTrue(ledger.manualTakeover())
        assertFalse(ledger.removePeer("peer", 100) { false })
        assertEquals(1, ledger.activeCount(100))
        assertTrue(ledger.manualTakeover())

        assertTrue(ledger.acceptPersisted(release, "peer", "initiator", key, 100) { true }!!.accepted)
        assertTrue(ledger.removePeer("peer", 100) { true })
        assertTrue(ledger.records().isEmpty())
        assertFalse(ledger.manualTakeover())
    }
}
