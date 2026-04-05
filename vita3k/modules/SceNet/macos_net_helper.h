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

#pragma once

#include <cstdint>
#include <cstring>

#if TARGET_OS_IOS
// SCDynamicStore is macOS-only. On iOS, network interface queries are not
// available to sandboxed apps — return false to signal unavailability.
#include <TargetConditionals.h>
inline bool get_primary_interface_name(char * /*dest*/, size_t /*bufferSize*/) { return false; }
inline bool get_mac_address(const char * /*hint*/, uint8_t mac[6]) {
    // Use a deterministic dummy MAC rather than crashing
    const uint8_t dummy[6] = { 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    memcpy(mac, dummy, 6);
    return false;
}
#else
bool get_primary_interface_name(char *dest, size_t bufferSize);
bool get_mac_address(const char *hint, uint8_t mac[6]);
#endif
