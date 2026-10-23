use super::{mac, CoreError};
use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};

const DOMAIN: &[u8] = b"Shenglin-Microphone-v1";
pub const AUDIO_MAX_PLAINTEXT: usize = 16_384;

/// Each direction uses its pairing role, independently of which peer captures audio.
#[uniffi::export]
pub fn audio_session_key(
    key: Vec<u8>,
    server_nonce: Vec<u8>,
    client_nonce: Vec<u8>,
    role: String,
) -> Result<Vec<u8>, CoreError> {
    if key.len() != 32
        || server_nonce.len() != 32
        || client_nonce.len() != 32
        || !matches!(role.as_str(), "initiator" | "responder")
    {
        return Err(CoreError::InvalidMessage);
    }
    let mut context = DOMAIN.to_vec();
    context.extend_from_slice(&server_nonce);
    context.extend_from_slice(&client_nonce);
    context.extend_from_slice(role.as_bytes());
    Ok(mac(&key, &context))
}

fn nonce(sequence: u64) -> [u8; 12] {
    let mut nonce = [0; 12];
    nonce[4..].copy_from_slice(&sequence.to_be_bytes());
    nonce
}

#[uniffi::export]
pub fn audio_seal(key: Vec<u8>, sequence: u64, plaintext: Vec<u8>) -> Result<Vec<u8>, CoreError> {
    if plaintext.is_empty() || plaintext.len() > AUDIO_MAX_PLAINTEXT || sequence == u64::MAX {
        return Err(CoreError::InvalidMessage);
    }
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CoreError::InvalidMessage)?;
    cipher
        .encrypt(
            Nonce::from_slice(&nonce(sequence)),
            Payload {
                msg: &plaintext,
                aad: DOMAIN,
            },
        )
        .map_err(|_| CoreError::CryptoFailed)
}

#[uniffi::export]
pub fn audio_open(key: Vec<u8>, sequence: u64, ciphertext: Vec<u8>) -> Result<Vec<u8>, CoreError> {
    if ciphertext.len() <= 16 || ciphertext.len() > AUDIO_MAX_PLAINTEXT + 16 || sequence == u64::MAX
    {
        return Err(CoreError::InvalidMessage);
    }
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|_| CoreError::InvalidMessage)?;
    cipher
        .decrypt(
            Nonce::from_slice(&nonce(sequence)),
            Payload {
                msg: &ciphertext,
                aad: DOMAIN,
            },
        )
        .map_err(|_| CoreError::CryptoFailed)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn records_bind_session_direction_sequence_and_contents() {
        let key =
            audio_session_key(vec![7; 32], vec![1; 32], vec![2; 32], "initiator".into()).unwrap();
        let other =
            audio_session_key(vec![7; 32], vec![1; 32], vec![2; 32], "responder".into()).unwrap();
        let record = audio_seal(key.clone(), 0, b"microphone".to_vec()).unwrap();
        assert_eq!(
            audio_open(key.clone(), 0, record.clone()).unwrap(),
            b"microphone"
        );
        assert!(audio_open(other, 0, record.clone()).is_err());
        assert!(audio_open(key.clone(), 1, record.clone()).is_err());
        let fresh =
            audio_session_key(vec![7; 32], vec![3; 32], vec![2; 32], "initiator".into()).unwrap();
        assert!(audio_open(fresh, 0, record.clone()).is_err());
        let mut corrupt = record;
        corrupt[0] ^= 1;
        assert!(audio_open(key.clone(), 0, corrupt).is_err());
        assert!(audio_seal(key, 0, vec![0; AUDIO_MAX_PLAINTEXT + 1]).is_err());
    }
}
