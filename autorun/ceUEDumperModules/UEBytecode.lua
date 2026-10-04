--[[
  ceUEDumperModules — a Cheat Engine Unreal Engine Dumper — Copyright (C) 2026 palepine

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.
]]

--- Unreal Kismet bytecode decoder

local Module =
{
  Opcodes = {},
  Decoder = {},
  Structures = {},
  Patches = {},
  Decompiler = {},
}

-- EX_Return, EX_Nothing, EX_EndOfScript for NOPing and returning function prologue
Module.Patches.VOID_RETURN = { 0x04, 0x0B, 0x53 }

local PTR_SIZE = 0x8
local MAX_EXPRESSION_DEPTH = 0x100
local MIN_INSTRUCTION_LIMIT = 0x10000
local MAX_RAW_TAIL_BYTES = 0x10000

local function opcode(value, name, operation)
  Module.Opcodes[value] = { value = value, name = name, operation = operation or name }
end

-- stable runtime EExprToken s
-- deliberate gaps remain unsupported
opcode(0x00, 'EX_LocalVariable')
opcode(0x01, 'EX_InstanceVariable')
opcode(0x02, 'EX_DefaultVariable')
opcode(0x04, 'EX_Return')
opcode(0x06, 'EX_Jump')
opcode(0x07, 'EX_JumpIfNot')
opcode(0x09, 'EX_Assert')
opcode(0x0B, 'EX_Nothing')
opcode(0x0C, 'EX_NothingInt32')
opcode(0x0F, 'EX_Let')
opcode(0x11, 'EX_BitFieldConst')
opcode(0x12, 'EX_ClassContext')
opcode(0x13, 'EX_MetaCast')
opcode(0x14, 'EX_LetBool')
opcode(0x15, 'EX_EndParmValue')
opcode(0x16, 'EX_EndFunctionParms')
opcode(0x17, 'EX_Self')
opcode(0x18, 'EX_Skip')
opcode(0x19, 'EX_Context')
opcode(0x1A, 'EX_Context_FailSilent')
opcode(0x1B, 'EX_VirtualFunction')
opcode(0x1C, 'EX_FinalFunction')
opcode(0x1D, 'EX_IntConst')
opcode(0x1E, 'EX_FloatConst')
opcode(0x1F, 'EX_StringConst')
opcode(0x20, 'EX_ObjectConst')
opcode(0x21, 'EX_NameConst')
opcode(0x22, 'EX_RotationConst')
opcode(0x23, 'EX_VectorConst')
opcode(0x24, 'EX_ByteConst')
opcode(0x25, 'EX_IntZero')
opcode(0x26, 'EX_IntOne')
opcode(0x27, 'EX_True')
opcode(0x28, 'EX_False')
opcode(0x29, 'EX_TextConst')
opcode(0x2A, 'EX_NoObject')
opcode(0x2B, 'EX_TransformConst')
opcode(0x2C, 'EX_IntConstByte')
opcode(0x2D, 'EX_NoInterface')
opcode(0x2E, 'EX_DynamicCast')
opcode(0x2F, 'EX_StructConst')
opcode(0x30, 'EX_EndStructConst')
opcode(0x31, 'EX_SetArray')
opcode(0x32, 'EX_EndArray')
opcode(0x33, 'EX_PropertyConst')
opcode(0x34, 'EX_UnicodeStringConst')
opcode(0x35, 'EX_Int64Const')
opcode(0x36, 'EX_UInt64Const')
opcode(0x37, 'EX_DoubleConst')
opcode(0x38, 'EX_Cast')
opcode(0x39, 'EX_SetSet')
opcode(0x3A, 'EX_EndSet')
opcode(0x3B, 'EX_SetMap')
opcode(0x3C, 'EX_EndMap')
opcode(0x3D, 'EX_SetConst')
opcode(0x3E, 'EX_EndSetConst')
opcode(0x3F, 'EX_MapConst')
opcode(0x40, 'EX_EndMapConst')
opcode(0x41, 'EX_Vector3fConst')
opcode(0x42, 'EX_StructMemberContext')
opcode(0x43, 'EX_LetMulticastDelegate')
opcode(0x44, 'EX_LetDelegate')
opcode(0x45, 'EX_LocalVirtualFunction')
opcode(0x46, 'EX_LocalFinalFunction')
opcode(0x48, 'EX_LocalOutVariable')
opcode(0x4A, 'EX_DeprecatedOp4A')
opcode(0x4B, 'EX_InstanceDelegate')
opcode(0x4C, 'EX_PushExecutionFlow')
opcode(0x4D, 'EX_PopExecutionFlow')
opcode(0x4E, 'EX_ComputedJump')
opcode(0x4F, 'EX_PopExecutionFlowIfNot')
opcode(0x50, 'EX_Breakpoint')
opcode(0x51, 'EX_InterfaceContext')
opcode(0x52, 'EX_ObjToInterfaceCast')
opcode(0x53, 'EX_EndOfScript')
opcode(0x54, 'EX_CrossInterfaceCast')
opcode(0x55, 'EX_InterfaceToObjCast')
opcode(0x5A, 'EX_WireTracepoint')
opcode(0x5B, 'EX_SkipOffsetConst')
opcode(0x5C, 'EX_AddMulticastDelegate')
opcode(0x5D, 'EX_ClearMulticastDelegate')
opcode(0x5E, 'EX_Tracepoint')
opcode(0x5F, 'EX_LetObj')
opcode(0x60, 'EX_LetWeakObjPtr')
opcode(0x61, 'EX_BindDelegate')
opcode(0x62, 'EX_RemoveMulticastDelegate')
opcode(0x63, 'EX_CallMulticastDelegate')
opcode(0x64, 'EX_LetValueOnPersistentFrame')
opcode(0x65, 'EX_ArrayConst')
opcode(0x66, 'EX_EndArrayConst')
opcode(0x67, 'EX_SoftObjectConst')
opcode(0x68, 'EX_CallMath')
opcode(0x69, 'EX_SwitchValue')
opcode(0x6A, 'EX_InstrumentationEvent')
opcode(0x6B, 'EX_ArrayGetByRef')
opcode(0x6C, 'EX_ClassSparseDataVariable')
opcode(0x6D, 'EX_FieldPathConst')
opcode(0x70, 'EX_AutoRtfmTransact')
opcode(0x71, 'EX_AutoRtfmStopTransact')
opcode(0x72, 'EX_AutoRtfmAbortIfNot')
opcode(0x73, 'EX_AutoRtfmAbort')

local NO_OPERANDS =
{
  EX_Nothing = true,
  EX_EndOfScript = true,
  EX_EndFunctionParms = true,
  EX_EndStructConst = true,
  EX_EndArray = true,
  EX_EndArrayConst = true,
  EX_EndSet = true,
  EX_EndMap = true,
  EX_EndSetConst = true,
  EX_EndMapConst = true,
  EX_IntZero = true,
  EX_IntOne = true,
  EX_True = true,
  EX_False = true,
  EX_NoObject = true,
  EX_NoInterface = true,
  EX_Self = true,
  EX_EndParmValue = true,
  EX_PopExecutionFlow = true,
  EX_DeprecatedOp4A = true,
  EX_WireTracepoint = true,
  EX_Tracepoint = true,
  EX_Breakpoint = true,
}

local function indent(depth)
  return string.rep( '  ', math.max( 0, depth or 0 ) )
end

--- Construct one bounded decoder context
-- @param scriptAddress number @ Script.Data pointer
-- @param scriptSize number @ Script.Num byte count
-- @param options table|nil @ optional pointer-name resolver
-- @return table @ decoder context
function Module.Decoder.newContext(scriptAddress, scriptSize, options)
  local configuredLimit = options and options.maxInstructionCount
  local instructionLimit = type(configuredLimit) == 'number' and configuredLimit or math.max( MIN_INSTRUCTION_LIMIT, scriptSize )

  return
  {
    address = scriptAddress,
    size = scriptSize,
    cursor = 0,
    instructionCount = 0,
    instructionLimit = instructionLimit,
    elements = {},
    errors = {},
    stopped = false,
    describePointer = options and options.describePointer,
    constantWidths = options and options.constantWidths or {},
  }
end

