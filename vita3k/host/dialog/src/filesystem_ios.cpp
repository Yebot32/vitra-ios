// Vita3K emulator project — iOS port
// Copyright (C) 2026 Vita3K team / Vitra contributors
//
// filesystem_ios.cpp
// iOS stub for the host::dialog::filesystem API.
//
// On iOS, native file picking is done through UIDocumentPickerViewController
// which must be presented on the main thread from Objective-C/Swift code.
// This stub returns CANCEL so the emulator falls back to its internal
// game-library scanner instead of trying to open a desktop file dialog.
//
// ROM installation on iOS is handled through the Files app / AirDrop /
// the Vitra document-provider extension — not through a runtime dialog.

#include <host/dialog/filesystem.h>

namespace host::dialog::filesystem {

Result open_file(fs::path & /*resulting_path*/,
                 const std::vector<FileFilter> & /*file_filters*/,
                 const fs::path & /*default_path*/) {
    // No runtime file picker on iOS — caller must handle CANCEL gracefully.
    return Result::CANCEL;
}

Result pick_folder(fs::path & /*resulting_path*/,
                   const fs::path & /*default_path*/) {
    return Result::CANCEL;
}

std::string get_error() {
    return "File dialogs are not supported on iOS. "
           "Use the Files app or AirDrop to install content.";
}

} // namespace host::dialog::filesystem
