#!/usr/bin/env python3
"""Capture a command's output, exit code and elapsed time without hiding failures."""
import subprocess,sys,time,json,datetime
from pathlib import Path
root=Path(__file__).resolve().parents[1]
evidence=root.parents[1]/'docs/verification/flutter-spike'
evidence.mkdir(parents=True,exist_ok=True)
name=sys.argv[1];command=sys.argv[2:]
started=datetime.datetime.now(datetime.timezone.utc).isoformat();timer=time.monotonic()
with (evidence/(name+'.log')).open('w') as log:
    log.write('COMMAND '+json.dumps(command)+'\n');log.flush()
    proc=subprocess.Popen(command,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    for line in proc.stdout:
        print(line,end='',flush=True);log.write(line);log.flush()
    code=proc.wait();elapsed=time.monotonic()-timer
    result={'started_at':started,'command':command,'exit_code':code,'seconds':round(elapsed,3)}
    log.write(json.dumps(result)+'\n');print(json.dumps(result))
(evidence/(name+'.json')).write_text(json.dumps(result,indent=2)+'\n')
raise SystemExit(code)
