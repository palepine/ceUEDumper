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

#include "ceUEDumperBridge.h"

#include <MinHook.h>

#include <Windows.h>
#include <TlHelp32.h>

#include <algorithm>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>
#include <unordered_map>
#include <vector>

namespace
{
  constexpr std::uint64_t HookMagic = 0x434555454250484Bull; // "CEUEBPHK"
  constexpr std::size_t MaximumConditions = 32;
  constexpr std::size_t MaximumWrites = 32;
  constexpr std::uint32_t LocalsOffsetUnavailable = 0xFFFFFFFFu;

  using UnrealFunction = void(__fastcall *)(void *context, void *frame, void *result);
  using ProcessEventFunction = void(__fastcall *)(void *object, void *ufunction, void *parameters);

  enum class HookBackend
  {
    FunctionPointer,
    ScriptDispatcher,
  };

  struct ValueDescriptor
  {
    CeueHookSource source{};
    CeueValueType type{};
    std::uint32_t offset{};
    std::uint64_t value_bits{};
    std::uint64_t mask_bits{};
  };

  struct Condition : ValueDescriptor
  {
    CeueCompareOperation operation{};
  };

  struct Write : ValueDescriptor
  {
    CeueWritePhase phase{};
  };

  struct HookRecord
  {
    std::uint64_t magic{ HookMagic };
    void *ufunction{};
    HookBackend backend{ HookBackend::FunctionPointer };
    void **function_slot{};
    UnrealFunction original{};
    void *thunk{};
    void **object_pointer{};
    std::uint32_t flags{};
    std::uint32_t frame_locals_offset{ LocalsOffsetUnavailable };
    std::atomic<std::uint32_t> active_calls{};
    std::atomic<std::uint64_t> hit_count{};
    std::atomic<bool> enabled{};
    std::size_t condition_count{};
    std::size_t write_count{};
    Condition conditions[ MaximumConditions ]{};
    Write writes[ MaximumWrites ]{};
  };

  struct InvocationRecord
  {
    void *object{};
    void *ufunction{};
    std::vector<std::byte> parameters;
    std::atomic<CeueInvocationStatus> status{ CeueInvocationStatus::Queued };
    std::atomic<std::uint32_t> completed_runs{};
    std::atomic<bool> release_when_terminal{};
    std::uint32_t remaining_runs{ 1 };
    std::uint32_t interval_dispatches{};
    std::uint32_t dispatches_until_run{};
  };

  std::mutex g_hook_mutex;
  std::unordered_set<HookRecord *> g_hooks;
  std::unordered_multimap<void *, HookRecord *> g_script_hooks;
  std::vector<HookRecord *> g_retired_hooks;
  std::atomic<std::uint32_t> g_enabled_script_hook_count{};
  std::atomic<std::uint32_t> g_active_script_dispatches{};
  UnrealFunction g_script_dispatcher_original{};
  void *g_script_dispatcher_target{};
  std::uint32_t g_frame_node_offset{ 0x08 };
  bool g_minhook_initialized{};
  bool g_script_dispatcher_created{};
  bool g_script_dispatcher_enabled{};
  std::mutex g_invocation_mutex;
  std::unordered_set<InvocationRecord *> g_invocations;
  std::deque<InvocationRecord *> g_invocation_queue;
  std::atomic<std::uint32_t> g_pending_invocation_count{};
  std::atomic<std::uint32_t> g_active_process_event_dispatches{};
  std::atomic<DWORD> g_scheduler_thread_id{};
  ProcessEventFunction g_process_event_original{};
  void *g_process_event_target{};
  bool g_process_event_dispatcher_created{};
  bool g_process_event_dispatcher_enabled{};
  thread_local std::string g_last_error;

  void set_error(std::string message)
  {
    g_last_error = std::move(message);
  }

  template <typename T>
  bool safe_read( const void *address, T &value )
  {
    if (!address)
    {
      return false;
    }

    __try
    {
      value = *static_cast< const volatile T * >(address);
      return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
      return false;
    }
  }

  template <typename T>
  bool safe_write( void *address, T value )
  {
    if (!address)
    {
      return false;
    }

    __try
    {
      *static_cast< volatile T * >(address) = value;
      return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
      return false;
    }
  }

  bool safe_copy( void *destination, const void *source, std::size_t size )
  {
    if (size == 0)
    {
      return true;
    }
    if ( !destination || !source )
    {
      return false;
    }

    __try
    {
      std::memcpy( destination, source, size );
      return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
      return false;
    }
  }

  bool valid_source(std::uint32_t source)
  {
    return source <= static_cast<std::uint32_t>( CeueHookSource::Result );
  }

  bool valid_type(std::uint32_t type)
  {
    return type >= static_cast<std::uint32_t>( CeueValueType::U8 ) && type <= static_cast<std::uint32_t>( CeueValueType::Pointer );
  }

  std::size_t value_size(CeueValueType type)
  {
    switch (type)
    {
    case CeueValueType::U8:
    case CeueValueType::I8:
      return 1;
    case CeueValueType::U16:
    case CeueValueType::I16:
      return 2;
    case CeueValueType::U32:
    case CeueValueType::I32:
    case CeueValueType::F32:
      return 4;
    case CeueValueType::U64:
    case CeueValueType::I64:
    case CeueValueType::F64:
    case CeueValueType::Pointer:
      return 8;
    }
    return 0;
  }

