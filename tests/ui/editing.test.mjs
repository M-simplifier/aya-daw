import test from 'node:test';
import assert from 'node:assert/strict';
import {blankProject, makePattern, makeClip, makeTrack, moveClip, resizeClip, duplicateClip, detachClip,
  removeTrack, reorderTrack, moveNotes, resizeNote, putAutomation, History} from '../../web/model.js';
import {CompileQueue} from '../../web/api.js';

function score() {
  const project=blankProject(),pattern=makePattern(16);
  pattern.notes=[{id:'low',start:2,duration:1,pitch:60.5,velocity:.7},{id:'high',start:4,duration:2,pitch:67.5,velocity:.8}];
  return {...project,patterns:[pattern],clips:[makeClip(project.tracks[0].id,pattern,8)]};
}
function deferred() {let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};}
const tick=()=>new Promise(resolve=>setTimeout(resolve,0));

test('clip moves and resizes stay in song while stable identities and original remain intact',()=>{
  const project=score(),original=JSON.stringify(project),clip=project.clips[0];
  let next=moveClip(project,clip.id,-100,clip.trackId,.25);assert.equal(next.clips[0].start,0);
  next=moveClip(project,clip.id,1000,clip.trackId,.25);assert.equal(next.clips[0].start,project.lengthBeats-clip.length);
  next=resizeClip(next,clip.id,1000,.25);assert.equal(next.clips[0].start+next.clips[0].length,project.lengthBeats);
  next=resizeClip(next,clip.id,-1,.25);assert.ok(next.clips[0].length>0);
  assert.equal(next.clips[0].id,clip.id);assert.equal(next.clips[0].patternId,clip.patternId);assert.equal(JSON.stringify(project),original);
  assert.equal(moveClip(project,clip.id,2,'missing'),project);
});

test('linked duplication shares source; detach gives unique editable source and note identities',()=>{
  const project=score(),result=duplicateClip(project,project.clips[0].id);
  assert.equal(result.project.clips.length,2);assert.equal(result.project.patterns.length,1);
  assert.equal(result.project.clips[1].patternId,result.project.clips[0].patternId);
  const next=detachClip(result.project,result.clipId);
  assert.equal(next.patterns.length,2);assert.notEqual(next.clips[1].patternId,next.clips[0].patternId);
  assert.notEqual(next.patterns[1].notes[0].id,next.patterns[0].notes[0].id);
  next.patterns[1].notes[0].pitch=73;assert.equal(project.patterns[0].notes[0].pitch,60.5);
});

test('track order changes without rewriting musical references; removing a track removes its clips only',()=>{
  const project=score(),track=makeTrack(1),next={...project,tracks:[...project.tracks,track]};
  const reordered=reorderTrack(next,track.id,-1);assert.equal(reordered.tracks[0].id,track.id);
  assert.equal(reordered.clips[0].trackId,project.tracks[0].id);
  const removed=removeTrack(reordered,project.tracks[0].id);assert.equal(removed.clips.length,0);assert.equal(removed.patterns.length,1);
});

test('group note drag preserves relative time and fractional pitch even at all domain boundaries',()=>{
  const project=score(),pattern=project.patterns[0],ids=['low','high'];
  for(const [time,pitch] of [[-100,-200],[100,200],[.5,12/19]]) {
    const next=moveNotes(project,pattern.id,ids,time,pitch,.25,0),[low,high]=next.patterns[0].notes;
    assert.equal(high.start-low.start,2);assert.ok(Math.abs(high.pitch-low.pitch-7)<1e-10);
    assert.ok(low.start>=0);assert.ok(high.start+high.duration<=16);assert.ok(low.pitch>=0);assert.ok(high.pitch<=127);
    if(time===.5)assert.ok(Math.abs(low.pitch-(60.5+12/19))<1e-10);
  }
});

test('generated patterns cannot be destructively edited before explicit materialization',()=>{
  const project=score();project.patterns[0].generator={kind:'euclid'};
  assert.equal(moveNotes(project,project.patterns[0].id,['low'],2,1),project);
  assert.equal(resizeNote(project,project.patterns[0].id,'low',4),project);
});

test('note resize preserves onset and pitch and cannot cross pattern end',()=>{
  const project=score(),pattern=project.patterns[0];
  const next=resizeNote(project,pattern.id,'high',100,.25),note=next.patterns[0].notes[1];
  assert.equal(note.start,4);assert.equal(note.pitch,67.5);assert.equal(note.duration,12);
  assert.equal(project.patterns[0].notes[1].duration,2);
});

test('drag is one undo transaction, redo restores it, fresh edit invalidates redo',()=>{
  const project=score(),history=new History(project),clip=project.clips[0];
  for(let beat=9;beat<20;beat++)moveClip(project,clip.id,beat,clip.trackId);
  const end=moveClip(project,clip.id,20,clip.trackId);history.commit(end,'move');
  assert.equal(history.past.length,1);assert.equal(history.undo(),'move');assert.deepEqual(history.present,project);
  assert.equal(history.redo(),'move');assert.deepEqual(history.present,end);
  history.undo();history.commit(resizeClip(project,clip.id,8),'resize');assert.equal(history.redo(),null);
});

test('automation is ordered with one value at each beat; editing one lane preserves other lanes',()=>{
  const project=score(),id=project.tracks[0].id;
  const panned=putAutomation(project,id,'pan',[{beat:0,value:-.5}]);
  const next=putAutomation(panned,id,'gain',[{beat:8,value:.2},{beat:0,value:.6},{beat:8,value:.9}]);
  assert.deepEqual(next.tracks[0].automation.find(a=>a.parameter==='gain').points,[{beat:0,value:.6},{beat:8,value:.9}]);
  assert.deepEqual(next.tracks[0].automation.find(a=>a.parameter==='pan').points,[{beat:0,value:-.5}]);
});

test('compile serializes requests, collapses edits, rejects stale projections and flush waits for last edit',async()=>{
  const calls=[],accepted=[],first=deferred(),last=deferred();
  const queue=new CompileQueue(project=>{calls.push(project);return calls.length===1?first.promise:last.promise;},{accepted:r=>accepted.push(r)},100000);
  queue.schedule({revision:1});const flushing=queue.flush();await tick();
  queue.schedule({revision:2});queue.schedule({revision:3});
  let finished=false;flushing.then(()=>{finished=true;});
  first.resolve({revision:1});await tick();
  assert.deepEqual(calls,[{revision:1},{revision:3}]);assert.deepEqual(accepted,[]);assert.equal(finished,false);
  last.resolve({revision:3});await flushing;assert.deepEqual(accepted,[{revision:3}]);assert.equal(queue.accepted,3);
});

test('failed compile is visible to flush and a later valid edit can recover',async()=>{
  let succeeds=false;const errors=[];
  const queue=new CompileQueue(async()=>{if(!succeeds)throw new Error('invalid music');return {ok:true};},{rejected:e=>errors.push(e.message)},100000);
  queue.schedule({bad:true});await assert.rejects(queue.flush(),/invalid music/);assert.deepEqual(errors,['invalid music']);
  succeeds=true;queue.schedule({bad:false});await queue.flush();assert.equal(queue.accepted,2);
});
