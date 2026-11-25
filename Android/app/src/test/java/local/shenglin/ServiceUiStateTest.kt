package local.shenglin

import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

class ServiceUiStateTest {
    @Test fun connectionSummaryCountsPairedDevicesWithAnAuthenticatedLink() {
        val peer = PeerUiState("one", "iPad", "ipad", true, true)
        val peers = listOf(
            peer,
            peer.copy(id = "two", lanConnected = false),
            peer.copy(id = "three", lanConnected = false, bleConnected = false, spaceEligible = true),
            peer.copy(id = "four", pending = true),
        )
        assertEquals("已连接 2 台，共配对 3 台", ServiceUiState(status = "配对已取消", peers = peers).connectionSummary())
        assertEquals("尚无已配对设备", ServiceUiState().connectionSummary())
        assertEquals("等待设备完成配对", ServiceUiState(peers = listOf(peer.copy(pending = true))).connectionSummary())
    }

    @Test fun linkChangesProduceIndependentObservableSnapshots() {
        val before = ServiceUiState(peers = listOf(PeerUiState("peer", "iPad", "ipad", true, false)))
        val state = MutableStateFlow(before)
        state.value = before.copy(peers = listOf(before.peers.single().copy(lanConnected = false, bleConnected = true, spaceEligible = true)))
        assertNotEquals(before, state.value)
        assertTrue(before.peers.single().lanConnected)
        assertFalse(before.peers.single().bleConnected)
        assertFalse(state.value.peers.single().lanConnected)
        assertTrue(state.value.peers.single().bleConnected)
        assertTrue(state.value.peers.single().spaceEligible)
        assertFalse(before.peers.single().spaceEligible)
    }
}
