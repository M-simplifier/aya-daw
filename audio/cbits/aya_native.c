#define COBJMACROS
#define INITGUID
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <wchar.h>

/* This file binds Windows ownership, COM and atomics. It contains no DSP. */
enum { AYA_HEADER_BYTES = 4096 };
#define AYA_SLOT_BYTES ((size_t)128 * 1024 * 1024)
#define AYA_MAP_BYTES (AYA_HEADER_BYTES + 2 * AYA_SLOT_BYTES)

typedef struct { HANDLE handle; void *view; HANDLE parent; } AyaMap;
typedef struct {
    IAudioClient *client;
    IAudioRenderClient *render;
    IMMDeviceEnumerator *enumerator;
    IMMDevice *device;
    HANDLE event;
    HANDLE mmcss;
    DWORD mmcss_task;
    UINT32 frames;
    UINT32 acquired;
    BYTE *buffer;
    HRESULT error;
    int initialized_com;
    uint64_t starvation;
    uint64_t packets;
} AyaDevice;

static wchar_t *aya_wide(const char *s) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (!count) return NULL;
    wchar_t *result = (wchar_t *)calloc((size_t)count, sizeof(wchar_t));
    if (result) MultiByteToWideChar(CP_UTF8, 0, s, -1, result, count);
    return result;
}

void *aya_map_create(const char *name) {
    wchar_t *wide = aya_wide(name);
    if (!wide) return NULL;
    AyaMap *m = (AyaMap *)calloc(1, sizeof(AyaMap));
    if (m) {
        m->handle = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE,
            (DWORD)(((uint64_t)AYA_MAP_BYTES) >> 32), (DWORD)AYA_MAP_BYTES, wide);
        if (m->handle && GetLastError() == ERROR_ALREADY_EXISTS) {
            CloseHandle(m->handle); m->handle = NULL;
        }
        if (m->handle) m->view = MapViewOfFile(m->handle, FILE_MAP_ALL_ACCESS, 0, 0, AYA_MAP_BYTES);
        if (!m->view) { if (m->handle) CloseHandle(m->handle); free(m); m = NULL; }
        else { memset(m->view, 0, AYA_HEADER_BYTES); ((DWORD *)m->view)[28] = GetCurrentProcessId(); }
    }
    free(wide);
    return m;
}

void *aya_map_open(const char *name) {
    wchar_t *wide = aya_wide(name);
    if (!wide) return NULL;
    AyaMap *m = (AyaMap *)calloc(1, sizeof(AyaMap));
    if (m) {
        m->handle = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, wide);
        if (m->handle) m->view = MapViewOfFile(m->handle, FILE_MAP_ALL_ACCESS, 0, 0, AYA_MAP_BYTES);
        if (!m->view) { if (m->handle) CloseHandle(m->handle); free(m); m = NULL; }
        else m->parent = OpenProcess(SYNCHRONIZE, FALSE, ((DWORD *)m->view)[28]);
    }
    free(wide);
    return m;
}
void *aya_map_data(void *opaque) { return ((AyaMap *)opaque)->view; }
void aya_map_close(void *opaque) {
    AyaMap *m = (AyaMap *)opaque;
    if (!m) return;
    if (m->view) UnmapViewOfFile(m->view);
    if (m->handle) CloseHandle(m->handle);
    if (m->parent) CloseHandle(m->parent);
    free(m);
}
int aya_parent_alive(void *opaque) {
    AyaMap *m = (AyaMap *)opaque;
    return m->parent && WaitForSingleObject(m->parent, 0) == WAIT_TIMEOUT;
}
uint32_t aya_atomic_read32(void *p) { return (uint32_t)InterlockedCompareExchange((volatile LONG *)p, 0, 0); }
void aya_atomic_write32(void *p, uint32_t value) { InterlockedExchange((volatile LONG *)p, (LONG)value); }
uint64_t aya_atomic_read64(void *p) { return (uint64_t)InterlockedCompareExchange64((volatile LONG64 *)p, 0, 0); }
void aya_atomic_write64(void *p, uint64_t value) { InterlockedExchange64((volatile LONG64 *)p, (LONG64)value); }
DWORD aya_process_id(void) { return GetCurrentProcessId(); }

void *aya_spawn(const char *exe, const char *name) {
    wchar_t *wide_exe = aya_wide(exe), *wide_name = aya_wide(name);
    HANDLE result = NULL;
    if (wide_exe && wide_name) {
        size_t n = wcslen(wide_exe) + wcslen(wide_name) + 160;
        wchar_t *command = (wchar_t *)calloc(n, sizeof(wchar_t));
        if (command) {
            _snwprintf(command, n, L"\"%ls\" --audio-worker %ls +RTS -N1 -I0 -A64m -RTS", wide_exe, wide_name);
            STARTUPINFOW startup; PROCESS_INFORMATION process;
            memset(&startup, 0, sizeof(startup)); startup.cb = sizeof(startup);
            memset(&process, 0, sizeof(process));
            if (CreateProcessW(wide_exe, command, NULL, NULL, FALSE, CREATE_NO_WINDOW,
                              NULL, NULL, &startup, &process)) {
                CloseHandle(process.hThread); result = process.hProcess;
            }
            free(command);
        }
    }
    free(wide_exe); free(wide_name); return result;
}
int aya_child_alive(void *child) { return child && WaitForSingleObject((HANDLE)child, 0) == WAIT_TIMEOUT; }
int aya_child_wait(void *child, int millis) { return WaitForSingleObject((HANDLE)child, (DWORD)millis) != WAIT_TIMEOUT; }
void aya_child_terminate(void *child) { if (child) TerminateProcess((HANDLE)child, 1); }
void aya_child_close(void *child) { if (child) CloseHandle((HANDLE)child); }

