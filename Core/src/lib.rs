use base64::{engine::general_purpose::STANDARD as B64, Engine};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::{collections::HashMap, sync::Mutex};
use subtle::ConstantTimeEq;
mod pairing;
pub use pairing::*;
mod audio;
pub use audio::*;
uniffi::setup_scaffolding!();
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("invalid message")]
    InvalidMessage,
    #[error("wrong session")]
    WrongSession,
    #[error("wrong code")]
    WrongCode,
    #[error("expired")]
    Expired,
    #[error("wrong step")]
    WrongStep,
    #[error("crypto failed")]
    CryptoFailed,
}
pub(crate) fn mac(key: &[u8], message: &[u8]) -> Vec<u8> {
    let mut m = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts any key length");
    m.update(message);
    m.finalize().into_bytes().to_vec()
}
#[uniffi::export]
pub fn authentication_sign(message: String, key: Vec<u8>) -> String {
    B64.encode(mac(&key, message.as_bytes()))
}
#[uniffi::export]
pub fn authentication_matches(supplied: String, expected: String) -> bool {
    match (B64.decode(supplied), B64.decode(expected)) {
        (Ok(a), Ok(b)) => a.ct_eq(&b).into(),
        _ => false,
    }
}
#[uniffi::export]
pub fn wifi_proof_sign(role: String, nonce: String, key: Vec<u8>) -> String {
    authentication_sign(format!("wifi-proof|{role}|{nonce}"), key)
}
#[uniffi::export]
pub fn wifi_proof_valid(signature: String, role: String, nonce: String, key: Vec<u8>) -> bool {
    B64.decode(&nonce).is_ok_and(|v| v.len() == 16)
        && authentication_matches(signature, wifi_proof_sign(role, nonce, key))
}
#[uniffi::export]
pub fn network_medium_proof_sign(
    role: String,
    nonce: String,
    medium: String,
    key: Vec<u8>,
) -> Result<String, CoreError> {
    if !matches!(medium.as_str(), "wifi" | "ethernet") {
        return Err(CoreError::InvalidMessage);
    }
    Ok(authentication_sign(
        format!("network-medium|1|{role}|{nonce}|{medium}"),
        key,
    ))
}
#[uniffi::export]
pub fn network_medium_proof_valid(
    signature: String,
    role: String,
    nonce: String,
    medium: String,
    key: Vec<u8>,
) -> bool {
    B64.decode(&nonce).is_ok_and(|v| v.len() == 16)
        && network_medium_proof_sign(role, nonce, medium, key)
            .is_ok_and(|s| authentication_matches(signature, s))
}
#[uniffi::export]
pub fn service_name(key: Vec<u8>) -> String {
    format!(
        "Shenglin-{}",
        mac(&key, b"wifi-service")[..8]
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>()
    )
}
fn target(n: Option<i64>) -> String {
    n.map(|v| v.to_string()).unwrap_or_else(|| "-".into())
}
fn valid_target(n: Option<i64>) -> bool {
    n.is_none_or(|v| (0..=500).contains(&v))
}
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct PeerUpdate {
    pub origin: String,
    pub revision: u64,
    pub quiet: bool,
    pub known: bool,
    pub valid_until: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_milli: Option<i64>,
    pub signature: String,
}
impl PeerUpdate {
    fn message(&self) -> String {
        format!(
            "peer-state|2|{}|{}|{}|{}|{}|{}",
            self.origin,
            self.revision,
            self.quiet as u8,
            self.known as u8,
            self.valid_until,
            target(self.target_milli)
        )
    }
}
#[uniffi::export]
pub fn sign_update(
    origin: String,
    revision: u64,
    quiet: bool,
    known: bool,
    valid_until: i64,
    target_milli: Option<i64>,
    key: Vec<u8>,
) -> PeerUpdate {
    let mut u = PeerUpdate {
        origin,
        revision,
        quiet: known && quiet,
        known,
        valid_until,
        target_milli,
        signature: String::new(),
    };
    u.signature = authentication_sign(u.message(), key);
    u
}
#[uniffi::export]
pub fn valid_update(update: PeerUpdate, key: Vec<u8>, expected_origin: String, now: i64) -> bool {
    update.origin == expected_origin
        && update.valid_until > now
        && update.valid_until <= now.saturating_add(25)
        && valid_target(update.target_milli)
        && (!update.quiet || update.known)
        && authentication_matches(
            update.signature.clone(),
            authentication_sign(update.message(), key),
        )
}
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct PeerAck {
    pub origin: String,
    pub revision: u64,
    pub quiet: bool,
    pub result: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_milli: Option<i64>,
    pub signature: String,
}
impl PeerAck {
    fn message(&self) -> String {
        format!(
            "peer-ack|1|{}|{}|{}|{}|{}",
            self.origin,
            self.revision,
            self.quiet as u8,
            self.result,
            target(self.target_milli)
        )
    }
}
#[uniffi::export]
pub fn sign_ack(
    origin: String,
    revision: u64,
    quiet: bool,
    result: String,
    target_milli: Option<i64>,
    key: Vec<u8>,
) -> PeerAck {
    let mut a = PeerAck {
        origin,
        revision,
        quiet,
        result,
        target_milli,
        signature: String::new(),
    };
    a.signature = authentication_sign(a.message(), key);
    a
}
#[uniffi::export]
pub fn valid_ack(ack: PeerAck, key: Vec<u8>, expected_origin: String) -> bool {
    ack.origin == expected_origin
        && valid_target(ack.target_milli)
        && authentication_matches(
            ack.signature.clone(),
            authentication_sign(ack.message(), key),
        )
}
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct RustNameClaim {
    pub name: String,
    pub signature: String,
}
#[uniffi::export]
pub fn sign_name(name: String, key: Vec<u8>) -> RustNameClaim {
    let name = clean_name(&name, "设备", 64, 128, false);
    let signature = authentication_sign(format!("peer-name|3|{name}"), key);
    RustNameClaim { name, signature }
}
#[uniffi::export]
pub fn valid_name(claim: RustNameClaim, key: Vec<u8>) -> bool {
    !claim.name.is_empty()
        && claim.name == claim.name.trim()
        && claim.name.len() <= 128
        && !claim.name.chars().any(control)
        && authentication_matches(
            claim.signature,
            authentication_sign(format!("peer-name|3|{}", claim.name), key),
        )
}
macro_rules! wire {
    ($enc:ident,$dec:ident,$ty:ty) => {
        #[uniffi::export]
        pub fn $enc(value: $ty) -> String {
            serde_json::to_string(&value).expect("finite wire fields")
        }
        #[uniffi::export]
        pub fn $dec(json: String) -> Result<$ty, CoreError> {
            serde_json::from_str(&json).map_err(|_| CoreError::InvalidMessage)
        }
    };
}
wire!(encode_update, decode_update, PeerUpdate);
wire!(encode_ack, decode_ack, PeerAck);
wire!(encode_name, decode_name, RustNameClaim);
#[derive(uniffi::Object, Default)]
pub struct RustSpaceGate {
    last: Mutex<Option<i64>>,
}
#[uniffi::export]
impl RustSpaceGate {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }
    pub fn snapshot(&self) -> Option<i64> {
        *self.last.lock().unwrap()
    }
    pub fn load_snapshot(&self, last: Option<i64>) {
        *self.last.lock().unwrap() = last
    }
    pub fn reset(&self) {
        *self.last.lock().unwrap() = None
    }
    pub fn allows(&self, require_both: bool, ble: bool, network: bool, now: i64) -> bool {
        let mut last = self.last.lock().unwrap();
        if if require_both {
            ble && network
        } else {
            ble || network
        } {
            *last = Some(now);
            true
        } else {
            last.is_some_and(|v| now < v.saturating_add(20))
        }
    }
}
#[uniffi::export]
pub fn network_scope_allows(wifi_only: bool, lan_verified: bool, wifi_verified: bool) -> bool {
    if wifi_only {
        wifi_verified
    } else {
        lan_verified
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct DemandRecord {
    pub revision: u64,
    pub valid_until: Option<i64>,
}
#[derive(Clone, Default, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct LedgerSnapshot {
    pub records: HashMap<String, DemandRecord>,
    pub manual_takeover: bool,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct RustQuietChange {
    pub started: bool,
    pub ended: bool,
    pub manual_at_end: bool,
    pub active_count: u32,
    pub accepted: bool,
}
impl LedgerSnapshot {
    fn count(&self, now: i64) -> u32 {
        self.records
            .values()
            .filter(|r| r.valid_until.is_some_and(|v| v > now))
            .count() as u32
    }
    fn change(&mut self, now: i64, edit: impl FnOnce(&mut Self) -> bool) -> RustQuietChange {
        let was = self.records.values().any(|r| r.valid_until.is_some());
        for r in self.records.values_mut() {
            if r.valid_until.is_some_and(|v| v <= now) {
                r.valid_until = None;
            }
        }
        let accepted = edit(self);
        let count = self.count(now);
        let ended = was && count == 0;
        let manual_at_end = ended && self.manual_takeover;
        if ended {
            self.manual_takeover = false
        }
        RustQuietChange {
            started: !was && count > 0,
            ended,
            manual_at_end,
            active_count: count,
            accepted,
        }
    }
}
#[derive(Default, uniffi::Object)]
pub struct DemandLedger {
    state: Mutex<LedgerSnapshot>,
}
#[uniffi::export]
impl DemandLedger {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }
    pub fn load_snapshot(&self, snapshot: LedgerSnapshot) {
        *self.state.lock().unwrap() = snapshot
    }
    pub fn snapshot(&self) -> LedgerSnapshot {
        self.state.lock().unwrap().clone()
    }
    pub fn restore(&self, snapshot: LedgerSnapshot, now: i64) -> RustQuietChange {
        let mut s = self.state.lock().unwrap();
        *s = snapshot;
        let c = s.change(now, |_| false);
        if c.active_count == 0 {
            s.manual_takeover = false
        }
        c
    }
    pub fn active_count(&self, now: i64) -> u32 {
        self.state.lock().unwrap().count(now)
    }
    pub fn take_over(&self, now: i64) {
        let mut s = self.state.lock().unwrap();
        if s.count(now) > 0 {
            s.manual_takeover = true
        }
    }
    pub fn expire(&self, now: i64) -> RustQuietChange {
        self.state.lock().unwrap().change(now, |_| false)
    }
    pub fn stop_responding(&self, source: Option<String>, now: i64) -> RustQuietChange {
        self.state.lock().unwrap().change(now, |s| {
            for (k, r) in &mut s.records {
                if source.as_ref().is_none_or(|v| v == k) {
                    r.valid_until = None
                }
            }
            false
        })
    }
    pub fn accept(
        &self,
        update: PeerUpdate,
        source: String,
        expected_origin: String,
        key: Vec<u8>,
        now: i64,
    ) -> RustQuietChange {
        self.state.lock().unwrap().change(now, |s| {
            let old = s.records.get(&source);
            if !valid_update(update.clone(), key, expected_origin, now)
                || update.revision <= old.map_or(0, |r| r.revision)
            {
                return false;
            }
            let until = if update.known {
                if update.quiet {
                    Some(update.valid_until.min(now.saturating_add(20)))
                } else {
                    None
                }
            } else {
                old.and_then(|r| r.valid_until)
            };
            s.records.insert(
                source,
                DemandRecord {
                    revision: update.revision,
                    valid_until: until,
                },
            );
            true
        })
    }
}
#[uniffi::export]
pub fn remote_ducking_allowed(
    has_demand: bool,
    local_recording: Option<bool>,
    manual: bool,
) -> bool {
    has_demand && local_recording == Some(false) && !manual
}
#[uniffi::export]
pub fn quiet_target(local: Option<f32>, remote: Option<f32>) -> Option<f32> {
    match (local, remote) {
        (Some(a), Some(b)) => Some(if b < a { b } else { a }),
        (a, b) => a.or(b),
    }
}
#[uniffi::export]
pub fn volume_target(current: f32, configured: f32) -> Option<f32> {
    if current.is_finite()
        && configured.is_finite()
        && (0. ..=1.).contains(&current)
        && (0. ..=1.).contains(&configured)
        && current > configured + 0.005
    {
        Some(configured)
    } else {
        None
    }
}
#[uniffi::export]
pub fn volume_restore(
    current: f32,
    route: String,
    original: f32,
    applied: f32,
    original_route: String,
) -> Option<f32> {
    if current.is_finite() && route == original_route && (current - applied).abs() <= 0.005 {
        Some(original)
    } else {
        None
    }
}
#[derive(Default)]
struct ProofState {
    pending: std::collections::VecDeque<PeerUpdate>,
    authenticated_at: Option<i64>,
}
#[derive(Default, uniffi::Object)]
pub struct LinkProof {
    state: Mutex<ProofState>,
}
#[uniffi::export]
impl LinkProof {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }
    pub fn sent(&self, update: PeerUpdate) {
        let mut s = self.state.lock().unwrap();
        if let Some(old) = s.pending.iter_mut().find(|v| v.revision == update.revision) {
            *old = update
        } else {
            s.pending.push_back(update)
        }
        while s.pending.len() > 8 {
            s.pending.pop_front();
        }
    }
    pub fn accept(
        &self,
        ack: PeerAck,
        key: Vec<u8>,
        remote_origin: String,
        wall_seconds: i64,
        elapsed_millis: i64,
    ) -> bool {
        let mut s = self.state.lock().unwrap();
        let Some(index) = s.pending.iter().position(|v| v.revision == ack.revision) else {
            return false;
        };
        let request = &s.pending[index];
        if request.valid_until <= wall_seconds
            || request.quiet != ack.quiet
            || !valid_ack(ack, key, remote_origin)
        {
            return false;
        }
        s.pending.remove(index);
        s.authenticated_at = Some(elapsed_millis);
        true
    }
    pub fn accept_update(
        &self,
        update: PeerUpdate,
        key: Vec<u8>,
        remote_origin: String,
        wall_seconds: i64,
        elapsed_millis: i64,
    ) -> bool {
        if !valid_update(update, key, remote_origin, wall_seconds) {
            return false;
        }
        self.state.lock().unwrap().authenticated_at = Some(elapsed_millis);
        true
    }
    pub fn verified(&self, elapsed_millis: i64) -> bool {
        self.state
            .lock()
            .unwrap()
            .authenticated_at
            .is_some_and(|at| elapsed_millis >= at && elapsed_millis.saturating_sub(at) < 20_000)
    }
    pub fn clear(&self) {
        *self.state.lock().unwrap() = ProofState::default()
    }
}
#[uniffi::export]
pub fn android_ble_central(remote_platform: String, local_role: String) -> Result<bool, CoreError> {
    match remote_platform.as_str() {
        "mac" => Ok(false),
        "ipad" => Ok(true),
        "android" => Ok(local_role == "initiator"),
        _ => Err(CoreError::InvalidMessage),
    }
}