  HookRecord *checked_handle(void *handle)
  {
    auto *record = static_cast< HookRecord * >(handle);
    std::scoped_lock lock(g_hook_mutex);
    return record && g_hooks.contains(record) && record->magic == HookMagic ? record : nullptr;
  }

  InvocationRecord *checked_invocation(void *handle)
  {
    auto *record = static_cast< InvocationRecord* >(handle);
    std::scoped_lock lock( g_invocation_mutex );
    return record && g_invocations.contains(record) ? record : nullptr;
  }

  void *resolve_source( HookRecord &record, CeueHookSource source, void *context, void *frame, void *result )
  {
    if (source == CeueHookSource::Self)
    {
      return context;
    }
    if (source == CeueHookSource::Result)
    {
      return result;
    }
    if (record.frame_locals_offset == LocalsOffsetUnavailable || !frame)
    {
      return nullptr;
    }

    void *locals{};
    const auto address = static_cast<const std::byte *>(frame) + record.frame_locals_offset;
    return safe_read(address, locals) ? locals : nullptr;
  }

  bool descriptor_address( HookRecord &record, const ValueDescriptor &descriptor, void *context, void *frame, void *result, void *&address )
  {
    void *base = resolve_source( record, descriptor.source, context, frame, result );
    if (!base)
    {
      return false;
    }

    const auto base_value = reinterpret_cast<std::uintptr_t>(base);
    
    if (descriptor.offset > std::numeric_limits< std::uintptr_t >::max() - base_value)
    {
      return false;
    }

    address = reinterpret_cast<void *>( base_value + descriptor.offset );
    return true;
  }

  template <typename T>
  T bits_as(std::uint64_t bits)
  {
    if constexpr (sizeof(T) == 8)
    {
      return std::bit_cast<T>(bits);
    }
    else
    {
      const auto narrowed = static_cast<std::uint32_t>(bits);
      return std::bit_cast<T>(narrowed);
    }
  }

  template <typename T>
  bool compare_ordered( T actual, T expected, CeueCompareOperation operation )
  {
    switch (operation)
    {
    case CeueCompareOperation::Equal:
      return actual == expected;
    case CeueCompareOperation::NotEqual:
      return actual != expected;
    case CeueCompareOperation::Less:
      return actual < expected;
    case CeueCompareOperation::LessOrEqual:
      return actual <= expected;
    case CeueCompareOperation::Greater:
      return actual > expected;
    case CeueCompareOperation::GreaterOrEqual:
      return actual >= expected;
    default:
      return false;
    }
  }

  template <typename T>
  bool compare_integral( T actual, T expected, T mask, CeueCompareOperation operation )
  {
    if (mask != 0 && (operation == CeueCompareOperation::Equal || operation == CeueCompareOperation::NotEqual))
    {
      const bool equal = (actual & mask) == (expected & mask);
      return operation == CeueCompareOperation::Equal ? equal : !equal;
    }
    if (operation == CeueCompareOperation::AnyBits)
    {
      return (actual & mask) != 0;
    }
    if (operation == CeueCompareOperation::AllBits)
    {
      return (actual & mask) == mask;
    }
    return compare_ordered( actual, expected, operation );
  }

  template <typename T>
  bool read_and_compare( const void *address, const Condition &condition )
  {
    T actual{};
    if ( !safe_read( address, actual ) )
    {
      return false;
    }
    return compare_integral( actual, static_cast<T>( condition.value_bits ), static_cast<T>( condition.mask_bits ), condition.operation );
  }

  bool condition_matches( HookRecord &record, const Condition &condition, void *context, void *frame, void *result )
  {
    void *address{};
    if ( !descriptor_address( record, condition, context, frame, result, address ) )
    {
      return false;
    }

    switch (condition.type)
    {
    case CeueValueType::U8:
      return read_and_compare<std::uint8_t>( address, condition );
    case CeueValueType::U16:
      return read_and_compare<std::uint16_t>( address, condition );
    case CeueValueType::U32:
      return read_and_compare<std::uint32_t>( address, condition );
    case CeueValueType::U64:
    case CeueValueType::Pointer:
      return read_and_compare<std::uint64_t>( address, condition );
    case CeueValueType::I8:
      return read_and_compare<std::int8_t>( address, condition );
    case CeueValueType::I16:
      return read_and_compare<std::int16_t>( address, condition );
    case CeueValueType::I32:
      return read_and_compare<std::int32_t>( address, condition );
    case CeueValueType::I64:
      return read_and_compare<std::int64_t>( address, condition );
    case CeueValueType::F32:
    {
      float actual{};
      return safe_read( address, actual ) && compare_ordered( actual, bits_as<float>( condition.value_bits ), condition.operation );
    }
    case CeueValueType::F64:
    {
      double actual{};
      return safe_read( address, actual ) && compare_ordered( actual, bits_as<double>( condition.value_bits ), condition.operation );
    }
    }
    return false;
  }

  template <typename T>
  bool masked_write( void *address, std::uint64_t value_bits, std::uint64_t mask_bits )
  {
    const auto value = static_cast<T>(value_bits);
    const auto mask = static_cast<T>(mask_bits);
    if (mask == 0)
    {
      return safe_write( address, value );
    }

    T current{};
    if ( !safe_read( address, current ) )
    {
      return false;
    }
    return safe_write( address, static_cast<T>( (current & ~mask) | (value & mask) ) );
  }

