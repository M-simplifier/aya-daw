export const INSTRUMENTS = [
  ['bass', 'ベース'], ['pad', 'パッド'], ['bell', 'ベル'], ['lead', 'リード'],
  ['pluck', 'プラック'], ['kick', 'キック'], ['snare', 'スネア'], ['hat', 'ハット'], ['sample', 'サンプル'],
];
export const COLORS = ['#cf9b68', '#73afa7', '#8e9cc1', '#b494bb', '#a6b97b', '#cf857c', '#b8aa79', '#7ca6b7'];
export const clone = value => structuredClone(value);
export const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
export const snap = (value, step) => step > 0 ? Math.round(value / step) * step : value;
export const uid = prefix => `${prefix}-${globalThis.crypto?.randomUUID?.() ?? `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`}`;
export const number = (value, fallback = 0) => Number.isFinite(Number(value)) ? Number(value) : fallback;

export function makeTrack(index = 0, instrument = 'pluck') {
  const label = INSTRUMENTS.find(([id]) => id === instrument)?.[1] ?? instrument;
  return {id: uid('track'), name: label, color: COLORS[index % COLORS.length], instrument,
    gain: 0.65, pan: 0, mute: false, solo: false, assetId: null,
    patch: {attack: 0.015, release: 0.4, cutoff: 8000, resonance: 0.1, tone: 0.5,
      delaySend: 0.15, delayBeats: 0.75, delayFeedback: 0.3}, automation: []};
}

export function blankProject() {
  const track = makeTrack();
  return {schemaVersion: 1, id: uid('project'), name: '名前のない曲', tempo: 108, beatsPerBar: 4,
    lengthBeats: 64, masterGain: 0.8, loop: {enabled: false, start: 0, end: 16},
    tuning: {divisions: 12, referenceHz: 440, root: 60, scale: [0, 2, 3, 5, 7, 8, 10]},
    tracks: [track], patterns: [], clips: [], assets: []};
}

export function makePattern(length = 16) {
  return {id: uid('pattern'), name: '新しい音型', length, notes: [], generator: null, transforms: []};
}

export function makeClip(trackId, pattern, start = 0) {
  return {id: uid('clip'), trackId, patternId: pattern.id, start, length: pattern.length, transpose: 0, gain: 1};
}

export function editTrack(project, trackId, changes) {
  return {...project, tracks: project.tracks.map(t => t.id === trackId ? {...t, ...changes} : t)};
}

export function editPattern(project, patternId, changes) {
  return {...project, patterns: project.patterns.map(p => p.id === patternId ? {...p, ...changes} : p)};
}

export function editClip(project, clipId, changes) {
  return {...project, clips: project.clips.map(c => c.id === clipId ? {...c, ...changes} : c)};
}

export function moveClip(project, clipId, start, trackId, quantum = 0.25) {
  const clip = project.clips.find(c => c.id === clipId);
  if (!clip || !project.tracks.some(t => t.id === trackId)) return project;
  return editClip(project, clipId, {start: clamp(snap(start, quantum), 0, Math.max(0, project.lengthBeats - clip.length)), trackId});
}

export function resizeClip(project, clipId, length, quantum = 0.25) {
  const clip = project.clips.find(c => c.id === clipId);
  if (!clip) return project;
  const remaining = project.lengthBeats - clip.start;
  return editClip(project, clipId, {length: clamp(snap(length, quantum), Math.min(Math.max(quantum, 0.0625), remaining), remaining)});
}

export function duplicateClip(project, clipId, independent = false) {
  const original = project.clips.find(c => c.id === clipId);
  if (!original) return {project, clipId: null};
  let patterns = project.patterns;
  let patternId = original.patternId;
  if (independent) {
    const originalPattern = patterns.find(p => p.id === patternId);
    if (!originalPattern) return {project, clipId: null};
    const copy = {...clone(originalPattern), id: uid('pattern'), name: `${originalPattern.name} のコピー`};
    copy.notes = copy.notes.map(note => ({...note, id: uid('note')}));
    patterns = [...patterns, copy]; patternId = copy.id;
  }
  const copy = {...original, id: uid('clip'), patternId,
    start: Math.min(original.start + original.length, Math.max(0, project.lengthBeats - original.length))};
  return {project: {...project, patterns, clips: [...project.clips, copy]}, clipId: copy.id};
}

export function detachClip(project, clipId) {
  const clip = project.clips.find(c => c.id === clipId);
  const pattern = project.patterns.find(p => p.id === clip?.patternId);
  if (!pattern) return project;
  const copy = {...clone(pattern), id: uid('pattern'), name: `${pattern.name}・独立`};
  copy.notes = copy.notes.map(note => ({...note, id: uid('note')}));
  return {...project, patterns: [...project.patterns, copy], clips: project.clips.map(c => c.id === clipId ? {...c, patternId: copy.id} : c)};
}

