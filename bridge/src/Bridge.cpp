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

#include "ceUEDumperBridge.h"

#include <Windows.h>

#include <algorithm>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

namespace
{
  constexpr std::uint64_t HookMagic = 0x434555454250484Bull; // "CEUEBPHK"
  constexpr std::size_t MaximumConditions = 32;
  constexpr std::size_t MaximumWrites = 32;
  constexpr std::uint32_t LocalsOffsetUnavailable = 0xFFFFFFFFu;

  using UnrealFunction = void(__fastcall *)(void *context, void *frame, void *result);

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
    void **function_slot{};
    UnrealFunction original{};
    void *thunk{};
    // Address of a caller-owned UObject* cell. Its current value is read for
    // every invocation, so replacing the cell's value retargets the hook.
    void **object_pointer{};
    std::uint32_t flags{};
    std::uint32_t frame_locals_offset{ LocalsOffsetUnavailable };
    std::atomic<std::uint32_t> active_calls{};
    std::atomic<bool> enabled{};
    std::size_t condition_count{};
    std::size_t write_count{};
    Condition conditions[ MaximumConditions ]{};
    Write writes[ MaximumWrites ]{};
  };

  std::mutex g_hook_mutex;
  std::unordered_set<HookRecord *> g_hooks;
  std::vector<HookRecord *> g_retired_hooks;
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

  void __fastcall dispatch( void *context, void *frame, void *result, HookRecord *record )
  {
    if (!record || record->magic != HookMagic)
    {
      return;
    }

    record->active_calls.fetch_add( 1, std::memory_order_acquire );

    const bool enabled = record->enabled.load( std::memory_order_acquire );
    bool matched = enabled;

    if (matched && record->object_pointer)
    {
      void *selected_object{};
      matched = safe_read( record->object_pointer, selected_object )
                && selected_object
                && selected_object == context;
    }

    for (std::size_t index = 0; matched && index < record->condition_count; ++index)
    {
      matched = condition_matches( *record, record->conditions[index], context, frame, result );
    }

    if (matched)
    {
      for ( std::size_t index = 0; index < record->write_count; ++index )
      {
        const auto &write = record->writes[index];
        if (write.phase == CeueWritePhase::Before)
        {
          apply_write( *record, write, context, frame, result );
        }
      }
    }

    if (!matched || (record->flags & CeueHookSkipOriginal) == 0)
    {
      record->original( context, frame, result );
    }

    if (matched)
    {
      for (std::size_t index = 0; index < record->write_count; ++index)
      {
        const auto &write = record->writes[index];
        if (write.phase == CeueWritePhase::After)
        {
          apply_write( *record, write, context, frame, result );
        }
      }
    }

    record->active_calls.fetch_sub( 1, std::memory_order_release );
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

void *ceue_create_bp_hook( void *ufunction, std::uint32_t function_pointer_offset, void *expected_original, void **object_pointer, std::uint32_t flags )
{
  g_last_error.clear();
  if (!ufunction || function_pointer_offset == 0 || function_pointer_offset > 0x1000)
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
