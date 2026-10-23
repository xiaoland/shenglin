use crate::store::{atomic, Store};
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    time::{Duration, Instant},
};
use wasapi::*;
use windows::{
    core::Interface,
    Win32::{
        Media::Audio::*,
        System::Com::{CoTaskMemFree, CLSCTX_ALL},
    },
};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub id: String,
    pub name: String,
    pub sample_rate: u32,
    pub channels: u32,
}
pub fn sources() -> Result<Vec<Source>> {
    let enumerator = DeviceEnumerator::new()?;
    let mut result = vec![];
    for dev in &enumerator.get_device_collection(&Direction::Capture)? {
        let dev = dev?;
        result.push(Source {
            id: dev.get_id()?,
            name: dev.get_friendlyname()?,
            sample_rate: 48000,
            channels: 1,
        });
    }
    Ok(result)
}

/// A 20 ms packet keeps network work outside WASAPI's buffer acquisition.
pub fn capture(id: &str, mut consume: impl FnMut(Vec<u8>) -> Result<bool>) -> Result<()> {
    initialize_mta().ok()?;
    let enumerator = DeviceEnumerator::new()?;
    let dev = enumerator.get_device(id)?;
    ensure!(
        dev.get_direction() == Direction::Capture,
        "设备不是麦克风输入"
    );
    let mut client = dev.get_iaudioclient()?;
    let format = WaveFormat::new(32, 32, &SampleType::Float, 48000, 1, None);
    client.initialize_client(
        &format,
        &Direction::Capture,
        &StreamMode::EventsShared {
            autoconvert: true,
            buffer_duration_hns: 200_000,
        },
    )?;
    let event = client.set_get_eventhandle()?;
    let reader = client.get_audiocaptureclient()?;
    let mut queue = VecDeque::new();
    client.start_stream()?;
    let result: Result<()> = (|| {
        loop {
            event.wait_for_event(2000)?;
            while reader.get_next_packet_size()?.unwrap_or(0) > 0 {
                reader.read_from_device_to_deque(&mut queue)?;
            }
            // Drop old backlog after a stalled receiver; never transmit seconds of delayed speech.
            if queue.len() > 48000 * 4 / 5 {
                let drop = queue.len() - 3840;
                queue.drain(..drop);
            }
            while queue.len() >= 3840 {
                let chunk: Vec<u8> = queue.drain(..3840).collect();
                if !consume(chunk)? {
                    return Ok(());
                }
            }
        }
    })();
    let stopped = client.stop_stream();
    result?;
    stopped?;
    Ok(())
}

pub fn probe(id: &str, seconds: u64) -> Result<serde_json::Value> {
    let start = Instant::now();
    let mut frames = 0u64;
    let mut nonzero = 0u64;
    let mut square = 0f64;
    capture(id, |data| {
        for bytes in data.chunks_exact(4) {
            let n = f32::from_le_bytes(bytes.try_into().unwrap());
            ensure!(n.is_finite(), "非有限音频样本");
            if n.abs() > 0.000001 {
                nonzero += 1;
            }
            square += f64::from(n) * f64::from(n);
            frames += 1;
        }
        Ok(start.elapsed() < Duration::from_secs(seconds))
    })?;
    Ok(
        serde_json::json!({"frames":frames,"nonzero":nonzero,"rms":(square/frames.max(1) as f64).sqrt(),"seconds":start.elapsed().as_secs_f64()}),
    )
}

pub fn recording_pids() -> Result<HashSet<u32>> {
    let e = DeviceEnumerator::new()?;
    let mut pids = HashSet::new();
    for dev in &e.get_device_collection(&Direction::Capture)? {
        let sessions = dev?
            .get_iaudiosessionmanager()?
            .get_audiosessionenumerator()?;
        for i in 0..sessions.get_count()? {
            let s = sessions.get_session(i)?;
            if s.get_state()? == SessionState::Active {
                let pid = s.get_process_id()?;
                if pid != std::process::id() {
                    pids.insert(pid);
                }
            }
        }
    }
    Ok(pids)
}

