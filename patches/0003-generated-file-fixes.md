# Generated- and system-file fixes (not shippable as repo diffs)

These touch files that aren't tracked in the Shirudo tree (`config.mk` is generated; `luajit.pc` is a
system package file), so they're documented here rather than as `.patch` files. All are consequences of
one root cause: `make target-deps` builds its dependencies **static-only**, but the operator build
profile resolves them with non-static `pkg-config`, which omits the transitive link set.

## 1. `luajit.pc` — LuaJIT needs libm/libdl when linked statically

File: `/usr/lib/x86_64-linux-gnu/pkgconfig/luajit.pc`

Append `-lm -ldl` to the `Libs:` line. Without it, the static link fails with undefined references to
`cos`, `pow`, etc.

```
-Libs: -L${libdir} -lluajit-5.1
+Libs: -L${libdir} -lluajit-5.1 -lm -ldl
```

## 2. `config.mk` — use the full static link sets

After `make config.mk CC=clang`, replace these variables with their `pkg-config --static` values:

```bash
for v in TSS2:tss2-esys LIBCURL:libcurl LIBSSL:libssl LIBCRYPTO:libcrypto; do
  name=${v%%:*}; pkg=${v##*:}
  printf '%s_LIBS = %s\n' "$name" "$(pkg-config --static --libs "$pkg")"
done
# then edit config.mk's *_LIBS lines to match the printed values
```

Then append the TCTI device/null libs to `TSS2_LIBS` (the `nodl` `tctildr` needs them, and
`pkg-config` won't pull them in):

```
TSS2_LIBS = <...static libs from tss2-esys...> -ltss2-tcti-device -ltss2-tcti-null
```

Symptoms if you skip this:
- undefined reference to `Tss2_MU_*`  → the `--static` rewrite of `TSS2_LIBS` fixes it
- undefined reference to `Tss2_Tcti_Device_Init` → the appended `-ltss2-tcti-device -ltss2-tcti-null` fixes it

## 3. BPF header include path (only needed to *build* upatches)

`shirudo build` compiles upatches against headers at the baked `/usr/local/share/shirudo/bpf/include`.
`make install` populates it; if you run from the build tree, copy them there yourself:

```bash
sudo mkdir -p /usr/local/share/shirudo/bpf/include/bpf
sudo cp vendor/libbpf/src/*.h /usr/local/share/shirudo/bpf/include/bpf/
sudo cp bpf/lib/*.h           /usr/local/share/shirudo/bpf/include/
```

Symptom if you skip it: `put-shields` / `shirudo build` fails with `bpf/bpf_endian.h: No such file or
directory` (it runs in a temp dir, so relative `./vendor/libbpf/...` lookups miss).
