"""Collect original notices for the executable's actual Cabal dependency closure."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tarfile

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=pathlib.Path)
parser.add_argument('--plan', type=pathlib.Path, default=root/'.work/release-build/cache/plan.json')
parser.add_argument('--cache', type=pathlib.Path)
parser.add_argument('--ghc-libdir', type=pathlib.Path)
args = parser.parse_args()
destination = args.destination.resolve()
destination.mkdir(parents=True, exist_ok=True)

def command(*arguments):
    return subprocess.check_output(arguments, encoding='utf8').strip()

cache = args.cache or pathlib.Path(json.loads(command('cabal','path','--output-format=json'))['remote-repo-cache'])
ghc_libdir = args.ghc_libdir or pathlib.Path(command('ghc','--print-libdir'))
plan = json.loads(args.plan.read_text(encoding='utf8'))
units = {unit['id']:unit for unit in plan['install-plan']}
targets = [unit['id'] for unit in units.values() if unit['pkg-name']=='aya' and unit.get('component-name')=='exe:aya']
if len(targets)!=1:
    raise SystemExit('Expected exactly one aya executable in the selected plan')
closure = set()
pending = targets[:]
while pending:
    unit_id = pending.pop()
    if unit_id in closure:
        continue
    closure.add(unit_id)
    pending.extend(units[unit_id].get('depends',[]))
packages = {(units[unit]['pkg-name'],units[unit]['pkg-version']) for unit in closure if units[unit]['pkg-name'] not in {'aya','aya-audio'}}

def digest(content):
    return hashlib.sha256(content).hexdigest()

def record_file(relative,content):
    target = destination/relative
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_bytes(content)
    return {'path':pathlib.PurePosixPath(relative).as_posix(),'sha256':digest(content)}

def notice_name(name):
    return pathlib.PurePosixPath(name).name.upper().startswith(('LICENSE','LICENCE','COPYING','COPYRIGHT','NOTICE'))

manifest = []
for name,version in sorted(packages):
    prefix = pathlib.PurePosixPath('haskell')/f'{name}-{version}'
    archives = sorted(cache.glob(f'*/{name}/{version}/{name}-{version}.tar.gz'))
    files=[]
    if archives:
        archive=archives[0]
        with tarfile.open(archive,'r:gz') as package:
            cabal_member=next((entry for entry in package.getmembers() if entry.isfile() and entry.name.endswith(f'/{name}.cabal')),None)
            if cabal_member is None:
                raise SystemExit(f'No package metadata for {name}-{version}')
            cabal_text=package.extractfile(cabal_member).read().decode('utf8')
            field=re.search(r'^license\s*:\s*(.+)$',cabal_text,re.MULTILINE|re.IGNORECASE)
            declared=field.group(1).strip() if field else 'UNDECLARED'
            for member in package.getmembers():
                if not member.isfile() or not notice_name(member.name):
                    continue
                relative=pathlib.PurePosixPath(member.name)
                if relative.is_absolute() or '..' in relative.parts:
                    raise SystemExit('Unsafe notice path in source archive')
                relative=pathlib.PurePosixPath(*relative.parts[1:])
                files.append(record_file(prefix/relative,package.extractfile(member).read()))
        source=f'https://hackage.haskell.org/package/{name}-{version}/{name}-{version}.tar.gz'
        source_hash=digest(archive.read_bytes())
        expected={unit.get('pkg-src-sha256') for unit in units.values()
                  if unit['pkg-name']==name and unit['pkg-version']==version and unit.get('pkg-src-sha256')}
        if expected and source_hash not in expected:
            raise SystemExit(f'Cached source archive does not match the built plan: {name}-{version}')
    else:
        declared=command('ghc-pkg','field',f'{name}-{version}','license','--simple-output')
        bundled=sorted((ghc_libdir/'doc').glob(f'*/{name}-{version}/LICENSE*'))
        for license_file in bundled:
            files.append(record_file(prefix/license_file.name,license_file.read_bytes()))
        if name=='rts' and not files:
            files.append(record_file(prefix/'GHC-LICENSE',(root/'licenses/GHC-LICENSE').read_bytes()))
        source='https://downloads.haskell.org/ghc/9.14.1/ghc-9.14.1-src.tar.xz'
        source_hash=None
    if not files:
        raise SystemExit(f'No original license text found for {name}-{version}')
    manifest.append({'package':name,'version':version,'declaredLicense':declared,'source':source,'sourceSha256':source_hash,'notices':files})

runtime_files=[]
for license_file in sorted((root/'licenses').glob('*')):
    if license_file.is_file():
        runtime_files.append(record_file(pathlib.PurePosixPath('runtime')/license_file.name,license_file.read_bytes()))
lock=json.loads((root/'third-party/runtime-lock.json').read_text(encoding='utf8'))
record={'schemaVersion':1,'target':'aya executable','compiler':plan.get('compiler-id'),
        'haskellPackages':manifest,'runtimeNotices':runtime_files,'replaceableGmp':lock['gmp']}
(destination/'manifest.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf8')
lines=['Notices for the dependency closure of the Aya executable.','',
       'The manifest records the package declarations and the exact original notice files; it is not a relicensing of dependencies.',
       'GMP is distributed as a replaceable DLL under LGPL-3.0-or-later, with its complete corresponding MSYS2 source archive.',
       'See THIRD-PARTY.md and third-party/GMP-REPLACEMENT.md in the application folder.','']
lines.extend(f"{item['package']}-{item['version']}: {item['declaredLicense']}" for item in manifest)
(destination/'DEPENDENCIES.txt').write_text('\n'.join(lines)+'\n',encoding='utf8')
print(f'Collected original notices for {len(manifest)} linked Haskell packages and {len(runtime_files)} runtime files')