#[uniffi::export]
pub fn random_bytes(size: u32) -> Result<Vec<u8>, CoreError> {
    if size > 1_048_576 {
        return Err(CoreError::InvalidMessage);
    }
    let mut bytes = vec![0; size as usize];
    getrandom::getrandom(&mut bytes).map_err(|_| CoreError::CryptoFailed)?;
    Ok(bytes)
}
#[uniffi::export]
pub fn sha256(input: Vec<u8>) -> Vec<u8> {
    use sha2::Digest;
    Sha256::digest(input).to_vec()
}
#[uniffi::export]
pub fn wifi_evidence(
    identity_verified: bool,
    local_medium: Option<String>,
    remote_medium: Option<String>,
    remote_medium_verified: bool,
) -> bool {
    identity_verified
        && remote_medium_verified
        && local_medium.as_deref() == Some("wifi")
        && remote_medium.as_deref() == Some("wifi")
}
#[uniffi::export]
pub fn space_predicate(require_both: bool, ble: bool, network: bool) -> bool {
    if require_both {
        ble && network
    } else {
        ble || network
    }
}
#[uniffi::export]
pub fn local_update(
    origin: String,
    revision: u64,
    enabled: bool,
    recording_known: bool,
    recording: bool,
    space_evidence: bool,
    paused: bool,
    now: i64,
    target_milli: Option<i64>,
    key: Vec<u8>,
) -> PeerUpdate {
    let known = paused || !space_evidence || recording_known;
    let quiet = !paused && enabled && recording_known && recording && space_evidence;
    sign_update(
        origin,
        revision,
        quiet,
        known,
        now.saturating_add(20),
        target_milli,
        key,
    )
}
