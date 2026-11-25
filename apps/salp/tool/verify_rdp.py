#!/usr/bin/env python3
"""Loopback FreeRDP sample server: real TLS/certificate/framebuffer lifecycle."""
import ctypes, pathlib, subprocess, tempfile, socket, time, os, json, threading, select
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='salp-rdp-') as tmp:
    folder = pathlib.Path(tmp)
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(folder/'key.pem'), '-out', str(folder/'cert.pem'), '-days', '1', '-subj', '/CN=salp-fixture.invalid'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # The sample server's --local-only means a Unix socket. Proxy only from
    # loopback so this test never exposes its unauthenticated desktop on LAN.
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen()
    port=listener.getsockname()[1]
    env=os.environ.copy();env['WLOG_LEVEL']='DEBUG'
    log=(folder/'server.log').open('w+')
    server=subprocess.Popen(['stdbuf','-oL','-eL','sfreerdp-server3','--local-only',f'--port={port}',f'--cert={folder}/cert.pem',f'--key={folder}/key.pem'],stdout=log,stderr=log,env=env)
    unix=pathlib.Path(f'/tmp/tfreerdp-server.{port}')
    deadline=time.monotonic()+10
    while not unix.exists() and time.monotonic()<deadline: time.sleep(.05)
    if not unix.exists():
        server.terminate();server.wait(timeout=5);listener.close()
        raise RuntimeError('RDP fixture Unix socket did not start')
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
            try: client,_=listener.accept()
            except OSError:return
            threading.Thread(target=pump,args=(client,),daemon=True).start()
    threading.Thread(target=accept,daemon=True).start()
    os.environ['XDG_CONFIG_HOME']=str(folder/'config')
    bridge=ctypes.CDLL(str(root/'build/native-rdp/libsalp_rdp.so'))
    bridge.salp_rdp_start.restype=ctypes.c_void_p
    bridge.salp_rdp_start.argtypes=[ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int,ctypes.c_int]
    for name in ['salp_rdp_state','salp_rdp_error','salp_rdp_stop','salp_rdp_free']:
        getattr(bridge,name).argtypes=[ctypes.c_void_p]
    bridge.salp_rdp_certificate.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_int]
    bridge.salp_rdp_trust.argtypes=[ctypes.c_void_p,ctypes.c_int]
    bridge.salp_rdp_frame.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int,ctypes.POINTER(ctypes.c_int),ctypes.POINTER(ctypes.c_int)]
    bridge.salp_rdp_lock.argtypes=[ctypes.c_void_p,ctypes.c_int]
    bridge.salp_rdp_input.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_int]
    handle=None
    try:
        for _ in range(100):
            if server.poll() is not None:raise RuntimeError('Sample RDP server exited')
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.1):break
            except OSError:time.sleep(.05)
        handle=bridge.salp_rdp_start(b'127.0.0.1',port,b'fixture',b'fixture-password',b'',b'salp-fixture.invalid',str(folder/'client-config').encode(),800,600)
        assert handle
        deadline=time.monotonic()+25
        cert_seen=False;frame_seen=False
        width=ctypes.c_int();height=ctypes.c_int()
        while time.monotonic()<deadline:
            state=bridge.salp_rdp_state(handle)
            if state==2:
                buf=ctypes.create_string_buffer(16385)
                assert bridge.salp_rdp_certificate(handle,buf,16385)>0
                cert_seen=True;bridge.salp_rdp_trust(handle,1)
            elif state==1:
                size=bridge.salp_rdp_frame(handle,None,0,ctypes.byref(width),ctypes.byref(height))
                if size<0:
                    pixels=ctypes.create_string_buffer(-size)
                    assert bridge.salp_rdp_frame(handle,pixels,-size,ctypes.byref(width),ctypes.byref(height))>0
                    frame_seen=True;break
            elif state in (-1,3):
                raise RuntimeError(f'RDP failed: state={state}, code={bridge.salp_rdp_error(handle):x}')
            time.sleep(.02)
        assert cert_seen, 'No explicit certificate prompt observed'
        assert frame_seen, 'No actual RDP framebuffer observed'
        assert width.value==800 and height.value==600
        assert bridge.salp_rdp_input(handle,0,0x800,10,10)==1
        bridge.salp_rdp_lock(handle,1)
        assert bridge.salp_rdp_input(handle,0,0x800,10,10)==0
        assert bridge.salp_rdp_frame(handle,None,0,ctypes.byref(width),ctypes.byref(height))==0
        print(json.dumps({'certificate_prompt':True,'framebuffer':[width.value,height.value],'lock_blocks_input_and_frames':True}),flush=True)
        flutter_env=os.environ.copy()
        flutter_env['SALP_RDP_PORT']=str(port)
        flutter_env['LD_LIBRARY_PATH']=str(root/'build/native-rdp')
        subprocess.run(['python3',str(root/'tool/run.py'),'flutter','test','--no-pub','test/rdp_integration_test.dart'],env=flutter_env,check=True)
        subprocess.run(['python3',str(root/'tool/verify_ssh.py'),'test/rdp_integration_test.dart'],env=flutter_env,check=True)
        print(json.dumps({'rdp_openssh_jump_frame_certificate_input':True}),flush=True)
        log.flush();log.seek(0);events=log.read().lower()
        assert 'code:0x002e' in events, 'Ctrl-C was not sent as a physical C key'
        assert 'code:0xd83d' in events and 'code:0xde00' in events, 'Supplementary Unicode was lost'
        print(json.dumps({'rdp_shortcut_scan_code':True,'rdp_unicode_surrogates':True}),flush=True)
    except Exception:
        log.flush();log.seek(0);print(log.read()[-8000:]);raise
    finally:
        if handle:
            bridge.salp_rdp_stop(handle)
            deadline=time.monotonic()+10
            while bridge.salp_rdp_state(handle) not in (-1,3) and time.monotonic()<deadline:time.sleep(.05)
            if bridge.salp_rdp_state(handle) in (-1,3):bridge.salp_rdp_free(handle)
        stop.set();listener.close()
        server.terminate()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:server.kill();server.wait()
        log.close()
