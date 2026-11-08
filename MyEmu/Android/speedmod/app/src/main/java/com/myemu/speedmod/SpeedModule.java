package com.myemu.speedmod;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam;

// Loaded by VirtualXposed into every sandboxed app; only acts inside Xerion. Pulls in the native
// clock hook, which does all the work in JNI_OnLoad (installs bytehook on clock_gettime).
public class SpeedModule implements IXposedHookLoadPackage {

    private static final String TARGET = "com.com.Xerion";

    @Override
    public void handleLoadPackage(LoadPackageParam lpparam) {
        if (!TARGET.equals(lpparam.packageName)) return;
        try {
            System.loadLibrary("speedhook");
            XposedBridge.log("[MyEmuSpeed] hook library loaded for " + lpparam.packageName);
        } catch (Throwable t) {
            XposedBridge.log("[MyEmuSpeed] failed to load hook library: " + t);
        }
    }
}
