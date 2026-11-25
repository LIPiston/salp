#!/usr/bin/env python3
"""Build/run arm64 SAF fixture; restore the normal release APK in finally."""
import argparse, datetime, hashlib, json, pathlib, re, subprocess, time, uuid, xml.etree.ElementTree as ET
app=pathlib.Path(__file__).resolve().parents[1]
evidence=app.parents[1]/'docs/verification/flutter-spike'
parser=argparse.ArgumentParser();parser.add_argument('--serial',default='emulator-5580');args=parser.parse_args()
adb_path=pathlib.Path.home()/'Android/Sdk/platform-tools/adb'
run=uuid.uuid4().hex[:10];folder='salp-saf-'+run;path='/sdcard/Download/'+folder

def adb(*values,binary=False):
 return subprocess.check_output([str(adb_path),'-s',args.serial,*values],text=not binary,timeout=30)
def tree():
 adb('shell','uiautomator','dump','/sdcard/salp-window.xml')
 return ET.fromstring(adb('shell','cat','/sdcard/salp-window.xml'))
def tap(label):
 deadline=time.monotonic()+15
 while time.monotonic()<deadline:
  node=next((n for n in tree().iter('node') if n.get('text')==label or n.get('content-desc')==label),None)
  if node is not None:
   x0,y0,x1,y1=map(int,re.findall(r'\d+',node.get('bounds')))
   adb('shell','input','tap',str((x0+x1)//2),str((y0+y1)//2));return
 raise AssertionError('Missing Android picker label: '+label)
def wait_log(marker):
 deadline=time.monotonic()+30
 while time.monotonic()<deadline:
  log=adb('logcat','-d','-s','flutter:I','*:S')
  if marker in log:return log
  if 'Test failed.' in log:raise AssertionError(log)
  time.sleep(.2)
 raise AssertionError('Missing test marker '+marker+'\n'+log)
def launch():
 adb('shell','am','force-stop','dev.salp.salp')
 adb('logcat','-c')
 adb('shell','am','start','-n','dev.salp.salp/.MainActivity')
def build(*extra):
 subprocess.run(['python3',str(app/'tool/run.py'),'flutter','build','apk','--release','--target-platform','android-arm64',*extra],check=True)

assert adb('shell','getprop','ro.kernel.qemu').strip()=='1','Use a dedicated emulator'
report={'captured_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'serial':args.serial,'scope':'Android36 DocumentsUI / ExternalStorageProvider, arm64 APK translated on x86_64'}
try:
 build('-t','integration_test/android_documents_test.dart',f'--dart-define=SALP_SAF_RUN={run}')
 apk=app/'build/app/outputs/flutter-apk/app-release.apk'
 report['fixture_apk_sha256']=hashlib.sha256(apk.read_bytes()).hexdigest()
 adb('install','-r',str(apk));adb('shell','mkdir','-p',path);launch()
 wait_log('SALP_SAF_PICK_DIRECTORY')
 tap('Download');tap(folder);tap('USE THIS FOLDER');tap('ALLOW')
 phase1=wait_log('SALP_SAF_READY_TO_KILL')
 data=adb('exec-out','cat',path+'/complete.bin',binary=True)
 assert data==bytes(i%251 for i in range(150000)), 'SAF stream bytes differ'
 names=adb('shell','ls','-a',path).splitlines()
 assert 'aborted.bin' not in names and 'interrupted.bin' not in names, 'Partial file exposed as final'
 copies=[n for n in names if n.startswith('complete.bin.copy-')]
 assert len(copies)==1 and adb('exec-out','cat',path+'/'+copies[0],binary=True)==bytes([9,8,7])
 assert len([n for n in names if n.startswith('.salp-') and n.endswith('.part')])==1
 launch()  # Force-stop skips Activity.onDestroy.
 phase2=wait_log('SALP_SAF_RECOVERY_PASSED')
 names=adb('shell','ls','-a',path).splitlines()
 assert set(names)-{'.','..'}=={'complete.bin',copies[0],'contended.bin'}, names
 assert adb('exec-out','cat',path+'/complete.bin',binary=True)==data
 assert adb('exec-out','cat',path+'/contended.bin',binary=True)==bytes([42])
 report.update(late_conflict_preserves_winner=True,stream_exact_bytes=150000,conflict_preserves_original=True,keep_both=True,abort_cleanup=True,process_death_partial_cleanup=True,completed_file_survives_recovery=True)
 (evidence/'android-saf.json').write_text(json.dumps(report,indent=2)+'\n')
 (evidence/'android-saf-events.log').write_text(phase1+'\n'+phase2)
 print(json.dumps(report,indent=2),flush=True)
 # Only this script's uniquely named fixture directory, never user-selected data.
 adb('shell','rm','-rf',path)
finally:
 adb('shell','am','force-stop','dev.salp.salp')
 build('-t','lib/main.dart')
 adb('install','-r',str(app/'build/app/outputs/flutter-apk/app-release.apk'))
