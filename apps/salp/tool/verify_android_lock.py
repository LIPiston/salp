#!/usr/bin/env python3
"""Android file picker/background/screen lock integration. Restores main APK."""
import argparse,subprocess,time,pathlib,json,datetime
app=pathlib.Path(__file__).resolve().parents[1];evidence=app.parents[1]/'docs/verification/flutter-spike'
parser=argparse.ArgumentParser();parser.add_argument('--serial',default='emulator-5580');args=parser.parse_args()
ADB=str(pathlib.Path.home()/'Android/Sdk/platform-tools/adb')
def adb(*values):return subprocess.check_output([ADB,'-s',args.serial,*values],text=True,timeout=30)
def wait(marker):
 deadline=time.monotonic()+30
 while time.monotonic()<deadline:
  log=adb('logcat','-d','-s','flutter:I','*:S')
  if marker in log:return log
  if 'Test failed.' in log:raise AssertionError(log)
  time.sleep(.2)
 raise AssertionError('Missing marker '+marker+'\n'+log)
def build(target):subprocess.run(['python3',str(app/'tool/run.py'),'flutter','build','apk','--release','--target-platform','android-arm64','-t',target],check=True)
def install():adb('install','-r',str(app/'build/app/outputs/flutter-apk/app-release.apk'))
assert adb('shell','getprop','ro.kernel.qemu').strip()=='1'
try:
 build('integration_test/android_picker_lock_test.dart');install()
 adb('shell','am','force-stop','com.google.android.documentsui');adb('shell','am','force-stop','dev.salp.salp');adb('logcat','-c');adb('shell','am','start','-n','dev.salp.salp/.MainActivity')
 wait('SALP_PICKER_AWAIT_CANCEL');time.sleep(1);adb('shell','input','keyevent','4')
 wait('SALP_PICKER_AWAIT_SCREEN_LOCK');adb('shell','input','keyevent','223')
 wait('SALP_PICKER_SCREEN_LOCKED');adb('shell','input','keyevent','224');adb('shell','wm','dismiss-keyguard');adb('shell','input','keyevent','4')
 log=wait('SALP_PICKER_LOCK_PASSED');(evidence/'android-picker-lock-events.log').write_text(log)
 result={'captured_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'serial':args.serial,'picker_preserves_editor_with_master_password':True,'screen_off_locks':True,'system_unlock_requires_app_password':True}
 (evidence/'android-picker-lock.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
finally:
 adb('shell','input','keyevent','224');adb('shell','wm','dismiss-keyguard');adb('shell','am','force-stop','dev.salp.salp');build('lib/main.dart');install()
