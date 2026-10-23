use anyhow::{ensure, Result};
use serde::Serialize;
use std::net::Ipv4Addr;
use windows::Win32::{
    NetworkManagement::{IpHelper::*, Ndis::IfOperStatusUp},
    Networking::WinSock::*,
};
#[derive(Clone, Serialize)]
pub struct Network {
    pub ip: Ipv4Addr,
    pub name: String,
    pub medium: String,
}
pub fn networks() -> Result<Vec<Network>> {
    unsafe {
        let mut size = 0u32;
        GetAdaptersAddresses(
            AF_INET.0 as u32,
            GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
            None,
            None,
            &mut size,
        );
        let mut buffer = vec![0u64; (size as usize + 7) / 8];
        let first = buffer.as_mut_ptr().cast::<IP_ADAPTER_ADDRESSES_LH>();
        let result = GetAdaptersAddresses(
            AF_INET.0 as u32,
            GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
            None,
            Some(first),
            &mut size,
        );
        ensure!(result == 0, "无法读取网络接口：{result}");
        let mut result = vec![];
        let mut adapter = first;
        while !adapter.is_null() {
            let a = &*adapter;
            let mut row = MIB_IF_ROW2::default();
            row.InterfaceLuid = a.Luid;
            if a.OperStatus == IfOperStatusUp
                && matches!(a.IfType, 6 | 71)
                && GetIfEntry2(&mut row).0 == 0
                && row.InterfaceAndOperStatusFlags._bitfield & 1 != 0
            {
                let mut address = a.FirstUnicastAddress;
                while !address.is_null() {
                    let socket = &*(*address).Address.lpSockaddr;
                    if socket.sa_family == AF_INET {
                        let addr = &*((*address).Address.lpSockaddr as *const SOCKADDR_IN);
                        let ip = Ipv4Addr::from(addr.sin_addr.S_un.S_addr.to_ne_bytes());
                        if !ip.is_link_local() {
                            result.push(Network {
                                ip,
                                name: a.FriendlyName.to_string()?,
                                medium: if a.IfType == 71 { "wifi" } else { "ethernet" }.into(),
                            });
                        }
                    }
                    address = (*address).Next;
                }
            }
            adapter = a.Next;
        }
        Ok(result)
    }
}
