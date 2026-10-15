package local.shenglin.transport

import local.shenglin.core.Crypto
import local.shenglin.core.PeerState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

class TransportLifecycleTest {
    @Test fun cancelledPairAndSupersededConnectionCannotCompleteLate() {
        val pairing = TransportLifecycle.Epoch()
        val attempt = pairing.advance()
        pairing.advance() // cancellation or a newer user-selected device
        assertFalse(pairing.isCurrent(attempt))

        val connection = TransportLifecycle.Epoch()
        val disconnected = connection.advance()
        val reconnected = connection.advance()
        assertFalse(connection.isCurrent(disconnected))
        assertTrue(connection.isCurrent(reconnected))
    }

    @Test fun pendingPairExpiresAtItsOriginalDeadline() {
        val deadline = 1_000_000L
        assertFalse(TransportLifecycle.pendingExpired(deadline, deadline - 1))
        assertTrue(TransportLifecycle.pendingExpired(deadline, deadline))
        assertTrue(TransportLifecycle.pendingExpired(deadline, deadline + 1))
    }

    @Test fun pausingPublishesKnownClearState() {
        val key = Crypto.random(32)
        val update = TransportLifecycle.localUpdate("initiator", 5, true, false, true, true, true, 100, key)
        assertTrue(update.known)
        assertFalse(update.quiet)
        assertTrue(update.valid(key, "initiator", 100))
    }

    @Test fun transportSpaceGateKeepsEvidenceForOneLeaseAndCanReset() {
        val gates = HashMap<String, PeerState.SpaceGate>()
        assertTrue(TransportLifecycle.spaceAllowed(gates, "peer", true, true, true, 100))
        assertTrue(TransportLifecycle.spaceAllowed(gates, "peer", true, true, false, 119))
        assertFalse(TransportLifecycle.spaceAllowed(gates, "peer", true, true, false, 120))
        assertTrue(TransportLifecycle.spaceAllowed(gates, "peer", true, true, true, 200))
        TransportLifecycle.resetSpaceGates(gates)
        assertFalse(TransportLifecycle.spaceAllowed(gates, "peer", true, true, false, 201))
    }

    @Test fun unknownRecordingInsideSpaceDoesNotExtendQuietLease() {
        val key = Crypto.random(32)
        val update = TransportLifecycle.localUpdate("initiator", 6, true, false, false, true, false, 100, key)
        assertFalse(update.known)
        assertFalse(update.quiet)
        val outsideSpace = TransportLifecycle.localUpdate("initiator", 7, true, false, false, false, false, 100, key)
        assertTrue(outsideSpace.known)
        assertFalse(outsideSpace.quiet)
    }

    @Test fun unchangedRecordingSamplesDoNotTriggerStateUpdate() {
        assertFalse(TransportLifecycle.recordingChanged(true, true, true))
        assertFalse(TransportLifecycle.recordingChanged(false, false, null))
        assertTrue(TransportLifecycle.recordingChanged(true, false, true))
        assertTrue(TransportLifecycle.recordingChanged(true, true, false))
        assertTrue(TransportLifecycle.recordingChanged(false, false, false))
    }

    @Test fun wifiScopeRequiresSignedWifiOnBothAuthenticatedPathsButLanScopeDoesNot() {
        assertTrue(TransportLifecycle.wifiEvidence(true, "wifi", "wifi", true))
        assertFalse(TransportLifecycle.wifiEvidence(false, "wifi", "wifi", true))
        assertFalse(TransportLifecycle.wifiEvidence(true, "ethernet", "wifi", true))
        assertFalse(TransportLifecycle.wifiEvidence(true, "wifi", "ethernet", true))
        assertFalse(TransportLifecycle.wifiEvidence(true, "wifi", "wifi", false))
        assertFalse(TransportLifecycle.wifiEvidence(true, "wifi", null, false))

        assertFalse(TransportLifecycle.selectedNetworkProof(false, true, false))
        assertTrue(TransportLifecycle.selectedNetworkProof(true, true, false))
        assertTrue(TransportLifecycle.spacePredicate(false, true, false))
        assertFalse(TransportLifecycle.spacePredicate(true, true, false))
    }

    @Test fun selfDiscoveryUsesResolvedEndpointAndNotTheDisplayName() {
        val local = InetAddress.getByAddress(byteArrayOf(10, 0, 0, 8))
        val other = InetAddress.getByAddress(byteArrayOf(10, 0, 0, 9))
        val localV6 = InetAddress.getByAddress(byteArrayOf(0x20, 1, 0x0d, 0xb8.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8))
        assertTrue(TransportLifecycle.sameServiceEndpoint(local, 43000, local, 43000))
        assertTrue(TransportLifecycle.sameServiceEndpointOnAddresses(listOf(local, localV6), 43000, localV6, 43000))
        assertFalse(TransportLifecycle.sameServiceEndpoint(local, 43000, local, 43001))
        assertFalse(TransportLifecycle.sameServiceEndpoint(local, 43000, other, 43000))
        assertFalse(TransportLifecycle.sameServiceEndpoint(null, 43000, local, 43000))
    }

    @Test fun pairingSnapshotSurvivesActivityRecreationWithoutInventedDeadline() {
        assertTrue(TransportLifecycle.pairingCodeVisible("waiting", 200, 199))
        assertFalse(TransportLifecycle.pairingCodeVisible("waiting", 200, 200))
        assertFalse(TransportLifecycle.pairingCodeVisible("verified", 200, 199))
        assertTrue(TransportLifecycle.pairingStatusAt("waiting", 200, 200) == "expired")
        assertTrue(TransportLifecycle.pairingStatusAt("verified", 200, 500) == "verified")
        assertTrue(TransportLifecycle.pairingStatusAt("activated", 200, 500) == "activated")
        assertTrue(TransportLifecycle.clearPairingSnapshotOnForget("activated", "peer-a", "peer-a", false))
        assertTrue(TransportLifecycle.clearPairingSnapshotOnForget("verified", "peer-a", "peer-a", false))
        assertFalse(TransportLifecycle.clearPairingSnapshotOnForget("activated", "peer-a", "peer-b", false))
        assertFalse(TransportLifecycle.clearPairingSnapshotOnForget("activated", "peer-a", "peer-a", true))
    }
}
