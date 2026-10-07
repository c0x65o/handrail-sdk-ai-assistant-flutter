from pathlib import Path
import json, hashlib, shutil, sys
r=Path.cwd(); ev=r/'docs/qa/widget-compatibility-review-2026-10-07'
label=sys.argv[1]; v=json.loads((ev/(label+'.json')).read_text()); t=Path(v['temp'])
for name in ['handrail_ai_widgets','handrail_ai_client']:
 src=r/'packages'/name/'lib'; dst=t/'packages'/name/'lib'
 hashes=lambda root:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
 assert hashes(src)==hashes(dst)
b=t/'packages/handrail_ai_widgets/build'; size=sum(p.stat().st_size for p in b.rglob('*') if p.is_file())
if b.exists(): shutil.rmtree(b)
(ev/(label+'-compiler-custody.json')).write_text(json.dumps({'bothLibCopiesMatch':True,'deletedOnlyOwnedGeneratedBuild':str(b),'bytes':size},indent=2)+'\n')
print(label, 'PASS: both compiler library copies match final source')
