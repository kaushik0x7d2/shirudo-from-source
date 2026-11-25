#!/bin/bash
# Last-mile Shirudo attack demo: recycle guest, run full app-sandbox block/release
# over ONE persistent SSH ControlMaster connection (avoids slirp/sshd churn).
exec > ~/demo2.log 2>&1
set -x
cd ~/shirudo || exit 1

# ---- operator/build env (same as setupE6) ----
sudo prlimit --pid $$ --memlock=unlimited:unlimited
source build/target-deps/target.env
export PKG_CONFIG_PATH="$SHIRUDO_TARGET_PKG_CONFIG_PATH"
export PATH="$HOME/openssl35/bin:$PATH:/sbin:/usr/sbin"
export CC=clang LIBGUESTFS_BACKEND=direct

# ---- 1. recycle the wedged guest ----
echo "===== RECYCLE: vm-clean + vm ====="
make -C testing vm-clean VM_NAME=quickstart 2>&1 | tail -3
make vm VM_NAME=quickstart CC=clang 2>&1 | tail -25
echo "vm rc=${PIPESTATUS[0]}"

# ---- stack env for operator steps ----
. build/test-vm/stack/env
export PATH="$HOME/openssl35/bin:$PATH:/sbin:/usr/sbin"
echo "KEYS=$KEYS TREE=$TREE"

RUN=build/test-vm/vms/quickstart
KEY=$RUN/ssh/id_ed25519
PORT=$(cat $RUN/ssh.port)
CM=/tmp/cm-quickstart.sock
rm -f "$CM"
SSHG(){ ssh -o ControlMaster=auto -o ControlPath="$CM" -o ControlPersist=240 \
  -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=12 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
  -i "$KEY" -p "$PORT" root@127.0.0.1 "$@"; }

# ---- 2. establish the single master connection (with retries) ----
echo "===== ESTABLISH SSH MASTER on port $PORT ====="
UP=0
for i in $(seq 1 25); do
  if SSHG "echo GUEST_UP_$i; uname -r" 2>/dev/null; then echo "MASTER-UP on attempt $i"; UP=1; break; fi
  echo "ssh wait $i"; sleep 4
done
if [ "$UP" != 1 ]; then echo "FATAL: guest SSH never came up"; exit 2; fi

# ---- confirm enforcement before we start ----
echo "===== PRE: shirudo-runtime status ====="
SSHG "shirudo-runtime status 2>&1 | head -20"

# ---- STEP1 operator: build apache sandbox tar ----
echo "===== STEP1 operator: build apache-php.tar ====="
mkdir -p build/tutorial
upatches/app-sandbox/demo/build.sh build/tutorial/apache-php.tar; echo "build.sh rc=$?"

# ---- STEP2 guest: install apache ----
echo "===== STEP2 guest: install apache ====="
SSHG "sh /workspace/shirudo/upatches/app-sandbox/demo/apache.sh install /workspace/shirudo/build/tutorial/apache-php.tar 2>&1; echo install_rc=\$?"

# ---- STEP3 operator: publish sandbox upatch to tree ----
echo "===== STEP3 operator: publish + append to tree ====="
tools/put-shields --version 1.0.0 --keys-dir "$KEYS" --catalog build/tutorial/sandbox.json --new-index oci://127.0.0.1:15444/hardening upatches/app-sandbox; echo "put-shields rc=$?"
SANDBOX_DIGEST=$(jq -r ".shields[0].manifest_digest" build/tutorial/sandbox.json); echo "digest=$SANDBOX_DIGEST"
tools/backend/jobs/shields-put build/tutorial/sandbox.json; echo "shields-put rc=$?"
shirudo bpm tree append oci://127.0.0.1:15444/hardening/app-sandbox:1.0.0 --package-digest "$SANDBOX_DIGEST" "$TREE" --tree-id local-tree --keys-dir "$KEYS"; echo "append rc=$?"

# ---- STEP4 guest: sync tree + list upatches (THE tree-sync test) ----
echo "===== STEP4 guest: tree-sync + upatch list ====="
SSHG "set -x; systemctl start shirudo-bpm-tree-sync.service; echo start_rc=\$?; sleep 3; systemctl --no-pager --full status shirudo-bpm-tree-sync.service 2>&1 | tail -12; echo '--- journal ---'; journalctl -u shirudo-bpm-tree-sync -n 15 --no-pager 2>&1 | tail -15; echo '--- upatch list ---'; shirudo-runtime upatch list 2>&1"

# ---- STEP5 guest: start apache, benign, ATTACK (expect BLOCKED) ----
echo "===== STEP5 guest: start apache + benign + ATTACK (sandboxed) ====="
SSHG "sh /workspace/shirudo/upatches/app-sandbox/demo/apache.sh start 2>&1; sleep 3; echo '--- benign index.php ---'; curl -s --insecure https://127.0.0.1:8443/index.php 2>&1; echo; echo '--- ATTACK attack.php (EXPECT BLOCKED) ---'; curl -s --insecure https://127.0.0.1:8443/attack.php 2>&1; echo; echo '--- uploads dir (sandboxed) ---'; ls -la /var/lib/app-sandbox-demo/var/www/html/uploads 2>&1; echo '--- tamper counters ---'; shirudo-runtime status 2>&1 | sed -n '/Tamper/,$p'"

# ---- STEP6 operator: RELEASE (delete sandbox from tree) ----
echo "===== STEP6 operator: release (delete from tree) ====="
shirudo bpm tree append oci://127.0.0.1:15444/hardening/app-sandbox:1.0.0 --package-digest "$SANDBOX_DIGEST" "$TREE" --tree-id local-tree --keys-dir "$KEYS" --op delete; echo "delete rc=$?"

# ---- STEP7 guest: sync + ATTACK again (expect SUCCESS now) ----
echo "===== STEP7 guest: tree-sync + ATTACK (expect SUCCESS) ====="
SSHG "systemctl start shirudo-bpm-tree-sync.service; echo start_rc=\$?; sleep 3; echo '--- upatch list ---'; shirudo-runtime upatch list 2>&1; echo '--- ATTACK attack.php (EXPECT SUCCESS) ---'; curl -s --insecure https://127.0.0.1:8443/attack.php 2>&1; echo; echo '--- uploads dir (unsandboxed) ---'; ls -la /var/lib/app-sandbox-demo/var/www/html/uploads 2>&1"

# ---- close master ----
ssh -O exit -o ControlPath="$CM" root@127.0.0.1 2>/dev/null
echo "DEMO2-DONE"
