#!/bin/bash
# Records the Codex demo in the iPhone simulator (XCUITest drives it) and cuts it
# for X. Cut points come from the video itself, not test timestamps (under load
# the recorder lags the app by seconds):
#   start   0.5 s before the sidebar first scrolls (after it has sat still)
#   2nd     still stretch after the picker (Codex starting)  -> 8x
#   3rd     Codex thinking, from the send to the reply        -> 3x
#   end     just before the jump to the simulator home screen
# Raw files go to a temp dir, not ~/coding (Syncthing churns on them).
# Usage: demo/make-codex-demo.sh <simulator-udid> [output.mp4]   (CUT_ONLY=1 WORK=<dir> re-cuts an existing raw.mov)
set -euo pipefail
UDID=$1; HERE=$(cd "$(dirname "$0")" && pwd); FINAL=${2:-$HERE/damon-mobile-codex-demo.mp4}
WORK=${WORK:-$(mktemp -d /tmp/damon-demo.XXXX)}
PROMPT=${DEMO_PROMPT:-"Give me 3 thumbnail text ideas for a video about running my AI agents from my phone. Keep it short."}
if [ -z "${CUT_ONLY:-}" ]; then
cd "$HERE/../ios"
xcodegen generate -q
xcodebuild -project Damon.xcodeproj -scheme Damon -destination "id=$UDID" -derivedDataPath build/uitest build-for-testing -quiet
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiBars 3 --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl io "$UDID" recordVideo --force "$WORK/raw.mov" > /dev/null 2>&1 &
REC=$!; sleep 1.5
TEST_RUNNER_DEMO_AGENT=${DEMO_AGENT:?set DEMO_AGENT to an agent (workspace) name shown in the sidebar} TEST_RUNNER_DEMO_PROMPT="$PROMPT" \
  xcodebuild -project Damon.xcodeproj -scheme Damon -destination "id=$UDID" -derivedDataPath build/uitest \
  test-without-building -only-testing:DamonUITests/DemoRecording/testCodexDemo > "$WORK/test.log" 2>&1
kill -INT $REC; wait $REC 2>/dev/null || true
fi
ffmpeg -loglevel error -i "$WORK/raw.mov" -vf "fps=20,scale=88:190" -f rawvideo -pix_fmt gray -y "$WORK/frames.gray"

python3 - "$WORK" > "$WORK/cut.env" <<'PY'
import sys
work = sys.argv[1]
n, fps = 88 * 190, 20
d = open(f"{work}/frames.gray", "rb").read()
fr = [d[i:i + n] for i in range(0, len(d) - n + 1, n)]
diff = [sum(abs(a - b) for a, b in zip(fr[i][::3], fr[i + 1][::3])) / (n / 3) for i in range(len(fr) - 1)]
moving = [v > 2 for v in diff]
def still_runs(min_len):
    runs, start = [], None
    for i, m in enumerate(moving + [True]):
        if not m and start is None: start = i
        if m and start is not None:
            if i - start >= min_len: runs.append((start, i))
            start = None
    return runs
# End: the last full-screen jump is the app closing to the home screen.
end = max(i for i, v in enumerate(diff) if v > 25)
# Start: first sustained motion after the app's launch flash (the first
# full-screen change) that follows >=1 s of stillness, i.e. the sidebar at rest.
launch = next(i for i, v in enumerate(diff) if v > 25)
start = next(i for i in range(launch + fps, end) if all(moving[i:i + 4]) and not any(moving[i - fps:i]))
# The two long waits before the end: Codex starting (>=3 s) then thinking (>=1.5 s).
waits = [r for r in still_runs(int(1.5 * fps)) if start + 2 * fps < r[0] < end - fps]
boot = next(r for r in waits if r[1] - r[0] >= 3 * fps)
# Typing only nudges a few pixels, so it reads as "still" above; end the boot
# wait at the first change of any size, so the typing plays at real speed.
boot = (boot[0], next((i for i in range(boot[0] + fps, boot[1]) if diff[i] > 0.3), boot[1]))
# Codex thinking: the gap between the send (the last big change before a quiet
# stretch) and the reply (the last big change before the app closes).
events = [i for i in range(boot[1], end - 2) if diff[i] > 2]
think = None
if events:
    reply = events[-1]
    while reply > events[0] and diff[reply - 1] > 2: reply -= 1
    before = [i for i in events if i < reply - 2 * fps]
    if before: think = (before[-1] + fps // 2, reply - 5)
t = lambda i: f"{i / fps:.2f}"
print(f"A={t(max(0, start - fps // 2))}")
print(f"B={t(boot[0] + 6)} C={t(boot[1] - 4)}")
print(f"S1={t(think[0])} S2={t(think[1])}" if think else f"S1={t(boot[1])} S2={t(boot[1])}")
print(f"E={t(end - 4)}")
PY
. "$WORK/cut.env"
ffmpeg -loglevel error -i "$WORK/raw.mov" -filter_complex \
  "[0:v]fps=60,split=5[a][b][c][d][e];[a]trim=$A:$B,setpts=PTS-STARTPTS[v1];[b]trim=$B:$C,setpts=(PTS-STARTPTS)/8[v2];\
[c]trim=$C:$S1,setpts=PTS-STARTPTS[v3];[d]trim=$S1:$S2,setpts=(PTS-STARTPTS)/3[v4];[e]trim=$S2:$E,setpts=PTS-STARTPTS[v5];\
[v1][v2][v3][v4][v5]concat=n=5:v=1:a=0,fps=60,scale=-2:1900,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -preset slow -crf 18 -movflags +faststart -an -y "$FINAL"
echo "$FINAL ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FINAL")s) cuts: $(tr '\n' ' ' < "$WORK/cut.env")"
