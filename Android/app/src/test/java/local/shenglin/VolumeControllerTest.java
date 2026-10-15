package local.shenglin;

import org.junit.Test;
import static org.junit.Assert.*;

public class VolumeControllerTest {
    static final class Fake implements VolumeController.Port {
        int volume = 12;
        String route = "speaker";
        boolean fixed;
        boolean failNextSet;
        public boolean fixed() { return fixed; }
        VolumeController.Snapshot snapshot;
        public int current() { return volume; }
        public int maximum() { return 15; }
        public String route() { return route; }
        public void set(int value) { if (failNextSet) { failNextSet = false; throw new IllegalStateException("simulated set failure"); } assertNotNull("Persist before changing volume", snapshot); volume = value; }
        public VolumeController.Snapshot load() { return snapshot; }
        public void save(VolumeController.Snapshot value) { snapshot = value; }
    }
    @Test public void unknownRestoresButDemandCanResumeWhenIdle() {
        Fake port = new Fake(); VolumeController volume = new VolumeController(port);
        volume.update(true, false, 20); assertEquals(3, port.volume);
        volume.update(true, null, 20); assertEquals(12, port.volume);
        volume.update(true, false, 20); assertEquals(3, port.volume);
        volume.update(false, false, 20); assertEquals(12, port.volume); assertNull(port.snapshot);
    }
    @Test public void manualAdjustmentOwnsWholeRoundIncludingRenewals() {
        Fake port = new Fake(); VolumeController volume = new VolumeController(port);
        volume.update(true, false, 20); port.volume = 8;
        volume.update(true, false, 20); assertEquals(8, port.volume); assertTrue(volume.isManual());
        volume.update(true, true, 20); volume.update(true, false, 20); assertEquals(8, port.volume);
        volume.update(false, false, 20); volume.update(true, false, 20); assertEquals(3, port.volume);
        volume.update(false, false, 20); assertEquals(8, port.volume);
    }
    @Test public void routeChangeDoesNotRestoreOntoNewOutput() {
        Fake port = new Fake(); VolumeController volume = new VolumeController(port);
        volume.update(true, false, 20); port.route = "headphones"; port.volume = 5;
        volume.update(true, false, 20); volume.update(false, false, 20);
        assertEquals(5, port.volume); assertNull(port.snapshot);
    }
    @Test public void processRecoveryOnlyRestoresOwnedSnapshot() {
        Fake port = new Fake(); new VolumeController(port).update(true, false, 20);
        new VolumeController(port).recover(); assertEquals(12, port.volume);
        new VolumeController(port).update(true, false, 20); port.volume = 7;
        new VolumeController(port).recover(); assertEquals(7, port.volume); assertNull(port.snapshot);
    }
    @Test public void manualChangeWhileProtectedAlsoOwnsRound() {
        Fake port = new Fake(); VolumeController volume = new VolumeController(port);
        volume.update(true, true, 20); port.volume = 9;
        volume.update(true, false, 20); assertEquals(9, port.volume);
    }
    @Test public void targetNeverRaisesAlreadyQuietVolume() {
        Fake port = new Fake(); port.volume = 1; VolumeController volume = new VolumeController(port);
        volume.update(true, false, 50); volume.update(false, false, 50); assertEquals(1, port.volume);
    }
    @Test public void restoredManualRoundRemainsProtectedWithoutFreshLink() {
        Fake port = new Fake(); VolumeController volume = new VolumeController(port);
        volume.update(false, false, 20, true); assertEquals(12, port.volume);
        volume.update(true, false, 20, true); assertEquals(12, port.volume);
        volume.update(false, false, 20, false);
        volume.update(true, false, 20, false); assertEquals(3, port.volume);
    }
    @Test public void unknownRouteNeverWritesOrDiscardsRecovery() {
        Fake port = new Fake(); VolumeController volume = new VolumeController(port);
        volume.update(true, false, 20); port.route = null;
        volume.update(false, false, 20); assertEquals(3, port.volume); assertNotNull(port.snapshot);
        assertEquals("outputUnsupported", volume.result());
        port.route = "speaker"; volume.recover(); assertEquals(12, port.volume);
    }
    @Test public void externalChangeDuringProcessDeathIsReportedAsManual() {
        Fake port = new Fake(); new VolumeController(port).update(true, false, 20);
        port.volume = 7;
        VolumeController restarted = new VolumeController(port); restarted.recover();
        assertTrue(restarted.isManual());
        restarted.update(true, false, 20, true); assertEquals(7, port.volume);
    }
    @Test public void fixedVolumeDeviceRejectsControl() {
        Fake port = new Fake(); port.fixed = true;
        VolumeController volume = new VolumeController(port); volume.update(true, false, 20);
        assertEquals(12, port.volume); assertEquals("outputUnsupported", volume.result());
    }
    @Test public void immediateRecoveryFailureRetainsSnapshotAndRetriesWithoutDucking() {
        Fake port = new Fake(); VolumeController volume = new VolumeController(port);
        volume.update(true, false, 20); port.failNextSet = true;
        volume.restoreNow(); assertEquals(3, port.volume); assertNotNull(port.snapshot);
        assertEquals("restoreFailed", volume.result());
        volume.update(true, false, 20, true);
        assertEquals(12, port.volume); assertNull(port.snapshot);
        volume.update(true, false, 20, true); assertEquals(12, port.volume);
    }
}
