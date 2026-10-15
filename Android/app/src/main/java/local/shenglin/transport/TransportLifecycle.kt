package local.shenglin.transport

import local.shenglin.core.PeerState
import java.net.InetAddress
import uniffi.shenglin_core.localUpdate as rustLocalUpdate
import uniffi.shenglin_core.networkScopeAllows as rustNetworkScopeAllows
import uniffi.shenglin_core.spacePredicate as rustSpacePredicate
import uniffi.shenglin_core.wifiEvidence as rustWifiEvidence

/** Android lifecycle edges and thin access to shared Rust space/state decisions. */
object TransportLifecycle {
    class Epoch {
        private var value = 0L

        @Synchronized fun advance(): Long = ++value
        @Synchronized fun current(): Long = value
        @Synchronized fun isCurrent(candidate: Long): Boolean = value == candidate
    }

    @JvmStatic fun pendingExpired(expiresAtMillis: Long, nowMillis: Long): Boolean = expiresAtMillis <= nowMillis

    @JvmStatic fun sameServiceEndpoint(
        localAddress: InetAddress?, localPort: Int,
        discoveredAddress: InetAddress?, discoveredPort: Int,
    ): Boolean = sameServiceEndpointOnAddresses(
        localAddress?.let(::setOf) ?: emptySet(), localPort, discoveredAddress, discoveredPort,
    )

    @JvmStatic fun sameServiceEndpointOnAddresses(
        localAddresses: Collection<InetAddress>?, localPort: Int,
        discoveredAddress: InetAddress?, discoveredPort: Int,
    ): Boolean = !localAddresses.isNullOrEmpty() && discoveredAddress != null && localPort > 0 &&
        localPort == discoveredPort && discoveredAddress in localAddresses

    @JvmStatic fun pairingStatusAt(status: String, deadline: Long, now: Long): String =
        if ((status == "waiting" || status == "verifying") && now >= deadline) "expired" else status

    @JvmStatic fun pairingCodeVisible(status: String, deadline: Long, now: Long): Boolean =
        status == "waiting" && now < deadline

    @JvmStatic fun clearPairingSnapshotOnForget(
        status: String, pairedPeerId: String?, forgottenPeerId: String, sessionActive: Boolean,
    ): Boolean = !sessionActive && pairedPeerId == forgottenPeerId &&
        (status == "verified" || status == "activated")

    @JvmStatic fun wifiEvidence(
        identityVerified: Boolean, localMedium: String?, remoteMedium: String?, remoteMediumVerified: Boolean,
    ): Boolean = rustWifiEvidence(identityVerified, localMedium, remoteMedium, remoteMediumVerified)

    @JvmStatic fun selectedNetworkProof(lanScope: Boolean, lanVerified: Boolean, wifiVerified: Boolean): Boolean =
        rustNetworkScopeAllows(!lanScope, lanVerified, wifiVerified)

    @JvmStatic fun spacePredicate(requireBoth: Boolean, ble: Boolean, network: Boolean): Boolean =
        rustSpacePredicate(requireBoth, ble, network)

    @JvmStatic fun recordingChanged(wasKnown: Boolean, wasRecording: Boolean, sample: Boolean?): Boolean =
        wasKnown != (sample != null) || wasRecording != (sample == true)

    @JvmStatic fun localUpdate(
        origin: String, revision: Long, enabled: Boolean,
        recordingKnown: Boolean, recording: Boolean, spaceEvidence: Boolean,
        paused: Boolean, nowSeconds: Long, key: ByteArray,
    ): PeerState.Update = PeerState.Update.from(
        rustLocalUpdate(
            origin, revision.toULong(), enabled, recordingKnown, recording,
            spaceEvidence, paused, nowSeconds, null, key,
        ),
    )

    @JvmStatic fun spaceAllowed(
        gates: MutableMap<String, PeerState.SpaceGate>, peerId: String,
        requireBoth: Boolean, ble: Boolean, network: Boolean, nowSeconds: Long,
    ): Boolean = gates.getOrPut(peerId) { PeerState.SpaceGate() }
        .allows(requireBoth, ble, network, nowSeconds)

    @JvmStatic fun resetSpaceGates(gates: Map<String, PeerState.SpaceGate>) = gates.values.forEach(PeerState.SpaceGate::reset)
}
