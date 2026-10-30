import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

// These pins identify the independently verified complete native render and
// the exact tracked project it renders. Refresh both only after verifying a
// replacement render; do not derive the expected digest from the candidate.
export const renderSHA256='432c5a807c545ccf0eee2a10dbf798fabe0708cc1b28f212c5612e53f06fc733';
export const projectSHA256='cee42daec50e5f3dee7653501dde8d52a698ce3902c9304404da1712fb380cd7';
export const sha256=bytes=>createHash('sha256').update(bytes).digest('hex');

export function verifyOriginalRender(wav){
 assert.ok(wav.length>=44,'Truncated Aya WAV');
 assert.equal(wav.toString('ascii',0,4),'RIFF');
 assert.equal(wav.toString('ascii',8,12),'WAVE');
 assert.equal(wav.readUInt32LE(4)+8,wav.length,'RIFF size must cover the complete file');
 let offset=12,format,data;
 while(offset+8<=wav.length){
  const tag=wav.toString('ascii',offset,offset+4),size=wav.readUInt32LE(offset+4),start=offset+8;
  assert.ok(start+size<=wav.length,`Truncated WAV chunk ${tag}`);
  if(tag==='fmt '){
   assert.ok(!format&&size>=16,'Expected one PCM format chunk');
   assert.equal(wav.readUInt16LE(start),1,'Aya export must be integer PCM');
   format={channels:wav.readUInt16LE(start+2),sampleRate:wav.readUInt32LE(start+4),bits:wav.readUInt16LE(start+14)};
   assert.equal(wav.readUInt32LE(start+8),288000,'Stereo 48 kHz/24-bit byte rate');
   assert.equal(wav.readUInt16LE(start+12),6,'Stereo 24-bit block alignment');
  }
  if(tag==='data'){assert.ok(!data,'Expected one audio data chunk');data={offset:start,size};}
  offset=start+size+(size%2);
 }
 assert.equal(offset,wav.length,'Unexpected trailing or truncated WAV data');
 assert.deepEqual(format,{channels:2,sampleRate:48000,bits:24});
 assert.ok(data,'Missing audio data');
 assert.equal(data.size,28014408,'Complete 97.27225-second stereo render');
 assert.equal(data.size%6,0,'Audio data must contain complete stereo frames');
 const frames=data.size/6,durationSeconds=frames/format.sampleRate;
 assert.equal(durationSeconds,97.27225);
 assert.equal(sha256(wav),renderSHA256,'Native full-render SHA-256 differs');
 return {format,data,frames,durationSeconds};
}

export function verifyOriginalProject(bytes){
 assert.equal(sha256(bytes),projectSHA256,'Glass Tides project SHA-256 differs');
 const project=JSON.parse(bytes.toString('utf8'));
 assert.equal(project.schemaVersion,1);assert.equal(project.tuning.divisions,19);
 assert.equal(project.tracks.length,7);assert.equal(project.lengthBeats,160);
 return project;
}
