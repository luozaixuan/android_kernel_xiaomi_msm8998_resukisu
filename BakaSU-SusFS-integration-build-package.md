# Mi MIX 2 (chiron) BakaSU + SusFS 内核：集成、构建、打包完整文档

本文件记录在 **LineageOS 22.2**（Android 15，Linux 4.4）的小米 Mi MIX 2
（`chiron`）内核上，将 **ReSukiSU 迁移为 BakaSU**、并把内核侧 **SusFS 升级到
v2.3.0** 的完整过程，以及后续的更新/升级指南。

- 仓库：`android_kernel_xiaomi_msm8998_resukisu`
- 基线：LineageOS `lineage-22.2` 分支，tip `7231883a3686`
- 迁移提交：`55c4a7d3f152`（Rebrand to BakaSU and upgrade SusFS to v2.3.0）
- 远程分支：`lineage-22.2`

---

## 0. 当前状态总览

| 项目 | 值 |
|---|---|
| Linux 内核 | 4.4.302（release：`4.4.302-perf-bakasu+`） |
| BakaSU 子模块 | `e1682a28`（`v4.2.0-rc3-58-ge1682a28`，分支 `sync-susfs`，版本码 **35229**） |
| Hook 模式 | **SuSFS Inline Hook**（`CONFIG_KSU_SUSFS=y`） |
| SusFS | **v2.3.0**（4.4 专用补丁） |
| 目标机型 | chiron（小米 MIX 2）、sagit（小米 6） |
| 刷机包 | `Chiron/Sagit-BakaSU-Lineage22.2-AnyKernel3.zip` |

版本码公式（BakaSU Kbuild 内置）：

```text
KSU_VERSION = 30000 + commit_count + 700
```

`sync-susfs` 当前提交数 4529 → `30000 + 4529 + 700 = 35229`。
必须 ≥ 34634（管理器/模块/sepolicy 兼容的最低要求），所以子模块**禁止浅克隆**。

---

## 1. 背景：为什么是 BakaSU 的 sync-susfs 分支

ReSukiSU 已改名为 **BakaSU**（新仓库 `https://github.com/Baka-SU/BakaSU.git`）。
改名后 BakaSU 有三个相关状态：

| 版本 | 说明 | SusFS 可用性 |
|---|---|---|
| `main` 最新 HEAD | 2026-10-10 提交 `48fa4bb7 kernel: suspend susfs build` 在 `kernel/tools/susfs_compat.mk` 里**无条件 `$(error Please wait susfs update.)`** | ❌ 编译不过 |
| `sync-susfs` 分支 | 官方 SusFS 同步分支；`e1682a28 kernel: sync for latest susfs`（含 selinux_hide 时间侧信道修复），`susfs_compat.mk` 无暂停错误 | ✅ 本次采用 |
| 暂停前最后提交 `5b76b884` | `v4.2.0-rc3-51`，hook 检查与 ReSukiSU v4.2.0-rc1-80 完全一致 | ✅（保守回退选项） |

> 结论：`main` 等 simonpunk 把 susfs4ksu 同步到最新 KernelSU 前无法编译 SusFS。
> 本仓库跟踪 `sync-susfs` 分支；`update-bakasu.sh` / `update-bakasu.yml` 均以此为标准。

---

## 2. 材料准备

| 材料 | 用途 | 来源 | SHA256 |
|---|---|---|---|
| `susfs/susfs_patch_to_4.4.patch`（v2.3.00） | SusFS 内核侧补丁（20 文件） | `JackA1ltman/NonGKI_Kernel_Build_2nd` `Patches/Patch/` | `f56740dc698186700f8178621981bc1430cf02ab898b3ffbd684b69380c4a407` |
| `susfs/susfs_inline_hook_patches.sh`（PATCH_LEVEL 2.3.00） | KSU inline hook 脚本（含 post-exec hook） | 同上 `Patches/`（已测 3.18/4.4/4.9/4.14/4.19/5.4） | `9afa89ee6474b80e2615096b926c1d8eef1cb7585f74130a375fbe6cf63d00f2` |

两份材料均提交在仓库 `susfs/` 目录下，保证可复现。

