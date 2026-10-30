import {INSTRUMENTS, COLORS, clone, clamp, snap, uid, number, makeTrack, blankProject, makePattern, makeClip,
  editTrack, editPattern, editClip, moveClip, resizeClip, duplicateClip, detachClip, removeTrack, reorderTrack,
  moveNotes, resizeNote, removeNotes, putAutomation, History, pitchLabel, beatLabel} from './model.js';
import {api, CompileQueue} from './api.js';

const $ = selector => document.querySelector(selector);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt = (n, places = 2) => Number(n.toFixed(places)).toString();
let project = blankProject(), history = new History(project), resolved = {patterns: [], notes: []};
let clipId = null, trackId = project.tracks[0]?.id, noteIds = new Set(), inspectorTab = 'pattern';
let loaded = false, dirty = false, busy = false, quantize = .25, timelineZoom = 28, noteZoom = 44;
let songFitted = true, viewFocus = null;
let pitchLow = 48, pitchHigh = 83, keyboard = false, recording = false, keyOctave = 4;
let status = {playing:false,beat:0,engine:{available:false}}, statusTime = performance.now();
let queue, toastTimer, recoveryTimer, pollTimer, drag = null, autoParameter = 'gain', autoSelected = -1;
let instruments = INSTRUMENTS.map(([id,name]) => ({id,name})), version = '', midiSupported = false;
const pressedKeys = new Map(); let inputSequence = 0;
const activeClip = () => project.clips.find(c => c.id === clipId);
const activeTrack = () => project.tracks.find(t => t.id === trackId);
const activePattern = () => project.patterns.find(p => p.id === activeClip()?.patternId);
const resolvedPattern = pattern => resolved.patterns?.find(p => p.id === pattern?.id);
const isDirect = pattern => !!pattern && !pattern.generator && !pattern.transforms?.length;
const patternNotes = pattern => isDirect(pattern) ? pattern.notes : resolvedPattern(pattern)?.notes ?? [];

function notice(message, error = false) {
  $('#notice-text').textContent = message; $('#notice').classList.toggle('error', error); $('#notice').hidden = false;
}
function toast(message) {
  clearTimeout(toastTimer); $('#toast').textContent = message; $('#toast').hidden = false;
  toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 3200);
}
function fail(error) {
  const details = error.details?.slice(0,3).map(e => `${e.path ? `${e.path}: ` : ''}${e.message}`).join(' / ');
  notice(details || error.message || String(error), true);
  console.error(error);
}
function modal(content) { $('#modal-content').innerHTML = content; if (!$('#modal').open) $('#modal').showModal(); }
function closeModal() { $('#modal').close(); }
async function guarded(action) { try { await action(); } catch (error) { fail(error); } }
function setBusy(value) { busy = value; document.body.classList.toggle('busy', value); }

function commit(next, label = '編集', {renderNow = true} = {}) {
  if (!loaded || !history.commit(next, label)) return;
  project = history.present; dirty = true; queue.schedule(project);
  saveBrowserRecovery();
  if (renderNow) render(); else renderSaveState();
}

function replaceProject(next, label) {
  project = next; history = new History(project); resolved = {patterns:[], notes:[]};
  clipId = project.clips[0]?.id ?? null; trackId = activeClip()?.trackId ?? project.tracks[0]?.id ?? null;
  noteIds.clear(); dirty = false; recording = false; queue.schedule(project); render(); fitNotes();
  fitSong(); scrollSelectedTrack(); saveBrowserRecovery(); toast(label);
}
function saveBrowserRecovery() {
  try { localStorage.setItem('aya.recovery.v1', JSON.stringify({savedAt:Date.now(),project})); }
  catch { /* Backend recovery remains active when browser storage is full. */ }
}
function stableJSON(value) {
  if(Array.isArray(value))return `[${value.map(stableJSON).join(',')}]`;
  if(value&&typeof value==='object')return `{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${stableJSON(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}

function reconcileSelection() {
  if (!project.clips.some(c => c.id === clipId)) clipId = null;
  if (!project.tracks.some(t => t.id === trackId)) trackId = project.tracks[0]?.id ?? null;
  if (activeClip()) trackId = activeClip().trackId;
  const ids = new Set(patternNotes(activePattern()).map(n => n.id));
  noteIds = new Set([...noteIds].filter(id => ids.has(id)));
}

function renderSaveState() {
  $('#save-state').textContent = dirty ? '未保存の変更 · 自動回復あり' : 'プロジェクトファイルへ保存できます';
  $('#undo-button').disabled = !history.past.length; $('#redo-button').disabled = !history.future.length;
  $('#undo-button').title = history.past.length ? `元に戻す: ${history.past.at(-1).label} (Ctrl Z)` : '元に戻す (Ctrl Z)';
}

function render() {
  reconcileSelection(); renderTop(); renderTracks(); renderTimeline(); renderEditor(); renderInspector(); renderSaveState(); updatePlayhead();
}
function renderTop() {
  $('#project-name').value = project.name; $('#tempo').value = project.tempo;
  $('#master-gain').value = project.masterGain; $('#loop-enabled').checked = project.loop.enabled;
  $('#loop-start').value = fmt(project.loop.start / project.beatsPerBar + 1);
  $('#loop-end').value = fmt(project.loop.end / project.beatsPerBar + 1);
  $('#song-bars').value = fmt(project.lengthBeats / project.beatsPerBar); $('#song-bars').max=4096/project.beatsPerBar;
  $('#tuning-summary').textContent = `${project.tuning.divisions}音`;
  $('#duplicate-clip').disabled = !activeClip(); $('#delete-clip').disabled = !activeClip();
  $('#keyboard-button').setAttribute('aria-pressed', String(keyboard));
  $('#keyboard-button').classList.toggle('subtle-accent', keyboard);
  $('#record-button').classList.toggle('recording', recording); $('#record-button').setAttribute('aria-pressed', String(recording));
  $('#keyboard-status').textContent = keyboard ? `PC鍵盤 A–K · Z / X 音域 · C${keyOctave}` : 'Space 再生 / 停止';
  const clip = activeClip(), pattern = activePattern();
  $('#selection-summary').textContent = clip && pattern ? `${pattern.name} · ${fmt(clip.start / project.beatsPerBar + 1)}小節目 / ${fmt(clip.length / project.beatsPerBar)}小節` : '空いた場所をダブルクリックして音型を置く';
}

function renderTracks() {
  const scroll = $('#track-headers').scrollTop;
  $('#track-headers').innerHTML = project.tracks.map((track,index) => `<div class="track-header ${track.id === trackId ? 'selected':''}" data-track="${esc(track.id)}" style="--track-color:${esc(track.color)}">
    <div class="track-top"><span class="track-index">${String(index + 1).padStart(2,'0')}</span><button class="track-name" data-action="select-track" data-id="${esc(track.id)}" title="トラックを選択">${esc(track.name)}</button><span class="track-instrument">${esc(instruments.find(i => i.id === track.instrument)?.name ?? track.instrument)}</span><button class="track-switch ${track.mute?'active':''}" data-action="mute-track" data-id="${esc(track.id)}" aria-label="${esc(track.name)}をミュート" aria-pressed="${track.mute}">M</button><button class="track-switch solo ${track.solo?'active':''}" data-action="solo-track" data-id="${esc(track.id)}" aria-label="${esc(track.name)}をソロ" aria-pressed="${track.solo}">S</button></div>
    <div class="track-mix"><label>音量<input type="range" min="0" max="2" step="0.01" value="${track.gain}" data-track-mix="gain" data-id="${esc(track.id)}" aria-label="${esc(track.name)}の音量"><output>${Math.round(track.gain*100)}</output></label><label>定位<input class="pan" type="range" min="-1" max="1" step="0.01" value="${track.pan}" data-track-mix="pan" data-id="${esc(track.id)}" aria-label="${esc(track.name)}の定位"></label></div></div>`).join('');
  $('#track-headers').scrollTop = scroll;
}

function clipPreview(pattern, length) {
  const notes = patternNotes(pattern); if (!notes.length) return '';
  const low = Math.min(...notes.map(n=>n.pitch)), high = Math.max(low+12,...notes.map(n=>n.pitch));
  const sourceLength=resolvedPattern(pattern)?.length??pattern.length,preview=[];
  for(let offset=0;offset<length&&preview.length<500;offset+=sourceLength)for(const note of notes) {
    const start=offset+note.start;if(start>=length||preview.length>=500)continue;
    preview.push(`<rect x="${100*start/length}" y="${24-(note.pitch-low)/(high-low)*22}" width="${Math.max(.6,100*Math.min(note.duration,length-start)/length)}" height="2" fill="currentColor"/>`);
  }
  return `<svg viewBox="0 0 100 28" preserveAspectRatio="none" aria-hidden="true">${preview.join('')}</svg>`;
}

function renderTimeline() {
  document.documentElement.style.setProperty('--beat-px',`${timelineZoom}px`);
  const width = Math.max(project.lengthBeats*timelineZoom, $('#timeline-scroll').clientWidth - 1);
  $('#timeline').style.width = `${width}px`;
  const markers = [];
  const barStep = Math.max(1,2**Math.ceil(Math.log2(48/(timelineZoom*project.beatsPerBar))));
  for (let beat = 0; beat < project.lengthBeats; beat += project.beatsPerBar) {
    const bar = Math.round(beat/project.beatsPerBar);
    if (bar % barStep === 0) markers.push(`<span class="ruler-marker" style="left:${beat*timelineZoom}px">${bar+1}</span>`);
  }
  if (project.loop.enabled) markers.push(`<div class="loop-shade" style="left:${project.loop.start*timelineZoom}px;width:${(project.loop.end-project.loop.start)*timelineZoom}px"></div>`);
  $('#ruler').innerHTML = markers.join('');
  $('#timeline-lanes').innerHTML = project.tracks.map(track => `<div class="timeline-lane ${track.id===trackId?'selected':''}" data-lane="${esc(track.id)}" style="--beat-px:${timelineZoom}px">${project.clips.filter(c=>c.trackId===track.id).map(clip => {
    const pattern = project.patterns.find(p=>p.id===clip.patternId); if (!pattern) return '';
    const links = project.clips.filter(c=>c.patternId===pattern.id).length;
    return `<div class="clip ${clip.id===clipId?'selected':''}" role="button" tabindex="0" data-clip="${esc(clip.id)}" aria-label="${esc(pattern.name)}、${fmt(clip.start/project.beatsPerBar+1)}小節目、${fmt(clip.length/project.beatsPerBar)}小節" style="left:${clip.start*timelineZoom}px;width:${Math.max(10,clip.length*timelineZoom)}px;--clip-color:${esc(track.color)}"><div class="clip-name">${esc(pattern.name)}${links>1?`<span class="clip-link" title="同じ音型を${links}か所で使用">↔ ${links}</span>`:''}</div>${clipPreview(pattern,clip.length)}<div class="clip-handle" data-resize-clip="${esc(clip.id)}" aria-label="クリップの長さを変更"></div></div>`;
  }).join('')}</div>`).join('');
}

function fitNotes() {
  const notes = patternNotes(activePattern());
  if (notes.length) { const low = Math.min(...notes.map(n=>n.pitch)); const high = Math.max(...notes.map(n=>n.pitch)); pitchLow = clamp(Math.floor(low)-6,0,96); pitchHigh = clamp(Math.max(pitchLow+23,Math.ceil(high)+6),23,127); }
  else { pitchLow=48; pitchHigh=83; }
  renderEditor();
  const viewport = $('#piano-viewport');
  const center = notes.length ? (Math.min(...notes.map(n=>n.pitch))+Math.max(...notes.map(n=>n.pitch)))/2 : 64;
  viewport.scrollTop = Math.max(0,(pitchHigh-center)*18 - viewport.clientHeight/2 + 24);
}

function renderEditor() {
  const pattern = activePattern(), notes = patternNotes(pattern), direct = isDirect(pattern);
  $('#editor-empty').hidden = !!pattern; $('#piano').hidden = !pattern;
  $('#editor-title').textContent = pattern?.name ?? '音型';
  const banner = $('#pattern-edit-banner');
  const links = project.clips.filter(c=>c.patternId===pattern?.id).length;
  banner.hidden = !pattern || (direct && links < 2);
  if (pattern && !direct) banner.innerHTML = `<span>規則から作った音型です。音符を直接直すときは確定します。</span><button data-action="materialize">音符に確定</button>`;
  else if (pattern && links > 1) banner.innerHTML = `<span>この音型は${links}か所で共有。音符の変更はすべてに反映されます。</span><button data-action="detach">この配置だけ独立</button>`;
  if (!pattern) { renderNoteFields(); return; }
  const length = resolvedPattern(pattern)?.length ?? pattern.length;
  const width = Math.max(length*noteZoom+58,$('#piano-viewport').clientWidth-1);
  const height = (pitchHigh-pitchLow+1)*18+24;
  $('#piano').style.width = `${width}px`; $('#piano').style.height = `${height}px`;
  $('#piano-keys').innerHTML = Array.from({length:pitchHigh-pitchLow+1},(_,i)=>pitchHigh-i).map(p=>`<div class="piano-key ${[1,3,6,8,10].includes(p%12)?'black':''} ${p%12===0?'c':''}" data-key-pitch="${p}" title="${pitchLabel(p)} を試聴">${p%12===0 || (pitchHigh-p <= 2) ? pitchLabel(p):''}</div>`).join('');
  const ruler=[];
  for(let beat=0;beat<length;beat+=project.beatsPerBar) ruler.push(`<span class="ruler-marker" style="left:${58+beat*noteZoom}px">${Math.floor(beat/project.beatsPerBar)+1}</span>`);
  $('#piano-ruler').innerHTML=ruler.join('');
  $('#note-grid').style.setProperty('--note-px',`${noteZoom}px`); $('#note-grid').style.setProperty('--quantum',quantize||1);
  $('#note-grid').innerHTML=Array.from({length:pitchHigh-pitchLow+1},(_,i)=>pitchHigh-i).filter(p=>[1,3,6,8,10].includes(p%12)).map(p=>`<div class="pitch-stripe" style="top:${(pitchHigh-p)*18}px"></div>`).join('');
  $('#notes').innerHTML=notes.map(note=>`<div class="note ${noteIds.has(note.id)?'selected':''} ${direct?'':'generated'}" data-note="${esc(note.id)}" title="${pitchLabel(note.pitch)} · ${fmt(note.start)}拍 / ${fmt(note.duration)}拍 · 強さ${fmt(note.velocity)}" style="left:${58+note.start*noteZoom}px;top:${24+(pitchHigh-note.pitch)*18+2}px;width:${Math.max(6,note.duration*noteZoom)}px;opacity:${.5+note.velocity*.5}">${note.duration*noteZoom>27?esc(pitchLabel(note.pitch)):''}${direct?'<div class="note-handle"></div>':''}</div>`).join('');
  renderNoteFields(); updatePlayhead();
}

function renderNoteFields() {
  const pattern=activePattern(), notes=patternNotes(pattern).filter(n=>noteIds.has(n.id)), first=notes[0], editable=isDirect(pattern)&&!!first;
  $('#note-selection-label').textContent=notes.length ? `${notes.length}音を選択 · ${first ? pitchLabel(first.pitch):''}` : 'ダブルクリックで追加 · ドラッグで移動 · 端で長さを変更';
  for(const field of ['pitch','start','duration','velocity']) { const el=$(`#note-${field}`); el.disabled=!editable; if(document.activeElement!==el)el.value=first?fmt(first[field],4):''; }
  $('[data-action="delete-note"]').disabled=!editable;
}

