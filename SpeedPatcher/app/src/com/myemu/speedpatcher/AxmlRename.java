package com.myemu.speedpatcher;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Gives a compiled (binary) AndroidManifest.xml a new package name so the app installs beside the
 * original: the package, the content-provider authorities and the app's own permissions move to the
 * new name (two apps can't share those), and the app's label becomes plain text. Class names stay,
 * since the code is the same. Like aapt's --rename-manifest-package, but on an already-built APK.
 * Changed values are added to the end of the string pool, so a string shared with something that
 * must not change (a class name, say) is left alone.
 */
final class AxmlRename {
    private static final int RES_XML = 0x0003, STRING_POOL = 0x0001, RESOURCE_MAP = 0x0180, START_ELEMENT = 0x0102;
    private static final int UTF8 = 0x100;
    private static final int ATTR_LABEL = 0x01010001, ATTR_NAME = 0x01010003, ATTR_AUTHORITIES = 0x01010018;
    private static final int TYPE_STRING = 0x03;

    private AxmlRename() {}

    static byte[] rename(byte[] manifest, String from, String to, String label) throws IOException {
        ByteBuffer in = ByteBuffer.wrap(manifest).order(ByteOrder.LITTLE_ENDIAN);
        if (in.getShort(0) != RES_XML || in.getShort(8) != STRING_POOL) throw new IOException("unexpected manifest format");
        int poolSize = in.getInt(12);
        List<String> strings = readPool(in, 8);
        int originalCount = strings.size();
        Map<String, Integer> added = new HashMap<>();
        int[] resourceIds = new int[0];
        byte[] rest = new byte[manifest.length - 8 - poolSize];
        System.arraycopy(manifest, 8 + poolSize, rest, 0, rest.length);
        ByteBuffer body = ByteBuffer.wrap(rest).order(ByteOrder.LITTLE_ENDIAN);
        int appLabelType = -1, appLabelData = 0;
        boolean renamedPackage = false;

        for (int at = 0; at < rest.length; ) {
            int type = body.getShort(at) & 0xffff, header = body.getShort(at + 2) & 0xffff, size = body.getInt(at + 4);
            if (type == RESOURCE_MAP) {
                resourceIds = new int[(size - header) / 4];
                for (int i = 0; i < resourceIds.length; i++) resourceIds[i] = body.getInt(at + header + 4 * i);
            } else if (type == START_ELEMENT) {
                String element = strings.get(body.getInt(at + header + 4));
                int attrStart = body.getShort(at + header + 8) & 0xffff, attrSize = body.getShort(at + header + 10) & 0xffff;
                int attrCount = body.getShort(at + header + 12) & 0xffff;
                for (int i = 0; i < attrCount; i++) {
                    int a = at + header + attrStart + i * attrSize;
                    int nameIndex = body.getInt(a + 4);
                    int id = nameIndex >= 0 && nameIndex < resourceIds.length ? resourceIds[nameIndex] : 0;
                    String name = nameIndex >= 0 ? strings.get(nameIndex) : "";
                    int dataType = body.get(a + 15) & 0xff, data = body.getInt(a + 16);
                    String value = dataType == TYPE_STRING ? strings.get(data) : null;
                    String changed = null;
                    if (element.equals("manifest") && id == 0 && name.equals("package") && from.equals(value)) {
                        changed = to;
                        renamedPackage = true;
                    } else if (element.equals("provider") && is(id, name, ATTR_AUTHORITIES, "authorities") && value != null) {
                        changed = value.replace(from + ".", to + ".");
                    } else if (element.startsWith("permission") || element.startsWith("uses-permission")) {
                        if (is(id, name, ATTR_NAME, "name") && value != null && value.startsWith(from + "."))
                            changed = to + value.substring(from.length());
                    } else if (label != null && is(id, name, ATTR_LABEL, "label")) {
                        if (element.equals("application")) {
                            appLabelType = dataType;
                            appLabelData = data;
                            changed = label;
                        } else if ((element.equals("activity") || element.equals("activity-alias"))
                                && dataType == appLabelType && data == appLabelData) {
                            changed = label; // the launcher entry repeats the app's label
                        }
                    }
                    if (changed == null || changed.equals(value)) continue;
                    Integer index = added.get(changed);
                    if (index == null) {
                        index = strings.size();
                        strings.add(changed);
                        added.put(changed, index);
                    }
                    body.putInt(a + 8, index); // raw value
                    body.put(a + 15, (byte) TYPE_STRING);
                    body.putInt(a + 16, index);
                }
            }
            at += size;
        }
        if (!renamedPackage) throw new IOException("the manifest's package isn't " + from);
        if (strings.size() == originalCount) return manifest;

        byte[] pool = writePool(in, 8, strings);
        ByteBuffer out = ByteBuffer.allocate(8 + pool.length + rest.length).order(ByteOrder.LITTLE_ENDIAN);
        out.putShort((short) RES_XML).putShort((short) 8).putInt(8 + pool.length + rest.length);
        out.put(pool).put(rest);
        return out.array();
    }

    /**
     * Renames the package in resources.arsc too: the game looks resources up by name with
     * getIdentifier(name, type, getPackageName()), which only finds them under the table's own name.
     * The name is a fixed 128-character field, so this is an in-place edit.
     */
    static byte[] renameResources(byte[] table, String from, String to) throws IOException {
        ByteBuffer in = ByteBuffer.wrap(table).order(ByteOrder.LITTLE_ENDIAN);
        if (in.getShort(0) != 0x0002) throw new IOException("unexpected resources.arsc format");
        int renamed = 0;
        for (int at = in.getShort(2) & 0xffff; at < table.length; at += in.getInt(at + 4)) {
            if ((in.getShort(at) & 0xffff) != 0x0200) continue; // ResTable_package; the global string pool is skipped
            int name = at + 12;
            StringBuilder current = new StringBuilder();
            for (int i = 0; i < 128 && in.getChar(name + 2 * i) != 0; i++) current.append(in.getChar(name + 2 * i));
            if (!current.toString().equals(from)) continue;
            for (int i = 0; i < 128; i++) in.putChar(name + 2 * i, i < to.length() ? to.charAt(i) : 0);
            renamed++;
        }
        if (renamed == 0) throw new IOException("resources.arsc has no package " + from);
        return table;
    }

    private static boolean is(int id, String name, int wantId, String wantName) {
        return id != 0 ? id == wantId : name.equals(wantName);
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
