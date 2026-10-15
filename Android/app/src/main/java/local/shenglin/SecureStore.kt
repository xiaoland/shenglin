package local.shenglin

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Keeps the existing encrypted format and alias so upgrades retain paired identities. */
class SecureStore(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "peers.enc"))
    private val key: SecretKey
    init {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "shenglin.peers.v1"
        if (!store.containsAlias(alias)) {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
                generateKey()
            }
        }
        key = store.getKey(alias, null) as SecretKey
    }
    @Synchronized fun read(): ByteArray? {
        val encoded = try { file.readFully() } catch (error: FileNotFoundException) {
            if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
            throw error
        }
        if (encoded.size < 28) throw IOException("配对记录损坏")
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, encoded, 0, 12))
            doFinal(encoded, 12, encoded.size - 12)
        }
    }
    @Synchronized fun write(value: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
        val encoded = cipher.iv + cipher.doFinal(value)
        val stream = file.startWrite()
        try { stream.write(encoded); file.finishWrite(stream) }
        catch (error: Exception) { file.failWrite(stream); throw error }
    }
}
