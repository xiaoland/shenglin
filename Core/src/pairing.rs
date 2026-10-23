use super::*;
use sha2::Digest;
use std::ffi::c_void;
use unicode_general_category::{get_general_category, GeneralCategory};
use unicode_segmentation::UnicodeSegmentation;
pub(crate) fn control(c: char) -> bool {
    matches!(
        get_general_category(c),
        GeneralCategory::Control | GeneralCategory::Format
    )
}
pub(crate) fn clean_name(
    text: &str,
    fallback: &str,
    characters: usize,
    bytes: usize,
    pairing: bool,
) -> String {
    let clean: String = text
        .chars()
        .filter(|c| !control(*c) && (!pairing || (*c != '\\' && *c != '"')))
        .collect();
    let mut value = String::new();
    for g in clean.trim().graphemes(true).take(characters) {
        if value.len() + g.len() > bytes {
            break;
        }
        value.push_str(g)
    }
    let value = value.trim().to_string();
    if value.is_empty() {
        fallback.into()
    } else {
        value
    }
}
fn valid_pair_name(name: &Option<String>) -> Result<String, CoreError> {
    name.as_ref()
        .filter(|n| !n.is_empty() && n.len() <= 96 && clean_name(n, "", 24, 24, true) == **n)
        .cloned()
        .ok_or(CoreError::InvalidMessage)
}
fn platform_valid(p: &Option<String>) -> bool {
    p.as_ref()
        .is_none_or(|p| matches!(p.as_str(), "mac" | "ipad" | "android" | "windows"))
}
fn display(p: &Option<String>, fallback: &str) -> String {
    match p.as_deref() {
        Some("mac") => "Mac",
        Some("ipad") => "iPad",
        Some("android") => "Android",
        Some("windows") => "Windows",
        _ => fallback,
    }
    .into()
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct RustPairingFrame {
    pub version: i32,
    pub kind: String,
    pub session: Vec<u8>,
    pub message: Option<Vec<u8>>,
    pub name: Option<String>,
    pub proof: Option<Vec<u8>>,
    pub pairing_mode: Option<bool>,
    pub platform: Option<String>,
}
impl RustPairingFrame {
    fn new(kind: &str, version: i32, session: Vec<u8>) -> Self {
        Self {
            version,
            kind: kind.into(),
            session,
            message: None,
            name: None,
            proof: None,
            pairing_mode: None,
            platform: None,
        }
    }
}
#[derive(Serialize, Deserialize)]
struct WirePairing {
    v: i32,
    k: String,
    s: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    p: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    d: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    f: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    m: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    t: Option<String>,
}
#[uniffi::export]
pub fn encode_pairing(value: RustPairingFrame) -> String {
    serde_json::to_string(&WirePairing {
        v: value.version,
        k: value.kind,
        s: B64.encode(value.session),
        p: value.message.map(|v| B64.encode(v)),
        d: value.name,
        f: value.proof.map(|v| B64.encode(v)),
        m: value.pairing_mode,
        t: value.platform,
    })
    .unwrap()
}
#[uniffi::export]
pub fn decode_pairing(json: String) -> Result<RustPairingFrame, CoreError> {
    let w: WirePairing = serde_json::from_str(&json).map_err(|_| CoreError::InvalidMessage)?;
    if !matches!(w.v, 3 | 4)
        || !matches!(
            w.k.as_str(),
            "info" | "start" | "offer" | "confirm" | "finish" | "reject"
        )
        || !platform_valid(&w.t)
    {
        return Err(CoreError::InvalidMessage);
    }
    let decode = |s: String| B64.decode(s).map_err(|_| CoreError::InvalidMessage);
    Ok(RustPairingFrame {
        version: w.v,
        kind: w.k,
        session: decode(w.s)?,
        message: w.p.map(decode).transpose()?,
        name: w.d,
        proof: w.f.map(decode).transpose()?,
        pairing_mode: w.m,
        platform: w.t,
    })
}
unsafe extern "C" {
    fn na_spake_start(role: i32, code: *const u8, len: usize, message: *mut u8) -> *mut c_void;
    fn na_spake_finish(state: *mut c_void, peer: *const u8, key: *mut u8) -> i32;
    fn na_spake_free(state: *mut c_void);
}
struct Pake {
    state: *mut c_void,
    message: Vec<u8>,
}
// Each context is only accessed while its owning session mutex is held.
unsafe impl Send for Pake {}
impl Pake {
    fn new(code: &str, role: i32) -> Result<Self, CoreError> {
        if code.len() != 6 || !code.bytes().all(|c| c.is_ascii_digit()) {
            return Err(CoreError::WrongCode);
        }
        let mut message = vec![0; 32];
        let state =
            unsafe { na_spake_start(role, code.as_ptr(), code.len(), message.as_mut_ptr()) };
        if state.is_null() {
            return Err(CoreError::CryptoFailed);
        }
        Ok(Self { state, message })
    }
    fn finish(&mut self, peer: &[u8]) -> Result<Vec<u8>, CoreError> {
        if peer.len() != 32 || self.state.is_null() {
            return Err(CoreError::InvalidMessage);
        }
        let mut key = vec![0; 64];
        let ok = unsafe { na_spake_finish(self.state, peer.as_ptr(), key.as_mut_ptr()) };
        unsafe { na_spake_free(self.state) }
        self.state = std::ptr::null_mut();
        if ok == 1 {
            Ok(key)
        } else {
            Err(CoreError::InvalidMessage)
        }
    }
}
impl Drop for Pake {
    fn drop(&mut self) {
        if !self.state.is_null() {
            unsafe { na_spake_free(self.state) }
        }
    }
}
struct Keys {
    control: Vec<u8>,
    proof: Vec<u8>,
    hash: Vec<u8>,
}
fn derive(
    secret: &[u8],
    session: &[u8],
    iname: &str,
    rname: &str,
    imsg: &[u8],
    rmsg: &[u8],
    ip: &Option<String>,
    rp: &Option<String>,
) -> Keys {
    let domain = if ip.is_some() {
        "Shenglin-SPAKE2-v4"
    } else {
        "Shenglin-SPAKE2-v3"
    };
    let mut transcript = domain.as_bytes().to_vec();
    let mut fields = vec![session, iname.as_bytes(), rname.as_bytes()];
    if let (Some(i), Some(r)) = (ip, rp) {
        fields.extend([i.as_bytes(), r.as_bytes()])
    }
    fields.extend([imsg, rmsg]);
    for f in fields {
        transcript.extend((f.len() as u32).to_be_bytes());
        transcript.extend(f)
    }
    let hash = Sha256::digest(transcript).to_vec();
    let hk = hkdf::Hkdf::<Sha256>::new(Some(&hash), secret);
    let key = |purpose: &str| {
        let mut k = vec![0; 32];
        hk.expand(format!("{domain}/{purpose}").as_bytes(), &mut k)
            .unwrap();
        k
    };
    Keys {
        control: key("control"),
        proof: key("proof"),
        hash,
    }
}
fn proof(keys: &Keys, role: &str) -> Vec<u8> {
    mac(&keys.proof, &[role.as_bytes(), &keys.hash].concat())
}
#[uniffi::export]
pub fn pairing_code() -> Result<String, CoreError> {
    loop {
        let mut bytes = [0; 4];
        getrandom::getrandom(&mut bytes).map_err(|_| CoreError::CryptoFailed)?;
        let n = u32::from_ne_bytes(bytes);
        if n < 4_294_000_000 {
            return Ok(format!("{:06}", n % 1_000_000));
        }
    }
}
struct InitiatorState {
    pake: Pake,
    name: String,
    platform: Option<String>,
    session: Vec<u8>,
    deadline: f64,
    step: u8,
    keys: Option<Keys>,
    peer_name: Option<String>,
    peer_platform: Option<String>,
}
#[derive(uniffi::Object)]
pub struct RustPairingInitiator {
    state: Mutex<InitiatorState>,
}
#[uniffi::export]
impl RustPairingInitiator {
    #[uniffi::constructor]
    pub fn new(
        code: String,
        name: String,
        platform: Option<String>,
        now: f64,
    ) -> Result<Self, CoreError> {
        if !platform_valid(&platform) || !now.is_finite() {
            return Err(CoreError::InvalidMessage);
        }
        let name = clean_name(&name, &display(&platform, "Mac"), 24, 24, true);
        let pake = Pake::new(&code, 0)?;
        let mut session = vec![0; 16];
        getrandom::getrandom(&mut session).map_err(|_| CoreError::CryptoFailed)?;
        Ok(Self {
            state: Mutex::new(InitiatorState {
                pake,
                name,
                platform,
                session,
                deadline: now + 90.,
                step: 0,
                keys: None,
                peer_name: None,
                peer_platform: None,
            }),
        })
    }
    pub fn session(&self) -> Vec<u8> {
        self.state.lock().unwrap().session.clone()
    }
    pub fn peer_name(&self) -> Option<String> {
        self.state.lock().unwrap().peer_name.clone()
    }
    pub fn peer_platform(&self) -> Option<String> {
        self.state.lock().unwrap().peer_platform.clone()
    }
    pub fn start_frame(&self) -> RustPairingFrame {
        let s = self.state.lock().unwrap();
        let mut f = RustPairingFrame::new(
            "start",
            if s.platform.is_some() { 4 } else { 3 },
            s.session.clone(),
        );
        f.message = Some(s.pake.message.clone());
        f.name = Some(s.name.clone());
        f.platform = s.platform.clone();
        f
    }
    pub fn receive_offer(
        &self,
        frame: RustPairingFrame,
        now: f64,
    ) -> Result<RustPairingFrame, CoreError> {
        let mut s = self.state.lock().unwrap();
        if s.step != 0 {
            return Err(CoreError::WrongStep);
        }
        check(
            &frame,
            "offer",
            if s.platform.is_some() { 4 } else { 3 },
            &s.session,
            s.deadline,
            now,
        )?;
        let name = valid_pair_name(&frame.name)?;
        if !platform_valid(&frame.platform) || (s.platform.is_some() && frame.platform.is_none()) {
            return Err(CoreError::InvalidMessage);
        }
        let message = frame.message.ok_or(CoreError::InvalidMessage)?;
        let secret = s.pake.finish(&message)?;
        let keys = derive(
            &secret,
            &s.session,
            &s.name,
            &name,
            &s.pake.message,
            &message,
            &s.platform,
            &frame.platform,
        );
        let mut f = RustPairingFrame::new("confirm", frame.version, s.session.clone());
        f.proof = Some(proof(&keys, "initiator-confirm"));
        s.keys = Some(keys);
        s.peer_name = Some(name);
        s.peer_platform = frame.platform;
        s.step = 1;
        Ok(f)
    }
    pub fn receive_finish(&self, frame: RustPairingFrame, now: f64) -> Result<Vec<u8>, CoreError> {
        let mut s = self.state.lock().unwrap();
        if s.step != 1 {
            return Err(CoreError::WrongStep);
        }
        check(
            &frame,
            "finish",
            if s.platform.is_some() { 4 } else { 3 },
            &s.session,
            s.deadline,
            now,
        )?;
        let keys = s.keys.as_ref().ok_or(CoreError::WrongStep)?;
        if !frame
            .proof
            .is_some_and(|p| bool::from(p.ct_eq(&proof(keys, "responder-confirm"))))
        {
            return Err(CoreError::WrongCode);
        }
        let key = keys.control.clone();
        s.step = 2;
        Ok(key)
    }
}
fn check(
    f: &RustPairingFrame,
    kind: &str,
    version: i32,
    session: &[u8],
    deadline: f64,
    now: f64,
) -> Result<(), CoreError> {
    if !now.is_finite() || now >= deadline {
        return Err(CoreError::Expired);
    }
    if f.version != version || f.kind != kind {
        return Err(CoreError::InvalidMessage);
    }
    if f.session != session {
        return Err(CoreError::WrongSession);
    }
    Ok(())
}
struct ResponderState {
    keys: Keys,
    offer: RustPairingFrame,
    peer_platform: Option<String>,
    deadline: f64,
    finished: bool,
}
#[derive(uniffi::Object)]
pub struct RustPairingResponder {
    state: Mutex<ResponderState>,
}
#[uniffi::export]
impl RustPairingResponder {
    #[uniffi::constructor]
    pub fn new(
        start: RustPairingFrame,
        code: String,
        name: String,
        fallback_name: String,
        platform: Option<String>,
        now: f64,
    ) -> Result<Self, CoreError> {
        let version = if platform.is_some() { 4 } else { 3 };
        if !now.is_finite()
            || !platform_valid(&platform)
            || !platform_valid(&start.platform)
            || (platform.is_some() && start.platform.is_none())
            || start.version != version
            || start.kind != "start"
            || start.session.len() != 16
        {
            return Err(CoreError::InvalidMessage);
        }
        let iname = valid_pair_name(&start.name)?;
        let message = start.message.ok_or(CoreError::InvalidMessage)?;
        let name = clean_name(&name, &display(&platform, &fallback_name), 24, 24, true);
        let mut pake = Pake::new(&code, 1)?;
        let secret = pake.finish(&message)?;
        let keys = derive(
            &secret,
            &start.session,
            &iname,
            &name,
            &message,
            &pake.message,
            &if platform.is_some() {
                start.platform.clone()
            } else {
                None
            },
            &platform,
        );
        let mut offer = RustPairingFrame::new("offer", version, start.session);
        offer.name = Some(name);
        offer.message = Some(pake.message.clone());
        offer.platform = platform;
        Ok(Self {
            state: Mutex::new(ResponderState {
                keys,
                offer,
                peer_platform: start.platform,
                deadline: now + 90.,
                finished: false,
            }),
        })
    }
    pub fn offer_frame(&self) -> RustPairingFrame {
        self.state.lock().unwrap().offer.clone()
    }
    pub fn session(&self) -> Vec<u8> {
        self.state.lock().unwrap().offer.session.clone()
    }
    pub fn peer_platform(&self) -> Option<String> {
        self.state.lock().unwrap().peer_platform.clone()
    }
    pub fn confirmed_key(&self) -> Option<Vec<u8>> {
        let s = self.state.lock().unwrap();
        s.finished.then(|| s.keys.control.clone())
    }
    pub fn receive_confirm(
        &self,
        frame: RustPairingFrame,
        now: f64,
    ) -> Result<RustPairingFrame, CoreError> {
        let mut s = self.state.lock().unwrap();
        if s.finished {
            return Err(CoreError::WrongStep);
        }
        check(
            &frame,
            "confirm",
            s.offer.version,
            &s.offer.session,
            s.deadline,
            now,
        )?;
        if !frame
            .proof
            .is_some_and(|p| bool::from(p.ct_eq(&proof(&s.keys, "initiator-confirm"))))
        {
            return Err(CoreError::WrongCode);
        }
        s.finished = true;
        let mut f = RustPairingFrame::new("finish", s.offer.version, s.offer.session.clone());
        f.proof = Some(proof(&s.keys, "responder-confirm"));
        Ok(f)
    }
}
