--[[
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
]]

local Module =
{
  ABI = 1,
  DEFAULT_FRAME_LOCALS_OFFSET = 0x20,
  BRIDGE_ATTACHMENT_NAME = 'ceUEDumper.ceUEDumperBridge.dll',
  State =
  {
    processId = 0,
    path = nil,
    exports = nil,
    extractionSerial = 0,
    extractedPath = nil,
  },
}

Module.Source =
{
  self = 0,
  locals = 1,
  params = 1,
  parameter = 1,
  result = 2
}

Module.ValueType =
{
  u8 = 1,
  bool = 1,
  u16 = 2,
  u32 = 3,
  u64 = 4,
  i8 = 5,
  i16 = 6,
  i32 = 7,
  i64 = 8,
  f32 = 9,
  float = 9,
  f64 = 10,
  double = 10,
  pointer = 11,
  object = 11,
}

Module.Operation =
{
  eq = 0,
  ['=='] = 0,

  ne = 1,
  ['~='] = 1,
  ['!='] = 1,

  lt = 2,
  ['<'] = 2,

  le = 3,
  ['<='] = 3,

  gt = 4,
  ['>'] = 4,

  ge = 5,
  ['>='] = 5,

  anyBits = 6,
  allBits = 7,
}
Module.Phase = { before = 0, after = 1 }

local EXPORT_NAMES =
{
  'ceue_bridge_version',
  'ceue_bridge_abi',
  'ceue_create_bp_hook',
  'ceue_set_frame_locals_offset',
  'ceue_add_condition',
  'ceue_add_write',
  'ceue_enable_bp_hook',
  'ceue_remove_bp_hook',
  'ceue_remove_all_bp_hooks',
  'ceue_get_hook_count',
  'ceue_get_last_error',
}

local function integerArgument(value)
  return { type = 0, value = value or 0 }
end

local function call(address, ...)
  local arguments = { ... }
  for index, value in ipairs(arguments) do arguments[index] = integerArgument(value) end
  return executeCodeEx( 0, 10000, address, table.unpack(arguments) )
end

local function resolveExport(name)
  local names =
  {
    'ceUEDumperBridge.' .. name,
    'ceUEDumperBridge.dll.' .. name,
    name,
  }

  for _, symbol in ipairs(names) do
    local address = getAddressSafe(symbol)
    if address then return address end
  end

  return nil
end

local function resolveExports()
  local exports = {}
  for _, name in ipairs(EXPORT_NAMES) do
    exports[name] = resolveExport(name)
    if not exports[name] then return nil, 'Bridge export was not resolved: ' .. name end
  end
  return exports
end

local function defaultBridgePath()
  return (getCheatEngineDir() or '') .. [[autorun\ceUEDumperModules\ceUEDumperBridge.dll]]
end

local function readableFile(path)
  local file = io.open( path, 'rb' )
  if not file then return false end
  file:close()
  return true
end

--- Remove a temp bridge dll
-- @param path string|nil @ extracted DLL path
-- @return boolean @ true when no retained temporary file remains
local function discardTemporaryBridge(path)
  if not path then return true end

  local removed = os.remove(path)
  if removed and Module.State.extractedPath == path then Module.State.extractedPath = nil end
  return removed == true
end

--- Find and validate optional bridge attachment on demand
-- @return table|userdata|nil @ TableFile, nil when no bridge is attached
-- @return string|nil @ validation error
local function findAttachedBridge()
  if type(findTableFile) ~= 'function' then return nil end

  local tableFile = findTableFile( Module.BRIDGE_ATTACHMENT_NAME )
  if not tableFile then return nil end

  local stream = tableFile.getData()
  if not stream then return nil, 'Attached ceUEDumper bridge could not be read' end

  stream.Position = 0
  local firstByte = stream.readByte()
  local secondByte = stream.readByte()
  stream.destroy()

  if firstByte ~= 0x4D or secondByte ~= 0x5A then return nil, 'Attached ceUEDumper bridge is not a PE image' end
  return tableFile
end

--- Save to temp and inject
-- @param tableFile table|userdata @ validated bridge attachment
-- @param processId number @ target PID included in the temporary name
-- @return string|nil @ temporary DLL path
-- @return string|nil @ filesystem error
local function extractAttachedBridge(tableFile, processId)
  local temporaryDirectory = os.getenv('TEMP') or os.getenv('TMP')
  if not temporaryDirectory or temporaryDirectory == '' then return nil, 'Win TEMP dir is unavailable' end

  Module.State.extractionSerial = Module.State.extractionSerial + 1

  local separator = temporaryDirectory:sub(-1) == '\\' and '' or '\\'
  local temporaryPath = temporaryDirectory .. separator .. ('ceUEDumperBridge-abi%d-%d-%d-%d.dll')
                                                           :format( Module.ABI, processId, os.time(), Module.State.extractionSerial )

  local stream = tableFile.getData()
  if not stream then return nil, 'Attached ceUEDumper bridge could not be read' end

  local saved, saveError = stream.saveToFileNoError(temporaryPath)
  stream.destroy()

  if not saved then return nil, 'Could not extract temporary bridge DLL: ' .. tostring(saveError) end

  return temporaryPath