  bool apply_write( HookRecord &record, const Write &write, void *context, void *frame, void *result )
  {
    void *address{};
    if ( !descriptor_address( record, write, context, frame, result, address ) )
    {
      return false;
    }

    switch (write.type)
    {
    case CeueValueType::U8:
    case CeueValueType::I8:
      return masked_write<std::uint8_t>( address, write.value_bits, write.mask_bits );
    case CeueValueType::U16:
    case CeueValueType::I16:
      return masked_write<std::uint16_t>( address, write.value_bits, write.mask_bits );
    case CeueValueType::U32:
    case CeueValueType::I32:
    case CeueValueType::F32:
      return masked_write<std::uint32_t>( address, write.value_bits, write.mask_bits );
    case CeueValueType::U64:
    case CeueValueType::I64:
    case CeueValueType::F64:
    case CeueValueType::Pointer:
      return masked_write<std::uint64_t>( address, write.value_bits, write.mask_bits );
    }
    return false;
  }

  bool record_matches( HookRecord &record, void *context, void *frame, void *result )
  {
    bool matched = record.enabled.load( std::memory_order_acquire );

    if ( matched && record.object_pointer )
    {
      void *selected_object{};
      matched = safe_read( record.object_pointer, selected_object )
                && selected_object
                && selected_object == context;
    }

    for (std::size_t index = 0; matched && index < record.condition_count; ++index)
    {
      matched = condition_matches( record, record.conditions[index], context, frame, result );
    }
    return matched;
  }

  void apply_writes( HookRecord &record, CeueWritePhase phase, void *context, void *frame, void *result )
  {
    for (std::size_t index = 0; index < record.write_count; ++index)
    {
      const auto &write = record.writes[index];
      if ( write.phase == phase )
      {
        apply_write( record, write, context, frame, result );
      }
    }
  }

  void __fastcall dispatch( void *context, void *frame, void *result, HookRecord *record )
  {
    if (!record || record->magic != HookMagic)
    {
      return;
    }

    record->active_calls.fetch_add( 1, std::memory_order_acquire );
    const bool matched = record_matches( *record, context, frame, result );

    if (matched)
    {
      record->hit_count.fetch_add( 1, std::memory_order_relaxed );
      apply_writes( *record, CeueWritePhase::Before, context, frame, result );
    }

    if (!matched || (record->flags & CeueHookSkipOriginal) == 0)
    {
      record->original( context, frame, result );
    }

    if (matched)
    {
      apply_writes( *record, CeueWritePhase::After, context, frame, result );
    }

    record->active_calls.fetch_sub( 1, std::memory_order_release );
  }

  // creadit to UE4SS/UEPseudo: ProcessLocalScriptFunction is detoured once and callbacks are selected through FFrame::Node
  void __fastcall dispatch_script( void *context, void *frame, void *result )
  {
    g_active_script_dispatches.fetch_add( 1, std::memory_order_acquire );

    void *function{};
    if (frame)
    {
      const auto node_address = static_cast< const std::byte * >(frame) + g_frame_node_offset;
      safe_read( node_address, function );
    }

    std::vector<HookRecord *> records;
    if ( function && g_enabled_script_hook_count.load( std::memory_order_acquire ) != 0 )
    {
      std::scoped_lock lock(g_hook_mutex);
      const auto [first, last] = g_script_hooks.equal_range(function);
      for (auto iterator = first; iterator != last; ++iterator)
      {
        auto *record = iterator->second;
        record->active_calls.fetch_add( 1, std::memory_order_acquire );
        records.push_back(record);
      }
    }

    std::vector<HookRecord *> matched_records;
    bool skip_original{};

    for (auto *record : records)
    {
      if ( record_matches( *record, context, frame, result ) )
      {
        record->hit_count.fetch_add( 1, std::memory_order_relaxed );
        apply_writes( *record, CeueWritePhase::Before, context, frame, result );
        matched_records.push_back(record);
        skip_original = skip_original || (record->flags & CeueHookSkipOriginal) != 0;
      }
    }

    if ( !skip_original && g_script_dispatcher_original )
    {
      g_script_dispatcher_original( context, frame, result );
    }

    for (auto *record : matched_records)
    {
      apply_writes( *record, CeueWritePhase::After, context, frame, result );
    }

    for (auto *record : records)
    {
      record->active_calls.fetch_sub( 1, std::memory_order_release );
    }
    g_active_script_dispatches.fetch_sub( 1, std::memory_order_release );
  }

