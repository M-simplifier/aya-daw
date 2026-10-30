"""Verify replaceable GMP imports and reject embedded static GMP implementations."""
import argparse
import hashlib
import json
import pathlib
import re
import struct
import subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary',type=pathlib.Path)
parser.add_argument('--nm',required=True)
args=parser.parse_args()
data=args.binary.read_bytes()
u16=lambda offset:struct.unpack_from('<H',data,offset)[0]
u32=lambda offset:struct.unpack_from('<I',data,offset)[0]
u64=lambda offset:struct.unpack_from('<Q',data,offset)[0]
pe=u32(0x3c)
if data[pe:pe+4]!=b'PE\0\0' or u16(pe+24)!=0x20b:
    raise SystemExit('Expected a PE32+ executable')
optional=pe+24
image_base=u64(optional+24)
section_start=optional+u16(pe+20)
sections=[]
for index in range(u16(pe+6)):
    offset=section_start+index*40
    sections.append((u32(offset+12),u32(offset+8),u32(offset+20),u32(offset+16)))

def file_offset(rva):
    for address,virtual_size,raw_start,raw_size in sections:
        if address<=rva<address+max(virtual_size,raw_size):
            result=raw_start+rva-address
            if result>=len(data):
                raise ValueError('RVA exceeds file')
            return result
    raise ValueError(f'Unmapped RVA {rva:x}')

def string_at(rva):
    start=file_offset(rva)
    return data[start:data.index(b'\0',start)].decode('ascii')

imports={}
gmp_iat={}
descriptor=file_offset(u32(optional+120))
while any(data[descriptor:descriptor+20]):
    names_rva,_,_,name_rva,iat_rva=struct.unpack_from('<IIIII',data,descriptor)
    library=string_at(name_rva)
    symbols=[]
    index=0
    while True:
        entry=u64(file_offset((names_rva or iat_rva)+index*8))
        if entry==0:
            break
        name=f'ordinal#{entry&0xffff}' if entry&(1<<63) else string_at(entry+2)
        symbols.append(name)
        if library.lower()=='libgmp-10.dll':
            gmp_iat[iat_rva+index*8]=name
        index+=1
    imports[library]=symbols
    descriptor+=20
if not gmp_iat:
    raise SystemExit('GMP DLL import missing: this executable must not be redistributed by the release packager')

symbols=subprocess.check_output([args.nm,'--defined-only',str(args.binary)],encoding='utf8')
thunks=[]
for line in symbols.splitlines():
    match=re.fullmatch(r'([0-9a-fA-F]+)\s+([A-Za-z])\s+(__gmp\S+)',line)
    if not match:
        continue
    address,kind,name=match.groups()
    if kind=='I':
        continue
    if kind!='T':
        raise SystemExit(f'Unexpected embedded GMP data symbol: {kind} {name}')
    rva=int(address,16)-image_base
    offset=file_offset(rva)
    if data[offset:offset+2]!=b'\xff\x25':
        raise SystemExit(f'Embedded GMP implementation rather than an import thunk: {name}')
    displacement=struct.unpack_from('<i',data,offset+2)[0]
    if gmp_iat.get(rva+6+displacement)!=name:
        raise SystemExit(f'GMP thunk does not target its named DLL import: {name}')
    thunks.append(name)
if not thunks:
    raise SystemExit('No GMP import thunks found')
report={'binary':args.binary.name,'sha256':hashlib.sha256(data).hexdigest(),
        'imports':{name:len(entries) for name,entries in sorted(imports.items())},
        'gmpFunctionThunks':len(thunks),'gmpImportedSymbols':len(gmp_iat),
        'embeddedGmpImplementations':0}
print(json.dumps(report,indent=2))
