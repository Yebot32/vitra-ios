// ============================================================================
// vita3k/ios/ios_overlay.mm
// On-screen PS Vita controller overlay — iOS implementation.
// ============================================================================

#include "ios_overlay.h"

#if TARGET_OS_IOS

#include <emuenv/state.h>
#include <gui/state.h>
#include <touch/functions.h>
#include <util/log.h>

#include <SDL3/SDL_joystick.h>
#include <SDL3/SDL_events.h>

#import <Foundation/Foundation.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <vector>

// We pull in imgui directly — the gui module already links it.
#include <imgui.h>

// ============================================================================
// SDL virtual joystick state
// ============================================================================
static int  s_joystick_id  = -1;
static SDL_Joystick *s_joystick = nullptr;

// ============================================================================
// Overlay config
// ============================================================================
static bool  s_visible  = true;
static float s_scale    = 1.0f;
static float s_opacity  = 0.75f; // 0..1
static bool  s_editing  = false;

// ============================================================================
// Button / zone descriptors
// ============================================================================
// Positions are stored as fractions of the viewport (0..1 × 0..1) so they
// survive orientation changes and different screen sizes.

enum class BtnId : int {
    // D-pad
    DpadUp = 0, DpadDown, DpadLeft, DpadRight,
    // Face
    Cross, Circle, Square, Triangle,
    // Shoulders
    L1, R1, L2, R2,
    // Center
    Start, Select, PS,
    // Sticks (virtual joystick zones, not discrete buttons)
    LeftStick, RightStick,
    _Count
};

constexpr int BTN_COUNT = static_cast<int>(BtnId::_Count);

// Default normalized positions [0..1] relative to the logical viewport
static const float DEFAULT_POS[BTN_COUNT][2] = {
    // DpadUp      DpadDown    DpadLeft    DpadRight
    {0.085f,0.42f},{0.085f,0.62f},{0.045f,0.52f},{0.125f,0.52f},
    // Cross       Circle      Square      Triangle
    {0.88f,0.62f}, {0.92f,0.50f},{0.84f,0.50f},{0.88f,0.38f},
    // L1          R1          L2          R2
    {0.06f,0.12f}, {0.94f,0.12f},{0.06f,0.03f},{0.94f,0.03f},
    // Start       Select      PS
    {0.60f,0.88f}, {0.40f,0.88f},{0.50f,0.94f},
    // LeftStick   RightStick
    {0.18f,0.72f}, {0.72f,0.72f},
};

struct ButtonZone {
    float cx = 0, cy = 0;   // center, normalized viewport coords
    float r  = 0;            // radius, normalized (square half-size for d-pad/face)
    bool  held   = false;
    int   touchId = -1;      // which finger is holding this button
    // Stick state
    float stickDx = 0, stickDy = 0; // -1..1
};

static ButtonZone s_zones[BTN_COUNT];
static bool s_layout_dirty = true;

// SDL gamepad button / axis to push for each BtnId
static const SDL_GamepadButton BTN_MAP[BTN_COUNT] = {
    SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_DOWN,
    SDL_GAMEPAD_BUTTON_DPAD_LEFT, SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
    SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST,
    SDL_GAMEPAD_BUTTON_WEST,  SDL_GAMEPAD_BUTTON_NORTH,
    SDL_GAMEPAD_BUTTON_LEFT_SHOULDER,  SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
    SDL_GAMEPAD_BUTTON_INVALID, // L2 → axis
    SDL_GAMEPAD_BUTTON_INVALID, // R2 → axis
    SDL_GAMEPAD_BUTTON_START, SDL_GAMEPAD_BUTTON_BACK, SDL_GAMEPAD_BUTTON_GUIDE,
    SDL_GAMEPAD_BUTTON_INVALID, // LeftStick
    SDL_GAMEPAD_BUTTON_INVALID, // RightStick
};

static void push_button(int btn, bool value) {
    if (!s_joystick) return;
    const auto sdl_btn = BTN_MAP[btn];
    if (sdl_btn != SDL_GAMEPAD_BUTTON_INVALID)
        SDL_SetJoystickVirtualButton(s_joystick, static_cast<int>(sdl_btn), value ? 1 : 0);
}

