package com.myemu.speedpatcher;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Adds android:supportsPictureInPicture="true" to every activity in Xerion's compiled (binary)
 * AndroidManifest.xml, for the drawer: the game shrinks to a floating window (which can be pushed to
 * the screen's edge) and keeps playing, since it stays on screen. The attribute's name goes to the
 * end of the string pool and the resource map is padded with 0 (no resource) up to it; attributes
 * stay sorted by resource id, as Android expects.
 */
final class AxmlEdit {
    private static final int RES_XML = 0x0003, STRING_POOL = 0x0001, RESOURCE_MAP = 0x0180, START_ELEMENT = 0x0102;
    private static final int UTF8 = 0x100;
    private static final int ATTR_PIP = 0x010104F7, TYPE_BOOLEAN = 0x12;
    private static final String ANDROID = "http://schemas.android.com/apk/res/android";

    private AxmlEdit() {}

    /** The manifest with picture-in-picture allowed; the same array if it already was. */
    static byte[] allowPip(byte[] manifest) throws IOException {
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
        if (ns < 0) throw new IOException("unexpected manifest contents");

        int pip = -1; // the attribute's name string, added on first use
        for (int i = 0; i < chunks.size(); i++) {
            if (type(chunks.get(i)) != START_ELEMENT) continue;
            ByteBuffer c = le(chunks.get(i));
            if (!strings.get(c.getInt(20)).equals("activity")) continue;
            int count = c.getShort(28) & 0xffff, insert = count;
            boolean has = false;
            for (int a = 0; a < count; a++) {
                int name = c.getInt(36 + 20 * a + 4);
                int id = name >= 0 && name < ids.length ? ids[name] : 0;
                if (id == ATTR_PIP) has = true;
                if (insert == count && (id == 0 || id > ATTR_PIP)) insert = a;
            }
            if (has) continue;
            if (pip < 0) {
                pip = strings.size();
                strings.add("supportsPictureInPicture");
            }
            chunks.set(i, withAttribute(chunks.get(i), insert, ns, pip));
        }
        if (pip < 0) return manifest;
        int[] longer = new int[Math.max(ids.length, pip + 1)]; // the strings in between map to 0: no resource, as before
        System.arraycopy(ids, 0, longer, 0, ids.length);
        longer[pip] = ATTR_PIP;
        ByteBuffer newMap = ByteBuffer.allocate(8 + 4 * longer.length).order(ByteOrder.LITTLE_ENDIAN);
        newMap.putShort((short) RESOURCE_MAP).putShort((short) 8).putInt(newMap.capacity());
        for (int id : longer) newMap.putInt(id);
        chunks.set(map, newMap.array());

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
    private static byte[] withAttribute(byte[] chunk, int insert, int ns, int name) {
        int at = 36 + 20 * insert;
        byte[] out = new byte[chunk.length + 20];
        System.arraycopy(chunk, 0, out, 0, at);
        System.arraycopy(chunk, at, out, at + 20, chunk.length - at);
        ByteBuffer o = le(out);
        o.putInt(4, out.length);
        o.putShort(28, (short) ((o.getShort(28) & 0xffff) + 1));
        for (int f = 30; f <= 34; f += 2) { // id/class/style attribute indexes after the insert move up one
            int index = o.getShort(f) & 0xffff;
            if (index > insert) o.putShort(f, (short) (index + 1));
        }
        o.putInt(at, ns).putInt(at + 4, name).putInt(at + 8, -1)
            .putShort(at + 12, (short) 8).put(at + 14, (byte) 0).put(at + 15, (byte) TYPE_BOOLEAN).putInt(at + 16, -1);
        return out;
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
