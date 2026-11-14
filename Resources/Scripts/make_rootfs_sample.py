# -*- coding: utf-8 -*-
"""make_rootfs_sample.py — 最小 rootfs 样例打包脚本 (Tier B-3 冒烟).

产出可直接喂给 TequilaDash/Engine/TDRootfsUnpack (宿主侧) 的归档:
  usr/bin/curl + usr/bin/ksh (两个可执行) + etc/passwd + var/jb -> . 符号链接
+ usr/lib/ 空目录 —— procursus binpack 的最小形状 (Nyxian 同构, 见
  NYXIAN-INTEGRATION-PLAN §1 vroot 行 / HANDOFF §4.4).

默认 (不给 --src/--bin) 打出来的是**合成占位文件**, 不是真 Mach-O —— 用来验证
打包/解包管线 (tar 结构、路径规范、权限位), 不是用来跑的. 真实二进制两种给法:

  # 1) 整目录: procursus binpack 解包目录 (usr/bin/curl、usr/bin/ksh 已在其中)
  python make_rootfs_sample.py --src <binpack目录> --out Documents/rootfs.tar

  # 2) 逐个二进制
  python make_rootfs_sample.py --bin curl=<路径> --bin ksh=<路径> --out Documents/rootfs.tar

round-trip 校验 (--verify): 重新打开产出 tar, 逐成员核对
  · 无绝对路径成员 (SECURE_NOABSOLUTEPATHS 消费契约)
  · 无 ".." 组件 (SECURE_NODOTDOT 消费契约)
  · 数据可读回且大小一致
对齐 decomp_nyxian_app.c unzipArchiveAtPath* (0x10002e1dc / 0x10002e38c) 的安全语义.

zstd 明确不支持: iOS 无系统 libzstd, 本仓 SWCompression 无 zstd 解码器, Apple 系
libarchive 也无 zstd filter —— --out 以 .zst 结尾会直接拒绝 (与 TDRootfsUnpack
的 TDRootfsUnpackErrorCodeZstdUnsupported 同口径).

Windows 可跑: 纯标准库 (tarfile / os / argparse), 无外部依赖.
用法示例:
    python Resources/Scripts/make_rootfs_sample.py --out Documents/rootfs.tar --verify
退出码: 0 = 成功; 1 = 校验/参数失败; 2 = 用法错误.
"""
import argparse
import io
import os
import sys
import tarfile

DEFAULT_OUT = "Documents/rootfs.tar"

# 默认样例成员: (路径, 类型, 内容 / 链接目标, 模式)
SAMPLE_DIRS = [
    ("usr", 0o755),
    ("usr/bin", 0o755),
    ("usr/lib", 0o755),
    ("etc", 0o755),
    ("var", 0o755),
]
SAMPLE_FILES = [
    ("usr/bin/curl", b"#!/bin/sh\n# TDRootfsUnpack sample placeholder (not a real Mach-O)\necho curl-placeholder\n", 0o755),
    ("usr/bin/ksh",  b"#!/bin/sh\n# TDRootfsUnpack sample placeholder (not a real Mach-O)\necho ksh-placeholder\n", 0o755),
    ("etc/passwd",   b"root:x:0:0:root:/root:/bin/sh\nguest:x:501:501:guest:/var/mobile:/bin/sh\n", 0o644),
    ("etc/hosts",    b"127.0.0.1 localhost\n", 0o644),
]
SAMPLE_SYMLINKS = [
    ("var/jb", "."),  # procursus 惯例: /var/jb 指向 rootfs 根
]


def _safe_member_name(name):
    """拒绝绝对路径与 .. 组件 (解包消费方 TDRootfsUnpack 的 SECURE_* 契约)."""
    if name.startswith("/"):
        return "绝对路径成员"
    parts = [p for p in name.replace("\\", "/").split("/") if p]
    if any(p == ".." for p in parts):
        return "含 .. 组件"
    if ":" in name or name.startswith("//"):
        return "Windows 风格路径"
    return None


def add_dir(tf, name, mode):
    info = tarfile.TarInfo(name.rstrip("/"))
    info.type = tarfile.DIRTYPE
    info.mode = mode
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime = 0
    tf.addfile(info)


def add_file_bytes(tf, name, data, mode):
    info = tarfile.TarInfo(name)
    info.type = tarfile.REGTYPE
    info.size = len(data)
    info.mode = mode
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime = 0
    tf.addfile(info, fileobj=io.BytesIO(data))


def add_symlink(tf, name, target):
    info = tarfile.TarInfo(name)
    info.type = tarfile.SYMTYPE
    info.linkname = target
    info.mode = 0o777
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime = 0
    tf.addfile(info)


def add_real_path(tf, src_root, rel, stats):
    """从 binpack 目录按相对路径添加真实文件/目录/符号链接 (含权限位)."""
    full = os.path.join(src_root, rel)
    st = os.lstat(full)
    rel = rel.replace(os.sep, "/").rstrip("/")
    bad = _safe_member_name(rel)
    if bad:
        print(f"  ! 跳过 {bad}: {rel}")
        return
    if os.path.isdir(full) and not os.path.islink(full):
        add_dir(tf, rel, st.st_mode & 0o7777)
        stats["dirs"] += 1
        return
    if os.path.islink(full):
        add_symlink(tf, rel, os.readlink(full))
        stats["links"] += 1
        return
    info = tarfile.TarInfo(rel)
    info.type = tarfile.REGTYPE
    info.size = st.st_size
    info.mode = st.st_mode & 0o7777
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime = 0
    with open(full, "rb") as f:
        tf.addfile(info, fileobj=io.BytesIO(f.read()))
    stats["files"] += 1