> SusFS 上游：https://gitlab.com/simonpunk/susfs4ksu（v2.3.0 对应 2.3.00 内核侧补丁）。

---

## 3. Part A：子模块迁移（ReSukiSU → BakaSU）

### 3.1 修改 `.gitmodules`

```ini
[submodule "BakaSU"]
	path = BakaSU
	url = https://github.com/Baka-SU/BakaSU.git
```

替换旧的 `[submodule "ReSukiSU"]`，子模块目录从 `ReSukiSU/` 改为 `BakaSU/`。

### 3.2 更新符号链接

```sh
ln -sfn ../BakaSU/kernel drivers/kernelsu
```

最终为 `drivers/kernelsu -> ../BakaSU/kernel`（符号链接 `120000`，可提交进 git）。

### 3.3 检出 sync-susfs 分支

```sh
git submodule update --init --recursive BakaSU
git -C BakaSU fetch origin sync-susfs
git -C BakaSU checkout -q origin/sync-susfs     # e1682a28
```

### 3.4 版本码校验

```sh
C=$(git -C BakaSU rev-list --count HEAD)   # 4529
V=$((30000 + C + 700))                      # 35229
```

---

## 4. Part B：内核侧 SusFS 升级 v2.2.0 → v2.3.0

### 4.1 为什么必须"回退再重打"

- 旧集成（提交 `23d2780938d3`）只把 **v2.2.0** 补丁打进源码并提交。
- v2.3.00 的 `susfs_patch_to_4.4.patch` 是**相对 vanilla kernel 的完整补丁**
  （文件 `fs/susfs.c`、`susfs.h`、`susfs_def.h` 都是新增/整体替换），直接叠在
  已应用的 2.2.0 上会冲突。
- 因此做法：把 SusFS 涉及的所有源文件**回退到 lineage 基线**，再应用 2.3.00 补丁
  + 新 inline hook 脚本。

> 回退前先确认这些文件相对基线只有集成改动（本次验证：仅
> `83430d91bedb` 手动 Hook、`23d2780938d3` SusFS 2.2.0、`b7b22a73c840`
> post-exec hook 三个提交碰过它们）。

### 4.2 ① 回退 SusFS 相关文件到基线 `7231883a3686`

```sh
git checkout 7231883a3686 -- fs/Makefile fs/namei.c fs/namespace.c \
    fs/notify/fdinfo.c fs/open.c fs/proc/base.c fs/proc/cmdline.c \
    fs/proc/fd.c fs/proc/task_mmu.c fs/proc_namespace.c fs/read_write.c \
    fs/readdir.c fs/stat.c fs/statfs.c fs/super.c fs/exec.c \
    include/linux/seccomp.h kernel/kallsyms.c kernel/reboot.c kernel/sys.c \
    mm/memory.c security/selinux/avc.c security/selinux/hooks.c \
    security/selinux/ss/services.c drivers/input/input.c
git rm fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h
```

（`fs/susfs.c`、`susfs.h`、`susfs_def.h` 是 2.2.0 新增文件，基线上不存在，需 `git rm`。）

### 4.3 ② 替换 susfs/ 材料为 v2.3.00

```sh
cp  NonGKI_Path/Patches/Patch/susfs_patch_to_4.4.patch  susfs/susfs_patch_to_4.4.patch
cp  NonGKI_Path/Patches/susfs_inline_hook_patches.sh    susfs/susfs_inline_hook_patches.sh
```

### 4.4 ③ 应用 SusFS 4.4 内核补丁（v2.3.00）

```sh
git apply --check susfs/susfs_patch_to_4.4.patch   # 先验证
git apply susfs/susfs_patch_to_4.4.patch
```

共 20 个文件（相对 v2.2.0 新增 `fs/super.c`）：

