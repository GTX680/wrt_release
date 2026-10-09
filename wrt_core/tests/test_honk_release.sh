#!/usr/bin/env bash
set -euo pipefail

BASE_PATH=$(cd "$(dirname "$0")/.." && pwd)
source <(sed 's/\r$//' "$BASE_PATH/modules/custom_feed.sh")

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
core_revision=eac5e0c5fba5078a7ff4517a3e3851e7fa0f4f8e
mkdir -p "$test_dir/release" "$test_dir/package"
cat > "$test_dir/package/Makefile" <<EOF
CORE_COMMIT:=$core_revision
-include \$(CURDIR)/generated-stage.mk
HONK_ASSET_AARCH64?=honk-core-\$(CORE_COMMIT)-aarch64.tar.gz
HONK_HASH_AARCH64?=SKIP
PKG_SOURCE:=\$(HONK_ASSET_AARCH64)
PKG_HASH:=\$(HONK_HASH_AARCH64)

print-source:
	@printf '%s\t%s\n' '\$(PKG_SOURCE)' '\$(PKG_HASH)'
EOF
for arch in x86_64 aarch64 armv7; do
    printf 'HONK_ASSET_%s:=honk-core-%s-%s.tar.gz\nHONK_HASH_%s:=%064d\n' \
        "${arch^^}" "$core_revision" "$arch" "${arch^^}" 1 >> "$test_dir/release/generated-stage.mk"
done
printf '{"core":{"commit":"%s"}}\n' "$core_revision" > "$test_dir/release/generated-provenance.json"

curl_retry() {
    local output_file=""
    local url="${!#}"
    while (( $# )); do
        case "$1" in
            -o) output_file="$2"; shift ;;
        esac
        shift
    done
    [[ $url == https://github.com/kenzok8/openwrt-honk/releases/download/staging/* ]]
    cp "$test_dir/release/${url##*/}" "$output_file"
}

before=$(make --no-print-directory -C "$test_dir/package" print-source)
[[ $before == *$'\tSKIP' ]]
prepare_honk_release "$test_dir/package"
after=$(make --no-print-directory -C "$test_dir/package" print-source)
[[ $after == "$(printf 'honk-core-%s-aarch64.tar.gz\t%064d' "$core_revision" 1)" ]]
cmp "$test_dir/release/generated-provenance.json" "$test_dir/package/generated-provenance.json"
echo "PASS: release metadata replaces SKIP with SHA256 and supplies the installed provenance file"

first_hash=$(sha256sum "$test_dir/package/generated-stage.mk" "$test_dir/package/generated-provenance.json")
prepare_honk_release "$test_dir/package"
[[ $first_hash == "$(sha256sum "$test_dir/package/generated-stage.mk" "$test_dir/package/generated-provenance.json")" ]]
echo "PASS: repeated release preparation is idempotent"

assert_invalid_metadata() {
    if prepare_honk_release "$test_dir/package" > "$test_dir/output" 2> "$test_dir/error"; then
        echo "FAIL: invalid release metadata was accepted" >&2
        exit 1
    fi
    [[ $first_hash == "$(sha256sum "$test_dir/package/generated-stage.mk" "$test_dir/package/generated-provenance.json")" ]]
}

cp "$test_dir/release/generated-stage.mk" "$test_dir/stage"
sed -i "s/$core_revision/1111111111111111111111111111111111111111/g" "$test_dir/release/generated-stage.mk"
assert_invalid_metadata
grep -q 'does not match CORE_COMMIT' "$test_dir/error"
cp "$test_dir/stage" "$test_dir/release/generated-stage.mk"
echo "PASS: a release for another core revision is rejected without changing package inputs"

sed -i 's/^HONK_HASH_AARCH64:=.*/HONK_HASH_AARCH64:=SKIP/' "$test_dir/release/generated-stage.mk"
assert_invalid_metadata
grep -q 'no valid SHA256' "$test_dir/error"
cp "$test_dir/stage" "$test_dir/release/generated-stage.mk"
echo "PASS: skip markers cannot replace published SHA256 hashes"

printf '$(error unexpected make expression)\n' >> "$test_dir/release/generated-stage.mk"
assert_invalid_metadata
grep -q 'invalid Honk release stage manifest' "$test_dir/error"
cp "$test_dir/stage" "$test_dir/release/generated-stage.mk"
echo "PASS: the manifest accepts only release asset and hash assignments"

printf '{"core":{"commit":"1111111111111111111111111111111111111111"}}\n' \
    > "$test_dir/release/generated-provenance.json"
assert_invalid_metadata
grep -q 'provenance does not match CORE_COMMIT' "$test_dir/error"
echo "PASS: mismatched provenance is rejected"

curl_retry() { return 22; }
assert_invalid_metadata
grep -q 'failed to fetch Honk release metadata' "$test_dir/error"
echo "PASS: metadata download failure stops preparation without installing partial files"