  DWORD find_primary_thread_id()
  {
    const DWORD process_id = GetCurrentProcessId();
    HANDLE snapshot = CreateToolhelp32Snapshot( TH32CS_SNAPTHREAD, 0 );
    if (snapshot == INVALID_HANDLE_VALUE)
    {
      return 0;
    }

    DWORD selected_id{};
    ULONGLONG earliest_creation = std::numeric_limits<ULONGLONG>::max();
    THREADENTRY32 entry{ sizeof(entry) };

    if ( Thread32First( snapshot, &entry ) )
    {
      do
      {
        if (entry.th32OwnerProcessID != process_id)
        {
          continue;
        }

        HANDLE thread = OpenThread( THREAD_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ThreadID );
        if (!thread)
        {
          continue;
        }

        FILETIME creation{}, exit{}, kernel{}, user{};
        if ( GetThreadTimes( thread, &creation, &exit, &kernel, &user ) )
        {
          ULARGE_INTEGER value{};
          value.LowPart = creation.dwLowDateTime;
          value.HighPart = creation.dwHighDateTime;
          if ( value.QuadPart < earliest_creation )
          {
            earliest_creation = value.QuadPart;
            selected_id = entry.th32ThreadID;
          }
        }
        CloseHandle(thread);
      }
      while ( Thread32Next( snapshot, &entry ) );
    }

    CloseHandle(snapshot);
    return selected_id;
  }

  void drain_invocation_queue()
  {
    std::vector< InvocationRecord* > ready;

    {
      std::scoped_lock lock( g_invocation_mutex );
      const std::size_t queued_count = g_invocation_queue.size();

      for (std::size_t index = 0; index < queued_count; ++index)
      {
        auto *record = g_invocation_queue.front();
        g_invocation_queue.pop_front();

        if (record->status.load( std::memory_order_acquire ) == CeueInvocationStatus::Cancelled)
        {
          g_pending_invocation_count.fetch_sub( 1, std::memory_order_release );
          continue;
        }

        if ( record->dispatches_until_run != 0 )
        {
          --record->dispatches_until_run;
          g_invocation_queue.push_back(record);
          continue;
        }

        record->status.store( CeueInvocationStatus::Running, std::memory_order_release );
        g_pending_invocation_count.fetch_sub( 1, std::memory_order_release );
        ready.push_back(record);
      }
    }

    for (auto *record : ready)
    {
      g_process_event_original( record->object, record->ufunction, record->parameters.empty() ? nullptr : record->parameters.data() );

      record->completed_runs.fetch_add( 1, std::memory_order_release );

      std::scoped_lock lock( g_invocation_mutex );
      if ( record->release_when_terminal.load( std::memory_order_acquire ) )
      {
        g_invocations.erase(record);
        delete record;
      }
      else if ( record->remaining_runs > 1 )
      {
        --record->remaining_runs;
        record->dispatches_until_run = record->interval_dispatches;
        record->status.store( CeueInvocationStatus::Queued, std::memory_order_release );
        g_invocation_queue.push_back(record);
        g_pending_invocation_count.fetch_add( 1, std::memory_order_release );
      }
      else
      {
        record->remaining_runs = 0;
        record->status.store( CeueInvocationStatus::Completed, std::memory_order_release );
      }
    }
  }

  void __fastcall dispatch_process_event( void *object, void *ufunction, void *parameters )
  {
    g_active_process_event_dispatches.fetch_add( 1, std::memory_order_acquire );
    g_process_event_original( object, ufunction, parameters );

    if ( g_pending_invocation_count.load( std::memory_order_acquire ) != 0 && GetCurrentThreadId() == g_scheduler_thread_id.load( std::memory_order_acquire ) )
    {
      drain_invocation_queue();
    }

    g_active_process_event_dispatches.fetch_sub( 1, std::memory_order_release );
  }

  bool initialize_minhook()
  {
    if (g_minhook_initialized)
    {
      return true;
    }

    const auto status = MH_Initialize();
    if ( status != MH_OK && status != MH_ERROR_ALREADY_INITIALIZED )
    {
      set_error( std::string("MinHook initialization failed: ") + MH_StatusToString(status) );
      return false;
    }
    g_minhook_initialized = true;
    return true;
  }

  bool enable_script_dispatcher()
  {
    if ( !g_script_dispatcher_created )
    {
      set_error("ProcessLocalScriptFunction dispatcher is not configured");
      return false;
    }
    if ( g_script_dispatcher_enabled )
    {
      return true;
    }

    const auto status = MH_EnableHook( g_script_dispatcher_target );
    if ( status != MH_OK && status != MH_ERROR_ENABLED )
    {
      set_error( std::string("Could not enable ProcessLocalScriptFunction detour: ") + MH_StatusToString(status) );
      return false;
    }
    g_script_dispatcher_enabled = true;
    return true;
  }

  bool disable_script_dispatcher()
  {
    if ( !g_script_dispatcher_enabled )
    {
      return true;
    }

    const auto status = MH_DisableHook( g_script_dispatcher_target );
    if ( status != MH_OK && status != MH_ERROR_DISABLED )
    {
      set_error( std::string("Could not disable ProcessLocalScriptFunction detour: ") + MH_StatusToString(status) );
      return false;
    }
    g_script_dispatcher_enabled = false;
    return true;
  }

  void *create_thunk(HookRecord *record)
  {
    // mov r9, record
    // mov rax, dispatch
    // jmp rax
    constexpr std::size_t ThunkSize = 22;
    auto *memory = static_cast<std::uint8_t *>( VirtualAlloc( nullptr, ThunkSize, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE ) );
    if (!memory)
    {
      return nullptr;
    }

    memory[0] = 0x49;
    memory[1] = 0xB9;
    *reinterpret_cast<std::uint64_t *>(memory + 2) = reinterpret_cast<std::uint64_t>(record);
    memory[10] = 0x48;
    memory[11] = 0xB8;
    *reinterpret_cast<std::uint64_t *>(memory + 12) = reinterpret_cast<std::uint64_t>(&dispatch);
    memory[20] = 0xFF;
    memory[21] = 0xE0;
    FlushInstructionCache( GetCurrentProcess(), memory, ThunkSize );
    return memory;
  }

