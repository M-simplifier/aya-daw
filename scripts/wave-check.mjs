import assert from 'node:assert/strict';

export function inspectWave(bytes) {
  assert.equal(bytes.subarray(0,4).toString(),'RIFF'); assert.equal(bytes.subarray(8,12).toString(),'WAVE');
  assert.equal(bytes.readUInt32LE(4)+8,bytes.length,'RIFF length mismatch');
  let offset=12,format,channels,rate,bits,samples;
  while(offset+8<=bytes.length) {
    const kind=bytes.subarray(offset,offset+4).toString(),length=bytes.readUInt32LE(offset+4),start=offset+8;
    assert.ok(start+length<=bytes.length,'Chunk exceeds file');
    if(kind==='fmt ') {format=bytes.readUInt16LE(start);channels=bytes.readUInt16LE(start+2);rate=bytes.readUInt32LE(start+4);bits=bytes.readUInt16LE(start+14);}
    if(kind==='data') samples=bytes.subarray(start,start+length);
    offset=start+length+(length%2);
  }
  assert.ok(samples); assert.ok(format===1 || format===3); assert.ok(channels===1 || channels===2);
  assert.ok([8,16,24,32,64].includes(bits)); assert.equal(samples.length%(bits/8*channels),0);
  let peak=0,sumSquares=0,tailSquares=0,tailCount=0,lastNonzeroFrame=0;
  const count=samples.length/(bits/8),frames=count/channels;
  for(let i=0,index=0;i<samples.length;i+=bits/8,index++) {
    const value=format===3?(bits===64?samples.readDoubleLE(i):samples.readFloatLE(i)):
      bits===8?(samples.readUInt8(i)-128)/128:samples.readIntLE(i,bits/8)/(2**(bits-1));
    assert.ok(Number.isFinite(value)); peak=Math.max(peak,Math.abs(value));sumSquares+=value*value;
    if(Math.abs(value)>1/8388608) lastNonzeroFrame=Math.floor(index/channels);
    if(index>=count-rate*channels) {tailSquares+=value*value;tailCount++;}
  }
  return {format,bits,rate,channels,frames,peak,rms:Math.sqrt(sumSquares/count),
    tailRms:Math.sqrt(tailSquares/Math.max(1,tailCount)),lastNonzeroFrame,duration:frames/rate};
}