end

--- Inject native per-target bridge, get exports
-- @param path string|nil @ DLL path
-- @return boolean|nil @ true on exports ready
-- @return string|nil @ error
function Module.load(path)
  local processId = getOpenedProcessID()
  if not processId or processId == 0 then return nil, 'No target process is open' end

  if Module.State.processId ~= processId then
    discardTemporaryBridge(Module.State.extractedPath)

    Module.State.processId = processId
    Module.State.path = nil
    Module.State.exports = nil
    Module.State.extractedPath = nil
  end

  if Module.State.exports then return true end

  local exports = resolveExports()
  local temporaryPath

  if not path and not exports then
    local attachedBridge, attachmentError = findAttachedBridge()
    if attachmentError then return nil, attachmentError end

    if attachedBridge then
      path, attachmentError = extractAttachedBridge( attachedBridge, processId )
      if not path then return nil, attachmentError end

      temporaryPath = path
      Module.State.extractedPath = path
    end
  end

  path = path or defaultBridgePath()

  if not exports then
    if not readableFile(path) then
      discardTemporaryBridge(temporaryPath)
      return nil, 'BP hook bridge is unavailable: no attached DLL and no readable file at ' .. tostring(path)
    end

    local callSucceeded, injectionResult = pcall( injectDLL, path )
    if not callSucceeded or injectionResult ~= true then
      discardTemporaryBridge(temporaryPath)
      return nil, 'Could not inject ceUEDumperBridge: ' .. tostring(injectionResult)
    end

    -- should reload
    -- if reinitializeSymbolhandler then pcall(reinitializeSymbolhandler) end
    exports = resolveExports()
  end

  if not exports then
    discardTemporaryBridge(temporaryPath)
    return nil, 'ceUEDumperBridge was injected, but its exports were not resolved'
  end

  local abi = call( exports.ceue_bridge_abi )
  if abi ~= Module.ABI then
    discardTemporaryBridge(temporaryPath)
    return nil, ('Hook bridge ABI mismatch: Lua expects %d, DLL provides %s'):format( Module.ABI, tostring(abi) )
  end

  Module.State.path = path
  Module.State.exports = exports

  -- loaded image may remain locked?
  discardTemporaryBridge(temporaryPath)
  return true
end

function Module.lastError()
  local exports = Module.State.exports
  if not exports then return 'Hook bridge is not loaded' end

  local capacity = 1024
  local buffer = allocateMemory(capacity)
  if not buffer then return 'Hook bridge reported an error' end

  call( exports.ceue_get_last_error, buffer, capacity )
  local message = readString( buffer, capacity, false )

  deAlloc(buffer)
  
  return message and message ~= '' and message or 'Hook bridge operation failed'
end

function Module.callExport( name, ... )
  local exports = Module.State.exports
  if not exports or not exports[name] then return nil, 'Hook bridge is not loaded' end
  return call( exports[name], ... )
end

function Module.create( functionAddress, functionPointerOffset, functionPointer, objectPointerAddress, skipOriginal )
  local handle, callError = Module.callExport(
                                                'ceue_create_bp_hook',
                                                functionAddress,
                                                functionPointerOffset,
                                                functionPointer,
                                                objectPointerAddress or 0,
                                                skipOriginal and 1 or 0
                                              )
  if not handle or handle == 0 then return nil, callError or Module.lastError() end
  return handle
end

function Module.setFrameLocalsOffset( handle, offset )
  local result, callError = Module.callExport( 'ceue_set_frame_locals_offset', handle, offset )
  if result ~= 1 then return nil, callError or Module.lastError() end
  return true
end

function Module.addCondition( handle, condition )
  local result, callError = Module.callExport(
                                                'ceue_add_condition',
                                                handle,
                                                condition.source,
                                                condition.valueType,
                                                condition.operation,
                                                condition.offset,
                                                condition.valueBits,
                                                condition.maskBits or 0
                                              )
  if result ~= 1 then return nil, callError or Module.lastError() end
  return true
end

function Module.addWrite( handle, write )
  local result, callError = Module.callExport(
                                                'ceue_add_write',
                                                handle,
                                                write.phase,
                                                write.source,
                                                write.valueType,
                                                write.offset,
                                                write.valueBits,
                                                write.maskBits or 0
                                              )
  if result ~= 1 then return nil, callError or Module.lastError() end
  return true
end

function Module.enable( handle, enabled )
  local result, callError = Module.callExport( 'ceue_enable_bp_hook', handle, enabled == false and 0 or 1 )
  if result ~= 1 then return nil, callError or Module.lastError() end
  return true
end

function Module.remove(handle)
  local result, callError = Module.callExport( 'ceue_remove_bp_hook', handle )
  if result ~= 1 then return nil, callError or Module.lastError() end
  return true
end

function Module.removeAll()
  return Module.callExport('ceue_remove_all_bp_hooks')
end

function Module.count()
  return Module.callExport('ceue_get_hook_count')
end

return Module
