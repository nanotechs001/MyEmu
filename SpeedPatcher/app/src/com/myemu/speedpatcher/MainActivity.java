package com.myemu.speedpatcher;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * One screen that adds the speed button to Xerion itself: uninstall the original (Android won't
 * replace an app signed by someone else), then install the patched one, which keeps the game's
 * package name. Also updates an older patch in place and removes an older version's speed copy.
 */
public final class MainActivity extends Activity {
    private static final String INSTALLED = "com.myemu.speedpatcher.INSTALLED";
    /** An older version's separate copy, which the game flags as a clone. */
    private static final String OLD_COPY = "com.com.Xerion.speed";
    private TextView status;
    private Button primary, secondary;
    private File patched, installing;
    private boolean busy;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        int pad = (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 24, getResources().getDisplayMetrics());
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);
        TextView title = new TextView(this);
        title.setText("Xerion Speed Patcher");
        title.setTextSize(24);
        status = new TextView(this);
        status.setTextSize(16);
        status.setPadding(0, pad, 0, pad);
        primary = new Button(this);
        secondary = new Button(this);
        root.addView(title);
        root.addView(status);
        root.addView(primary);
        root.addView(secondary);
        setContentView(root);
        new File(getExternalFilesDir(null), "xerion-speed-copy.apk").delete(); // an older version's speed copy
        patched = new File(getExternalFilesDir(null), "xerion-speed.apk");
        // The uninstall dialog closes (and we resume) before the app is actually gone.
        IntentFilter changes = new IntentFilter(Intent.ACTION_PACKAGE_REMOVED);
        changes.addAction(Intent.ACTION_PACKAGE_ADDED);
        changes.addDataScheme("package");
        registerReceiver(packages, changes, Build.VERSION.SDK_INT >= 33 ? RECEIVER_NOT_EXPORTED : 0);
    }

    private final BroadcastReceiver packages = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) { refresh(); }
    };

    @Override
    protected void onDestroy() {
        unregisterReceiver(packages);
        super.onDestroy();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (!INSTALLED.equals(intent.getAction())) return;
        int result = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
        if (result == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            startActivity((Intent) intent.getParcelableExtra(Intent.EXTRA_INTENT));
            return;
        }
        busy = false;
        if (result == PackageInstaller.STATUS_SUCCESS) {
            if (installing != null) installing.delete();
            refresh();
        } else {
            File apk = installing;
            show("Installing failed: " + intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE),
                "Try again", v -> install(apk), null, null);
        }
    }

    private void refresh() {
        if (busy) return;
        ApplicationInfo game = info(XerionPatch.GAME);
        boolean ours = game != null
            && getPackageManager().checkSignatures(XerionPatch.GAME, getPackageName()) == PackageManager.SIGNATURE_MATCH;
        if (ours && patched.exists() && current(game)) patched.delete(); // installed while we were away
        boolean oldCopy = info(OLD_COPY) != null;

        if (patched.exists() && game != null && !ours) {
            show("The patched Xerion is ready. Android only replaces an app with one signed by the same developer, so the original Xerion "
                + "has to be uninstalled first. This clears the game's data on this device (your account stays on the game's server).",
                "Uninstall original Xerion", v -> uninstall(XerionPatch.GAME), null, null);
        } else if (patched.exists()) {
            show("The patched Xerion is ready to install.", "Install patched Xerion", v -> install(patched), null, null);
        } else if (game == null) {
            show("Install Xerion first, then come back here.", null, null, null, null);
        } else if (game.splitSourceDirs != null) {
            show("This Xerion is installed in several parts (split APKs), which the patcher can't rebuild yet.", null, null, null, null);
        } else {
            File source = new File(game.sourceDir);
            boolean stale = ours && !current(game);
            String text = !ours
                ? "Xerion found.\n\nPatch Xerion to add the speed button. The original is uninstalled first, which clears the game's "
                    + "data on this device (your account stays on the game's server), then the game downloads its data again."
                : stale ? "Xerion's speed patch is out of date: update it (your game data stays)."
                : "Xerion has the speed button: tap it in the game to change speed (1× → 1.5× → … → 5× → 1×), drag it to move it.";
            if (oldCopy) text += "\n\nThe old \"Xerion Speed\" copy is still installed: the game flags it as a clone, so remove it.";
            text += "\n\nPatching needs about " + (source.length() * 2 >> 20) + " MB free.";
            String second = oldCopy ? "Remove old speed copy" : null;
            View.OnClickListener removeCopy = v -> uninstall(OLD_COPY);
            if (!ours) show(text, "Patch Xerion", v -> patch(source), second, removeCopy);
            else if (stale) show(text, "Update speed patch", v -> patch(source), second, removeCopy);
            else show(text, "Open Xerion", v -> open(XerionPatch.GAME), second, removeCopy);
        }
    }

    private void uninstall(String app) {
        startActivity(new Intent(Intent.ACTION_DELETE, Uri.parse("package:" + app)));
    }

    // Built by this version of the patcher? (An older one's speed library needs replacing.)
    private boolean current(ApplicationInfo app) {
        try {
            return XerionPatch.isCurrent(new File(app.sourceDir), getAssets()::open);
        } catch (Exception e) {
            return true; // can't tell: don't nag
        }
    }

    private ApplicationInfo info(String app) {
        try {
            return getPackageManager().getApplicationInfo(app, 0);
        } catch (PackageManager.NameNotFoundException e) {
            return null;
        }
    }

    @SuppressWarnings("deprecation")
    private long version(String app) {
        try {
            PackageInfo info = getPackageManager().getPackageInfo(app, 0);
            return Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode;
        } catch (PackageManager.NameNotFoundException e) {
            return -1;
        }
    }

    private void open(String app) {
        Intent launch = getPackageManager().getLaunchIntentForPackage(app);
        if (launch != null) startActivity(launch);
    }

    private void show(String text, String first, View.OnClickListener firstClick, String second, View.OnClickListener secondClick) {
        status.setText(text);
        set(primary, first, firstClick);
        set(secondary, second, secondClick);
    }

    private static void set(Button button, String text, View.OnClickListener click) {
        button.setVisibility(text == null ? View.GONE : View.VISIBLE);
        button.setEnabled(true);
        button.setText(text);
        button.setOnClickListener(click);
    }

    private void working(String text) {
        runOnUiThread(() -> {
            status.setText(text);
            primary.setEnabled(false);
            secondary.setEnabled(false);
        });
    }

    private void patch(File source) {
        File target = patched;
        File folder = target.getParentFile();
        if (folder.getUsableSpace() < source.length() * 2) {
            show("Not enough free space: the patcher needs about " + (source.length() * 2 >> 20) + " MB.",
                "Try again", v -> refresh(), null, null);
            return;
        }
        busy = true;
        new Thread(() -> {
            File building = new File(folder, "building.apk");
            try {
                XerionPatch.build(source, building, getAssets()::open, this::working);
                if (!building.renameTo(target)) throw new java.io.IOException("couldn't save the patched Xerion");
                runOnUiThread(() -> { busy = false; refresh(); });
            } catch (Throwable e) { // out of memory included
                building.delete();
                runOnUiThread(() -> { busy = false; show("Patching failed: " + e.getMessage(), "Try again", v -> refresh(), null, null); });
            }
        }).start();
    }

    private void install(File apk) {
        if (!getPackageManager().canRequestPackageInstalls()) {
            show("Allow this app to install apps, then come back.", "Open settings", v -> startActivity(
                new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + getPackageName()))), null, null);
            return;
        }
        busy = true;
        installing = apk;
        working("Installing…");
        new Thread(() -> {
            try {
                PackageInstaller installer = getPackageManager().getPackageInstaller();
                PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
                params.setSize(apk.length());
                int id = installer.createSession(params);
                try (PackageInstaller.Session session = installer.openSession(id)) {
                    try (InputStream in = new FileInputStream(apk); OutputStream out = session.openWrite("base.apk", 0, apk.length())) {
                        byte[] buffer = new byte[1 << 16];
                        for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
                        session.fsync(out);
                    }
                    Intent done = new Intent(this, MainActivity.class).setAction(INSTALLED);
                    int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
                    session.commit(PendingIntent.getActivity(this, 0, done, flags).getIntentSender());
                }
            } catch (Exception e) {
                runOnUiThread(() -> { busy = false; show("Installing failed: " + e.getMessage(), "Try again", v -> install(apk), null, null); });
            }
        }).start();
    }
}
