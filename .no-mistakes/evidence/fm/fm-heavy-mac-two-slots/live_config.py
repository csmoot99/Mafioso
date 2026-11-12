import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path.cwd()
lab = root / '.test-validation/config-home'
(lab/'config').mkdir(parents=True)
env = dict(os.environ, FM_HOME=str(lab), FM_ROOT_OVERRIDE=str(lab),
           FM_STATE_OVERRIDE=str(lab/'state'), FM_DATA_OVERRIDE=str(lab/'data'),
           FM_CONFIG_OVERRIDE=str(lab/'config'), FM_PROJECTS_OVERRIDE=str(lab/'projects'))
try:
    for setting in ('host-slots 0', 'host-slots 65', 'host-slots 01', 'host-slots -1',
                    'host-slots two', 'host-slots 2\nhost-slots 2'):
        (lab/'config/heavy-remote').write_text('host unused.invalid\nproject p\n'+setting+'\n')
        result = subprocess.run([str(root/'bin/fm-heavy.sh'), '--class','test','--task','live-config',
                                 '--project','p','--remote','--','true'], env=env,
                                capture_output=True, text=True, timeout=10)
        print(json.dumps(dict(setting=setting, exit=result.returncode,
                              stdout=result.stdout, stderr=result.stderr)), flush=True)
        assert result.returncode == 2
        assert 'malformed' in result.stderr
finally:
    shutil.rmtree(lab)