const field = (label,control,hint='') => `<label class="field"><span>${label}</span>${control}${hint?`<small>${hint}</small>`:''}</label>`;
const input = (scope,key,value,{min, max,step=1,type='number'}={}) => `<input type="${type}" data-scope="${scope}" data-field="${key}" value="${esc(value)}" ${min!==undefined?`min="${min}"`:''} ${max!==undefined?`max="${max}"`:''} step="${step}">`;
const option = (id,label,selected) => `<option value="${esc(id)}" ${id===selected?'selected':''}>${esc(label)}</option>`;
function rangeField(label,scope,key,value,min,max,step=0.01) {
  return `<div class="range-field"><label>${label}</label><input type="range" data-scope="${scope}" data-field="${key}" value="${value}" min="${min}" max="${max}" step="${step}" aria-label="${label}"><input type="number" data-scope="${scope}" data-field="${key}" value="${value}" min="${min}" max="${max}" step="${step}" aria-label="${label}の値"></div>`;
}

function renderInspector() {
  const container=$('#inspector-content'), scroll=container.scrollTop;
  $$('.inspector-tabs button').forEach(b=>b.setAttribute('aria-selected',String(b.dataset.tab===inspectorTab)));
  const pattern=activePattern(), clip=activeClip(), track=activeTrack();
  if(inspectorTab==='pattern') container.innerHTML=renderPatternInspector(pattern,clip);
  else if(inspectorTab==='sound') container.innerHTML=renderSoundInspector(track);
  else container.innerHTML=renderAutomationInspector(track);
  container.scrollTop=scroll;
}
function $$(selector) { return [...document.querySelectorAll(selector)]; }

function renderPatternInspector(pattern,clip) {
  if(!pattern||!clip) return `<h3 class="inspector-heading">音型から、曲を育てる</h3><p class="inspector-note">トラックの空いた場所をダブルクリックして音型を置きます。<br><br>音符を直接描いても、規則から作っても。同じ音型を並べ、少しずつ変えて曲にできます。</p><button class="wide-button" data-action="add-pattern">＋ 音型を置く</button><button class="wide-button" data-action="example">制作例を開く</button>`;
  const generator=pattern.generator, links=project.clips.filter(c=>c.patternId===pattern.id).length;
  const transformLabels={transpose:'移調（半音）',rotate:'回転（拍）',reverse:'逆から演奏',stretch:'時間を伸縮（倍）',invert:'音程を反転（中心音高）',probability:'音を間引く（0–1）'};
  return `<section><h3 class="inspector-heading">音型 <small>PATTERN</small></h3>${field('名前',input('pattern','name',pattern.name,{type:'text'}))}<div class="field-row">${field('長さ（拍）',input('pattern','length',pattern.length,{min:.25,max:1024,step:.25}))}${field('配置の長さ（拍）',input('clip','length',clip.length,{min:.25,max:project.lengthBeats-clip.start,step:.25}))}</div><div class="link-count">↔ <b>${links}か所</b>で同じ音型を使用</div>${links>1?`<button class="wide-button" data-action="detach">この配置だけ独立させる</button>`:''}</section>
    <section><h3 class="inspector-heading">規則で作る <small>SEED</small></h3>${field('作り方',`<select data-scope="generator-kind">${option('','音符を直接描く',generator?.kind??'')}${option('euclid','等間隔に散らすリズム',generator?.kind)}${option('arpeggio','音階をたどる',generator?.kind)}${option('chords','和音をつなぐ',generator?.kind)}</select>`)}${generator?renderGenerator(generator,pattern):'<p class="inspector-note">下の鍵盤へダブルクリックして音符を追加できます。</p>'}
    ${generator||pattern.transforms.length?`<button class="wide-button subtle-accent" data-action="materialize">音符に確定して、手で直す</button><p class="inspector-note">現在の生成結果を音符として残します。元に戻すこともできます。</p>`:''}</section>
    <section><h3 class="inspector-heading">変化を重ねる <small>TRANSFORM</small></h3>${pattern.transforms.map((t,i)=>`<div class="transform"><select data-transform-kind="${i}">${Object.entries(transformLabels).map(([id,label])=>option(id,label,t.kind)).join('')}</select>${t.kind==='reverse'?'<span class="transform-fixed">全体</span>':`<input type="number" data-transform-amount="${i}" value="${t.amount}" step="${t.kind==='probability'?.05:.25}" aria-label="変化の量">`}<button data-action="remove-transform" data-index="${i}" aria-label="変形を削除">×</button></div>`).join('')}<button class="wide-button" data-action="add-transform">＋ 変化を追加</button>${pattern.transforms.length?'<p class="inspector-note">上から順に適用します。音高は12半音で1オクターブ。</p>':''}</section>
    <section><h3 class="inspector-heading">この配置 <small>CLIP</small></h3><div class="field-row">${field('開始（拍）',input('clip','start',clip.start,{min:0,max:project.lengthBeats-clip.length,step:.25}))}${field('移調（半音）',input('clip','transpose',clip.transpose,{min:-96,max:96,step:.01}))}</div>${rangeField('この配置の音量','clip','gain',clip.gain,0,2)}<div class="inspector-buttons"><button data-action="duplicate-clip">同じ音型を複製</button><button data-action="duplicate-independent">独立した複製</button></div></section>`;
}