--- Add one patchable field descriptor to decoded output
-- @param context table @ decoder context
-- @param offset number @ byte offset relative to Script.Data
-- @param kind string @ renderer value type
-- @param name string @ structure element caption
-- @param size number|nil @ optional explicit element size
function Module.Decoder.addElement(context, offset, kind, name, size)
  context.elements[ #context.elements + 1 ] =
  {
    offset = offset,
    kind = kind,
    name = name,
    size = size,
  }
end

--- Stop symbolic parsing without reading beyond Script.Num
-- @param context table @ decoder context
-- @param message string @ diagnostic
function Module.Decoder.fail(context, message)
  if context.stopped then return end
  context.stopped = true
  context.errors[ #context.errors + 1 ] = ('0x%X: %s'):format( context.cursor, message )
end

--- Reserve bounded operand and expose it as struct field
-- @param context table @ decoder context
-- @param byteCount number @ operand width
-- @param kind string @ renderer value type
-- @param label string @ operand caption
-- @param depth number @ expression nesting level
-- @return number|nil @ operand offset
function Module.Decoder.consume(context, byteCount, kind, label, depth)
  if context.stopped then return nil end

  if context.cursor + byteCount > context.size then
    Module.Decoder.fail( context, ('truncated %s operand (%d byte(s) required)'):format( label, byteCount ) )
    return nil
  end

  local offset = context.cursor
  Module.Decoder.addElement( context, offset, kind, indent(depth) .. label, byteCount )
  context.cursor = context.cursor + byteCount
  return offset
end

--- Describe linked UObject/FField pointer when runtime metadata can resolve it
-- @param context table @ decoder context
-- @param operandOffset number @ pointer offset inside Script.Data
-- @return string|nil @ display suffix
function Module.Decoder.pointerSuffix(context, operandOffset)
  if type(context.describePointer) ~= 'function' then return nil end

  local address = readPointer( context.address + operandOffset )
  if not address or address == 0 then return nil end

  local resolved = context.describePointer(address)
  return resolved and (' -> ' .. resolved) or nil
end

--- Consume one runtime-linked pointer operand
-- @param context table @ decoder context
-- @param label string @ pointer role
-- @param depth number @ expression nesting level
function Module.Decoder.consumePointer(context, label, depth)
  local offset = Module.Decoder.consume( context, PTR_SIZE, 'pointer', label, depth )
  if not offset then return end

  local suffix = Module.Decoder.pointerSuffix(context, offset)
  if suffix then context.elements[ #context.elements ].name = context.elements[ #context.elements ].name .. suffix end
end

--- Consume runtime FScriptName (FName plus serialized number/display field)
-- @param context table @ decoder context
-- @param label string @ name role
-- @param depth number @ expression nesting level
function Module.Decoder.consumeScriptName(context, label, depth)
  -- current supported targets use eight-byte FName followed by one dword
  Module.Decoder.consume( context, 8, 'fname', label, depth )
  Module.Decoder.consume( context, 4, 'dword', label .. ' [extra]', depth )
end

--- Decode expressions until a requested delimiter is consumed
-- @param context table @ decoder context
-- @param delimiter string @ canonical EExprToken operation
-- @param depth number @ expression nesting level
function Module.Decoder.decodeUntil(context, delimiter, depth)
  while not context.stopped and context.cursor < context.size do
    local operation = Module.Decoder.decodeExpression( context, depth )
    if operation == delimiter then return true end
  end

  if not context.stopped then Module.Decoder.fail( context, 'missing ' .. delimiter ) end
  return false
end

--- Decode one null-terminated byte or UTF-16 string operand
-- @param context table @ decoder context
-- @param wide boolean @ true for UTF-16
-- @param depth number @ expression nesting level
function Module.Decoder.decodeString(context, wide, depth)
  local start = context.cursor
  local unitSize = wide and 2 or 1
  local terminated = false

  while context.cursor + unitSize <= context.size do
    local value = wide and readSmallInteger( context.address + context.cursor ) or readByte( context.address + context.cursor )
    context.cursor = context.cursor + unitSize
    if value == 0 then terminated = true; break end
  end

  if not terminated then
    Module.Decoder.fail( context, 'unterminated string constant' )
  end

  Module.Decoder.addElement( context, start, wide and 'wstring' or 'string', indent(depth) .. 'Value', context.cursor - start )
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// OPERAND HANDLERS

local DECODER_OPERAND_HANDLERS = {}

--- Assign one operand decoder to one or more ops
-- @param operations string[] @ canonical EExprToken operations
-- @param handler function @ decoder callback
local function registerDecoderHandler(operations, handler)
  for _, operation in ipairs(operations) do DECODER_OPERAND_HANDLERS[operation] = handler end
end

registerDecoderHandler(
  { 'EX_LocalVariable', 'EX_InstanceVariable', 'EX_DefaultVariable', 'EX_LocalOutVariable', 'EX_ClassSparseDataVariable', 'EX_PropertyConst' },
  function(context, depth)
    Module.Decoder.consumePointer( context, 'Property*', depth )
  end
)

registerDecoderHandler(
  { 'EX_Cast' },
  function(context, depth)
    Module.Decoder.consume( context, 1, 'byte', 'Conversion type', depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_ObjToInterfaceCast', 'EX_CrossInterfaceCast', 'EX_InterfaceToObjCast' },
  function(context, depth)
    Module.Decoder.consumePointer( context, 'Class*', depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_Let' },
  function(context, depth)
    Module.Decoder.consumePointer( context, 'Property*', depth )
    Module.Decoder.decodeExpression( context, depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_LetObj', 'EX_LetWeakObjPtr', 'EX_LetBool', 'EX_LetDelegate', 'EX_LetMulticastDelegate' },
  function(context, depth)
    Module.Decoder.decodeExpression( context, depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_LetValueOnPersistentFrame' },
  function(context, depth)
    Module.Decoder.consumePointer( context, 'Property*', depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_StructMemberContext' },
  function(context, depth)
    Module.Decoder.consumePointer( context, 'Member property*', depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_Jump', 'EX_PushExecutionFlow', 'EX_SkipOffsetConst' },
  function(context, depth)
    Module.Decoder.consume( context, 4, 'dword', 'Code offset', depth )
  end
)

registerDecoderHandler(
  { 'EX_ComputedJump', 'EX_InterfaceContext', 'EX_PopExecutionFlowIfNot', 'EX_Return', 'EX_ClearMulticastDelegate', 'EX_SoftObjectConst', 'EX_FieldPathConst', 'EX_AutoRtfmAbortIfNot' },
  function(context, depth)
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_NothingInt32' },
  function(context, depth)
    Module.Decoder.consume( context, 4, 'dword', 'Value', depth )
  end
)

registerDecoderHandler(
  { 'EX_FinalFunction', 'EX_LocalFinalFunction', 'EX_CallMath', 'EX_CallMulticastDelegate' },
  function(context, depth)
    Module.Decoder.consumePointer( context, 'Function*', depth )
    Module.Decoder.decodeUntil( context, 'EX_EndFunctionParms', depth )
  end
)

registerDecoderHandler(
  { 'EX_VirtualFunction', 'EX_LocalVirtualFunction' },
  function(context, depth)
    Module.Decoder.consumeScriptName( context, 'Function name', depth )
    Module.Decoder.decodeUntil( context, 'EX_EndFunctionParms', depth )
  end
)

registerDecoderHandler(
  { 'EX_BitFieldConst' },
  function(context, depth)
    Module.Decoder.consumePointer( context, 'Property*', depth )
    Module.Decoder.consume( context, 1, 'byte', 'Field mask', depth )
  end
)

registerDecoderHandler(
  { 'EX_ClassContext', 'EX_Context', 'EX_Context_FailSilent' },
  function(context, depth)
    Module.Decoder.decodeExpression( context, depth )
    Module.Decoder.consume( context, 4, 'dword', 'Skip offset', depth )
    Module.Decoder.consumePointer( context, 'R-value property*', depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_AddMulticastDelegate', 'EX_RemoveMulticastDelegate', 'EX_ArrayGetByRef' },
  function(context, depth)
    Module.Decoder.decodeExpression( context, depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_IntConst' },
  function(context, depth)
    Module.Decoder.consume( context, 4, 'dword', 'Value', depth )
  end
)

registerDecoderHandler(
  { 'EX_Int64Const', 'EX_UInt64Const' },
  function(context, depth)
    Module.Decoder.consume( context, 8, 'qword', 'Value', depth )
  end
)

registerDecoderHandler(
  { 'EX_FloatConst' },
  function(context, depth)
    Module.Decoder.consume( context, 4, 'float', 'Value', depth )
  end
)

registerDecoderHandler(
  { 'EX_DoubleConst' },
  function(context, depth)
    Module.Decoder.consume( context, 8, 'double', 'Value', depth )
  end
)

registerDecoderHandler(
  { 'EX_ByteConst', 'EX_IntConstByte' },
  function(context, depth)
    Module.Decoder.consume( context, 1, 'byte', 'Value', depth )
  end
)

registerDecoderHandler(
  { 'EX_StringConst' },
  function(context, depth)
    Module.Decoder.decodeString( context, false, depth )
  end
)

registerDecoderHandler(
  { 'EX_UnicodeStringConst' },
  function(context, depth)
    Module.Decoder.decodeString( context, true, depth )
  end
)

registerDecoderHandler(
  { 'EX_TextConst' },
  function(context, depth)
    local literalTypeOffset = Module.Decoder.consume( context, 1, 'byte', 'Text literal type', depth )
    local literalType = literalTypeOffset and readByte( context.address + literalTypeOffset )

    if literalType == 1 then
      Module.Decoder.decodeExpression( context, depth )
      Module.Decoder.decodeExpression( context, depth )
      Module.Decoder.decodeExpression( context, depth )
    elseif literalType == 2 or literalType == 3 then
      Module.Decoder.decodeExpression( context, depth )
    elseif literalType == 4 then
      Module.Decoder.consumePointer( context, 'String table*', depth )
      Module.Decoder.decodeExpression( context, depth )
      Module.Decoder.decodeExpression( context, depth )
    elseif literalType ~= 0 then
      Module.Decoder.fail( context, 'unknown text literal type ' .. tostring(literalType) )
    end
  end
)

registerDecoderHandler(
  { 'EX_ObjectConst' },
  function(context, depth)
    Module.Decoder.consumePointer( context, 'Object*', depth )
  end
)

registerDecoderHandler(
  { 'EX_NameConst', 'EX_InstanceDelegate' },
  function(context, depth)
    Module.Decoder.consumeScriptName( context, 'Name', depth )
  end
)

registerDecoderHandler(
  { 'EX_RotationConst' },
  function(context, depth)
    local componentSize = context.constantWidths.rotator or 4
    local componentKind = componentSize == 8 and 'double' or 'dword'

    Module.Decoder.consume( context, componentSize, componentKind, 'Pitch', depth )
    Module.Decoder.consume( context, componentSize, componentKind, 'Yaw', depth )
    Module.Decoder.consume( context, componentSize, componentKind, 'Roll', depth )
  end
)

registerDecoderHandler(
  { 'EX_VectorConst', 'EX_Vector3fConst' },
  function(context, depth, operation)
    local componentSize = operation == 'EX_Vector3fConst' and 4 or context.constantWidths.vector or 4
    local componentKind = componentSize == 8 and 'double' or 'float'

    Module.Decoder.consume( context, componentSize, componentKind, 'X', depth )
    Module.Decoder.consume( context, componentSize, componentKind, 'Y', depth )
    Module.Decoder.consume( context, componentSize, componentKind, 'Z', depth )
  end
)

registerDecoderHandler(
  { 'EX_TransformConst' },
  function(context, depth)
    local componentSize = context.constantWidths.transform or 4
    local componentKind = componentSize == 8 and 'double' or 'float'

    for _, label in ipairs({ 'Rotation.X', 'Rotation.Y', 'Rotation.Z', 'Rotation.W', 'Translation.X', 'Translation.Y', 'Translation.Z', 'Scale.X', 'Scale.Y', 'Scale.Z' }) do
      Module.Decoder.consume( context, componentSize, componentKind, label, depth )
    end
  end
)

registerDecoderHandler(
  { 'EX_StructConst' },
  function(context, depth)
    Module.Decoder.consumePointer( context, 'ScriptStruct*', depth )
    Module.Decoder.consume( context, 4, 'dword', 'Serialized size', depth )
    Module.Decoder.decodeUntil( context, 'EX_EndStructConst', depth )
  end
)

registerDecoderHandler(
  { 'EX_SetArray' },
  function(context, depth)
    Module.Decoder.decodeExpression( context, depth )
    Module.Decoder.decodeUntil( context, 'EX_EndArray', depth )
  end
)

registerDecoderHandler(
  { 'EX_SetSet', 'EX_SetMap' },
  function(context, depth, operation)
    Module.Decoder.decodeExpression( context, depth )
    Module.Decoder.consume( context, 4, 'dword', 'Element count', depth )
    Module.Decoder.decodeUntil( context, operation == 'EX_SetSet' and 'EX_EndSet' or 'EX_EndMap', depth )
  end
)

registerDecoderHandler(
  { 'EX_ArrayConst', 'EX_SetConst' },
  function(context, depth, operation)
    Module.Decoder.consumePointer( context, 'Inner property*', depth )
    Module.Decoder.consume( context, 4, 'dword', 'Element count', depth )
    Module.Decoder.decodeUntil( context, operation == 'EX_ArrayConst' and 'EX_EndArrayConst' or 'EX_EndSetConst', depth )
  end
)

registerDecoderHandler(
  { 'EX_MapConst' },
  function(context, depth)
    Module.Decoder.consumePointer( context, 'Key property*', depth )
    Module.Decoder.consumePointer( context, 'Value property*', depth )
    Module.Decoder.consume( context, 4, 'dword', 'Pair count', depth )
    Module.Decoder.decodeUntil( context, 'EX_EndMapConst', depth )
  end
)

registerDecoderHandler(
  { 'EX_MetaCast', 'EX_DynamicCast' }, function(context, depth)
    Module.Decoder.consumePointer( context, 'Class*', depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_JumpIfNot' },
  function(context, depth)
    Module.Decoder.consume( context, 4, 'dword', 'Destination', depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_Assert' },
  function(context, depth)
    Module.Decoder.consume( context, 2, 'word', 'Line', depth )
    Module.Decoder.consume( context, 1, 'byte', 'Debug mode', depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_Skip' },
  function(context, depth)
    Module.Decoder.consume( context, 4, 'dword', 'Skip count', depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_BindDelegate' },
  function(context, depth)
    Module.Decoder.consumeScriptName( context, 'Function name', depth )
    Module.Decoder.decodeExpression( context, depth )
    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_SwitchValue' },
  function(context, depth, operation)
    local countOffset = Module.Decoder.consume( context, 2, 'word', 'Case count', depth )
    Module.Decoder.consume( context, 4, 'dword', 'End offset', depth )
    Module.Decoder.decodeExpression( context, depth )
    local caseCount = countOffset and readSmallInteger( context.address + countOffset ) or 0

    if caseCount > 0x1000 then
      Module.Decoder.fail( context, 'implausible switch case count' )
      return operation
    end

    for caseIndex = 0, caseCount - 1 do
      Module.Decoder.decodeExpression( context, depth )
      Module.Decoder.consume( context, 4, 'dword', ('Case %d next offset'):format(caseIndex), depth )
      Module.Decoder.decodeExpression( context, depth )
    end

    Module.Decoder.decodeExpression( context, depth )
  end
)

registerDecoderHandler(
  { 'EX_AutoRtfmTransact' },
  function(context, depth)
    Module.Decoder.consume( context, 4, 'dword', 'Transaction id', depth )
    Module.Decoder.consume( context, 4, 'dword', 'End offset', depth )
    Module.Decoder.decodeUntil( context, 'EX_AutoRtfmStopTransact', depth )
  end
)

registerDecoderHandler(
  { 'EX_AutoRtfmStopTransact' },
  function(context, depth)
    Module.Decoder.consume( context, 4, 'dword', 'Transaction id', depth )
    Module.Decoder.consume( context, 1, 'byte', 'Status', depth )
  end
)

registerDecoderHandler(
  { 'EX_InstrumentationEvent' },
  function(context)
    Module.Decoder.fail( context, 'instrumentation payload is version-dependent' )
  end
)

--- Decode one recursive Kismet expression
-- @param context table @ decoder context
-- @param depth number|nil @ nesting level
-- @return string|nil @ canonical operation name
function Module.Decoder.decodeExpression(context, depth)
  depth = depth or 0

  if context.stopped or context.cursor >= context.size then return nil end
  if depth > MAX_EXPRESSION_DEPTH then Module.Decoder.fail( context, 'expression nesting limit exceeded' ); return nil end

  context.instructionCount = context.instructionCount + 1
  if context.instructionCount > context.instructionLimit then Module.Decoder.fail( context, 'instruction limit exceeded' ); return nil end

  local opcodeOffset = context.cursor
  local opcodeValue = readByte( context.address + opcodeOffset )
  if opcodeValue == nil then Module.Decoder.fail( context, 'opcode is unreadable' ); return nil end

  local definition = Module.Opcodes[opcodeValue]
  local opcodeName = definition and definition.name or ('EX_Unknown_%02X'):format(opcodeValue)
  local operation = definition and definition.operation
  Module.Decoder.addElement( context, opcodeOffset, 'byte', ('%s%04X  %s'):format( indent(depth), opcodeOffset, opcodeName ), 1 )
  context.cursor = context.cursor + 1

  if not operation then Module.Decoder.fail( context, ('unknown opcode 0x%02X'):format(opcodeValue) ); return nil end
  if NO_OPERANDS[operation] then return operation end

  local operandHandler = DECODER_OPERAND_HANDLERS[operation]

  if operandHandler then
    operandHandler( context, depth + 1, operation )
  else
    Module.Decoder.fail( context, 'unsupported operand layout for ' .. operation )
  end

  return operation
end

--- Decode complete runtime UStruct::Script byte array
-- @param scriptAddress number @ validated Script.Data pointer
-- @param scriptSize number @ validated Script.Num
-- @param options table|nil @ decoder callbacks
-- @return table @ decoded elements, errors and termination state
function Module.decode(scriptAddress, scriptSize, options)
  assert( type(scriptAddress) == 'number' and scriptAddress ~= 0, 'Script.Data must be a valid address' )
  assert( type(scriptSize) == 'number' and scriptSize > 0, 'Script.Num must be positive' )

  local context = Module.Decoder.newContext( scriptAddress, scriptSize, options )

  while not context.stopped and context.cursor < context.size do
    local operation = Module.Decoder.decodeExpression( context, 0 )
    if operation == 'EX_EndOfScript' then context.terminated = true; break end
  end

  if not context.terminated and not context.stopped then
    Module.Decoder.fail( context, 'Script ended without EX_EndOfScript' )
  end

  local rawTailEnd = math.min( context.size, context.cursor + MAX_RAW_TAIL_BYTES )

  if context.stopped then
    for offset = context.cursor, rawTailEnd - 1 do
      Module.Decoder.addElement( context, offset, 'byte', ('%04X  Raw byte'):format(offset), 1 )
    end
  end

  context.truncatedRawTail = rawTailEnd < context.size
  return context
end

-- ///---///--///---///--///---///--/// KISMET PSEUDOCODE DECOMPILER

--- Convert reflected name into stable C++-like identifier
-- @param name any @ reflected or fallback name
-- @return string @ sanitized identifier
function Module.Decompiler.identifier(name)
  local value = tostring( name or 'Unknown' )
  value = value:gsub('[^%w_]', '_'):gsub('_+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if value == '' then value = 'Unknown' end
  if value:match('^%d') then value = '_' .. value end
  return value
end

--- Construct bounded pseudocode parser context
-- @param scriptAddress number @ Script.Data pointer
-- @param scriptSize number @ Script.Num
-- @param options table|nil @ metadata callbacks and rendering options
-- @return table @ parser context
function Module.Decompiler.newContext(scriptAddress, scriptSize, options)
  local configuredLimit = options and options.maxInstructionCount
  local instructionLimit = type(configuredLimit) == 'number' and configuredLimit or math.max( MIN_INSTRUCTION_LIMIT, scriptSize )

  return
  {
    address = scriptAddress,
    size = scriptSize,
    cursor = 0,
    stopped = false,
    errors = {},
    trace = {},
    instructionCount = 0,
    instructionLimit = instructionLimit,
    options = options or {},
    symbolByAddress = {},
    symbolOwnerByName = {},
    nextSymbolSuffix = {},
  }
end

--- Stop parsing at the first unknown/truncated operand boundary
-- @param context table @ parser context
-- @param message string @ diagnostic
function Module.Decompiler.fail(context, message)
  if context.stopped then return end
  context.stopped = true
  context.errors[ #context.errors + 1 ] = ('+0x%X: %s'):format( context.cursor, message )
end

--- Reserve bytes while enforcing Script.Num
-- @param context table @ parser context
-- @param byteCount number @ requested bytes
-- @return number|nil @ starting byte offset
function Module.Decompiler.consume(context, byteCount)
  if context.stopped then return nil end
  if context.cursor + byteCount > context.size then
    Module.Decompiler.fail( context, ('truncated operand requiring %d byte(s)'):format(byteCount) )
    return nil
  end

  local offset = context.cursor
  context.cursor = context.cursor + byteCount
  return offset
end

--- Read bounded unsigned integer assembled from bytes
-- @param context table @ parser context
-- @param byteCount number @ integer width
-- @return number|nil @ decoded value
function Module.Decompiler.readUnsigned(context, byteCount)
  local offset = Module.Decompiler.consume( context, byteCount )
  if not offset then return nil end

  local value = 0
  for index = byteCount - 1, 0, -1 do
    local byteValue = readByte( context.address + offset + index )
    if byteValue == nil then Module.Decompiler.fail( context, 'unreadable operand' ); return nil end
    value = value * 0x100 + byteValue
  end

  return value
end

--- Read bounded signed integer
-- @param context table @ parser context
-- @param byteCount number @ 1, 2, 4 or 8
-- @return number|nil @ signed value
function Module.Decompiler.readSigned(context, byteCount)
  local offset = Module.Decompiler.consume( context, byteCount )
  if not offset then return nil end

  if byteCount == 8 then return readQword( context.address + offset ) end

  local value = 0
  for index = byteCount - 1, 0, -1 do
    local byteValue = readByte( context.address + offset + index )
    if byteValue == nil then Module.Decompiler.fail( context, 'unreadable signed operand' ); return nil end
    value = value * 0x100 + byteValue
  end

  local signBit = 2 ^ (byteCount * 8 - 1)
  if value >= signBit then value = value - 2 ^ (byteCount * 8) end
  return value
end

--- Read one serialized floating-point component
-- @param context table @ parser context
-- @param byteCount number @ four for float or eight for double
-- @return number|nil @ decoded component
function Module.Decompiler.readReal(context, byteCount)
  local offset = Module.Decompiler.consume( context, byteCount )
  if not offset then return nil end
  if byteCount == 8 then return readDouble( context.address + offset ) end
  return readFloat( context.address + offset )
end


--- Read bounded runtime pointer operand
-- @param context table @ parser context
-- @return number|nil @ pointer value
function Module.Decompiler.readPointer(context)
  local offset = Module.Decompiler.consume( context, PTR_SIZE )
  if not offset then return nil end
  return readPointer( context.address + offset )
end

--- Resolve linked pointer through the caller's metadata adapter
-- @param context table @ parser context
-- @param address number|nil @ linked address
-- @param role string @ property/function/object/class role
-- @return string @ readable identifier
function Module.Decompiler.pointerName(context, address, role)
  if address and context.symbolByAddress[address] then return context.symbolByAddress[address] end

  local resolver = context.options.resolvePointer
  local resolved = type(resolver) == 'function' and resolver( address, role )
  if type(resolved) == 'table' then resolved = resolved.name end

  local baseName
  if type(resolved) == 'string' and resolved ~= '' then
    baseName = Module.Decompiler.identifier(resolved)
  else
    baseName = address and ('%s_0x%X'):format( Module.Decompiler.identifier(role), address ) or Module.Decompiler.identifier(role)
  end

  if not address then return baseName end

  local symbolName = baseName
  local owner = context.symbolOwnerByName[symbolName]

  if owner and owner ~= address then
    local suffix = context.nextSymbolSuffix[baseName] or 1

    repeat
      symbolName = baseName .. '_' .. suffix
      suffix = suffix + 1
      owner = context.symbolOwnerByName[symbolName]
    until not owner or owner == address

    context.nextSymbolSuffix[baseName] = suffix
  end

  context.symbolByAddress[address] = symbolName
  context.symbolOwnerByName[symbolName] = address
  return symbolName
end

--- Read current-target FScriptName (FName plus serialized extra dword)
-- @param context table @ parser context
-- @return string @ resolved or indexed name
function Module.Decompiler.readScriptName(context)
  local offset = Module.Decompiler.consume( context, 12 )
  if not offset then return 'UnknownName' end

  local nameIndex = readInteger( context.address + offset )
  local number = readInteger( context.address + offset + 4 ) or 0
  local resolver = context.options.resolveName
  local name = type(resolver) == 'function' and resolver( nameIndex, number )
  if not name then name = ('Name_%s_%d'):format( tostring(nameIndex or '?'), number ) end
  return Module.Decompiler.identifier(name)
end

--- Read null-terminated ANSI/UTF-16 string literal
-- @param context table @ parser context
-- @param wide boolean @ UTF-16 when true
-- @return string @ escaped C++ literal
function Module.Decompiler.readString(context, wide)
  local characters = {}
  local unitSize = wide and 2 or 1

  while not context.stopped and context.cursor + unitSize <= context.size do
    local offset = Module.Decompiler.consume( context, unitSize )
    local value = wide and readSmallInteger( context.address + offset ) or readByte( context.address + offset )
    if value == nil then Module.Decompiler.fail( context, 'unreadable string literal' ); break end
    if value == 0 then return (wide and 'L"' or '"') .. table.concat(characters) .. '"' end

    if value == 0x22 then characters[ #characters + 1 ] = '\\"'
    elseif value == 0x5C then characters[ #characters + 1 ] = '\\\\'
    elseif value >= 0x20 and value < 0x7F then characters[ #characters + 1 ] = string.char(value)
    else characters[ #characters + 1 ] = ('\\x%X'):format(value)
    end
  end

  Module.Decompiler.fail( context, 'unterminated string literal' )
  return wide and 'L"<unterminated>"' or '"<unterminated>"'
end

--- Parse expressions until delimiter token is consumed
-- @param context table @ parser context
-- @param delimiter string @ canonical delimiter opcode
-- @param depth number @ recursion depth
-- @return table[] @ child nodes excluding delimiter
function Module.Decompiler.parseUntil(context, delimiter, depth)
  local nodes = {}

  while not context.stopped and context.cursor < context.size do
    local node = Module.Decompiler.parseExpression( context, depth )
    if not node then break end
    if node.opcode == delimiter then return nodes end
    nodes[ #nodes + 1 ] = node
  end

  if not context.stopped then Module.Decompiler.fail( context, 'missing ' .. delimiter ) end
  return nodes
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// SEMANTIC HANDLERS

local DECOMPILER_OPERATION_HANDLERS = {}

--- Assign one semantic parser to one or more canonical operations
-- @param operations string[] @ canonical EExprToken operations
-- @param handler function @ semantic parser callback
local function registerDecompilerHandler(operations, handler)
  for _, operation in ipairs(operations) do DECOMPILER_OPERATION_HANDLERS[operation] = handler end
end

registerDecompilerHandler(
  { 'EX_LocalVariable', 'EX_InstanceVariable', 'EX_DefaultVariable', 'EX_LocalOutVariable', 'EX_ClassSparseDataVariable', 'EX_PropertyConst' },
  function(context, node, _, operation)
    node.kind = 'variable'
    node.property = Module.Decompiler.readPointer(context)
    node.name = Module.Decompiler.pointerName( context, node.property, 'Property' )
    node.scope = operation
  end
)

local SIMPLE_LITERAL_TEXT =
{
  EX_Self = 'this',
  EX_NoObject = 'nullptr',
  EX_NoInterface = 'nullptr',
  EX_IntZero = '0',
  EX_IntOne = '1',
  EX_True = 'true',
  EX_False = 'false',
}

registerDecompilerHandler(
  { 'EX_Self', 'EX_NoObject', 'EX_NoInterface', 'EX_IntZero', 'EX_IntOne', 'EX_True', 'EX_False' },
  function(_, node, _, operation)
    node.kind, node.text = 'literal', SIMPLE_LITERAL_TEXT[operation]
  end
)

registerDecompilerHandler(
  { 'EX_Nothing' },
  function(_, node)
    node.kind, node.text = 'nothing', ''
  end
)
registerDecompilerHandler(
  { 'EX_IntConst' },
  function(context, node)
    node.kind, node.text = 'literal', tostring( Module.Decompiler.readSigned(context, 4) or 0 )
  end
)
registerDecompilerHandler(
  { 'EX_IntConstByte', 'EX_ByteConst' },
  function(context, node)
    node.kind, node.text = 'literal', tostring( Module.Decompiler.readUnsigned(context, 1) or 0 )
  end
)
registerDecompilerHandler(
  { 'EX_Int64Const' },
  function(context, node)
    node.kind, node.text = 'literal', tostring( Module.Decompiler.readSigned(context, 8) or 0 )
  end
)
registerDecompilerHandler(
  { 'EX_UInt64Const' },
  function(context, node)
    node.kind, node.text = 'literal', ('0x%XULL'):format( Module.Decompiler.readUnsigned(context, 8) or 0 )
  end
)

registerDecompilerHandler(
  { 'EX_FloatConst' },
  function(context, node)
    local offset = Module.Decompiler.consume(context, 4)
    node.kind, node.text = 'literal', offset and ('%.9gF'):format(readFloat( context.address + offset )) or '0.0F'
  end
)

registerDecompilerHandler(
  { 'EX_DoubleConst' },
  function(context, node)
    local offset = Module.Decompiler.consume(context, 8)
    node.kind, node.text = 'literal', offset and ('%.17g'):format(readDouble( context.address + offset )) or '0.0'
  end
)

registerDecompilerHandler(
  { 'EX_StringConst', 'EX_UnicodeStringConst' },
  function(context, node, _, operation)
    node.kind, node.text = 'literal', Module.Decompiler.readString( context, operation == 'EX_UnicodeStringConst' )
  end
)

registerDecompilerHandler(
  { 'EX_NameConst', 'EX_InstanceDelegate' },
  function(context, node)
    node.kind, node.text = 'literal', ('FName("%s")'):format( Module.Decompiler.readScriptName(context) )
  end
)

registerDecompilerHandler(
  { 'EX_ObjectConst' },
  function(context, node)
    node.kind = 'literal'
    node.text = Module.Decompiler.pointerName( context, Module.Decompiler.readPointer(context), 'Object' )
  end
)

registerDecompilerHandler(
  { 'EX_TextConst' },
  function(context, node, depth)
    node.kind, node.literalType = 'text', Module.Decompiler.readUnsigned(context, 1)
    node.values = {}
    local valueCount = node.literalType == 1 and 3 or (node.literalType == 2 or node.literalType == 3) and 1 or node.literalType == 4 and 2 or 0

    if node.literalType == 4 then node.stringTable = Module.Decompiler.readPointer(context) end
    for _ = 1, valueCount do node.values[ #node.values + 1 ] = Module.Decompiler.parseExpression( context, depth ) end
    if node.literalType and node.literalType > 4 then Module.Decompiler.fail( context, 'unknown text literal type ' .. tostring(node.literalType) ) end
  end
)

registerDecompilerHandler(
  { 'EX_RotationConst' },
  function(context, node)
    local values = {}
    local componentSize = context.options.constantWidths and context.options.constantWidths.rotator or 4

    for index = 1, 3 do
      if componentSize == 8 then values[index] = ('%.17g'):format(Module.Decompiler.readReal(context, 8) or 0)
      else                       values[index] = tostring(Module.Decompiler.readSigned(context, 4) or 0)
      end
    end

    node.kind, node.text = 'literal', 'FRotator{ ' .. table.concat(values, ', ') .. ' }'
  end
)

registerDecompilerHandler(
  { 'EX_VectorConst', 'EX_Vector3fConst' },
  function(context, node, _, operation)
    local values = {}
    local componentSize = operation == 'EX_Vector3fConst' and 4
                                        or context.options.constantWidths and context.options.constantWidths.vector or 4

    for index = 1, 3 do
      local value = Module.Decompiler.readReal( context, componentSize ) or 0
      values[index] = componentSize == 8 and ('%.17g'):format(value) or ('%.9g'):format(value)
    end

    node.kind, node.text = 'literal', 'FVector{ ' .. table.concat(values, ', ') .. ' }'
  end
)

registerDecompilerHandler(
  { 'EX_TransformConst' },
  function(context, node)
    local values = {}
    local componentSize = context.options.constantWidths and context.options.constantWidths.transform or 4

    for index = 1, 10 do
      local value = Module.Decompiler.readReal( context, componentSize ) or 0
      values[index] = componentSize == 8 and ('%.17g'):format(value) or ('%.9g'):format(value)
    end

    node.kind, node.text = 'literal', 'FTransform{ ' .. table.concat(values, ', ') .. ' }'
  end
)

registerDecompilerHandler(
  { 'EX_Return' },
  function(context, node, depth)
    node.kind, node.expression = 'return', Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_Jump' },
  function(context, node)
    node.kind, node.target = 'jump', Module.Decompiler.readUnsigned(context, 4)
  end
)

registerDecompilerHandler(
  { 'EX_JumpIfNot' },
  function(context, node, depth)
    node.kind = 'jump_if_not'
    node.target = Module.Decompiler.readUnsigned(context, 4)
    node.condition = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_ComputedJump' },
  function(context, node, depth)
    node.kind, node.expression = 'computed_jump', Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_PushExecutionFlow', 'EX_SkipOffsetConst' },
  function(context, node)
    node.kind, node.target = 'flow_offset', Module.Decompiler.readUnsigned(context, 4)
  end
)

registerDecompilerHandler(
  { 'EX_PopExecutionFlowIfNot' },
  function(context, node, depth)
    node.kind, node.condition = 'pop_if_not', Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_PopExecutionFlow' },
  function(_, node)
    node.kind = 'pop_flow'
  end
)

registerDecompilerHandler(
  { 'EX_Let' },
  function(context, node, depth)
    node.kind = 'assign'
    node.assignmentProperty = Module.Decompiler.readPointer(context)
    node.left = Module.Decompiler.parseExpression( context, depth )
    node.right = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_LetObj', 'EX_LetWeakObjPtr', 'EX_LetBool', 'EX_LetDelegate', 'EX_LetMulticastDelegate' },
  function(context, node, depth)
    node.kind = 'assign'
    node.left = Module.Decompiler.parseExpression( context, depth )
    node.right = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_LetValueOnPersistentFrame' },
  function(context, node, depth)
    node.kind = 'assign'
    local propertyAddress = Module.Decompiler.readPointer(context)
    node.left = { kind = 'variable', name = Module.Decompiler.pointerName( context, propertyAddress, 'Property' ), scope = 'EX_LocalVariable' }
    node.right = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_StructMemberContext' },
  function(context, node, depth)
    node.kind = 'member'
    node.property = Module.Decompiler.readPointer(context)
    node.name = Module.Decompiler.pointerName( context, node.property, 'Member' )
    node.context = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_Context', 'EX_Context_FailSilent', 'EX_ClassContext' },
  function(context, node, depth, operation)
    node.kind = 'context'
    node.context = Module.Decompiler.parseExpression( context, depth )
    node.skipOffset = Module.Decompiler.readUnsigned(context, 4)
    node.resultProperty = Module.Decompiler.readPointer(context)
    node.expression = Module.Decompiler.parseExpression( context, depth )
    node.failSilent = operation == 'EX_Context_FailSilent'
    node.classContext = operation == 'EX_ClassContext'
  end
)

registerDecompilerHandler(
  { 'EX_InterfaceContext', 'EX_SoftObjectConst', 'EX_FieldPathConst' },
  function(context, node, depth)
    node.kind, node.expression = 'passthrough', Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_FinalFunction', 'EX_LocalFinalFunction', 'EX_CallMath', 'EX_CallMulticastDelegate' },
  function(context, node, depth, operation)
    node.kind = operation == 'EX_CallMulticastDelegate' and 'delegate_call' or 'call'
    node.callOpcode = operation
    node.functionAddress = Module.Decompiler.readPointer(context)
    node.name = Module.Decompiler.pointerName( context, node.functionAddress, 'Function' )
    node.arguments = Module.Decompiler.parseUntil( context, 'EX_EndFunctionParms', depth )
  end
)

registerDecompilerHandler(
  { 'EX_VirtualFunction', 'EX_LocalVirtualFunction' },
  function(context, node, depth, operation)
    node.kind = 'call'
    node.callOpcode = operation
    node.name = Module.Decompiler.readScriptName(context)
    node.virtual = true
    node.arguments = Module.Decompiler.parseUntil( context, 'EX_EndFunctionParms', depth )
  end
)

registerDecompilerHandler(
  { 'EX_AddMulticastDelegate', 'EX_RemoveMulticastDelegate' },
  function(context, node, depth, operation)
    node.kind = 'binary_call'
    node.name = operation == 'EX_AddMulticastDelegate' and 'AddDelegate' or 'RemoveDelegate'
    node.left = Module.Decompiler.parseExpression( context, depth )
    node.right = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_ClearMulticastDelegate' },
  function(context, node, depth)
    node.kind, node.name = 'unary_call', 'ClearDelegate'
    node.expression = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_BindDelegate' },
  function(context, node, depth)
    node.kind, node.name = 'bind_delegate', Module.Decompiler.readScriptName(context)
    node.left = Module.Decompiler.parseExpression( context, depth )
    node.right = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_MetaCast', 'EX_DynamicCast', 'EX_ObjToInterfaceCast', 'EX_CrossInterfaceCast', 'EX_InterfaceToObjCast' },
  function(context, node, depth)
    node.kind = 'cast'
    node.typeName = Module.Decompiler.pointerName( context, Module.Decompiler.readPointer(context), 'Class' )
    node.expression = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_Cast' },
  function(context, node, depth)
    node.kind, node.conversion = 'cast', Module.Decompiler.readUnsigned(context, 1)
    node.typeName = ('Conversion_%02X'):format(node.conversion or 0)
    node.expression = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_Skip' },
  function(context, node, depth)
    node.kind, node.skipOffset = 'passthrough', Module.Decompiler.readUnsigned(context, 4)
    node.expression = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_Assert' },
  function(context, node, depth)
    node.kind = 'assert'
    node.line = Module.Decompiler.readUnsigned(context, 2)
    node.debugMode = Module.Decompiler.readUnsigned(context, 1)
    node.expression = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_StructConst' },
  function(context, node, depth)
    node.kind = 'aggregate'
    node.typeName = Module.Decompiler.pointerName( context, Module.Decompiler.readPointer(context), 'Struct' )
    node.serializedSize = Module.Decompiler.readUnsigned(context, 4)
    node.values = Module.Decompiler.parseUntil( context, 'EX_EndStructConst', depth )
  end
)

registerDecompilerHandler(
  { 'EX_ArrayConst', 'EX_SetConst' },
  function(context, node, depth, operation)
    node.kind = 'aggregate'
    node.typeName = operation == 'EX_ArrayConst' and 'TArray' or 'TSet'
    node.innerProperty = Module.Decompiler.readPointer(context)
    node.elementCount = Module.Decompiler.readUnsigned(context, 4)
    node.values = Module.Decompiler.parseUntil( context, operation == 'EX_ArrayConst' and 'EX_EndArrayConst' or 'EX_EndSetConst', depth )
  end
)

registerDecompilerHandler(
  { 'EX_MapConst' },
  function(context, node, depth)
    node.kind, node.typeName = 'aggregate', 'TMap'
    node.keyProperty = Module.Decompiler.readPointer(context)
    node.valueProperty = Module.Decompiler.readPointer(context)
    node.elementCount = Module.Decompiler.readUnsigned(context, 4)
    node.values = Module.Decompiler.parseUntil( context, 'EX_EndMapConst', depth )
  end
)

registerDecompilerHandler(
  { 'EX_SetArray', 'EX_SetSet', 'EX_SetMap' },
  function(context, node, depth, operation)
    node.kind = 'container_set'
    node.container = Module.Decompiler.parseExpression( context, depth )
    if operation ~= 'EX_SetArray' then node.elementCount = Module.Decompiler.readUnsigned(context, 4) end
    local delimiter = operation == 'EX_SetArray' and 'EX_EndArray' or operation == 'EX_SetSet' and 'EX_EndSet' or 'EX_EndMap'
    node.values = Module.Decompiler.parseUntil( context, delimiter, depth )
  end
)

registerDecompilerHandler(
  { 'EX_ArrayGetByRef' },
  function(context, node, depth)
    node.kind = 'index'
    node.left = Module.Decompiler.parseExpression( context, depth )
    node.right = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_SwitchValue' },
  function(context, node, depth)
    node.kind = 'switch_value'
    local caseCount = Module.Decompiler.readUnsigned(context, 2) or 0
    node.switchEndOffset = Module.Decompiler.readUnsigned(context, 4)
    node.index = Module.Decompiler.parseExpression( context, depth )
    node.cases = {}

    if caseCount > 0x1000 then
      Module.Decompiler.fail( context, 'implausible switch case count' )
      return
    end

    for caseIndex = 1, caseCount do
      node.cases[caseIndex] =
      {
        match = Module.Decompiler.parseExpression( context, depth ),
        nextOffset = Module.Decompiler.readUnsigned(context, 4),
        value = Module.Decompiler.parseExpression( context, depth ),
      }
    end

    node.default = Module.Decompiler.parseExpression( context, depth )
  end
)

registerDecompilerHandler(
  { 'EX_EndOfScript', 'EX_EndFunctionParms', 'EX_EndStructConst', 'EX_EndArray', 'EX_EndArrayConst', 'EX_EndSet', 'EX_EndMap', 'EX_EndSetConst', 'EX_EndMapConst', 'EX_EndParmValue' },
  function(_, node)
    node.kind = 'delimiter'
  end
)

registerDecompilerHandler(
  { 'EX_NothingInt32' },
  function(context, node)
    node.kind, node.text = 'literal', tostring( Module.Decompiler.readUnsigned(context, 4) or 0 )
  end
)

registerDecompilerHandler(
  { 'EX_BitFieldConst' },
  function(context, node)
    node.kind = 'literal'
    local propertyAddress = Module.Decompiler.readPointer(context)
    local mask = Module.Decompiler.readUnsigned(context, 1) or 0
    node.text = ('BitField(%s, 0x%X)'):format( Module.Decompiler.pointerName( context, propertyAddress, 'Property' ), mask )
  end )

registerDecompilerHandler(
  { 'EX_Breakpoint', 'EX_Tracepoint', 'EX_WireTracepoint', 'EX_DeprecatedOp4A' },
  function(_, node, _, operation)
    node.kind, node.text = 'debug', operation
  end
)

--- Parse one Kismet expression into semantic intermediate node
-- faulty/unsupported ops terminate parsing at known byte
-- @param context table @ parser context
-- @param depth number|nil @ recursive expression depth
-- @return table|nil @ intermediate expression node
function Module.Decompiler.parseExpression(context, depth)
  depth = depth or 0
  if context.stopped or context.cursor >= context.size then return nil end
  if depth > MAX_EXPRESSION_DEPTH then Module.Decompiler.fail( context, 'expression nesting limit exceeded' ); return nil end

  context.instructionCount = context.instructionCount + 1
  if context.instructionCount > context.instructionLimit then Module.Decompiler.fail( context, 'instruction limit exceeded' ); return nil end

  local startOffset = context.cursor
  local opcodeValue = Module.Decompiler.readUnsigned( context, 1 )
  if opcodeValue == nil then return nil end

  local definition = Module.Opcodes[opcodeValue]
  local operation = definition and definition.operation
  local node = { opcode = operation or ('EX_Unknown_%02X'):format(opcodeValue), value = opcodeValue, offset = startOffset }
  context.trace[ #context.trace + 1 ] = { offset = startOffset, value = opcodeValue, opcode = node.opcode, depth = depth }

  if not operation then Module.Decompiler.fail( context, ('unknown opcode 0x%02X'):format(opcodeValue) ); return node end

  local operationHandler = DECOMPILER_OPERATION_HANDLERS[operation]

  if operationHandler then
    operationHandler( context, node, depth + 1, operation )
  else
    node.kind = 'unsupported'
    Module.Decompiler.fail( context, 'pseudocode operand layout is unsupported for ' .. operation )
  end

  node.endOffset = context.cursor
  return node
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// RENDER HANDLERS

local EXPRESSION_RENDER_HANDLERS =
{
  literal = function(node)
    return node.text or node.opcode
  end,

  debug = function(node)
    return node.text or node.opcode
  end,
  
  nothing = function()
    return ''
  end,

  variable = function(node, memberOnly)
    if node.scope == 'EX_InstanceVariable' or node.scope == 'EX_ClassSparseDataVariable' then
      return memberOnly and node.name or 'this->' .. node.name
    end
    if node.scope == 'EX_DefaultVariable' then
      return memberOnly and node.name or 'DefaultObject->' .. node.name
    end
    return node.name
  end,

  assign = function(node, _, render)
    return render(node.left) .. ' = ' .. render(node.right)
  end,

  member = function(node, _, render)
    return render(node.context) .. '.' .. node.name
  end,

  context = function(node, _, render)
    local separator = node.classContext and '::' or '->'
    return render(node.context) .. separator .. render( node.expression, true )
  end,

  passthrough = function(node, _, render)
    return render(node.expression)
  end,

  cast = function(node, _, render)
    return ('Cast<%s>(%s)'):format( node.typeName or 'Unknown', render(node.expression) )
  end,

  call = function(node, memberOnly, render)
    local arguments = {}
    for _, argument in ipairs(node.arguments or {}) do
      arguments[ #arguments + 1 ] = render(argument)
    end
    local memberCall = node.virtual or node.callOpcode == 'EX_FinalFunction' or node.callOpcode == 'EX_LocalFinalFunction'
    local prefix = memberCall and not memberOnly and 'this->' or ''
    return prefix .. (node.name or 'UnknownFunction') .. '(' .. table.concat( arguments, ', ' ) .. ')'
  end,

  delegate_call = function(node, _, render)
    local arguments = {}
    for _, argument in ipairs(node.arguments or {}) do
      arguments[ #arguments + 1 ] = render(argument)
    end
    return (node.name or 'UnknownFunction') .. '(' .. table.concat( arguments, ', ' ) .. ')'
  end,

  binary_call = function(node, _, render)
    return ('%s(%s, %s)'):format( node.name, render(node.left), render(node.right) )
  end,

  unary_call = function(node, _, render)
    return ('%s(%s)'):format( node.name, render(node.expression) )
  end,

  bind_delegate = function(node, _, render)
    return ('BindDelegate(%s, %s, &%s)'):format( render(node.left), render(node.right), node.name )
  end,

  aggregate = function(node, _, render)
    local values = {}
    for _, value in ipairs(node.values or {}) do
      values[ #values + 1 ] = render(value)
    end
    return (node.typeName or 'Aggregate') .. '{ ' .. table.concat( values, ', ' ) .. ' }'
  end,

  container_set = function(node, _, render)
    local values = {}
    for _, value in ipairs(node.values or {}) do
      values[ #values + 1 ] = render(value)
    end
    return render(node.container) .. ' = { ' .. table.concat( values, ', ' ) .. ' }'
  end,

  index = function(node, _, render)
    return render(node.left) .. '[' .. render(node.right) .. ']'
  end,

  text = function(node, _, render)
    local values = {}
    for _, value in ipairs(node.values or {}) do
      values[ #values + 1 ] = render(value)
    end
    return ('FText::FromLiteral(%s)'):format( table.concat(values, ', ') )
  end,

  switch_value = function(node, _, render)
    local cases = {}
    for _, case in ipairs(node.cases or {}) do
      cases[ #cases + 1 ] = render(case.match) .. ' : ' .. render(case.value)
    end
    return ('SwitchValue(%s, { %s }, %s)'):format( render(node.index), table.concat(cases, ', '), render(node.default) )
  end,

  assert = function(node, _, render)
    return 'ensure(' .. render(node.expression) .. ')'
  end,

  ['return'] = function(node, _, render)
    local expression = render(node.expression)
    return expression ~= '' and 'return ' .. expression or 'return'
  end,

  computed_jump = function(node, _, render)
    return 'goto /* computed */ ' .. render(node.expression)
  end,

  pop_if_not = function(node, _, render)
    return 'if (!(' .. render(node.condition) .. ')) /* pop execution flow */'
  end,

  flow_offset = function(node)
    return ('/* execution-flow target L_%04X */'):format(node.target or 0)
  end,

  pop_flow = function()
    return '/* pop execution flow */'
  end,

  delimiter = function()
    return ''
  end,
}

--- Render one intermediate expression as C++-style pseudocode
-- @param node table|nil @ parsed node
-- @param memberOnly boolean|nil @ suppress this-> on member side of context
-- @return string @ expression text
function Module.Decompiler.renderExpression(node, memberOnly)
  if not node then return '/* missing expression */' end
  local handler = EXPRESSION_RENDER_HANDLERS[node.kind]
  if handler then return handler( node, memberOnly, Module.Decompiler.renderExpression ) end

  return '/* ' .. (node.opcode or 'unsupported') .. ' */'
end

--- Format complete Script array as one hex line for parser investigations
-- @param context table @ parser context
-- @return string @ space-separated bytes from Script.Data through Script.Num
function Module.Decompiler.formatBytecode(context)
  local bytes = {}

  for offset = 0, context.size - 1 do
    local byteValue = readByte( context.address + offset )
    bytes[ #bytes + 1 ] = byteValue and ('%02X'):format(byteValue) or '??'
  end

  return table.concat( bytes, ' ' )
end

--- Render parsed top-level bytecode with explicit labels and gotos
-- preserves branch destinations
-- @param context table @ completed parser context
-- @return string @ pseudocode function body
function Module.Decompiler.renderBody(context)
  local lines = {}
  local labels = {}

  local function appendSpaced(line)
    lines[ #lines + 1 ] = line
    lines[ #lines + 1 ] = ''
  end

  for _, statement in ipairs(context.statements or {}) do
    if statement.kind == 'jump' or statement.kind == 'jump_if_not' then labels[statement.target] = true end
  end

  appendSpaced('{')

  for _, statement in ipairs(context.statements or {}) do
    if labels[statement.offset] then appendSpaced( ('L_%04X:'):format(statement.offset) ) end

    local prefix = context.options.includeStatementOffsets == false and '    ' or ('    /* +0x%04X */ '):format(statement.offset)

    if statement.kind == 'jump' then
      appendSpaced( prefix .. ('goto L_%04X;'):format(statement.target or 0) )
    elseif statement.kind == 'jump_if_not' then
      appendSpaced( prefix .. ('if (!(%s)) goto L_%04X;'):format( Module.Decompiler.renderExpression(statement.condition), statement.target or 0 ) )
    elseif statement.opcode ~= 'EX_EndOfScript' and statement.kind ~= 'delimiter' then
      local expression = Module.Decompiler.renderExpression(statement)
      if expression ~= '' then appendSpaced( prefix .. expression .. ';' ) end
    end
  end

  if context.stopped then
    lines[ #lines + 1 ] = '    /*'
    lines[ #lines + 1 ] = ('       Partial decompilation stopped at +0x%X: %s'):format( context.cursor, table.concat(context.errors, '; ') )
    lines[ #lines + 1 ] = '       Bytecode: ' .. Module.Decompiler.formatBytecode(context)
    lines[ #lines + 1 ] = '    */'
    lines[ #lines + 1 ] = ''
  end

  if lines[#lines] == '' then lines[#lines] = nil end
  lines[ #lines + 1 ] = '}'
  return table.concat( lines, '\n' )
end

--- Decompile one UFunction Script array into intermediate model and body
-- @param functionMetadata table @ validated UFunction metadata
-- @param options table|nil @ metadata resolvers and rendering options
-- @return table|nil @ decompilation result
-- @return string|nil @ error
function Module.Decompiler.decompile(functionMetadata, options)
  if type(functionMetadata) ~= 'table'
     or type(functionMetadata.bytecode) ~= 'number'
     or type(functionMetadata.bytecodeSize) ~= 'number'
     or functionMetadata.bytecodeSize <= 0
  then
    return nil, 'UFunction has no validated Blueprint bytecode'
  end

  local context = Module.Decompiler.newContext( functionMetadata.bytecode, functionMetadata.bytecodeSize, options )
  context.statements = {}

  while not context.stopped and context.cursor < context.size do
    local statement = Module.Decompiler.parseExpression( context, 0 )
    if not statement then break end
    context.statements[ #context.statements + 1 ] = statement
    if statement.opcode == 'EX_EndOfScript' then context.terminated = true; break end
  end

  if not context.terminated and not context.stopped then Module.Decompiler.fail( context, 'Script ended without EX_EndOfScript' ) end

  context.body = Module.Decompiler.renderBody(context)
  return context
end

-- ///---///--///---///--///---///--/// BYTECODE PATCHING

--- Copy and validate supplied byte sequence
-- @param patchBytes number[] @ byte values indexed from one
-- @return number[]|nil @ independent validated copy
-- @return string|nil @ validation error
function Module.Patches.validateBytes(patchBytes)
  if type(patchBytes) ~= 'table' or #patchBytes == 0 then return nil, 'Patch bytes must be a non-empty array' end

  local validated = {}

  for index, byteValue in ipairs(patchBytes) do
    if type(byteValue) ~= 'number' or byteValue % 1 ~= 0 or byteValue < 0 or byteValue > 0xFF then
      return nil, ('Patch byte %d is not an integer in the 0..255 range'):format(index)
    end

    validated[index] = byteValue
  end

  return validated
end

--- Read exact byte range into a lua array
-- @param address number @ target-process address
-- @param byteCount number @ number of bytes to copy
-- @return number[]|nil @ copied bytes
-- @return string|nil @ read error
function Module.Patches.readRange(address, byteCount)
  local bytes = readBytes( address, byteCount, true )
  if type(bytes) ~= 'table' or #bytes ~= byteCount then return nil, 'Bytecode range is unreadable' end

  local copy = {}
  for index = 1, byteCount do copy[index] = bytes[index] end
  return copy
end

--- Compare target byte range with expected array
-- @param address number @ target-process address
-- @param expected number[] @ expected bytes
-- @return boolean @ true when every byte matches
function Module.Patches.rangeEquals(address, expected)
  local actual = readBytes( address, #expected, true )
  if type(actual) ~= 'table' or #actual ~= #expected then return false end

  for index, expectedByte in ipairs(expected) do
    if actual[index] ~= expectedByte then return false end
  end

  return true
end

--- Write and verify exact byte array
-- Individual writes avoid depending on CE builds accepting a table argument
-- to writeBytes. The caller owns rollback when verification fails.
-- @param address number @ target-process address
-- @param bytes number[] @ bytes to write
-- @return boolean @ true when read-back matches
function Module.Patches.writeRange(address, bytes)
  for index, byteValue in ipairs(bytes) do writeBytes( address + index - 1, byteValue ) end
  return Module.Patches.rangeEquals( address, bytes )
end

--- Test if two half-open byte ranges overlap
-- @param leftStart number
-- @param leftSize number
-- @param rightStart number
-- @param rightSize number
-- @return boolean
function Module.Patches.rangesOverlap(leftStart, leftSize, rightStart, rightSize)
  return leftStart < rightStart + rightSize and rightStart < leftStart + leftSize
end

--- Append little-endian integer to a byte array
-- @param bytes number[] @ destination byte array
-- @param value number @ integer value
-- @param byteCount number @ encoded width
function Module.Patches.appendInteger(bytes, value, byteCount)
  for _ = 1, byteCount do
    bytes[ #bytes + 1 ] = value & 0xFF
    value = value >> 8
  end
end

--- Append Lua-packed scalar to a byte array
-- @param bytes number[] @ destination byte array
-- @param format string @ string.pack format
-- @param value number @ scalar value
-- @return boolean|nil @ true when packed
-- @return string|nil @ packing error
function Module.Patches.appendPacked(bytes, format, value)
  if type(string.pack) ~= 'function' then return nil, 'This Lua build does not provide string.pack' end

  local packed, packError
  local packedSuccessfully

  packedSuccessfully, packed = pcall( string.pack, format, value )
  if not packedSuccessfully then packError = packed; packed = nil end
  if not packed then return nil, tostring(packError) end

  for byteIndex = 1, #packed do bytes[ #bytes + 1 ] = packed:byte(byteIndex) end
  return true
end

Module.Patches.outputAssignmentHandlers = {}

--- Register one output-assignment encoder for one/more types
-- @param propertyTypes string[]
-- @param handler function @ encoder(bytes, propertyAddress, propertyType, value)
function Module.Patches.registerOutputAssignmentHandler(propertyTypes, handler)
  for _, propertyType in ipairs(propertyTypes) do
    Module.Patches.outputAssignmentHandlers[propertyType] = handler
  end
end

--- Append common EX_Let target used by scalar output assignments
-- @param bytes number[] @ destination byte array
-- @param propertyAddress number @ reflected output FProperty/UProperty address
function Module.Patches.appendScalarOutTarget(bytes, propertyAddress)
  bytes[ #bytes + 1 ] = 0x0F -- EX_Let
  Module.Patches.appendInteger( bytes, propertyAddress, PTR_SIZE ) -- assignment FProperty*
  bytes[ #bytes + 1 ] = 0x48 -- EX_LocalOutVariable
  Module.Patches.appendInteger( bytes, propertyAddress, PTR_SIZE )
end

Module.Patches.registerOutputAssignmentHandler(
  { 'BoolProperty' },
  function(bytes, propertyAddress, _, value)
    if type(value) ~= 'boolean' then return nil, 'BoolProperty output requires true or false' end

    bytes[ #bytes + 1 ] = 0x14 -- EX_LetBool
    bytes[ #bytes + 1 ] = 0x48 -- EX_LocalOutVariable
    Module.Patches.appendInteger( bytes, propertyAddress, PTR_SIZE )
    bytes[ #bytes + 1 ] = value and 0x27 or 0x28 -- EX_True / EX_False
    return true
  end
)

Module.Patches.registerOutputAssignmentHandler(
  { 'ObjectProperty', 'ClassProperty', 'ClassPtrProperty' },
  function(bytes, propertyAddress, propertyType, value)
    if type(value) ~= 'number' or value % 1 ~= 0 or value < 0 then
      return nil, propertyType .. ' output requires a raw address or zero'
    end

    bytes[ #bytes + 1 ] = 0x5F -- EX_LetObj
    bytes[ #bytes + 1 ] = 0x48 -- EX_LocalOutVariable
    Module.Patches.appendInteger( bytes, propertyAddress, PTR_SIZE )

    if value == 0 then
      bytes[ #bytes + 1 ] = 0x2A -- EX_NoObject
    else
      bytes[ #bytes + 1 ] = 0x20 -- EX_ObjectConst
      Module.Patches.appendInteger( bytes, value, PTR_SIZE )
    end

    return true
  end
)

Module.Patches.registerOutputAssignmentHandler(
  { 'ByteProperty', 'UInt8Property' },
  function(bytes, propertyAddress, propertyType, value)
    if type(value) ~= 'number' or value % 1 ~= 0 or value < 0 or value > 0xFF then
      return nil, propertyType .. ' output must be an integer in the 0..255 range'
    end

    Module.Patches.appendScalarOutTarget( bytes, propertyAddress )
    bytes[ #bytes + 1 ] = 0x24 -- EX_ByteConst
    Module.Patches.appendInteger( bytes, value, 1 )
    return true
  end
)

Module.Patches.registerOutputAssignmentHandler(
  { 'IntProperty', 'Int32Property' },
  function(bytes, propertyAddress, propertyType, value)
    if type(value) ~= 'number' or value % 1 ~= 0 or value < -0x80000000 or value > 0x7FFFFFFF then
      return nil, propertyType .. ' output exceeds int32 range'
    end

    Module.Patches.appendScalarOutTarget( bytes, propertyAddress )
    bytes[ #bytes + 1 ] = 0x1D -- EX_IntConst
    Module.Patches.appendInteger( bytes, value, 4 )
    return true
  end
)

Module.Patches.registerOutputAssignmentHandler(
  { 'Int64Property' },
  function(bytes, propertyAddress, _, value)
    if type(value) ~= 'number' or value % 1 ~= 0 then return nil, 'Int64Property output requires an integer' end

    Module.Patches.appendScalarOutTarget( bytes, propertyAddress )
    bytes[ #bytes + 1 ] = 0x35 -- EX_Int64Const
    Module.Patches.appendInteger( bytes, value, 8 )
    return true
  end
)

Module.Patches.registerOutputAssignmentHandler(
  { 'UInt64Property' },
  function(bytes, propertyAddress, _, value)
    if type(value) ~= 'number' or value % 1 ~= 0 or value < 0 then
      return nil, 'UInt64Property output requires a non-negative integer'
    end

    Module.Patches.appendScalarOutTarget( bytes, propertyAddress )
    bytes[ #bytes + 1 ] = 0x36 -- EX_UInt64Const
    Module.Patches.appendInteger( bytes, value, 8 )
    return true
  end
)

Module.Patches.registerOutputAssignmentHandler(
  { 'FloatProperty' },
  function(bytes, propertyAddress, _, value)
    if type(value) ~= 'number' then return nil, 'FloatProperty output requires a number' end

    Module.Patches.appendScalarOutTarget( bytes, propertyAddress )
    bytes[ #bytes + 1 ] = 0x1E -- EX_FloatConst
    return Module.Patches.appendPacked( bytes, '<f', value )
  end
)

Module.Patches.registerOutputAssignmentHandler(
  { 'DoubleProperty' },
  function(bytes, propertyAddress, _, value)
    if type(value) ~= 'number' then return nil, 'DoubleProperty output requires a number' end

    Module.Patches.appendScalarOutTarget( bytes, propertyAddress )
    bytes[ #bytes + 1 ] = 0x37 -- EX_DoubleConst
    return Module.Patches.appendPacked( bytes, '<d', value )
  end
)

--- Encode one assignment to output parameter
-- It writes through EX_LocalOutVariable
-- @param bytes number[] @ destination byte array
-- @param assignment table @ name, property and requested value
-- @return boolean|nil @ true when encoded
-- @return string|nil @ unsupported type/value error
function Module.Patches.appendOutParameterAssignment(bytes, assignment)
  local property = assignment.property
  local propertyAddress = property and property.propertyAddress
  local propertyType = property and property.propertyType
  if type(propertyAddress) ~= 'number' or propertyAddress == 0 then return nil, 'reflected property address is unavailable' end

  local handler = Module.Patches.outputAssignmentHandlers[propertyType]
  if not handler then return nil, 'unsupported output type ' .. tostring(propertyType) end

  return handler( bytes, propertyAddress, propertyType, assignment.value )
end

--- Build BP function stub assigning outputs and returning
-- @param assignments table[] @ ordered reflected output assignments
-- @return number[]|nil @ complete replacement bytecode
-- @return string|nil @ encoding error
function Module.Patches.buildOutParameterStub(assignments)
  if type(assignments) ~= 'table' or #assignments == 0 then return nil, 'At least one output assignment is required' end

  local bytes = {}

  for _, assignment in ipairs(assignments) do
    local encoded, encodingError = Module.Patches.appendOutParameterAssignment( bytes, assignment )
    if not encoded then return nil, ('%s: %s'):format( tostring(assignment.name), tostring(encodingError) ) end
  end

  bytes[ #bytes + 1 ] = 0x04 -- EX_Return
  bytes[ #bytes + 1 ] = 0x0B -- EX_Nothing
  bytes[ #bytes + 1 ] = 0x53 -- EX_EndOfScript
  return bytes
end

--- Apply reversible patch inside validated UFunction Script array
-- returned handle has original bytes
-- @param functionMetadata table @ validated UFunction metadata
-- @param patchBytes number[] @ replacement byte sequence
-- @param byteOffset number|nil @ zero-based offset in Script.Data
-- @return table|nil @ reversible patch handle
-- @return string|nil @ error
function Module.Patches.apply(functionMetadata, patchBytes, byteOffset)
  if type(functionMetadata) ~= 'table' then return nil, 'UFunction metadata is required' end
  if type(functionMetadata.bytecode) ~= 'number' or functionMetadata.bytecode == 0 then return nil, 'UFunction has no validated Blueprint bytecode' end
  if type(functionMetadata.bytecodeSize) ~= 'number' or functionMetadata.bytecodeSize <= 0 then return nil, 'UFunction Script.Num is unavailable' end

  byteOffset = byteOffset or 0
  if type(byteOffset) ~= 'number' or byteOffset % 1 ~= 0 or byteOffset < 0 then return nil, 'Patch offset must be a non-negative integer' end

  local validatedBytes, validationError = Module.Patches.validateBytes(patchBytes)
  if not validatedBytes then return nil, validationError end
  if byteOffset + #validatedBytes > functionMetadata.bytecodeSize then return nil, 'Patch exceeds UFunction Script.Num' end

  local patchAddress = functionMetadata.bytecode + byteOffset
  local originalBytes, readError = Module.Patches.readRange( patchAddress, #validatedBytes )
  if not originalBytes then return nil, readError end

  if not Module.Patches.writeRange( patchAddress, validatedBytes ) then
    Module.Patches.writeRange( patchAddress, originalBytes )
    return nil, 'Bytecode patch verification failed; original bytes were restored'
  end

  return
  {
    functionAddress = functionMetadata.address,
    functionName = functionMetadata.name,
    bytecodeAddress = functionMetadata.bytecode,
    bytecodeSize = functionMetadata.bytecodeSize,
    address = patchAddress,
    offset = byteOffset,
    size = #validatedBytes,
    originalBytes = originalBytes,
    patchedBytes = validatedBytes,
    active = true,
  }
end

--- Restore patch handle
-- as produced by Module.Patches.apply
-- @param patch table @ patch handle
-- @param force boolean|nil @ restore even when current bytes changed externally
-- @return boolean|nil @ true when restored
-- @return string|nil @ error
function Module.Patches.restore(patch, force)
  if type(patch) ~= 'table' or type(patch.address) ~= 'number' or type(patch.originalBytes) ~= 'table' then
    return nil, 'Invalid function patch handle'
  end

  if patch.active == false then return true end
  if not force and not Module.Patches.rangeEquals( patch.address, patch.patchedBytes or {} ) then
    return nil, 'Patched bytecode changed after patching; pass force=true to overwrite it'
  end

  if not Module.Patches.writeRange( patch.address, patch.originalBytes ) then return nil, 'Original bytecode restoration failed verification' end

  patch.active = false
  return true
end

local VALUE_TYPES =
{
  byte = function() return vtByte end,
  word = function() return vtWord end,
  dword = function() return vtDword end,
  qword = function() return vtQword end,
  pointer = function() return vtPointer end,
  float = function() return vtSingle end,
  double = function() return vtDouble end,
  string = function() return vtString end,
  wstring = function() return vtUnicodeString end,
  fname = function() return vtQword end,
}

--- Render decoded bytecode as ce struct
-- @param functionMetadata table @ validated UFunction metadata
-- @param options table|nil @ pointer description and FName custom-type options
-- @return userdata|nil @ CE structure rooted at Script.Data
-- @return string|nil @ error or partial-decoding feedback
function Module.Structures.create(functionMetadata, options)
  if type(functionMetadata) ~= 'table' or not functionMetadata.bytecode or not functionMetadata.bytecodeSize or functionMetadata.bytecodeSize <= 0 then
    return nil, 'UFunction has no validated Blueprint bytecode'
  end

  local decoded = Module.decode( functionMetadata.bytecode, functionMetadata.bytecodeSize, options )
  local structure = createStructure( 'ceUE.Kismet ' .. (functionMetadata.name or '') )
  structure.beginUpdate()

  for _, descriptor in ipairs(decoded.elements) do
    local element = structure.addElement()
    element.Name = descriptor.name
    element.Offset = descriptor.offset
    element.Vartype = VALUE_TYPES[descriptor.kind] and VALUE_TYPES[descriptor.kind]() or vtByte

    if descriptor.size and (descriptor.kind == 'string' or descriptor.kind == 'wstring') then
      element.ByteSize = descriptor.size
    end

    if descriptor.kind == 'fname' and options and options.hasFNameCustomType then
      element.Vartype = vtCustom
      element.CustomTypeName = 'FName'
    end
  end

  structure.endUpdate()

  local feedback = #decoded.errors > 0 and table.concat( decoded.errors, '; ' ) or nil
  if decoded.truncatedRawTail then feedback = (feedback and feedback .. '; ' or '') .. 'raw tail display was truncated' end
  return structure, feedback
end

return Module