double aya_clock(void) {
    LARGE_INTEGER ticks, frequency;
    QueryPerformanceCounter(&ticks); QueryPerformanceFrequency(&frequency);
    return (double)ticks.QuadPart / (double)frequency.QuadPart;
}

void aya_device_close(void *opaque) {
    AyaDevice *d = (AyaDevice *)opaque;
    if (!d) return;
    if (d->client) IAudioClient_Stop(d->client);
    if (d->acquired && d->render) IAudioRenderClient_ReleaseBuffer(d->render, d->acquired, AUDCLNT_BUFFERFLAGS_SILENT);
    if (d->render) IAudioRenderClient_Release(d->render);
    if (d->client) IAudioClient_Release(d->client);
    if (d->device) IMMDevice_Release(d->device);
    if (d->enumerator) IMMDeviceEnumerator_Release(d->enumerator);
    if (d->event) CloseHandle(d->event);
    if (d->mmcss) AvRevertMmThreadCharacteristics(d->mmcss);
    if (d->initialized_com) CoUninitialize();
    free(d);
}

void *aya_device_open(int32_t *error_out) {
    AyaDevice *d = (AyaDevice *)calloc(1, sizeof(AyaDevice));
    HRESULT hr = E_OUTOFMEMORY;
    if (!d) { *error_out = (int32_t)hr; return NULL; }
    hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) goto fail;
    d->initialized_com = 1;
    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                         &IID_IMMDeviceEnumerator, (void **)&d->enumerator);
    if (FAILED(hr)) goto fail;
    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(d->enumerator, eRender, eConsole, &d->device);
    if (FAILED(hr)) goto fail;
    hr = IMMDevice_Activate(d->device, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&d->client);
    if (FAILED(hr)) goto fail;
    WAVEFORMATEX format;
    memset(&format, 0, sizeof(format));
    format.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    format.nChannels = 2; format.nSamplesPerSec = 48000;
    format.wBitsPerSample = 32; format.nBlockAlign = 8; format.nAvgBytesPerSec = 384000;
    hr = IAudioClient_Initialize(d->client, AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
        AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY | AUDCLNT_STREAMFLAGS_NOPERSIST,
        200000, 0, &format, NULL);
    if (FAILED(hr)) goto fail;
    d->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!d->event) { hr = HRESULT_FROM_WIN32(GetLastError()); goto fail; }
    hr = IAudioClient_SetEventHandle(d->client, d->event);
    if (FAILED(hr)) goto fail;
    hr = IAudioClient_GetBufferSize(d->client, &d->frames);
    if (FAILED(hr)) goto fail;
    hr = IAudioClient_GetService(d->client, &IID_IAudioRenderClient, (void **)&d->render);
    if (FAILED(hr)) goto fail;
    d->mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &d->mmcss_task);
    if (d->mmcss) AvSetMmThreadPriority(d->mmcss, AVRT_PRIORITY_HIGH);
    *error_out = 0; return d;
fail:
    *error_out = (int32_t)hr; aya_device_close(d); return NULL;
}
int aya_device_frames(void *opaque) { return (int)((AyaDevice *)opaque)->frames; }
int32_t aya_device_start(void *opaque) { return (int32_t)IAudioClient_Start(((AyaDevice *)opaque)->client); }
int aya_device_wait(void *opaque, int milliseconds) {
    DWORD status = WaitForSingleObject(((AyaDevice *)opaque)->event, (DWORD)milliseconds);
    if (status == WAIT_OBJECT_0) return 1;
    if (status == WAIT_TIMEOUT) return 0;
    return -1;
}
int aya_device_begin(void *opaque) {
    AyaDevice *d = (AyaDevice *)opaque;
    UINT32 padding;
    HRESULT hr = IAudioClient_GetCurrentPadding(d->client, &padding);
    if (FAILED(hr)) { d->error = hr; return -1; }
    UINT32 count = d->frames - padding;
    if (!count) return 0;
    if (!padding && d->packets > 1) d->starvation++;
    hr = IAudioRenderClient_GetBuffer(d->render, count, &d->buffer);
    if (FAILED(hr)) { d->error = hr; return -1; }
    d->acquired = count; return (int)count;
}
void *aya_device_buffer(void *opaque) { return ((AyaDevice *)opaque)->buffer; }
int32_t aya_device_end(void *opaque) {
    AyaDevice *d = (AyaDevice *)opaque;
    HRESULT hr = IAudioRenderClient_ReleaseBuffer(d->render, d->acquired, 0);
    d->acquired = 0; d->packets++; d->error = hr; return (int32_t)hr;
}
uint64_t aya_device_starvation(void *opaque) { return ((AyaDevice *)opaque)->starvation; }
int32_t aya_device_error(void *opaque) { return (int32_t)((AyaDevice *)opaque)->error; }