static void push_axis(SDL_GamepadAxis axis, float normalized) {
    if (!s_joystick) return;
    const int16_t val = static_cast<int16_t>(normalized * SDL_MAX_SINT16);
    SDL_SetJoystickVirtualAxis(s_joystick, static_cast<int>(axis), val);
}

// ============================================================================
// Layout helpers
// ============================================================================
static void rebuild_layout(const EmuEnvState &emuenv) {
    // Button radius in normalized coords (we target ~50pt at 375pt viewport width)
    const float vw = emuenv.logical_viewport_size.x;
    const float vh = emuenv.logical_viewport_size.y;
    if (vw < 1.f || vh < 1.f) return;

    const float btn_r_px = 28.f * s_scale;
    const float stick_r_px = 52.f * s_scale;

    for (int i = 0; i < BTN_COUNT; ++i) {
        auto &z = s_zones[i];
        z.cx = DEFAULT_POS[i][0];
        z.cy = DEFAULT_POS[i][1];
        const bool is_stick = (i == (int)BtnId::LeftStick || i == (int)BtnId::RightStick);
        z.r = (is_stick ? stick_r_px : btn_r_px) / std::min(vw, vh);
    }
    s_layout_dirty = false;
}

static bool hit_test(const ButtonZone &z, float nx, float ny) {
    const float dx = nx - z.cx, dy = ny - z.cy;
    return (dx*dx + dy*dy) <= (z.r * z.r * 1.2f); // slight oversize for fat fingers
}

// Viewport-normalized coordinate from pixel position
static ImVec2 to_norm(float px, float py, const EmuEnvState &emuenv) {
    return {
        (px - emuenv.logical_viewport_pos.x) / emuenv.logical_viewport_size.x,
        (py - emuenv.logical_viewport_pos.y) / emuenv.logical_viewport_size.y
    };
}

// Viewport pixel from normalized
static ImVec2 to_px(float nx, float ny, const EmuEnvState &emuenv) {
    return {
        emuenv.logical_viewport_pos.x + nx * emuenv.logical_viewport_size.x,
        emuenv.logical_viewport_pos.y + ny * emuenv.logical_viewport_size.y
    };
}

