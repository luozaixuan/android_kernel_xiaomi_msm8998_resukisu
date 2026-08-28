# Mi MIX 2 (chiron) ReSukiSU 内核：集成、构建与打包完整文档

本文件记录了如何在 **LineageOS 22.2**（Android 15，内核 4.4）的小米 Mi MIX 2（`chiron`）内核中集成
[ReSukiSU](https://github.com/ReSukiSU/ReSukiSU)，并将其编译、打包成可刷入的 AnyKernel3 zip 的完整流程。

- 仓库：`android_kernel_xiaomi_msm8998_resukisu`
- 基线：LineageOS `lineage-22.2` 分支，tip `7231883a368604f90806e167890e00f515a9927c`
- ReSukiSU 子模块：`7bb6f0df4162a657433d0645f3dca1f21e27fc29`
  （描述 `v4.2.0-rc1-32-g7bb6f0df`，版本码 **35093**）
- 集成提交：`c2ef78bbb7d3`
- 文档/脚本提交：`2d21d8a5198f`

---

## 1. 环境与工具链

Ubuntu 24.04（WSL2 亦可）。需要安装：

```sh
sudo apt-get install -y build-essential git make flex bison bc \
    libssl-dev libelf-dev \
    gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf
```

交叉编译器版本（本仓库验证通过）：

```text
aarch64-linux-gnu-gcc   GCC 13.3.0
arm-linux-gnueabihf-gcc GCC 13.3.0
```

> 提示：打包阶段如果系统没有 `zip`/`unzip` 命令，可用 Python 标准库 `zipfile` 完成，文档 4.3 节已给出脚本。

---

## 2. 集成 ReSukiSU

ReSukiSU 对 4.4 内核要求使用 **Manual Hook** 方式：
`CONFIG_KSU=y` + `CONFIG_KSU_MANUAL_HOOK=y`，并在内核源码中手工打 Hook。
ReSukiSU 会在编译期检查每一个必需 Hook，缺失任何一个都会**直接编译失败**。

### 2.1 添加 ReSukiSU 为 git 子模块

```sh
cd android_kernel_xiaomi_msm8998_resukisu
git submodule add https://github.com/ReSukiSU/ReSukiSU.git ReSukiSU
```

产生的 `.gitmodules`：

```ini
[submodule "ReSukiSU"]
	path = ReSukiSU
	url = https://github.com/ReSukiSU/ReSukiSU.git
```

注意：

- 必须保留 `ReSukiSU/.git`，ReSukiSU 的 `Kbuild` 会检查父目录存在 `.git`，
  直接把源码拷贝进树而不带 git 元数据会导致构建报
  `You should use ReSukiSU as a git submodule instead of copying code directly`。
- 不要使用 `--depth 1` 浅克隆作为子模块，否则 `git rev-list --count HEAD` 只能算出
  `1`，得到的 KSU 版本码只有 `30701`，低于管理器要求的 `34634`，模块/sepolicy 会出问题。
- 本文档用的完整克隆共 4393 个提交，最终版本码 = `30000 + 4393 + 700 = 35093`。

### 2.2 建立相对符号链接

ReSukiSU 的 Kbuild 默认通过 `drivers/kernelsu` 目录参与内核构建。使用**相对链接**，
避免把编译机绝对路径写进 git：

```sh
ln -sfn ../ReSukiSU/kernel drivers/kernelsu
```

最终为 `drivers/kernelsu -> ../ReSukiSU/kernel`，并作为 git 内容提交
（符号链接 `120000`，换机器 clone 后仍然有效）。

### 2.3 注册 Kconfig

编辑 `drivers/Kconfig`，在 `endmenu` 之前加入：

```diff
 source "drivers/tee/Kconfig"

+source "drivers/kernelsu/Kconfig"
+
 endmenu
```

这样 `make olddefconfig` 才能识别 `CONFIG_KSU`、`CONFIG_KSU_MANUAL_HOOK` 等选项。

### 2.4 注册驱动目录

编辑 `drivers/Makefile`，在末尾加入：

```diff
 obj-$(CONFIG_TEE)		+= tee/
+
+obj-$(CONFIG_KSU)		+= kernelsu/
```

### 2.5 手工 Hook 补丁

所有 Hook 都放在 `#ifdef CONFIG_KSU_MANUAL_HOOK` 内。4.4 内核必须修改以下四个文件。

#### 2.5.1 `fs/stat.c`

在 `SYSCALL_DEFINE2(newlstat, ...)` 之后、`newfstatat` 之前加声明：

```c
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
				int *flags);

extern void ksu_handle_newfstat_ret(unsigned int *fd,
				     struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd,
				   struct stat64 __user **statbuf_ptr);
#endif
#endif
```

在 `SYSCALL_DEFINE4(newfstatat, ...)` 中：

```c
	struct kstat stat;
	int error;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);
```

在 `SYSCALL_DEFINE2(newfstat, ...)` 返回前：

```c
	if (!error)
		error = cp_new_stat(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
	return error;
```

在 `SYSCALL_DEFINE2(fstat64, ...)` 返回前（32 位 su 需要）：

```c
	if (!error)
		error = cp_new_stat64(&stat, statbuf);

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_fstat64_ret(&fd, &statbuf);
#endif
	return error;
```

在 `SYSCALL_DEFINE4(fstatat64, ...)` 中（32 位 su 需要）：

```c
	struct kstat stat;
	int error;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif
	error = vfs_fstatat(dfd, filename, &stat, flag);
```

#### 2.5.2 `fs/exec.c`

在 `static int do_execveat_common(...)` 之前加声明，并在函数开头调用：

```c
/*
 * sys_execve() executes a new program.
 */
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
#endif

static int do_execveat_common(int fd, struct filename *filename,
			      struct user_arg_ptr argv,
			      struct user_arg_ptr envp,
			      int flags)
{
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
#endif

	char *pathbuf = NULL;
	...
```

> `ksu_handle_execveat` 内部对 `IS_ERR(filename)` 做了保护，放在
> `if (IS_ERR(filename))` 检查之前是安全的（官方文档也是这个位置）。

#### 2.5.3 `fs/open.c`

在 `faccessat` 注释前加声明，并在函数中调用：

```c
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif

/*
 * access() needs to use the real uid/gid, not the effective uid/gid.
 * ...
 */
SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	...
	int res;
	unsigned int lookup_flags = LOOKUP_FOLLOW;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif

	if (mode & ~S_IRWXO)	/* where's F_OK, X_OK, W_OK, R_OK? */
		return -EINVAL;
```

#### 2.5.4 `kernel/reboot.c`

`SYSCALL_DEFINE4(reboot, ...)` 前加声明，函数体开头调用：

```c
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
				 void __user **arg);
#endif

SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,
		void __user *, arg)
{
	struct pid_namespace *pid_ns = task_active_pid_ns(current);
	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif

	/* We only trust the superuser with rebooting the system. */
```

### 2.6 使用自动 Hook 代替另外三个手动 Hook

4.4 内核可以打开以下三个选项，由 ReSukiSU 通过 LSM / input handler 自动完成，
无需再改 `kernel/sys.c`、`fs/read_write.c`、`drivers/input/input.c`：

```text
CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y   # 自动 hook setuid
CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y   # 自动 hook init rc（sys_read）
CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y    # 自动 hook input_event
```

- 4.4 < 6.8，所以前两个 LSM 自动 Hook 可用。
- 如果 `CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK` 关闭，则必须按官方文档在
  `drivers/input/input.c` 的 `input_event()` 中加 `ksu_handle_input_handle_event`。

### 2.7 新建配置片段

新建 `arch/arm64/configs/resukisu.config`：

```text
CONFIG_LOCALVERSION="-perf-resukisu"
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y
# CONFIG_KSU_DEBUG is not set
# CONFIG_CC_WERROR is not set
CONFIG_OVERLAY_FS=y
```

`chiron_defconfig` 本身已经满足：

```text
CONFIG_KALLSYMS_ALL=y
CONFIG_SECURITY_SELINUX=y
CONFIG_EXT4_FS_ENCRYPTION=y
CONFIG_OVERLAY_FS=y
```

其中 `CONFIG_KALLSYMS_ALL=y` 会跳过 ReSukiSU 的静态符号导出检查
（`write_op`、`sel_handle_status_ops` 等不需要再去掉 `static`）。
若内核没开 `KALLSYMS_ALL`，必须按官方 `manual-integrate` 文档导出那些 SELinux 符号。

### 2.8 GCC 13 编译参数调整

4.4 老 Makefile 与 GCC 13 组合需要以下调整（来自已验证可构建的 KernelSU 参考树）：

```diff
-KBUILD_CFLAGS   := -Wall -Wundef -Wstrict-prototypes -Wno-trigraphs \
+KBUILD_CFLAGS   := -w -Wundef -Wstrict-prototypes -Wno-trigraphs \
 		   -fno-strict-aliasing -fno-common \
 		   -Werror-implicit-function-declaration \
 		   -Wno-format-security \
-		   -std=gnu89 $(call cc-option,-fno-PIE)
+		   -std=gnu89 -fPIE # $(call cc-option,-fno-PIE)
...
-KBUILD_AFLAGS   := -D__ASSEMBLY__ $(call cc-option,-fno-PIE)
+KBUILD_AFLAGS   := -D__ASSEMBLY__ -fPIE # $(call cc-option,-fno-PIE)
```

同时 `resukisu.config` 里已经 `# CONFIG_CC_WERROR is not set`。

---

## 3. 构建

仓库自带 `build.sh`，执行：

```sh
cd android_kernel_xiaomi_msm8998_resukisu
git submodule update --init --recursive   # 首次 clone 后必须执行
./build.sh
```

`build.sh` 内容等价于：

```sh
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabihf-

make O=out chiron_defconfig
scripts/kconfig/merge_config.sh -m -O out \
    arch/arm64/configs/chiron_defconfig \
    arch/arm64/configs/resukisu.config
make O=out olddefconfig
make O=out -j"$(nproc)" Image.gz-dtb modules
```

### 3.1 构建时的 ReSukiSU 检查输出

正常输出应包含：

```text
-- ReSukiSU version code: 35093
-- ReSukiSU version name: v4.2.0-rc1-7bb6f0df@ReSukiSU
-- KERNEL_VERSION: 4.4
-- KERNEL_TYPE: Non-GKI
-- ReSukiSU: using Manual Hook
-- ReSukiSU/manual_hook: You are using LSM hooks for setuid hooks.
-- ReSukiSU/manual_hook: You are using LSM hooks for init rc hooks.
-- ReSukiSU/manual_hook: You are using input_handler for input hooks.
-- ReSukiSU/manual_hook: ksu_handle_execveat found
-- ReSukiSU/manual_hook: ksu_handle_faccessat found
-- ReSukiSU/manual_hook: ksu_handle_stat found
-- ReSukiSU/manual_hook: ksu_handle_newfstat_ret found
-- ReSukiSU/manual_hook: ksu_handle_fstat64_ret found
-- ReSukiSU/manual_hook: ksu_handle_sys_reboot found
```

任何一条 `You lost ... hook` 或 `You should integrate ReSukiSU in your kernel`
都会让编译失败，按 2.5 节补对应 Hook 即可。

### 3.2 产物

```text
out/arch/arm64/boot/Image.gz-dtb     # 可刷入的内核镜像（约 14.9 MB）
out/vmlinux
out/System.map
```

内核版本字符串：

```text
out/include/generated/utsrelease.h
#define UTS_RELEASE "4.4.302-perf-resukisu+"
```

### 3.3 校验 ReSukiSU 已编进内核

```sh
grep -E 'ksu_core_init|ksu_handle_execveat|ksu_handle_faccessat|ksu_handle_sys_reboot|ksu_handle_input_handle_event' out/System.map
```

正常会有 `T ksu_core_init` 及各个 `T ksu_handle_*` 符号（本构建共 222 个 `ksu_` 符号）。

---

## 4. AnyKernel3 打包

### 4.1 模板

使用官方 [AnyKernel3](https://github.com/osm0sis/AnyKernel3) 模板：

```sh
git clone --depth 1 https://github.com/osm0sis/AnyKernel3.git /tmp/ak3
cp -r /tmp/ak3/AK3 /tmp/ak3-build/AK3   # 实际工作目录，不要带 .git 进 zip
```

把编译产物放到模板根目录：

```sh
cp out/arch/arm64/boot/Image.gz-dtb /tmp/ak3-build/AK3/Image.gz-dtb
```

### 4.2 `anykernel.sh`

`chiron` 非 A/B 设备，Android 15，boot 分区为
`/dev/block/bootdevice/by-name/boot`：

```sh
### AnyKernel3 Ramdisk Mod Script
## chiron (Xiaomi Mi MIX 2) - LineageOS 22.2 + ReSukiSU

### AnyKernel setup
properties() { '
kernel.string=Chiron-ReSukiSU 4.4.302-perf-resukisu for LineageOS 22.2
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=chiron
supported.versions=15
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

dump_boot;
write_boot;
## end boot install
```

### 4.3 用 Python 生成 zip（保留 0755 权限）

```python
#!/usr/bin/env python3
import os, zipfile

src = '/tmp/ak3-build/AK3'
out = 'Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip'

zf = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9)
for root, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if d != '.git']   # 排除模板的 .git
    for f in files:
        fp = os.path.join(root, f)
        rel = os.path.relpath(fp, src)
        mode = (os.stat(fp).st_mode & 0o777) or 0o644
        zi = zipfile.ZipInfo(rel)
        zi.external_attr = (mode & 0xFFFF) << 16   # 保留可执行位
        zi.create_system = 3                       # Unix
        with open(fp, 'rb') as fh:
            zf.writestr(zi, fh.read())
zf.close()
```

校验 zip 完整性：

```sh
python3 -m zipfile -t Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip
```

### 4.4 产物与校验值

```text
Image.gz-dtb
  SHA256 cb0965989de536d4e8334b8adb72ea8ffa0c60fb5410535ace57660ade60a5e3

Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip
  SHA256 fe02f0fb6d0b6c323e555b42384757107408b0da398b516138988cf6884e7dbe
```

> 校验值会随 ReSukiSU 子模块版本、工具链、编译时间变化，上面是本仓库当前构建的实测值。

---

## 5. 刷入 Mi MIX 2

1. 把 `Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip` 放到手机。
2. 重启进 Recovery：
   - 关机后按住 **电源键 + 音量上**；或
   - `adb reboot recovery`
3. 选 **Apply update → 选择 zip**；或电脑上：
   ```sh
   adb sideload Chiron-ReSukiSU-Lineage22.2-AnyKernel3.zip
   ```
4. 重启系统。
5. 安装 ReSukiSU 管理器 APK：
   https://github.com/ReSukiSU/ReSukiSU/releases

注意：**内核和管理器版本码都必须 ≥ 34634**（本内核为 35093，满足）。

该 zip 只通过 AnyKernel3 替换 boot 分区里的内核，不清数据、不改 recovery。

---

## 6. 从零复现

```sh
git clone --recurse-submodules \
    <此仓库地址> android_kernel_xiaomi_msm8998_resukisu
cd android_kernel_xiaomi_msm8998_resukisu

# 确认子模块到位
git submodule update --init --recursive

# 构建
./build.sh

# 产物
ls -l out/arch/arm64/boot/Image.gz-dtb
```

---

## 7. 常见问题

### 7.1 删除 `/data/adb` 后开机提示 `set_policy_failed:/data/adb`

这是 LineageOS 22.2 自带的 `init.usb.rc`：

```text
mkdir /data/adb 0700 root root encryption=Require
```

删掉 `/data/adb` 后，init 重建目录时设置 fscrypt 加密策略失败，就 reboot 到
recovery 显示 “Your data may be corrupt”。数据没坏，处理方式：

1. TWRP 挂载 Data，彻底 `rm -rf /data/adb`（如有挂载先 `umount -l`），重启；
2. 若 Data 无法解密，挂载 System，把
   `/system/etc/init/hw/init.usb.rc` 中的 `encryption=Require` 改为 `encryption=Attempt`；
3. 最后才考虑恢复出厂。

### 7.2 版本码低于 34634

不要用浅克隆子模块；用完整 `git submodule add`。构建日志里 `version code` 必须 ≥ 34634。

### 7.3 `drivers/kernelsu` 断链

必须使用相对链接 `../ReSukiSU/kernel`。不要把编译机的绝对路径提交进仓库。

### 7.4 编译报某个 `ksu_handle_*` 缺失

对照官方文档：
https://resukisu.github.io/guide/manual-integrate.html

ReSukiSU 会检查：

- `fs/exec.c`：`ksu_handle_execveat`
- `fs/open.c`：`ksu_handle_faccessat`
- `fs/stat.c`：`ksu_handle_stat`、`ksu_handle_newfstat_ret`、`ksu_handle_fstat64_ret`
- `kernel/reboot.c`：`ksu_handle_sys_reboot`（3.12+）
- 禁止出现旧 KernelSU 的 `ksu_vfs_read_hook`、`ksu_handle_rename`、`is_ksu_transition` 等不兼容 Hook

按第 2.5 节逐一补齐即可。
