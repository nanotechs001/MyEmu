package com.myemu.speed;

import android.app.Activity;
import android.content.Context;
import android.app.PictureInPictureParams;
import android.util.Rational;
import android.widget.Toast;
import android.app.Application;
import android.app.Instrumentation;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.Gravity;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.PixelCopy;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * The floating speed button inside a patched Xerion. Loaded from memory by libjnigraphicz.so
 * (native/xerion_speed.c), which also provides setSpeed. Tap: a dropdown (speed, watchdog on/off,
 * hide the button); drag: move it. Hiding sets 1× until the game is next started.
 *
 * The watchdog keeps an unattended game going: it logs back in, starts the game and turns auto-hunt
 * back on, holding the speed at 1× until the game is hunting again (fast clocks while logging in can
 * cost the connection). It reads the game's own log (ConquerOnline: login steps) and the colour of
 * the auto-hunt button (gold while hunting, pale when not); engine-drawn buttons are found by the
 * game's layout: a 1280x720 design scaled by min(width/1280, height/720), anchored to the edges.
 * Settings and speed live in the game's own "myemu_speed" preferences.
 */
public final class SpeedOverlay implements Application.ActivityLifecycleCallbacks {
    static native void setSpeed(double speed);

    private static final String TAG = "myemu_speed";
    private static final double[] SPEEDS = {1, 1.5, 2, 2.5, 3, 4, 5};
    private static final Map<Activity, TextView> buttons = new WeakHashMap<>();
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static SharedPreferences prefs;
    private static Application application;
    private static int index;
    private static boolean hidden;
    private static volatile boolean watchdog, held;
    private static volatile Activity resumed;
    private static View panel;
    private static TextView panelStatus;

    public static void start() {
        main.post(SpeedOverlay::attach);
    }

    private static void attach() {
        try {
            Class<?> thread = Class.forName("android.app.ActivityThread");
            Application app = (Application) thread.getMethod("currentApplication").invoke(null);
            application = app;
            prefs = app.getSharedPreferences(TAG, 0);
            index = Math.min(Math.max(prefs.getInt("index", 0), 0), SPEEDS.length - 1);
            watchdog = prefs.getBoolean("watchdog", false);
            held = watchdog;
            applySpeed();
            app.registerActivityLifecycleCallbacks(new SpeedOverlay());
            for (Activity activity : runningActivities(thread)) {
                resumed = activity;
                addButton(activity);
            }
            Watchdog.begin();
        } catch (Throwable t) {
            Log.e(TAG, "speed button failed", t);
        }
    }

    // The game may already be on screen when its engine (and so this) loads.
    private static List<Activity> runningActivities(Class<?> thread) {
        List<Activity> list = new ArrayList<>();
        try {
            Object current = thread.getMethod("currentActivityThread").invoke(null);
            Field field = thread.getDeclaredField("mActivities");
            field.setAccessible(true);
            for (Object record : ((Map<?, ?>) field.get(current)).values()) {
                Field activity = record.getClass().getDeclaredField("activity");
                activity.setAccessible(true);
                if (activity.get(record) != null) list.add((Activity) activity.get(record));
            }
        } catch (Throwable t) {
            Log.w(TAG, "the button shows when the game next comes to the front", t);
        }
        return list;
    }

    /** 1× while hidden, or while the watchdog waits for the game to hunt; else the chosen speed. */
    private static void applySpeed() {
        setSpeed(hidden || (watchdog && held) ? 1 : SPEEDS[index]);
        main.post(() -> {
            for (TextView button : buttons.values()) {
                button.setText(label());
                button.setAlpha(watchdog && held ? 0.55f : 1f);
            }
        });
    }

    private static String label() {
        return label(SPEEDS[index]);
    }

    private static String label(double s) {
        return (s == Math.rint(s) ? String.valueOf((int) s) : String.valueOf(s)) + "×";
    }

    private static GradientDrawable pill(float dp, int color) {
        GradientDrawable pill = new GradientDrawable();
        pill.setColor(color);
        pill.setCornerRadius(18 * dp);
        return pill;
    }

    private static float dp(Activity activity) {
        return activity.getResources().getDisplayMetrics().density;
    }

    private static GradientDrawable background(float dp, float radius) {
        GradientDrawable background = new GradientDrawable();
        background.setColor(radius > 20 ? 0xCC000000 : 0xF2181818); // the round button stays see-through; the dropdown doesn't
        background.setCornerRadius(radius * dp);
        background.setStroke((int) dp, 0x66FFFFFF);
        return background;
    }

    private static WindowManager.LayoutParams windowParams() {
        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.TOP | Gravity.START;
        if (Build.VERSION.SDK_INT >= 28)
            params.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        return params;
    }

    private static void removeButton(Activity activity) {
        TextView old = buttons.remove(activity);
        if (old != null) {
            try { activity.getWindowManager().removeViewImmediate(old); } catch (RuntimeException ignored) {}
        }
    }

    // The button is a small window of its own: Xerion covers its activity with a transparent
    // full-screen window that takes every touch, so a view inside the activity can't be tapped.
    // Re-added on every resume so it sits above the game's windows.
    private static void addButton(Activity activity) {
        removeButton(activity);
        if (hidden) return;
        float dp = dp(activity);
        TextView button = new TextView(activity);
        button.setText(label());
        button.setAlpha(watchdog && held ? 0.55f : 1f);
        button.setTextColor(Color.WHITE);
        button.setTextSize(15);
        button.setTypeface(Typeface.DEFAULT_BOLD);
        button.setGravity(Gravity.CENTER);
        button.setMinWidth((int) (48 * dp));
        button.setMinHeight((int) (48 * dp));
        button.setPadding((int) (10 * dp), 0, (int) (10 * dp), 0);
        button.setBackground(background(dp, 24));
        WindowManager.LayoutParams params = windowParams();
        params.x = (int) prefs.getFloat("x", 16 * dp);
        params.y = (int) prefs.getFloat("y", 96 * dp);
        button.setOnTouchListener(new Drag(activity, params));
        try {
            activity.getWindowManager().addView(button, params);
            buttons.put(activity, button);
        } catch (RuntimeException e) {
            Log.w(TAG, "no speed button on " + activity, e);
        }
    }

