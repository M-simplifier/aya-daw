import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {promises as fs} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import http from 'node:http';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const binary = path.resolve(process.argv[2] ?? path.join(root, '.work/bin/aya.exe'));
const testRoot = path.join(root, '.work', `integration-${Date.now()}`);
await fs.mkdir(path.join(testRoot, 'web'), {recursive:true});
const child = spawn(binary, ['--root', testRoot, '--port', '0'], {cwd:testRoot, windowsHide:true,
  stdio:['ignore','pipe','pipe'], env:process.env});
let log = ''; child.stdout.on('data', chunk => { log += chunk; }); child.stderr.on('data', chunk => { log += chunk; });
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve,milliseconds));
let url;
for (let i=0;i<160;i++) {
  await sleep(100);
  try { url = JSON.parse(await fs.readFile(path.join(testRoot,'.work/endpoint.json'),'utf8')).url; break; } catch {}
  if (child.exitCode !== null) throw new Error(`Server failed: ${log}`);
}
assert.ok(url, `Server startup timed out: ${log}`);
const passed = [];
async function api(route, body, expected=200, headers={}) {
  const response = await fetch(`${url}/api/${route}`, {method:body===undefined?'GET':'POST',
    headers:body===undefined?headers:{'Content-Type':'application/json',...headers},
    body:body===undefined?undefined:JSON.stringify(body), signal:AbortSignal.timeout(120000)});
  const text = await response.text();
  assert.equal(response.status, expected, `${route}: ${text}`);
  return JSON.parse(text);
}
function pass(name) { passed.push(name); console.log(`PASS ${name}`); }

