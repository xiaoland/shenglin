use std::{env, path::PathBuf};
fn main() {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .parent()
        .unwrap()
        .to_path_buf();
    let target = env::var("TARGET").unwrap();
    let default = if target.contains("windows") {
        "boringssl-windows"
    } else if target.contains("ios") {
        "boringssl-ios"
    } else {
        "boringssl-macos"
    };
    let lib = env::var("SHENGLIN_CRYPTO_LIB_DIR")
        .unwrap_or_else(|_| root.join("local").join(default).display().to_string());
    cc::Build::new()
        .file(root.join("NativePAKE/NativePAKE.c"))
        .include(root.join("NativePAKE/include"))
        .include(root.join("local/boringssl/include"))
        .compile("shenglin_pake");
    println!("cargo:rustc-link-search=native={lib}");
    println!("cargo:rustc-link-lib=static=crypto");
    if !target.contains("msvc") {
        println!(
            "cargo:rustc-link-lib={}",
            if target.contains("windows-gnu") {
                "static=c++"
            } else if target.contains("android") {
                "c++_static"
            } else {
                "c++"
            }
        );
    }
    println!("cargo:rerun-if-env-changed=SHENGLIN_CRYPTO_LIB_DIR");
    println!("cargo:rerun-if-changed=../NativePAKE/NativePAKE.c");
    println!("cargo:rerun-if-changed=../NativePAKE/include/NativePAKE.h");
    println!("cargo:rerun-if-changed={lib}/libcrypto.a");
}
