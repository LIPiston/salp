#!/usr/bin/env python3
"""Ephemeral loopback OpenSSH fixture; never touches the user's SSH config."""
import subprocess, tempfile, pathlib, socket, os, json, time, getpass, sys
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='salp-ssh-') as tmp:
    folder=pathlib.Path(tmp)
    for name in ('host_key','client_key'):
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(folder/name)],check=True)
    (folder/'authorized_keys').write_text((folder/'client_key.pub').read_text())
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
    fingerprint=subprocess.check_output(['ssh-keygen','-lf',str(folder/'host_key.pub')],text=True).split()[1]
    (folder/'public.json').write_text(json.dumps({'port':port,'username':getpass.getuser(),'fingerprint':fingerprint}))
    (folder/'sshd_config').write_text(f'''ListenAddress 127.0.0.1
Port {port}
HostKey {folder}/host_key
PidFile {folder}/sshd.pid
AuthorizedKeysFile {folder}/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowTcpForwarding yes
PermitRootLogin no
Subsystem sftp internal-sftp
LogLevel ERROR
''')
    log=(folder/'sshd.log').open('w+')
    daemon=subprocess.Popen(['/usr/bin/sshd','-D','-e','-f',str(folder/'sshd_config')],stdout=log,stderr=log)
    agent=subprocess.Popen(['ssh-agent','-D','-a',str(folder/'agent.sock')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if (folder/'agent.sock').exists():break
            time.sleep(.02)
        agent_env=os.environ.copy();agent_env['SSH_AUTH_SOCK']=str(folder/'agent.sock')
        subprocess.run(['ssh-add',str(folder/'client_key')],env=agent_env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for _ in range(100):
            if daemon.poll() is not None:
                log.seek(0);raise RuntimeError(log.read())
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.1):break
            except OSError:time.sleep(.05)
        env=agent_env.copy();env['SALP_SSH_FIXTURE']=tmp
        tests = sys.argv[1:] or ['test/ssh_integration_test.dart', 'test/sftp_picker_test.dart', 'test/mcp_operations_test.dart']
        result=subprocess.run([sys.executable,str(root/'tool/run.py'),'flutter','test','--no-pub',*tests],env=env)
    finally:
        agent.terminate();agent.wait(timeout=5)
        daemon.terminate()
        try:daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:daemon.kill();daemon.wait()
        log.close()
    raise SystemExit(result.returncode)