| 文件 | 说明 |
|---|---|
| `fs/susfs.c`（新增）、`include/linux/susfs.h`、`susfs_def.h` | SusFS 内核实现（`SUSFS_VERSION "v2.3.0"`） |
| `fs/Makefile` | `obj-$(CONFIG_KSU_SUSFS) += susfs.o` |
| `fs/namei.c` | sus_path / open_redirect |
| `fs/namespace.c`、`fs/proc_namespace.c`、`fs/notify/fdinfo.c`、`fs/proc/fd.c` | sus_mount / mnt 隐藏 |
| `fs/proc/base.c`、`task_mmu.c` | sus_map / maps 隐藏 |
| `fs/proc/cmdline.c` | cmdline 伪造 |
| `fs/stat.c`、`statfs.c`、`readdir.c`、`fs/super.c` | sus_kstat 相关 |
| `kernel/sys.c` | uname 伪造 |
| `kernel/kallsyms.c` | 隐藏 ksu/susfs 符号 |
| `security/selinux/avc.c` | AVC 日志伪造 |

### 4.5 ④ 运行 KSU inline hook 脚本

```sh
bash susfs/susfs_inline_hook_patches.sh
```

在以下文件里打上 `ksu_handle_*` inline hooks（**必须带上已检出的 BakaSU 子模块**，
否则 `kernel/sys.c` 的 setresuid hook 会被脚本跳过）：

- `fs/exec.c`：`ksu_handle_execveat` / `ksu_handle_execveat_sucompat` / `ksu_handle_post_execveat_sucompat`
- `fs/open.c`：`ksu_handle_faccessat`
- `fs/read_write.c`：`ksu_handle_sys_read`
- `fs/stat.c`：`ksu_handle_stat` + `ksu_handle_vfs_fstat`
- `drivers/input/input.c`：`ksu_handle_input_handle_event`
- `kernel/reboot.c`：`ksu_handle_sys_reboot`
- `kernel/sys.c`：`ksu_handle_setresuid`

### 4.6 ⑤ 核对 BakaSU 的 hook 检查

BakaSU 的 `kernel/tools/inline_hook_check.mk` 会在编译期逐项检查，缺一个直接编译失败：

```text
ku_handle_setresuid          -> kernel/sys.c
ksu_handle_execveat          -> fs/exec.c
ksu_handle_faccessat         -> fs/open.c
ksu_handle_sys_read          -> fs/read_write.c
ksu_handle_stat              -> fs/stat.c
ksu_handle_sys_reboot        -> kernel/reboot.c
ksu_handle_input_handle_event-> drivers/input/input.c
```

同时要求**不存在**旧式 hook：`ksu_vfs_read_hook` / `ksu_input_hook` /
`ksu_execveat_hook` / `ksu_init_rc_hook`。

`susfs_compat.mk`（sync-susfs 分支无暂停错误）：

- 若 `security/selinux/hooks.c` 含 `ksu_selinux_hide_running` → 定义
  `KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE`（本次内核侧不含，驱动回退为内部
  实现，`__maybe_static` 按 static 处理，正常）。
- 若 `fs/exec.c` 含 `ksu_install_su_fd` → 定义 `KSU_COMPAT_HAS_SUSFS_INSTALL_SU_FD_DIRECT_CALL`（本次不含，正常）。

---

## 5. Part C：配置与改名

### 5.1 配置片段 `resukisu.config` → `bakasu.config`

```text
CONFIG_LOCALVERSION="-perf-bakasu"
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
# CONFIG_KSU_DEBUG is not set
# CONFIG_CC_WERROR is not set
CONFIG_OVERLAY_FS=y
```

（BakaSU sync-susfs 的 Kconfig 选项与旧版完全兼容，无增删。）

### 5.2 改名清单

| 旧 | 新 |
|---|---|
| `ReSukiSU/`（子模块） | `BakaSU/` |
| `drivers/kernelsu -> ../ReSukiSU/kernel` | `-> ../BakaSU/kernel` |
| `arch/arm64/configs/resukisu.config` | `bakasu.config` |
| `build-resukisu.sh` | `build-bakasu.sh` |
| `update-resukisu.sh` | `update-bakasu.sh` |
| `.github/workflows/update-resukisu.yml` | `update-bakasu.yml` |
| `README-ReSukiSU.md` | `README-BakaSU.md` |
| `Chiron/Sagit-ReSukiSU-*.zip` | `Chiron/Sagit-BakaSU-*.zip` |
| `build-resukisu.log` | `build-bakasu.log` |
| `kernel.string=Chiron-ReSukiSU ... perf-resukisu` | `Chiron-BakaSU ... perf-bakasu` |