struct Session {
    id: String,
    pid: u32,
    volume: ISimpleAudioVolume,
    active: bool,
}
fn outputs() -> Result<Vec<Session>> {
    let e = DeviceEnumerator::new()?;
    let mut result = vec![];
    for dev in &e.get_device_collection(&Direction::Render)? {
        let dev = dev?;
        unsafe {
            let manager: IAudioSessionManager2 = dev.as_immdevice().Activate(CLSCTX_ALL, None)?;
            let sessions = manager.GetSessionEnumerator()?;
            for i in 0..sessions.GetCount()? {
                let control: IAudioSessionControl2 = sessions.GetSession(i)?.cast()?;
                let raw = control.GetSessionInstanceIdentifier()?;
                let id = raw.to_string();
                CoTaskMemFree(Some(raw.0.cast()));
                result.push(Session {
                    id: format!("{}|{}", dev.get_id()?, id?),
                    pid: control.GetProcessId()?,
                    volume: control.cast()?,
                    active: control.GetState()? == AudioSessionStateActive,
                });
            }
        }
    }
    Ok(result)
}
#[derive(Clone, Serialize, Deserialize, PartialEq)]
struct Snapshot {
    original: f32,
    applied: f32,
    #[serde(default)]
    pending: Option<f32>,
}
impl Snapshot {
    fn owns(&self, current: f32) -> bool {
        (current - self.applied).abs() <= 0.005
            || self.pending.is_some_and(|v| (current - v).abs() <= 0.005)
    }
}
#[derive(Default, Serialize, Deserialize, PartialEq, Clone)]
struct Saved {
    values: HashMap<String, Snapshot>,
    manual: bool,
    active: bool,
}
pub struct Volume {
    store: Store,
    saved: Saved,
    persisted: Saved,
}
impl Volume {
    pub fn new(store: Store) -> Result<Self> {
        let path = store.0.join("volume.json");
        let saved = if path.exists() {
            serde_json::from_slice(&std::fs::read(path)?)?
        } else {
            Saved::default()
        };
        Ok(Self {
            store,
            persisted: saved.clone(),
            saved,
        })
    }
    fn save(&mut self) -> Result<()> {
        if self.saved != self.persisted {
            atomic(
                &self.store.0.join("volume.json"),
                &serde_json::to_vec(&self.saved)?,
            )?;
            self.persisted = self.saved.clone();
        }
        Ok(())
    }
    fn adjust(
        &mut self,
        id: &str,
        original: f32,
        target: f32,
        set: impl FnOnce(f32) -> Result<()>,
    ) -> Result<()> {
        let entry = self.saved.values.entry(id.to_owned()).or_insert(Snapshot {
            original,
            applied: original,
            pending: None,
        });
        entry.pending = Some(target);
        self.save()?;
        set(target)?;
        let entry = self.saved.values.get_mut(id).unwrap();
        entry.applied = target;
        entry.pending = None;
        self.save()
    }
    pub fn apply(
        &mut self,
        demand: bool,
        known: bool,
        protected: &HashSet<u32>,
        gain: f32,
    ) -> Result<&'static str> {
        let sessions = outputs()?;
        for s in &sessions {
            if let Some(old) = self.saved.values.get(&s.id) {
                let current = unsafe { s.volume.GetMasterVolume()? };
                if !old.owns(current) {
                    self.saved.manual = true;
                }
            }
        }
        if !demand {
            self.saved.manual = false;
        }
        let allow = demand && known && !self.saved.manual;
        // Save restoration ownership before changing system volume, including crash recovery.
        for s in &sessions {
            let eligible = allow
                && s.active
                && s.pid != 0
                && s.pid != std::process::id()
                && !protected.contains(&s.pid);
            if eligible {
                let original = if let Some(old) = self.saved.values.get(&s.id) {
                    old.original
                } else {
                    unsafe { s.volume.GetMasterVolume()? }
                };
                let target = original * gain;
                if self
                    .saved
                    .values
                    .get(&s.id)
                    .is_none_or(|old| old.applied != target || old.pending.is_some())
                {
                    self.adjust(&s.id, original, target, |value| {
                        unsafe { s.volume.SetMasterVolume(value, std::ptr::null())? };
                        Ok(())
                    })?;
                }
            } else if let Some(old) = self.saved.values.get(&s.id).cloned() {
                let current = unsafe { s.volume.GetMasterVolume()? };
                if old.owns(current) {
                    unsafe { s.volume.SetMasterVolume(old.original, std::ptr::null())? };
                }
                self.saved.values.remove(&s.id);
                self.save()?;
            }
        }
        let ids: HashSet<_> = sessions.iter().map(|s| s.id.clone()).collect();
        self.saved.values.retain(|id, _| ids.contains(id));
        self.saved.active = demand;
        self.save()?;
        Ok(if !known {
            "unavailable"
        } else if self.saved.manual {
            "manual"
        } else if self.saved.values.is_empty() {
            "alreadyRestored"
        } else {
            "applied"
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failed_gain_change_preserves_both_possible_owned_volumes() {
        let path = std::env::temp_dir().join(format!(
            "shenglin-volume-{}-{}",
            std::process::id(),
            crate::wire::nonce().replace('/', "_")
        ));
        std::fs::create_dir_all(&path).unwrap();
        let store = Store(path.clone());
        let mut volume = Volume::new(store.clone()).unwrap();
        volume.adjust("session", 1.0, 0.2, |_| Ok(())).unwrap();
        assert!(volume
            .adjust("session", 1.0, 0.1, |_| anyhow::bail!(
                "injected system failure"
            ))
            .is_err());
        let restored = Volume::new(store.clone()).unwrap();
        let old = &restored.saved.values["session"];
        assert_eq!(old.original, 1.0);
        assert!(old.owns(0.2));
        assert!(old.owns(0.1));
        assert!(!old.owns(0.4));
        volume.adjust("session", 1.0, 0.1, |_| Ok(())).unwrap();
        let restored = Volume::new(store).unwrap();
        let applied = &restored.saved.values["session"];
        assert!(applied.owns(0.1));
        assert!(!applied.owns(0.2));
        assert_eq!(applied.pending, None);
        std::fs::remove_dir_all(path).unwrap();
    }
}
