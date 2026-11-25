#!/usr/bin/env python3
"""Exercise a release arm64 APK on a dedicated Android emulator over adb.

Uses only fixture credentials and a loopback FreeRDP sample server. Never clears
app data. Leaves two named fixture hosts for inspecting restart persistence.
An emulator with arm64 support (native or translation) must already be running.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

app = Path(__file__).resolve().parents[1]
evidence = app.parents[1] / 'docs/verification/flutter-spike'
parser = argparse.ArgumentParser()
parser.add_argument('--serial', default='emulator-5580')
args = parser.parse_args()
adb_path = Path(os.environ.get('ANDROID_HOME', str(Path.home() / 'Android/Sdk'))) / 'platform-tools/adb'

def adb(*values, binary=False):
    return subprocess.check_output([str(adb_path), '-s', args.serial, *values], text=not binary, timeout=30)

def tree():
    adb('shell', 'uiautomator', 'dump', '/sdcard/salp-window.xml')
    return ET.fromstring(adb('shell', 'cat', '/sdcard/salp-window.xml'))

def label(node):
    return node.get('content-desc') or node.get('text') or ''

def wait_node(predicate, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = tree()
        node = next((n for n in current.iter('node') if predicate(n)), None)
        if node is not None:
            return node
    raise AssertionError('Expected Android UI state not reached: ' + ET.tostring(current, encoding='unicode')[:5000])

def tap_node(node):
    x0, y0, x1, y1 = map(int, re.findall(r'\d+', node.get('bounds')))
    adb('shell', 'input', 'tap', str((x0 + x1)//2), str((y0 + y1)//2))

def tap(text):
    tap_node(wait_node(lambda n: label(n) == text))

def fill(hint, value):
    node = wait_node(lambda n: n.get('class') == 'android.widget.EditText' and n.get('hint') == hint)
    tap_node(node)
    adb('shell', 'input', 'keyevent', '123', *(['67'] * 160))  # End, then clear fixture text
    if value:
        adb('shell', 'input', 'text', value)
    # Hardware keyboard mode may have no IME; Escape would dismiss the dialog.
    state = adb('shell', 'dumpsys', 'input_method')
    if 'mInputShown=true' in state or 'isInputViewShown=true' in state:
        adb('shell', 'input', 'keyevent', '4')

def screenshot(name):
    (evidence / name).write_bytes(adb('exec-out', 'screencap', '-p', binary=True))

def restart():
    adb('shell', 'am', 'force-stop', 'dev.salp.salp')
    adb('shell', 'am', 'start', '-n', 'dev.salp.salp/.MainActivity')
    wait_node(lambda n: '连接到你的工作现场' in label(n))

def open_editor(name):
    tap('主机列表')
    current = tree()
    host = next((n for n in current.iter('node') if (label(n).startswith(name + '\n') or (name=='AndroidPersistenceFixture' and label(n).startswith('AndroidPersist')))), None)
    if host is None:
        # Header add button; footer may scroll off short devices.
        tap('新建主机')
    else:
        operation = next(n for n in host.iter('node') if label(n) == '主机操作')
        tap_node(operation)
        tap('编辑')
    wait_node(lambda n: n.get('hint') == '名称')

def close_drawer():
    size = list(map(int,re.findall(r'\d+',adb('shell','wm','size'))))[-2:]
    adb('shell','input','tap',str(size[0]-10),str(size[1]//2))

def save():
    # Hide software keyboard first; labels remain accessible in the form.
    tap('保存主机')
    wait_node(lambda n: label(n).startswith('主机  '))
    close_drawer()

assert adb('shell', 'getprop', 'ro.kernel.qemu').strip() == '1', 'Use a dedicated emulator, not a personal device'
apk = app / 'build/app/outputs/flutter-apk/app-release.apk'
adb('install', '-r', str(apk))
report = {
    'captured_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'serial': args.serial,
    'abis': adb('shell', 'getprop', 'ro.product.cpu.abilist').strip(),
    'apk_sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
    'scope': 'Android emulator; arm64 translation is not physical arm64 evidence',
}
with tempfile.TemporaryDirectory(prefix='salp-android-rdp-') as temporary:
    folder = Path(temporary)
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(folder/'key.pem'),'-out',str(folder/'cert.pem'),'-days','1','-subj','/CN=salp-fixture.invalid'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    fingerprint = subprocess.check_output(['openssl','x509','-in',str(folder/'cert.pem'),'-noout','-fingerprint','-sha256'],text=True).strip().split('=')[1].lower()
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen()
    port=listener.getsockname()[1]
    unix=Path(f'/tmp/tfreerdp-server.{port}')
    log=(folder/'server.log').open('w+')
    env=os.environ.copy();env['WLOG_LEVEL']='DEBUG'
    server=subprocess.Popen(['stdbuf','-oL','-eL','sfreerdp-server3','--local-only',f'--port={port}',f'--cert={folder}/cert.pem',f'--key={folder}/key.pem'],stdout=log,stderr=log,env=env)
    stop=threading.Event()
    def pump(client):
        peer=socket.socket(socket.AF_UNIX)
        try:
            peer.connect(str(unix))
            while not stop.is_set():
                readers,_,_=select.select([client,peer],[],[],.5)
                for source in readers:
                    data=source.recv(65536)
                    if not data:return
                    (peer if source is client else client).sendall(data)
        except OSError:pass
        finally:client.close();peer.close()
    def accept():
        while not stop.is_set():
            try:client,_=listener.accept()
            except OSError:return
            threading.Thread(target=pump,args=(client,),daemon=True).start()
    try:
        deadline=time.monotonic()+10
        while not unix.exists() and time.monotonic()<deadline:time.sleep(.05)
        assert unix.exists(), 'RDP sample server failed to start'
        threading.Thread(target=accept,daemon=True).start()
        print('Checking credential persistence',flush=True)
        restart()
        open_editor('AndroidPersistenceFixture')
        fill('名称','AndroidPersistenceFixture')
        fill('地址','192.0.2.1')
        fill('密码','fixture-only-not-real-secret')
        save()
        restart()
        open_editor('AndroidPersistenceFixture')
        wait_node(lambda n:n.get('hint')=='地址' and n.get('text')=='192.0.2.1')
        password=wait_node(lambda n:n.get('hint')=='密码')
        assert password.get('password')=='true' and password.get('text'), 'Saved fixture credential missing after process restart'
        tap('取消')
        # Close drawer before the next open_editor.
        close_drawer()
        report['secure_storage_restart_masked_credential']=True
        print('Credential persisted after force-stop/restart',flush=True)
        print('Checking RDP certificate and input',flush=True)
        open_editor('AndroidRdpVerification')
        fill('名称','AndroidRdpVerification')
        # Protocol menu is selected by label, no hard-coded device coordinates.
        protocol=next(n for n in tree().iter('node') if n.get('class')=='android.widget.Button' and label(n) in ('协议\nSSH','协议\nRDP'))
        if label(protocol)!='协议\nRDP':
            tap_node(protocol);tap('RDP')
        fill('地址','10.0.2.2')
        fill('端口',str(port))
        fill('用户名','fixture')
        save()
        tap('主机列表')
        tap('AndroidRdpVerification\nfixture@10.0.2.2')
        cert=wait_node(lambda n:fingerprint in label(n).lower())
        report['certificate_fingerprint_matches_fixture']=True
        tap('确认')
        close_drawer()
        wait_node(lambda n:'RDP · TLS' in label(n) and '1280×720' in label(n))
        screenshot('android-rdp-after.png')
        tap('显示键盘')
        wait_node(lambda n:label(n)=='隐藏键盘')
        adb('shell','input','text','salp')
        tap('Ctrl-C')
        # Touch the remote framebuffer (centre of the view above the IME).
        upper=wait_node(lambda n:label(n)=='隐藏键盘')
        lower=wait_node(lambda n:label(n)=='Esc')
        upper_bounds=list(map(int,re.findall(r'\d+',upper.get('bounds'))))
        lower_bounds=list(map(int,re.findall(r'\d+',lower.get('bounds'))))
        size=list(map(int,re.findall(r'\d+',adb('shell','wm','size'))))[-2:]
        adb('shell','input','tap',str(size[0]//2),str((upper_bounds[3]+lower_bounds[1])//2))
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            log.flush();log.seek(0);events=log.read().lower()
            if 'code:0x0070' in events and 'code:0x002e' in events and 'mouse event' in events:break
            time.sleep(.05)
        assert 'code:0x0073' in events and 'code:0x0061' in events and 'code:0x006c' in events and 'code:0x0070' in events, 'Text did not reach real RDP peer'
        assert 'keyboard event (flags:0x0000 code:0x002e)' in events, 'Ctrl-C did not reach peer'
        assert 'mouse event' in events, 'Touch did not reach peer'
        report.update(rdp_framebuffer=[1280,720],rdp_native_keyboard=True,rdp_shortcut=True,rdp_touch=True)
        screenshot('android-rdp-keyboard.png')
        tap('关闭会话')
        restart()
        report['process_death_discards_active_sessions']=True
        (evidence/'android-runtime.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(report,ensure_ascii=False,indent=2))
    except Exception:
        screenshot('android-runtime-failure.png')
        raise
    finally:
        stop.set();listener.close();server.terminate()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:server.kill();server.wait()
        log.close()
