package local.shenglin

import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Test

class ServiceUiStateTest {
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
