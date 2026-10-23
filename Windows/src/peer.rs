use crate::{
    network::Network,
    store::{Peer, Store},
    wire::*,
};
use anyhow::{ensure, Result};
use serde_json::{json, Value};
use shenglin_core::*;
use std::{
    collections::HashSet,
    io::Read,
    net::{TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::Sender,
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};

#[derive(Default)]
pub struct Live {
    pub known: bool,
    pub quiet: bool,
    pub revision: u64,
    pub online: HashSet<String>,
    pub streams: HashSet<String>,
}
pub enum Event {
    Update(Peer, PeerUpdate, bool, Sender<String>),
    Verified(String, bool),
}

fn handshake(s: &mut TcpStream, p: &Peer, medium: &str, stop: &AtomicBool) -> Result<bool> {
    setup(s)?;
    let ours = nonce();
    send(s, &json!({"kind":"challenge","nonce":ours}))?;
    let challenge = receive(s)?;
    ensure!(challenge["kind"] == "challenge", "认证步骤无效");
    ensure!(!stop.load(Ordering::Relaxed), "正在停止");
    let theirs = challenge["nonce"].as_str().unwrap_or("").to_string();
    // The core validator also enforces the challenge's 16-byte nonce.
    ensure!(
        wifi_proof_valid(
            wifi_proof_sign(p.role.clone(), theirs.clone(), p.key.clone()),
            p.role.clone(),
            theirs.clone(),
            p.key.clone()
        ),
        "挑战无效"
    );
    send(
        s,
        &json!({"kind":"proof","nonce":theirs,"signature":wifi_proof_sign(p.role.clone(),theirs.clone(),p.key.clone()),"medium":medium,"mediumSignature":network_medium_proof_sign(p.role.clone(),theirs,medium.into(),p.key.clone())?}),
    )?;
    let proof = receive(s)?;
    ensure!(!stop.load(Ordering::Relaxed), "正在停止");
    ensure!(
        proof["kind"] == "proof"
            && proof["nonce"] == ours
            && wifi_proof_valid(
                proof["signature"].as_str().unwrap_or("").into(),
                p.remote_role().into(),
                ours.clone(),
                p.key.clone()
            ),
        "设备认证失败"
    );
    let remote_medium = proof["medium"].as_str().unwrap_or("");
    let wifi = medium == "wifi"
        && remote_medium == "wifi"
        && network_medium_proof_valid(
            proof["mediumSignature"].as_str().unwrap_or("").into(),
            p.remote_role().into(),
            ours,
            remote_medium.into(),
            p.key.clone(),
        );
    send(s, &json!({"kind":"ready"}))?;
    ensure!(receive(s)?["kind"] == "ready", "认证未完成");
    Ok(wifi)
}
fn connected(
    mut s: TcpStream,
    p: &Peer,
    net: &Network,
    store: &Store,
    live: &Mutex<Live>,
    events: &Sender<Event>,
    stop: &AtomicBool,
) -> Result<()> {
    let wifi = handshake(&mut s, p, &net.medium, stop)?;
    store.change(|c| {
        if let Some(saved) = c.peers.iter_mut().find(|v| v.key == p.key) {
            saved.pending_until = None;
        }
        Ok(())
    })?;
    events.send(Event::Verified(p.id(), true))?;
    let result = (|| {
        s.set_read_timeout(Some(Duration::from_millis(250)))?;
        let mut buffer = vec![];
        let mut last_sent = Instant::now() - Duration::from_secs(5);
        let mut last_ack = Instant::now();
        let mut pending = HashSet::new();
        let mut last_name = String::new();
        let mut config = store.load()?;
        let mut refreshed = Instant::now();
        while !stop.load(Ordering::Relaxed) {
            if refreshed.elapsed() >= Duration::from_millis(500) {
                config = store.load()?;
                refreshed = Instant::now();
            }
            let allowed = config.enabled && (config.network_scope == "lan" || wifi);
            if last_sent.elapsed() >= Duration::from_secs(5) {
                let mut current = live.lock().unwrap();
                current.revision += 1;
                let update = sign_update(
                    p.role.clone(),
                    current.revision,
                    allowed && current.quiet,
                    current.known,
                    now() + 20,
                    None,
                    p.key.clone(),
                );
                pending.insert(update.revision);
                drop(current);
                send(&mut s, &json!({"kind":"update","update":update}))?;
                last_sent = Instant::now();
                if last_name != config.name {
                    send(
                        &mut s,
                        &json!({"kind":"name","name":sign_name(config.name.clone(),p.key.clone())}),
                    )?;
                    last_name = config.name.clone();
                }
            }
            ensure!(last_ack.elapsed() < Duration::from_secs(20), "设备回执超时");
            let mut b = [0];
            match s.read(&mut b) {
                Ok(0) => return Ok(()),
                Ok(_) => {
                    if b[0] != 10 {
                        buffer.push(b[0]);
                        ensure!(buffer.len() <= 1024, "状态帧过长");
                        continue;
                    }
                    let frame: Value = serde_json::from_slice(&buffer)?;
                    buffer.clear();
                    match frame["kind"].as_str() {
                        Some("name") => {
                            let claim: RustNameClaim =
                                serde_json::from_value(frame["name"].clone())?;
                            ensure!(valid_name(claim.clone(), p.key.clone()), "名称签名错误");
                            store.change(|c| {
                                if let Some(saved) = c.peers.iter_mut().find(|v| v.key == p.key) {
                                    saved.name = claim.name;
                                }
                                Ok(())
                            })?;
                        }
                        Some("update") => {
                            let u: PeerUpdate = serde_json::from_value(frame["update"].clone())?;
                            ensure!(
                                valid_update(
                                    u.clone(),
                                    p.key.clone(),
                                    p.remote_role().into(),
                                    now()
                                ),
                                "状态签名或租约无效"
                            );
                            let response = if allowed {
                                let (tx, rx) = std::sync::mpsc::channel();
                                events.send(Event::Update(p.clone(), u.clone(), wifi, tx))?;
                                rx.recv_timeout(Duration::from_secs(2))?
                            } else {
                                "paused".into()
                            };
                            send(
                                &mut s,
                                &json!({"kind":"ack","ack":sign_ack(p.role.clone(),u.revision,u.quiet,response,None,p.key.clone())}),
                            )?;
                        }
                        Some("ack") => {
                            let ack: PeerAck = serde_json::from_value(frame["ack"].clone())?;
                            ensure!(
                                valid_ack(ack.clone(), p.key.clone(), p.remote_role().into())
                                    && pending.remove(&ack.revision),
                                "回执无效"
                            );
                            last_ack = Instant::now();
                        }
                        _ => anyhow::bail!("状态消息类型无效"),
                    }
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    })();
    let _ = events.send(Event::Verified(p.id(), false));
    result
}

pub fn spawn(
    p: Peer,
    net: Network,
    store: Store,
    live: Arc<Mutex<Live>>,
    events: Sender<Event>,
    stop: Arc<AtomicBool>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let run = (|| -> Result<()> {
            let d = daemon(net.ip)?;
            let listener = if p.role == "initiator" {
                let l = TcpListener::bind((net.ip, 0))?;
                l.set_nonblocking(true)?;
                advertise(&d, net.ip, STATE_SERVICE, &p.id(), l.local_addr()?.port())?;
                Some(l)
            } else {
                None
            };
            while !stop.load(Ordering::Relaxed) {
                if p.pending_until.is_some_and(|deadline| deadline < now())
                    && store
                        .load()?
                        .peers
                        .iter()
                        .any(|v| v.key == p.key && v.pending_until.is_some())
                {
                    break;
                }
                let stream = if let Some(l) = &listener {
                    l.accept().ok().map(|(s, _)| s)
                } else {
                    discover(&d, STATE_SERVICE, Some(&p.id()), 2)?
                        .into_iter()
                        .find_map(|(_, addr)| connect_from(net.ip, addr).ok())
                };
                if let Some(s) = stream {
                    if let Err(e) = connected(s, &p, &net, &store, &live, &events, &stop) {
                        eprintln!("设备 {}：{e}", p.name);
                    }
                }
                thread::sleep(Duration::from_millis(500));
            }
            d.shutdown()?;
            Ok(())
        })();
        if let Err(e) = run {
            eprintln!("设备连接失败：{e}");
        }
    })
}

fn microphone_session(
    s: TcpStream,
    p: &Peer,
    store: &Store,
    live: &Mutex<Live>,
    busy: &Mutex<HashSet<String>>,
    stop: &AtomicBool,
) -> Result<()> {
    wasapi::initialize_mta().ok()?;
    let mut wire = AudioWire::accept(s, p)?;
    let data = wire.read()?;
    ensure!(data.first() == Some(&1), "麦克风请求无效");
    let request: Value = serde_json::from_slice(&data[1..])?;
    let config = store.load()?;
    let peer = config
        .peers
        .iter()
        .find(|v| v.key == p.key && v.pending_until.is_none())
        .ok_or_else(|| anyhow::anyhow!("配对未激活"))?;
    let sources = crate::audio::sources()?
        .into_iter()
        .filter(|s| peer.sources.contains(&s.id))
        .collect::<Vec<_>>();
    if request["operation"] == "list" {
        wire.json(json!({"sources":sources}))?;
        return Ok(());
    }
    ensure!(request["operation"] == "stream", "不支持的麦克风操作");
    let id = request["sourceID"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("缺少输入设备"))?;
    ensure!(sources.iter().any(|s| s.id == id), "此设备未授权共享");
    ensure!(
        busy.lock().unwrap().insert(id.to_string()),
        "此输入已在向该 peer 传输"
    );
    socket2::SockRef::from(&wire.stream).set_send_buffer_size(8192)?;
    wire.stream
        .set_write_timeout(Some(Duration::from_millis(300)))?;
    let stream_id = format!("{}|{}", p.id(), id);
    let result = (|| {
        wire.json(json!({"sampleRate":48000,"channels":1,"encoding":"f32le","packetFrames":960}))?;
        live.lock().unwrap().streams.insert(stream_id.clone());
        let mut checked = Instant::now();
        crate::audio::capture(id, |chunk| {
            if stop.load(Ordering::Relaxed) {
                return Ok(false);
            }
            if checked.elapsed() >= Duration::from_millis(250) {
                let c = store.load()?;
                if !c.peers.iter().any(|v| {
                    v.key == p.key && v.pending_until.is_none() && v.sources.iter().any(|s| s == id)
                }) {
                    return Ok(false);
                }
                checked = Instant::now();
            }
            let mut packet = vec![2];
            packet.extend(chunk);
            wire.write(packet)?;
            Ok(true)
        })
    })();
    live.lock().unwrap().streams.remove(&stream_id);
    busy.lock().unwrap().remove(id);
    result
}

pub fn spawn_microphone(
    p: Peer,
    net: Network,
    store: Store,
    live: Arc<Mutex<Live>>,
    stop: Arc<AtomicBool>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let run = (|| -> Result<()> {
            let d = daemon(net.ip)?;
            let listener = TcpListener::bind((net.ip, 0))?;
            listener.set_nonblocking(true)?;
            advertise(
                &d,
                net.ip,
                MIC_SERVICE,
                &format!("{}-{}", p.id(), p.role),
                listener.local_addr()?.port(),
            )?;
            let busy = Arc::new(Mutex::new(HashSet::new()));
            let mut sessions: Vec<(thread::JoinHandle<()>, TcpStream)> = vec![];
            while !stop.load(Ordering::Relaxed) {
                let mut i = 0;
                while i < sessions.len() {
                    if sessions[i].0.is_finished() {
                        let (h, _) = sessions.swap_remove(i);
                        let _ = h.join();
                    } else {
                        i += 1;
                    }
                }
                if let Ok((s, _)) = listener.accept() {
                    if sessions.len() < 8 {
                        let socket = s.try_clone()?;
                        let (p, store, live, busy, stop) = (
                            p.clone(),
                            store.clone(),
                            live.clone(),
                            busy.clone(),
                            stop.clone(),
                        );
                        let handle = thread::spawn(move || {
                            if let Err(e) = microphone_session(s, &p, &store, &live, &busy, &stop) {
                                eprintln!("麦克风 {}：{e}", p.name);
                            }
                        });
                        sessions.push((handle, socket));
                    }
                }
                thread::sleep(Duration::from_millis(50));
            }
            for (_, s) in &sessions {
                let _ = s.shutdown(std::net::Shutdown::Both);
            }
            for (h, _) in sessions {
                let _ = h.join();
            }
            d.shutdown()?;
            Ok(())
        })();
        if let Err(e) = run {
            eprintln!("麦克风共享失败：{e}");
        }
    })
}