    private static long panelClosedAt;

    private static volatile boolean touching;

    // The game opens windows of its own over the button later (its login screens are full-screen SDK
    // windows), which would cover it: put the button back on top. Not mid-touch or with the dropdown open.
    private static void raiseButton() {
        Activity activity = resumed;
        if (activity == null || hidden || panel != null || touching) return;
        TextView button = buttons.get(activity);
        if (button == null) return;
        try {
            List<View> roots = Watchdog.rootViews();
            if (!roots.isEmpty() && roots.get(roots.size() - 1) != button) addButton(activity);
        } catch (Throwable ignored) {
            // can't see the window list: the button returns when the game next resumes
        }
    }

    // Tap the button: open the dropdown, or close it if open.
    private static void togglePanel(Activity activity, View button, WindowManager.LayoutParams at) {
        if (panel != null) closePanel(activity);
        // A tap on the button also reaches the open dropdown as an outside touch, which closes it first.
        else if (SystemClock.uptimeMillis() - panelClosedAt > 300) showPanel(activity, button, at);
    }

    // The dropdown: speed chips, watchdog switch (with its status), hide. Outside touches close it.
    private static void showPanel(Activity activity, View button, WindowManager.LayoutParams at) {
        float dp = dp(activity);
        int gold = 0xFFE0C080, grey = 0xFFB0B0B0;
        LinearLayout box = new LinearLayout(activity);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding((int) (14 * dp), (int) (10 * dp), (int) (14 * dp), (int) (12 * dp));
        box.setBackground(background(dp, 14));

        box.addView(text(activity, "Speed", 12, gold));
        LinearLayout chips = new LinearLayout(activity);
        TextView[] chip = new TextView[SPEEDS.length];
        Runnable paintChips = () -> {
            for (int i = 0; i < chip.length; i++) {
                chip[i].setBackground(pill(dp, i == index ? gold : 0x33FFFFFF));
                chip[i].setTextColor(i == index ? Color.BLACK : Color.WHITE);
            }
        };
        for (int i = 0; i < SPEEDS.length; i++) {
            TextView c = new TextView(activity);
            c.setText(label(SPEEDS[i]));
            c.setTextSize(14);
            c.setTypeface(Typeface.DEFAULT_BOLD);
            c.setGravity(Gravity.CENTER);
            c.setMinWidth((int) (44 * dp));
            c.setMinHeight((int) (36 * dp));
            c.setPadding((int) (8 * dp), 0, (int) (8 * dp), 0);
            int pick = i;
            c.setOnClickListener(v -> {
                index = pick;
                prefs.edit().putInt("index", index).apply();
                applySpeed();
                paintChips.run();
            });
            LinearLayout.LayoutParams gap = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
            gap.rightMargin = (int) (6 * dp);
            chips.addView(c, gap);
            chip[i] = c;
        }
        paintChips.run();
        box.addView(chips);

        LinearLayout row = new LinearLayout(activity);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, (int) (12 * dp), 0, 0);
        TextView name = text(activity, "Watchdog", 15, Color.WHITE);
        row.addView(name, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        TextView toggle = new TextView(activity);
        toggle.setTextSize(13);
        toggle.setTypeface(Typeface.DEFAULT_BOLD);
        toggle.setGravity(Gravity.CENTER);
        toggle.setMinWidth((int) (56 * dp));
        toggle.setMinHeight((int) (30 * dp));
        Runnable paintToggle = () -> {
            toggle.setText(watchdog ? "ON" : "OFF");
            toggle.setTextColor(watchdog ? Color.BLACK : Color.WHITE);
            toggle.setBackground(pill(dp, watchdog ? 0xFF7BD389 : 0x33FFFFFF));
        };
        paintToggle.run();
        row.addView(toggle);
        row.setOnClickListener(v -> {
            watchdog = !watchdog;
            prefs.edit().putBoolean("watchdog", watchdog).apply();
            held = watchdog; // 1× until the watchdog sees the game hunting
            Watchdog.status(watchdog ? "Checking the game…" : "Off");
            applySpeed();
            paintToggle.run();
        });
        box.addView(row);
        box.addView(text(activity, "Logs back in and restarts auto-hunt. Keeps 1× until hunting.", 11, grey));
        panelStatus = text(activity, "Status: " + Watchdog.status, 12, gold);
        box.addView(panelStatus);

        TextView hide = text(activity, "Hide speed button (sets 1×)", 14, grey);
        hide.setPadding(0, (int) (10 * dp), 0, 0);
        hide.setOnClickListener(v -> {
            closePanel(activity);
            hidden = true;
            for (Activity a : new ArrayList<>(buttons.keySet())) removeButton(a);
            applySpeed();
        });
        box.addView(hide);

        TextView drawerButton = text(activity, "Minimize game (keeps playing)", 14, grey);
        drawerButton.setOnClickListener(v -> { closePanel(activity); Drawer.hide(activity); });
        box.addView(drawerButton);

        box.setOnTouchListener((v, e) -> {
            // Not the watchdog's own taps on the game, only the player's.
            if (e.getActionMasked() == MotionEvent.ACTION_OUTSIDE && SystemClock.uptimeMillis() - Watchdog.tappedAt > 1000)
                closePanel(activity);
            return false;
        });
        WindowManager.LayoutParams params = windowParams();
        params.flags |= WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH;
        // Under the button, kept on screen.
        int screenW = activity.getResources().getDisplayMetrics().widthPixels;
        int screenH = activity.getResources().getDisplayMetrics().heightPixels;
        box.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED);
        params.x = Math.max(0, Math.min(at.x, screenW - box.getMeasuredWidth()));
        params.y = at.y + button.getHeight() + (int) (6 * dp);
        if (params.y + box.getMeasuredHeight() > screenH) params.y = Math.max(0, at.y - box.getMeasuredHeight() - (int) (6 * dp));
        try {
            activity.getWindowManager().addView(box, params);
            panel = box;
        } catch (RuntimeException e) {
            Log.w(TAG, "no settings panel", e);
        }
    }

    private static TextView text(Activity activity, String s, int size, int color) {
        float dp = dp(activity);
        TextView view = new TextView(activity);
        view.setText(s);
        view.setTextSize(size);
        view.setTextColor(color);
        view.setPadding(0, (int) (6 * dp), 0, (int) (6 * dp));
        return view;
    }

    private static void closePanel(Activity activity) {
        if (panel == null) return;
        try { activity.getWindowManager().removeViewImmediate(panel); } catch (RuntimeException ignored) {}
        panel = null;
        panelStatus = null;
        panelClosedAt = SystemClock.uptimeMillis();
    }

    // Tap: open/close the dropdown; drag: move the button.
    private static final class Drag implements View.OnTouchListener {
        private final Activity activity;
        private final WindowManager.LayoutParams params;
        private final int slop;
        private float downX, downY;
        private int startX, startY;
        private boolean dragging;

        Drag(Activity activity, WindowManager.LayoutParams params) {
            this.activity = activity;
            this.params = params;
            this.slop = ViewConfiguration.get(activity).getScaledTouchSlop();
        }

        @Override
        public boolean onTouch(View v, MotionEvent e) {
            switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                downX = e.getRawX(); downY = e.getRawY();
                startX = params.x; startY = params.y;
                dragging = false;
                touching = true;
                return true;
            case MotionEvent.ACTION_MOVE:
                float dx = e.getRawX() - downX, dy = e.getRawY() - downY;
                if (!dragging && Math.hypot(dx, dy) > slop) {
                    dragging = true;
                    closePanel(activity);
                }
                if (dragging) {
                    int width = v.getResources().getDisplayMetrics().widthPixels;
                    int height = v.getResources().getDisplayMetrics().heightPixels;
                    params.x = (int) Math.max(0, Math.min(startX + dx, width - v.getWidth()));
                    params.y = (int) Math.max(0, Math.min(startY + dy, height - v.getHeight()));
                    activity.getWindowManager().updateViewLayout(v, params);
                }
                return true;
            case MotionEvent.ACTION_UP:
                touching = false;
                int edge = (int) (8 * dp(activity)), width = v.getResources().getDisplayMetrics().widthPixels;
                if (dragging && (e.getRawX() < edge || e.getRawX() > width - edge)) {
                    // Pushed off the side: into the drawer (the button goes back where it was).
                    params.x = startX; params.y = startY;
                    activity.getWindowManager().updateViewLayout(v, params);
                    Drawer.hide(activity);
                } else if (dragging) prefs.edit().putFloat("x", params.x).putFloat("y", params.y).apply();
                else togglePanel(activity, v, params);
                return true;
            case MotionEvent.ACTION_CANCEL:
                touching = false;
                return true;
            default:
                return false;
            }
        }
    }

    /** Checks the game every few seconds while on; see the class comment. */
    private static final class Watchdog {
        static final String LOGIN = "login", SERVER = "server", ENTERING = "entering", GAME = "game";
        static volatile String phase = "", status = "Off";
        static volatile long tappedAt; // last injected tap, which the dropdown must not take as the player's
        private static long lastTap, lastLogin;
        private static long lastMessage;
        private static int notHunting, missingHud, updateSeen;
        private static final java.util.ArrayDeque<Long> logins = new java.util.ArrayDeque<>();

        static void begin() {
            status = watchdog ? "Checking the game…" : "Off";
            thread("myemu-log", Watchdog::readLog);
            thread("myemu-watchdog", () -> {
                while (true) {
                    SystemClock.sleep(3000);
                    try {
                        main.post(SpeedOverlay::raiseButton);
                        if (watchdog && !hidden) tick();
                        if (watchdog) Drawer.check();
                    } catch (Throwable t) {
                        Log.w(TAG, "watchdog", t);
                    }
                }
            });
        }

        private static void thread(String name, Runnable body) {
            Thread t = new Thread(body, name);
            t.setDaemon(true);
            t.start();
        }

        /** What the watchdog measured last (shown under the status, not logged: it changes every check). */
        static volatile String detail = "";

        static void status(String text) {
            if (!text.equals(status)) Log.i(TAG, "watchdog: " + text + " (" + phase + ")");
            status = text;
            String shown = "Status: " + text + (detail.isEmpty() ? "" : "\n" + detail);
            main.post(() -> { if (panelStatus != null) panelStatus.setText(shown); });
        }

        private static long huntingSince; // when the game was first seen hunting since the last hold

        private static void hold(boolean hold) {
            if (hold) huntingSince = 0;
            if (held == hold) return;
            held = hold;
            applySpeed();
        }

        // The game's own log (an app may read its own): which step of logging in it is on.
        private static void readLog() {
            try {
                Process logcat = new ProcessBuilder("logcat", "-v", "raw", "-s", "ConquerOnline:V").redirectErrorStream(true).start();
                BufferedReader lines = new BufferedReader(new InputStreamReader(logcat.getInputStream()));
                for (String line; (line = lines.readLine()) != null; ) {
                    if (line.contains("==ChannelLogin=") || line.contains("code:EVENT_LoginSDK_001000")) phase = LOGIN;
                    else if (line.contains("code:EVENT_ACCOUNT_SERVER_RECENT") || line.contains("code:EVENT_LoginSDKSuccess")) phase = SERVER;
                    else if (line.contains("code:Click_Login")) phase = ENTERING;
                    else if (line.contains("code:Login_BP") || line.contains("code:Login_Score")) phase = GAME;
                }
            } catch (Throwable t) {
                Log.w(TAG, "can't read the game's log: the watchdog only handles the login box and auto-hunt", t);
            }
        }

        private static void tick() {
            Activity activity = resumed;
            if (activity == null || Drawer.isSmall(activity)) return; // small: Drawer.check follows the log
            long now = SystemClock.uptimeMillis();
            if (now - lastLogin > 20000 && clickLogIn(activity)) {
                lastLogin = now;
                hold(true);
                // Logging in over and over (5 times in 5 minutes) means something is stuck: start over.
                logins.addLast(now);
                while (now - logins.peekFirst() > 5 * 60000) logins.removeFirst();
                if (logins.size() >= 5) {
                    logins.clear();
                    relaunch(activity, "Logged in 5 times in 5 minutes");
                    return;
                }
                status("Logging in (" + logins.size() + " of 5 in 5 min)");
                return;
            }
            if (now - lastMessage > 5000 && clickMessageOk(activity)) { // e.g. Connection failed: OK, then log in again
                lastMessage = now;
                phase = LOGIN;
                hold(true);
                status("Pressing OK on a message");
                return;
            }
            if (now - lastTap > 15000 && clickAccountLogin(activity)) {
                lastTap = now;
                phase = LOGIN; // the game logs nothing when it drops back to this screen
                hold(true);
                status("Opening the login");
                return;
            }
            View decor = activity.getWindow().getDecorView();
            SurfaceView game = findSurface(decor);
            View surface = game;
            Bitmap shot = game == null ? null : capture(game);
            boolean black = false; // a picture came back, all black (not: couldn't copy it)
            if (shot == null || allBlack(shot)) { // some GPUs (MyEmu on a Mac) can't copy the game's surface: the window, then
                if (shot != null) { black = true; shot.recycle(); }
                surface = decor;
                shot = captureWindow(activity, decor);
                if (shot != null && allBlack(shot)) { black = true; shot.recycle(); shot = null; }
            }
            int w = surface.getWidth(), h = surface.getHeight();
            if (w <= 0 || h <= 0) return;
            float s = Math.min(w / 1280f, h / 720f);
            if (shot == null) {
                blind(surface, w, h, s, now);
                // The game sometimes loses its picture for good (black, seen on MuMu after switching apps):
                // after 20 s of that, start it over. Loading screens are black for a few seconds.
                if (!black) {
                    blackSince = 0;
                } else if (blackSince == 0) {
                    blackSince = now;
                } else if (now - blackSince >= 20000) {
                    blackSince = 0;
                    relaunch(activity, "Black screen for 20 s");
                } else {
                    status("Black screen " + (now - blackSince) / 1000 + " s (restarting the game at 20 s)");
                }
                return;
            }
            blackSince = 0;
            float k = shot.getWidth() / (float) w;
            // The auto-hunt button (crossed swords) sits 100 design px from the right edge, 194 down, plus the
            // game's safe-area margin (a camera cut-out: ~67 design px on a Galaxy Z Fold, 0 on MuMu). Found by
            // its outline, so other icons and sand don't count (measured: the button matches 0.46-1.0, other
            // screens at most 0.29); then gold (hunting) or pale by how yellow its strokes are.
            int pw = shot.getWidth(), ph = shot.getHeight();
            int[] px = new int[pw * ph];
            shot.getPixels(px, 0, pw, 0, 0, pw, ph);
            float[] found = findSwords(px, pw, ph, w, s, k); // {match, shift, dy, x, y, size}
            boolean hud = found[0] >= 0.4f;
            int shift = hud ? (int) found[1] : 0;
            float right = w - shift * s; // the game's right edge, inside its safe area
            float swordsX = right - 100 * s, swordsY = (194 + (hud ? found[2] : 0)) * s;
            float yellow = hud ? yellowShare(px, pw, (int) found[3], (int) found[4], (int) found[5]) : 0;
            // A tutorial prompt dims the screen (hiding the HUD) and shows a bright "Skip" over the minimap.
            int skip = bright(shot, (right - 155 * s) * k, 75 * s * k, (right - 50 * s) * k, 108 * s * k);
            // "Account Disconnected. Please try again." [Yes]: a box on a black screen, gold button below the middle.
            float yesX = w / 2f, yesY = h / 2f + 140 * s;
            float yesGold = goldShare(shot, (yesX - 70 * s) * k, (yesY - 18 * s) * k, (yesX + 70 * s) * k, (yesY + 18 * s) * k);
            float sidesDark = darkSides(shot);
            // "New version detected, update now?" [No] [Yes]: the game's two-button box, gold Yes 114 design px
            // right of the middle and blue-grey No 130 left, 139 below (measured from a phone screenshot).
            // The same box style shows game errors in the world, so only off the world (login, start, loading).
            float boxY = h / 2f + 139 * s;
            float yesShare = shareOf(shot, (w / 2f + 69 * s) * k, (boxY - 12 * s) * k, (w / 2f + 159 * s) * k, (boxY + 12 * s) * k, true);
            float noShare = shareOf(shot, (w / 2f - 175 * s) * k, (boxY - 12 * s) * k, (w / 2f - 85 * s) * k, (boxY + 12 * s) * k, false);
            boolean updateBox = !GAME.equals(phase) && yesShare >= 0.5f && noShare >= 0.5f; // measured 0.85 / 0.89 on it
            int light = meanBrightness(shot);
            saveForDebugging(activity, shot, now);
            shot.recycle();
            detail = String.format(java.util.Locale.ROOT,
                "Auto-hunt button: %s (match %.2f, edge %d), yellow %d%% (hunting ≥ 50%%) · screen %dx%d%s",
                hud ? "seen" : "not seen", found[0], shift, (int) (yellow * 100), w, h, tapError.isEmpty() ? "" : " · " + tapError);
            if (hud) {
                missingHud = 0;
                if (yellow >= 0.5f) { // measured: hunting 0.58-0.66 (MuMu and a Fold), not hunting 0.39-0.40
                    notHunting = 0;
                    // 10 s of hunting at 1× (after a login or turning auto-hunt on) before the chosen speed.
                    if (huntingSince == 0) huntingSince = now;
                    long wait = 10000 - (now - huntingSince);
                    if (!held || wait <= 0) {
                        hold(false);
                        status("Hunting");
                        Drawer.fixed();
                    } else {
                        status("Hunting: " + label() + " in " + (wait + 999) / 1000 + " s");
                    }
                } else if (found[0] < 0.5f) {
                    // Seen, but not clearly (damage numbers and effects fly over it): no verdict this time.
                    status("Checking auto-hunt…");
                } else if (++notHunting < 3) {
                    // Fights make the button misread now and then: 3 clear readings in a row (~9 s) before acting,
                    // since tapping it while it's on turns auto-hunt off.
                    Log.i(TAG, String.format(java.util.Locale.ROOT, "watchdog: not hunting? match %.2f yellow %.2f", found[0], yellow));
                    status("Not hunting?");
                } else {
                    hold(true);
                    if (now - lastTap > 15000) {
                        tap(surface, swordsX, swordsY);
                        lastTap = now;
                        notHunting = 0;
                        status("Turning auto-hunt on");
                    } else {
                        status("Not hunting");
                    }
                }
                return;
            }
            notHunting = 0;
            // The update box: twice in a row, then start the game over (it checks for the update again).
            if (updateBox) {
                if (++updateSeen >= 2) {
                    updateSeen = 0;
                    relaunch(activity, "Update box");
                } else {
                    hold(true);
                    status("Update box?");
                }
                return;
            }
            updateSeen = 0;
            float skipArea = 105 * s * k * 33 * s * k;
            boolean disconnected = yesGold >= 0.4f && sidesDark >= 0.9f; // measured: 0.62 / 1.0 on it; sand ~0.57 / 0.0
            boolean prompt = GAME.equals(phase) && light < 60 && skip >= skipArea * 0.018;
            // In the world the button can vanish for a moment (a menu, a dialog, a flash of effects): keep the
            // speed and auto-hunt as they are for up to 10 checks (~30 s). Real logouts show their own windows.
            if (GAME.equals(phase) && !disconnected && !prompt && ++missingHud < 10) {
                status("In game (auto-hunt button hidden for a moment)");
                return;
            }
            hold(true);
            if (now - lastTap < 15000) return;
            if (disconnected) {
                tap(surface, yesX, yesY);
                lastTap = now;
                status("Disconnected: pressing Yes");
            } else if (GAME.equals(phase) && light < 60 && skip >= skipArea * 0.018) {
                // measured: ~25 of 900 bright with the prompt, 0-9 without; the prompt dims the screen to ~39
                // brightness, while the login screen (bright sky there too, and the support button) is ~140.
                tap(surface, right - 130 * s, 91 * s);
                lastTap = now;
                status("Skipping a tutorial prompt");
            } else if (SERVER.equals(phase)) {
                tap(surface, w / 2f, h - 150 * s); // Start Game
                lastTap = now;
                status("Starting the game");
            } else if (LOGIN.equals(phase)) {
                tap(surface, w / 2f, h - 72 * s); // Xerion Login (opens the login box)
                lastTap = now;
                status("Opening the login");
            } else {
                status(GAME.equals(phase) ? "In game, waiting for the HUD" : ENTERING.equals(phase) ? "Loading" : "Waiting");
            }
        }

        private static long blackSince;

        // Start the game over: a fresh task for its launcher activity, then end this (frozen) process.
        // Allowed because the game is in front; Android starts the new activity in a new process.
        private static void relaunch(Activity activity, String why) {
            Intent launch = activity.getPackageManager().getLaunchIntentForPackage(activity.getPackageName());
            if (launch == null || launch.getComponent() == null) return;
            status(why + ": restarting the game");
            Log.i(TAG, "watchdog: restarting the game (" + why + ")");
            Intent restart = Intent.makeRestartActivityTask(launch.getComponent());
            main.post(() -> {
                activity.startActivity(restart);
                main.postDelayed(() -> Runtime.getRuntime().exit(0), 500);
            });
        }

        // Can't see the game's picture: go by its log alone. In the world: the chosen speed (auto-hunt
        // isn't checked); logging in: 1× and the Start Game / Xerion Login taps. Neither: leave the speed be.
        private static void blind(View surface, int w, int h, float s, long now) {
            notHunting = 0;
            if (GAME.equals(phase) || phase.isEmpty()) {
                hold(false);
                status(phase.isEmpty() ? "Can't see the screen or the game's log: speed not held"
                    : "In game (can't see the screen, so auto-hunt isn't checked)");
                return;
            }
            hold(true);
            if (now - lastTap < 15000) return;
            if (SERVER.equals(phase)) {
                tap(surface, w / 2f, h - 150 * s);
                lastTap = now;
                status("Starting the game (can't see the screen)");
            } else if (LOGIN.equals(phase)) {
                tap(surface, w / 2f, h - 72 * s);
                lastTap = now;
                status("Opening the login (can't see the screen)");
            } else {
                status("Loading (can't see the screen)");
            }
        }

        // The whole game window (what the game draws when its view isn't a SurfaceView, or the GPU won't copy one).
        private static Bitmap captureWindow(Activity activity, View decor) {
            int w = decor.getWidth(), h = decor.getHeight();
            if (w <= 0 || h <= 0) return null;
            Bitmap bitmap = Bitmap.createBitmap(640, Math.max(1, 640 * h / w), Bitmap.Config.ARGB_8888);
            int[] result = {-1};
            CountDownLatch done = new CountDownLatch(1);
            try {
                PixelCopy.request(activity.getWindow(), bitmap, code -> { result[0] = code; done.countDown(); }, main);
            } catch (RuntimeException e) {
                bitmap.recycle();
                return null;
            }
            await(done);
            if (result[0] != PixelCopy.SUCCESS) {
                if (!copyFailureLogged) Log.w(TAG, "can't copy the game's window: PixelCopy " + result[0]);
                copyFailureLogged = true;
                bitmap.recycle();
                return null;
            }
            return bitmap;
        }

        private static boolean copyFailureLogged;

        /** A copy that came back black (the GPU gave nothing): every sampled pixel near black. */
        static boolean allBlack(Bitmap shot) {
            int dark = 0, all = 0;
            for (int y = 0; y < shot.getHeight(); y += 8) {
                for (int x = 0; x < shot.getWidth(); x += 8) {
                    int c = shot.getPixel(x, y);
                    all++;
                    if (Color.red(c) < 12 && Color.green(c) < 12 && Color.blue(c) < 12) dark++;
                }
            }
            return all > 0 && dark > all * 0.98;
        }

        // The game's login screens are the SDK's own Android windows over the game (measured with
        // uiautomator), so their buttons are pressed by id, at any screen size:
        //  - the account box: Log In (the SDK's generic confirm button, so only in the window that has the
        //    box's version label), with the saved account;
        //  - the screen behind it: Xerion Login (opens the box).
        private static boolean clickLogIn(Activity activity) {
            return clickById(activity, "nd_tv_confirm_btn_confirm", "nd_login_tv_version", null);
        }

        private static boolean clickAccountLogin(Activity activity) {
            return clickById(activity, "nd_other_account_login", null, null);
        }

        // The SDK's message boxes ("Conquer · Connection failed · OK", seen on a Galaxy Z Fold): the same
        // confirm button under the SDK's dialog title, in a window that isn't the account box.
        private static boolean clickMessageOk(Activity activity) {
            return clickById(activity, "nd_tv_confirm_btn_confirm", "nd_tv_dialog_title", "nd_login_tv_version");
        }

        /** Clicks `button` in the first window that shows it, has `alongside` (if given) and not `without`. */
        private static boolean clickById(Activity activity, String button, String alongside, String without) {
            android.content.res.Resources res = activity.getResources();
            int id = res.getIdentifier(button, "id", activity.getPackageName());
            int with = alongside == null ? 0 : res.getIdentifier(alongside, "id", activity.getPackageName());
            int not = without == null ? 0 : res.getIdentifier(without, "id", activity.getPackageName());
            if (id == 0 || (alongside != null && with == 0)) return false;
            boolean[] clicked = {false};
            CountDownLatch done = new CountDownLatch(1);
            main.post(() -> {
                try {
                    for (View root : rootViews()) {
                        View view = root.findViewById(id);
                        if (view != null && view.isShown() && (with == 0 || root.findViewById(with) != null)
                                && (not == 0 || root.findViewById(not) == null)) {
                            clicked[0] = view.performClick();
                            break;
                        }
                    }
                } catch (Throwable t) {
                    Log.w(TAG, "login screen", t);
                } finally {
                    done.countDown();
                }
            });
            await(done);
            return clicked[0];
        }

        @SuppressWarnings("unchecked")
        private static List<View> rootViews() throws ReflectiveOperationException {
            Class<?> global = Class.forName("android.view.WindowManagerGlobal");
            Object instance = global.getMethod("getInstance").invoke(null);
            Field views = global.getDeclaredField("mViews");
            views.setAccessible(true);
            return new ArrayList<>((List<View>) views.get(instance));
        }

        static SurfaceView findSurface(View view) {
            if (view instanceof SurfaceView && view.isShown()) return (SurfaceView) view;
            if (view instanceof ViewGroup) {
                ViewGroup group = (ViewGroup) view;
                for (int i = 0; i < group.getChildCount(); i++) {
                    SurfaceView found = findSurface(group.getChildAt(i));
                    if (found != null) return found;
                }
            }
            return null;
        }

        // A small copy (640 wide) of the game's picture.
        private static Bitmap capture(SurfaceView surface) {
            int w = surface.getWidth(), h = surface.getHeight();
            if (w <= 0 || h <= 0) return null;
            Bitmap bitmap = Bitmap.createBitmap(640, Math.max(1, 640 * h / w), Bitmap.Config.ARGB_8888);
            int[] result = {-1};
            CountDownLatch done = new CountDownLatch(1);
            try {
                PixelCopy.request(surface, bitmap, code -> { result[0] = code; done.countDown(); }, main);
            } catch (RuntimeException e) {
                bitmap.recycle();
                return null;
            }
            await(done);
            if (result[0] != PixelCopy.SUCCESS) {
                if (!surfaceFailureLogged) Log.w(TAG, "can't copy the game's view: PixelCopy " + result[0]);
                surfaceFailureLogged = true;
                bitmap.recycle();
                return null;
            }
            return bitmap;
        }

        private static boolean surfaceFailureLogged;

        // The auto-hunt button's crossed swords: bright strokes in a 28x28 box at the capture scale of a
        // 2560x1440 game (design scale 0.5), from MuMu.
        private static final String[] SWORDS = {
            "0000000000000000000000000000", "0000000000000000000000000000", "0000000000000000000000000000",
            "0000000000000000000000000000", "0000000000000000000000000000", "0000000000000000000000000000",
            "0000000000000000000000000000", "0000000000000000000000000000", "0000000011000000000110000000",
            "0000000001110000001100000000", "0000000000111000011100000000", "0000000000011001111000000000",
            "0000000000000011110000000000", "0000000000000111100000000000", "0000000000001111000000000000",
            "0000000000010010010000000000", "0000000000100100001000000000", "0000000000111000111000000000",
            "0000000001110000011110000000", "0000000011000000000110000000", "0000000010000000000000000000",
            "0000000000000000000000000000", "0000000000000000000000000000", "0000000000000000000000000000",
            "0000000000000000000000000000", "0000000000000000000000000000", "0000000000000000000000000000",
            "0000000000000000000000000000",
        };

        /**
         * Where the swords outline best matches the picture's bright strokes (normalized correlation),
         * searching 0-300 design px left of the usual spot and 24 up or down:
         * {match -1..1, shift, dy (design px), x, y, size (picture px)}.
         */
        static float[] findSwords(int[] px, int pw, int ph, int w, float s, float k) {
            int n = Math.max(8, Math.round(28 * s * k / 0.5f));
            float[] t = new float[n * n];
            float mean = 0;
            for (int i = 0; i < n; i++)
                for (int j = 0; j < n; j++) mean += t[i * n + j] = SWORDS[i * 28 / n].charAt(j * 28 / n) == '1' ? 1 : 0;
            mean /= n * n;
            float tn = 0;
            for (int i = 0; i < t.length; i++) { t[i] -= mean; tn += t[i] * t[i]; }
            tn = (float) Math.sqrt(tn);
            byte[] stroke = new byte[px.length];
            for (int i = 0; i < px.length; i++)
                if (Color.red(px[i]) > 170 && Color.green(px[i]) > 140) stroke[i] = 1;
            float[] best = {-1, 0, 0, 0, 0, n};
            for (int extra = 0; extra <= 300; extra += 2) {
                for (int dy = -24; dy <= 24; dy += 3) {
                    int x = Math.round((w - (100 + extra) * s) * k - n / 2f), y = Math.round((194 + dy) * s * k - n / 2f);
                    if (x < 0 || y < 0 || x + n > pw || y + n > ph) continue;
                    float dot = 0;
                    int on = 0;
                    for (int i = 0; i < n; i++) {
                        int row = (y + i) * pw + x;
                        for (int j = 0; j < n; j++)
                            if (stroke[row + j] != 0) { dot += t[i * n + j]; on++; }
                    }
                    float spread = on - on * (float) on / (n * n); // the window's variance × its size (binary)
                    if (spread <= 0) continue;
                    float match = dot / ((float) Math.sqrt(spread) * tn);
                    if (match > best[0]) best = new float[] {match, extra, dy, x, y, n};
                }
            }
            return best;
        }

        /** Of the bright stroke pixels in the found box, the share that is yellow (red - blue ≥ 60). */
        static float yellowShare(int[] px, int pw, int x, int y, int n) {
            int yellow = 0, bright = 0;
            for (int i = 0; i < n; i++) {
                for (int j = 0; j < n; j++) {
                    int c = px[(y + i) * pw + x + j], r = Color.red(c), g = Color.green(c), b = Color.blue(c);
                    if (r > 190 && g > 170) {
                        bright++;
                        if (r - b >= 60) yellow++;
                    }
                }
            }
            return bright == 0 ? 0 : yellow / (float) bright;
        }

        /** Share of a box that is the game's gold button colour. */
        static float goldShare(Bitmap shot, float x0, float y0, float x1, float y1) {
            int gold = 0, all = 0;
            for (int y = Math.max(0, (int) y0); y < Math.min(shot.getHeight(), y1); y++) {
                for (int x = Math.max(0, (int) x0); x < Math.min(shot.getWidth(), x1); x++) {
                    int c = shot.getPixel(x, y), r = Color.red(c), g = Color.green(c), b = Color.blue(c);
                    all++;
                    if (r > 190 && g > 160 && b > 90 && b < 190 && r - b > 50) gold++;
                }
            }
            return all == 0 ? 0 : gold / (float) all;
        }

        /** Share of black pixels in the outer fifths of the middle band (a message box on a black screen). */
        static float darkSides(Bitmap shot) {
            int w = shot.getWidth(), h = shot.getHeight(), dark = 0, all = 0;
            for (int y = h * 3 / 10; y < h * 7 / 10; y += 4) {
                for (int x = 0; x < w; x += 4) {
                    if (x >= w / 5 && x < w * 4 / 5) continue;
                    int c = shot.getPixel(x, y);
                    all++;
                    if (Color.red(c) < 30 && Color.green(c) < 30 && Color.blue(c) < 30) dark++;
                }
            }
            return all == 0 ? 0 : dark / (float) all;
        }

        private static long lastSaved;

        // What the watchdog last saw, for when it misreads a device's screen (another GPU, scaling):
        // <app external files>/watchdog.png, e.g. adb pull /sdcard/Android/data/com.com.Xerion/files/watchdog.png
        // Every 30 s at most, overwritten; a 640-wide picture.
        private static void saveForDebugging(Activity activity, Bitmap shot, long now) {
            if (now - lastSaved < 30000) return;
            lastSaved = now;
            java.io.File folder = activity.getExternalFilesDir(null);
            if (folder == null) return;
            try (java.io.FileOutputStream out = new java.io.FileOutputStream(new java.io.File(folder, "watchdog.png"))) {
                shot.compress(Bitmap.CompressFormat.PNG, 100, out);
            } catch (java.io.IOException | RuntimeException e) {
                Log.w(TAG, "can't save watchdog.png", e);
            }
        }

        /** Share of a box in the game's gold button colour (gold) or its blue-grey button colour (not gold). */
        static float shareOf(Bitmap shot, float x0, float y0, float x1, float y1, boolean gold) {
            int hit = 0, all = 0;
            for (int y = Math.max(0, (int) y0); y < Math.min(shot.getHeight(), y1); y++) {
                for (int x = Math.max(0, (int) x0); x < Math.min(shot.getWidth(), x1); x++) {
                    int c = shot.getPixel(x, y), r = Color.red(c), g = Color.green(c), b = Color.blue(c);
                    all++;
                    if (gold ? r > 160 && g > 140 && b < 150 && r - b > 40 : b > 140 && g > 130 && b - r > 15) hit++;
                }
            }
            return all == 0 ? 0 : hit / (float) all;
        }

        /** Average brightness (0-255) of the picture. */
        static int meanBrightness(Bitmap shot) {
            long sum = 0;
            int n = 0;
            for (int y = 0; y < shot.getHeight(); y += 8) {
                for (int x = 0; x < shot.getWidth(); x += 8) {
                    int c = shot.getPixel(x, y);
                    sum += (Color.red(c) + Color.green(c) + Color.blue(c)) / 3;
                    n++;
                }
            }
            return n == 0 ? 0 : (int) (sum / n);
        }

        /** Near-white pixels in a box. */
        static int bright(Bitmap shot, float x0, float y0, float x1, float y1) {
            int n = 0;
            for (int y = Math.max(0, (int) y0); y < Math.min(shot.getHeight(), y1); y++) {
                for (int x = Math.max(0, (int) x0); x < Math.min(shot.getWidth(), x1); x++) {
                    int c = shot.getPixel(x, y);
                    if (Color.red(c) > 200 && Color.green(c) > 200 && Color.blue(c) > 170) n++;
                }
            }
            return n;
        }

        // A tap the game sees as a finger (injecting into the app's own windows needs no permission).
        // A finger tap on the game. First straight into the game's own window, as Android delivers a finger
        // (no permission needed); only if the game doesn't take it, an injected touch, which phones can refuse
        // (seen on a Galaxy Z Fold: SecurityException, likely Samsung's game overlay above the game).
        private static void tap(View surface, float x, float y) {
            Activity activity = resumed;
            int[] at = new int[2];
            surface.getLocationInWindow(at);
            float wx = at[0] + x, wy = at[1] + y;
            long down = SystemClock.uptimeMillis();
            tappedAt = down;
            MotionEvent press = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, wx, wy, 0);
            press.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            MotionEvent release = MotionEvent.obtain(down, down + 80, MotionEvent.ACTION_UP, wx, wy, 0);
            release.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            try {
                boolean[] taken = {false};
                if (activity != null) {
                    onMain(() -> taken[0] = activity.dispatchTouchEvent(press));
                    SystemClock.sleep(80);
                    onMain(() -> activity.dispatchTouchEvent(release));
                }
                if (taken[0]) {
                    tapError = "";
                    return;
                }
                surface.getLocationOnScreen(at);
                press.setLocation(at[0] + x, at[1] + y);
                release.setLocation(at[0] + x, at[1] + y);
                Instrumentation input = new Instrumentation();
                input.sendPointerSync(press);
                SystemClock.sleep(80);
                input.sendPointerSync(release);
                tapError = "";
            } catch (RuntimeException e) {
                Log.w(TAG, "tap at " + x + "," + y, e);
                tapError = "tap refused (" + e.getClass().getSimpleName() + ")";
            } finally {
                press.recycle();
                release.recycle();
            }
        }

        private static void onMain(Runnable work) {
            CountDownLatch done = new CountDownLatch(1);
            main.post(() -> {
                try {
                    work.run();
                } finally {
                    done.countDown();
                }
            });
            await(done);
        }

        static volatile String tapError = "";

        private static void await(CountDownLatch latch) {
            try { latch.await(2, TimeUnit.SECONDS); } catch (InterruptedException ignored) {}
        }
    }

    @Override public void onActivityResumed(Activity activity) {
        resumed = activity;
        Drawer.resumed();
        addButton(activity);
    }
    @Override public void onActivityPaused(Activity activity) {
        if (Drawer.isSmall(activity)) { // shrunk to the floating window: still on screen, keep it going
            closePanel(activity);
            Drawer.keepPlaying(activity);
            return;
        }
        if (resumed == activity) resumed = null;
        closePanel(activity);
    }
    @Override public void onActivityCreated(Activity activity, Bundle state) {}
    @Override public void onActivityStarted(Activity activity) {}
    @Override public void onActivityStopped(Activity activity) {}
    @Override public void onActivitySaveInstanceState(Activity activity, Bundle state) {}
    @Override public void onActivityDestroyed(Activity activity) {
        removeButton(activity);
    }

    /**
     * The drawer: the game shrinks to Android's picture-in-picture window, which floats over other
     * apps and can be pushed to the screen's edge (tap it there to bring it back). The game is still
     * on screen, so it keeps its picture and its engine keeps running: it draws (and so plays) on its
     * GL thread, which the game pauses with its activity; that's resumed here. Tap the window to get
     * the game back. In the small window the watchdog doesn't read the screen; it follows the game's
     * log: when the game drops out of the world (or every 10 minutes, to check auto-hunt) it brings the
     * game back full screen, puts it right, and shrinks it again once it's hunting at the chosen speed.
     */
    static final class Drawer {
        private static final long CHECK_EVERY = 10 * 60000;
        static volatile boolean woken; // the watchdog brought it back to fix something
        private static volatile Activity small; // the game, while shrunk by the player
        private static volatile long hiddenAt;

        static boolean isSmall(Activity activity) {
            return activity != null && activity.isInPictureInPictureMode();
        }

        static void hide(Activity activity) {
            closePanel(activity);
            try {
                if (!activity.enterPictureInPictureMode(new PictureInPictureParams.Builder()
                        .setAspectRatio(new Rational(16, 9)).build())) throw new IllegalStateException("refused");
                small = activity;
                woken = false;
                hiddenAt = SystemClock.uptimeMillis();
                Log.i(TAG, "drawer: game shrunk");
            } catch (RuntimeException e) {
                Log.w(TAG, "drawer: no picture-in-picture", e);
                Toast.makeText(activity, "Can't minimize: open the Speed Patcher and tap Update speed patch", Toast.LENGTH_LONG).show();
            }
        }

        // The game paused itself (and its GL thread) on shrinking: keep it drawing, and so playing.
        static void keepPlaying(Activity activity) {
            main.postDelayed(() -> {
                if (!isSmall(activity)) return;
                TextView button = buttons.get(activity); // it would cover the small window; back on resume
                if (button != null) button.setVisibility(View.GONE);
                SurfaceView view = Watchdog.findSurface(activity.getWindow().getDecorView());
                try { // C3DemoGLSurfaceView: the engine's own GL view, paused and resumed like GLSurfaceView
                    view.getClass().getMethod("onResume").invoke(view);
                    Log.i(TAG, "drawer: game kept running");
                } catch (Throwable t) {
                    Log.w(TAG, "drawer: can't keep the game running: " + view, t);
                }
            }, 300);
        }

        // Back full screen: by the player (the drawer is done) or by the watchdog (it shrinks it again).
        static void resumed() {
            if (!woken) small = null;
        }

        private static void bringBack(Context app) {
            Intent launch = app.getPackageManager().getLaunchIntentForPackage(app.getPackageName());
            if (launch == null) return;
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK); // the running game's task, full screen again
            try {
                app.startActivity(launch);
            } catch (RuntimeException e) {
                Log.w(TAG, "drawer: can't bring the game back", e);
            }
        }

        // Watchdog thread, every 3 s.
        static void check() {
            if (woken || !isSmall(small)) return;
            String phase = Watchdog.phase;
            boolean out = !phase.isEmpty() && !Watchdog.GAME.equals(phase);
            if (!out && SystemClock.uptimeMillis() - hiddenAt < CHECK_EVERY) return;
            woken = true;
            Watchdog.status(out ? "Out of the game: bringing it back full screen" : "Checking auto-hunt (full screen for a moment)");
            main.post(() -> bringBack(application));
        }

        // Watchdog: hunting at the chosen speed again, so small again if it came back for that.
        // Not while the log says it's logging in: after a drop the world stays on screen a few seconds.
        static void fixed() {
            String phase = Watchdog.phase;
            if (!woken || small == null || !phase.isEmpty() && !Watchdog.GAME.equals(phase)) return;
            main.post(() -> {
                Activity activity = resumed;
                if (activity == null || !woken || isSmall(activity)) return;
                woken = false;
                hide(activity);
            });
        }
    }
}
