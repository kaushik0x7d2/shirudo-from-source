# Shirudo from source, on Debian 12, on purpose

Hands-on notes and reproducible artifacts for building
[Shirudo](https://github.com/shirudo-dev/shirudo), OpenAI and Cisco's eBPF Linux runtime-security tool
(released 2026-11-23), from source on a distro it doesn't support, booting it on the required `bpf-next`
kernel, and running its full shield block-then-release attack cycle end to end.

> 📖 Full write-up, with the story and real command output: _dev.to link coming, see the repo description._

This repo is the supporting material: the exact patches, the build recipe, and the demo orchestration. It
is not a fork of Shirudo. Nothing from their tree is vendored here. The patches are small diffs you apply
on top of an upstream checkout.

## What I found

- Shirudo builds and runs. I booted a test VM on the `bpf-next` kernel with a software TPM, enforcement
  came up green, and it blocked unsigned BPF program loads in real time.
- The headline trick works end to end. A signed `app-sandbox` shield contained a php2shell-style attack:
  the web shell never got written, the shell never spawned, outbound traffic was refused, and the benign
  path kept working. Remove the shield and the same attack goes straight through. No reboot either way.
- You can't deploy it on a normal fleet yet. It needs a custom patched kernel with no fallback, a real
  TPM 2.0, and a toolchain newer than stable distros carry. It also takes over BPF loading, so it evicts
  any other eBPF tool (Falco, Tetragon, Cilium) on an enforcing host.
- I built it on Debian 12 on purpose, to map that gap. About ten fixes. One of them is a single-line
  patch that is the clearest demonstration of its kernel requirement (see below).

## What's here

| Path | What it is |
|------|------------|
| [`BUILD.md`](BUILD.md) | The full build recipe on Debian 12 (bookworm), every fix, in order |
| [`patches/`](patches/) | The exact changes needed to build and run on an old-kernel host |
| [`scripts/demo.sh`](scripts/demo.sh) | The end-to-end app-sandbox demo (recycle guest, sync shield, attack blocked, release, attack lands), over one persistent SSH connection |

## The one-line patch

On a host kernel older than 6.7, every `shirudo` command dies with `image state: Invalid argument`. The
reason: Shirudo's `identity_read()` calls `bpf_obj_get_opts(..., BPF_F_PATH_FD)`, and `BPF_F_PATH_FD` only
exists on kernel 6.7 and up. On older kernels that `bpf()` syscall returns `EINVAL`, and the startup check
doesn't tolerate it.
[`patches/0001`](patches/0001-image_runtime-tolerate-EINVAL-on-old-kernels.patch) makes it treat `EINVAL`
as "no identity, proceed", which lets you experiment on an old host. It is a lab workaround, not a fix.
The failure is Shirudo correctly reporting that your kernel is too young. On a 6.7-or-patched kernel you
never hit it.

## The result (real output)

Shield loaded, attack contained:

```
write note.txt:               ok          <- benign write, allowed
write shell.php:              refused      <- blocked: no writing executable .php
rename note.txt note.php:     refused      <- blocked
mkdir d.php:                  refused      <- blocked
run a command:                did not run  <- blocked: no shell spawn
connect 127.0.0.1 port 8443:  ok           <- loopback, allowed
connect 1.1.1.1 port 80:      errno 13     <- blocked: no egress to the internet
```

Shield released (`upatch list` shows `none`), same attack:

```
write shell.php:  ok   |  mkdir d.php: ok  |  run a command: ran  |  connect 1.1.1.1: ok
```

## Verdict

It's well-built, with a strict trust model: signed, TPM-attested micropatches that an agent can author,
and a kernel that refuses any BPF loader it can't verify. For a homelab, or any fleet on stable distro
kernels, my call is watch, don't deploy. It won't run on a stock Debian, Ubuntu or Proxmox kernel, it
needs a real TPM 2.0 on every target, and it takes over BPF loading, so it can't run alongside the Falco
or Tetragon you already have. If you want this capability today, Falco or Tetragon on a stock kernel will
do it. Revisit Shirudo once it has tagged releases and a story for distro kernels.

## Credits and license

- The patches in [`patches/`](patches/) are diffs against
  [`shirudo-dev/shirudo`](https://github.com/shirudo-dev/shirudo) at commit `6514073`. Shirudo is
  © its authors under BSD-2-Clause.
- The scripts and notes in this repo are © 2026 and released under [BSD-2-Clause](LICENSE) to match.
- This is an independent experiment, not affiliated with OpenAI, Cisco, or the Shirudo project.
