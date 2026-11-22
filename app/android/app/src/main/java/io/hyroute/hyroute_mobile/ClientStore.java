package io.hyroute.hyroute_mobile;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.AtomicFile;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyStore;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class ClientStore {
    private static final String KEY_ALIAS = "hyroute.client-state.v1";
    private static final String KEY_STORE = "AndroidKeyStore";
    private static final String TRANSFORMATION = "AES/GCM/NoPadding";
    private static final int NONCE_LENGTH = 12;
    private static final int TAG_BITS = 128;

    private final AtomicFile file;

    ClientStore(File directory) {
        file = new AtomicFile(new File(directory, "client-state.v1"));
    }

    private SecretKey key(boolean create) throws IOException, GeneralSecurityException {
        KeyStore store = KeyStore.getInstance(KEY_STORE);
        store.load(null);
        SecretKey key = (SecretKey) store.getKey(KEY_ALIAS, null);
        if (key != null) return key;
        if (!create) throw new GeneralSecurityException("Missing state key");

        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEY_STORE);
        generator.init(new KeyGenParameterSpec.Builder(KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
        return generator.generateKey();
    }

    String read() throws IOException, GeneralSecurityException {
        byte[] content;
        try {
            content = file.readFully();
        } catch (FileNotFoundException e) {
            if (file.getBaseFile().exists()) throw e;
            return "";
        }
        if (content.length < NONCE_LENGTH + TAG_BITS / 8) {
            throw new IOException("Truncated client state");
        }
        Cipher cipher = Cipher.getInstance(TRANSFORMATION);
        cipher.init(Cipher.DECRYPT_MODE, key(false),
                new GCMParameterSpec(TAG_BITS, content, 0, NONCE_LENGTH));
        return new String(cipher.doFinal(content, NONCE_LENGTH, content.length - NONCE_LENGTH),
                StandardCharsets.UTF_8);
    }

    void write(String state) throws IOException, GeneralSecurityException {
        Cipher cipher = Cipher.getInstance(TRANSFORMATION);
        cipher.init(Cipher.ENCRYPT_MODE, key(true));
        byte[] nonce = cipher.getIV();
        if (nonce.length != NONCE_LENGTH) throw new GeneralSecurityException("Invalid state nonce");
        byte[] encrypted = cipher.doFinal(state.getBytes(StandardCharsets.UTF_8));
        byte[] content = Arrays.copyOf(nonce, NONCE_LENGTH + encrypted.length);
        System.arraycopy(encrypted, 0, content, NONCE_LENGTH, encrypted.length);
        FileOutputStream stream = file.startWrite();
        try {
            stream.write(content);
            stream.getFD().sync();
        } catch (IOException e) {
            file.failWrite(stream);
            throw e;
        }
        file.finishWrite(stream);
        if (!Arrays.equals(content, file.readFully())) throw new IOException("State commit failed");
    }
}