// ============================================================================
// Lifecycle
// ============================================================================
namespace ios_overlay {

void attach_controller() {
    if (s_joystick_id != -1) return;

    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type     = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.naxes    = SDL_GAMEPAD_AXIS_COUNT;
    desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    desc.name     = "Vitra Virtual Controller";

    s_joystick_id = SDL_AttachVirtualJoystick(&desc);
    if (s_joystick_id == 0) {
        LOG_ERROR("[iOS overlay] SDL_AttachVirtualJoystick failed: {}", SDL_GetError());
        return;
    }
    s_joystick = SDL_OpenJoystick(s_joystick_id);
    if (!s_joystick)
        LOG_ERROR("[iOS overlay] SDL_OpenJoystick failed: {}", SDL_GetError());
    else
        LOG_INFO("[iOS overlay] Virtual controller attached (id {})", s_joystick_id);
}

void detach_controller() {
    if (s_joystick) { SDL_CloseJoystick(s_joystick); s_joystick = nullptr; }
    if (s_joystick_id != -1) { SDL_DetachVirtualJoystick(s_joystick_id); s_joystick_id = -1; }
}

void set_visible(bool v) { s_visible = v; }
void set_scale(float sc) { s_scale = sc; s_layout_dirty = true; }
void set_opacity(int pct) { s_opacity = std::clamp(pct / 100.f, 0.f, 1.f); }
void set_edit_mode(bool e) { s_editing = e; }
void reset_layout() { s_layout_dirty = true; }

// ============================================================================
// Input handling
// ============================================================================
bool handle_finger(SDL_TouchFingerEvent &finger, const EmuEnvState &emuenv) {
    if (!s_visible) return false;
    if (s_layout_dirty) rebuild_layout(emuenv);

    // SDL finger coords are already normalized 0..1 over the entire window.
    // Convert to viewport-normalized coords.
    const float px = finger.x * emuenv.drawable_size.x * (emuenv.logical_viewport_size.x / emuenv.drawable_viewport_size.x);
    const float py = finger.y * emuenv.drawable_size.y * (emuenv.logical_viewport_size.y / emuenv.drawable_viewport_size.y);
    const auto n = to_norm(px, py, emuenv);
    const float nx = n.x, ny = n.y;

    if (finger.type == SDL_EVENT_FINGER_DOWN) {
        for (int i = 0; i < BTN_COUNT; ++i) {
            auto &z = s_zones[i];
            if (!hit_test(z, nx, ny)) continue;

            z.touchId = static_cast<int>(finger.fingerID);

            if (i == (int)BtnId::LeftStick || i == (int)BtnId::RightStick) {
                z.stickDx = 0; z.stickDy = 0;
                push_axis(i == (int)BtnId::LeftStick ? SDL_GAMEPAD_AXIS_LEFTX  : SDL_GAMEPAD_AXIS_RIGHTX, 0);
                push_axis(i == (int)BtnId::LeftStick ? SDL_GAMEPAD_AXIS_LEFTY  : SDL_GAMEPAD_AXIS_RIGHTY, 0);
            } else {
                z.held = true;
                push_button(i, true);
                // L2/R2 as axis
                if (i == (int)BtnId::L2) push_axis(SDL_GAMEPAD_AXIS_LEFT_TRIGGER,  1.f);
                if (i == (int)BtnId::R2) push_axis(SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, 1.f);
            }
            return true;
        }
        return false;
    }

    if (finger.type == SDL_EVENT_FINGER_MOTION) {
        for (int i = 0; i < BTN_COUNT; ++i) {
            auto &z = s_zones[i];
            if (z.touchId != static_cast<int>(finger.fingerID)) continue;

            if (i == (int)BtnId::LeftStick || i == (int)BtnId::RightStick) {
                // Compute offset from zone centre, scaled by zone radius
                const float vw = emuenv.logical_viewport_size.x;
                const float vh = emuenv.logical_viewport_size.y;
                float dx = (nx - z.cx) / z.r;
                float dy = (ny - z.cy) / z.r;
                // Clamp to unit circle
                const float len = std::sqrt(dx*dx + dy*dy);
                if (len > 1.f) { dx /= len; dy /= len; }
                z.stickDx = dx; z.stickDy = dy;
                push_axis(i == (int)BtnId::LeftStick ? SDL_GAMEPAD_AXIS_LEFTX  : SDL_GAMEPAD_AXIS_RIGHTX, dx);
                push_axis(i == (int)BtnId::LeftStick ? SDL_GAMEPAD_AXIS_LEFTY  : SDL_GAMEPAD_AXIS_RIGHTY, dy);
                return true;
            }
            return true; // motion on button zone — swallow but no action
        }
        return false;
    }

    if (finger.type == SDL_EVENT_FINGER_UP) {
        for (int i = 0; i < BTN_COUNT; ++i) {
            auto &z = s_zones[i];
            if (z.touchId != static_cast<int>(finger.fingerID)) continue;
            z.touchId = -1;

            if (i == (int)BtnId::LeftStick || i == (int)BtnId::RightStick) {
                z.stickDx = 0; z.stickDy = 0;
                push_axis(i == (int)BtnId::LeftStick ? SDL_GAMEPAD_AXIS_LEFTX  : SDL_GAMEPAD_AXIS_RIGHTX, 0);
                push_axis(i == (int)BtnId::LeftStick ? SDL_GAMEPAD_AXIS_LEFTY  : SDL_GAMEPAD_AXIS_RIGHTY, 0);
            } else {
                z.held = false;
                push_button(i, false);
                if (i == (int)BtnId::L2) push_axis(SDL_GAMEPAD_AXIS_LEFT_TRIGGER,  0);
                if (i == (int)BtnId::R2) push_axis(SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, 0);
            }
            return true;
        }
        return false;
    }
    return false;
}

// ============================================================================
// Rendering
// ============================================================================
// Colours — PS Vita palette
static constexpr ImU32 COL_CROSS    = IM_COL32(100, 160, 240, 255);
static constexpr ImU32 COL_CIRCLE   = IM_COL32(230,  80,  80, 255);
static constexpr ImU32 COL_SQUARE   = IM_COL32(220, 110, 180, 255);
static constexpr ImU32 COL_TRIANGLE = IM_COL32( 80, 200, 130, 255);
static constexpr ImU32 COL_DPAD     = IM_COL32(200, 200, 200, 255);
static constexpr ImU32 COL_SHOULDER = IM_COL32(160, 160, 180, 255);
static constexpr ImU32 COL_CENTER   = IM_COL32(180, 180, 190, 255);
static constexpr ImU32 COL_STICK_BG = IM_COL32( 60,  60,  80, 255);
static constexpr ImU32 COL_STICK_NB = IM_COL32(120, 120, 150, 255);
static constexpr ImU32 COL_HELD     = IM_COL32(255, 255, 255,  60);

static ImU32 apply_opacity(ImU32 col) {
    const ImVec4 c = ImGui::ColorConvertU32ToFloat4(col);
    return ImGui::ColorConvertFloat4ToU32({c.x, c.y, c.z, c.w * s_opacity});
}

static void draw_button(ImDrawList *dl, const ButtonZone &z, ImU32 col,
                        const char *label, const EmuEnvState &emuenv) {
    const auto p  = to_px(z.cx, z.cy, emuenv);
    const float r = z.r * std::min(emuenv.logical_viewport_size.x, emuenv.logical_viewport_size.y);

    const ImU32 bg = apply_opacity(col);
    dl->AddCircleFilled(p, r, bg);
    if (z.held) dl->AddCircleFilled(p, r, COL_HELD);
    dl->AddCircle(p, r, apply_opacity(IM_COL32(255,255,255,100)), 32, 1.5f);

    if (label && *label) {
        const ImVec2 tsz = ImGui::CalcTextSize(label);
        dl->AddText({p.x - tsz.x * 0.5f, p.y - tsz.y * 0.5f},
                    apply_opacity(IM_COL32(255,255,255,220)), label);
    }
}

static void draw_dpad_segment(ImDrawList *dl, const ButtonZone &z, ImU32 col,
                               int dir, // 0=up,1=dn,2=lt,3=rt
                               const EmuEnvState &emuenv) {
    const auto c  = to_px(z.cx, z.cy, emuenv);
    const float r = z.r * std::min(emuenv.logical_viewport_size.x, emuenv.logical_viewport_size.y);
    const float a = r * 0.5f;

    ImVec2 pts[4];
    switch (dir) {
        case 0: pts[0]={c.x-a,c.y-a}; pts[1]={c.x+a,c.y-a}; pts[2]={c.x,c.y-r}; pts[3]=pts[0]; break;
        case 1: pts[0]={c.x-a,c.y+a}; pts[1]={c.x+a,c.y+a}; pts[2]={c.x,c.y+r}; pts[3]=pts[0]; break;
        case 2: pts[0]={c.x-r,c.y};   pts[1]={c.x-a,c.y-a}; pts[2]={c.x-a,c.y+a}; pts[3]=pts[0]; break;
        case 3: pts[0]={c.x+r,c.y};   pts[1]={c.x+a,c.y-a}; pts[2]={c.x+a,c.y+a}; pts[3]=pts[0]; break;
        default: return;
    }
    dl->AddTriangleFilled(pts[0], pts[1], pts[2], apply_opacity(col));
}

static void draw_stick(ImDrawList *dl, const ButtonZone &z, const EmuEnvState &emuenv) {
    const auto c  = to_px(z.cx, z.cy, emuenv);
    const float r = z.r * std::min(emuenv.logical_viewport_size.x, emuenv.logical_viewport_size.y);

    dl->AddCircleFilled(c, r, apply_opacity(COL_STICK_BG));
    dl->AddCircle(c, r, apply_opacity(IM_COL32(255,255,255,60)), 32, 1.5f);

    // Nub position
    const ImVec2 nub{c.x + z.stickDx * r * 0.55f, c.y + z.stickDy * r * 0.55f};
    dl->AddCircleFilled(nub, r * 0.38f, apply_opacity(COL_STICK_NB));
}

void draw(GuiState & /*gui*/, EmuEnvState &emuenv) {
    if (!s_visible) return;
    if (s_layout_dirty) rebuild_layout(emuenv);

    // Skip if we don't have a valid viewport yet
    if (emuenv.logical_viewport_size.x < 1.f) return;

    // Invisible full-screen ImGui window — purely for draw list access
    ImGui::SetNextWindowPos({0, 0});
    ImGui::SetNextWindowSize(ImGui::GetIO().DisplaySize);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, {0,0});
    ImGui::PushStyleColor(ImGuiCol_WindowBg, {0,0,0,0});
    ImGui::Begin("##ios_overlay", nullptr,
        ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoInputs |
        ImGuiWindowFlags_NoMove       | ImGuiWindowFlags_NoSavedSettings |
        ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_NoNav);
    ImGui::PopStyleColor();
    ImGui::PopStyleVar();

