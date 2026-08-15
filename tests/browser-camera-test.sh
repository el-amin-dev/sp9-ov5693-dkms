#!/usr/bin/env bash
# Drive a browser at the camera probe and report what it actually got.
#
#   ./tests/browser-camera-test.sh                  # Chrome, PipeWire backend
#   ./tests/browser-camera-test.sh --no-pipewire    # control run, raw V4L2
#   ./tests/browser-camera-test.sh --headful        # real window in the session
#   WIDTH=640 ./tests/browser-camera-test.sh        # negotiate a different size
#
# Chrome always runs against a throwaway profile under out/, never the user's
# own profile, so an experiment cannot disturb a running browser or its settings.
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1

OUT="out"
PORT="${PORT:-8765}"
WIDTH="${WIDTH:-1920}"
mkdir -p "${OUT}"

pipewire=1
headful=0
for arg in "$@"; do
	case ${arg} in
	--no-pipewire) pipewire=0 ;;
	--headful) headful=1 ;;
	*) echo "unknown option: ${arg}" >&2; exit 2 ;;
	esac
done

label=$([[ ${pipewire} -eq 1 ]] && echo pipewire || echo v4l2)
log="${OUT}/chrome-${label}-${WIDTH}.log"

flags=(
	--user-data-dir="$(pwd)/${OUT}/chrome-profile"
	--no-first-run --no-default-browser-check
	--use-fake-ui-for-media-stream # auto-grant getUserMedia, no human needed
	# A headless page counts as hidden, and Chrome throttles timers in hidden
	# pages to about one tick a minute -- which stalls the probe's settle delay
	# and makes a working camera look like a hang.
	--disable-background-timer-throttling
	--disable-backgrounding-occluded-windows
	--disable-renderer-backgrounding
)
# chrome://flags entries are not base::Features -- Chrome 151 carries the flag id
# "enable-webrtc-pipewire-camera" but no matching feature name, so
# --enable-features cannot switch it on and silently does nothing. Persist it in
# Local State exactly as the chrome://flags UI would, which is also what the user
# has to do in their own profile.
python3 - "$(pwd)/${OUT}/chrome-profile" "${pipewire}" <<'PY'
import json, pathlib, sys
profile, on = pathlib.Path(sys.argv[1]), sys.argv[2] == "1"
profile.mkdir(parents=True, exist_ok=True)
state_path = profile / "Local State"
state = json.loads(state_path.read_text()) if state_path.exists() else {}
labs = set(state.setdefault("browser", {}).get("enabled_labs_experiments", []))
labs.discard("enable-webrtc-pipewire-camera@1")
if on:
    labs.add("enable-webrtc-pipewire-camera@1")
state["browser"]["enabled_labs_experiments"] = sorted(labs)
state_path.write_text(json.dumps(state))
PY
[[ ${headful} -eq 1 ]] || flags+=(--headless=new)

# The portal asks for camera permission the first time. Headless has no way to
# answer that dialog, so the first run on a machine has to be --headful.
DEADLINE="${DEADLINE:-75}"

echo "== chrome backend=${label} width=${WIDTH} headful=${headful}"

# The probe posts its verdict back to this server, which exits when it arrives.
python3 tests/serve-probe.py --port "${PORT}" --timeout "${DEADLINE}" >"${OUT}/serve.log" 2>&1 &
server=$!
sleep 1

google-chrome "${flags[@]}" "http://127.0.0.1:${PORT}/cam-test.html?auto=1&w=${WIDTH}" \
	>"${log}" 2>&1 &
browser=$!

wait "${server}"
rc=$?
kill "${browser}" 2>/dev/null
wait "${browser}" 2>/dev/null

if [[ ${rc} -ne 0 ]]; then
	echo "   NO RESULT within the deadline; chrome stderr tail:"
	tail -8 "${log}" | sed 's/^/   | /'
	exit 1
fi

python3 -c '
import json, pathlib
d = json.loads(pathlib.Path("out/browser-result.json").read_text())
for line in d.get("lines", []):
    print("  ", line)
print("   VERDICT:", d.get("verdict"))
'
