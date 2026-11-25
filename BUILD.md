# Building Shirudo from source on Debian 12 (bookworm)

Shirudo targets bleeding-edge distros. Building it on **Debian 12**, which it does *not* support, is a
good way to find exactly where the hard dependencies are. The only true hard requirement turns out to be
the kernel; everything else is a soft spot you can work around. The test VM Shirudo boots uses a
**prebuilt `bpf-next` kernel artifact the project ships**, so you do *not* have to compile a kernel.

Environment used: a 6-vCPU / 12 GB Debian 12 VM with nested KVM. Host kernel 6.1.

Apply [`patches/0001`](patches/) and [`patches/0002`](patches/) to your upstream checkout first, then
follow the steps. See [`patches/0003-generated-file-fixes.md`](patches/0003-generated-file-fixes.md) for
the fixes to generated/system files that can't be shipped as git diffs.

## 1. Toolchain

```bash
# clang-23 with the BPF target (Debian 12 ships far older; apt.llvm.org carries 23 for bookworm)
sudo apt-get install -y software-properties-common          # llvm.sh needs add-apt-repository
wget https://apt.llvm.org/llvm.sh && chmod +x llvm.sh && sudo ./llvm.sh 23

sudo apt-get install -y \
  qemu-system-x86 swtpm swtpm-tools tpm2-tools libtss2-dev \
  libguestfs-tools dracut-core cryptsetup-bin e2fsprogs \
  luajit libluajit-5.1-dev docker.io jq \
  autoconf automake libtool autoconf-archive              # target-deps needs autoreconf

# console-setup's postinst fails on a headless VM and jams dpkg/apt, so remove it
sudo apt-get purge -y console-setup keyboard-configuration
```

## 2. Static dependencies (`make target-deps`)

Builds OpenSSL 3.5.9 / libcurl 8.18 / tpm2-tss 4.2 as static libs into `build/target-deps/`
(bookworm ships OpenSSL 3.0, which is too old; 3.5 is the first release with **ML-DSA**, which Shirudo's
post-quantum signatures require). Creates `build/target-deps/target.env`.

```bash
make target-deps
```

## 3. An OpenSSL 3.5 CLI (the ML-DSA probe needs the binary, not just libs)

`target-deps` builds OpenSSL **libs-only** (`no-apps`), but the operator build probes run the `openssl`
*binary* to check for ML-DSA. Build the CLI from the staged source:

```bash
cd build/target-deps/src/openssl-3.5.9
./Configure linux-x86_64 no-docs no-tests --prefix=$HOME/openssl35
make -j"$(nproc)" && make install_sw
# it links the system libssl 3.0 at runtime unless you point it at its own libs:
patchelf --set-rpath "$HOME/openssl35/lib64" "$HOME/openssl35/bin/openssl"
# install_sw doesn't install a config; give it one:
mkdir -p "$HOME/openssl35/ssl" && cp apps/openssl.cnf "$HOME/openssl35/ssl/openssl.cnf"
cd -
```

## 4. Build environment (export everything)

```bash
source build/target-deps/target.env
export PKG_CONFIG_PATH="$SHIRUDO_TARGET_PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$HOME/openssl35/lib64"
export PATH="$HOME/openssl35/bin:$PATH:/sbin:/usr/sbin"
export CC=clang                    # gcc-12 lacks -fstrict-flex-arrays=3; clang-23 has it
```

## 5. Static-link fixes

The target-deps libs are static-only, but the operator profile uses non-static `pkg-config`, which omits
the transitive link set. After `make config.mk CC=clang`:

- Add `-lm -ldl` to the `Libs:` line of `/usr/lib/x86_64-linux-gnu/pkgconfig/luajit.pc` (LuaJIT needs libm).
- In `config.mk`, replace `TSS2_LIBS` / `LIBCURL_LIBS` / `LIBSSL_LIBS` / `LIBCRYPTO_LIBS` with their
  `pkg-config --static --libs <pkg>` values.
- Append `-ltss2-tcti-device -ltss2-tcti-null` to `TSS2_LIBS` (the `nodl` tctildr needs them).

(Details and rationale: [`patches/0003-generated-file-fixes.md`](patches/0003-generated-file-fixes.md).)

Then build:

```bash
make CC=clang
make shirudo-build CC=clang
```

Out the other side: a statically-linked `shirudo` (~15.7 MB PIE) and `tools/shirudo-build/shirudo-build`.

## 6. Boot the test VM and run the demo

```bash
# user in the kvm group (libguestfs) + memlock for BPF
sudo usermod -aG kvm "$USER"          # re-login after this
sudo prlimit --pid $$ --memlock=unlimited:unlimited

testing/vm/kernel-artifact.sh fetch   # prebuilt bpf-next kernel, no kernel compile
export LIBGUESTFS_BACKEND=direct
make stack-up                         # OCI registry + ClickHouse + OTel collector (Docker)
make -C testing vm-clean VM_NAME=quickstart
make vm VM_NAME=quickstart CC=clang   # builds the Ubuntu image + boots the nested test VM; enrolls at boot
loginctl enable-linger "$USER"        # so the user-unit VM survives your ssh session
```

Then run [`scripts/demo.sh`](scripts/demo.sh) for the full shield block → release attack cycle.

> **Test-harness gotcha:** `make vm-ssh` opens a *fresh* SSH connection per command. A scripted demo
> that fires ~9 of them in a burst will exhaust the nested guest's user-mode networking and you'll see
> `SSH did not become ready`. Run all guest steps over a single persistent SSH `ControlMaster`
> connection instead, which is what `scripts/demo.sh` does.
