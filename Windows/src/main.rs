mod audio;
mod network;
mod peer;
mod store;
mod wire;
use anyhow::{bail, ensure, Result};
use peer::{Event, Live};
use serde::{Deserialize, Serialize};
use serde_json::json;
use shenglin_core::{DemandLedger, LedgerSnapshot};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Mutex,
    },
    time::{Duration, Instant},
};
use store::{atomic, Store};

fn main() {
    if let Err(e) = run() {
        eprintln!("声邻：{e:#}");
        std::process::exit(1);
    }
}
fn run() -> Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str).unwrap_or("help") {
        "help" | "--help" | "-h" => {
            println!("声邻 Windows {}\nserve | pair [设备名称 验证码] | discover | status | sources | networks\nshare|unshare <peer ID> <输入 ID> | remove <peer ID> | enabled on|off | scope lan|wifi | gain <0..0.5> | name <名称>\nprobe <输入 ID> <秒数> | version\n选项：--data <私有数据目录> --bind <本机物理网络 IPv4>", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        "version" | "--version" | "-V" => {
            println!("shenglin {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        _ => {}
    }
    wasapi::initialize_mta().ok()?;
    let directory = take_option(&mut args, "--data")?
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var("PROGRAMDATA").unwrap_or("C:\\ProgramData".into()))
                .join("Shenglin")
        });
    let bind = take_option(&mut args, "--bind")?;
    let command = args.first().map(String::as_str).unwrap_or("");
    if matches!(command, "sources" | "networks") {
        ensure!(args.len() == 1, "{command} 不接受额外参数");
        let value = if command == "sources" {
            serde_json::to_value(audio::sources()?)?
        } else {
            serde_json::to_value(network::networks()?)?
        };
        println!("{}", serde_json::to_string_pretty(&value)?);
        return Ok(());
    }
    let store = Store::new(directory)?;
    match command {
        "probe" => {
            ensure!(args.len() == 3, "用法：probe <输入 ID> <秒数>");
            let seconds: u64 = args[2].parse()?;
            ensure!((1..=60).contains(&seconds), "采样时长为1至60秒");
            println!("{}", audio::probe(&args[1], seconds)?);
        }
        "status" => print_status(&store)?,
        "share" | "unshare" => {
            ensure!(args.len() == 3, "用法：share|unshare <peer ID> <输入 ID>");
            if command == "share" {
                ensure!(
                    audio::sources()?.iter().any(|source| source.id == args[2]),
                    "输入不存在"
                );
            }
            store.change(|config| {
                let peer = config
                    .peers
                    .iter_mut()
                    .find(|peer| peer.id() == args[1] && peer.pending_until.is_none())
                    .ok_or_else(|| anyhow::anyhow!("已激活的 peer 不存在"))?;
                peer.sources.retain(|source| source != &args[2]);
                if command == "share" {
                    peer.sources.push(args[2].clone());
                }
                Ok(())
            })?;
            println!("共享授权已更新");
        }
        "remove" => {
            ensure!(args.len() == 2, "用法：remove <peer ID>");
            store.change(|config| {
                ensure!(
                    config.peers.iter().any(|peer| peer.id() == args[1]),
                    "peer 不存在"
                );
                config.peers.retain(|peer| peer.id() != args[1]);
                Ok(())
            })?;
        }
        "enabled" => {
            ensure!(
                args.len() == 2 && matches!(args[1].as_str(), "on" | "off"),
                "用法：enabled on|off"
            );
            store.change(|config| {
                config.enabled = args[1] == "on";
                Ok(())
            })?;
        }
        "scope" => {
            ensure!(
                args.len() == 2 && matches!(args[1].as_str(), "lan" | "wifi"),
                "用法：scope lan|wifi"
            );
            store.change(|config| {
                config.network_scope = args[1].clone();
                Ok(())
            })?;
        }
        "gain" => {
            ensure!(args.len() == 2, "用法：gain <0..0.5>");
            let gain: f32 = args[1].parse()?;
            ensure!(
                gain.is_finite() && (0.0..=0.5).contains(&gain),
                "增益必须在0至0.5之间"
            );
            store.change(|config| {
                config.gain = gain;
                Ok(())
            })?;
        }
        "name" => {
            ensure!(
                args.len() == 2 && !args[1].trim().is_empty() && args[1].len() <= 24,
                "名称为1至24字节"
            );
            store.change(|config| {
                config.name = args[1].clone();
                Ok(())
            })?;
        }
        "serve" | "pair" | "discover" => {
            let networks = network::networks()?;
            let network = if let Some(bind) = bind {
                networks
                    .into_iter()
                    .find(|network| network.ip.to_string() == bind)
                    .ok_or_else(|| anyhow::anyhow!("--bind 必须为活动物理 Wi-Fi/以太网地址"))?
            } else {
                ensure!(
                    networks.len() == 1,
                    "存在零个或多个物理网络；用 networks 查看后指定 --bind"
                );
                networks.into_iter().next().unwrap()
            };
            if command == "serve" {
                serve(store, network)?;
            } else {
                let daemon = wire::daemon(network.ip)?;
                let result = (|| -> Result<()> {
                    if command == "discover" {
                        let candidates = wire::discover(&daemon, wire::PAIR_SERVICE, None, 5)?;
                        println!("{}", json!(candidates.iter().map(|(name, address)|
                            json!({"name": name, "address": address.to_string()})).collect::<Vec<_>>()));
                    } else {
                        let config = store.load()?;
                        let peer = if args.len() == 1 {
                            wire::pair_server(&daemon, network.ip, &config.name)?
                        } else {
                            ensure!(args.len() == 3, "用法：pair [设备名称 验证码]");
                            let candidates =
                                wire::discover(&daemon, wire::PAIR_SERVICE, Some(&args[1]), 8)?;
                            let address = candidates
                                .first()
                                .ok_or_else(|| anyhow::anyhow!("未发现配对设备"))?
                                .1;
                            wire::pair_client(network.ip, address, &config.name, &args[2])?
                        };
                        store.stage(peer.clone())?;
                        println!(
                            "{}",
                            json!({"paired": peer.id(), "name": peer.name, "pending": true})
                        );
                        println!("服务运行且完成双向认证后激活配对；用 status 查看结果。");
                    }
                    Ok(())
                })();
                daemon.shutdown()?;
                result?;
            }
        }
        _ => bail!("未知命令；运行 help 查看用法"),
    }
    Ok(())
}
fn print_status(store: &Store) -> Result<()> {
    let c = store.load()?;
    let path = store.0.join("status.json");
    let mut runtime = if path.exists() {
        serde_json::from_slice::<serde_json::Value>(&std::fs::read(path)?)?
    } else {
        json!({})
    };
    let running = store.is_running()?;
    runtime["running"] = json!(running);
    runtime["current"] = json!(
        running
            && runtime["updatedAt"]
                .as_i64()
                .is_some_and(|t| wire::now() - t <= 5)
    );
    println!(
        "{}",
        json!({"version":env!("CARGO_PKG_VERSION"),"name":c.name,"enabled":c.enabled,"gain":c.gain,"networkScope":c.network_scope,
        "peers":c.peers.iter().map(|p|json!({"id":p.id(),"name":p.name,"platform":p.platform,"pending":p.pending_until.is_some(),"sources":p.sources})).collect::<Vec<_>>(),"runtime":runtime})
    );
    Ok(())
}

