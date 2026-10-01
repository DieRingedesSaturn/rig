"""Audit regressions: isolated HOME/configs, simulated system services, no installs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("RIG_TEST_BASH", "bash")
CHECKS = 0


def check(condition, message):
    global CHECKS
    assert condition, message
    CHECKS += 1


def run(script, env, ok=True):
    proc = subprocess.run([BASH, "-c", script], env=env, text=True,
                          capture_output=True, timeout=30)
    if ok and proc.returncode:
        raise AssertionError(f"command failed ({proc.returncode}):\n{proc.stdout}\n{proc.stderr}")
    return proc


CONTROLLER = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
w = pathlib.Path(os.environ['RIG_FIXTURE'])
cmd = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (w/'operations').open('a') as f: f.write(cmd+' '+' '.join(args)+'\n')
cfg = w/'etc/firewalld/config.json'
runtime = w/'runtime.json'
active = w/'active'
enabled = w/'enabled'
failure = os.environ.get('RIG_FAIL_STEP', '')
def load(p): return json.loads(p.read_text())
def save(p, data): p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(data))
def once(name):
    marker=w/('failed-'+name)
    if failure == name and not marker.exists(): marker.touch(); return True
    return False
if cmd == 'sudo':
    if args and args[0] == '-n': args=args[1:]
    if args and args[0] == '-l': sys.exit(0)
    if args[0] in ['cp','rm','chown','mkdir','test']:
        # A fixture accidentally calling an unrewritten system path must fail.
        for a in args[1:]:
            if a.startswith('/') and not a.startswith(str(w)):
                raise SystemExit('UNSAFE fixture path: '+a)
    os.execvp(args[0],args)
if cmd == 'systemctl':
    target = 'firewalld' in args
    action = args[0]
    if action == 'show': print('Version=fixture'); sys.exit(0)
    if target:
        if action == 'is-active': sys.exit(0 if active.read_text()=='1' else 3)
        if action == 'is-enabled': sys.exit(0 if enabled.read_text()=='1' else 1)
        if action in ['enable','start']:
            if action == 'enable': enabled.write_text('1')
            if action == 'start' or '--now' in args:
                active.write_text('1'); shutil.copyfile(cfg,runtime)
        if action == 'stop': active.write_text('0')
        if action == 'disable': enabled.write_text('0')
    elif failure == 'reload' and 'Port 2222' in (w/'sshd_config').read_text():
        sys.exit(1)
    sys.exit(0)
if cmd in ['firewall-cmd','firewall-offline-cmd']:
    if '--state' in args: print('running' if active.read_text()=='1' else 'not running'); sys.exit(0 if active.read_text()=='1' else 252)
    if '--runtime-to-permanent' in args: shutil.copyfile(runtime,cfg); sys.exit(0)
    if '--reload' in args:
        if 'remove-public' in (w/'operations').read_text() and once('final-reload'): sys.exit(1)
        shutil.copyfile(cfg,runtime); sys.exit(0)
    permanent=cmd=='firewall-offline-cmd' or '--permanent' in args
    path=cfg if permanent else runtime
    data=load(path)
    zone=next((a.split('=',1)[1] for a in args if a.startswith('--zone=')),data['default'])
    z=data['zones'].setdefault(zone,{'ports':[],'services':[],'interfaces':[],'sources':[],'target':'default'})
    for a in args:
        if a=='--get-zones': print(' '.join(data['zones'])); sys.exit(0)
        if a=='--get-default-zone': print(data['default']); sys.exit(0)
        if a.startswith('--new-zone='): data['zones'].setdefault(a.split('=',1)[1],{'ports':[],'services':[],'interfaces':[],'sources':[],'target':'default'})
        if a.startswith('--set-default-zone='):
            data['default']=a.split('=',1)[1]
            if cmd=='firewall-cmd':
                disk=load(cfg); disk['default']=data['default']; save(cfg,disk)
        if a.startswith('--set-target='): z['target']=a.split('=',1)[1]
        if a.startswith('--change-interface='): z['interfaces']=[a.split('=',1)[1]]
        if a.startswith('--add-port='):
            value=a.split('=',1)[1]
            if value not in z['ports']: z['ports'].append(value)
        if a.startswith('--query-port='): sys.exit(0 if a.split('=',1)[1] in z['ports'] else 1)
        if a.startswith('--remove-port='):
            value=a.split('=',1)[1]
            z['ports']=[p for p in z['ports'] if p != value]
            with (w/'operations').open('a') as f: f.write('remove-public\n')
        if a.startswith('--remove-service='): z['services'].remove(a.split('=',1)[1])
        for field in ['ports','services','interfaces','sources']:
            if a=='--list-'+field: print(' '.join(z[field])); sys.exit(0)
    save(path,data); sys.exit(0)
if cmd == 'ufw':
    path=w/'etc/ufw/config.json'; data=load(path)
    if args[0]=='status':
        print('Status: '+('active' if active.read_text()=='1' else 'inactive'))
        for p in data['ports']:
            if p.endswith('@tailscale'): print(p.split('@')[0]+' on tailscale0 ALLOW IN Anywhere')
            else: print(p+' ALLOW Anywhere')
        sys.exit(0)
    if '--force' in args: args.remove('--force')
    if args[0]=='allow':
        port=args[args.index('port')+1]+'/tcp@tailscale' if args[1]=='in' else args[1]
        if port not in data['ports']: data['ports'].append(port)
    if args[0]=='default': data[args[2]]=args[1]
    if args[0]=='enable': active.write_text('1')
    if args[0]=='disable': active.write_text('0')
    if args[0]=='delete':
        port=args[args.index('port')+1]+'/tcp@tailscale' if args[2]=='in' else args[2]
        data['ports']=[p for p in data['ports'] if p != port]
        with (w/'operations').open('a') as f: f.write('remove-public\n')
    if args[0]=='reload' and once('final-reload'): sys.exit(1)
    save(path,data); sys.exit(0)
if cmd == 'ss':
    port='22' if failure in ['listener','rollback'] else '2222'
    print('LISTEN 0 128 *:'+port+' *:* users:(("sshd",pid=123,fd=3))'); sys.exit(0)
if cmd == 'tailscale': print('100.64.0.1'); sys.exit(0)
if cmd == 'sshd': print('port 22'); sys.exit(0)
if cmd == 'curl': sys.stderr.write('simulated download failure\n'); sys.exit(22)
raise SystemExit('unexpected fixture command: '+cmd)
'''


def fixture(base, name, backend="ufw", active=False):
    work = base / name
    (work / "bin").mkdir(parents=True)
    (work / "lib").mkdir()
    (work / "home").mkdir()
    (work / "etc/ufw").mkdir(parents=True)
    (work / "etc/default").mkdir(parents=True)
    (work / "etc/firewalld").mkdir(parents=True)
    (work / "operations").touch()
    (work / "active").write_text("1" if active else "0")
    (work / "enabled").write_text("1" if active else "0")
    (work / "sshd_config").write_text("Port 22\nPasswordAuthentication yes\nPubkeyAuthentication yes\n")
    (work / "etc/ufw/config.json").write_text(json.dumps({"ports": ["22/tcp", "80/tcp"], "incoming": "allow", "outgoing": "allow"}))
    (work / "etc/default/ufw").write_text("original defaults\n")
    zones = {z: {"ports": [], "services": [], "interfaces": [], "sources": [], "target": "default"}
             for z in ["home", "public"]}
    zones["public"]["services"] = ["ssh", "dhcpv6-client"]
    data = {"default": "home", "zones": zones}
    (work / "etc/firewalld/config.json").write_text(json.dumps(data))
    runtime_data = json.loads(json.dumps(data))
    runtime_data["zones"]["home"]["ports"] = ["3333/tcp"]
    (work / "runtime.json").write_text(json.dumps(runtime_data))
    for file in (ROOT / "lib").glob("*.sh"):
        text = file.read_text()
        for path in ["/etc/default/ufw", "/etc/ufw", "/etc/firewalld"]:
            text = text.replace(path, str(work / path.lstrip("/")))
        (work / "lib" / file.name).write_text(text)
    with (work / "lib/rig-config.sh").open("a") as f:
        f.write(r'''
eval "$(declare -f rig_config_set | sed '1s/rig_config_set/_fixture_config_set/')"
rig_config_set() {
    [[ "${RIG_FAIL_STEP:-}" != policy || "$1" != RIG_PUBLIC_TCP ]] || return 1
    _fixture_config_set "$@"
}
''')
    # Test the real apply/rollback choreography; test authentication separately.
    with (work / "lib/security.sh").open("a") as f:
        f.write(r'''
security_verify_admin_user() {
    [[ -f "$2" && "$3" == user=admin,* ]] || return 1
    [[ "${RIG_FAIL_STEP:-}" != guard ]]
}
security_test_sshd_config() {
    if [[ "${RIG_FAIL_STEP:-}" == installed && "${1:-}" == "" && ! -f "$RIG_FIXTURE/failed-installed" ]]; then
        touch "$RIG_FIXTURE/failed-installed"; return 1
    fi
    return 0
}
''')
    body = (ROOT / "setup-security.sh").read_text().replace('SSHD_CONFIG="/etc/ssh/sshd_config"', f'SSHD_CONFIG="{work}/sshd_config"')
    (work / "setup-security.sh").write_text(body)
    controller = work / "bin/controller"
    controller.write_text(CONTROLLER)
    controller.chmod(0o755)
    for command in ["sudo", "systemctl", "firewall-cmd", "firewall-offline-cmd", "ufw", "ss", "sshd", "tailscale", "curl"]:
        (work / "bin" / command).symlink_to(controller.name)
    env = {k: v for k, v in os.environ.items() if not k.startswith("RIG_") and k not in ["SSH_CONNECTION", "GH_PROXY", "NVM_DIR"]}
    env.update(HOME=str(work / "home"), TMPDIR=str(work), PATH=str(work / "bin") + ":" + os.environ["PATH"],
               RIG_FIXTURE=str(work), RIG_CONFIG_FILE=str(work / "home/config"), RIG_ADMIN_USER="admin",
               RIG_SSH_PORT="2222", RIG_SSH_PASSWORD_AUTH="no", RIG_SSH_ROOT_LOGIN="no",
               RIG_SSH_PUBKEY_AUTH="yes", RIG_SSH_ACCESS="public", RIG_FIREWALL=backend,
               RIG_CHECK_LISTENING_PORTS="no", GH_PROXY="")
    return work, env


with tempfile.TemporaryDirectory(prefix="rig-regressions-") as temp:
    base = Path(temp)
    plain_env = dict(os.environ, HOME=str(base / "home"), NVM_DIR=str(base / "home/.nvm"), GH_PROXY="")
    (base / "home").mkdir()
    # Every failure must restore BOTH SSH and the firewall, without persisting policy.
    for failure in ["guard", "installed", "reload", "listener", "final-reload", "policy"]:
        work, env = fixture(base, "ufw-" + failure)
        env["RIG_FAIL_STEP"] = failure
        original = (work / "etc/ufw/config.json").read_text()
        proc = run(f'"{BASH}" "{work}/setup-security.sh" --yes', env, ok=False)
        check(proc.returncode != 0, f"{failure} reported success")
        check((work / "sshd_config").read_text().startswith("Port 22\n"), f"{failure}: SSH not restored")
        check((work / "etc/ufw/config.json").read_text() == original, f"{failure}: firewall rules not restored: {proc.stderr}")
        check((work / "active").read_text() == "0", f"{failure}: firewall activation not restored")
        check(not (work / "home/config").exists(), f"{failure}: failed policy persisted")
        if failure == "guard":
            check("ufw " not in (work / "operations").read_text(), "candidate rejection mutated firewall")
        check(not list((work / "home").glob("config.tmp.*")), "failed policy left staging files")
    for backend in ["ufw", "firewalld"]:
        work, env = fixture(base, backend + "-success", backend)
        run(f'"{BASH}" "{work}/setup-security.sh" --yes', env)
        operations = (work / "operations").read_text()
        enable = operations.index("ufw --force enable" if backend == "ufw" else "systemctl enable --now firewalld")
        check(operations.index("22/tcp") < enable and operations.index("2222/tcp") < enable, f"{backend}: activated before SSH protection")
        check(operations.index("ss -H -lntp") < operations.index("remove-public"), f"{backend}: withdrew old SSH before listener verification")
        check('RIG_SSH_PORT="2222"' in (work / "home/config").read_text(), "successful policy not persisted")
        if backend == "firewalld":
            data = json.loads((work / "runtime.json").read_text())
            check(data["default"] == "public" and "2222/tcp" in data["zones"]["public"]["ports"], "firewalld allow rule landed in wrong zone")
            check("firewall-offline-cmd --zone=public --add-port=2222/tcp" in operations, "stopped firewalld was not prepared offline")
    # Repeated current-session ports must not leave an old Tailscale rule behind.
    for backend in ["ufw", "firewalld"]:
        work, env = fixture(base, backend + "-tailscale", backend)
        (work / "home/config").write_text('RIG_SSH_ACCESS="tailscale"\n')
        env.update(RIG_SSH_ACCESS="tailscale", SSH_CONNECTION="100.64.0.2 12345 100.64.0.1 22")
        run(f'"{BASH}" "{work}/setup-security.sh" --yes', env)
        if backend == "ufw":
            ports = json.loads((work / "etc/ufw/config.json").read_text())["ports"]
            check("2222/tcp@tailscale" in ports and "2222/tcp" not in ports, "ufw lost Tailscale restriction")
            check("22/tcp@tailscale" not in ports and "22/tcp" not in ports, "ufw kept old SSH rules")
            operations = (work / "operations").read_text()
            check(operations.splitlines().count("ufw --force delete allow in on tailscale0 to any port 22 proto tcp") == 1, "duplicate current port caused repeated deletion")
        else:
            zones = json.loads((work / "runtime.json").read_text())["zones"]
            check("2222/tcp" in zones["rig-tailscale"]["ports"] and "2222/tcp" not in zones["public"]["ports"], "firewalld lost Tailscale restriction")
            check("22/tcp" not in zones["rig-tailscale"]["ports"] and "22/tcp" not in zones["public"]["ports"], "firewalld kept old SSH rules")
    # Runtime and disk state may differ. Rollback must preserve that distinction.
    work, env = fixture(base, "firewalld-rollback", "firewalld", active=True)
    env["RIG_FAIL_STEP"] = "reload"
    original_disk = (work / "etc/firewalld/config.json").read_text()
    original_runtime = (work / "runtime.json").read_text()
    proc = run(f'"{BASH}" "{work}/setup-security.sh" --yes', env, ok=False)
    check(proc.returncode != 0, "firewalld reload failure accepted")
    check((work / "etc/firewalld/config.json").read_text() == original_disk, "firewalld permanent rollback lost state")
    check((work / "runtime.json").read_text() == original_runtime, "firewalld runtime rollback lost state")
    check((work / "active").read_text() == "1" and (work / "enabled").read_text() == "1", "firewalld service state lost")
    work, env = fixture(base, "firewalld-stopped-rollback", "firewalld")
    env["RIG_FAIL_STEP"] = "reload"
    original_disk = (work / "etc/firewalld/config.json").read_text()
    proc = run(f'"{BASH}" "{work}/setup-security.sh" --yes', env, ok=False)
    check(proc.returncode != 0, "stopped firewalld failure accepted")
    check((work / "etc/firewalld/config.json").read_text() == original_disk, "stopped firewalld configuration not restored")
    check((work / "active").read_text() == "0" and (work / "enabled").read_text() == "0", "stopped firewalld was left enabled")
    work, env = fixture(base, "unmanaged-zone", "firewalld")
    cfg_path = work / "etc/firewalld/config.json"
    cfg_data = json.loads(cfg_path.read_text())
    cfg_data["zones"]["home"]["interfaces"] = ["eth0"]
    original_disk = json.dumps(cfg_data)
    cfg_path.write_text(original_disk)
    proc = run(f'"{BASH}" "{work}/setup-security.sh" --yes', env, ok=False)
    check(proc.returncode != 0 and "Unmanaged firewalld zone" in proc.stderr, "explicit external zone binding ignored")
    check(cfg_path.read_text() == original_disk and (work / "active").read_text() == "0", "binding rejection changed firewall")
    # Both authentication flags must be rejected even in noninteractive mode.
    work, env = fixture(base, "auth-disabled")
    env["RIG_SSH_PUBKEY_AUTH"] = "no"
    proc = run(f'"{BASH}" "{work}/setup-security.sh" --yes', env, ok=False)
    check(proc.returncode != 0 and "disable both" in proc.stderr, "all-auth-disabled policy accepted")
    check("ufw " not in (work / "operations").read_text(), "invalid auth mutated firewall")

    # Lists retain all rows and all values; wildcard sockets remain in the audit.
    proc = run(f'''
source "{ROOT}/lib/security.sh"
sshd() {{ printf 'denyusers other\\ndenyusers admin\\nauthorizedkeysfile .ssh/first .ssh/second\\n'; }}
[[ "$(security_get_sshd_param DenyUsers '')" == 'other admin' ]]
[[ "$(security_get_sshd_param AuthorizedKeysFile '')" == '.ssh/first .ssh/second' ]]
_security_user_in_list admin 'admin@192.0.2.*' 'addr=192.0.2.1,host=client' allow
if _security_user_in_list admin 'admin@192.0.2.*' 'addr=198.51.100.1,host=client' allow; then exit 1; fi
_security_user_in_list admin 'admin@192.0.2.0/24' 'addr=192.0.2.1,host=client' deny
firewall_is_active() {{ return 1; }}
firewall_detect_backend() {{ echo none; }}
ss() {{ printf 'Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port\\ntcp LISTEN 0 128 *:8080 *:*\\ntcp LISTEN 0 128 [::]:8081 *:*\\n'; }}
sudo() {{ return 1; }}
security_audit_listening_ports '' '' yes public 22
''', plain_env)
    check("8080" in proc.stdout and "8081" in proc.stdout, "wildcard/IPv6 listener disappeared")

    # Exercise the real admin guard with a valid key and simulated account data.
    admin_home = base / "admin-home"
    (admin_home / ".ssh").mkdir(parents=True)
    key = base / "test-key"
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
    shutil.copyfile(str(key) + ".pub", admin_home / ".ssh/authorized_keys")
    account_stubs = f'''
id() {{ if [[ "${{1:-}}" == -Gn ]]; then echo 'admin wheel'; elif [[ "${{1:-}}" == -u ]]; then echo 1000; else return 0; fi; }}
getent() {{ if [[ "$1" == passwd ]]; then echo 'admin:x:1000:1000::{admin_home}:/bin/bash'; fi; }}
sudo() {{ return 0; }}
_security_owner_of() {{ echo admin; }}
'''
    run(f'''
source "{ROOT}/lib/security.sh"
{account_stubs}
scenario=valid
sshd() {{
    echo 'authorizedkeysfile .ssh/missing .ssh/authorized_keys'
    echo 'allowusers other'
    echo 'allowusers admin'
    if [[ "$scenario" == pubkey ]]; then echo 'pubkeyauthentication no'; else echo 'pubkeyauthentication yes'; fi
    if [[ "$scenario" == methods ]]; then echo 'authenticationmethods publickey,password'; else echo 'authenticationmethods any'; fi
    if [[ "$scenario" == deny ]]; then printf 'denyusers other\\ndenyusers admin\\n'; fi
}}
security_verify_admin_user admin
for scenario in deny pubkey methods; do
    if security_verify_admin_user admin; then echo "guard accepted $scenario" >&2; exit 1; fi
done
sshd() {{ return 1; }}
sudo() {{ [[ "$1" == -n && "${{2:-}}" == -l ]]; }}
if security_verify_admin_user admin; then echo 'guard accepted failed effective query' >&2; exit 1; fi
''', plain_env)
    check(True, "admin guard lists/authentication/query failures")

    # On hosts with a usable sshd, resolve a real Match User candidate as well.
    real_sshd = shutil.which("sshd")
    if real_sshd:
        candidate = base / "match-candidate"
        candidate.write_text(f"HostKey {key}\nPubkeyAuthentication yes\nPasswordAuthentication no\nMatch User admin\n  PubkeyAuthentication no\n")
        probe = subprocess.run([real_sshd, "-T", "-f", str(candidate), "-C", "user=admin,addr=127.0.0.1,host=localhost"], capture_output=True, text=True)
        if probe.returncode == 0:
            run(f'''
source "{ROOT}/lib/security.sh"
{account_stubs}
sshd() {{ "{real_sshd}" "$@"; }}
if security_verify_admin_user admin "{candidate}" 'user=admin,addr=127.0.0.1,host=localhost'; then
    echo 'guard accepted real Match User denial' >&2; exit 1
fi
''', plain_env)
            check("pubkeyauthentication no" in probe.stdout, "real sshd did not resolve Match denial")
        else:
            print("SKIP real sshd Match check: temporary config query unavailable")

    # Update functions must propagate failures, including when invoked in an if.
    updater = base / "update.sh"
    text = (ROOT / "update.sh").read_text().rsplit('main "$@"', 1)[0]
    text = text.replace('SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"', f'SCRIPT_DIR="{ROOT}"')
    updater.write_text(text)
    run(f'''
source "{updater}"
is_macos() {{ return 1; }}
pkg_update() {{ echo 'expected update failure' >&2; return 42; }}
uv() {{ return 42; }}
for fn in update_shell update_tmux update_git update_tools update_uv update_neovim update_ssh; do
    if "$fn"; then echo "$fn swallowed failure" >&2; exit 1; fi
done
''', plain_env)
    check(True, "update failure propagation")

    # The real uninstaller must preserve nvm under --yes/--force; removal is opt-in.
    for flag in ["--yes", "--force", "--yes --remove-node-data"]:
        home = base / ("node-" + flag.replace(" ", "_"))
        (home / ".nvm/versions/node/v24.0.0").mkdir(parents=True)
        (home / ".nvm/nvm.sh").write_text("nvm() { :; }\n")
        env = dict(plain_env, HOME=str(home), NVM_DIR=str(home / ".nvm"), RIG_CONFIG_FILE=str(home / "config"))
        run(f'"{BASH}" "{ROOT}/uninstall.sh" --components node {flag}', env)
        check((home / ".nvm").exists() == ("--remove-node-data" not in flag), "nvm data preservation failed")

    # Real JSON exporter round-trips quotes, Unicode, backslashes, and control bytes.
    name = '测试 "A" \\path\nB\tC\rD\bE\x01F'
    cfg = base / "gitconfig"
    subprocess.run(["git", "config", "--file", str(cfg), "user.name", name], check=True)
    env = dict(plain_env, GIT_CONFIG_GLOBAL=str(cfg), RIG_CONFIG_FILE=str(base / "empty-config"))
    proc = run(f'"{BASH}" "{ROOT}/export-config.sh" --json', env)
    check(json.loads(proc.stdout)["config"]["git"]["user_name"] == name, "export JSON escaping changed data")

    # Remote import failure must be nonzero and must occur before config writes.
    work, env = fixture(base, "remote-import")
    shutil.copyfile(ROOT / "import-config.sh", work / "import-config.sh")
    (work / "input.json").write_text('{"components":["shell"],"config":{"system":{}}}')
    proc = run(f'"{BASH}" "{work}/import-config.sh" "{work}/input.json" --yes', env, ok=False)
    check(proc.returncode != 0, "remote import download failure reported success")
    check(not (work / "home/config").exists(), "failed import changed config")

print(f"audit regression tests passed ({CHECKS} assertions)")