function renderGenerator(g,pattern) {
  const rhythmic=g.kind==='euclid',arpeggio=g.kind==='arpeggio',seeded=pattern.transforms.some(t=>t.kind==='probability');
  return `${g.kind!=='chords'?`<div class="field-row">${field('分割数',input('generator','steps',g.steps,{min:1,max:256}))}${rhythmic?field('鳴らす数',input('generator','pulses',g.pulses,{min:0,max:g.steps})):''}</div>`:''}<div class="field-row">${field('中心音高',input('generator','root',g.root,{min:0,max:108,step:.01}))}${arpeggio?field('音域（オクターブ）',input('generator','octaves',g.octaves,{min:1,max:4})):''}</div>${rhythmic?field('リズムのずれ',input('generator','rotation',g.rotation,{min:-256,max:256})):field(g.kind==='chords'?'和音の進行':'音階の順番',`<input type="text" data-scope="generator" data-field="degrees" value="${esc(g.degrees.join(', '))}">`,'0は音階の最初。1、2…で上へ、負の数で下へ。')}
    <div class="field-row">${field('音の長さ（比率）',input('generator','gate',g.gate,{min:.01,max:1,step:.01}))}${seeded?field('間引きの種',input('generator','seed',g.seed,{min:0,max:2147483647})):''}</div>${rangeField('音の強さ','generator','velocity',g.velocity,.01,1)}<p class="inspector-note">${rhythmic?'ひとつの音高を、指定した回数で均等に散らします。':`${project.tuning.divisions}分割の音律と、設定した音階で作ります。`}${seeded?'同じ間引きの種から同じ結果が生まれます。':''}</p>`;
}

function renderSoundInspector(track) {
  if(!track) return '<p class="inspector-note">トラックを追加して音色を選びます。</p><button class="wide-button" data-action="add-track">＋ トラック</button>';
  const patch=track.patch,asset=project.assets.find(a=>a.id===track.assetId);
  return `<section><h3 class="inspector-heading">トラック <small>TRACK</small></h3><div class="track-detail-heading"><input type="color" data-scope="track" data-field="color" value="${esc(track.color)}" aria-label="トラックの色"><input type="text" data-scope="track" data-field="name" value="${esc(track.name)}" aria-label="トラック名"></div>${field('楽器',`<select data-scope="track" data-field="instrument">${instruments.map(i=>option(i.id,i.name,track.instrument)).join('')}</select>`)}${track.instrument==='sample'?`<button class="wide-button" data-action="import-wav">WAV素材を読み込む</button>${asset?`<p class="asset-info">${esc(asset.name)}<br>${asset.sampleRate??48000} Hz · ${asset.channels??'?'}ch${asset.frames?` · ${fmt(asset.frames/(asset.sampleRate??48000))}秒`:''}</p>`:'<p class="inspector-note emphasis">WAV素材を読み込むと演奏できます。</p>'}`:''}${rangeField('音量','track','gain',track.gain,0,2)}${rangeField('定位　左 ← → 右','track','pan',track.pan,-1,1)}<div class="track-actions"><div><button data-action="track-up">↑ 上へ</button><button data-action="track-down">↓ 下へ</button></div><button class="text-danger" data-action="delete-track">削除</button></div></section>
    <section><h3 class="inspector-heading">音の輪郭 <small>ENVELOPE</small></h3>${rangeField('立ち上がり（秒）','patch','attack',patch.attack,.001,10,.001)}${rangeField('余韻（秒）','patch','release',patch.release,.005,20,.005)}${rangeField('明るさ','patch','tone',patch.tone,0,1)}</section>
    <section><h3 class="inspector-heading">フィルター <small>FILTER</small></h3>${rangeField('開き（Hz）','patch','cutoff',patch.cutoff,20,20000,10)}${rangeField('共鳴','patch','resonance',patch.resonance,0,1)}</section>
    <section><h3 class="inspector-heading">繰り返す余韻 <small>DELAY</small></h3>${rangeField('送る量','patch','delaySend',patch.delaySend,0,1)}${field('間隔（拍）',`<select data-scope="patch" data-field="delayBeats">${[[.03125,'1/32拍'],[.0625,'1/16拍'],[.125,'1/8拍'],[.25,'1/4拍'],[.3333333333,'1/3拍'],[.5,'1/2拍'],[.75,'3/4拍'],[1,'1拍'],[1.5,'1.5拍'],[2,'2拍'],[4,'4拍'],[8,'8拍']].filter(([v])=>v*60/project.tempo<=4).map(([v,label])=>option(v,label,patch.delayBeats)).join('')}</select>`)}${rangeField('繰り返しの量','patch','delayFeedback',patch.delayFeedback,0,.92)}</section>`;
}

function automationRange(parameter) { return parameter==='pan'?[-1,1]:parameter==='cutoff'?[20,20000]:[0,2]; }
function autoY(value) { const [min,max]=automationRange(autoParameter); const normalized=autoParameter==='cutoff'?Math.log(value/min)/Math.log(max/min):(value-min)/(max-min); return 124-clamp(normalized,0,1)*106; }
function autoValue(y) { const [min,max]=automationRange(autoParameter),value=clamp((124-y)/106,0,1); return autoParameter==='cutoff'?Math.round(min*(max/min)**value):Math.round((min+value*(max-min))*100)/100; }
function activeAutoPoints() { return activeTrack()?.automation.find(a=>a.parameter===autoParameter)?.points??[]; }
function renderAutomationInspector(track) {
  if(!track)return '<p class="inspector-note">トラックを選択してください。</p>';
  const points=activeAutoPoints(),[min,max]=automationRange(autoParameter);
  return `<section><h3 class="inspector-heading">${esc(track.name)}の動き <small>AUTOMATION</small></h3><p class="inspector-note">曲の進行に合わせて、音量や音色を変えます。線上をダブルクリックして点を追加し、ドラッグで動かせます。</p>${field('変えるもの',`<select id="auto-parameter">${option('gain','音量',autoParameter)}${option('pan','定位',autoParameter)}${option('cutoff','フィルターの開き',autoParameter)}</select>`)}<svg id="auto-chart" class="auto-chart" viewBox="0 0 240 145" role="img" aria-label="オートメーション編集、横軸は曲の時間、縦軸は値"><line x1="16" y1="18" x2="229" y2="18" stroke="#3e4f34"/><line x1="16" y1="71" x2="229" y2="71" stroke="#33462a"/><line x1="16" y1="124" x2="229" y2="124" stroke="#3e4f34"/><text x="17" y="11">${max}</text><text x="17" y="140">1</text><text x="211" y="140">${fmt(project.lengthBeats/project.beatsPerBar)}小節</text>${points.length?`<polyline points="${points.map(p=>`${16+p.beat/project.lengthBeats*213},${autoY(p.value)}`).join(' ')}" fill="none" stroke="#a8b883" stroke-width="1.5"/>`:''}${points.map((p,i)=>`<circle data-auto-point="${i}" class="${i===autoSelected?'selected':''}" cx="${16+p.beat/project.lengthBeats*213}" cy="${autoY(p.value)}" r="4"/>`).join('')}</svg><div class="field-row"><span class="inspector-note">開始からの拍</span><span class="inspector-note">値</span></div><div class="auto-points">${points.map((p,i)=>`<div class="auto-point ${i===autoSelected?'selected':''}"><input data-auto-beat="${i}" type="number" min="0" max="${project.lengthBeats}" step=".25" value="${fmt(p.beat)}" aria-label="点${i+1}の拍"><input data-auto-value="${i}" type="number" min="${min}" max="${max}" step="${autoParameter==='cutoff'?10:.01}" value="${fmt(p.value)}" aria-label="点${i+1}の値"><button data-action="remove-auto-point" data-index="${i}" aria-label="点を削除">×</button></div>`).join('')}</div><button class="wide-button" data-action="add-auto-point">＋ 点を追加</button>${points.length?'<button class="wide-button text-danger" data-action="clear-automation">この動きを消す</button>':''}</section>`;
}

