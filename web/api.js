export class ApiError extends Error {
  constructor(message, details = [], kind = 'request') { super(message); this.name = 'ApiError'; this.details = details; this.kind = kind; }
}

export async function api(path, body, {signal, keepalive = false} = {}) {
  let response;
  try {
    response = await fetch(`/api/${path}`, {method: body === undefined ? 'GET' : 'POST',
      headers: body === undefined ? {} : {'Content-Type': 'application/json'},
      body: body === undefined ? undefined : JSON.stringify(body), signal, keepalive});
  } catch(error) { throw new ApiError(error.message, [], 'connection'); }
  let data;
  try { data = await response.json(); } catch { throw new ApiError(`応答を読めませんでした (${response.status})`); }
  if (!response.ok || data.error || data.errors?.length) {
    const details = data.errors ?? data.error?.details ?? [];
    const message = typeof data.error === 'string' ? data.error : data.error?.message ?? data.message ?? details[0]?.message ?? `処理に失敗しました (${response.status})`;
    throw new ApiError(message, details);
  }
  return data;
}

// One compile at a time: an old request can never overwrite a newer accepted
// projection, and flush waits for the actual latest edit before transport/export.
export class CompileQueue {
  constructor(send, callbacks = {}, delay = 180) {
    this.send = send; this.callbacks = callbacks; this.delay = delay;
    this.revision = 0; this.accepted = 0; this.pending = null; this.running = false;
    this.timer = null; this.waiters = []; this.lastError = null;
  }
  schedule(project) {
    const revision = ++this.revision;
    this.pending = {project: structuredClone(project), revision};
    this.lastError = null; clearTimeout(this.timer);
    this.callbacks.pending?.(revision);
    this.timer = this.running ? null : setTimeout(() => { this.timer = null; this.drain(); }, this.delay);
    return revision;
  }
  async drain() {
    if (this.running || !this.pending) return;
    clearTimeout(this.timer); this.timer = null; this.running = true;
    while (this.pending) {
      const request = this.pending; this.pending = null;
      try {
        const result = await this.send(request.project);
        if (request.revision === this.revision) {
          this.accepted = request.revision; this.lastError = null;
          this.callbacks.accepted?.(result, request.revision);
        }
      } catch (error) {
        if (request.revision === this.revision) {
          this.lastError = error; this.callbacks.rejected?.(error, request.revision);
        }
      }
    }
    this.running = false;
    const waiters = this.waiters.splice(0);
    for (const waiter of waiters) this.lastError ? waiter.reject(this.lastError) : waiter.resolve();
  }
  async flush() {
    clearTimeout(this.timer); this.timer = null;
    if (!this.running && !this.pending) {
      if (this.lastError) throw this.lastError;
      return;
    }
    const done = new Promise((resolve, reject) => this.waiters.push({resolve, reject}));
    this.drain(); await done;
    if (this.accepted < this.revision) return this.flush();
  }
}
