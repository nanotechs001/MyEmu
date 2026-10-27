#!/bin/bash
# Frame-spike stress test: 20 s of frame times inside Android plus MyEmu's slow-frame log.
# Run with MyEmu open in front and a continuously animating game (e.g. Conquer Online's login screen).
# Usage: scripts/stress-test.sh <label> <old-text-field-check 0|1> <driver-log 0|1> <busy-cpu-threads>
#   e.g. scripts/stress-test.sh new 0 0 8      (8 busy threads oversubscribe Android's 6 vCPUs)
# Leaves Android at 180 fps for the game; leave log 0 to keep the driver log quiet afterwards.
A=~/Library/Android/sdk/platform-tools/adb; S=${SERIAL:-emulator-5554}; G=${GAME:-com.Tq.CQ2ClientAndroid}
P="${TMPDIR:-/tmp}/myemu-stress"; mkdir -p "$P"; SECS=20
label=$1; oldcheck=$2; driverlog=$3; cpu=$4
$A -s $S shell "settings put system peak_refresh_rate 180.0; settings put system min_refresh_rate 180.0; cmd game set --fps 180 $G; setprop log.tag.MESA $([ $driverlog = 1 ] && echo I || echo W)" >/dev/null
[ "$cpu" -gt 0 ] && $A -s $S shell "for i in \$(seq 1 $cpu); do timeout $((SECS+3)) sh -c 'while :; do :; done' & done" >/dev/null 2>&1 &
if [ $oldcheck = 1 ]; then ( end=$((SECONDS+SECS)); while [ $SECONDS -lt $end ]; do $A -s $S shell "dumpsys input_method 2>/dev/null | grep -m1 -A1 'mCurrentEditorInfo:' | grep -o 'inputType=0x[0-9a-f]*'" >/dev/null; sleep 0.5; done ) & fi
log stream --level debug --predicate 'subsystem == "MyEmu" AND category == "frames"' > "$P/host-$label.txt" 2>/dev/null & LS=$!
sleep 1; $A -s $S shell 'dumpsys SurfaceFlinger --timestats -clear -enable' >/dev/null
sleep $SECS
$A -s $S shell 'dumpsys SurfaceFlinger --timestats -dump' > "$P/ts-$label.txt"; $A -s $S shell 'dumpsys SurfaceFlinger --timestats -disable' >/dev/null
kill $LS 2>/dev/null; wait 2>/dev/null
awk '/presentToPresent histogram/ && !h {getline; h=$0} END{print h}' "$P/ts-$label.txt" | tr ' ' '\n' | awk -F= '$2>0 {sub("ms","",$1); ms=$1+0; n=$2+0; tot+=n; t+=ms*n; if(ms>=25&&ms<40) mid+=n; if(ms>=40){big+=n; bl=bl" "ms}} END{printf "%-26s %4.0f fps | 25-39 ms: %3d | >=40 ms: %2d [%s ]", L, tot/SECS, mid, big, bl}' L="$label" SECS=$SECS
echo " | MyEmu slow arrivals: $(grep -c 'slow frame' "$P/host-$label.txt")"