function selectClip(id) {
  const changed=activeClip()?.patternId!==project.clips.find(c=>c.id===id)?.patternId;
  clipId=id; trackId=activeClip()?.trackId??trackId; noteIds.clear(); render(); if(changed)fitNotes(); scrollSelectedTrack();
}
function selectTrack(id) { trackId=id; if(activeClip()?.trackId!==id)clipId=null; noteIds.clear(); render(); scrollSelectedTrack(); }
function fitSong() {
  songFitted=true;timelineZoom=clamp(($('#timeline-scroll').clientWidth-10)/project.lengthBeats,.1,64);
  $('#timeline-zoom').value=timelineZoom;$('#timeline-scroll').scrollLeft=0;renderTimeline();updatePlayhead();
}
function scrollSelectedTrack() {
  const index=project.tracks.findIndex(track=>track.id===trackId);if(index<0)return;
  const scroller=$('#timeline-scroll'),visibleHeight=scroller.clientHeight-32;
  const top=index*68,bottom=top+68;
  if(top<scroller.scrollTop||bottom>scroller.scrollTop+visibleHeight)scroller.scrollTop=Math.max(0,top-(visibleHeight-68)/2);
  $('#track-headers').scrollTop=scroller.scrollTop;
}
function focusArea(area) {
  viewFocus=viewFocus===area?null:area;
  $('.workspace').classList.toggle('arrangement-focus',viewFocus==='arrangement');
  $('.workspace').classList.toggle('editor-focus',viewFocus==='editor');
  $('#focus-arrangement').textContent=viewFocus==='arrangement'?'元の高さへ':'編曲を広く';
  $('#focus-editor').textContent=viewFocus==='editor'?'元の高さへ':'音型を広く';
  if(songFitted)fitSong();else renderTimeline();fitNotes();scrollSelectedTrack();
}
function addPatternAt(id=trackId,start=currentBeat()) {
  if(!id) { const track=makeTrack(project.tracks.length); id=track.id; project={...project,tracks:[...project.tracks,track]}; }
  const length=Math.min(16,project.lengthBeats), pattern=makePattern(length);
  pattern.name=`音型 ${project.patterns.length+1}`;
  const clip=makeClip(id,pattern,clamp(snap(start,project.beatsPerBar),0,project.lengthBeats-length));
  clipId=clip.id; trackId=id; noteIds.clear(); inspectorTab='pattern';
  commit({...project,patterns:[...project.patterns,pattern],clips:[...project.clips,clip]},'音型を追加'); fitNotes();
}
function duplicateSelected(independent=false) {
  const result=duplicateClip(project,clipId,independent); if(!result.clipId)return;
  clipId=result.clipId; noteIds.clear(); commit(result.project,independent?'独立した音型を複製':'クリップを複製');
}
async function materialize() {
  const pattern=activePattern(); if(!pattern||isDirect(pattern))return;
  await queue.flush();
  const snapshot=project;
  const response=await api('materialize',{project:snapshot,patternId:pattern.id});
  if(project!==snapshot) {queue.schedule(project);throw new Error('確定の途中で編集が変わりました。もう一度「音符に確定」を押してください');}
  noteIds.clear(); commit(response.project,'生成結果を音符に確定'); resolved=response.resolved;
  render(); fitNotes(); toast('音符に確定しました。音符をドラッグして直せます');
}

function currentBeat() {
  if(!status.playing)return status.beat??0;
  let beat=(status.beat??0)+(performance.now()-statusTime)/1000*project.tempo/60;
  if(project.loop.enabled && beat>=project.loop.end)beat=project.loop.start+(beat-project.loop.start)%(project.loop.end-project.loop.start);
  return clamp(beat,0,project.lengthBeats);
}
function updatePlayhead() {
  const beat=currentBeat(),clip=activeClip(),pattern=activePattern();
  $('#position').textContent=beatLabel(beat,project.beatsPerBar);
  $('#arrange-playhead').style.transform=`translateX(${beat*timelineZoom}px)`;
  if(clip&&pattern) {
    const length=resolvedPattern(pattern)?.length??pattern.length;
    const local=(beat-clip.start)%length;
    $('#piano-playhead').hidden=beat<clip.start||beat>clip.start+clip.length;
    $('#piano-playhead').style.left=`${58+local*noteZoom}px`;
  } else $('#piano-playhead').hidden=true;
}
function animate() { updatePlayhead(); requestAnimationFrame(animate); }

async function transport(action,beat) {
  if(action==='play')await queue.flush();
  const response=await api('transport',{action,...(beat!==undefined?{beat}:{})});
  if(typeof response.playing==='boolean')applyStatus(response); else await pollStatus();
}
async function stopForReplace() {
  if(status.engine.available) {await transport('stop');await panic();}
  status={...status,playing:false,beat:0};statusTime=performance.now();
}
function applyStatus(next) {
  status={...status,...next,engine:{...status.engine,...next.engine}}; statusTime=performance.now();
  const engine=status.engine,available=!!engine.available;
  $('#engine-led').className=available?'connected':'error';
  $('#engine-status').textContent=available?`音声接続 · ${engine.backend??'Native'} · ${Math.round((engine.sampleRate??48000)/1000)} kHz${engine.underruns?` · 供給遅延 ${engine.underruns}`:''}`:`音声未接続${engine.message?` · ${engine.message}`:''}`;
  $('#engine-status').title=engine.message??'';
  $('#play-button').classList.toggle('playing',status.playing);
  $('#play-button').innerHTML=status.playing?'Ⅱ <span>一時停止</span>':'▶ <span>再生</span>';
  $('#play-button').title=status.playing?'一時停止 (Space)':'再生 (Space)';
  const peaks=[status.peakL??0,status.peakR??0];
  ['#meter-left','#meter-right'].forEach((selector,i)=>{
    const value=peaks[i]; $(selector).style.setProperty('--level',`${clamp(value,0,1)*100}%`); $(selector).classList.toggle('hot',value>=.97);
  });
  $('#clip-indicator').classList.toggle('active',peaks.some(p=>p>=.999));
}
let polling=false;
async function pollStatus() {
  if(polling||!loaded)return;
  polling=true;
  try { applyStatus(await api('status')); }
  catch(error) { $('#engine-led').className='error'; $('#engine-status').textContent='サーバーへの接続が切れました'; }
  finally { polling=false; }
}

function showHelp(first=false) {
  modal(`<p class="dialog-eyebrow">AYA / 音を編む</p><h2>${first?'ひとつの音型から、曲に。':'作る、変える、並べる。'}</h2><p>音符と規則を行き来して、自分の曲を編んでいきましょう。</p><div class="first-use-steps"><div><strong>音型を作る</strong><p>トラックの空いた場所をダブルクリック。音符を描くか、「規則で作る」で種を作ります。</p></div><div><strong>変化を育てる</strong><p>移調や回転を重ねます。気になる音は「音符に確定」で直接編集できます。</p></div><div><strong>曲へ並べる</strong><p>音型を複製して配置。音色と動きを整え、保存して音源を書き出します。</p></div></div><h3>よく使う操作</h3><div class="shortcut-list"><kbd>Space / Enter</kbd><span>再生・一時停止 / 停止</span><kbd>Ctrl S / Ctrl O</kbd><span>保存 / プロジェクトを開く</span><kbd>Ctrl Z / Ctrl Shift Z</kbd><span>元に戻す / やり直す</span><kbd>Ctrl D / Delete</kbd><span>選択中の音符・クリップを複製 / 削除</span><kbd>Shift + クリック</kbd><span>音符を追加選択（空白をドラッグして範囲選択）</span><kbd>← ↑ → ↓</kbd><span>選択音符を移動（Shiftでオクターブ）</span><kbd>PC鍵盤 → A W S E D…</kbd><span>選択トラックを演奏。Z / Xで音域変更</span></div><p class="focus-note">音声はネイティブエンジンから出ます。下部に「音声接続」が出ていることを確認してください。音高は60=C4、12半音=1オクターブ。小数で微分音を指定できます。</p><div class="dialog-actions"><button data-action="example">制作例を開く</button><button class="accent" data-action="close-modal">制作を始める</button></div>`);
}
function showTuning() {
  const tuning=project.tuning;
  modal(`<p class="dialog-eyebrow">TUNING & SCALE</p><h2>曲の音律と音階</h2><p>音階をたどる音型と和音に使います。直接描いた音符の音高はそのまま保たれます。中心音高は各音型のパネルで変えられます。</p><div class="field-row">${field('1オクターブの分割数',`<input id="tuning-divisions" type="number" min="1" max="120" value="${tuning.divisions}">`)}${field('A4の基準周波数（Hz）',`<input id="tuning-reference" type="number" min="300" max="600" step=".01" value="${tuning.referenceHz}">`)}</div>${field('音階の段（0から分割数−1まで）',`<input id="tuning-scale" type="text" value="${tuning.scale.join(', ')}">`,'例: 12分割で 0, 2, 3, 5, 7, 8, 10。19分割なら0〜18から選びます。')}${field('新しい音型の中心音高（60 = C4）',`<input id="tuning-root" type="number" min="0" max="120" step=".01" value="${tuning.root}">`)}<div class="inspector-buttons"><button data-action="scale-preset" data-preset="minor">12音・短音階</button><button data-action="scale-preset" data-preset="major">12音・長音階</button><button data-action="scale-preset" data-preset="19">19音・全音階</button><button data-action="scale-preset" data-preset="31">31音・全音階</button></div><div class="dialog-actions"><button data-action="close-modal">閉じる</button><button class="accent" data-action="apply-tuning">音律を適用</button></div>`);
}
function showAddTrack() {
  modal(`<p class="dialog-eyebrow">NEW TRACK</p><h2>トラックを追加</h2>${field('楽器',`<select id="new-track-instrument">${instruments.map(i=>option(i.id,i.name,'pluck')).join('')}</select>`)}${field('名前（空欄なら楽器名）','<input id="new-track-name" type="text" placeholder="トラック名">')}<div class="dialog-actions"><button data-action="close-modal">閉じる</button><button class="accent" data-action="create-track">追加する</button></div>`);
}