  bool exchange_slot( void **slot, void *expected, void *replacement )
  {
    DWORD old_protection{};
    if ( !VirtualProtect( slot, sizeof(void *), PAGE_READWRITE, &old_protection ) )
    {
      return false;
    }

    void *observed = InterlockedCompareExchangePointer( slot, replacement, expected );
    DWORD ignored{};
    VirtualProtect( slot, sizeof(void *), old_protection, &ignored );
    return observed == expected;
  }

  bool set_enabled( HookRecord &record, bool enabled )
  {
    if ( record.backend == HookBackend::ScriptDispatcher )
    {
      std::scoped_lock lock(g_hook_mutex);

      if (enabled)
      {
        if ( record.enabled.load( std::memory_order_acquire ) )
        {
          return true;
        }
        if ( !enable_script_dispatcher() )
        {
          return false;
        }
        record.enabled.store( true, std::memory_order_release );
        g_enabled_script_hook_count.fetch_add( 1, std::memory_order_release );
        return true;
      }

      if ( !record.enabled.exchange( false, std::memory_order_acq_rel ) )
      {
        return true;
      }

      const auto remaining = g_enabled_script_hook_count.fetch_sub( 1, std::memory_order_acq_rel ) - 1;
      if ( remaining == 0 && !disable_script_dispatcher() )
      {
        g_enabled_script_hook_count.fetch_add( 1, std::memory_order_release );
        record.enabled.store( true, std::memory_order_release );
        return false;
      }
      return true;
    }

    if (enabled)
    {
      if ( record.enabled.load( std::memory_order_acquire ) )
      {
        return true;
      }
      if ( !exchange_slot( record.function_slot, reinterpret_cast<void *>( record.original ), record.thunk ) )
      {
        set_error("UFunction::Func changed before the hook could be installed");
        return false;
      }
      record.enabled.store( true, std::memory_order_release );
      return true;
    }

    if ( !record.enabled.exchange( false, std::memory_order_acq_rel ) )
    {
      return true;
    }
    if ( !exchange_slot( record.function_slot, record.thunk, reinterpret_cast<void *>( record.original ) ) )
    {
      record.enabled.store( true, std::memory_order_release );
      set_error("UFunction::Func no longer points to this hook thunk");
      return false;
    }
    return true;
  }

  bool remove_record(HookRecord *record)
  {
    // thread may already have fetched UFunction::Func immediately before it was restored
    std::scoped_lock lock( g_hook_mutex );
    g_retired_hooks.push_back( record );
    return true;
  }
}

std::uint32_t ceue_bridge_version()
{
  return 0x00010000u;
}

std::uint32_t ceue_bridge_abi()
{
  return 1;
}

std::uint32_t ceue_configure_process_event_dispatcher(void *process_event)
{
  g_last_error.clear();
  if ( !process_event )
  {
    set_error("Invalid UObject::ProcessEvent address");
    return 0;
  }

  std::scoped_lock lock(g_invocation_mutex);
  if ( g_process_event_dispatcher_created && g_process_event_target == process_event )
  {
    return 1;
  }
  if ( !g_invocation_queue.empty() )
  {
    set_error("ProcessEvent dispatcher cannot change while invocations are queued");
    return 0;
  }
  if ( g_active_process_event_dispatches.load( std::memory_order_acquire ) != 0 )
  {
    set_error("ProcessEvent dispatcher cannot change while it is active");
    return 0;
  }

  if ( g_process_event_dispatcher_created )
  {
    const auto disable_status = MH_DisableHook( g_process_event_target );
    if (disable_status != MH_OK && disable_status != MH_ERROR_DISABLED)
    {
      set_error( std::string("Could not disable ProcessEvent detour: ") + MH_StatusToString(disable_status) );
      return 0;
    }

    while ( g_active_process_event_dispatches.load( std::memory_order_acquire ) != 0 )
    {
      SwitchToThread();
    }

    const auto remove_status = MH_RemoveHook(g_process_event_target);
    if ( remove_status != MH_OK && remove_status != MH_ERROR_NOT_CREATED )
    {
      set_error( std::string("Could not replace ProcessEvent detour: ") + MH_StatusToString(remove_status) );
      return 0;
    }
    g_process_event_dispatcher_created = false;
    g_process_event_dispatcher_enabled = false;
    g_process_event_target = nullptr;
    g_process_event_original = nullptr;
  }

  if ( !initialize_minhook() )
  {
    return 0;
  }

  const auto create_status = MH_CreateHook( process_event, reinterpret_cast<void *>(&dispatch_process_event), reinterpret_cast<void **>(&g_process_event_original) );
  if ( create_status != MH_OK )
  {
    set_error( std::string("Could not create ProcessEvent detour: ") + MH_StatusToString(create_status) );
    return 0;
  }

  const auto enable_status = MH_EnableHook(process_event);
  if ( enable_status != MH_OK && enable_status != MH_ERROR_ENABLED )
  {
    MH_RemoveHook(process_event);
    g_process_event_original = nullptr;
    set_error( std::string("Could not enable ProcessEvent detour: ") + MH_StatusToString(enable_status) );
    return 0;
  }

  const DWORD scheduler_thread = find_primary_thread_id();
  if (scheduler_thread == 0)
  {
    MH_DisableHook(process_event);
    MH_RemoveHook(process_event);
    g_process_event_original = nullptr;
    set_error("Could not identify the target process primary/game thread");
    return 0;
  }

  g_scheduler_thread_id.store( scheduler_thread, std::memory_order_release );
  g_process_event_target = process_event;
  g_process_event_dispatcher_created = true;
  g_process_event_dispatcher_enabled = true;
  return 1;
}