    ImDrawList *dl = ImGui::GetWindowDrawList();

    // ── Analog sticks ──────────────────────────────────────────
    draw_stick(dl, s_zones[(int)BtnId::LeftStick],  emuenv);
    draw_stick(dl, s_zones[(int)BtnId::RightStick], emuenv);

    // ── D-pad (drawn as 4 triangles around a common centre) ────
    // We use DpadUp's zone position as the d-pad centre
    for (int dir = 0; dir < 4; ++dir) {
        const auto &z = s_zones[(int)BtnId::DpadUp + dir];
        draw_dpad_segment(dl, s_zones[(int)BtnId::DpadUp], apply_opacity(COL_DPAD),
                          dir, emuenv);
    }
    // Highlight pressed d-pad segment
    for (int dir = 0; dir < 4; ++dir) {
        const auto &z = s_zones[(int)BtnId::DpadUp + dir];
        if (z.held) draw_dpad_segment(dl, s_zones[(int)BtnId::DpadUp], COL_HELD, dir, emuenv);
    }

    // ── Face buttons ───────────────────────────────────────────
    draw_button(dl, s_zones[(int)BtnId::Cross],    COL_CROSS,    "\xC3\x97", emuenv); // ×
    draw_button(dl, s_zones[(int)BtnId::Circle],   COL_CIRCLE,   "O",        emuenv);
    draw_button(dl, s_zones[(int)BtnId::Square],   COL_SQUARE,   "\xE2\x96\xA1",emuenv); // □
    draw_button(dl, s_zones[(int)BtnId::Triangle], COL_TRIANGLE, "\xE2\x96\xB3",emuenv); // △

