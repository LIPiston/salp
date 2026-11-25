// SPDX-License-Identifier: GPL-3.0-or-later
// Small FreeRDP bridge: protocol IO stays on one worker, Flutter polls snapshots.
#include <freerdp/freerdp.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/codec/color.h>
#include <winpr/synch.h>
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#define SALP_EXPORT extern "C" __declspec(dllexport)
#else
#define SALP_EXPORT extern "C" __attribute__((visibility("default")))
#endif

struct Bridge;
struct Context { rdpContext base; Bridge* bridge; };
struct Input { int type, flags, x, y; };
struct Bridge {
  std::mutex mutex;
  std::condition_variable cert_ready;
  std::thread worker;
  std::atomic<bool> stop{false};
  std::atomic<int> state{0}; // 0 connecting, 1 connected, 2 certificate, 3 stopped, -1 failed
  freerdp* instance = nullptr;
  bool locked = false, dirty = false;
  int width = 0, height = 0, cert_answer = -1;
  std::atomic<uint32_t> error{0};
  std::string certificate;
  std::vector<uint8_t> pixels;
  std::deque<Input> inputs;
};
static Bridge* bridge(rdpContext* context) { return reinterpret_cast<Context*>(context)->bridge; }
static BOOL paint(rdpContext* context) {
  auto* b = bridge(context);
  auto* gdi = context->gdi;
  if (!gdi || gdi->width <= 0 || gdi->height <= 0 || gdi->width > 4096 || gdi->height > 4096) return FALSE;
  std::lock_guard<std::mutex> lock(b->mutex);
  if (b->locked || b->stop) return TRUE;
  b->width = gdi->width; b->height = gdi->height;
  b->pixels.resize(static_cast<size_t>(b->width) * b->height * 4);
  for (int row = 0; row < b->height; row++) {
    memcpy(b->pixels.data() + static_cast<size_t>(row) * b->width * 4,
           gdi->primary_buffer + static_cast<size_t>(row) * gdi->stride,
           static_cast<size_t>(b->width) * 4);
  }
  b->dirty = true;
  return TRUE;
}
static BOOL resized(rdpContext* context) {
  const auto width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
  const auto height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
  if (width > 4096 || height > 4096 || width == 0 || height == 0) return FALSE;
  return gdi_resize(context->gdi, width, height);
}
static BOOL connected(freerdp* instance) {
  if (!gdi_init(instance, PIXEL_FORMAT_RGBA32)) return FALSE;
  instance->context->update->EndPaint = paint;
  instance->context->update->DesktopResize = resized;
  bridge(instance->context)->state = 1;
  return TRUE;
}
static DWORD verify(freerdp* instance, const char* host, UINT16 port,
                    const char* common_name, const char* subject, const char* issuer,
                    const char* fingerprint, DWORD) {
  auto* b = bridge(instance->context);
  std::unique_lock<std::mutex> lock(b->mutex);
  if (b->stop || b->locked) return 0;
  b->certificate = std::string(host ? host : "") + ":" + std::to_string(port) + "\n" +
      (common_name ? common_name : "") + "\n" + (subject ? subject : "") + "\n" +
      (issuer ? issuer : "") + "\n" + (fingerprint ? fingerprint : "");
  if (b->certificate.size() > 16384) return 0;
  b->cert_answer = -1; b->state = 2;
  const bool answered = b->cert_ready.wait_for(lock, std::chrono::minutes(2), [b] {
    return b->cert_answer != -1 || b->stop || b->locked;
  });
  b->state = 0;
  return answered && b->cert_answer == 1 && !b->stop && !b->locked ? 2 : 0;
}
static DWORD changed(freerdp* instance, const char* host, UINT16 port,
    const char* common_name, const char* subject, const char* issuer,
    const char* fingerprint, const char*, const char*, const char*, DWORD flags) {
  return verify(instance, host, port, common_name, subject, issuer, fingerprint, flags);
}
static BOOL authenticate(freerdp*, char**, char**, char**, rdp_auth_reason) { return FALSE; }