export function removeTrack(project, trackId) {
  return {...project, tracks: project.tracks.filter(t => t.id !== trackId), clips: project.clips.filter(c => c.trackId !== trackId)};
}

export function reorderTrack(project, trackId, direction) {
  const index = project.tracks.findIndex(t => t.id === trackId);
  const next = clamp(index + direction, 0, project.tracks.length - 1);
  if (index < 0 || index === next) return project;
  const tracks = [...project.tracks];
  [tracks[index], tracks[next]] = [tracks[next], tracks[index]];
  return {...project, tracks};
}

export function moveNotes(project, patternId, noteIds, beatDelta, pitchDelta, quantum = 0.25, pitchStep = 1) {
  const pattern = project.patterns.find(p => p.id === patternId);
  if (!pattern || pattern.generator || pattern.transforms.length) return project;
  const ids = new Set(noteIds), selected = pattern.notes.filter(n => ids.has(n.id));
  if (!selected.length) return project;
  const left = Math.min(...selected.map(n => n.start));
  const right = Math.max(...selected.map(n => n.start + n.duration));
  const delta = clamp(snap(beatDelta, quantum), -left, pattern.length - right);
  const pitch = clamp(snap(pitchDelta, pitchStep), -Math.min(...selected.map(n => n.pitch)), 127 - Math.max(...selected.map(n => n.pitch)));
  return editPattern(project, patternId, {notes: pattern.notes.map(n => ids.has(n.id)
    ? {...n, start: n.start + delta, pitch: n.pitch + pitch} : n)});
}

export function resizeNote(project, patternId, noteId, duration, quantum = 0.25) {
  const pattern = project.patterns.find(p => p.id === patternId);
  if (!pattern || pattern.generator || pattern.transforms.length) return project;
  return editPattern(project, patternId, {notes: pattern.notes.map(n => n.id === noteId
    ? {...n, duration: clamp(snap(duration, quantum), Math.min(Math.max(quantum, 0.03125), pattern.length - n.start), pattern.length - n.start)} : n)});
}

export function removeNotes(project, patternId, noteIds) {
  const pattern = project.patterns.find(p => p.id === patternId);
  if (!pattern || pattern.generator || pattern.transforms.length) return project;
  const ids = new Set(noteIds);
  return editPattern(project, patternId, {notes: pattern.notes.filter(n => !ids.has(n.id))});
}

export function putAutomation(project, trackId, parameter, points) {
  const track = project.tracks.find(t => t.id === trackId);
  if (!track) return project;
  const unique = new Map(points.map(point => [point.beat, point]));
  const lane = {parameter, points: [...unique.values()].sort((a, b) => a.beat - b.beat)};
  return editTrack(project, trackId, {automation: [...track.automation.filter(a => a.parameter !== parameter), lane]});
}

export class History {
  constructor(project, limit = 80) { this.present = project; this.past = []; this.future = []; this.limit = limit; }
  commit(project, label = '編集') {
    if (JSON.stringify(project) === JSON.stringify(this.present)) return false;
    this.past = [...this.past.slice(-(this.limit - 1)), {project: this.present, label}];
    this.present = project; this.future = []; return true;
  }
  undo() {
    const entry = this.past.at(-1); if (!entry) return null;
    this.future = [{project: this.present, label: entry.label}, ...this.future];
    this.past = this.past.slice(0, -1); this.present = entry.project; return entry.label;
  }
  redo() {
    const entry = this.future[0]; if (!entry) return null;
    this.past = [...this.past, {project: this.present, label: entry.label}];
    this.future = this.future.slice(1); this.present = entry.project; return entry.label;
  }
}

export function pitchLabel(pitch) {
  const nearest = Math.round(pitch), offset = pitch - nearest;
  return `${['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'][((nearest % 12) + 12) % 12]}${Math.floor(nearest / 12) - 1}${Math.abs(offset) > 0.0001 ? `${offset > 0 ? '+' : ''}${(offset * 100).toFixed(0)}¢` : ''}`;
}

export function beatLabel(beat, beatsPerBar = 4) {
  const bar = Math.floor(Math.max(0, beat) / beatsPerBar) + 1;
  const within = Math.max(0, beat) % beatsPerBar;
  return `${String(bar).padStart(2, '0')} : ${String(Math.floor(within) + 1).padStart(2, '0')} : ${String(Math.floor((within % 1) * 100)).padStart(2, '0')}`;
}
