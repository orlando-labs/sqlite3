#!/usr/bin/env python3
"""Prepare scoped, relocatable release inputs from sibling package checkouts.

Build outputs live below release/out (ignored). This never publishes implicitly.
"""
import argparse, copy, hashlib, json, os, re, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SDK_ROOT = Path(os.environ.get('SPUTNIK_ROOT', ROOT/'sputnik-lang')).resolve()
Q = lambda x: json.dumps(x, ensure_ascii=False)
MAPPING = {x: 'slowpilot.' + x for x in ['orbit', 'orm', 'sqlite3', 'plot', 'progressbar', 'pycall', 'rbcall', 'sdk', 'notebook.ui', 'audio']}
def scoped(name):
    if name in ['orm.sqlite3.adapter', 'orm.sqlite3.pool']:
        return 'slowpilot.'+name.rsplit('.',1)[0]+'._'+name.rsplit('.',1)[1]
    for prefix in sorted(MAPPING, key=len, reverse=True):
        if name == prefix or name.startswith(prefix + '.'):
            return MAPPING[prefix] + name[len(prefix):]
    return name

def rewrite(text):
    def line(m):
        indent, kind, name, tail = m.groups()
        # AudioCodec is a builtin, while source UI helpers live in our scope.
        if kind == 'from' and name == 'notebook.ui' and 'AudioCodec' in tail:
            return m.group(0)
        new = scoped(name)
        if kind == 'import' and new != name and not tail.strip():
            tail = ' as ' + name.rsplit('.', 1)[-1]
        return indent + kind + ' ' + new + tail
    text = re.sub(r'^(\s*)(package|from|import) ([\w.]+)([^\n]*)', line, text, flags=re.M)
    text = re.sub(r'(?m)(\bwhen )orm\.', r'\1slowpilot.orm.', text)
    text = re.sub(r'(?m)(^class [^\n<]+< )orm\.', r'\1slowpilot.orm.', text)
    for old in ['Sqlite3', 'Orm', 'Orbit', 'Plot', 'Pycall', 'Rbcall']:
        text = re.sub(r'(?<![\w.])'+old+r'\.', 'Slowpilot.'+old+'.', text)
    return text

def manifest(data):
    lines = ['schema = "sputnik.package-manifest.v1"']
    def table(name, obj, repeated=False):
        lines.append('\n' + ('[[' if repeated else '[') + name + (']]' if repeated else ']'))
        for k,v in obj.items():
            if isinstance(v,dict): continue
            if isinstance(v,list) and v and isinstance(v[0],dict): continue
            lines.append(Q(k) + ' = ' + Q(v))
        for k,v in obj.items():
            if isinstance(v,dict): table(name+'.'+k,v)
            elif isinstance(v,list) and v and isinstance(v[0],dict):
                for item in v: table(name+'.'+k,item,True)
    for name,obj in data.items():
        if isinstance(obj,list):
            for item in obj: table(name,item,True)
        else: table(name,obj)
    return '\n'.join(lines)+'\n'

def run(cmd,log):
    print('+', ' '.join(map(str,cmd)),flush=True)
    with log.open('w') as out:
        result = subprocess.run(list(map(str,cmd)), stdout=out, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text()[-10000:]); raise SystemExit(result.returncode)

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('config',type=Path)
p.add_argument('--sputnik',type=Path,default=SDK_ROOT/'build/sputnik')
p.add_argument('--out',type=Path,default=Path(__file__).resolve().parent/'out')
p.add_argument('--platform',choices=['macos-aarch64','linux-x86_64-gnu'],default='macos-aarch64')
p.add_argument('--native',choices=['source','prebuilt'],default='source')
p.add_argument('--modules',choices=['source','bytecode','mixed'],default='source')
a=p.parse_args(); config=a.config.resolve(); cfg=json.loads(config.read_text()); repo=config.parent.parent
native=cfg.get('native',[])
bundle=cfg.get('bundle','none')
if a.native=='prebuilt' and bundle=='sdk':bundle='runtime'
variant=(a.platform+'-'+a.native+'-' if native else '')+a.modules+('-'+bundle if bundle!='none' else '')
work=a.out.resolve()/cfg['name']/variant; stage=work/'stage'; stage.mkdir(parents=True,exist_ok=True)
data={'package':{'name':'slowpilot/'+cfg['name'],'version':cfg['version'],'root':scoped(cfg['root'])},'artifact':{'variant':variant},'target':{'os':'any','arch':'any'},'modules':[]}
seen=set()
for src in cfg['sources']:
    for file in sorted(repo.glob(src)):
        if file in seen: continue
        seen.add(file)
        if not file.is_file(): continue
        text=file.read_text(); name=re.search(r'^package ([\w.]+)',text,re.M).group(1)
        dest=stage/file.relative_to(repo); dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(rewrite(text))
        data['modules'].append({'name':scoped(name),'source':file.relative_to(repo).as_posix()})
