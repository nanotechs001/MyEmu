package com.myemu.speedpatcher;

import com.android.apksig.ApkSigner;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.zip.CRC32;
import java.util.zip.Deflater;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * Builds the patched Xerion: a copy of its APK whose engine (libCQ2ClientEn.so) loads our speed
 * library (libjnigraphicz.so, native/xerion_speed.c) in place of libjnigraphics.so (which ours loads
 * in turn), signed again with our key. Plain Java, no Android classes, so it can be tested on a PC.
 */
public final class XerionPatch {
    public static final String GAME = "com.com.Xerion";
    static final String ENGINE = "libCQ2ClientEn.so";
    static final String SPEED_LIB = "libjnigraphicz.so";
    private static final byte[] FROM = "libjnigraphics.so\0".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] TO = "libjnigraphicz.so\0".getBytes(StandardCharsets.US_ASCII);

    /** The patcher's own files: speed-&lt;abi&gt;.so, key.pk8 (PKCS#8 DER), cert.der (flat: Windows aapt2 writes \ in folders). */
    public interface Files { InputStream open(String name) throws IOException; }
    public interface Progress { void update(String text); }

    private XerionPatch() {}

    /** The patched Xerion keeps the game's package name: it replaces Xerion, which isn't then flagged as a clone. */
    public static void build(File source, File out, Files files, Progress progress) throws Exception {
        File unsigned = new File(out.getPath() + ".unsigned");
        try {
            rewrite(source, unsigned, files, progress);
            progress.update("Signing the patched Xerion…");
            sign(unsigned, out, files);
        } finally {
            unsigned.delete();
        }
    }

    public static boolean isPatched(File apk) throws IOException {
        try (ZipFile zip = new ZipFile(apk)) {
            return zip.stream().anyMatch(e -> e.getName().endsWith("/" + SPEED_LIB));
        }
    }

    /** True when apk carries this patcher's speed library and manifest edits; false for an older patcher's (or none). */
    public static boolean isCurrent(File apk, Files files) throws IOException {
        boolean any = false;
        try (ZipFile zip = new ZipFile(apk)) {
            for (ZipEntry entry : Collections.list(zip.entries())) {
                String name = entry.getName();
                if (!name.startsWith("lib/") || !name.endsWith("/" + SPEED_LIB)) continue;
                CRC32 crc = new CRC32();
                try (InputStream lib = files.open("speed-" + name.substring(4, name.lastIndexOf('/')) + ".so")) {
                    crc.update(read(lib));
                }
                if (crc.getValue() != entry.getCrc()) return false;
                any = true;
            }
            byte[] manifest = read(zip.getInputStream(zip.getEntry("AndroidManifest.xml")));
            if (AxmlEdit.allowPip(manifest) != manifest) return false; // patched before the drawer (no picture-in-picture)
        }
        return any;
    }

    private static void rewrite(File source, File out, Files files, Progress progress) throws IOException {
        Set<String> abis = new TreeSet<>();
        byte[] buffer = new byte[1 << 16];
        try (ZipFile in = new ZipFile(source);
             ZipOutputStream zip = new ZipOutputStream(new BufferedOutputStream(new FileOutputStream(out), 1 << 16))) {
            zip.setLevel(Deflater.BEST_SPEED); // ponytail: re-deflates every entry; raw copy if it's too slow
            List<? extends ZipEntry> entries = Collections.list(in.entries());
            for (int i = 0; i < entries.size(); i++) {
                ZipEntry entry = entries.get(i);
                String name = entry.getName();
                if (i % 50 == 0) progress.update("Copying Xerion… " + i * 100 / entries.size() + "%");
                if (isSignature(name) || name.endsWith("/" + SPEED_LIB)) continue;
                if (name.startsWith("lib/") && name.endsWith("/" + ENGINE)) {
                    abis.add(name.substring(4, name.lastIndexOf('/')));
                    byte[] engine = new byte[(int) entry.getSize()]; // 68 MB: exactly once, not a growing buffer
                    try (DataInputStream data = new DataInputStream(in.getInputStream(entry))) { data.readFully(engine); }
                    put(zip, name, patchEngine(engine, name), entry.getMethod());
                    continue;
                }
                if (name.equals("AndroidManifest.xml")) {
                    try (InputStream data = in.getInputStream(entry)) {
                        put(zip, name, AxmlEdit.allowPip(read(data)), entry.getMethod());
                    }
                    continue;
                }
                ZipEntry same = new ZipEntry(name);
                if (entry.getMethod() == ZipEntry.STORED) {
                    same.setMethod(ZipEntry.STORED);
                    same.setSize(entry.getSize());
                    same.setCompressedSize(entry.getSize());
                    same.setCrc(entry.getCrc());
                }
                zip.putNextEntry(same);
                try (InputStream data = in.getInputStream(entry)) {
                    for (int n; (n = data.read(buffer)) > 0; ) zip.write(buffer, 0, n);
                }
                zip.closeEntry();
            }
            if (abis.isEmpty()) throw new IOException("This isn't Xerion: " + ENGINE + " is missing.");
            for (String abi : abis) {
                try (InputStream lib = files.open("speed-" + abi + ".so")) {
                    put(zip, "lib/" + abi + "/" + SPEED_LIB, read(lib), ZipEntry.DEFLATED);
                }
            }
        }
    }

    // Swaps the one libjnigraphics.so the engine needs for ours (same length, so nothing moves).
    static byte[] patchEngine(byte[] engine, String name) throws IOException {
        int at = -1;
        for (int i = 0; i + FROM.length <= engine.length; i++) {
            if (!matches(engine, i)) continue;
            if (at >= 0) at = -2;
            if (at == -1) at = i;
        }
        if (at == -1 && contains(engine, TO)) return engine; // already patched (updating a patched Xerion's speed library)
        if (at < 0) throw new IOException("This Xerion version's engine (" + name + ") isn't one the patcher knows.");
        System.arraycopy(TO, 0, engine, at, TO.length);
        return engine;
    }

    private static boolean matches(byte[] data, int at) { return matches(data, at, FROM); }

    private static boolean matches(byte[] data, int at, byte[] what) {
        for (int j = 0; j < what.length; j++) if (data[at + j] != what[j]) return false;
        return true;
    }

    private static boolean contains(byte[] data, byte[] what) {
        for (int i = 0; i + what.length <= data.length; i++) if (matches(data, i, what)) return true;
        return false;
    }

    private static boolean isSignature(String name) {
        if (!name.startsWith("META-INF/")) return false;
        String upper = name.toUpperCase(java.util.Locale.ROOT);
        return upper.equals("META-INF/MANIFEST.MF") || upper.endsWith(".SF") || upper.endsWith(".RSA")
            || upper.endsWith(".DSA") || upper.endsWith(".EC");
    }

    private static void put(ZipOutputStream zip, String name, byte[] data, int method) throws IOException {
        ZipEntry entry = new ZipEntry(name);
        if (method == ZipEntry.STORED) {
            CRC32 crc = new CRC32();
            crc.update(data);
            entry.setMethod(ZipEntry.STORED);
            entry.setSize(data.length);
            entry.setCompressedSize(data.length);
            entry.setCrc(crc.getValue());
        }
        zip.putNextEntry(entry);
        zip.write(data);
        zip.closeEntry();
    }

    private static byte[] read(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[1 << 16];
        for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
        return out.toByteArray();
    }

    // apksig aligns the stored entries itself.
    private static void sign(File in, File out, Files files) throws Exception {
        PrivateKey key;
        X509Certificate cert;
        try (InputStream k = files.open("key.pk8"); InputStream c = files.open("cert.der")) {
            key = KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(read(k)));
            cert = (X509Certificate) CertificateFactory.getInstance("X.509").generateCertificate(c);
        }
        ApkSigner.SignerConfig signer =
            new ApkSigner.SignerConfig.Builder("MYEMU", key, Collections.singletonList(cert)).build();
        new ApkSigner.Builder(Collections.singletonList(signer))
            .setInputApk(in)
            .setOutputApk(out)
            .setV1SigningEnabled(true)
            .setV2SigningEnabled(true)
            .setV3SigningEnabled(true)
            .build()
            .sign();
    }
}
