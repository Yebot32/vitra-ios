#pragma once
// ============================================================================
// vita3k/ios/ios_overlay.h
// On-screen PS Vita controller overlay for iOS.
//
// Draws a complete PS Vita button layout (D-pad, face buttons, shoulders,
// analog sticks, Start/Select/PS) using ImGui draw lists so it sits on top
// of the game frame without blocking SDL touch events from reaching the
// emulator's touch subsystem.
//
// Input pipeline:
//   SDL finger events → ios_overlay_handle_finger()
//       ├─ touches inside a button zone → SDL virtual joystick
//       └─ touches outside button zones → forwarded to handle_touch_event()
//
// Call sequence every frame:
//   1. ios_overlay_handle_finger() for each SDL_TouchFingerEvent
//   2. ios_overlay_draw() after gui::draw_begin() and before gui::draw_end()
// ============================================================================

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if TARGET_OS_IOS

#include <cstdint>

struct SDL_TouchFingerEvent;
struct GuiState;
struct EmuEnvState;

namespace ios_overlay {

// ---------------------------------------------------------------------------
// Lifecycle — mirrors Android's attachController / detachController JNI calls
// ---------------------------------------------------------------------------

/// Create the SDL virtual joystick. Call once at emulator init on iOS.
void attach_controller();

/// Destroy the SDL virtual joystick. Call at emulator shutdown.
void detach_controller();

// ---------------------------------------------------------------------------
// Per-frame input + rendering
// ---------------------------------------------------------------------------

/// Process one SDL finger event. Returns true if the event was consumed by
/// the overlay (i.e. it hit a button/stick zone) and should NOT be forwarded
/// to the game's touch subsystem. Returns false if the event is in free space
/// and the caller should forward it to handle_touch_event().
bool handle_finger(SDL_TouchFingerEvent &finger, const EmuEnvState &emuenv);

/// Draw the on-screen controller overlay using ImGui draw lists.
/// Call between gui::draw_begin() and gui::draw_end() while a game is running.
void draw(GuiState &gui, EmuEnvState &emuenv);

// ---------------------------------------------------------------------------
// Configuration (driven from overlay_dialog settings)
// ---------------------------------------------------------------------------

/// Show/hide the overlay. Wraps cfg.enable_gamepad_overlay.
void set_visible(bool visible);

/// Rescale all buttons by `scale` (1.0 = default).
void set_scale(float scale);

/// Set overall opacity 0-100.
void set_opacity(int opacity_pct);

/// Enter or exit layout-edit mode (buttons become draggable).
void set_edit_mode(bool editing);

/// Reset button positions to defaults.
void reset_layout();

} // namespace ios_overlay

#endif // TARGET_OS_IOS
