# Shirudo from source — on Debian 12, on purpose

Hands-on notes and reproducible artifacts for building **[Shirudo](https://github.com/shirudo-dev/shirudo)**
— OpenAI and Cisco's eBPF Linux runtime-security tool (launched 2026-11-23) — **from source on a distro
it explicitly doesn't support**, booting it on the required `bpf-next` kernel, and running its full
shield **block → release** attack cycle end to end.

> 📖 **Full write-up (the story, with real command output):** _dev.to link coming — see Releases/description_

This repo is the supporting material: the exact patches, the build recipe, and the demo orchestration.
It is **not** a fork of Shirudo — nothing from their tree is vendored here. The patches are small diffs
you apply on top of an upstream checkout.

## TL;DR findings

- **Shirudo is real and it works.** Built from source, booted a test VM on the `bpf-next` kernel with a
  software TPM, enforcement came up green and blocked unsigned BPF program loads in real time.
- **The headline capability works end to end.** A signed `app-sandbox` shield contained a php2shell-style
  attack — writing `shell.php`, spawning a shell, and reaching the internet were all refused while the
  benign path kept working. Remove the shield and the identical attack immediately succeeds. No reboot
  at either edge.
- **It is not deployable on a normal fleet today.** It needs a custom patched kernel (no fallback), a
  real TPM 2.0, and a toolchain newer than stable distros ship — and it *evicts* any other eBPF tool
  (Falco, Tetragon, Cilium) on an enforcing host.
- Built on **Debian 12** on purpose, to map the gap. ~10 fixes. One is a one-line patch that *is* the
  whole thesis of Shirudo's kernel requirement (see below).

## What's here

| Path | What it is |
|------|------------|
| [`BUILD.md`](BUILD.md) | The full build recipe on Debian 12 (bookworm) — every fix, in order |
| [`patches/`](patches/) | The exact changes needed to build/run on an old-kernel host |
| [`scripts/demo.sh`](scripts/demo.sh) | The end-to-end app-sandbox attack demo (recycle guest → shield → attack blocked → release → attack lands), over one persistent SSH connection |

## The one-line patch that is the whole point

On a host kernel older than 6.7, every `shirudo` command dies with `image state: Invalid argument`.
The cause: Shirudo's `identity_read()` calls `bpf_obj_get_opts(..., BPF_F_PATH_FD)`, and `BPF_F_PATH_FD`
only exists in kernel ≥ 6.7. On older kernels that `bpf()` syscall returns `EINVAL`, and the startup
check doesn't tolerate it. [`patches/0001`](patches/0001-image_runtime-tolerate-EINVAL-on-old-kernels.patch)
makes it treat `EINVAL` as "no identity, proceed" — which lets you *experiment* on an old host, but it's
also Shirudo correctly telling you your kernel is too young. On a ≥6.7/patched kernel you never hit it.

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

Shield released (`upatch list → none`), same attack:

```
write shell.php:  ok   |  mkdir d.php: ok  |  run a command: ran  |  connect 1.1.1.1: ok
```

## Verdict

Serious, well-built engineering with an unusually strict trust model. But for a homelab — or any fleet
on stable distro kernels — it is **watch, don't deploy**: it won't run on a stock Debian/Ubuntu/Proxmox
kernel, it needs a real TPM 2.0 on every target, and it takes over BPF loading entirely so it can't sit
alongside the Falco/Tetragon you already run. If you want this capability *today*, **Falco or Tetragon
on a stock kernel is the shippable answer.** Revisit Shirudo after it has tagged releases and a
distro-kernel story.

## Credits & license

- The patches in [`patches/`](patches/) are diffs against
  [`shirudo-dev/shirudo`](https://github.com/shirudo-dev/shirudo) at commit `6514073`. Shirudo is
  © its authors under BSD-2-Clause.
- The scripts and notes in this repo are © 2026 and released under [BSD-2-Clause](LICENSE) to match.
- This is an independent experiment. Not affiliated with OpenAI, Cisco, or the Shirudo project.
