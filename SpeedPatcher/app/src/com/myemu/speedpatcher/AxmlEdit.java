package com.myemu.speedpatcher;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Adds uses-permission SYSTEM_ALERT_WINDOW to Xerion's compiled (binary) AndroidManifest.xml: the
 * drawer's tab floats over other apps while the game is hidden. The permission's name goes to the
 * end of the string pool; nothing else moves.
 */
final class AxmlEdit {
    private static final int RES_XML = 0x0003, STRING_POOL = 0x0001, RESOURCE_MAP = 0x0180;
    private static final int START_ELEMENT = 0x0102, END_ELEMENT = 0x0103;
    private static final int UTF8 = 0x100;
    private static final int ATTR_NAME = 0x01010003;
    private static final int TYPE_STRING = 0x03;
    private static final String ANDROID = "http://schemas.android.com/apk/res/android";
    static final String OVERLAY = "android.permission.SYSTEM_ALERT_WINDOW";

    private AxmlEdit() {}

    static byte[] allowOverlay(byte[] manifest) throws IOException {
        ByteBuffer in = ByteBuffer.wrap(manifest).order(ByteOrder.LITTLE_ENDIAN);
        if (in.getShort(0) != RES_XML || in.getShort(8) != STRING_POOL) throw new IOException("unexpected manifest format");
        int poolSize = in.getInt(12);
        List<String> strings = readPool(in, 8);
        List<byte[]> chunks = new ArrayList<>();
        for (int at = 8 + poolSize; at < manifest.length; at += in.getInt(at + 4)) {
            byte[] chunk = new byte[in.getInt(at + 4)];
            System.arraycopy(manifest, at, chunk, 0, chunk.length);
            chunks.add(chunk);
        }
        int map = -1;
        for (int i = 0; i < chunks.size(); i++) if (type(chunks.get(i)) == RESOURCE_MAP) map = i;
        if (map < 0) throw new IOException("the manifest has no resource map");
        ByteBuffer m = le(chunks.get(map));
        int[] ids = new int[(m.capacity() - 8) / 4];
        for (int i = 0; i < ids.length; i++) ids[i] = m.getInt(8 + 4 * i);
        int ns = strings.indexOf(ANDROID);
        int usesPermission = strings.indexOf("uses-permission"), name = -1;
        for (int i = 0; i < ids.length; i++) if (ids[i] == ATTR_NAME) name = i;
        if (ns < 0 || usesPermission < 0 || name < 0) throw new IOException("unexpected manifest contents");

        boolean hasOverlay = false;
        int manifestElement = -1;
        for (int i = 0; i < chunks.size(); i++) {
            if (type(chunks.get(i)) != START_ELEMENT) continue;
            ByteBuffer c = le(chunks.get(i));
            String element = strings.get(c.getInt(20));
            if (element.equals("manifest")) manifestElement = i;
            int count = c.getShort(28) & 0xffff;
            if (element.equals("uses-permission")) {
                for (int a = 0; a < count; a++)
                    if (attrId(c, a, ids) == ATTR_NAME && (c.get(36 + 20 * a + 15) & 0xff) == TYPE_STRING
                            && OVERLAY.equals(strings.get(c.getInt(36 + 20 * a + 16)))) hasOverlay = true;
            }
        }
        if (hasOverlay) return manifest;
        if (manifestElement < 0) throw new IOException("the manifest has no manifest element");
        int value = strings.size();
        strings.add(OVERLAY);
        chunks.add(manifestElement + 1, endElement(usesPermission));
        chunks.add(manifestElement + 1, permission(usesPermission, ns, name, value));
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] pool = writePool(in, 8, strings);
        int size = 8 + pool.length;
        for (byte[] chunk : chunks) size += chunk.length;
        ByteBuffer header = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
        header.putShort((short) RES_XML).putShort((short) 8).putInt(size);
        out.write(header.array());
        out.write(pool);
        for (byte[] chunk : chunks) out.write(chunk);
        return out.toByteArray();
    }

    private static ByteBuffer le(byte[] b) {
        return ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN);
    }

    private static int type(byte[] chunk) {
        return le(chunk).getShort(0) & 0xffff;
    }

    // Start-element layout: 16-byte header, then ns, name, attributeStart(2)=20, attributeSize(2)=20,
    // count(2), id/class/style index(2 each, 1-based), then 20-byte attributes from offset 36.
    private static int attrId(ByteBuffer c, int a, int[] ids) {
        int nameIndex = c.getInt(36 + 20 * a + 4);
        return nameIndex >= 0 && nameIndex < ids.length ? ids[nameIndex] : 0;
    }

    private static byte[] permission(int element, int ns, int name, int value) {
        ByteBuffer o = ByteBuffer.allocate(56).order(ByteOrder.LITTLE_ENDIAN);
        o.putShort((short) START_ELEMENT).putShort((short) 16).putInt(56).putInt(1).putInt(-1);
        o.putInt(-1).putInt(element).putShort((short) 20).putShort((short) 20).putShort((short) 1)
            .putShort((short) 0).putShort((short) 0).putShort((short) 0);
        o.putInt(ns).putInt(name).putInt(value).putShort((short) 8).put((byte) 0).put((byte) TYPE_STRING).putInt(value);
        return o.array();
    }

    private static byte[] endElement(int element) {
        ByteBuffer o = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN);
        o.putShort((short) END_ELEMENT).putShort((short) 16).putInt(24).putInt(1).putInt(-1).putInt(-1).putInt(element);
        return o.array();
    }

    private static List<String> readPool(ByteBuffer in, int pool) throws IOException {
        int count = in.getInt(pool + 8), styles = in.getInt(pool + 12), flags = in.getInt(pool + 16);
        int stringsStart = pool + in.getInt(pool + 20);
        if (styles != 0) throw new IOException("styled strings in the manifest aren't supported");
        List<String> strings = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            int p = stringsStart + in.getInt(pool + 28 + 4 * i);
            if ((flags & UTF8) != 0) {
                p += (in.get(p) & 0x80) != 0 ? 2 : 1; // length in UTF-16 units
                int bytes = in.get(p) & 0xff;
                if ((bytes & 0x80) != 0) { bytes = ((bytes & 0x7f) << 8) | (in.get(p + 1) & 0xff); p += 2; } else p += 1;
                strings.add(new String(in.array(), p, bytes, StandardCharsets.UTF_8));
            } else {
                int chars = in.getShort(p) & 0xffff;
                if ((chars & 0x8000) != 0) { chars = ((chars & 0x7fff) << 16) | (in.getShort(p + 2) & 0xffff); p += 4; } else p += 2;
                strings.add(new String(in.array(), p, chars * 2, StandardCharsets.UTF_16LE));
            }
        }
        return strings;
    }

    // Written back as UTF-16, which every Android version reads; same flags otherwise (not sorted).
    private static byte[] writePool(ByteBuffer in, int pool, List<String> strings) {
        int flags = in.getInt(pool + 16) & ~UTF8 & ~1;
        ByteArrayOutputStream data = new ByteArrayOutputStream();
        int[] offsets = new int[strings.size()];
        for (int i = 0; i < strings.size(); i++) {
            offsets[i] = data.size();
            byte[] chars = strings.get(i).getBytes(StandardCharsets.UTF_16LE);
            int length = chars.length / 2;
            if (length > 0x7fff) {
                writeShort(data, 0x8000 | (length >>> 16));
                writeShort(data, length & 0xffff);
            } else {
                writeShort(data, length);
            }
            data.write(chars, 0, chars.length);
            writeShort(data, 0);
        }
        while (data.size() % 4 != 0) data.write(0);
        int header = 28, stringsStart = header + 4 * strings.size();
        int size = stringsStart + data.size();
        ByteBuffer out = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        out.putShort((short) STRING_POOL).putShort((short) header).putInt(size)
            .putInt(strings.size()).putInt(0).putInt(flags).putInt(stringsStart).putInt(0);
        for (int offset : offsets) out.putInt(offset);
        out.put(data.toByteArray());
        return out.array();
    }

    private static void writeShort(ByteArrayOutputStream out, int value) {
        out.write(value & 0xff);
        out.write((value >>> 8) & 0xff);
    }
}
