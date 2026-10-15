package local.shenglin.core

import java.util.Base64
import uniffi.shenglin_core.*

/** Encoding is platform-local; authentication and protocol domains live in Rust. */
object Crypto {
    @JvmStatic fun utf8(value: String) = value.toByteArray(Charsets.UTF_8)
    @JvmStatic fun base64(value: ByteArray) = Base64.getEncoder().encodeToString(value)
    @JvmStatic fun decode(value: String) = Base64.getDecoder().decode(value)
    @JvmStatic fun random(size: Int) = randomBytes(size.toUInt())
    @JvmStatic fun sha256(value: ByteArray) = uniffi.shenglin_core.sha256(value)
    @JvmStatic fun sign(message: String, key: ByteArray) = authenticationSign(message, key)
    @JvmStatic fun matches(supplied: String, expected: String) = authenticationMatches(supplied, expected)
    @JvmStatic fun wifiProof(role: String, nonce: String, key: ByteArray) = wifiProofSign(role, nonce, key)
    @JvmStatic fun validWifiProof(signature: String, role: String, nonce: String, key: ByteArray) = wifiProofValid(signature, role, nonce, key)
    @JvmStatic fun networkMediumProof(role: String, nonce: String, medium: String, key: ByteArray) = networkMediumProofSign(role, nonce, medium, key)
    @JvmStatic fun validNetworkMediumProof(signature: String?, role: String, nonce: String, medium: String?, key: ByteArray) = signature != null && medium != null && networkMediumProofValid(signature, role, nonce, medium, key)
    @JvmStatic fun serviceName(key: ByteArray) = uniffi.shenglin_core.serviceName(key)
}
