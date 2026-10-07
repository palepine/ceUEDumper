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

// returns required byte count including trailing NUL
// passing a buffer copies as much as fits and always NUL-terminates it
CEUE_API std::uint32_t ceue_get_last_error( char *buffer, std::uint32_t capacity );
