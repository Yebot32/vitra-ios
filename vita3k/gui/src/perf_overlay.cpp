// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

// Suppress MacTypes.h Ptr/Handle typedefs that conflict with vita3k Ptr<T>.
// Must be first before any include that reaches MacTypes.h.
#ifdef __APPLE__
#define __MACTYPES__
typedef unsigned char           UInt8;
typedef unsigned short          UInt16;
typedef unsigned int            UInt32;
typedef unsigned long long      UInt64;
typedef signed char             SInt8;
typedef signed short            SInt16;
typedef signed int              SInt32;
typedef signed long long        SInt64;
typedef unsigned char           Boolean;
typedef float                   Float32;
typedef double                  Float64;
typedef unsigned short          UniChar;
typedef unsigned int            UTF32Char;
typedef unsigned short          UTF16Char;
typedef unsigned char           UTF8Char;
typedef const UniChar *         ConstUniCharPtr;
typedef UInt32                  UniCharCount;
typedef unsigned char *         StringPtr;
typedef const unsigned char *   ConstStringPtr;
typedef unsigned char           Str255[256];
typedef unsigned char           Str63[64];
typedef unsigned char           Str32[33];
typedef unsigned char           Str15[16];
typedef const unsigned char *   ConstStr255Param;
typedef const unsigned char *   ConstStr63Param;
typedef const unsigned char *   ConstStr32Param;
typedef SInt32                  OSStatus;
typedef SInt16                  OSErr;
typedef unsigned int            FourCharCode;
typedef FourCharCode            OSType;
typedef FourCharCode            ResType;
typedef long                    Size;
typedef long                    LogicalAddress;
typedef unsigned long           ByteCount;
typedef unsigned long           ByteOffset;
typedef UInt32                  OptionBits;
typedef UInt32                  ItemCount;
typedef SInt32                  Fixed;
typedef Fixed *                 FixedPtr;
typedef SInt32                  Fract;
typedef SInt32                  ShortFixed;
typedef SInt16                  LangCode;
typedef SInt16                  RegionCode;
typedef SInt16                  ScriptCode;
// 'Ptr' and 'Handle' omitted — conflict with vita3k class Ptr<T>.
#endif

#include "private.h"

#include <config/state.h>

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#if TARGET_OS_IOS
#include <sys/mman.h>
#include "ios/ios_platform.h"
#endif

