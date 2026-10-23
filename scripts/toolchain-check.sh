# Sourced by scripts/bundle.sh. Checks that the selected developer toolchain can expand SwiftUI macros
# (@State needs the plugin that ships with full Xcode). If not, tries an installed Xcode via DEVELOPER_DIR
# (the global xcode-select setting is left alone), else prints guidance and exits non-zero.
# Overrides for tests: SWIFTC (compiler command), XCODE_APPS_GLOB (where to look for Xcode apps).

toolchain_probe() {
  local dir file rc=0
  dir="$(mktemp -d)"
  file="$dir/Probe.swift"
  printf 'import SwiftUI\nstruct Probe: View {\n  @State private var n = 0\n  var body: some View { Text("\\(n)") }\n}\n' > "$file"
  "${SWIFTC:-swiftc}" -typecheck -parse-as-library "$file" >/dev/null 2>&1 || rc=$?
  rm -rf "$dir"
  return $rc
}

toolchain_guidance() {
  cat >&2 <<'MSG'
error: Building Hush needs a full Xcode. The Command Line Tools alone can't expand SwiftUI macros.
Fix it one of two ways:
  - Install full Xcode, or select an installed one: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  - Use the Releases channel instead; it needs no developer tools.
Your current Hush is untouched.
MSG
}

toolchain_check() {
  if ! command -v "${SWIFTC:-swiftc}" >/dev/null 2>&1; then toolchain_guidance; exit 1; fi
  if toolchain_probe; then return 0; fi
  local app glob="${XCODE_APPS_GLOB:-/Applications/Xcode*.app}"
  # Newest first (reverse lexical order is good enough for Xcode.app / Xcode-16.2.app names).
  for app in $(ls -d $glob 2>/dev/null | sort -r); do
    [ -d "$app/Contents/Developer" ] || continue
    if DEVELOPER_DIR="$app/Contents/Developer" toolchain_probe; then
      export DEVELOPER_DIR="$app/Contents/Developer"
      echo "Using $DEVELOPER_DIR for this build" >&2
      return 0
    fi
  done
  toolchain_guidance
  exit 1
}

toolchain_check