def build(out_path, src_root=None, bin_map=None):
    stats = {"files": 0, "dirs": 0, "links": 0}
    out_dir = os.path.dirname(os.path.abspath(out_path))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with tarfile.open(out_path, "w", format=tarfile.GNU_FORMAT) as tf:
        # --bin 提供真二进制时替换默认样例里的同名占位文件, 不产生重复成员.
        provided = {f"usr/bin/{name}" for name, _ in (bin_map or [])}
        sample_files = [s for s in SAMPLE_FILES if s[0] not in provided]
        if src_root:
            src_root = os.path.abspath(src_root)
            for root, dirs, files in os.walk(src_root):
                rel_root = os.path.relpath(root, src_root).replace(os.sep, "/")
                if rel_root != ".":
                    add_real_path(tf, src_root, rel_root, stats)  # 目录在走到它时添加一次
                for name in files:
                    child = f"{rel_root}/{name}" if rel_root != "." else name
                    add_real_path(tf, src_root, child, stats)
                # os.walk 默认不深入符号链接目录: 它们不会成为 root, 这里补记
                for name in list(dirs):
                    full = os.path.join(root, name)
                    if os.path.islink(full):
                        child = f"{rel_root}/{name}" if rel_root != "." else name
                        add_real_path(tf, src_root, child, stats)
                        dirs.remove(name)
        else:
            for name, mode in SAMPLE_DIRS:
                add_dir(tf, name, mode)
                stats["dirs"] += 1
            for name, data, mode in sample_files:
                add_file_bytes(tf, name, data, mode)
                stats["files"] += 1
            for name, target in SAMPLE_SYMLINKS:
                add_symlink(tf, name, target)
                stats["links"] += 1
        for name, path in bin_map or []:
            with open(path, "rb") as f:
                add_file_bytes(tf, f"usr/bin/{name}", f.read(), 0o755)
            stats["files"] += 1
    print(f"[ok] {out_path} ({os.path.getsize(out_path)} B) "
          f"dirs={stats['dirs']} files={stats['files']} symlinks={stats['links']}")
    return stats


def verify(out_path, stats=None):
    """round-trip: 重开 tar, 核对 SECURE_* 契约与数据可读回."""
    members = []
    with tarfile.open(out_path, "r") as tf:
        members = tf.getmembers()
        seen = set()
        for m in members:
            if m.name in seen:
                return f"重复成员: {m.name}"
            seen.add(m.name)
            bad = _safe_member_name(m.name)
            if bad:
                return f"成员 {m.name}: {bad}"
            if m.issym() and m.linkname.startswith("/"):
                return f"符号链接 {m.name} -> {m.linkname} 是绝对目标"
            if m.isfile():
                data = tf.extractfile(m).read()
                if len(data) != m.size:
                    return f"成员 {m.name} 数据长度 {len(data)} != {m.size}"
        if stats:
            expect = stats["files"] + stats["dirs"] + stats["links"]
            if len(members) != expect:
                return f"成员数 {len(members)} != 打包数 {expect}"
        if not any(m.name == "usr/bin/curl" for m in members):
            return "缺少 usr/bin/curl (样例契约)"
        if not any(m.name == "usr/bin/ksh" for m in members):
            return "缺少 usr/bin/ksh (样例契约)"
    print(f"[ok] verify: {len(members)} members, SECURE_NODOTDOT/NOABSOLUTEPATHS 契约通过")
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="最小 rootfs (procursus binpack 形状) 样例打包 -> Documents/rootfs.tar")
    parser.add_argument("--out", default=DEFAULT_OUT, help="产出 tar 路径 (默认 Documents/rootfs.tar)")
    parser.add_argument("--src", help="binpack 解包目录 (整体打包)")
    parser.add_argument("--bin", action="append", default=[], metavar="NAME=PATH",
                        help="单二进制: usr/bin/NAME=PATH (可多次)")
    parser.add_argument("--verify", action="store_true", help="打包后 round-trip 校验")
    parser.add_argument("--list", action="store_true", help="打包后列出成员")
    args = parser.parse_args(argv)

    out = os.path.normpath(args.out)
    if out.lower().endswith((".zst", ".tar.zst", ".tzst")):
        print("[fail] zstd 不支持: iOS 无系统 libzstd, SWCompression 无 zstd 解码器, "
              "Apple 系 libarchive 无 zstd filter。请产出 .tar (本脚本亦只支持无压缩 tar)。")
        return 2
    if args.src and args.bin:
        print("[fail] --src 与 --bin 二选一")
        return 2
    if args.src and not os.path.isdir(args.src):
        print(f"[fail] --src 不是目录: {args.src}")
        return 2
    bin_map = []
    for item in args.bin:
        if "=" not in item:
            print(f"[fail] --bin 需要 NAME=PATH: {item}")
            return 2
        name, path = item.split("=", 1)
        if not os.path.isfile(path):
            print(f"[fail] --bin 文件不存在: {path}")
            return 2
        if "/" in name or name.startswith("."):
            print(f"[fail] --bin NAME 只能是文件名: {name}")
            return 2
        bin_map.append((name, path))

    stats = build(out, src_root=args.src, bin_map=bin_map)
    if args.list:
        with tarfile.open(out, "r") as tf:
            for m in tf.getmembers():
                kind = {tarfile.REGTYPE: "f", tarfile.DIRTYPE: "d",
                        tarfile.SYMTYPE: "l"}.get(m.type, "?")
                print(f"  {kind} {m.name}" + (f" -> {m.linkname}" if m.issym() else ""))
    if args.verify:
        problem = verify(out, stats)
        if problem:
            print(f"[fail] verify: {problem}")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