void *ceue_queue_process_event(
                                void *object,
                                void *ufunction,
                                const void *parameters,
                                std::uint32_t parameter_size,
                                std::uint32_t runs,
                                std::uint32_t interval_dispatches
                              )
{
  g_last_error.clear();
  if ( !object || !ufunction || runs == 0 || (parameter_size != 0 && !parameters) )
  {
    set_error("Invalid queued ProcessEvent object, function, parameters, or run count");
    return nullptr;
  }

  auto record = std::make_unique<InvocationRecord>();
  record->object = object;
  record->ufunction = ufunction;
  record->remaining_runs = runs;
  record->interval_dispatches = interval_dispatches;

  if (parameter_size != 0)
  {
    record->parameters.resize(parameter_size);
    if ( !safe_copy( record->parameters.data(), parameters, parameter_size ) )
    {
      set_error("Queued ProcessEvent parameter buffer is unreadable");
      return nullptr;
    }
  }

  auto *handle = record.release();
  {
    std::scoped_lock lock(g_invocation_mutex);
    if ( !g_process_event_dispatcher_enabled || !g_process_event_original )
    {
      delete handle;
      set_error("ProcessEvent game-thread dispatcher is not configured");
      return nullptr;
    }
    g_invocations.insert(handle);
    g_invocation_queue.push_back(handle);
    g_pending_invocation_count.fetch_add( 1, std::memory_order_release );
  }
  return handle;
}

std::uint32_t ceue_get_invocation_status(void *handle)
{
  auto *record = checked_invocation(handle);
  if (!record)
  {
    set_error("Invalid queued invocation handle");
    return 0;
  }
  return static_cast<std::uint32_t>( record->status.load(std::memory_order_acquire) );
}

std::uint32_t ceue_get_invocation_completed_runs(void *handle)
{
  auto *record = checked_invocation(handle);
  if (!record)
  {
    set_error("Invalid queued invocation handle");
    return 0;
  }
  return record->completed_runs.load( std::memory_order_acquire );
}

std::uint32_t ceue_copy_invocation_parameters( void *handle, void *destination, std::uint32_t capacity )
{
  auto *record = checked_invocation(handle);
  if ( !record || (!destination && !record->parameters.empty()) || capacity < record->parameters.size() )
  {
    set_error("Invalid invocation handle or output parameter capacity");
    return 0;
  }

  const auto status = record->status.load( std::memory_order_acquire );
  if ( status != CeueInvocationStatus::Completed && status != CeueInvocationStatus::Cancelled )
  {
    set_error("Queued invocation has not reached a terminal state");
    return 0;
  }

  if ( !record->parameters.empty() )
  {
    if ( !safe_copy( destination, record->parameters.data(), record->parameters.size() ) )
    {
      set_error("Invocation output destination is unreadable");
      return 0;
    }
  }
  return static_cast<std::uint32_t>( record->parameters.size() );
}

std::uint32_t ceue_cancel_invocation(void *handle)
{
  auto *record = static_cast< InvocationRecord* >(handle);
  std::scoped_lock lock( g_invocation_mutex );
  if ( !record || !g_invocations.contains(record) )
  {
    set_error("Invalid queued invocation handle");
    return 0;
  }

  const auto status = record->status.load( std::memory_order_acquire );
  if (status == CeueInvocationStatus::Running)
  {
    set_error("Invocation is already running on the game thread");
    return 0;
  }
  if ( status == CeueInvocationStatus::Completed || status == CeueInvocationStatus::Cancelled )
  {
    return 1;
  }

  const auto iterator = std::find( g_invocation_queue.begin(), g_invocation_queue.end(), record );
  if ( iterator != g_invocation_queue.end() )
  {
    g_invocation_queue.erase(iterator);
    g_pending_invocation_count.fetch_sub( 1, std::memory_order_release );
  }
  record->status.store( CeueInvocationStatus::Cancelled, std::memory_order_release );
  return 1;
}

std::uint32_t ceue_abandon_invocation(void *handle)
{
  auto *record = static_cast< InvocationRecord* >(handle);
  std::scoped_lock lock( g_invocation_mutex );
  if ( !record || !g_invocations.contains(record) )
  {
    set_error("Invalid queued invocation handle");
    return 0;
  }

  if ( record->status.load( std::memory_order_acquire ) == CeueInvocationStatus::Running )
  {
    record->release_when_terminal.store( true, std::memory_order_release );
    return 1;
  }

  const auto iterator = std::find( g_invocation_queue.begin(), g_invocation_queue.end(), record );
  if ( iterator != g_invocation_queue.end() )
  {
    g_invocation_queue.erase(iterator);
    g_pending_invocation_count.fetch_sub( 1, std::memory_order_release );
  }
  g_invocations.erase(record);
  delete record;
  return 1;
}