function downloadBlob(data,name,type='application/json') {
  const url=URL.createObjectURL(new Blob([data],{type})),anchor=document.createElement('a');
  anchor.href=url; anchor.download=name; anchor.click(); setTimeout(()=>URL.revokeObjectURL(url),2000);
}
async function saveProject() {
  await queue.flush();
  const name=(project.name||'Aya').replace(/[<>:"/\\|?*\x00-\x1f]/g,'_');
  downloadBlob(JSON.stringify({format:'Aya',version:1,project},null,2),`${name}.aya`);
  dirty=false; renderSaveState(); toast('プロジェクトを保存しました（素材も含みます）');
}
async function openProjectFile(file) {
  if(/\.midi?$/i.test(file.name)) {await importMidi(file);return;}
  const document=JSON.parse(await file.text()),next=document.project??document;
  if(next.schemaVersion!==1||!Array.isArray(next.tracks)||!Array.isArray(next.patterns))throw new Error('Ayaのプロジェクトファイルを選んでください');
  await stopForReplace();
  const accepted=await api('compile',next); replaceProject(accepted.project,'プロジェクトを開きました');
  resolved=accepted.resolved; render(); fitNotes();
}
async function base64File(file) {
  const bytes=new Uint8Array(await file.arrayBuffer());let binary='';
  for(let i=0;i<bytes.length;i+=32768)binary+=String.fromCharCode(...bytes.subarray(i,i+32768));
  return btoa(binary);
}
async function importMidi(file) {
  if(!midiSupported)throw new Error('このバージョンではMIDIファイルの読み込みを使えません');
  const response=await api('midi/import',{name:file.name,data:await base64File(file)});
  await stopForReplace();const accepted=await api('compile',response.project);
  replaceProject(accepted.project,'MIDIを読み込みました');resolved=accepted.resolved;render();fitNotes();dirty=true;renderSaveState();
  if(response.warnings?.length)notice(response.warnings.map(w=>typeof w==='string'?w:w.message).join(' / '));
}
function confirmReplace(action) {
  if(!dirty) { guarded(action); return; }
  modal(`<h2>現在の曲を閉じますか？</h2><p>未保存の変更があります。保存してから開くこともできます。</p><div class="dialog-actions"><button data-action="close-modal">戻る</button><button id="replace-discard">保存せず進む</button><button id="replace-save" class="accent">保存して進む</button></div>`);
  $('#replace-discard').onclick=()=>{closeModal(); guarded(action);};
  $('#replace-save').onclick=()=>guarded(async()=>{await saveProject(); closeModal(); await action();});
}
async function importWav(file) {
  if(!activeTrack())throw new Error('素材を使うトラックを選択してください');
  const targetId=trackId; notice(`「${file.name}」を読み込んでいます…`);
  const response=await api('assets/wav',{name:file.name,data:await base64File(file)}),asset=response.asset??response;
  const next={...project,assets:[...project.assets.filter(a=>a.id!==asset.id),asset]};
  commit(editTrack(next,targetId,{instrument:'sample',assetId:asset.id}),'WAV素材を読み込み');
  $('#notice').hidden=true; toast('素材を読み込みました。音符のC4で原音を演奏します');
}
function showExport() {
  modal(`<p class="dialog-eyebrow">EXPORT AUDIO</p><h2>音源を書き出す</h2><p>現在のアレンジをステレオWAVにします。曲末のディレイと余韻も含めて書き出します。</p><label class="confirmation-text"><input id="export-stems" type="checkbox"> トラックごとのWAVも書き出す</label><p>${esc(project.name)} · ${fmt(project.lengthBeats/project.beatsPerBar)}小節 · ${project.tempo} BPM</p><div class="dialog-actions">${midiSupported?'<button data-action="export-midi">MIDIを書き出す</button>':''}<button data-action="close-modal">閉じる</button><button class="accent" data-action="start-export">WAVを書き出す</button></div>`);
}
async function exportAudio() {
  if(busy)return; const stems=$('#export-stems').checked; setBusy(true);
  const started=performance.now();
  modal('<p class="dialog-eyebrow">RENDERING</p><h2>音源を書き出しています</h2><div class="export-progress"><span class="spinner"></span><span id="export-elapsed">音符と余韻を計算しています…</span></div><p>この画面を閉じても処理は続きます。</p>');
  const timer=setInterval(()=>{const el=$('#export-elapsed');if(el)el.textContent=`音符と余韻を計算しています… ${Math.floor((performance.now()-started)/1000)}秒`;},1000);
  try {
    await queue.flush(); const result=await api('export',{project,stems});
    if(!result.files?.length)throw new Error('書き出したファイルが返されませんでした');
    modal(`<p class="dialog-eyebrow">EXPORT COMPLETE</p><h2>音源ができました</h2><p>${result.duration?`${fmt(result.duration)}秒 · `:''}ファイルを選んで保存してください。</p><ul class="download-list">${result.files.map(file=>`<li><a href="${esc(file.url)}" download="${esc(file.name)}">↓　${esc(file.name)}</a></li>`).join('')}</ul><div class="dialog-actions"><button class="accent" data-action="close-modal">完了</button></div>`);
    toast('書き出しが完了しました');
  } finally {clearInterval(timer);setBusy(false);}
}
async function exportMidi() {
  await queue.flush();
  const response=await api('midi/export',project);
  modal(`<p class="dialog-eyebrow">EXPORT MIDI</p><h2>MIDIを書き出しました</h2>${response.warnings?.length?`<p>${esc(response.warnings.map(w=>typeof w==='string'?w:w.message).join(' / '))}</p>`:''}<ul class="download-list">${response.files.map(file=>`<li><a href="${esc(file.url)}" download="${esc(file.name)}">↓　${esc(file.name)}</a></li>`).join('')}</ul><div class="dialog-actions"><button class="accent" data-action="close-modal">完了</button></div>`);
}

let auditionChain=Promise.resolve();
function sendInput(event) {
  auditionChain=auditionChain.catch(()=>{}).then(()=>api('audition',event)).catch(error=>fail(error));
}
async function audition(pitch,duration=.3) {
  if(!activeTrack())return;
  await api('audition',{trackId,pitch,velocity:.72,duration});
}
function pressKey(code,pitch) {
  if(pressedKeys.has(code)||!activeTrack())return;
  const eventId=uid('key'),timestampMs=performance.now(),pattern=activePattern(),clip=activeClip();
  const entry={eventId,pitch,timestampMs,beat:currentBeat(),patternId:recording&&isDirect(pattern)?pattern.id:null,clipStart:clip?.start??0,patternLength:pattern?.length??16,trackId};
  pressedKeys.set(code,entry);
  sendInput({kind:'on',eventId,trackId,pitch,velocity:.75,timestampMs,sequence:++inputSequence});
}
function releaseKey(code) {
  const entry=pressedKeys.get(code);if(!entry)return;
  pressedKeys.delete(code); const timestampMs=performance.now();
  sendInput({kind:'off',eventId:entry.eventId,timestampMs,sequence:++inputSequence});
  if(entry.patternId) {
    const pattern=project.patterns.find(p=>p.id===entry.patternId);if(!isDirect(pattern))return;
    const local=((entry.beat-entry.clipStart)%pattern.length+pattern.length)%pattern.length;
    const start=clamp(snap(local,quantize),0,pattern.length-.03125);
    const duration=clamp(snap((timestampMs-entry.timestampMs)/1000*project.tempo/60,quantize),Math.min(Math.max(quantize,.03125),pattern.length-start),pattern.length-start);
    const note={id:uid('note'),start,duration,pitch:entry.pitch,velocity:.75};
    noteIds=new Set([note.id]);commit(editPattern(project,pattern.id,{notes:[...pattern.notes,note]}),'演奏を録音');
  }
}
async function releasePressedKeys() {for(const code of [...pressedKeys.keys()])releaseKey(code);await auditionChain;}
async function panic() {await releasePressedKeys();await api('panic',{});}

async function onAction(action,button) {
  if(!loaded&&action!=='reconnect'&&action!=='dismiss-notice'&&action!=='help'&&action!=='close-modal')return;
  switch(action) {
    case 'dismiss-notice': $('#notice').hidden=true; break;
    case 'close-modal': closeModal(); break;
    case 'reconnect': await boot(); break;
    case 'help': showHelp(); break;
    case 'new': confirmReplace(async()=>{closeModal();await stopForReplace();replaceProject(blankProject(),'空の曲を作りました');});break;
    case 'example': confirmReplace(async()=>{closeModal();const next=await api('example');await stopForReplace();replaceProject(next.project??next,'制作例を開きました');});break;
    case 'open': confirmReplace(()=>{$('#open-file').click();});break;
    case 'save': await saveProject();break;
    case 'export': showExport();break;
    case 'start-export': await exportAudio();break;
    case 'export-midi': await exportMidi();break;
    case 'play': await transport(status.playing?'pause':'play');break;
    case 'stop': recording=false;await transport('stop');await panic();renderTop();break;
    case 'rewind': await transport('seek',0);break;
    case 'seek-dialog': modal(`<h2>再生位置へ移動</h2>${field('小節（1から）',`<input id="seek-bar" type="number" min="1" max="${project.lengthBeats/project.beatsPerBar+1}" step=".25" value="${fmt(currentBeat()/project.beatsPerBar+1)}">`)}<div class="dialog-actions"><button class="accent" data-action="apply-seek">移動する</button></div>`);break;
    case 'apply-seek': await transport('seek',clamp((number($('#seek-bar').value,1)-1)*project.beatsPerBar,0,project.lengthBeats));closeModal();break;
    case 'record': if(!recording&&!isDirect(activePattern())){notice('録音する音型を選んでください。規則の音型は、先に「音符に確定」します。');break;}if(!recording&&!status.engine.available)throw new Error('録音するには音声エンジンへの接続が必要です');recording=!recording;keyboard=true;renderTop();if(recording&&!status.playing)await transport('play');toast(recording?'PC鍵盤の演奏を選択した音型へ録音します':'録音を終えました');break;
    case 'keyboard': keyboard=!keyboard; if(!keyboard)await releasePressedKeys(); renderTop();break;
    case 'fit-notes': fitNotes();break;
    case 'fit-song': fitSong();break;
    case 'focus-arrangement': focusArea('arrangement');break;
    case 'focus-editor': focusArea('editor');break;
    case 'add-track': showAddTrack();break;
    case 'create-track': { const requested=$('#new-track-instrument').value,track=makeTrack(project.tracks.length,requested);if(requested==='sample')track.instrument='pluck';track.name=$('#new-track-name').value.trim()||track.name;trackId=track.id;clipId=null;inspectorTab='sound';commit({...project,tracks:[...project.tracks,track]},'トラックを追加');closeModal();if(requested==='sample')$('#wav-file').click();break; }
    case 'select-track': selectTrack(button.dataset.id);inspectorTab='sound';renderInspector();break;
    case 'mute-track': case 'solo-track': {const track=project.tracks.find(t=>t.id===button.dataset.id),field=action==='mute-track'?'mute':'solo';if(track)commit(editTrack(project,track.id,{[field]:!track[field]}),field==='mute'?'ミュートを変更':'ソロを変更');break;}
    case 'track-up': case 'track-down': commit(reorderTrack(project,trackId,action==='track-up'?-1:1),'トラックを並べ替え');break;
    case 'delete-track': { const track=activeTrack();if(!track)break;modal(`<h2>「${esc(track.name)}」を削除しますか？</h2><p>このトラックの配置も削除します。あとから元に戻せます。</p><div class="dialog-actions"><button data-action="close-modal">戻る</button><button class="text-danger" data-action="confirm-delete-track">削除する</button></div>`);break;}
    case 'confirm-delete-track': commit(removeTrack(project,trackId),'トラックを削除');closeModal();break;
    case 'add-pattern': addPatternAt();break;
    case 'duplicate-clip': duplicateSelected();break;
    case 'duplicate-independent': duplicateSelected(true);break;
    case 'delete-clip': if(clipId){commit({...project,clips:project.clips.filter(c=>c.id!==clipId)},'クリップを削除');}break;
    case 'detach': {const next=detachClip(project,clipId);noteIds.clear();commit(next,'音型を独立');toast('この配置だけの音型にしました');break;}
    case 'materialize': await materialize();break;
    case 'add-transform': if(activePattern())commit(editPattern(project,activePattern().id,{transforms:[...activePattern().transforms,{kind:'transpose',amount:12}]}),'変化を追加');break;
    case 'remove-transform': if(activePattern())commit(editPattern(project,activePattern().id,{transforms:activePattern().transforms.filter((_,i)=>i!==Number(button.dataset.index))}),'変化を削除');break;
    case 'delete-note': if(activePattern())commit(removeNotes(project,activePattern().id,[...noteIds]),'音符を削除');break;
    case 'undo': if(history.undo()){project=history.present;dirty=true;queue.schedule(project);saveBrowserRecovery();render();}break;
    case 'redo': if(history.redo()){project=history.present;dirty=true;queue.schedule(project);saveBrowserRecovery();render();}break;
    case 'tuning': showTuning();break;
    case 'scale-preset': {const preset=button.dataset.preset,div=preset==='19'?19:preset==='31'?31:12;$('#tuning-divisions').value=div;$('#tuning-scale').value=preset==='major'?'0, 2, 4, 5, 7, 9, 11':preset==='minor'?'0, 2, 3, 5, 7, 8, 10':Array.from({length:div},(_,i)=>i).join(', ');break;}
    case 'apply-tuning': {const divisions=number($('#tuning-divisions').value),scale=$('#tuning-scale').value.split(/[,\s]+/).filter(Boolean).map(Number);if(!Number.isInteger(divisions)||divisions<1||divisions>120||!scale.length||scale.some((s,i)=>!Number.isInteger(s)||s<0||s>=divisions||(i&&s<=scale[i-1])))throw new Error('音階は0から分割数−1までの整数を、小さい順に入力してください');commit({...project,tuning:{divisions,referenceHz:clamp(number($('#tuning-reference').value,440),300,600),root:clamp(number($('#tuning-root').value,60),0,120),scale}},'音律を変更');closeModal();break;}
    case 'import-wav': $('#wav-file').click();break;
    case 'add-auto-point': {const points=activeAutoPoints(),beat=points.length?Math.min(project.lengthBeats,points.at(-1).beat+project.beatsPerBar):0,value=autoParameter==='cutoff'?activeTrack().patch.cutoff:activeTrack()[autoParameter];commit(putAutomation(project,trackId,autoParameter,[...points,{beat,value}]),'動きの点を追加');break;}
    case 'remove-auto-point': commit(putAutomation(project,trackId,autoParameter,activeAutoPoints().filter((_,i)=>i!==Number(button.dataset.index))),'動きの点を削除');break;
    case 'clear-automation': commit(editTrack(project,trackId,{automation:activeTrack().automation.filter(a=>a.parameter!==autoParameter)}),'動きを削除');break;
  }
}

async function onChange(target) {
  if(!loaded)return;
  if(target.id==='project-name') {commit({...project,name:target.value.trim()||'名前のない曲'},'曲名を変更');return;}
  if(target.id==='tempo') {commit({...project,tempo:clamp(number(target.value,108),30,300)},'テンポを変更');return;}
  if(target.id==='master-gain') {commit({...project,masterGain:clamp(number(target.value,.8),0,2)},'マスター音量を変更');return;}
  if(['loop-enabled','loop-start','loop-end'].includes(target.id)) {
    const start=clamp((number($('#loop-start').value,1)-1)*project.beatsPerBar,0,project.lengthBeats-.25);
    const end=clamp((number($('#loop-end').value,5)-1)*project.beatsPerBar,start+.25,project.lengthBeats);
    commit({...project,loop:{enabled:$('#loop-enabled').checked,start,end}},'ループを変更');return;
  }
  if(target.id==='song-bars') {
    const minimum=Math.max(project.beatsPerBar,...project.clips.map(c=>c.start+c.length),...project.tracks.flatMap(t=>t.automation.flatMap(a=>a.points.map(p=>p.beat))));
    const lengthBeats=clamp(number(target.value,16)*project.beatsPerBar,minimum,4096);
    if(lengthBeats!==number(target.value)*project.beatsPerBar)toast('配置と動きが収まる長さまでにしました');
    commit({...project,lengthBeats,loop:{...project.loop,start:Math.min(project.loop.start,lengthBeats-.25),end:Math.min(project.loop.end,lengthBeats)}},'曲の長さを変更');return;
  }
  if(target.id==='quantize') {quantize=number(target.value,.25);for(const id of ['#note-start','#note-duration'])$(id).step=quantize||.01;renderEditor();return;}
  if(target.id==='auto-parameter') {autoParameter=target.value;autoSelected=-1;renderInspector();return;}
  if(target.dataset.trackMix) {commit(editTrack(project,target.dataset.id,{[target.dataset.trackMix]:number(target.value)}),'トラックのミックスを変更');return;}
  if(target.id.startsWith('note-')) {editSelectedNoteField(target.id.slice(5),number(target.value));return;}
  if(target.dataset.autoBeat!==undefined||target.dataset.autoValue!==undefined) {
    const index=Number(target.dataset.autoBeat??target.dataset.autoValue),points=clone(activeAutoPoints());
    const [min,max]=automationRange(autoParameter);
    if(target.dataset.autoBeat!==undefined)points[index].beat=clamp(number(target.value),0,project.lengthBeats);
    else points[index].value=clamp(number(target.value),min,max);
    commit(putAutomation(project,trackId,autoParameter,points),'動きの点を編集');return;
  }
  if(target.dataset.transformKind!==undefined||target.dataset.transformAmount!==undefined) {
    const pattern=activePattern();if(!pattern)return;
    const index=Number(target.dataset.transformKind??target.dataset.transformAmount),transforms=clone(pattern.transforms);
    if(target.dataset.transformKind!==undefined) {
      const defaults={transpose:12,rotate:1,reverse:1,stretch:2,invert:60,probability:.8};
      transforms[index]={kind:target.value,amount:defaults[target.value]};
    } else transforms[index].amount=number(target.value);
    commit(editPattern(project,pattern.id,{transforms}),'変化を編集');return;
  }
  const scope=target.dataset.scope,key=target.dataset.field;
  if(!scope)return;
  if(scope==='generator-kind') {
    const pattern=activePattern();if(!pattern)return;
    if(!target.value&&pattern.generator) {await materialize();return;}
    const generator=target.value?{kind:target.value,steps:16,pulses:5,rotation:0,root:project.tuning.root,octaves:2,gate:.7,seed:1,degrees:[0,2,4,2],velocity:.8}:null;
    commit(editPattern(project,pattern.id,{generator}),'作り方を変更');return;
  }
  let value=['text','color'].includes(target.type)?target.value:number(target.value);
  if(target.type==='number'||target.type==='range') {if(target.min!=='')value=Math.max(Number(target.min),value);if(target.max!=='')value=Math.min(Number(target.max),value);}
  if(scope==='track') {
    if(target.tagName==='SELECT')value=target.value;
    if(key==='instrument'&&value==='sample'&&!activeTrack().assetId) {$('#wav-file').click();renderInspector();return;}
    commit(editTrack(project,trackId,{[key]:value}),'トラックを編集');
  } else if(scope==='patch') commit(editTrack(project,trackId,{patch:{...activeTrack().patch,[key]:value}}),'音色を編集');
  else if(scope==='pattern') {
    const pattern=activePattern();if(!pattern)return;
    if(key==='length'&&isDirect(pattern))value=Math.max(value,...pattern.notes.map(n=>n.start+n.duration));
    commit(editPattern(project,pattern.id,{[key]:value}),'音型を編集');
  } else if(scope==='clip') {
    if(!activeClip())return;
    if(key==='length')commit(resizeClip(project,clipId,value,0),'配置の長さを変更');
    else if(key==='start')commit(moveClip(project,clipId,value,trackId,0),'配置を移動');
    else commit(editClip(project,clipId,{[key]:value}),'配置を編集');
  } else if(scope==='generator') {
    const pattern=activePattern();if(!pattern?.generator)return;
    if(key==='degrees') {
      value=String(target.value).split(/[,\s]+/).filter(Boolean).map(Number);
      if(!value.length||value.some(x=>!Number.isInteger(x)||Math.abs(x)>128))throw new Error('音階の順番は整数をカンマで区切って入力してください');
    }
    const generator={...pattern.generator,[key]:value};
    if(key==='steps')generator.pulses=Math.min(generator.pulses,value);
    commit(editPattern(project,pattern.id,{generator}),'生成する規則を編集');
  }
}

function editSelectedNoteField(key,value) {
  const pattern=activePattern();if(!isDirect(pattern))return;
  const selected=pattern.notes.filter(n=>noteIds.has(n.id)),first=selected[0];if(!first)return;
  if(key==='pitch') {commit(moveNotes(project,pattern.id,[...noteIds],0,value-first.pitch,0,0),'音高を編集');return;}
  if(key==='start') {commit(moveNotes(project,pattern.id,[...noteIds],value-first.start,0,0,0),'音符の位置を編集');return;}
  const notes=pattern.notes.map(note=>noteIds.has(note.id)?{...note,[key]:key==='duration'?clamp(value,.03125,pattern.length-note.start):clamp(value,.01,1)}:note);
  commit(editPattern(project,pattern.id,{notes}),'音符を編集');
}

function onPointerDown(event) {
  if(!loaded||event.button!==0||event.target.closest('button,input,select'))return;
  if(event.target.closest('#timeline,#piano,#auto-chart'))document.activeElement?.blur();
  const clipElement=event.target.closest('[data-clip]');
  if(clipElement) {
    event.preventDefault();const id=clipElement.dataset.clip,clip=project.clips.find(c=>c.id===id);
    if(id!==clipId)selectClip(id);
    drag={kind:event.target.closest('[data-resize-clip]')?'clip-resize':'clip-move',id,origin:project,
      x:event.clientX,y:event.clientY,start:clip.start,length:clip.length,trackIndex:project.tracks.findIndex(t=>t.id===clip.trackId),
      scrollLeft:$('#timeline-scroll').scrollLeft,moved:false};return;
  }
  const noteElement=event.target.closest('[data-note]');
  if(noteElement) {
    event.preventDefault();const id=noteElement.dataset.note,pattern=activePattern(),note=patternNotes(pattern).find(n=>n.id===id);
    if(event.shiftKey||event.ctrlKey||event.metaKey) {if(noteIds.has(id))noteIds.delete(id);else noteIds.add(id);}
    else if(!noteIds.has(id))noteIds=new Set([id]);
    renderEditor();
    if(!isDirect(pattern)) {toast('「音符に確定」で音符を直接編集できます');return;}
    drag={kind:event.target.closest('.note-handle')?'note-resize':'note-move',id,origin:project,patternId:pattern.id,
      x:event.clientX,y:event.clientY,duration:note.duration,scrollLeft:$('#piano-viewport').scrollLeft,scrollTop:$('#piano-viewport').scrollTop,moved:false};return;
  }
  const autoPoint=event.target.closest('[data-auto-point]');
  if(autoPoint) {
    event.preventDefault();autoSelected=Number(autoPoint.dataset.autoPoint);
    drag={kind:'auto',origin:project,index:autoSelected,points:clone(activeAutoPoints()),chart:$('#auto-chart').getBoundingClientRect(),moved:false};return;
  }
  if(event.target.closest('#note-grid')) {
    event.preventDefault();const rect=$('#piano').getBoundingClientRect();noteIds.clear();renderNoteFields();
    $$('.note.selected').forEach(note=>note.classList.remove('selected'));
    drag={kind:'marquee',x:event.clientX,y:event.clientY,rect,startX:event.clientX-rect.left,startY:event.clientY-rect.top,moved:false};
  }
}

function onPointerMove(event) {
  if(!drag)return;
  const dx=event.clientX-drag.x,dy=event.clientY-drag.y;
  if(drag.kind.startsWith('clip')) {
    if(Math.abs(dx)+Math.abs(dy)<4&&!drag.moved)return;
    drag.moved=true;const scroller=$('#timeline-scroll'),rect=scroller.getBoundingClientRect();
    if(event.clientX>rect.right-30)scroller.scrollLeft+=12;else if(event.clientX<rect.left+30)scroller.scrollLeft-=12;
    const beatDelta=(dx+scroller.scrollLeft-drag.scrollLeft)/timelineZoom;
    if(drag.kind==='clip-resize')project=resizeClip(drag.origin,drag.id,drag.length+beatDelta,quantize||.0625);
    else {
      const trackIndex=clamp(drag.trackIndex+Math.round(dy/68),0,project.tracks.length-1);
      project=moveClip(drag.origin,drag.id,drag.start+beatDelta,project.tracks[trackIndex].id,quantize||.0625);
    }
    renderTimeline();updatePlayhead();return;
  }
  if(drag.kind.startsWith('note')) {
    if(Math.abs(dx)+Math.abs(dy)<3&&!drag.moved)return;
    drag.moved=true;const viewport=$('#piano-viewport'),rect=viewport.getBoundingClientRect();
    if(event.clientX>rect.right-25)viewport.scrollLeft+=10;else if(event.clientX<rect.left+65)viewport.scrollLeft-=10;
    if(event.clientY>rect.bottom-15)viewport.scrollTop+=8;else if(event.clientY<rect.top+35)viewport.scrollTop-=8;
    const beatDelta=(dx+viewport.scrollLeft-drag.scrollLeft)/noteZoom;
    if(drag.kind==='note-resize')project=resizeNote(drag.origin,drag.patternId,drag.id,drag.duration+beatDelta,quantize||.03125);
    else project=moveNotes(drag.origin,drag.patternId,[...noteIds],beatDelta,-(dy+viewport.scrollTop-drag.scrollTop)/18,quantize||.001,12/project.tuning.divisions);
    renderEditor();return;
  }
  if(drag.kind==='marquee') {
    if(Math.abs(dx)+Math.abs(dy)<4&&!drag.moved)return;
    drag.moved=true;const rect=$('#piano').getBoundingClientRect();
    const x1=Math.min(drag.startX,event.clientX-rect.left),x2=Math.max(drag.startX,event.clientX-rect.left);
    const y1=Math.min(drag.startY,event.clientY-rect.top),y2=Math.max(drag.startY,event.clientY-rect.top);
    noteIds=new Set(patternNotes(activePattern()).filter(n=>{
      const x=58+n.start*noteZoom,y=24+(pitchHigh-n.pitch)*18+2;
      return x<x2&&x+n.duration*noteZoom>x1&&y<y2&&y+14>y1;
    }).map(n=>n.id));renderEditor();
    let marquee=$('#marquee');if(!marquee){marquee=document.createElement('div');marquee.id='marquee';marquee.className='marquee';$('#piano').append(marquee);}
    Object.assign(marquee.style,{left:`${x1}px`,top:`${y1}px`,width:`${x2-x1}px`,height:`${y2-y1}px`});return;
  }
  if(drag.kind==='auto') {
    drag.moved=true;const x=(event.clientX-drag.chart.left)/drag.chart.width*240,y=(event.clientY-drag.chart.top)/drag.chart.height*145;
    const point={beat:clamp(snap((x-16)/213*project.lengthBeats,quantize||.01),0,project.lengthBeats),value:autoValue(y)};
    const points=drag.points.map((p,i)=>i===drag.index?point:p);
    project=putAutomation(drag.origin,trackId,autoParameter,points);renderInspector();
  }
}
function onPointerUp() {
  if(!drag)return;const gesture=drag;drag=null;$('#marquee')?.remove();
  if(gesture.moved&&gesture.origin) {
    const next=project;project=gesture.origin;
    const labels={'clip-move':'配置を移動','clip-resize':'配置の長さを変更','note-move':'音符を移動','note-resize':'音符の長さを変更',auto:'動きの点を移動'};
    commit(next,labels[gesture.kind]??'編集');
  } else if(gesture.kind==='marquee'&&gesture.moved)renderEditor();
}
function onPointerCancel() {if(drag?.origin)project=drag.origin;drag=null;$('#marquee')?.remove();render();}

async function onDoubleClick(event) {
  if(!loaded)return;
  const note=event.target.closest('[data-note]');
  if(note&&isDirect(activePattern())) {commit(removeNotes(project,activePattern().id,[note.dataset.note]),'音符を削除');return;}
  if(event.target.closest('#note-grid')) {
    const pattern=activePattern();if(!isDirect(pattern)) {toast('先に「音符に確定」すると直接編集できます');return;}
    const rect=$('#piano').getBoundingClientRect(),step=12/project.tuning.divisions;
    const start=clamp(snap((event.clientX-rect.left-58)/noteZoom,quantize||.001),0,pattern.length-.03125);
    const pitch=clamp(snap(pitchHigh-(event.clientY-rect.top-24-9)/18,step),0,127);
    const newNote={id:uid('note'),start,duration:Math.min(quantize||.25,pattern.length-start),pitch,velocity:.8};
    noteIds=new Set([newNote.id]);commit(editPattern(project,pattern.id,{notes:[...pattern.notes,newNote]}),'音符を追加');await audition(pitch);return;
  }
  const lane=event.target.closest('[data-lane]');
  if(lane&&!event.target.closest('[data-clip]')) {
    const rect=lane.getBoundingClientRect();addPatternAt(lane.dataset.lane,(event.clientX-rect.left)/timelineZoom);return;
  }
  if(event.target.closest('#auto-chart')&&!event.target.closest('[data-auto-point]')) {
    const rect=$('#auto-chart').getBoundingClientRect(),x=(event.clientX-rect.left)/rect.width*240,y=(event.clientY-rect.top)/rect.height*145;
    const point={beat:clamp(snap((x-16)/213*project.lengthBeats,quantize||.01),0,project.lengthBeats),value:autoValue(y)};
    commit(putAutomation(project,trackId,autoParameter,[...activeAutoPoints(),point]),'動きの点を追加');
  }
}

const KEY_OFFSETS={KeyA:0,KeyW:1,KeyS:2,KeyE:3,KeyD:4,KeyF:5,KeyT:6,KeyG:7,KeyY:8,KeyH:9,KeyU:10,KeyJ:11,KeyK:12,KeyO:13,KeyL:14,KeyP:15,Semicolon:16};
function onKeyDown(event) {
  if(!loaded)return;
  const command=event.ctrlKey||event.metaKey;
  if(command&&['KeyS','KeyO'].includes(event.code)&&!$('#modal').open) {
    event.preventDefault();if(event.repeat)return;
    if(event.code==='KeyS')guarded(saveProject);else confirmReplace(()=>$('#open-file').click());return;
  }
  if(event.target.closest('input,select,textarea,[contenteditable=true]')||$('#modal').open)return;
  if(command&&['KeyS','KeyO','KeyZ','KeyY','KeyD','KeyA'].includes(event.code)) {
    event.preventDefault();if(event.repeat)return;
    if(event.code==='KeyS')guarded(saveProject);
    else if(event.code==='KeyO')confirmReplace(()=>$('#open-file').click());
    else if(event.code==='KeyZ')guarded(()=>onAction(event.shiftKey?'redo':'undo'));
    else if(event.code==='KeyY')guarded(()=>onAction('redo'));
    else if(event.code==='KeyA') {noteIds=new Set(patternNotes(activePattern()).map(n=>n.id));renderEditor();}
    else if(event.code==='KeyD') {
      const pattern=activePattern(),selected=patternNotes(pattern).filter(n=>noteIds.has(n.id));
      if(selected.length&&isDirect(pattern)) {
        const offset=Math.max(...selected.map(n=>n.start+n.duration))-Math.min(...selected.map(n=>n.start));
        const copies=selected.map(n=>({...n,id:uid('note'),start:n.start+offset})).filter(n=>n.start+n.duration<=pattern.length);
        noteIds=new Set(copies.map(n=>n.id));commit(editPattern(project,pattern.id,{notes:[...pattern.notes,...copies]}),'音符を複製');
      } else duplicateSelected();
    }return;
  }
  if(event.code==='Space') {event.preventDefault();if(!event.repeat)guarded(()=>onAction('play'));return;}
  if(event.code==='Enter') {event.preventDefault();if(!event.repeat)guarded(()=>onAction('stop'));return;}
  if(event.code==='Home') {event.preventDefault();guarded(()=>transport('seek',0));return;}
  if(event.code==='Escape') {noteIds.clear();renderEditor();guarded(panic);return;}
  if(['Delete','Backspace'].includes(event.code)) {event.preventDefault();guarded(()=>onAction(noteIds.size?'delete-note':'delete-clip'));return;}
  if(event.code.startsWith('Arrow')&&noteIds.size&&isDirect(activePattern())) {
    event.preventDefault();const beatDelta=(event.code==='ArrowLeft'?-1:event.code==='ArrowRight'?1:0)*(quantize||.01),pitchDelta=(event.code==='ArrowUp'?1:event.code==='ArrowDown'?-1:0)*(event.shiftKey?12:12/project.tuning.divisions);
    commit(moveNotes(project,activePattern().id,[...noteIds],beatDelta,pitchDelta,quantize||.001,0),'音符を移動');return;
  }
  if(keyboard&&!command&&!event.altKey) {
    if(['KeyZ','KeyX'].includes(event.code)) {event.preventDefault();if(!event.repeat){keyOctave=clamp(keyOctave+(event.code==='KeyX'?1:-1),0,8);renderTop();}return;}
    const offset=KEY_OFFSETS[event.code];
    if(offset!==undefined) {event.preventDefault();if(!event.repeat)pressKey(event.code,(keyOctave+1)*12+offset);}
  }
}

function installEvents() {
  document.addEventListener('click',event=>{
    const button=event.target.closest('[data-action]');
    if(button){guarded(()=>onAction(button.dataset.action,button));return;}
    const tab=event.target.closest('[data-tab]');if(tab){inspectorTab=tab.dataset.tab;renderInspector();return;}
    const key=event.target.closest('[data-key-pitch]');if(key){guarded(()=>audition(Number(key.dataset.keyPitch)));return;}
    if(event.target.closest('#ruler')) {const rect=$('#ruler').getBoundingClientRect();guarded(()=>transport('seek',clamp((event.clientX-rect.left)/timelineZoom,0,project.lengthBeats)));}
  });
  document.addEventListener('change',event=>guarded(()=>onChange(event.target)));
  document.addEventListener('input',event=>{
    const target=event.target;
    if(target.id==='timeline-zoom') {songFitted=false;timelineZoom=number(target.value,28);renderTimeline();updatePlayhead();}
    if(target.id==='note-zoom') {noteZoom=number(target.value,44);renderEditor();}
    if(target.dataset.trackMix==='gain')target.nextElementSibling.textContent=Math.round(number(target.value)*100);
    if(target.type==='range'&&target.dataset.scope) {
      const paired=target.parentElement.querySelector('input[type=number]');if(paired)paired.value=target.value;
    }
  });
  document.addEventListener('pointerdown',onPointerDown);document.addEventListener('pointermove',onPointerMove);document.addEventListener('pointerup',onPointerUp);document.addEventListener('pointercancel',onPointerCancel);
  document.addEventListener('dblclick',event=>guarded(()=>onDoubleClick(event)));
  document.addEventListener('keydown',onKeyDown);document.addEventListener('keyup',event=>releaseKey(event.code));
  window.addEventListener('blur',()=>{for(const code of [...pressedKeys.keys()])releaseKey(code);});
  $('#timeline-scroll').addEventListener('scroll',()=>{$('#track-headers').scrollTop=$('#timeline-scroll').scrollTop;});
  $('#open-file').addEventListener('change',event=>guarded(async()=>{const file=event.target.files[0];if(file)await openProjectFile(file);event.target.value='';}));
  $('#wav-file').addEventListener('change',event=>guarded(async()=>{const file=event.target.files[0];if(file)await importWav(file);event.target.value='';}));
  $('#modal').addEventListener('click',event=>{if(event.target===$('#modal')){const rect=$('#modal').getBoundingClientRect();if(event.clientX<rect.left||event.clientX>rect.right||event.clientY<rect.top||event.clientY>rect.bottom)closeModal();}});
  window.addEventListener('pagehide',()=>{api('transport',{action:'stop'},{keepalive:true}).catch(()=>{});api('panic',{},{keepalive:true}).catch(()=>{});});
  window.addEventListener('beforeunload',event=>{if(dirty){event.preventDefault();event.returnValue='';}});
  window.addEventListener('resize',()=>{if(songFitted)fitSong();else renderTimeline();renderEditor();scrollSelectedTrack();});
}

async function boot() {
  $('#app').setAttribute('aria-busy','true');
  try {
    const bootstrap=await api('bootstrap');
    if(!bootstrap.project)throw new Error('プロジェクトを読み込めませんでした');
    instruments=bootstrap.instruments?.length?bootstrap.instruments.map(i=>typeof i==='string'?{id:i,name:INSTRUMENTS.find(([id])=>id===i)?.[1]??i}:i):instruments;
    version=bootstrap.version??'';midiSupported=!!bootstrap.capabilities?.midi;
    project=bootstrap.project;history=new History(project);clipId=project.clips[0]?.id??null;trackId=activeClip()?.trackId??project.tracks[0]?.id??null;
    loaded=true;
    if(bootstrap.engine)applyStatus({engine:bootstrap.engine});
    queue=new CompileQueue(value=>api('compile',value),{
      pending:()=>{$('#compile-status').textContent='変更を反映中…';},
      accepted:result=>{
        resolved=result.resolved;$('#compile-status').textContent=result.warnings?.length?`${result.warnings.length}件のお知らせ`:'すべての変更を反映';
        if(result.warnings?.length)notice(result.warnings.map(w=>typeof w==='string'?w:w.message).join(' / '));
        if(!drag){renderTimeline();renderEditor();}
        clearTimeout(recoveryTimer);const acceptedProject=clone(project);
        recoveryTimer=setTimeout(()=>api('recovery',acceptedProject).catch(error=>notice(`自動回復を保存できませんでした: ${error.message}`,true)),700);
      },
      rejected:error=>{$('#compile-status').textContent=error.kind?'変更を反映できませんでした':'画面の更新で問題が起きました';fail(error);},
    });
    queue.schedule(project);await queue.flush();render();fitNotes();fitSong();scrollSelectedTrack();
    await pollStatus();
    $('#version').textContent=version?`AYA ${version}`:'AYA';$('#notice').hidden=true;
    clearInterval(pollTimer);pollTimer=setInterval(()=>pollStatus(),180);
    let localRecovery;
    try{localRecovery=JSON.parse(localStorage.getItem('aya.recovery.v1')??'null');}catch{}
    if(localRecovery?.project&&stableJSON(localRecovery.project)!==stableJSON(project)) {
      notice('ブラウザに別の曲の自動回復データがあります。');
      const button=document.createElement('button');button.textContent='回復する';button.onclick=()=>confirmReplace(async()=>{await stopForReplace();const accepted=await api('compile',localRecovery.project);replaceProject(accepted.project,'自動回復しました');resolved=accepted.resolved;render();fitNotes();$('#notice').hidden=true;});$('#notice-text').append(' ',button);
    }
    if(!localStorage.getItem('aya.welcomed.v1')){showHelp(true);localStorage.setItem('aya.welcomed.v1','1');}
  } catch(error) {
    notice(error.kind==='connection'?`Ayaに接続できませんでした。起動したアプリのURLを確認してください。 ${error.message}`:`Ayaの画面を準備できませんでした。 ${error.message}`,true);
    console.error(error);
    const retry=document.createElement('button');retry.textContent='再接続';retry.dataset.action='reconnect';$('#notice-text').append(' ',retry);
    if(error.kind==='connection') {$('#engine-led').className='error';$('#engine-status').textContent='接続待ち';}
  } finally {$('#app').setAttribute('aria-busy','false');}
}

installEvents();requestAnimationFrame(animate);boot();
