import assert from 'node:assert/strict';
import {readFile,readdir,stat} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {renderSHA256,projectSHA256,verifyOriginalRender,verifyOriginalProject} from './scripts/media.mjs';

const root=path.dirname(fileURLToPath(import.meta.url)),repo=path.resolve(root,'..');
const publicBase=new URL('https://m-simplifier.github.io/aya-daw/');
const routes=[{file:'index.html',url:'',lang:'ja',developer:false},{file:'en/index.html',url:'en/',lang:'en',developer:false},{file:'developers/index.html',url:'developers/',lang:'ja',developer:true},{file:'en/developers/index.html',url:'en/developers/',lang:'en',developer:true}];
const read=relative=>readFile(path.join(root,relative),'utf8');
const htmlCache=new Map();
const unescape=text=>text.replace(/&amp;/g,'&').replace(/&quot;/g,'"').replace(/&#39;/g,"'");
const attr=(tag,name)=>unescape(tag.match(new RegExp(`\\b${name}=["']([^"']*)["']`,'i'))?.[1]??'');
async function localTarget(url){
 assert.equal(url.origin,publicBase.origin);
 assert.ok(url.pathname.startsWith(publicBase.pathname),`Path escaped Pages base: ${url.href}`);
 const relative=decodeURIComponent(url.pathname.slice(publicBase.pathname.length));
 let file=path.join(root,relative),info=await stat(file).catch(()=>null);
 assert.ok(info,`Missing local target: ${relative}`);
 if(info.isDirectory()){file=path.join(file,'index.html');info=await stat(file).catch(()=>null);assert.ok(info,`Missing directory index: ${relative}`);}
 assert.ok(info.isFile(),`Target is not a file: ${relative}`);
 return file;
}

let localReferences=0,sourceReferences=0;
for(const route of routes){
 const html=await read(route.file),pageURL=new URL(route.url,publicBase);htmlCache.set(route.file,html);
 assert.match(html,new RegExp(`<html lang="${route.lang}">`));
 assert.equal((html.match(/<h1\b/g)??[]).length,1,`${route.file}: exactly one main heading`);
 assert.match(html,/<title>[^<]+<\/title>/);assert.match(html,/<meta name="description" content="[^"<>]{70,}"/);
 const canonical=html.match(/<link rel="canonical" href="([^"]+)"/);assert.equal(canonical?.[1],pageURL.href);
 for(const lang of ['ja','en','x-default'])assert.match(html,new RegExp(`<link rel="alternate" hreflang="${lang}" href="https://m-simplifier\\.github\\.io/aya-daw/`));
 assert.match(html,/<meta property="og:image" content="https:\/\/m-simplifier.github.io\/aya-daw\/assets\/aya-studio.jpg"/);
 assert.match(html,/<meta name="twitter:card" content="summary_large_image"/);
 assert.match(html,/<a class="skip-link" href="#main">/);
 assert.match(html,/<meta name="viewport" content="width=device-width,initial-scale=1"/);
 assert.doesNotMatch(html,/C:\\Users|\.codex|codex:\/\/|localhost|127\.0\.0\.1|SessionStart|MYStudio|オーナー|owner history|agent task/i);
 assert.doesNotMatch(html,/<audio\b[^>]*\bautoplay\b/i);
 const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(match=>match[1]);assert.equal(ids.length,new Set(ids).size,`${route.file}: duplicate IDs`);
 for(const tag of html.match(/<(?:a|link|script|img|audio)\b[^>]*>/g)??[]){
  const reference=attr(tag,/^<(?:script|img|audio)/.test(tag)?'src':'href');if(!reference||/^(?:data:|mailto:)/.test(reference))continue;
  const url=new URL(reference,pageURL);
  if(/^<script|^<img|^<audio/.test(tag))assert.equal(url.origin,publicBase.origin,`${route.file}: no external runtime/media dependencies`);
  if(url.origin===publicBase.origin){
   const target=await localTarget(url);localReferences++;
   if(url.hash){const targetHTML=await readFile(target,'utf8');const id=decodeURIComponent(url.hash.slice(1));assert.ok(targetHTML.includes(`id="${id}"`),`${route.file}: missing anchor ${reference}`);}
  }else if(url.hostname==='github.com'&&url.pathname.startsWith('/M-simplifier/aya-daw/blob/main/')){
   const source=decodeURIComponent(url.pathname.slice('/M-simplifier/aya-daw/blob/main/'.length));assert.ok((await stat(path.join(repo,source)).catch(()=>null))?.isFile(),`Missing linked repository source: ${source}`);sourceReferences++;
  }
 }
 for(const tag of html.match(/<img\b[^>]*>/g)??[]){assert.ok(/\balt=/.test(tag),`${route.file}: image missing alt`);assert.ok(/\bwidth=/.test(tag)&&/\bheight=/.test(tag),`${route.file}: image dimensions missing`);}
 if(route.developer){
  assert.equal((html.match(/<h2 id="section-/g)??[]).length,8,`${route.file}: all guide sections`);
  assert.match(html,/compileProject/);assert.match(html,/preparePlan/);assert.match(html,/18,?000/);assert.match(html,/729/);assert.match(html,/32/);
  assert.match(html,/Reference.hs/);assert.match(html,/Diagnostics.hs/);assert.match(html,/WASAPI/);
  assert.match(html,/60000|60,000/);assert.match(html,/c\/n\/0/);assert.match(html,/456\.3482/);
  assert.match(html,/architecture-branches/);assert.match(html,/source-diagram/);
  assert.ok((html.match(/<pre><code>/g)??[]).length>=4,`${route.file}: source excerpts or diagram description missing`);
  assert.match(html,route.lang==='ja'?/共有メモリーでの計画交換を含む負荷試験は、表の別の試験です/:/shared-memory exchange protocol is exercised by the separate load test/);
 }else{
  assert.equal((html.match(/data-study-phase=/g)??[]).length,3);
  assert.match(html,/<audio[^>]+preload="none"/);
  assert.match(html,/href="https:\/\/github.com\/M-simplifier\/aya-daw\/releases\/latest\/download\/Aya-Windows-x64.zip"/);
  assert.match(html,/download="glass-tides.aya.json"/);assert.match(html,/THIRD-PARTY.md/);
  assert.match(html,route.lang==='ja'?/ブラウザーで動く操作の説明図/:/illustrative browser interaction/);
  assert.match(html,route.lang==='ja'?/編集画面は日本語/:/editor currently uses Japanese/);
 }
}

const media=JSON.parse(await read('assets/media-sources.json'));
for(const item of [media.screenshot,media.audio]){const bytes=await readFile(path.join(root,'assets',item.file));assert.equal(createHash('sha256').update(bytes).digest('hex'),item.sha256,`Media hash differs: ${item.file}`);}
const wav=await readFile(path.join(root,'assets/glass-tides.wav'));
const {format,durationSeconds}=verifyOriginalRender(wav);
assert.equal(media.audio.sha256,renderSHA256);
for(const [key,value] of Object.entries({...format,durationSeconds}))assert.equal(media.audio[key],value,`Audio metadata differs: ${key}`);
const projectBytes=await readFile(path.join(root,'assets/glass-tides.aya.json'));
const project=verifyOriginalProject(projectBytes);
assert.equal(media.project.sha256,projectSHA256);
assert.deepEqual(projectBytes,await readFile(path.join(repo,'examples/glass-tides.aya.json')),'Site project must match the tracked example exactly');
assert.match(await read('main.js'),/prefers|audio|copy/);assert.doesNotMatch(await read('main.js'),/AudioContext|OscillatorNode|fetch\(['"]\/api/);
assert.match(await read('style.css'),/prefers-reduced-motion/);
assert.match(await read('sitemap.xml'),/en\/developers\//);

const urlIndex=process.argv.indexOf('--url');
if(urlIndex!==-1){
 const base=new URL(process.argv[urlIndex+1]);
 for(const route of routes){const response=await fetch(new URL(route.url,base));assert.equal(response.status,200);const body=await response.text();assert.match(body,new RegExp(`<html lang="${route.lang}">`));}
 const response=await fetch(new URL('assets/glass-tides.wav',base),{headers:{Range:'bytes=0-43'}});assert.equal(response.status,206);assert.match(response.headers.get('content-type'),/audio\/wav/);assert.equal((await response.arrayBuffer()).byteLength,44);
 const json=await fetch(new URL('assets/glass-tides.aya.json',base));assert.equal(json.status,200);assert.equal((await json.json()).name,project.name);
 console.log('HTTP:4routes+audio-range+project-download passed.');
}
console.log(`Site check passed:4pages,${localReferences} local references,${sourceReferences} linked source files; original media hashes verified.`);