SALP_EXPORT void* salp_rdp_start(const char* host, int port, const char* username,
                               const char* password, const char* domain,
                               const char* certificate_name, const char* config_directory, int width, int height) {
  if (!host || !username || !password || !domain || !certificate_name || !config_directory || !*config_directory || port < 1 || port > 65535 ||
      width < 200 || height < 200 || width > 4096 || height > 4096) return nullptr;
#ifdef __ANDROID__
  // WinPR's Android path patch reads this application-specific location. Do not
  // modify HOME/XDG or depend on desktop paths that do not exist in an APK.
  if (setenv("SALP_RDP_PRIVATE_DIR", config_directory, 1) != 0) return nullptr;
#endif
  auto* b = new Bridge();
  std::string address(host), user(username), secret(password), realm(domain), cert_name(certificate_name), config(config_directory);
  b->worker = std::thread([b, address, port, user, secret, realm, cert_name, config, width, height]() mutable {
    auto* instance = freerdp_new();
    if (!instance) { b->state = -1; return; }
    instance->ContextSize = sizeof(Context);
    if (!freerdp_context_new(instance)) { freerdp_free(instance); b->state = -1; return; }
    reinterpret_cast<Context*>(instance->context)->bridge = b;
    { std::lock_guard<std::mutex> lock(b->mutex); b->instance = instance; }
    instance->PostConnect = connected;
    instance->VerifyCertificateEx = verify;
    instance->VerifyChangedCertificateEx = changed;
    instance->AuthenticateEx = authenticate;
    auto* settings = instance->context->settings;
    const bool configured =
      freerdp_settings_set_string(settings, FreeRDP_ConfigPath, config.c_str()) &&
      freerdp_settings_set_string(settings, FreeRDP_ActionScript, "") &&
      freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, FALSE) &&
      freerdp_settings_set_string(settings, FreeRDP_ServerHostname, address.c_str()) &&
      freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, port) &&
      freerdp_settings_set_string(settings, FreeRDP_Username, user.c_str()) &&
      freerdp_settings_set_string(settings, FreeRDP_Password, secret.c_str()) &&
      freerdp_settings_set_string(settings, FreeRDP_Domain, realm.c_str()) &&
      freerdp_settings_set_string(settings, FreeRDP_CertificateName, cert_name.c_str()) &&
      freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, width) &&
      freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, height) &&
      freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
      freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE) &&
      freerdp_settings_set_bool(settings, FreeRDP_NSCodec, TRUE) &&
      freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE) &&
      freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
      freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE) &&
      freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE) &&
      freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, FALSE);
    std::fill(secret.begin(), secret.end(), '\0');
    const bool ok = configured && !b->stop && freerdp_connect(instance);
    if (ok) {
      while (!b->stop && !freerdp_shall_disconnect_context(instance->context)) {
        {
          std::lock_guard<std::mutex> lock(b->mutex);
          if (!b->locked) {
            for (const auto& input : b->inputs) {
              if (input.type == 0) freerdp_input_send_mouse_event(instance->context->input, input.flags, input.x, input.y);
              else if (input.type == 1) freerdp_input_send_keyboard_event(instance->context->input, input.flags, static_cast<UINT8>(input.x));
              else if (input.type == 2) freerdp_input_send_unicode_keyboard_event(instance->context->input, input.flags, input.x);
            }
          }
          b->inputs.clear();
        }
        HANDLE events[64];
        const DWORD count = freerdp_get_event_handles(instance->context, events, 64);
        if (count == 0) break;
        const auto wait = WaitForMultipleObjects(count, events, FALSE, 20);
        if (wait == WAIT_FAILED || !freerdp_check_event_handles(instance->context)) break;
      }
    }
    b->error = freerdp_get_last_error(instance->context);
    freerdp_disconnect(instance);
    if (instance->context->gdi) gdi_free(instance);
    { std::lock_guard<std::mutex> lock(b->mutex); b->instance = nullptr; }
    freerdp_context_free(instance); freerdp_free(instance);
    b->state = b->stop || ok ? 3 : -1;
  });
  return b;
}
SALP_EXPORT int salp_rdp_state(void* handle) { return static_cast<Bridge*>(handle)->state.load(); }
SALP_EXPORT uint32_t salp_rdp_error(void* handle) { return static_cast<Bridge*>(handle)->error.load(); }
SALP_EXPORT int salp_rdp_frame(void* handle, uint8_t* output, int capacity, int* width, int* height) {
  auto* b = static_cast<Bridge*>(handle);
  std::lock_guard<std::mutex> lock(b->mutex);
  *width = b->width; *height = b->height;
  if (b->locked || !b->dirty || b->pixels.empty()) return 0;
  const auto size = static_cast<int>(b->pixels.size());
  if (capacity < size || !output) return -size;
  memcpy(output, b->pixels.data(), size); b->dirty = false;
  return size;
}
SALP_EXPORT int salp_rdp_certificate(void* handle, char* output, int capacity) {
  auto* b = static_cast<Bridge*>(handle);
  std::lock_guard<std::mutex> lock(b->mutex);
  if (b->locked || b->state != 2 || capacity <= 0) return 0;
  const auto length = std::min(static_cast<int>(b->certificate.size()), capacity - 1);
  memcpy(output, b->certificate.data(), length); output[length] = 0; return length;
}
SALP_EXPORT void salp_rdp_trust(void* handle, int accept) {
  auto* b = static_cast<Bridge*>(handle);
  std::lock_guard<std::mutex> lock(b->mutex);
  if (b->state == 2) { b->cert_answer = !b->locked && accept == 1 ? 1 : 0; b->cert_ready.notify_all(); }
}
SALP_EXPORT int salp_rdp_input(void* handle, int type, int flags, int x, int y) {
  auto* b = static_cast<Bridge*>(handle);
  std::lock_guard<std::mutex> lock(b->mutex);
  if (b->state != 1 || b->locked || b->stop || b->inputs.size() >= 128) return 0;
  b->inputs.push_back({type, flags, x, y}); return 1;
}
SALP_EXPORT void salp_rdp_lock(void* handle, int locked) {
  auto* b = static_cast<Bridge*>(handle);
  std::lock_guard<std::mutex> lock(b->mutex);
  b->locked = locked != 0; b->inputs.clear();
  b->cert_ready.notify_all();
}
SALP_EXPORT void salp_rdp_stop(void* handle) {
  auto* b = static_cast<Bridge*>(handle);
  b->stop = true; b->cert_ready.notify_all();
  std::lock_guard<std::mutex> lock(b->mutex);
  if (b->instance) freerdp_abort_connect_context(b->instance->context);
}
SALP_EXPORT void salp_rdp_free(void* handle) {
  auto* b = static_cast<Bridge*>(handle);
  if (b->worker.joinable()) b->worker.join();
  delete b;
}
