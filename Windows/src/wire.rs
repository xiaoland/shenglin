use crate::store::Peer;
use anyhow::{bail, ensure, Result};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use mdns_sd::{IfKind, ServiceDaemon, ServiceEvent, ServiceInfo};
use serde_json::{json, Value};
use shenglin_core::*;
use std::{
    io::{Read, Write},
    net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub const PAIR_SERVICE: &str = "_shenglin-pair4._tcp.local.";
pub const STATE_SERVICE: &str = "_shenglin._tcp.local.";
pub const MIC_SERVICE: &str = "_shenglin-mic._tcp.local.";
pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}
pub fn random(n: usize) -> Vec<u8> {
    let mut b = vec![0; n];
    getrandom::getrandom(&mut b).expect("系统随机数不可用");
    b
}
pub fn nonce() -> String {
    B64.encode(random(16))
}
pub fn setup(s: &TcpStream) -> Result<()> {
    s.set_nonblocking(false)?;
    s.set_nodelay(true)?;
    s.set_read_timeout(Some(Duration::from_secs(8)))?;
    s.set_write_timeout(Some(Duration::from_secs(2)))?;
    Ok(())
}
pub fn line(s: &mut TcpStream, max: usize) -> Result<String> {
    let mut data = Vec::new();
    let mut b = [0];
    let deadline = Instant::now() + Duration::from_secs(8);
    while data.len() <= max {
        read_before(s, &mut b, deadline)?;
        if b[0] == 10 {
            return Ok(String::from_utf8(data)?);
        }
        data.push(b[0]);
    }
    bail!("网络消息过长")
}
fn read_before(s: &mut TcpStream, mut bytes: &mut [u8], deadline: Instant) -> Result<()> {
    while !bytes.is_empty() {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| anyhow::anyhow!("网络操作超时"))?;
        s.set_read_timeout(Some(remaining))?;
        let n = s.read(bytes)?;
        ensure!(n > 0, "连接已关闭");
        bytes = &mut bytes[n..];
    }
    Ok(())
}
pub fn send(s: &mut TcpStream, v: &Value) -> Result<()> {
    let mut b = serde_json::to_vec(v)?;
    ensure!(b.len() <= 1024, "控制消息过长");
    b.push(10);
    s.write_all(&b)?;
    Ok(())
}
pub fn receive(s: &mut TcpStream) -> Result<Value> {
    Ok(serde_json::from_str(&line(s, 1024)?)?)
}

pub fn daemon(ip: Ipv4Addr) -> Result<ServiceDaemon> {
    let d = ServiceDaemon::new()?;
    d.disable_interface(IfKind::All)?;
    d.enable_interface(IfKind::Addr(ip.into()))?;
    Ok(d)
}
pub fn advertise(
    d: &ServiceDaemon,
    ip: Ipv4Addr,
    kind: &str,
    name: &str,
    port: u16,
) -> Result<String> {
    let host = format!("shenglin-{}.local.", ip.to_string().replace('.', "-"));
    let info = ServiceInfo::new(kind, name, &host, ip.to_string().as_str(), port, None)?;
    let full = info.get_fullname().to_owned();
    d.register(info)?;
    Ok(full)
}
pub fn discover(
    d: &ServiceDaemon,
    kind: &str,
    name: Option<&str>,
    seconds: u64,
) -> Result<Vec<(String, SocketAddr)>> {
    let rx = d.browse(kind)?;
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut found = vec![];
    while Instant::now() < deadline {
        if let Ok(ServiceEvent::ServiceResolved(info)) = rx.recv_timeout(Duration::from_millis(200))
        {
            let instance = info
                .get_fullname()
                .strip_suffix(&format!(".{kind}"))
                .unwrap_or(info.get_fullname())
                .to_owned();
            if name.is_none_or(|n| n == instance) {
                for ip in info.get_addresses_v4() {
                    let item = (
                        instance.clone(),
                        SocketAddr::new(ip.into(), info.get_port()),
                    );
                    if !found.contains(&item) {
                        found.push(item);
                    }
                }
                if name.is_some() && !found.is_empty() {
                    break;
                }
            }
        }
    }
    d.stop_browse(kind)?;
    Ok(found)
}
pub fn pair_server(d: &ServiceDaemon, ip: Ipv4Addr, name: &str) -> Result<Peer> {
    let listener = TcpListener::bind((ip, 0))?;
    listener.set_nonblocking(true)?;
    let full = advertise(d, ip, PAIR_SERVICE, name, listener.local_addr()?.port())?;
    let code = pairing_code()?;
    println!(
        "{}",
        json!({"code":code,"name":name,"port":listener.local_addr()?.port(),"expiresIn":120})
    );
    let deadline = Instant::now() + Duration::from_secs(120);
    let mut attempts = 0;
    let result = (|| {
        while Instant::now() < deadline && attempts < 3 {
            match listener.accept() {
                Ok((mut s, _)) => {
                    attempts += 1;
                    setup(&s)?;
                    let attempt: Result<Peer> = (|| {
                        let start = decode_pairing(line(&mut s, 1024)?)?;
                        let peer_name = start.name.clone().unwrap_or("设备".into());
                        let responder = RustPairingResponder::new(
                            start,
                            code.clone(),
                            name.into(),
                            "Windows".into(),
                            Some("windows".into()),
                            now() as f64,
                        )?;
                        writeln!(s, "{}", encode_pairing(responder.offer_frame()))?;
                        let finish = responder
                            .receive_confirm(decode_pairing(line(&mut s, 1024)?)?, now() as f64)?;
                        let peer = Peer {
                            key: responder
                                .confirmed_key()
                                .ok_or_else(|| anyhow::anyhow!("配对未确认"))?,
                            name: peer_name,
                            platform: responder.peer_platform().unwrap(),
                            role: "responder".into(),
                            pending_until: Some(now() + 300),
                            sources: vec![],
                        };
                        writeln!(s, "{}", encode_pairing(finish))?;
                        Ok(peer)
                    })();
                    match attempt {
                        Ok(p) => return Ok(p),
                        Err(e) => eprintln!("配对失败：{e}"),
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(100))
                }
                Err(e) => return Err(e.into()),
            }
        }
        bail!("配对超时或尝试次数用尽")
    })();
    d.unregister(&full)?;
    result
}
pub fn connect_from(ip: Ipv4Addr, addr: SocketAddr) -> Result<TcpStream> {
    let socket = socket2::Socket::new(
        socket2::Domain::IPV4,
        socket2::Type::STREAM,
        Some(socket2::Protocol::TCP),
    )?;
    socket.bind(&SocketAddr::new(ip.into(), 0).into())?;
    socket.connect_timeout(&addr.into(), Duration::from_secs(3))?;
    Ok(socket.into())
}
pub fn pair_client(ip: Ipv4Addr, addr: SocketAddr, name: &str, code: &str) -> Result<Peer> {
    let mut s = connect_from(ip, addr)?;
    setup(&s)?;
    let p = RustPairingInitiator::new(
        code.into(),
        name.into(),
        Some("windows".into()),
        now() as f64,
    )?;
    writeln!(s, "{}", encode_pairing(p.start_frame()))?;
    let confirm = p.receive_offer(decode_pairing(line(&mut s, 1024)?)?, now() as f64)?;
    writeln!(s, "{}", encode_pairing(confirm))?;
    let key = p.receive_finish(decode_pairing(line(&mut s, 1024)?)?, now() as f64)?;
    Ok(Peer {
        key,
        name: p.peer_name().unwrap_or("设备".into()),
        platform: p.peer_platform().unwrap(),
        role: "initiator".into(),
        pending_until: Some(now() + 300),
        sources: vec![],
    })
}

