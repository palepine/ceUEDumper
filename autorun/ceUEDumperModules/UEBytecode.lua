--[[
  ceUEDumperModules — a Cheat Engine Unreal Engine Dumper — Copyright (C) 2026 palepine

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.
]]

--- Unreal Kismet bytecode decoder
-- todo: use handlers to clean functions

local Module =
{
  Opcodes = {},
  Decoder = {},
  Structures = {},
  Patches = {},
}

-- EX_Return, EX_Nothing, EX_EndOfScript for NOPing and returning function prologue
Module.Patches.VOID_RETURN = { 0x04, 0x0B, 0x53 }

local PTR_SIZE = 0x8
local MAX_EXPRESSION_DEPTH = 0x100
local MAX_INSTRUCTION_COUNT = 0x10000
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

local PROPERTY_OPERAND =
{
  EX_LocalVariable = true,
  EX_InstanceVariable = true,
  EX_DefaultVariable = true,
  EX_LocalOutVariable = true,
  EX_ClassSparseDataVariable = true,
  EX_PropertyConst = true,
}

local TWO_EXPRESSION_LET =
{
  EX_LetObj = true,
  EX_LetWeakObjPtr = true,
  EX_LetBool = true,
  EX_LetDelegate = true,
  EX_LetMulticastDelegate = true,
}

local INTERFACE_CAST =
{
  EX_ObjToInterfaceCast = true,
  EX_CrossInterfaceCast = true,
  EX_InterfaceToObjCast = true,
}

local FINAL_CALL =
{
  EX_CallMath = true,
  EX_LocalFinalFunction = true,
  EX_FinalFunction = true,
  EX_CallMulticastDelegate = true,
}

