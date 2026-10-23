#!/bin/bash
# Runs bundle.sh with a stubbed swiftc that fails the macro probe; expects guidance, non-zero exit, no build.
set -uo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
# swiftc fails the macro probe; swift only records that a build was attempted.
cat > "$T/bin/swiftc" <<'STUB'
#!/bin/bash
echo "error: plugin for module 'SwiftUIMacros' not found" >&2
exit 1
STUB
cat > "$T/bin/swift" <<STUB
#!/bin/bash
echo "\$*" >> "$T/calls"
STUB
chmod +x "$T/bin/swiftc" "$T/bin/swift"
out="$(PATH="$T/bin:$PATH" XCODE_APPS_GLOB="$T/none/Xcode*.app" DIST_DIR="$T/dist" scripts/bundle.sh 2>&1)"; code=$?
fail() { echo "FAIL: $1"; echo "$out"; exit 1; }
[ "$code" -ne 0 ] || fail "expected non-zero exit"
for s in "full Xcode" "xcode-select" "Releases" "Your current Hush is untouched."; do
  grep -qF "$s" <<<"$out" || fail "missing guidance: $s"
done
[ ! -e "$T/calls" ] || fail "build started"
echo "ok"
