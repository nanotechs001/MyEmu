package com.myemu.speed;

import android.app.Activity;
import android.app.Application;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.WindowManager;
import android.widget.TextView;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;

/**
 * The floating speed button inside a patched Xerion. Loaded from memory by libjnigraphicz.so
 * (native/xerion_speed.c), which also provides setSpeed. Tap: next speed; drag: move it.
 * The speed and position are kept in the game's own "myemu_speed" preferences.
 */
public final class SpeedOverlay implements Application.ActivityLifecycleCallbacks {
    static native void setSpeed(double speed);

    private static final String TAG = "myemu_speed";
    private static final double[] SPEEDS = {1, 1.5, 2, 2.5, 3, 4, 5};
    private static final Map<Activity, TextView> buttons = new WeakHashMap<>();
    private static SharedPreferences prefs;
    private static int index;

    public static void start() {
        new Handler(Looper.getMainLooper()).post(SpeedOverlay::attach);
    }

    private static void attach() {
        try {
            Class<?> thread = Class.forName("android.app.ActivityThread");
            Application app = (Application) thread.getMethod("currentApplication").invoke(null);
            prefs = app.getSharedPreferences(TAG, 0);
            index = Math.min(Math.max(prefs.getInt("index", 0), 0), SPEEDS.length - 1);
            setSpeed(SPEEDS[index]);
            app.registerActivityLifecycleCallbacks(new SpeedOverlay());
            for (Activity activity : runningActivities(thread)) addButton(activity);
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

    private static String label() {
        double s = SPEEDS[index];
        return (s == Math.rint(s) ? String.valueOf((int) s) : String.valueOf(s)) + "×";
    }

    // The button is a small window of its own: Xerion covers its activity with a transparent
    // full-screen window that takes every touch, so a view inside the activity can't be tapped.
    // Re-added on every resume so it sits above the game's windows.
    private static void addButton(Activity activity) {
        TextView old = buttons.remove(activity);
        if (old != null) {
            try { activity.getWindowManager().removeViewImmediate(old); } catch (RuntimeException ignored) {}
        }
        float dp = activity.getResources().getDisplayMetrics().density;
        TextView button = new TextView(activity);
        button.setText(label());
        button.setTextColor(Color.WHITE);
        button.setTextSize(15);
        button.setTypeface(Typeface.DEFAULT_BOLD);
        button.setGravity(Gravity.CENTER);
        button.setMinWidth((int) (48 * dp));
        button.setMinHeight((int) (48 * dp));
        button.setPadding((int) (10 * dp), 0, (int) (10 * dp), 0);
        GradientDrawable background = new GradientDrawable();
        background.setColor(0x99000000);
        background.setCornerRadius(24 * dp);
        background.setStroke((int) dp, 0x66FFFFFF);
        button.setBackground(background);
        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.TOP | Gravity.START;
        params.x = (int) prefs.getFloat("x", 16 * dp);
        params.y = (int) prefs.getFloat("y", 96 * dp);
        if (Build.VERSION.SDK_INT >= 28)
            params.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
        button.setOnTouchListener(new Drag(activity.getWindowManager(), params, ViewConfiguration.get(activity).getScaledTouchSlop()));
        try {
            activity.getWindowManager().addView(button, params);
            buttons.put(activity, button);
        } catch (RuntimeException e) {
            Log.w(TAG, "no speed button on " + activity, e);
        }
    }

    private static final class Drag implements View.OnTouchListener {
        private final WindowManager windows;
        private final WindowManager.LayoutParams params;
        private final int slop;
        private float downX, downY;
        private int startX, startY;
        private boolean dragging;

        Drag(WindowManager windows, WindowManager.LayoutParams params, int slop) {
            this.windows = windows;
            this.params = params;
            this.slop = slop;
        }

        @Override
        public boolean onTouch(View v, MotionEvent e) {
            switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                downX = e.getRawX(); downY = e.getRawY();
                startX = params.x; startY = params.y;
                dragging = false;
                return true;
            case MotionEvent.ACTION_MOVE:
                float dx = e.getRawX() - downX, dy = e.getRawY() - downY;
                if (!dragging && Math.hypot(dx, dy) > slop) dragging = true;
                if (dragging) {
                    View screen = v.getRootView();
                    int width = v.getResources().getDisplayMetrics().widthPixels;
                    int height = v.getResources().getDisplayMetrics().heightPixels;
                    params.x = (int) Math.max(0, Math.min(startX + dx, width - screen.getWidth()));
                    params.y = (int) Math.max(0, Math.min(startY + dy, height - screen.getHeight()));
                    windows.updateViewLayout(v, params);
                }
                return true;
            case MotionEvent.ACTION_UP:
                if (dragging) {
                    prefs.edit().putFloat("x", params.x).putFloat("y", params.y).apply();
                } else {
                    index = (index + 1) % SPEEDS.length;
                    setSpeed(SPEEDS[index]);
                    prefs.edit().putInt("index", index).apply();
                    ((TextView) v).setText(label());
                }
                return true;
            default:
                return false;
            }
        }
    }

    @Override public void onActivityResumed(Activity activity) { addButton(activity); }
    @Override public void onActivityCreated(Activity activity, Bundle state) {}
    @Override public void onActivityStarted(Activity activity) {}
    @Override public void onActivityPaused(Activity activity) {}
    @Override public void onActivityStopped(Activity activity) {}
    @Override public void onActivitySaveInstanceState(Activity activity, Bundle state) {}
    @Override public void onActivityDestroyed(Activity activity) {
        TextView button = buttons.remove(activity);
        if (button != null) {
            try { activity.getWindowManager().removeViewImmediate(button); } catch (RuntimeException ignored) {}
        }
    }
}
