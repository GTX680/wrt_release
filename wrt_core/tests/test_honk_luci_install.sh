#!/usr/bin/env bash
set -euo pipefail

BASE_PATH=$(cd "$(dirname "$0")/.." && pwd)
source <(sed 's/\r$//' "$BASE_PATH/modules/custom_feed.sh")

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
package_dir="$test_dir/package"
vendor_dir="$package_dir/htdocs/luci-static/resources/view/honk/vendor"
mkdir -p "$package_dir"
cat > "$package_dir/Makefile" <<'EOF'
INSTALL_DIR=install -d -m0755
INSTALL_DATA=install -m0644

define Package/luci-app-honk/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/honk/vendor
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/honk/vendor/* $(1)/www/luci-static/resources/view/honk/vendor/
endef

install:
	$(call Package/luci-app-honk/install,$(DESTDIR))
EOF

run_install() {
    make --no-print-directory -C "$package_dir" "DESTDIR=$test_dir/root" install \
        > "$test_dir/install.log" 2>&1
}

if run_install; then
    echo "FAIL: unpatched recipe did not reproduce the missing vendor failure" >&2
    exit 1
fi
grep -q "cannot stat.*vendor/" "$test_dir/install.log"
rm -rf -- "$test_dir/root"
echo "PASS: upstream recipe reproduces the missing vendor failure"

fix_honk_luci_vendor_install "$package_dir"
run_install
[[ ! -d "$test_dir/root/www/luci-static/resources/view/honk/vendor" ]]
echo "PASS: an absent optional vendor directory does not fail installation"

mkdir -p "$vendor_dir"
run_install
[[ ! -d "$test_dir/root/www/luci-static/resources/view/honk/vendor" ]]
echo "PASS: an empty optional vendor directory does not fail installation"

printf '/* Optional vendor asset */\n' > "$vendor_dir/library.js"
run_install
cmp "$vendor_dir/library.js" "$test_dir/root/www/luci-static/resources/view/honk/vendor/library.js"
[[ $(stat -c '%a' "$test_dir/root/www/luci-static/resources/view/honk/vendor/library.js") == 644 ]]
echo "PASS: existing vendor assets are installed with the original permissions"

first_hash=$(sha256sum "$package_dir/Makefile")
fix_honk_luci_vendor_install "$package_dir"
[[ $first_hash == "$(sha256sum "$package_dir/Makefile")" ]]
echo "PASS: the Makefile fix is idempotent"

rm -rf -- "$test_dir/root"
printf 'Not a directory\n' > "$test_dir/root"
if run_install; then
    echo "FAIL: an actual installation error was suppressed" >&2
    exit 1
fi
echo "PASS: real installation errors still stop the package build"