namespace gui {

static const ImVec2 PERF_OVERLAY_PAD      = ImVec2(12.f, 12.f);
static const ImVec4 PERF_OVERLAY_BG_COLOR = ImVec4(0.282f, 0.239f, 0.545f, 0.8f);

// ── Helpers ──────────────────────────────────────────────────────────────────

static ImVec2 get_perf_pos(ImVec2 window_size, EmuEnvState &emuenv) {
    const auto TOP    = emuenv.logical_viewport_pos.y - PERF_OVERLAY_PAD.y;
    const auto LEFT   = emuenv.logical_viewport_pos.x - PERF_OVERLAY_PAD.x;
    const auto CENTER = emuenv.logical_viewport_pos.x + (emuenv.logical_viewport_size.x / 2.f) - (window_size.x / 2.f);
    const auto RIGHT  = emuenv.logical_viewport_pos.x + emuenv.logical_viewport_size.x - window_size.x + PERF_OVERLAY_PAD.x;
    const auto BOTTOM = emuenv.logical_viewport_pos.y + emuenv.logical_viewport_size.y - window_size.y + PERF_OVERLAY_PAD.y;

    switch (emuenv.cfg.performance_overlay_position) {
    case TOP_CENTER:    return ImVec2(CENTER, TOP);
    case TOP_RIGHT:     return ImVec2(RIGHT,  TOP);
    case BOTTOM_LEFT:   return ImVec2(LEFT,   BOTTOM);
    case BOTTOM_CENTER: return ImVec2(CENTER, BOTTOM);
    case BOTTOM_RIGHT:  return ImVec2(RIGHT,  BOTTOM);
    case TOP_LEFT:
    default: break;
    }
    return ImVec2(LEFT, TOP);
}

// Detects at runtime whether the dynarmic JIT recompiler is active.
// On iOS, JIT requires the dynamic-codesigning entitlement. We probe it
// once by attempting a MAP_JIT mmap — if denied, we're on the interpreter.
static bool jit_is_active(const EmuEnvState &emuenv) {
    if (!emuenv.cfg.cpu_opt)
        return false; // user forced interpreter

#if TARGET_OS_IOS
    static int s_jit_ok = -1; // -1 = not yet probed
    if (s_jit_ok == -1) {
#ifdef MAP_JIT
        void *p = mmap(nullptr, 4096,
                       PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
        if (p != MAP_FAILED) {
            munmap(p, 4096);
            s_jit_ok = 1;
        } else {
            s_jit_ok = 0;
        }
#else
        s_jit_ok = 0;
#endif
    }
    return s_jit_ok == 1;
#else
    return true; // desktop: JIT always available when cpu_opt is on
#endif
}

// ── Full performance overlay (unchanged behaviour) ────────────────────────────

void draw_perf_overlay(GuiState &gui, EmuEnvState &emuenv) {
    auto lang = gui.lang.performance_overlay;

    const ImVec2 RES_SCALE(emuenv.gui_scale.x, emuenv.gui_scale.y);
    const ImVec2 SCALE(RES_SCALE.x * emuenv.manual_dpi_scale, RES_SCALE.y * emuenv.manual_dpi_scale);

    const auto SCALED_FONT_SIZE = ImGui::GetFontSize() * (0.7f * RES_SCALE.y);
    const auto FONT_SCALE       = SCALED_FONT_SIZE / ImGui::GetFontSize();

    const auto FPS_TEXT = emuenv.cfg.performance_overlay_detail == MINIMUM
        ? fmt::format("FPS: {}", emuenv.fps)
        : fmt::format("FPS: {} {}: {}", emuenv.fps, lang["avg"], emuenv.avg_fps);
    const auto MIN_MAX_FPS_TEXT = fmt::format("{}: {} {}: {}",
        lang["min"], emuenv.min_fps, lang["max"], emuenv.max_fps);

    const ImVec2 TOTAL_WINDOW_PADDING(
        ImGui::GetStyle().WindowPadding.x * 2,
        ImGui::GetStyle().WindowPadding.y * 2);

    const auto MAX_TEXT_WIDTH_SCALED = std::max(
        ImGui::CalcTextSize(FPS_TEXT.c_str()).x,
        emuenv.cfg.performance_overlay_detail == MINIMUM
            ? 0.f : ImGui::CalcTextSize(MIN_MAX_FPS_TEXT.c_str()).x) * FONT_SCALE;
    const auto MAX_TEXT_HEIGHT_SCALED = SCALED_FONT_SIZE
        + (emuenv.cfg.performance_overlay_detail >= MEDIUM
            ? SCALED_FONT_SIZE + (ImGui::GetStyle().ItemSpacing.y * 2.f) : 0.f);

    const ImVec2 WINDOW_SIZE(
        MAX_TEXT_WIDTH_SCALED + TOTAL_WINDOW_PADDING.x,
        MAX_TEXT_HEIGHT_SCALED + TOTAL_WINDOW_PADDING.y);
    const ImVec2 MAIN_WINDOW_SIZE(
        WINDOW_SIZE.x + TOTAL_WINDOW_PADDING.x,
        WINDOW_SIZE.y + TOTAL_WINDOW_PADDING.y
            + (emuenv.cfg.performance_overlay_detail == MAXIMUM ? WINDOW_SIZE.y : 0.f));

    const auto WINDOW_POS = get_perf_pos(MAIN_WINDOW_SIZE, emuenv);
    ImGui::SetNextWindowSize(MAIN_WINDOW_SIZE);
    ImGui::SetNextWindowPos(WINDOW_POS);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.f);
    ImGui::Begin("##performance", nullptr,
        ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_NoMove |
        ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoSavedSettings |
        ImGuiWindowFlags_NoBringToFrontOnFocus);
    ImGui::PushStyleColor(ImGuiCol_ChildBg, PERF_OVERLAY_BG_COLOR);
    ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, 5.f * SCALE.x);
    ImGui::BeginChild("#perf_stats", WINDOW_SIZE, ImGuiChildFlags_Borders,
        ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoDecoration |
        ImGuiWindowFlags_NoSavedSettings);

    ImGui::SetWindowFontScale(0.7f * RES_SCALE.y);
    ImGui::Text("%s", FPS_TEXT.c_str());
    if (emuenv.cfg.performance_overlay_detail >= PerformanceOverlayDetail::MEDIUM) {
        ImGui::Separator();
        ImGui::Text("%s", MIN_MAX_FPS_TEXT.c_str());
    }
    ImGui::EndChild();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
    if (emuenv.cfg.performance_overlay_detail == PerformanceOverlayDetail::MAXIMUM) {
        ImGui::SetCursorPosY(ImGui::GetCursorPosY() - ImGui::GetStyle().ItemSpacing.y);
        ImGui::PlotLines("##fps_graphic", emuenv.fps_values, IM_ARRAYSIZE(emuenv.fps_values),
            emuenv.current_fps_offset, nullptr,
            0.f, static_cast<float>(emuenv.max_fps), WINDOW_SIZE);
    }
    ImGui::End();
    ImGui::PopStyleVar();
}

// ── Compact always-on FPS counter ────────────────────────────────────────────