std::uint32_t ceue_release_invocation(void *handle)
{
  auto *record = static_cast< InvocationRecord* >(handle);
  {
    std::scoped_lock lock( g_invocation_mutex );
    if ( !record || !g_invocations.contains(record) )
    {
      set_error("Invalid queued invocation handle");
      return 0;
    }

    const auto status = record->status.load( std::memory_order_acquire );
    if ( status != CeueInvocationStatus::Completed && status != CeueInvocationStatus::Cancelled && status != CeueInvocationStatus::Failed )
    {
      set_error("Queued invocation must complete or be cancelled before release");
      return 0;
    }
    g_invocations.erase(record);
  }
  delete record;
  return 1;
}

std::uint32_t ceue_get_pending_invocation_count()
{
  return g_pending_invocation_count.load( std::memory_order_acquire );
}

std::uint32_t ceue_get_scheduler_thread_id()
{
  return g_scheduler_thread_id.load( std::memory_order_acquire );
}

void *ceue_create_bp_hook( void *ufunction, std::uint32_t function_pointer_offset, void *expected_original, void **object_pointer, std::uint32_t flags )
{
  g_last_error.clear();
  if ( !ufunction || function_pointer_offset == 0 || function_pointer_offset > 0x1000 )
  {
    set_error("Invalid UFunction address or Func offset");
    return nullptr;
  }

  auto **slot = reinterpret_cast<void **>( static_cast<std::byte *>(ufunction) + function_pointer_offset );
  void *original{};
  if ( !safe_read( slot, original ) || !original )
  {
    set_error("UFunction::Func is unreadable");
    return nullptr;
  }
  if ( expected_original && original != expected_original )
  {
    set_error("UFunction::Func does not match the metadata value supplied by Lua");
    return nullptr;
  }

  auto record = std::make_unique<HookRecord>();
  record->ufunction = ufunction;
  record->backend = HookBackend::FunctionPointer;
  record->function_slot = slot;
  record->original = reinterpret_cast<UnrealFunction>(original);
  record->object_pointer = object_pointer;
  record->flags = flags;
  record->thunk = create_thunk( record.get() );
  if ( !record->thunk )
  {
    set_error("VirtualAlloc failed while creating the Blueprint hook thunk");
    return nullptr;
  }

  auto *handle = record.release();
  {
    std::scoped_lock lock(g_hook_mutex);
    g_hooks.insert(handle);
  }
  return handle;
}

std::uint32_t ceue_configure_script_dispatcher( void *dispatcher, std::uint32_t frame_node_offset )
{
  g_last_error.clear();
  if ( !dispatcher || frame_node_offset > 0x100 )
  {
    set_error("Invalid ProcessLocalScriptFunction address or FFrame::Node offset");
    return 0;
  }

  std::scoped_lock lock(g_hook_mutex);
  if ( g_script_dispatcher_created && g_script_dispatcher_target == dispatcher && g_frame_node_offset == frame_node_offset )
  {
    return 1;
  }

  if ( g_enabled_script_hook_count.load( std::memory_order_acquire ) != 0 )
  {
    set_error("Script dispatcher cannot change while Blueprint script hooks are enabled");
    return 0;
  }

  if ( g_script_dispatcher_created && g_script_dispatcher_target == dispatcher )
  {
    g_frame_node_offset = frame_node_offset;
    return 1;
  }

  if ( g_script_dispatcher_created )
  {
    if ( !disable_script_dispatcher() )
    {
      return 0;
    }
    const auto remove_status = MH_RemoveHook( g_script_dispatcher_target );
    if ( remove_status != MH_OK && remove_status != MH_ERROR_NOT_CREATED )
    {
      set_error( std::string("Could not replace ProcessLocalScriptFunction detour: ") + MH_StatusToString(remove_status) );
      return 0;
    }
    g_script_dispatcher_created = false;
    g_script_dispatcher_target = nullptr;
    g_script_dispatcher_original = nullptr;
  }

  if ( !initialize_minhook() )
  {
    return 0;
  }

  const auto create_status = MH_CreateHook( dispatcher, reinterpret_cast<void *>( &dispatch_script ), reinterpret_cast<void **>( &g_script_dispatcher_original ) );
  if (create_status != MH_OK)
  {
    set_error( std::string("Could not create ProcessLocalScriptFunction detour: ") + MH_StatusToString(create_status) );
    return 0;
  }

  g_script_dispatcher_target = dispatcher;
  g_frame_node_offset = frame_node_offset;
  g_script_dispatcher_created = true;
  return 1;
}

void *ceue_create_script_hook( void *ufunction, void **object_pointer, std::uint32_t flags )
{
  g_last_error.clear();
  if (!ufunction)
  {
    set_error("Invalid UFunction address");
    return nullptr;
  }

  auto record = std::make_unique<HookRecord>();
  record->ufunction = ufunction;
  record->backend = HookBackend::ScriptDispatcher;
  record->object_pointer = object_pointer;
  record->flags = flags;

  auto *handle = record.release();
  {
    std::scoped_lock lock(g_hook_mutex);
    if ( !g_script_dispatcher_created )
    {
      delete handle;
      set_error("ProcessLocalScriptFunction dispatcher is not configured");
      return nullptr;
    }
    g_hooks.insert(handle);
    g_script_hooks.emplace( ufunction, handle );
  }
  return handle;
}

