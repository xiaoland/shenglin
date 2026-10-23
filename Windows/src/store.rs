use anyhow::{bail, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    path::{Path, PathBuf},
};
use windows::Win32::{
    Foundation::{LocalFree, HLOCAL},
    Security::Cryptography::*,
};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Peer {
    pub key: Vec<u8>,
    pub name: String,
    pub platform: String,
    pub role: String,
    pub pending_until: Option<i64>,
    #[serde(default)]
    pub sources: Vec<String>,
}
impl Peer {
    pub fn id(&self) -> String {
        shenglin_core::service_name(self.key.clone())
    }
    pub fn remote_role(&self) -> &str {
        if self.role == "initiator" {
            "responder"
        } else {
            "initiator"
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub name: String,
    pub enabled: bool,
    pub gain: f32,
    pub network_scope: String,
    pub peers: Vec<Peer>,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            name: std::env::var("COMPUTERNAME").unwrap_or("Windows".into()),
            enabled: true,
            gain: 0.2,
            network_scope: "lan".into(),
            peers: vec![],
        }
    }
}
#[derive(Clone)]
pub struct Store(pub PathBuf);
impl Store {
    pub fn new(path: PathBuf) -> Result<Self> {
        fs::create_dir_all(&path)?;
        private_acl(&path)?;
        let settings = path.join("settings.bin");
        if settings.exists() {
            private_acl(&settings)?;
        }
        Ok(Self(path))
    }
    fn lock(&self, name: &str) -> Result<File> {
        let f = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(self.0.join(name))?;
        f.lock_exclusive()?;
        Ok(f)
    }
    pub fn run_lock(&self) -> Result<File> {
        let f = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(self.0.join("run.lock"))?;
        f.try_lock_exclusive()
            .map_err(|_| anyhow::anyhow!("声邻服务已在运行"))?;
        Ok(f)
    }
    pub fn is_running(&self) -> Result<bool> {
        let f = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(self.0.join("run.lock"))?;
        match f.try_lock_exclusive() {
            Ok(()) => Ok(false),
            Err(e) if e.raw_os_error() == fs2::lock_contended_error().raw_os_error() => Ok(true),
            Err(e) => Err(e.into()),
        }
    }
    pub fn load(&self) -> Result<Config> {
        let _lock = self.lock("config.lock")?;
        self.load_unlocked()
    }
    fn load_unlocked(&self) -> Result<Config> {
        let path = self.0.join("settings.bin");
        if !path.exists() {
            return Ok(Config::default());
        }
        let c: Config = serde_json::from_slice(&protect(fs::read(path)?, false)?)?;
        if c.peers.len() > 32
            || !c.gain.is_finite()
            || !(0.0..=0.5).contains(&c.gain)
            || !matches!(c.network_scope.as_str(), "wifi" | "lan")
            || c.peers
                .iter()
                .any(|p| p.key.len() != 32 || !matches!(p.role.as_str(), "initiator" | "responder"))
        {
            bail!("配置无效");
        }
        Ok(c)
    }
    pub fn change(&self, change: impl FnOnce(&mut Config) -> Result<()>) -> Result<()> {
        let _lock = self.lock("config.lock")?;
        let mut c = self.load_unlocked()?;
        change(&mut c)?;
        atomic(
            &self.0.join("settings.bin"),
            &protect(serde_json::to_vec(&c)?, true)?,
        )
    }
    pub fn stage(&self, peer: Peer) -> Result<()> {
        self.change(|c| {
            if c.peers.len() >= 32 {
                bail!("最多配对32台设备");
            }
            c.peers.retain(|p| p.key != peer.key);
            c.peers.push(peer);
            Ok(())
        })
    }
}
pub fn atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let temp = path.with_extension("tmp");
    {
        use std::io::Write;
        let mut f = File::create(&temp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::rename(temp, path)?;
    Ok(())
}
fn protect(mut bytes: Vec<u8>, encrypt: bool) -> Result<Vec<u8>> {
    let input = CRYPT_INTEGER_BLOB {
        cbData: bytes.len().try_into()?,
        pbData: bytes.as_mut_ptr(),
    };
    let mut output = CRYPT_INTEGER_BLOB::default();
    unsafe {
        if encrypt {
            CryptProtectData(
                &input,
                None,
                None,
                None,
                None,
                CRYPTPROTECT_LOCAL_MACHINE | CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )?;
        } else {
            CryptUnprotectData(
                &input,
                None,
                None,
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )?;
        }
        let data = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        LocalFree(Some(HLOCAL(output.pbData.cast())));
        Ok(data)
    }
}

// Machine DPAPI is shared by the service and administrator CLI; ACLs restrict decryption access.
fn private_acl(path: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows::{
        core::{w, PCWSTR},
        Win32::Security::{Authorization::*, *},
    };
    let path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    unsafe {
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            w!("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"),
            1,
            &mut descriptor,
            None,
        )?;
        let result = SetFileSecurityW(
            PCWSTR(path.as_ptr()),
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            descriptor,
        )
        .ok();
        LocalFree(Some(HLOCAL(descriptor.0)));
        result.map_err(|e| anyhow::anyhow!("无法保护数据目录；请使用管理员终端：{e}"))?;
    }
    Ok(())
}