if cfg.get('dependencies'):data['dependencies']={'slowpilot/'+k:v for k,v in cfg['dependencies'].items()}
if cfg.get('capabilities'):data['capabilities']=cfg['capabilities']
files=[]
for name in ['README.md','LICENSE','API.md']:
    if (repo/name).is_file():
        if name.endswith('.md'):(stage/name).write_text(rewrite((repo/name).read_text()))
        else:shutil.copy2(repo/name,stage/name)
        files.append(name)
if files:data['files']={'include':files}
for original,destination in cfg.get('assets',{}).items():
    shutil.copytree(original,stage/destination,dirs_exist_ok=True)
data['artifact']['bundle']=bundle
if cfg.get('native_providers'):data['native_providers']=copy.deepcopy(cfg['native_providers'])
if native:
    data['target']={'os':'macos','arch':'aarch64','min_os':'26.0'} if a.platform=='macos-aarch64' else {'os':'linux','arch':'x86_64','libc':'gnu','min_libc':'2.36'}
    data['native']=copy.deepcopy(native)
    if cfg.get('native_requirements'): data['native_requirements']=copy.deepcopy(cfg['native_requirements'])
    for ext in data['native']:
        for pattern in ext.get('sources',[])+ext.get('headers',[]):
            dest=stage/pattern;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(repo/pattern,dest)
    if a.native=='prebuilt':
        lib=stage/'lib'/('lib'+cfg['name']+('.dylib' if a.platform.startswith('macos') else '.so'));lib.parent.mkdir(exist_ok=True)
        shim=work/'abi.c';shim.write_text('#include "runtime/sputnik_ext.h"\n#if defined(__GNUC__)\n__attribute__((weak))\n#endif\nuint32_t sputnik_ext_abi_version(void) { return SPUTNIK_EXT_ABI_VERSION; }\n')
        objects=[]; compiler=os.environ.get('CXX','clang++' if a.platform.startswith('macos') else 'g++')
        for i,ext in enumerate(native):
            for j,src in enumerate(ext['sources']):
                obj=work/f'{i}-{j}.o';cmd=[compiler,'-x','c' if ext['language']=='c' else 'c++','-std=c11' if ext['language']=='c' else '-std=c++17','-O3','-fPIC','-I',SDK_ROOT]
                cmd+=['-D'+x for x in ext.get('defines',[])];cmd+=sum((['-I',x] for x in cfg.get('build_include_dirs',[])),[]);cmd+=['-c',repo/src,'-o',obj];run(cmd,work/f'compile-{i}-{j}.log');objects.append(obj)
        obj=work/'abi.o';run([compiler,'-x','c','-fPIC','-O2','-I',SDK_ROOT,'-c',shim,'-o',obj],work/'abi.log');objects.append(obj)
        cmd=[compiler]+(['-dynamiclib','-Wl,-undefined,dynamic_lookup','-Wl,-headerpad_max_install_names'] if a.platform.startswith('macos') else ['-shared'])+objects+['-pthread','-o',lib]
        cmd+=sum((['-L',x] for x in cfg.get('build_library_dirs',[])),[]);cmd+=['-l'+x for x in cfg.get('build_link_libraries',[])];run(cmd,work/'link.log')
        if cfg.get('native_requirements') and a.platform.startswith('macos'):
            changes=[]
            for old,new in cfg.get('install_names',{}).items(): changes+=['-change',old,'@loader_path/vendor/'+Path(new).name]
            for req in cfg['native_requirements']:
                if req['kind']=='runtime':
                    for library in req.get('libraries',[]):changes+=['-change','@rpath/'+library,'@loader_path/vendor/'+library]
            if changes: run(['install_name_tool']+changes+[lib],work/'relocate.log')
            run(['codesign','--force','--sign','-',lib],work/'codesign.log')
        if a.platform.startswith('macos'):
            run(['install_name_tool','-id','@rpath/'+lib.name,lib],work/'install-name.log')
            run(['codesign','--force','--sign','-',lib],work/'codesign.log')
        ext=copy.deepcopy(native[0]);ext={k:v for k,v in ext.items() if k in ['name','symbols','types','errors','blocking_symbols','required_runtime_features']}
        ext.update(kind='prebuilt',library=lib.relative_to(stage).as_posix(),sputnik_ext_abi=1)
        if data.get('native_providers'):data['native_providers']=[p for p in data['native_providers'] if p['kind']=='runtime']
        if cfg.get('native_requirements'):
            data['native_requirements']=[r for r in data['native_requirements'] if r['kind']=='runtime'];ext['requirements']=[r['id'] for r in data['native_requirements']]
        data['native']=[ext]
(stage/'sputnik.toml').write_text(manifest(data))
archive=work/(cfg['name']+'-'+variant+'.sputnikpkg')
run([a.sputnik.resolve(),'pkg','build',stage,'--modules',a.modules,'--out',archive],work/'build.log')
run([a.sputnik.resolve(),'pkg','inspect',archive],work/'inspect.json')
if a.modules=='mixed' and json.loads((work/'inspect.json').read_text())['bytecode_modules']==0:
    archive.unlink();print('Skipped redundant mixed variant with no bytecode modules');raise SystemExit(0)
print(archive)
