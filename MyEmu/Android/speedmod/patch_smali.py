#!/usr/bin/env python3
"""Inject the MyEmu speed loader into an apktool-decoded app dir.

Finds the launcher activity from the manifest, makes its onCreate call our loader, and drops a
self-contained Lcom/myemu/Patch; helper. The helper is a zero-arg static, so the call can be
prepended to onCreate without disturbing the method's register count.

    python3 patch_smali.py <decoded_app_dir>
    python3 patch_smali.py --selftest
"""
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"

PATCH_SMALI = """.class public Lcom/myemu/Patch;
.super Ljava/lang/Object;
.method public static init()V
    .locals 1
    const-string v0, "speedhook"
    invoke-static {v0}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V
    return-void
.end method
"""

CALL = "    invoke-static {}, Lcom/myemu/Patch;->init()V\n"


def _resolve(name, pkg):
    if name.startswith("."):
        return pkg + name
    if "." not in name:
        return pkg + "." + name
    return name


def launcher_class(manifest):
    root = ET.parse(manifest).getroot()
    pkg = root.get("package", "")
    for tag, attr in (("activity", ANDROID + "name"), ("activity-alias", ANDROID + "targetActivity")):
        for act in root.iter(tag):
            for intent in act.findall("intent-filter"):
                actions = {a.get(ANDROID + "name") for a in intent.findall("action")}
                cats = {c.get(ANDROID + "name") for c in intent.findall("category")}
                if "android.intent.action.MAIN" in actions and "android.intent.category.LAUNCHER" in cats:
                    return _resolve(act.get(attr), pkg)
    raise SystemExit("no launcher activity found in manifest")


def find_smali(app_dir, cls):
    rel = cls.replace(".", "/") + ".smali"
    hits = glob.glob(os.path.join(app_dir, "smali*", rel))
    return hits[0] if hits else None


def super_of(text):
    m = re.search(r"^\.super (\S+)\s*$", text, re.M)
    return m.group(1) if m else "Landroid/app/Activity;"


def inject_oncreate(text, super_cls):
    """Return smali with our loader called at the top of onCreate (idempotent)."""
    if CALL in text:
        return text
    decl = re.search(r"^\.method [^\n]*\bonCreate\(Landroid/os/Bundle;\)V\s*$", text, re.M)
    if decl:
        regs = re.search(r"^\s*\.(locals|registers) \d+\s*$", text[decl.end():], re.M)
        if not regs:
            raise SystemExit("onCreate has no .locals/.registers directive")
        at = decl.end() + regs.end() + 1  # just past the directive's newline
        return text[:at] + CALL + text[at:]
    # launcher has no onCreate of its own: synthesize one that calls us then super.
    method = (
        ".method public onCreate(Landroid/os/Bundle;)V\n"
        "    .locals 0\n"
        + CALL
        + "    invoke-super {p0, p1}, " + super_cls + "->onCreate(Landroid/os/Bundle;)V\n"
        "    return-void\n"
        ".end method\n\n"
    )
    sup = re.search(r"^\.super [^\n]+\n", text, re.M)
    at = sup.end()
    return text[:at] + "\n" + method + text[at:]


def main(app):
    cls = launcher_class(os.path.join(app, "AndroidManifest.xml"))
    smali = find_smali(app, cls)
    if not smali:
        raise SystemExit("launcher %s has no smali in this apk (inherited?) — patch its base class" % cls)
    text = open(smali).read()
    open(smali, "w").write(inject_oncreate(text, super_of(text)))
    root = sorted(glob.glob(os.path.join(app, "smali*")))[0]
    pdir = os.path.join(root, "com", "myemu")
    os.makedirs(pdir, exist_ok=True)
    open(os.path.join(pdir, "Patch.smali"), "w").write(PATCH_SMALI)
    print("patched %s -> %s" % (cls, smali))


def selftest():
    sample = (
        ".class public LFoo;\n.super Landroid/app/Activity;\n"
        ".method public onCreate(Landroid/os/Bundle;)V\n    .locals 2\n    .prologue\n"
        "    invoke-super {p0, p1}, Landroid/app/Activity;->onCreate(Landroid/os/Bundle;)V\n"
        "    return-void\n.end method\n"
    )
    out = inject_oncreate(sample, "Landroid/app/Activity;")
    assert CALL in out, "call not injected"
    assert out.index(CALL) < out.index("invoke-super"), "loader must run before super.onCreate"
    assert inject_oncreate(out, "Landroid/app/Activity;") == out, "not idempotent"
    synth = inject_oncreate(".class public LBar;\n.super Landroid/app/Activity;\n", "Landroid/app/Activity;")
    assert "onCreate" in synth and CALL in synth, "synthesized onCreate missing loader"
    print("selftest ok")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        selftest()
    elif len(sys.argv) == 2:
        main(sys.argv[1])
    else:
        raise SystemExit(__doc__)