local VIRTUAL_CALL =
{
  EX_LocalVirtualFunction = true,
  EX_VirtualFunction = true,
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
  return
  {
    address = scriptAddress,
    size = scriptSize,
    cursor = 0,
    instructionCount = 0,
    elements = {},
    errors = {},
    stopped = false,
    describePointer = options and options.describePointer,
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

--- Decode one recursive Kismet expression
-- unknown operations stop at their opcode so the remaining bytes can be rendered raw without inventing operand boundaries
-- @param context table @ decoder context
-- @param depth number|nil @ nesting level
-- @return string|nil @ canonical operation name
function Module.Decoder.decodeExpression(context, depth)
  depth = depth or 0

  if context.stopped or context.cursor >= context.size then return nil end
  if depth > MAX_EXPRESSION_DEPTH then Module.Decoder.fail( context, 'expression nesting limit exceeded' ); return nil end

  context.instructionCount = context.instructionCount + 1
  if context.instructionCount > MAX_INSTRUCTION_COUNT then Module.Decoder.fail( context, 'instruction limit exceeded' ); return nil end

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

  local nestedDepth = depth + 1
  local decodeExpression = Module.Decoder.decodeExpression
  local consume = Module.Decoder.consume
  local consumePointer = Module.Decoder.consumePointer

  if PROPERTY_OPERAND[operation] then
    consumePointer( context, 'Property*', nestedDepth )

  elseif operation == 'EX_Cast' then
    consume( context, 1, 'byte', 'Conversion type', nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif INTERFACE_CAST[operation] then
    consumePointer( context, 'Class*', nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_Let' then
    consumePointer( context, 'Property*', nestedDepth )
    decodeExpression( context, nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif TWO_EXPRESSION_LET[operation] then
    decodeExpression( context, nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_LetValueOnPersistentFrame' then
    consumePointer( context, 'Property*', nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_StructMemberContext' then
    consumePointer( context, 'Member property*', nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_Jump' or operation == 'EX_PushExecutionFlow' or operation == 'EX_SkipOffsetConst' then
    consume( context, 4, 'dword', 'Code offset', nestedDepth )

  elseif operation == 'EX_ComputedJump' or operation == 'EX_InterfaceContext' or operation == 'EX_PopExecutionFlowIfNot' then
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_NothingInt32' then
    consume( context, 4, 'dword', 'Value', nestedDepth )

  elseif operation == 'EX_Return' then
    decodeExpression( context, nestedDepth )

  elseif FINAL_CALL[operation] then
    consumePointer( context, 'Function*', nestedDepth )
    Module.Decoder.decodeUntil( context, 'EX_EndFunctionParms', nestedDepth )

  elseif VIRTUAL_CALL[operation] then
    Module.Decoder.consumeScriptName( context, 'Function name', nestedDepth )
    Module.Decoder.decodeUntil( context, 'EX_EndFunctionParms', nestedDepth )

  elseif operation == 'EX_BitFieldConst' then
    consumePointer( context, 'Property*', nestedDepth )
    consume( context, 1, 'byte', 'Field mask', nestedDepth )

  elseif operation == 'EX_ClassContext' or operation == 'EX_Context' or operation == 'EX_Context_FailSilent' then
    decodeExpression( context, nestedDepth )
    consume( context, 4, 'dword', 'Skip offset', nestedDepth )
    consumePointer( context, 'R-value property*', nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_AddMulticastDelegate' or operation == 'EX_RemoveMulticastDelegate' then
    decodeExpression( context, nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_ClearMulticastDelegate' then
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_IntConst' then consume( context, 4, 'dword', 'Value', nestedDepth )
  elseif operation == 'EX_Int64Const' or operation == 'EX_UInt64Const' then consume( context, 8, 'qword', 'Value', nestedDepth )
  elseif operation == 'EX_FloatConst' then consume( context, 4, 'float', 'Value', nestedDepth )
  elseif operation == 'EX_DoubleConst' then consume( context, 8, 'double', 'Value', nestedDepth )
  elseif operation == 'EX_ByteConst' or operation == 'EX_IntConstByte' then consume( context, 1, 'byte', 'Value', nestedDepth )

  elseif operation == 'EX_StringConst' then Module.Decoder.decodeString( context, false, nestedDepth )
  elseif operation == 'EX_UnicodeStringConst' then Module.Decoder.decodeString( context, true, nestedDepth )

  elseif operation == 'EX_TextConst' then
    local literalTypeOffset = consume( context, 1, 'byte', 'Text literal type', nestedDepth )
    local literalType = literalTypeOffset and readByte( context.address + literalTypeOffset )
    if literalType == 1 then
      decodeExpression( context, nestedDepth ); decodeExpression( context, nestedDepth ); decodeExpression( context, nestedDepth )
    elseif literalType == 2 or literalType == 3 then
      decodeExpression( context, nestedDepth )
    elseif literalType == 4 then
      consumePointer( context, 'String table*', nestedDepth ); decodeExpression( context, nestedDepth ); decodeExpression( context, nestedDepth )
    elseif literalType ~= 0 then
      Module.Decoder.fail( context, 'unknown text literal type ' .. tostring(literalType) )
    end

  elseif operation == 'EX_ObjectConst' then consumePointer( context, 'Object*', nestedDepth )
  elseif operation == 'EX_SoftObjectConst' or operation == 'EX_FieldPathConst' then decodeExpression( context, nestedDepth )
  elseif operation == 'EX_NameConst' or operation == 'EX_InstanceDelegate' then Module.Decoder.consumeScriptName( context, 'Name', nestedDepth )

  elseif operation == 'EX_RotationConst' then
    consume( context, 4, 'dword', 'Pitch', nestedDepth ); consume( context, 4, 'dword', 'Yaw', nestedDepth ); consume( context, 4, 'dword', 'Roll', nestedDepth )

  elseif operation == 'EX_VectorConst' or operation == 'EX_Vector3fConst' then
    consume( context, 4, 'float', 'X', nestedDepth ); consume( context, 4, 'float', 'Y', nestedDepth ); consume( context, 4, 'float', 'Z', nestedDepth )

  elseif operation == 'EX_TransformConst' then
    for _, label in ipairs({ 'Rotation.X', 'Rotation.Y', 'Rotation.Z', 'Rotation.W', 'Translation.X', 'Translation.Y', 'Translation.Z', 'Scale.X', 'Scale.Y', 'Scale.Z' }) do
      consume( context, 4, 'float', label, nestedDepth )
    end

  elseif operation == 'EX_StructConst' then
    consumePointer( context, 'ScriptStruct*', nestedDepth )
    consume( context, 4, 'dword', 'Serialized size', nestedDepth )
    Module.Decoder.decodeUntil( context, 'EX_EndStructConst', nestedDepth )

  elseif operation == 'EX_SetArray' then
    decodeExpression( context, nestedDepth )
    Module.Decoder.decodeUntil( context, 'EX_EndArray', nestedDepth )

  elseif operation == 'EX_SetSet' or operation == 'EX_SetMap' then
    decodeExpression( context, nestedDepth )
    consume( context, 4, 'dword', 'Element count', nestedDepth )
    Module.Decoder.decodeUntil( context, operation == 'EX_SetSet' and 'EX_EndSet' or 'EX_EndMap', nestedDepth )

  elseif operation == 'EX_ArrayConst' or operation == 'EX_SetConst' then
    consumePointer( context, 'Inner property*', nestedDepth )
    consume( context, 4, 'dword', 'Element count', nestedDepth )
    Module.Decoder.decodeUntil( context, operation == 'EX_ArrayConst' and 'EX_EndArrayConst' or 'EX_EndSetConst', nestedDepth )

  elseif operation == 'EX_MapConst' then
    consumePointer( context, 'Key property*', nestedDepth )
    consumePointer( context, 'Value property*', nestedDepth )
    consume( context, 4, 'dword', 'Pair count', nestedDepth )
    Module.Decoder.decodeUntil( context, 'EX_EndMapConst', nestedDepth )

  elseif operation == 'EX_MetaCast' or operation == 'EX_DynamicCast' then
    consumePointer( context, 'Class*', nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_JumpIfNot' then
    consume( context, 4, 'dword', 'Destination', nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_Assert' then
    consume( context, 2, 'word', 'Line', nestedDepth )
    consume( context, 1, 'byte', 'Debug mode', nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_Skip' then
    consume( context, 4, 'dword', 'Skip count', nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_BindDelegate' then
    Module.Decoder.consumeScriptName( context, 'Function name', nestedDepth )
    decodeExpression( context, nestedDepth )
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_SwitchValue' then
    local countOffset = consume( context, 2, 'word', 'Case count', nestedDepth )
    consume( context, 4, 'dword', 'End offset', nestedDepth )
    decodeExpression( context, nestedDepth )
    local caseCount = countOffset and readSmallInteger( context.address + countOffset ) or 0
    if caseCount > 0x1000 then Module.Decoder.fail( context, 'implausible switch case count' ); return operation end
    for caseIndex = 0, caseCount - 1 do
      decodeExpression( context, nestedDepth )
      consume( context, 4, 'dword', ('Case %d next offset'):format(caseIndex), nestedDepth )
      decodeExpression( context, nestedDepth )
    end
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_ArrayGetByRef' then
    decodeExpression( context, nestedDepth ); decodeExpression( context, nestedDepth )

  elseif operation == 'EX_AutoRtfmTransact' then
    consume( context, 4, 'dword', 'Transaction id', nestedDepth )
    consume( context, 4, 'dword', 'End offset', nestedDepth )
    Module.Decoder.decodeUntil( context, 'EX_AutoRtfmStopTransact', nestedDepth )

  elseif operation == 'EX_AutoRtfmStopTransact' then
    consume( context, 4, 'dword', 'Transaction id', nestedDepth )
    consume( context, 1, 'byte', 'Status', nestedDepth )

  elseif operation == 'EX_AutoRtfmAbortIfNot' then
    decodeExpression( context, nestedDepth )

  elseif operation == 'EX_InstrumentationEvent' then
    Module.Decoder.fail( context, 'instrumentation payload is version-dependent' )

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
