import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

test('every literal DOM consumer has a declared static or dynamically authored element',async()=>{
  const source=await readFile(new URL('../../web/main.js',import.meta.url),'utf8');
  const markup=await readFile(new URL('../../web/index.html',import.meta.url),'utf8');
  const declarations=new Set([...`${markup}\n${source}`.matchAll(/\bid=["']([\w-]+)["']/g)].map(match=>match[1]));
  for(const match of source.matchAll(/\b\w+\.id\s*=\s*["']([\w-]+)["']/g))declarations.add(match[1]);
  const consumers=new Set([...source.matchAll(/\$\(['"]#([\w-]+)['"]\)/g)].map(match=>match[1]));
  const missing=[...consumers].filter(id=>!declarations.has(id));
  assert.deepEqual(missing,[],'DOM IDs used by the renderer must survive toolbar/layout revisions');
});