pub struct AudioWire {
    pub stream: TcpStream,
    tx: Vec<u8>,
    rx: Vec<u8>,
    sent: u64,
    received: u64,
}
impl AudioWire {
    pub fn accept(mut stream: TcpStream, p: &Peer) -> Result<Self> {
        setup(&stream)?;
        let server = random(32);
        send(
            &mut stream,
            &json!({"version":1,"nonce":B64.encode(&server)}),
        )?;
        let open = receive(&mut stream)?;
        let client = B64.decode(open["nonce"].as_str().unwrap_or(""))?;
        let rx = audio_session_key(
            p.key.clone(),
            server.clone(),
            client.clone(),
            p.remote_role().into(),
        )?;
        let tx = audio_session_key(p.key.clone(), server, client, p.role.clone())?;
        ensure!(
            authentication_matches(
                open["proof"].as_str().unwrap_or("").into(),
                authentication_sign("microphone-open|1".into(), rx.clone())
            ),
            "麦克风认证失败"
        );
        send(
            &mut stream,
            &json!({"proof":authentication_sign("microphone-ready|1".into(),tx.clone())}),
        )?;
        Ok(Self {
            stream,
            tx,
            rx,
            sent: 0,
            received: 0,
        })
    }
    pub fn read(&mut self) -> Result<Vec<u8>> {
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut header = [0; 4];
        read_before(&mut self.stream, &mut header, deadline)?;
        let n = u32::from_be_bytes(header) as usize;
        ensure!(
            (17..=AUDIO_MAX_PLAINTEXT + 16).contains(&n),
            "音频帧长度无效"
        );
        let mut data = vec![0; n];
        read_before(&mut self.stream, &mut data, deadline)?;
        let plain = audio_open(self.rx.clone(), self.received, data)?;
        self.received += 1;
        Ok(plain)
    }
    pub fn write(&mut self, plain: Vec<u8>) -> Result<()> {
        let cipher = audio_seal(self.tx.clone(), self.sent, plain)?;
        self.stream
            .write_all(&(cipher.len() as u32).to_be_bytes())?;
        self.stream.write_all(&cipher)?;
        self.sent += 1;
        Ok(())
    }
    pub fn json(&mut self, v: Value) -> Result<()> {
        let mut data = vec![1];
        data.extend(serde_json::to_vec(&v)?);
        self.write(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn audio_handshake_rejects_an_unpaired_key() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let peer = Peer {
                key: vec![1; 32],
                name: "test".into(),
                platform: "mac".into(),
                role: "responder".into(),
                pending_until: None,
                sources: vec![],
            };
            assert!(AudioWire::accept(listener.accept().unwrap().0, &peer).is_err());
        });
        let mut client = connect_from("127.0.0.1".parse().unwrap(), address).unwrap();
        setup(&client).unwrap();
        let hello = receive(&mut client).unwrap();
        let server = B64.decode(hello["nonce"].as_str().unwrap()).unwrap();
        let nonce = vec![2; 32];
        let wrong =
            audio_session_key(vec![9; 32], server, nonce.clone(), "initiator".into()).unwrap();
        send(&mut client,&json!({"nonce":B64.encode(nonce),"proof":authentication_sign("microphone-open|1".into(),wrong)})).unwrap();
        assert!(receive(&mut client).is_err());
        worker.join().unwrap();
    }

    #[test]
    fn partial_reads_cannot_extend_the_record_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let worker = thread::spawn(move || {
            for _ in 0..12 {
                if client.write_all(&[1]).is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(30));
            }
        });
        let mut server = listener.accept().unwrap().0;
        let start = Instant::now();
        assert!(read_before(
            &mut server,
            &mut [0; 12],
            start + Duration::from_millis(150)
        )
        .is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
        drop(server);
        worker.join().unwrap();
    }
}
