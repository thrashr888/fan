#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/fan-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin"
cp "$repo_dir/fan" "$test_dir/fan"

cat >"$test_dir/fan-rpm" <<'EOF'
#!/bin/sh
printf '0\t2500\n'
EOF
cat >"$test_dir/bin/ps" <<'EOF'
#!/bin/sh
case "$1" in
  -axo)
    cat <<'PROCESSES'
100 1 70.0 /usr/libexec/spotlightknowledged.updater
101 1 30.0 /usr/libexec/syspolicyd
102 1 25.0 /usr/libexec/mediaanalysisd
103 1 20.0 /System/Library/PrivateFrameworks/FileProvider.framework/Support/fileproviderd
104 1 18.0 /System/Library/Frameworks/Virtualization.framework/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
105 1 16.0 /System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd
106 1 14.0 /Library/SystemExtensions/com.cisco.anyconnect.macos.acsockext
107 1 12.0 /Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary
108 107 23.0 /Applications/Google Chrome Canary.app/Contents/Helpers/Google Chrome Helper
PROCESSES
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$test_dir/fan-rpm" "$test_dir/bin/ps"

output=$(NO_COLOR=1 PATH="$test_dir/bin:$PATH" "$test_dir/fan" -s 1 -n 20)
escape=$(printf '\033')
case "$output" in
  *"$escape"*) printf 'NO_COLOR output contains ANSI escapes\n' >&2; exit 1 ;;
esac
for phrase in 'Spotlight' 'syspolicyd performs' 'Media analysis' 'fileproviderd handles' 'virtual machine is running' 'corespeechd is' 'managed Cisco' 'Try closing a busy tab in Google Chrome Canary'; do
  case "$output" in
    *"$phrase"*) ;;
    *) printf 'Missing %s in guidance:\n%s\n' "$phrase" "$output" >&2; exit 1 ;;
  esac
done
case "$output" in
  *'kill -TERM '*) printf 'Unsafe kill suggestion:\n%s\n' "$output" >&2; exit 1 ;;
esac
printf '%s\n' "$output" | awk '
  /^osascript -e / {
    found = 1
    if (getline line <= 0 || line != "") bad = 1
  }
  END { exit bad || !found }
' || { printf 'Quit command must be followed by a blank line\n' >&2; exit 1; }
printf '%s\n' 'fan guidance test passed'