try {
  const bootstrap = await api('bootstrap');
  assert.equal(bootstrap.engine.available,true,JSON.stringify(bootstrap.engine));
  assert.equal(bootstrap.engine.sampleRate,48000); pass('native device available through actual HTTP app');
  await api('compile',bootstrap.project,403,{'Origin':'https://foreign.example'});
  assert.equal(await rawStatus('/api/status',{Host:'foreign.example'}),403);
  assert.equal(await rawStatus('/api/status',{'Sec-Fetch-Site':'cross-site'}),403);
  pass('foreign Origin, Host and cross-site API are rejected');
  const badContent = await fetch(`${url}/api/compile`, {method:'POST',headers:{'Content-Type':'text/plain'},body:'{}'});
  assert.equal(badContent.status,415);
  const traversal = await fetch(`${url}/%2e%2e%2fAGENTS.md`); assert.equal(traversal.status,404);
  pass('content type and file traversal protections');

  const project = await api('empty');
  const empty = await api('compile',project); assert.equal(empty.resolved.notes.length,0); pass('blank project compiles');
  project.name='HTTP workflow composition'; project.tempo=120; project.lengthBeats=32;
  project.masterGain=0.04; project.loop={enabled:false,start:4,end:8};
  const defaultTrack=structuredClone(project.tracks[0]);
  project.tracks=['kick','bass','pad','pluck'].map((instrument,i)=>({...structuredClone(defaultTrack),id:`t-${i}`,name:instrument,instrument,
    gain:0.35,pan:(i-1.5)*0.15,patch:{...defaultTrack.patch,attack:0.01,release:0.15,delaySend:0.12,delayFeedback:0.24},
    automation:i===2?[{parameter:'cutoff',points:[{beat:0,value:800},{beat:16,value:4000},{beat:32,value:700}]}]:[]}));
  const generator=(kind,root,degrees,steps,pulses)=>({kind,root,degrees,steps,pulses,rotation:0,octaves:1,gate:0.65,seed:41,velocity:0.7});
  project.patterns=[
    {id:'p-kick',name:'pulse',length:4,notes:[],generator:generator('euclid',36,[0],16,4),transforms:[]},
    {id:'p-bass',name:'low',length:4,notes:[{id:'n-low',start:0,duration:1.5,pitch:43.5,velocity:0.6}],generator:null,transforms:[]},
    {id:'p-pad',name:'harmony',length:8,notes:[],generator:generator('chords',60,[0,3,4,0],16,5),transforms:[]},
    {id:'p-lead',name:'phrase',length:4,notes:[],generator:generator('arpeggio',72,[0,2,4,6],8,4),transforms:[{kind:'reverse',amount:0},{kind:'rotate',amount:0.25}]}
  ];
  project.clips=[
    {id:'c-intro',trackId:'t-2',patternId:'p-pad',start:0,length:32,transpose:0,gain:0.8},
    {id:'c-drums',trackId:'t-0',patternId:'p-kick',start:4,length:24,transpose:0,gain:0.8},
    {id:'c-bass',trackId:'t-1',patternId:'p-bass',start:4,length:24,transpose:0,gain:1},
    {id:'c-main',trackId:'t-3',patternId:'p-lead',start:8,length:8,transpose:0,gain:0.8},
    {id:'c-var',trackId:'t-3',patternId:'p-lead',start:16,length:8,transpose:3.25,gain:0.7},
    {id:'c-outro',trackId:'t-3',patternId:'p-lead',start:24,length:4,transpose:-12,gain:0.5}
  ];
  let compiled = await api('compile',project); assert.ok(compiled.resolved.notes.length>80);
  assert.ok(compiled.resolved.notes.every(note=>note.start>=0 && note.start+note.duration<=32+1e-10));
  pass('blank -> rhythm, bass, chords, melody -> intro/main/variation/outro arrangement');
  const materialized=await api('materialize',{project,patternId:'p-lead'});
  const direct=materialized.project.patterns.find(pattern=>pattern.id==='p-lead');
  assert.equal(direct.generator,null); assert.equal(direct.transforms.length,0);
  assert.deepEqual(direct.notes,compiled.resolved.patterns.find(pattern=>pattern.id==='p-lead').notes);
  direct.notes[0].pitch+=0.25; Object.assign(project,materialized.project);
  compiled=await api('compile',project); pass('generated phrase materializes and edits directly');

  const wav=sampleWav();
  const asset=await api('assets/wav',{name:'self-contained.wav',data:wav.toString('base64')});
  assert.equal(asset.sampleRate,48000); assert.equal(asset.frames,4800);
  project.assets.push(asset);
  project.tracks.push({...structuredClone(defaultTrack),id:'t-sample',name:'sample',instrument:'sample',assetId:asset.id,gain:0.2});
  project.clips.push({id:'c-sample',trackId:'t-sample',patternId:'p-bass',start:0,length:4,transpose:16.5,gain:1});
  compiled=await api('compile',project);
  await api('recovery',project); const recovered=await api('recovery'); assert.deepEqual(recovered,project);
  const savedPath=path.join(testRoot,'saved.aya.json'); await fs.writeFile(savedPath,JSON.stringify(project));
  const reopened=JSON.parse(await fs.readFile(savedPath,'utf8'));
  const reopenedCompile=await api('compile',reopened);
  assert.deepEqual(compiled.resolved,reopenedCompile.resolved); assert.equal(reopened.assets[0].data,wav.toString('base64'));
  pass('embedded sample + atomic recovery + save/reopen preserve canonical music');

  project.loop.enabled=true; await api('compile',project);
  await api('transport',{action:'seek',beat:7.8}); await api('transport',{action:'play'}); await sleep(700);
  const running=await api('status'); assert.equal(running.playing,true); assert.ok(running.beat>=4 && running.beat<8,JSON.stringify(running));
  const invalid=structuredClone(project); invalid.tempo=0; await api('compile',invalid,422);
  const stillRunning=await api('status'); assert.equal(stillRunning.playing,true);
  const liveEdit=structuredClone(project); liveEdit.tracks[1].pan=0.2;
  await api('compile',liveEdit); assert.equal((await api('status')).playing,true);
  await api('transport',{action:'pause'}); pass('seek/loop and live edits keep transport; invalid compile preserves playing plan');
  await api('input-events',{events:[{kind:'on',eventId:'key-1',trackId:'t-3',pitch:72.25,velocity:0.3,sequence:1,timestampMs:0},
    {kind:'on',eventId:'key-2',trackId:'t-3',pitch:75.5,velocity:0.3,sequence:2,timestampMs:10},
    {kind:'off',eventId:'key-1',sequence:3,timestampMs:100},{kind:'off',eventId:'key-2',sequence:4,timestampMs:120}]});
  await api('panic',{}); pass('ordered timestamped on/off batch and panic reach native audio');

  project.loop.enabled=false;
  const manifest=await api('export',{project,stems:true}); assert.equal(manifest.files.length,6);
  const downloaded=[];
  for(const file of manifest.files) {
    const response=await fetch(url+file.url); assert.equal(response.status,200);
    const bytes=Buffer.from(await response.arrayBuffer()); const decoded=readWave(bytes);
    assert.equal(decoded.rate,48000); assert.equal(decoded.channels,2); assert.ok(decoded.duration>=16);
    assert.ok(decoded.peak>0,`${file.name} unexpectedly silent`); assert.ok(Number.isFinite(decoded.peak));
    assert.ok(Math.abs(decoded.peak-file.peak)<0.000002,`${file.name} PCM peak differs from render report`);
    await fs.writeFile(path.join(testRoot,file.name),bytes); downloaded.push(bytes);
  }
  const second=await api('export',{project:reopened,stems:false});
  const secondBytes=Buffer.from(await (await fetch(url+second.files[0].url)).arrayBuffer());
  assert.ok(downloaded[0].equals(secondBytes),'Reopened composition WAV differs');
  pass('real stereo/stem WAV downloads + reopened project render byte-identically');
  const midi=await api('midi/export',project);
  const midiBytes=Buffer.from(await (await fetch(url+midi.files[0].url)).arrayBuffer());
  assert.equal(midiBytes.subarray(0,4).toString(),'MThd');
  const imported=await api('midi/import',{name:'roundtrip.mid',data:midiBytes.toString('base64')});
  assert.ok(imported.project.patterns.length>0); await api('compile',imported.project); pass('actual MIDI export/import/compile');
  await api('transport',{action:'stop'});
  const report={checks:passed,root:testRoot,mixSha256:createHash('sha256').update(downloaded[0]).digest('hex'),
    duration:manifest.duration,device:await api('status')};
  await fs.writeFile(path.join(testRoot,'report.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify(report,null,2));
} finally {
  try { await api('panic',{}); await api('shutdown',{}); } catch {}
  for(let i=0;i<50 && child.exitCode===null;i++) await sleep(100);
  if(child.exitCode===null) child.kill();
}

function rawStatus(route,headers) {
  return new Promise((resolve,reject)=>{
    const request=http.get(url+route,{headers},response=>{response.resume();resolve(response.statusCode);});
    request.on('error',reject); request.setTimeout(5000,()=>request.destroy(new Error('HTTP timeout')));
  });
}

function sampleWav() {
  const frames=4800, data=Buffer.alloc(44+frames*2);
  data.write('RIFF');data.writeUInt32LE(data.length-8,4);data.write('WAVEfmt ',8);data.writeUInt32LE(16,16);
  data.writeUInt16LE(1,20);data.writeUInt16LE(1,22);data.writeUInt32LE(48000,24);data.writeUInt32LE(96000,28);
  data.writeUInt16LE(2,32);data.writeUInt16LE(16,34);data.write('data',36);data.writeUInt32LE(frames*2,40);
  for(let i=0;i<frames;i++) data.writeInt16LE(Math.round(Math.sin(i*2*Math.PI*550/48000)*6000*(1-i/frames)),44+i*2);
  return data;
}
function readWave(bytes) {
  assert.equal(bytes.subarray(0,4).toString(),'RIFF'); assert.equal(bytes.subarray(8,12).toString(),'WAVE');
  let offset=12, format, channels, rate, bits, samples;
  while(offset+8<=bytes.length) {
    const kind=bytes.subarray(offset,offset+4).toString(), length=bytes.readUInt32LE(offset+4),start=offset+8;
    if(kind==='fmt ') {format=bytes.readUInt16LE(start);channels=bytes.readUInt16LE(start+2);rate=bytes.readUInt32LE(start+4);bits=bytes.readUInt16LE(start+14);}
    if(kind==='data') samples=bytes.subarray(start,start+length);
    offset=start+length+(length%2);
  }
  assert.ok(samples); let peak=0;
  for(let i=0;i<samples.length;i+=bits/8) {
    const value=format===3?(bits===64?samples.readDoubleLE(i):samples.readFloatLE(i)):
      bits===8?(samples.readUInt8(i)-128)/128:samples.readIntLE(i,bits/8)/(2**(bits-1));
    assert.ok(Number.isFinite(value)); peak=Math.max(peak,Math.abs(value));
  }
  return {rate,channels,peak,duration:samples.length/(bits/8)/channels/rate};
}