void draw_fps_overlay(GuiState & /*gui*/, EmuEnvState &emuenv) {
    if (!emuenv.cfg.show_fps_overlay) return;

    const ImVec2 RES_SCALE(emuenv.gui_scale.x, emuenv.gui_scale.y);
    const float  FONT_SCALE = 0.65f * RES_SCALE.y;
    const float  pad        = 6.f * RES_SCALE.x;

    const auto   text = fmt::format("{} FPS", emuenv.fps);
    const float  tw   = ImGui::CalcTextSize(text.c_str()).x * FONT_SCALE;
    const float  th   = ImGui::GetFontSize() * FONT_SCALE;
    const float  w    = tw + pad * 2.f;
    const float  h    = th + pad * 2.f;

    // Always top-right corner of the viewport
    const ImVec2 pos(
        emuenv.logical_viewport_pos.x + emuenv.logical_viewport_size.x - w - 4.f,
        emuenv.logical_viewport_pos.y + 4.f);

    ImGui::SetNextWindowPos(pos);
    ImGui::SetNextWindowSize({w, h});
    ImGui::SetNextWindowBgAlpha(0.55f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 4.f * RES_SCALE.x);
    ImGui::Begin("##fps_compact", nullptr,
        ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoInputs |
        ImGuiWindowFlags_NoMove       | ImGuiWindowFlags_NoSavedSettings |
        ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoNav);

    ImGui::SetWindowFontScale(FONT_SCALE);

    // Green ≥55, orange 30-54, red <30
    const ImVec4 col = (emuenv.fps >= 55) ? ImVec4(0.3f, 1.f, 0.4f, 1.f)
                     : (emuenv.fps >= 30) ? ImVec4(1.f, 0.75f, 0.2f, 1.f)
                                          : ImVec4(1.f, 0.3f, 0.3f, 1.f);
    ImGui::TextColored(col, "%s", text.c_str());

    ImGui::End();
    ImGui::PopStyleVar(2);
}

// ── JIT indicator ─────────────────────────────────────────────────────────────

void draw_jit_indicator(GuiState & /*gui*/, EmuEnvState &emuenv) {
    if (!emuenv.cfg.show_jit_indicator) return;

    const ImVec2 RES_SCALE(emuenv.gui_scale.x, emuenv.gui_scale.y);
    const float  FONT_SCALE = 0.6f * RES_SCALE.y;
    const float  pad        = 5.f * RES_SCALE.x;

    const bool   jit    = jit_is_active(emuenv);
    const char  *label  = jit ? "JIT" : "INT";
    const ImVec4 bg_col = jit
        ? ImVec4(0.08f, 0.55f, 0.15f, 0.82f)  // green  — JIT active
        : ImVec4(0.65f, 0.10f, 0.10f, 0.82f); // red    — interpreter fallback

    const float tw  = ImGui::CalcTextSize(label).x * FONT_SCALE;
    const float th  = ImGui::GetFontSize() * FONT_SCALE;
    const float w   = tw + pad * 2.f;
    const float h   = th + pad * 2.f;

    // Stack below the FPS counter if both are visible
    const float fps_h_offset = emuenv.cfg.show_fps_overlay ? (h + 2.f) : 0.f;
    const ImVec2 pos(
        emuenv.logical_viewport_pos.x + emuenv.logical_viewport_size.x - w - 4.f,
        emuenv.logical_viewport_pos.y + 4.f + fps_h_offset);

    ImGui::SetNextWindowPos(pos);
    ImGui::SetNextWindowSize({w, h});
    ImGui::SetNextWindowBgAlpha(0.f); // custom coloured background via draw list
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.f);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 4.f * RES_SCALE.x);
    ImGui::Begin("##jit_indicator", nullptr,
        ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoInputs |
        ImGuiWindowFlags_NoMove       | ImGuiWindowFlags_NoSavedSettings |
        ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoNav);

    // Filled rounded rect background
    ImDrawList *dl  = ImGui::GetWindowDrawList();
    const ImVec2 p0 = ImGui::GetWindowPos();
    const ImVec2 p1 = {p0.x + w, p0.y + h};
    dl->AddRectFilled(p0, p1,
        ImGui::ColorConvertFloat4ToU32(bg_col), 4.f * RES_SCALE.x);

    ImGui::SetWindowFontScale(FONT_SCALE);
    ImGui::SetCursorPos({pad, pad});
    ImGui::TextColored({1.f, 1.f, 1.f, 1.f}, "%s", label);

#if TARGET_OS_IOS
    // Show a warning dot when thermal throttle is active
    if (ios::get_frame_pacing().throttleRequested.load()) {
        ImGui::SameLine(0, 3.f);
        ImGui::TextColored({1.f, 0.55f, 0.1f, 1.f}, "!");
    }
#endif

    ImGui::End();
    ImGui::PopStyleVar(2);
}

} // namespace gui
