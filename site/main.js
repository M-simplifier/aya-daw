const locale=document.documentElement.lang==='en'?'en':'ja';
const copy=locale==='en'?{
  play:'Play the piece',pause:'Pause',audioError:'Playback could not start. Use the WAV link below to listen.',
  notes:n=>`${n} notes in 16 steps`,seed:'Change the number of notes. The rhythm spreads them as evenly as possible.',
  rotate:'Move the rhythm around its cycle. The spacing between its notes stays intact.',
  manual:'The notes are now independent. Press a coloured note to change its pitch; the other notes stay in place.',
  note:n=>`Change pitch of note ${n}`,menu:'Menu',close:'Close menu',
}: {
  play:'この曲を聴く',pause:'一時停止',audioError:'再生を始められませんでした。下のWAVリンクから音源を開けます。',
  notes:n=>`16分割に${n}音`,seed:'鳴らす数を変えると、音をなるべく均等に散らしたリズムになります。',
  rotate:'音の間隔を保ったまま、リズムを周期の中でずらします。',
  manual:'音符に確定した状態です。色のついた音符を押すと、その一音の高さだけが変わります。',
  note:n=>`音符${n}の高さを変える`,menu:'メニュー',close:'メニューを閉じる',
};

const navToggle=document.querySelector('.nav-toggle'),nav=document.querySelector('.nav');
navToggle?.addEventListener('click',()=>{
  const open=nav.classList.toggle('open');navToggle.setAttribute('aria-expanded',String(open));navToggle.textContent=open?copy.close:copy.menu;
});
nav?.querySelectorAll('a').forEach(link=>link.addEventListener('click',()=>{nav.classList.remove('open');navToggle?.setAttribute('aria-expanded','false');if(navToggle)navToggle.textContent=copy.menu;}));

const audio=document.querySelector('#example-audio'),play=document.querySelector('#listen-toggle'),seek=document.querySelector('#audio-seek'),time=document.querySelector('#audio-time');
function clock(seconds){if(!Number.isFinite(seconds))return '0:00';return `${Math.floor(seconds/60)}:${String(Math.floor(seconds%60)).padStart(2,'0')}`;}
function updateAudio(){
  if(!audio)return;
  const playing=!audio.paused&&!audio.ended;
  if(play){play.querySelector('.listen-symbol').textContent=playing?'Ⅱ':'▶';play.querySelector('.listen-label').textContent=playing?copy.pause:copy.play;play.setAttribute('aria-pressed',String(playing));}
  if(seek&&Number.isFinite(audio.duration)){seek.max=audio.duration;if(document.activeElement!==seek)seek.value=audio.currentTime;}
  if(time)time.textContent=`${clock(audio.currentTime)} / ${clock(Number.isFinite(audio.duration)?audio.duration:97.27225)}`;
}
async function playAudio(){
  if(!audio)return;
  const error=document.querySelector('#audio-error');if(error)error.hidden=true;
  try{await audio.play();}catch{if(error){error.textContent=copy.audioError;error.hidden=false;}}updateAudio();
}
if(audio){
  audio.volume=.65;
  for(const event of ['play','pause','timeupdate','ended','loadedmetadata','durationchange'])audio.addEventListener(event,updateAudio);
  audio.addEventListener('error',()=>{const error=document.querySelector('#audio-error');if(error){error.textContent=copy.audioError;error.hidden=false;}});
  play?.addEventListener('click',()=>audio.paused?playAudio():audio.pause());
  seek?.addEventListener('input',()=>{if(Number.isFinite(audio.duration))audio.currentTime=Number(seek.value);updateAudio();});
  document.querySelectorAll('[data-listen]').forEach(link=>link.addEventListener('click',()=>{playAudio();}));
  document.addEventListener('visibilitychange',()=>{if(document.hidden)audio.pause();});
  updateAudio();
}

const sequence=document.querySelector('#sequence');
if(sequence){
  const pulses=document.querySelector('#study-pulses'),rotation=document.querySelector('#study-rotation'),explanation=document.querySelector('#study-explanation');
  let phase='seed',manualNotes=null;
  function generated(){return Array.from({length:16},(_,column)=>column).filter(column=>(((column-Number(rotation.value))*Number(pulses.value))%16+16)%16<Number(pulses.value)).map(column=>({column,row:2,edited:false}));}
  function renderStudy(){
    const notes=phase==='manual'?manualNotes:generated();
    document.querySelectorAll('[data-study-phase]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.studyPhase===phase)));
    pulses.disabled=phase==='manual';rotation.disabled=phase!=='rotate';
    document.querySelector('#pulses-value').textContent=pulses.value;document.querySelector('#rotation-value').textContent=rotation.value;
    document.querySelector('#study-count').textContent=copy.notes(notes.length);explanation.textContent=copy[phase];
    sequence.replaceChildren();
    for(let column=0;column<16;column++){const number=document.createElement('span');number.className='seq-step';number.style.left=`calc(${column*6.25}% + 5px)`;number.textContent=String(column+1).padStart(2,'0');sequence.append(number);}
    notes.forEach((note,index)=>{
      const button=document.createElement('button');button.type='button';button.className=`seq-note${phase==='manual'?' editable':''}${note.edited?' edited':''}`;
      button.style.setProperty('--column',note.column);button.style.setProperty('--row',note.row);button.disabled=phase!=='manual';
      button.setAttribute('aria-label',copy.note(index+1));button.title=copy.note(index+1);
      button.addEventListener('click',()=>{note.row=note.row===2?0:note.row===0?4:2;note.edited=note.row!==2;button.style.setProperty('--row',note.row);button.classList.toggle('edited',note.edited);});
      sequence.append(button);
    });
  }
  document.querySelectorAll('[data-study-phase]').forEach(button=>button.addEventListener('click',()=>{
    const next=button.dataset.studyPhase;if(next==='manual'&&phase!=='manual')manualNotes=generated();phase=next;renderStudy();
  }));
  pulses.addEventListener('input',renderStudy);rotation.addEventListener('input',renderStudy);
  document.querySelector('#study-reset').addEventListener('click',()=>{pulses.value=5;rotation.value=0;phase='seed';manualNotes=null;renderStudy();});
  renderStudy();
}

const tocLinks=[...document.querySelectorAll('.toc a[href^="#"]')];
if(tocLinks.length&&'IntersectionObserver'in window){
  const visible=new Map();
  const observer=new IntersectionObserver(entries=>{
    for(const entry of entries)visible.set(entry.target.id,entry.isIntersecting);
    const active=tocLinks.find(link=>visible.get(link.hash.slice(1)));if(!active)return;
    tocLinks.forEach(link=>{link.classList.toggle('active',link===active);if(link===active)link.setAttribute('aria-current','location');else link.removeAttribute('aria-current');});
  },{rootMargin:'-10% 0px -60% 0px',threshold:0});
  tocLinks.forEach(link=>{const heading=document.getElementById(link.hash.slice(1));if(heading)observer.observe(heading);});
}