std::uint32_t ceue_set_frame_locals_offset( void *handle, std::uint32_t frame_locals_offset )
{
  auto *record = checked_handle(handle);
  if (!record)
  {
    set_error("Invalid Blueprint hook handle");
    return 0;
  }
  if ( record->enabled.load( std::memory_order_acquire ) )
  {
    set_error("Hook configuration cannot change while enabled");
    return 0;
  }
  record->frame_locals_offset = frame_locals_offset;
  return 1;
}

std::uint32_t ceue_add_condition(
                                  void *handle,
                                  std::uint32_t source,
                                  std::uint32_t value_type,
                                  std::uint32_t operation,
                                  std::uint32_t offset,
                                  std::uint64_t value_bits,
                                  std::uint64_t mask_bits
                                )
{
  auto *record = checked_handle(handle);
  if ( !record || !valid_source(source) || !valid_type(value_type) || operation > static_cast<std::uint32_t>( CeueCompareOperation::AllBits ) )
  {
    set_error("Invalid Blueprint hook condition");
    return 0;
  }
  if ( record->enabled.load( std::memory_order_acquire ) || record->condition_count >= MaximumConditions )
  {
    set_error("Hook is enabled or its condition capacity was exceeded");
    return 0;
  }

  auto &condition = record->conditions[ record->condition_count++ ];
  condition.source = static_cast<CeueHookSource>( source );
  condition.type = static_cast<CeueValueType>( value_type );
  condition.operation = static_cast<CeueCompareOperation>( operation );
  condition.offset = offset;
  condition.value_bits = value_bits;
  condition.mask_bits = mask_bits;
  return 1;
}

std::uint32_t ceue_add_write(
                              void *handle,
                              std::uint32_t phase,
                              std::uint32_t source,
                              std::uint32_t value_type,
                              std::uint32_t offset,
                              std::uint64_t value_bits,
                              std::uint64_t mask_bits
                            )
{
  auto *record = checked_handle(handle);
  if ( !record || phase > static_cast<std::uint32_t>( CeueWritePhase::After ) || !valid_source(source) || !valid_type(value_type) )
  {
    set_error("Invalid Blueprint hook write");
    return 0;
  }
  if ( record->enabled.load( std::memory_order_acquire ) || record->write_count >= MaximumWrites )
  {
    set_error("Hook is enabled or its write capacity was exceeded");
    return 0;
  }

  auto &write = record->writes[ record->write_count++ ];
  write.phase = static_cast<CeueWritePhase>( phase );
  write.source = static_cast<CeueHookSource>( source );
  write.type = static_cast<CeueValueType>( value_type );
  write.offset = offset;
  write.value_bits = value_bits;
  write.mask_bits = mask_bits;
  return 1;
}

std::uint32_t ceue_enable_bp_hook( void *handle, std::uint32_t enabled )
{
  auto *record = checked_handle(handle);
  if (!record)
  {
    set_error("Invalid Blueprint hook handle");
    return 0;
  }
  return set_enabled( *record, enabled != 0 ) ? 1u : 0u;
}

std::uint32_t ceue_remove_bp_hook(void *handle)
{
  auto *record = checked_handle(handle);
  if (!record)
  {
    set_error("Invalid Blueprint hook handle");
    return 0;
  }
  if ( !set_enabled( *record, false ) )
  {
    return 0;
  }

  {
    std::scoped_lock lock(g_hook_mutex);
    g_hooks.erase(record);
    if ( record->backend == HookBackend::ScriptDispatcher )
    {
      const auto [first, last] = g_script_hooks.equal_range( record->ufunction );
      for (auto iterator = first; iterator != last;)
      {
        if (iterator->second == record)
        {
          iterator = g_script_hooks.erase(iterator);
        }
        else
        {
          ++iterator;
        }
      }
    }
  }
  return remove_record(record) ? 1u : 0u;
}

std::uint32_t ceue_remove_all_bp_hooks()
{
  std::vector<HookRecord *> hooks;
  {
    std::scoped_lock lock(g_hook_mutex);
    hooks.assign( g_hooks.begin(), g_hooks.end() );
  }

  std::uint32_t removed{};
  for (auto *record : hooks)
  {
    if ( ceue_remove_bp_hook(record) )
    {
      ++removed;
    }
  }
  return removed;
}

std::uint32_t ceue_get_hook_count()
{
  std::scoped_lock lock( g_hook_mutex );
  return static_cast<std::uint32_t>( g_hooks.size() );
}

std::uint64_t ceue_get_hook_hit_count(void *handle)
{
  auto *record = checked_handle(handle);
  if ( !record )
  {
    set_error("Invalid Blueprint hook handle");
    return 0;
  }
  return record->hit_count.load( std::memory_order_relaxed );
}

std::uint32_t ceue_get_last_error( char *buffer, std::uint32_t capacity )
{
  const auto required = static_cast<std::uint32_t>( g_last_error.size() + 1 );
  if (buffer && capacity != 0)
  {
    const auto count = std::min<std::size_t>( g_last_error.size(), capacity - 1 );
    std::memcpy( buffer, g_last_error.data(), count );
    buffer[count] = '\0';
  }
  return required;
}
