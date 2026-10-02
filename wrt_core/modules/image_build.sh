#!/usr/bin/env bash
# Actions 多设备镜像构建的临时 rootfs 空间回收。

enable_ci_rootfs_reclamation() {
    [[ ${GITHUB_ACTIONS:-} == "true" ]] || return 0
    grep -qxF 'CONFIG_TARGET_mediatek_filogic=y' .config || return 0
    grep -qxF 'CONFIG_TARGET_MULTI_PROFILE=y' .config || return 0
    grep -qxF 'CONFIG_TARGET_PER_DEVICE_ROOTFS=y' .config || return 0

    python3 - include/image.mk <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "# WRT: reclaim compressed per-device rootfs in CI."
if marker in text:
    raise SystemExit(0)

recipe = """$(KDIR)/root.%: kernel_prepare
\t$(call Image/mkfs/$(word 1,$(target_params)),$(target_params))
"""
if text.count(recipe) != 1:
    raise SystemExit("无法定位唯一的 rootfs 镜像生成规则，停止构建以避免磁盘写满")

replacement = """# WRT: reclaim compressed per-device rootfs in CI.
# Only squashfs may consume this directory: keep it for initramfs, other
# filesystems or squashfs variants which can still need the same package set.
wrt_reclaim_rootfs = $(and $(filter 1,$(WRT_RECLAIM_ROOTFS)),\\
\t$(filter squashfs,$(word 1,$(target_params))),\\
\t$(call param_get,pkg,$(target_params)),\\
\t$(filter squashfs,$(TARGET_FILESYSTEMS)),\\
\t$(if $(filter-out squashfs,$(TARGET_FILESYSTEMS))$(CONFIG_TARGET_ROOTFS_INITRAMFS)$(FS_OPTIONS/squashfs),,1))

""" + recipe + """\t$(if $(wrt_reclaim_rootfs),rm -rf "$(call mkfs_target_dir,$(target_params))")
"""
path.write_text(text.replace(recipe, replacement))
PY

    export WRT_RECLAIM_ROOTFS=1
    echo "已启用 CI 多设备 rootfs 回收：squashfs 生成后释放临时目录。"
}
