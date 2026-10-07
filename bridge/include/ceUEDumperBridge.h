/*
  ceUEDumper — a Cheat Engine Unreal Engine Dumper — Copyright (C) 2026 palepine

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.


  MinHook - The Minimalistic API Hooking Library for x64/x86
  Copyright (C) 2009-2017 Tsuda Kageyu.
  All rights reserved.

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:

  1. Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
  HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

  MIT License

  Copyright (c) 2022 Narknon

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.

*/

#pragma once

#include <cstddef>
#include <cstdint>

#if defined(CEUEDUMPER_BRIDGE_EXPORTS)
#define CEUE_API extern "C" __declspec(dllexport)
#else
#define CEUE_API extern "C" __declspec(dllimport)
#endif

enum class CeueHookSource : std::uint32_t
{
  Self = 0,
  Locals = 1,
  Result = 2,
};

enum class CeueValueType : std::uint32_t
{
  U8 = 1,
  U16 = 2,
  U32 = 3,
  U64 = 4,
  I8 = 5,
  I16 = 6,
  I32 = 7,
  I64 = 8,
  F32 = 9,
  F64 = 10,
  Pointer = 11,
};

enum class CeueCompareOperation : std::uint32_t
{
  Equal = 0,
  NotEqual = 1,
  Less = 2,
  LessOrEqual = 3,
  Greater = 4,
  GreaterOrEqual = 5,
  AnyBits = 6,
  AllBits = 7,
};

enum class CeueWritePhase : std::uint32_t
{
  Before = 0,
  After = 1,
};

enum CeueHookFlags : std::uint32_t
{
  CeueHookSkipOriginal = 1u << 0,
};

enum class CeueHookBackend : std::uint32_t
{
  FunctionPointer = 0,
  ScriptDispatcher = 1,
};

CEUE_API std::uint32_t ceue_bridge_version();
CEUE_API std::uint32_t ceue_bridge_abi();

// 3-stage: create/configure/enable
CEUE_API void *ceue_create_bp_hook(
                                    void *ufunction,
                                    std::uint32_t function_pointer_offset,
                                    void *expected_original,
                                    void **object_pointer,
                                    std::uint32_t flags
                                  );

// Install/configure the one process-wide Blueprint VM detour. The target must
// have the ProcessLocalScriptFunction-compatible signature:
// void(UObject* Context, FFrame& Stack, void* Result).
CEUE_API std::uint32_t ceue_configure_script_dispatcher(
                                                          void *dispatcher,
                                                          std::uint32_t frame_node_offset
                                                        );

// Create a per-UFunction record consumed by the process-wide script detour.
// Configuration is completed with the same condition/write functions used by
// ceue_create_bp_hook before the record is enabled.
CEUE_API void *ceue_create_script_hook(
                                          void *ufunction,
                                          void **object_pointer,
                                          std::uint32_t flags
                                        );

CEUE_API std::uint32_t ceue_set_frame_locals_offset( void *handle, std::uint32_t frame_locals_offset );

CEUE_API std::uint32_t ceue_add_condition(
                                            void *handle,
                                            std::uint32_t source,
                                            std::uint32_t value_type,
                                            std::uint32_t operation,
                                            std::uint32_t offset,
                                            std::uint64_t value_bits,
                                            std::uint64_t mask_bits
                                          );

CEUE_API std::uint32_t ceue_add_write(
                                        void *handle,
                                        std::uint32_t phase,
                                        std::uint32_t source,
                                        std::uint32_t value_type,
                                        std::uint32_t offset,
                                        std::uint64_t value_bits,
                                        std::uint64_t mask_bits
                                      );

CEUE_API std::uint32_t ceue_enable_bp_hook( void *handle, std::uint32_t enabled );

CEUE_API std::uint32_t ceue_remove_bp_hook( void *handle );

CEUE_API std::uint32_t ceue_remove_all_bp_hooks();

CEUE_API std::uint32_t ceue_get_hook_count();

CEUE_API std::uint64_t ceue_get_hook_hit_count(void *handle);

// returns required byte count including trailing NUL
// passing a buffer copies as much as fits and always NUL-terminates it
CEUE_API std::uint32_t ceue_get_last_error( char *buffer, std::uint32_t capacity );
