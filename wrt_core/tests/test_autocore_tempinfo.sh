#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/package/emortal/autocore/files/tempinfo" >&2
    exit 1
fi

BASE_PATH=$(cd "$(dirname "$0")/.." && pwd)
source <(sed 's/\r$//' "$BASE_PATH/modules/target_fixes.sh")

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
BUILD_DIR="$test_dir/build"
tempinfo="$BUILD_DIR/package/emortal/autocore/files/tempinfo"
mkdir -p "$(dirname "$tempinfo")" "$test_dir"/{net,thermal,ieee80211,bin}
sed 's/\r$//' "$1" > "$tempinfo"

mkdir -p "$BUILD_DIR/include" "$BUILD_DIR/package/emortal/default-settings/files"
printf 'VERSION_REPO:=https://downloads.openwrt.org\n' > "$BUILD_DIR/include/version.mk"
printf '#!/bin/sh\n' > "$BUILD_DIR/package/emortal/default-settings/files/99-default-settings-chinese"
THEME_SET=argon
fix_default_set > "$test_dir/default-set.log" 2>&1
grep -q 'local mtwifi_present=0' "$tempinfo"
echo "PASS: normal build entry applies temperature patch"
first_hash=$(sha256sum "$tempinfo")
fix_autocore_mtwifi_temperature
[ "$first_hash" = "$(sha256sum "$tempinfo")" ]
echo "PASS: patch is idempotent"

printf "DISTRIB_TARGET='mediatek/filogic'\n" > "$test_dir/openwrt_release"
sed \
    -e "s|/etc/openwrt_release|$test_dir/openwrt_release|g" \
    -e "s|/sys/class/net/|$test_dir/net/|g" \
    -e "s|/sys/class/thermal|$test_dir/thermal|g" \
    -e "s|/sys/class/ieee80211|$test_dir/ieee80211|g" \
    "$tempinfo" > "$test_dir/tempinfo"
sh -n "$test_dir/tempinfo"

cat > "$test_dir/bin/iwpriv" <<'EOF'
#!/bin/sh
echo "$1" >> "$MOCK_IWPRIV_LOG"
[ "$MOCK_WIFI_TEMP" = "missing" ] || printf 'CurrentTemperature = %s\n' "$MOCK_WIFI_TEMP"
EOF
chmod +x "$test_dir/bin/iwpriv"
export PATH="$test_dir/bin:$PATH"
export MOCK_IWPRIV_LOG="$test_dir/iwpriv.log"
export MOCK_WIFI_TEMP=42
degree=$(printf '\302\260')

assert_tempinfo() {
    local expected="$1"
    local actual
    actual=$(sh "$test_dir/tempinfo")
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: expected <%s>, got <%s>\n' "$expected" "$actual" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$expected"
}

mkdir -p "$test_dir/thermal/thermal_zone0"
printf '35700\n' > "$test_dir/thermal/thermal_zone0/temp"
assert_tempinfo "CPU: 35.7${degree}C"
[ ! -e "$MOCK_IWPRIV_LOG" ]
echo "PASS: no iwpriv probe without wireless interfaces"

mkdir -p "$test_dir/net/ra0"
printf '0x1\n' > "$test_dir/net/ra0/flags"
assert_tempinfo "CPU: 35.7${degree}C, WiFi: 42${degree}C"

mkdir -p "$test_dir/net/rax0"
printf '0x1\n' > "$test_dir/net/rax0/flags"
assert_tempinfo "CPU: 35.7${degree}C, WiFi: 42${degree}C/42${degree}C"
rm "$test_dir/net/rax0/flags"

printf '0x0\n' > "$test_dir/net/ra0/flags"
assert_tempinfo "CPU: 35.7${degree}C, WiFi: unknown"

printf '0x1\n' > "$test_dir/net/ra0/flags"
export MOCK_WIFI_TEMP=missing
assert_tempinfo "CPU: 35.7${degree}C, WiFi: unknown"

export MOCK_WIFI_TEMP=42
rm "$test_dir/thermal/thermal_zone0/temp"
assert_tempinfo "WiFi: 42${degree}C"

rm "$test_dir/net/ra0/flags"
assert_tempinfo "No temperature info"

printf '#!/bin/sh\nprintf cpu-only\n' > "$tempinfo"
first_hash=$(sha256sum "$tempinfo")
fix_autocore_mtwifi_temperature
[ "$first_hash" = "$(sha256sum "$tempinfo")" ]
echo "PASS: source without vendor temperature helper is unchanged"

printf '#!/bin/sh\nget_mtwifi_temp() { echo changed; }\n' > "$tempinfo"
if fix_autocore_mtwifi_temperature > "$test_dir/patch-error.log" 2>&1; then
    echo "FAIL: incompatible temperature source was accepted" >&2
    exit 1
fi
grep -q 'ERROR: autocore-tempinfo-mtwifi.patch failed' "$test_dir/patch-error.log"
echo "PASS: incompatible source reports patch failure"
