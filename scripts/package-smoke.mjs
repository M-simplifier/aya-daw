import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {promises as fs} from 'node:fs';
import path from 'node:path';
import {inspectWave} from './wave-check.mjs';

const packageRoot=path.resolve(process.argv[2]);
const binary=path.join(packageRoot,'aya.exe');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
await fs.rm(path.join(packageRoot,'.work','endpoint.json'),{force:true});
const child=spawn(binary,['--root',packageRoot,'--port','0'],{cwd:packageRoot,windowsHide:true,
  stdio:['ignore','pipe','pipe'],env:{...process.env,PATH:path.join(process.env.SystemRoot??'C:\\Windows','System32')}});
let url,log='';child.stdout.on('data',b=>{log+=b;});child.stderr.on('data',b=>{log+=b;});
for(let i=0;i<100;i++){await sleep(100);try{url=JSON.parse(await fs.readFile(path.join(packageRoot,'.work','endpoint.json'),'utf8')).url;break;}catch{}}
assert.ok(url,log);
const api=async(route,body)=>{
  const response=await fetch(url+'/api/'+route,{method:body===undefined?'GET':'POST',headers:body===undefined?{}:{'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body)});
  const result=await response.json();assert.equal(response.status,200,JSON.stringify(result));return result;
};
try {
  for(const [file,type] of [['/','text/html'],['/main.js','text/javascript'],['/model.js','text/javascript'],['/api.js','text/javascript'],['/style.css','text/css']]) {
    const response=await fetch(url+file,{headers:{'Sec-Fetch-Site':'cross-site'}});assert.equal(response.status,200,file);
    assert.ok(response.headers.get('Content-Type').startsWith(type));assert.ok((await response.text()).length>100);
  }
  const bootstrap=await api('bootstrap');assert.equal(bootstrap.project.lengthBeats,160);assert.equal(bootstrap.project.tracks.length,7);
  assert.equal(bootstrap.engine.available,true);assert.equal(bootstrap.engine.sampleRate,48000);
  const project=await api('empty');project.lengthBeats=4;project.loop={enabled:false,start:0,end:4};project.masterGain=0.1;
  project.patterns=[{id:'p',name:'test',length:4,notes:[{id:'n',start:0,duration:0.5,pitch:60.25,velocity:0.3}],generator:null,transforms:[]}];
  project.clips=[{id:'c',trackId:project.tracks[0].id,patternId:'p',start:0,length:4,transpose:0,gain:1}];
  const compilation=await api('compile',project);assert.equal(compilation.resolved.notes.length,1);
  const exported=await api('export',{project,stems:false});
  const bytes=Buffer.from(await (await fetch(url+exported.files[0].url)).arrayBuffer());const wave=inspectWave(bytes);
  assert.ok(wave.peak>0&&wave.peak<1);assert.equal(wave.rate,48000);
  const status=await api('status');await api('panic',{});await api('shutdown',{});
  for(let i=0;i<50&&child.exitCode===null;i++)await sleep(100);
  assert.equal(child.exitCode,0,`App failed to close cleanly: ${log}`);
  console.log(JSON.stringify({packageRoot,restrictedPath:true,staticFiles:5,fullExampleBars:40,native:status.engine,wav:wave,cleanExit:true},null,2));
} finally {
  if(child.exitCode===null){try{await api('panic',{});await api('shutdown',{});}catch{}await sleep(1500);if(child.exitCode===null)child.kill();}
}
