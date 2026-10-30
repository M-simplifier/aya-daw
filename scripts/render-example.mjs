import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {promises as fs} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {inspectWave} from './wave-check.mjs';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const binary=path.resolve(process.argv[2]??path.join(root,'.work','bin','aya.exe'));
const testRoot=path.join(root,'.work','full-example-render');
await fs.mkdir(path.join(testRoot,'web'),{recursive:true});
await fs.mkdir(path.join(root,'examples'),{recursive:true});
await fs.rm(path.join(testRoot,'.work','endpoint.json'),{force:true});
const child=spawn(binary,['--root',testRoot,'--port','0'],
  {cwd:testRoot,windowsHide:true,stdio:['ignore','pipe','pipe']});
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let url,log='';child.stdout.on('data',b=>{log+=b;});child.stderr.on('data',b=>{log+=b;});
for(let i=0;i<100;i++) {await sleep(100);try{url=JSON.parse(await fs.readFile(path.join(testRoot,'.work','endpoint.json'),'utf8')).url;break;}catch{}}
assert.ok(url,log);
const api=async(route,body)=>{
  const response=await fetch(url+'/api/'+route,{method:body===undefined?'GET':'POST',headers:body===undefined?{}:{'Content-Type':'application/json'},
    body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(120000)});
  const result=await response.json();assert.equal(response.status,200,JSON.stringify(result));return result;
};
try {
  const project=await api('example');assert.equal(project.lengthBeats,160);assert.equal(project.tracks.length,7);
  const compiled=await api('compile',project);assert.ok(compiled.resolved.notes.length>=900);
  const manifest=await api('export',{project,stems:false});assert.equal(manifest.files.length,1);
  const bytes=Buffer.from(await (await fetch(url+manifest.files[0].url)).arrayBuffer());
  const wave=inspectWave(bytes);
  assert.equal(wave.rate,48000);assert.equal(wave.channels,2);assert.equal(wave.bits,24);
  assert.ok(wave.frames>Math.round(160*60/108*48000));assert.ok(wave.rms>0.001);
  assert.ok(wave.peak<1);assert.ok(wave.tailRms<0.00001,'Last second is not a quiet completed tail');
  assert.ok(Math.abs(wave.peak-manifest.files[0].peak)<0.000002);
  await fs.writeFile(path.join(root,'examples','glass-tides.aya.json'),JSON.stringify(project,null,2));
  const empty=await api('empty');await fs.writeFile(path.join(root,'examples','empty.aya.json'),JSON.stringify(empty,null,2));
  await fs.writeFile(path.join(root,'examples','Glass-Tides.wav'),bytes);
  const report={project:'examples/glass-tides.aya.json',wav:'examples/Glass-Tides.wav',bars:40,notes:compiled.resolved.notes.length,
    musicalSeconds:160*60/108,...wave,sha256:createHash('sha256').update(bytes).digest('hex'),device:await api('status')};
  await fs.writeFile(path.join(testRoot,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
} finally {
  try{await api('panic',{});await api('shutdown',{});}catch{}
  for(let i=0;i<50&&child.exitCode===null;i++)await sleep(100);
  if(child.exitCode===null)child.kill();
}
