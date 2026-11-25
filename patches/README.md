# Patches

Small diffs against [`shirudo-dev/shirudo`](https://github.com/shirudo-dev/shirudo) at commit `6514073`.
Apply from the root of an upstream checkout:

```bash
git apply /path/to/0001-image_runtime-tolerate-EINVAL-on-old-kernels.patch
git apply /path/to/0002-prepare-runtime-strip-no-selinux-relabel.patch
```

| Patch | Why |
|-------|-----|
| `0001-image_runtime-tolerate-EINVAL-on-old-kernels.patch` | On a host kernel < 6.7, `identity_read()` uses `BPF_F_PATH_FD` (kernel ≥ 6.7), so the `bpf()` syscall returns `EINVAL`. The startup check only tolerates `ENOENT`/`EPERM`/`EACCES`, so every command dies with `image state: Invalid argument`. This treats `EINVAL` as "no identity, proceed as operator." **This is a lab workaround, not a fix** — it's the tool correctly reporting that your kernel is too old. On a ≥6.7/patched kernel you never hit this path. |
| `0002-prepare-runtime-strip-no-selinux-relabel.patch` | Bookworm's `virt-customize` (libguestfs 1.48) predates the `--no-selinux-relabel` flag. The flag is a no-op on the Ubuntu guest image anyway, so it's simply removed. |

Generated/system-file fixes that can't be expressed as a repo diff (`config.mk`, `luajit.pc`) are
documented in [`0003-generated-file-fixes.md`](0003-generated-file-fixes.md).
