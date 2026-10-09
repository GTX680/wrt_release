#!/usr/bin/env bash
set -euo pipefail

BASE_PATH=$(cd "$(dirname "$0")/.." && pwd)
source <(sed 's/\r$//' "$BASE_PATH/modules/feed_source_fixes.sh")

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
release_base=https://release.66666.host
fixture_version=3.1.4
fixture_mode=normal

# Model the live service: browser URLs return HTML, the browse endpoint returns JSON.
curl_retry() {
    local output_file=""
    local url="${!#}"
    while (( $# )); do
        case "$1" in
            -o) output_file="$2"; shift ;;
        esac
        shift
    done
    [[ -n $output_file ]]
    printf '%s\n' "$url" >> "$test_dir/requests"

    case "$fixture_mode" in
        network-error) return 22 ;;
        invalid-json) printf '\n<!DOCTYPE html><title>File service</title>\n' > "$output_file"; return ;;
        invalid-schema) printf '{"error":"unavailable"}\n' > "$output_file"; return ;;
    esac

    case "$url" in
        "$release_base/.lucky-browse.json?"*)
            printf '[{"name":"v3.1.3beta","is_dir":true,"mod_time":"2026-10-07T12:05:12Z"},{"name":"v%sbeta","is_dir":true,"mod_time":"2026-10-08T11:58:17Z"}]\n' \
                "$fixture_version" > "$output_file"
            ;;
        "$release_base/v${fixture_version}beta/.lucky-browse.json?"*)
            printf '[{"name":"%s_wanji_docker","is_dir":true,"mod_time":"2026-10-08T11:55:17Z"}]\n' \
                "$fixture_version" > "$output_file"
            ;;
        "$release_base/v${fixture_version}beta/${fixture_version}_wanji_docker/.lucky-browse.json?"*)
            if [[ $fixture_mode == missing-package ]]; then
                printf '[{"name":"lucky_%s_Linux_arm64_wanji_docker.tar.gz","is_dir":false}]\n' \
                    "$fixture_version" > "$output_file"
            else
                printf '[{"name":"lucky_%s_Linux_arm64_wanji_docker.tar.gz","is_dir":false},{"name":"lucky_%s_Linux_x86_64_wanji_docker.tar.gz","is_dir":false}]\n' \
                    "$fixture_version" "$fixture_version" > "$output_file"
            fi
            ;;
        *) printf '\n<!DOCTYPE html><title>File service</title>\n' > "$output_file" ;;
    esac
}

fetch_lucky_release_index "$release_base/" "$test_dir/index.json"
grep -Fq "$release_base/.lucky-browse.json?" "$test_dir/requests"
echo "PASS: directory requests use the Lucky JSON endpoint instead of browser HTML"

fetch_lucky_release_index "$release_base" "$test_dir/index.json"
echo "PASS: directory URLs are normalized with or without a trailing slash"

resolved=$(resolve_latest_lucky_release)
[[ $resolved == $'v3.1.4beta\t3.1.4_wanji_docker\t3.1.4' ]]
[[ $(wc -l < "$test_dir/requests") == 5 ]]
echo "PASS: all three release levels resolve the current wanji_docker package"

fixture_version=3.2.0
resolved=$(resolve_latest_lucky_release)
[[ $resolved == $'v3.2.0beta\t3.2.0_wanji_docker\t3.2.0' ]]
fixture_version=3.1.4
echo "PASS: a newer release is discovered without a hard-coded version"

fixture_mode=missing-package
if resolve_latest_lucky_release > "$test_dir/output" 2> "$test_dir/error"; then
    echo "FAIL: an incomplete release was accepted" >&2
    exit 1
fi
grep -q 'lucky_3.1.4_Linux_x86_64_wanji_docker.tar.gz' "$test_dir/error"
echo "PASS: releases missing a required architecture are rejected"

for fixture_mode in invalid-json invalid-schema network-error; do
    if fetch_lucky_release_index "$release_base/" "$test_dir/index.json" \
        > "$test_dir/output" 2> "$test_dir/error"; then
        echo "FAIL: $fixture_mode was accepted" >&2
        exit 1
    fi
    echo "PASS: $fixture_mode is rejected"
done
fixture_mode=normal

get_custom_feed_worktree_dir() {
    printf '%s\n' "$test_dir/feed"
}

# Leave the LuCI directory absent to exercise Makefile updates without a checkout.
mkdir -p "$test_dir/feed/lucky"
makefile="$test_dir/feed/lucky/Makefile"
cat > "$makefile" <<'EOF'
PKG_NAME:=lucky
PKG_VERSION:=2.27.2
PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_$(LUCKY_ARCH).tar.gz
PKG_SOURCE_URL:=https://github.com/gdy666/lucky/releases/download/v$(PKG_VERSION)
PKG_HASH:=skip

define Build/Prepare
	gzip -dc $(DL_DIR)/$(PKG_SOURCE) | $(HOST_TAR) -C $(PKG_BUILD_DIR) -xf -
	$(Build/Patch)
endef

print-source:
	@printf '%s/%s\n' '$(PKG_SOURCE_URL)' '$(PKG_SOURCE)'
EOF
sed -n '/^define Build\/Prepare$/,$p' "$makefile" > "$test_dir/prepare-before"
update_lucky > "$test_dir/update.log" 2>&1
for arch in arm64 x86_64; do
    source_url=$(make --no-print-directory -f "$makefile" LUCKY_ARCH="$arch" print-source)
    [[ $source_url == "$release_base/v3.1.4beta/3.1.4_wanji_docker/lucky_3.1.4_Linux_${arch}_wanji_docker.tar.gz" ]]
done
sed -n '/^define Build\/Prepare$/,$p' "$makefile" > "$test_dir/prepare-after"
cmp "$test_dir/prepare-before" "$test_dir/prepare-after"
echo "PASS: Makefile download URLs are updated without changing Build/Prepare"

first_hash=$(sha256sum "$makefile")
update_lucky > "$test_dir/update.log" 2>&1
[[ $first_hash == "$(sha256sum "$makefile")" ]]
echo "PASS: repeated Lucky Makefile updates are idempotent"

fixture_mode=invalid-json
update_lucky > "$test_dir/update.log" 2>&1
[[ $first_hash == "$(sha256sum "$makefile")" ]]
grep -q 'Warning: Lucky' "$test_dir/update.log"
echo "PASS: failed release discovery preserves the existing Makefile"