`update-bakasu.sh` / `update-bakasu.yml` 的更新目标从 `main` 改为 **`sync-susfs`**。

---

## 6. Part D：构建与验证

```sh
./build-bakasu.sh                 # 或 ./build.sh
./package-ak3.sh -D chiron        # 打包；sagit 用 -D sagit
```

编译日志 `build-bakasu.log` 中应出现：

```text
-- BakaSU version code: 35229
-- BakaSU version name: v4.2.0-rc3-e1682a28
-- KERNEL_TYPE: Non-GKI
-- BakaSU: using SuSFS Inline hook
-- BakaSU/susfs_inline: ksu_handle_setresuid found
-- BakaSU/susfs_inline: ksu_handle_execveat found
-- BakaSU/susfs_inline: ksu_handle_faccessat found
-- BakaSU/susfs_inline: ksu_handle_sys_read found
-- BakaSU/susfs_inline: ksu_handle_stat found
-- BakaSU/susfs_inline: ksu_handle_sys_reboot found
-- BakaSU/susfs_inline: ksu_handle_input_handle_event found
-- SUSFS_VERSION: v2.3.0
```

产物：

- `out/arch/arm64/boot/Image.gz-dtb`
- `Chiron-BakaSU-Lineage22.2-AnyKernel3.zip` / `Sagit-BakaSU-Lineage22.2-AnyKernel3.zip`

刷机：`adb reboot recovery && adb sideload Chiron-BakaSU-Lineage22.2-AnyKernel3.zip`，
然后安装 BakaSU 管理器（https://github.com/Baka-SU/BakaSU/releases）。

---

## 7. Part E：提交与推送

```sh
git add -A
git commit -m "Rebrand to BakaSU and upgrade SusFS to v2.3.0"
git push origin lineage-22.2
```

本次迁移提交为 `55c4a7d3f152`。推送时若远程已有（例如 CI 或其它会话）更新，先
`git fetch` 并用 `git rebase origin/lineage-22.2` 处理（示例中远程有 3 个把
ReSukiSU 指针挪到 rc2-13 的提交，迁移提交的 `ReSukiSU` 删除形成 modify/delete
冲突，`git rm ReSukiSU` 后以删除为准继续 rebase）。

推送 `lineage-22.2` 会触发 `.github/workflows/build.yml` 自动编译打包（GitHub
Actions 自动 unshallow BakaSU 子模块以保证版本码正确）。

---

## 8. 后续更新指南

### 8.1 例行更新（只更新 BakaSU 源码）

```sh
./update-bakasu.sh          # 自动 fetch sync-susfs、提交子模块指针、rebase/编译
```

- 若 `git -C BakaSU diff --name-only OLD NEW -- kernel/` 有改动：**停止自动流程**，
  需要本地重新跑 `bash susfs/susfs_inline_hook_patches.sh` 并核对 hook 后重新编译。
- BakaSU `main` 的 SusFS 构建仍处于**暂停**状态，不要切到 `main` 构建 SusFS。
  若官方恢复（simonpunk 同步完成、移除 `susfs_compat.mk` 的 `$(error)`），
  可再评估切回 `main`，届时可能需要把内核侧 SusFS 再升一版。

### 8.2 内核侧 SusFS 再升级（例如 2.3.0 → 2.4.x）

按本文件 Part B 重复"回退基线 → 换 `susfs/susfs_patch_to_4.4.patch` 与
`susfs_inline_hook_patches.sh` → 应用补丁 + 跑脚本 → 核对 hook → 编译"。

---

## 9. 附：本次关键数据快照

```text
BakaSU HEAD      e1682a2831142e68fa30bab97d5690cf90b75119  (sync-susfs)
BakaSU describe  v4.2.0-rc3-58-ge1682a28
BakaSU count     4529
BakaSU version   35229
susfs_patch      f56740dc698186700f8178621981bc1430cf02ab898b3ffbd684b69380c4a407  (v2.3.00)
inline_hook.sh   9afa89ee6474b80e2615096b926c1d8eef1cb7585f74130a375fbe6cf63d00f2  (2.3.00)
SUSFS_VERSION    v2.3.0
```