    // ── Shoulders ──────────────────────────────────────────────
    draw_button(dl, s_zones[(int)BtnId::L1], COL_SHOULDER, "L1", emuenv);
    draw_button(dl, s_zones[(int)BtnId::R1], COL_SHOULDER, "R1", emuenv);
    // L2/R2 only when PSTV mode is on
    if (emuenv.cfg.pstv_mode) {
        draw_button(dl, s_zones[(int)BtnId::L2], COL_SHOULDER, "L2", emuenv);
        draw_button(dl, s_zones[(int)BtnId::R2], COL_SHOULDER, "R2", emuenv);
    }

    // ── Centre buttons ─────────────────────────────────────────
    draw_button(dl, s_zones[(int)BtnId::Start],  COL_CENTER, "START",  emuenv);
    draw_button(dl, s_zones[(int)BtnId::Select], COL_CENTER, "SELECT", emuenv);
    draw_button(dl, s_zones[(int)BtnId::PS],     COL_CENTER, "\xE2\x8A\x95", emuenv); // PS ⊕

    // ── Edit mode highlight ────────────────────────────────────
    if (s_editing) {
        for (int i = 0; i < BTN_COUNT; ++i) {
            const auto p = to_px(s_zones[i].cx, s_zones[i].cy, emuenv);
            const float r = s_zones[i].r * std::min(emuenv.logical_viewport_size.x,
                                                     emuenv.logical_viewport_size.y);
            dl->AddCircle(p, r + 3.f, IM_COL32(255,220,0,180), 32, 2.f);
        }
    }

    ImGui::End();
}

} // namespace ios_overlay

#endif // TARGET_OS_IOS