fn take_option(args: &mut Vec<String>, name: &str) -> Result<Option<String>> {
    if let Some(i) = args.iter().position(|s| s == name) {
        ensure!(i + 1 < args.len(), "{name} 缺少值");
        args.remove(i);
        Ok(Some(args.remove(i)))
    } else {
        Ok(None)
    }
}

fn serve(store: Store, net: network::Network) -> Result<()> {
    let _lock = store.run_lock()?;
    let stop = Arc::new(AtomicBool::new(false));
    let ctrl = stop.clone();
    ctrlc::set_handler(move || ctrl.store(true, Ordering::Relaxed))?;
    let ledger = DemandLedger::new();
    let ledger_path = store.0.join("ledger.json");
    let initial = store.load()?;
    if ledger_path.exists() {
        restore_ledger(
            &ledger,
            serde_json::from_slice(&std::fs::read(&ledger_path)?)?,
            &initial,
            &net,
            wire::now(),
        );
    }
    let sequence_path = store.0.join("sequence.json");
    let revision = if sequence_path.exists() {
        serde_json::from_slice::<u64>(&std::fs::read(&sequence_path)?)?
    } else {
        0
    };
    // Reserve revisions durably before workers send; a killed process cannot reuse a revision.
    let reserved = revision
        .checked_add(1_000_000)
        .ok_or_else(|| anyhow::anyhow!("序号耗尽"))?;
    atomic(&sequence_path, &serde_json::to_vec(&reserved)?)?;
    let live = Arc::new(Mutex::new(Live {
        revision,
        ..Default::default()
    }));
    let mut volume = audio::Volume::new(store.clone())?;
    let (tx, rx) = mpsc::channel();
    let mut workers: HashMap<
        String,
        (
            Arc<AtomicBool>,
            Vec<std::thread::JoinHandle<()>>,
            Vec<String>,
        ),
    > = HashMap::new();
    let mut last_status = Instant::now() - Duration::from_secs(2);
    let mut old_scope = initial.network_scope;
    let mut old_enabled = initial.enabled;
    let mut retired = vec![];
    let mut saved_ledger = vec![];
    println!(
        "{}",
        json!({"serving":net.ip,"medium":net.medium,"pid":std::process::id()})
    );
    let result = (|| -> Result<()> {
        while !stop.load(Ordering::Relaxed) {
            let config = store.load()?;
            if old_scope != config.network_scope || old_enabled != config.enabled {
                ledger.stop_responding(None, wire::now());
                old_scope = config.network_scope.clone();
                old_enabled = config.enabled;
            }
            let ids: HashSet<_> = config
                .peers
                .iter()
                .filter(|p| p.pending_until.is_none_or(|t| t > wire::now()))
                .map(|p| p.id())
                .collect();
            let removed: Vec<_> = workers
                .keys()
                .filter(|id| !ids.contains(*id))
                .cloned()
                .collect();
            for id in removed {
                if let Some((flag, handles, _)) = workers.remove(&id) {
                    flag.store(true, Ordering::Relaxed);
                    retired.extend(handles);
                    ledger.stop_responding(Some(id.clone()), wire::now());
                    live.lock().unwrap().online.remove(&id);
                }
            }
            for p in &config.peers {
                if !ids.contains(&p.id()) {
                    continue;
                }
                if !workers.contains_key(&p.id()) {
                    let flag = Arc::new(AtomicBool::new(false));
                    let h = peer::spawn(
                        p.clone(),
                        net.clone(),
                        store.clone(),
                        live.clone(),
                        tx.clone(),
                        flag.clone(),
                    );
                    workers.insert(p.id(), (flag, vec![h], vec![]));
                }
                let (flag, handles, shared) = workers.get_mut(&p.id()).unwrap();
                if p.pending_until.is_none() && !p.sources.is_empty() && shared.is_empty() {
                    handles.push(peer::spawn_microphone(
                        p.clone(),
                        net.clone(),
                        store.clone(),
                        live.clone(),
                        flag.clone(),
                    ));
                    *shared = p.sources.clone();
                }
            }
            let observation = audio::recording_pids();
            let known = observation.is_ok();
            let pids = observation.as_ref().cloned().unwrap_or_default();
            {
                let mut l = live.lock().unwrap();
                l.known = known;
                l.quiet = config.enabled && !pids.is_empty();
                ensure!(l.revision < reserved, "序号预留已用尽，请重启服务");
            }
            let mut replies = vec![];
            while let Ok(event) = rx.try_recv() {
                match event {
                    Event::Verified(id, yes) => {
                        let mut l = live.lock().unwrap();
                        if yes {
                            l.online.insert(id);
                        } else {
                            l.online.remove(&id);
                        }
                    }
                    Event::Update(p, u, wifi, reply) => {
                        if accepts_update(&config, &p, wifi) {
                            ledger.accept(u, p.id(), p.remote_role().into(), p.key, wire::now());
                            replies.push(reply);
                        } else {
                            let _ = reply.send("paused".into());
                        }
                    }
                }
            }
            ledger.expire(wire::now());
            let demand =
                config.enabled && (ledger.active_count(wire::now()) > 0 || !pids.is_empty());
            let applied = volume.apply(demand, known, &pids, config.gain);
            let response = applied.as_ref().copied().unwrap_or("unavailable");
            for reply in replies {
                let _ = reply.send(response.to_string());
            }
            let snapshot = serde_json::to_vec(&PersistedLedger {
                snapshot: ledger.snapshot(),
                policy: Some(LedgerPolicy::new(&config, &net)),
            })?;
            if snapshot != saved_ledger {
                atomic(&ledger_path, &snapshot)?;
                saved_ledger = snapshot;
            }
            retired.retain(|h| !h.is_finished());
            if last_status.elapsed() >= Duration::from_secs(1) {
                ensure!(
                    network::networks()?
                        .iter()
                        .any(|n| n.ip == net.ip && n.medium == net.medium),
                    "所绑定物理网络已断开；等待服务重新发现网络"
                );
                let l = live.lock().unwrap();
                atomic(
                    &store.0.join("status.json"),
                    &serde_json::to_vec_pretty(
                        &json!({"pid":std::process::id(),"updatedAt":wire::now(),"known":known,"recordingPIDs":pids,"online":l.online,"microphoneStreams":l.streams,"remoteDemands":ledger.active_count(wire::now()),"volume":response,"error":applied.err().map(|e|e.to_string()).or_else(||observation.err().map(|e|e.to_string()))}),
                    )?,
                )?;
                last_status = Instant::now();
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        Ok(())
    })();
    let restored = volume.apply(false, true, &HashSet::new(), 1.0);
    for (_, (flag, _, _)) in &workers {
        flag.store(true, Ordering::Relaxed);
    }
    for (_, (_, handles, _)) in workers {
        for h in handles {
            let _ = h.join();
        }
    }
    for h in retired {
        let _ = h.join();
    }
    restored?;
    result
}

#[derive(Serialize, Deserialize, PartialEq)]
struct LedgerPolicy {
    enabled: bool,
    scope: String,
    ip: std::net::Ipv4Addr,
    medium: String,
}
impl LedgerPolicy {
    fn new(config: &store::Config, net: &network::Network) -> Self {
        Self {
            enabled: config.enabled,
            scope: config.network_scope.clone(),
            ip: net.ip,
            medium: net.medium.clone(),
        }
    }
}
#[derive(Serialize, Deserialize)]
struct PersistedLedger {
    #[serde(flatten)]
    snapshot: LedgerSnapshot,
    #[serde(default)]
    policy: Option<LedgerPolicy>,
}
fn restore_ledger(
    ledger: &DemandLedger,
    mut saved: PersistedLedger,
    config: &store::Config,
    net: &network::Network,
    now: i64,
) {
    let same_policy = saved.policy.as_ref() == Some(&LedgerPolicy::new(config, net));
    let peers: HashSet<_> = config
        .peers
        .iter()
        .filter(|p| p.pending_until.is_none())
        .map(|p| p.id())
        .collect();
    for (id, record) in &mut saved.snapshot.records {
        if !same_policy || !peers.contains(id) {
            record.valid_until = None;
        }
    }
    ledger.restore(saved.snapshot, now);
}

fn accepts_update(config: &store::Config, peer: &store::Peer, wifi: bool) -> bool {
    config.enabled
        && (config.network_scope == "lan" || wifi)
        && config
            .peers
            .iter()
            .any(|p| p.key == peer.key && p.pending_until.is_none())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn restart_revalidates_offline_peer_removal_and_scope_changes() {
        let p = store::Peer {
            key: vec![7; 32],
            name: "test".into(),
            platform: "mac".into(),
            role: "initiator".into(),
            pending_until: None,
            sources: vec![],
        };
        let mut config = store::Config::default();
        config.peers.push(p.clone());
        let net = network::Network {
            ip: "192.168.1.2".parse().unwrap(),
            name: "test".into(),
            medium: "wifi".into(),
        };
        let snapshot = LedgerSnapshot {
            records: HashMap::from([(
                p.id(),
                shenglin_core::DemandRecord {
                    revision: 17,
                    valid_until: Some(120),
                },
            )]),
            manual_takeover: true,
        };
        let ledger = DemandLedger::new();
        let restore = |config: &store::Config| {
            restore_ledger(
                &ledger,
                PersistedLedger {
                    snapshot: snapshot.clone(),
                    policy: Some(LedgerPolicy::new(&store::Config::default(), &net)),
                },
                config,
                &net,
                100,
            )
        };
        restore(&config);
        assert_eq!(ledger.active_count(100), 1);
        assert!(ledger.snapshot().manual_takeover);
        config.peers.clear();
        restore(&config);
        assert_eq!(ledger.active_count(100), 0);
        assert_eq!(ledger.snapshot().records[&p.id()].revision, 17);
        config.peers.push(p);
        config.network_scope = "wifi".into();
        restore(&config);
        assert_eq!(ledger.active_count(100), 0);
    }
    #[test]
    fn queued_state_cannot_restore_removed_or_disallowed_relationship() {
        let p = store::Peer {
            key: vec![7; 32],
            name: "test".into(),
            platform: "mac".into(),
            role: "initiator".into(),
            pending_until: None,
            sources: vec![],
        };
        let mut c = store::Config::default();
        c.peers.push(p.clone());
        assert!(accepts_update(&c, &p, false));
        c.peers.clear();
        assert!(!accepts_update(&c, &p, true));
        c.peers.push(p.clone());
        c.network_scope = "wifi".into();
        assert!(!accepts_update(&c, &p, false));
        assert!(accepts_update(&c, &p, true));
        c.enabled = false;
        assert!(!accepts_update(&c, &p, true));
    }
}
