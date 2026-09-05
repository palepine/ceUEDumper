--[[
  ceUEDumperModules — a Cheat Engine Unreal Engine Dumper — Copyright (C) 2026 palepine

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

--- Adapter for UE runtime scanner

local Module =
{
  Resources = {},
  Lifecycle = {},
  Objects = {},
  Reflection = {},
  Functions = {},
  Options = {},
}

local CHUNK_SIZE = 0x10000
local MAX_OBJECTS = 0x1000000
local PTR_SIZE = 0x8

-- incremental reflected-type index for current object-array layout
-- each GUObjectArray entry is decoded at most once between cache resets
local typeLookupState
local cachedObjectArrayView

local resources = package.loaded['ceUEDumper.ownedResources']

if not resources then
  resources = { customTypes = {}, symbols = {}, borrowedSymbols = {} }
  package.loaded['ceUEDumper.ownedResources'] = resources
end

resources.borrowedSymbols = resources.borrowedSymbols or {}
resources.options = resources.options or { showReflectionMetadata = false }

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// HELPERS

--- Load Core from the portable table attachment or installed module
-- @return table @ core interface
local function loadCore()
  local dependencies =
  {
    UESignatures = require('ceUEDumperModules.UESignatures'),
    ceUEDumperResources = resources,
    ceUEDumperRegisterSymbol = function(name, address)
      return Module.Resources.registerOwnedSymbol( name, address )
    end,
  }

  local attachmentName = 'ceUEDumper.UEDumperCore'
  local tableFile = type(findTableFile) == 'function' and findTableFile(attachmentName)
  local sourceText

  if tableFile then
    local stringStream = createStringStream()
    stringStream.Position = 0
    stringStream.copyFrom( tableFile.Stream, tableFile.Stream.Size )
    sourceText = stringStream.DataString
    stringStream.destroy()
  end

  local chunk, loadError

  if sourceText then
    chunk, loadError = load( sourceText, '@UED:' .. attachmentName, 't' )
  else
    local path = getCheatEngineDir() .. 'autorun\\ceUEDumperModules\\UEDumperCore.lua'
    chunk, loadError = loadfile( path, 't' )
  end

  assert( chunk, 'UEDumperCore not loaded: ' .. (loadError or 'unknown load error') )
  local implementation = chunk(dependencies)
  assert( type(implementation) == 'table', 'dumper core module returned no interface' )
  return implementation
end

--- Test if non-null
-- @param address any
-- @return boolean
local function isValidAddress(address)
  return type(address) == 'number' and address ~= 0
end

--- Count named fields in one enumeration result
-- @param properties table|nil @ property map returned by the core
-- @return number @ number of named properties
local function countProperties(properties)
  local count = 0
  for _ in pairs( properties or {} ) do
    count = count + 1
  end
  return count
end

local Core = loadCore()

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// RESOURCES

--- Check named CE custom type
-- @param name string @ custom type name
-- @return boolean @ current registration is ours
function Module.Resources.ownsCustomType(name)
  return resources.customTypes[name] ~= nil and getCustomType(name) == resources.customTypes[name]
end

--- Refuse replacement of symbol
-- @param name string @ requested symbol
-- @return boolean @ available or still owned
function Module.Resources.canRegisterSymbol(name)
  local current = getAddressSafe(name)
  return current == nil or (resources.symbols[name] ~= nil and resources.symbols[name] == current)
end

--- Register symbol
-- @param name string @ symbol name
-- @param address number|string @ address/offset or relocatable expression
-- @return nil
function Module.Resources.registerOwnedSymbol(name, address)
  local resolved = getAddressSafe(address)
  assert(resolved ~= nil, 'Cannot resolve symbol value: ' .. tostring(address))

  local current = getAddressSafe(name)

  if current ~= nil and resources.symbols[name] == nil then
    assert(current == resolved, 'Symbol is already owned by something: ' .. name)

    -- CE can restore saved/user-defined symbol while this Lua ownership ledger starts empty after a restart
    -- identical value is safe to reuse, but remains borrowed (cleanup never deletes another owner)
    resources.borrowedSymbols[name] = resolved
    return
  end

  assert( Module.Resources.canRegisterSymbol(name), 'Symbol is already owned by another tool: ' .. name )

  if resources.symbols[name] ~= nil then unregisterSymbol(name) end
  registerSymbol(name, address, true)
  resources.symbols[name] = resolved
  resources.borrowedSymbols[name] = nil
end

--- Remove symbol only while its registered value still matches ours
-- @param name string @ symbol to release
-- @return nil
function Module.Resources.unregisterOwnedSymbol(name)
  
  if resources.symbols[name] ~= nil and getAddressSafe(name) == resources.symbols[name] then
    unregisterSymbol(name)
  end

  resources.symbols[name] = nil
  resources.borrowedSymbols[name] = nil
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE LIFECYCLE

--- If runtime reflection data is ready
-- @return boolean @ true when fundamental defenitions are ready
function Module.Lifecycle.isReady()
  local definitions = Core.definitions()
  return type( definitions ) == 'table' and
        type( definitions.UObject ) == 'table' and
        type( definitions.UClass ) == 'table' and
        type( definitions.FProperty ) == 'table' and
        isValidAddress( definitions.ObjectArray ) and
        definitions.UObject.Class ~= nil and
        definitions.FProperty.Offset ~= nil
end

--- Start core service
function Module.Lifecycle.launch()
  Core.launch()
end

--- Configure signature selection for subsequent search
-- @param mode string @ first (default) or scored
function Module.Lifecycle.configureSignatures(mode)
  Core.configureSignatures(mode)
end

--- Wait for the core service
-- @param timeout number @ max wait in millis
-- @return boolean|nil @ underlying CE wait result
function Module.Lifecycle.wait(timeout)
  return Core.wait(timeout)
end

--- Get status for current/most recent run
-- @return table @ core status
function Module.Lifecycle.status()
  return Core.status()
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// GUOBJECTARRAY ACCESS

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// OBJECT HELPERS

--- Return whether an object's runtime class derives from a named metaclass
-- @param objectAddress number @ reflected UObject descriptor
-- @param ancestorName string @ required UClass name, for example Function
-- @return boolean @ true when the metaclass ancestry contains ancestorName
local function objectHasMetaClass(objectAddress, ancestorName)
  local definitions = Core.definitions()
  local classAddress = Module.Objects.objectClass(objectAddress)
  local visited = {}

  for _ = 1, 32 do

    if not isValidAddress(classAddress) or visited[classAddress] then return false end

    visited[classAddress] = true

    if Module.Objects.objectName(classAddress) == ancestorName then return true end

    local superOffset = definitions.UClass and definitions.UClass.SuperStruct
    if type(superOffset) ~= 'number' then return false end

    classAddress = readPointer( classAddress + superOffset )
  end

  return false
end

--- Return the current number of entries in GUObjectArray
-- @return number @ number of allocated object slots
function Module.Objects.objectCount()
  local view = Module.Objects.createObjectArrayView(true)
  return view and view.count or 0
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// OBJECT/TYPE LOOKUP

--- Capture GUObjectArray fields required by indexed traversal
-- @param refresh boolean|nil @ reread mutable count/storage fields
-- @return table|nil @ validated object-array traversal context
function Module.Objects.createObjectArrayView(refresh)
  local definitions = Core.definitions()
  if type(definitions) ~= 'table' then return nil end

  local objectArrayAddress = definitions.ObjectArray
  local itemSize = definitions.ObjectArrayEntryStructSize
  local chunked = definitions.ObjectArrayListType == 0

  if not isValidAddress( objectArrayAddress ) then return nil end
  if not definitions.UObject or not definitions.UClass then return nil end
  if type(itemSize) ~= 'number' or itemSize < PTR_SIZE then return nil end

  local reusable = cachedObjectArrayView and
                   cachedObjectArrayView.definitions == definitions and
                   cachedObjectArrayView.objectArrayAddress == objectArrayAddress and
                   cachedObjectArrayView.itemSize == itemSize and
                   cachedObjectArrayView.chunked == chunked

  if reusable and not refresh then return cachedObjectArrayView end

  local objectsAddress = readPointer( objectArrayAddress + 0x10 )
  local count = readInteger( objectArrayAddress + 0x24 )

  if not isValidAddress(objectsAddress) then return nil end
  if type(count) ~= 'number' or count < 0 or count > MAX_OBJECTS then return nil end

  if reusable and cachedObjectArrayView.objectsAddress == objectsAddress then
    cachedObjectArrayView.count = count
    return cachedObjectArrayView
  end

  cachedObjectArrayView =
  {
    definitions = definitions,
    objectArrayAddress = objectArrayAddress,
    objectsAddress = objectsAddress,
    itemSize = itemSize,
    count = count,
    chunked = chunked,
    cachedChunkIndex = nil,
    cachedChunkAddress = nil,
  }

  return cachedObjectArrayView
end

--- Resolve UObject pointer using existing object-array view
-- Sequential traversal caches current chunk for optimization
-- ie reducing reading from once-per-object to once-per-65536-object chunk
-- @param view table @ context returned by createObjectArrayView
-- @param index number @ zero-based GUObjectArray index
-- @return number|nil @ UObject pointer
function Module.Objects.objectAtFromView(view, index)
  if type(view) ~= 'table' or type(index) ~= 'number' or index < 0 or index >= view.count then return nil end

  local itemAddress

  if view.chunked then
    local chunkIndex = math.floor( index / CHUNK_SIZE )
    local chunkAddress = view.cachedChunkAddress

    if view.cachedChunkIndex ~= chunkIndex then
      chunkAddress = readPointer( view.objectsAddress + chunkIndex * PTR_SIZE )
      view.cachedChunkIndex = chunkIndex
      view.cachedChunkAddress = chunkAddress
    end

    if not isValidAddress(chunkAddress) then return nil end

    itemAddress = chunkAddress + ( index % CHUNK_SIZE ) * view.itemSize
  else
    itemAddress = view.objectsAddress + index * view.itemSize
  end

  return readPointer(itemAddress)
end

--- Resolve obj pointer from GUObjectArray index
-- @param index number @ zero-based index
-- @return number|nil @ UObject pointer, nil for invalid
function Module.Objects.objectAt(index)
  local view = Module.Objects.createObjectArrayView()
  if not view then return nil end

  return Module.Objects.objectAtFromView( view, index )
end

--- Return short reflected name of a UObject
-- @param address number @ UObject addr
-- @return string|nil @ reflected name
function Module.Objects.objectName(address)
  if not isValidAddress(address) then return nil end
  return Core.objectName(address)
end

--- Return runtime UClass of UObject instance
-- @param address number @ UObject inst addr
-- @return number|nil @ runtime UClass addr
function Module.Objects.objectClass(address)
  if not isValidAddress(address) or not Module.Lifecycle.isReady() then return nil end

  local definitions = Core.definitions()
  if not definitions.UObject or type( definitions.UObject.Class ) ~= 'number' then
    return nil
  end

  return readPointer( address + definitions.UObject.Class )
end

--- Reset incremental reflected-type lookup index
-- call after scanner may publish different runtime layout/process
function Module.Objects.clearTypeLookupCache()
  typeLookupState = nil
  cachedObjectArrayView = nil
end

--- Return identity for fields that invalidate cached object indexes
-- @param view table @ object-array view
-- @return string @ stable identity while traversal assumptions remain valid
local function objectArrayViewIdentity(view)
  local definitions = view.definitions
  local objectLayout = definitions.UObject or {}
  local classLayout = definitions.UClass or {}

  return table.concat(
    {
      view.objectArrayAddress,
      view.objectsAddress,
      view.itemSize,
      view.chunked and 1 or 0,
      objectLayout.Class or -1,
      objectLayout.Name or -1,
      classLayout.SuperStruct or -1,
    },
    ':'
  )
end

--- Get incremental type-index state for the current runtime
-- The count is refreshed cuz GUObjectArray may grow after init
-- without invalidating entries that have already been indexed
-- @return table|nil @ lookup state
local function getTypeLookupState()
  local view = Module.Objects.createObjectArrayView(true)
  if not view then return nil end

  local identity = objectArrayViewIdentity(view)

  if not typeLookupState or typeLookupState.identity ~= identity then
    typeLookupState =
    {
      identity = identity,
      view = view,
      nextIndex = 0,
      byKind =
      {
        Class = {},
        ScriptStruct = {},
      },
      any = {},
      metaClassKinds = {},
    }
  else
    typeLookupState.view.count = view.count
  end

  return typeLookupState
end

--- Classify metaclass of a possible reflected type descriptor
-- classification is cached by ClassPrivate address
-- Ordinary UObject instances sharing one class therefore pay ancestry check only once
-- @param metaClassAddress number @ candidate object's ClassPrivate pointer
-- @param state table @ incremental type-lookup state
-- @return string|nil @ Class or ScriptStruct
local function reflectedTypeKind(metaClassAddress, state)
  if not isValidAddress(metaClassAddress) then return nil end

  local cachedKind = state.metaClassKinds[metaClassAddress]
  if cachedKind ~= nil then return cachedKind or nil end

  local definitions = state.view.definitions
  local superOffset = definitions.UClass and definitions.UClass.SuperStruct
  local objectName = Core.objectName
  local currentAddress = metaClassAddress
  local visited = {}
  local kind

  if type(superOffset) == 'number' then

    for _ = 1, 32 do
      if not isValidAddress(currentAddress) or visited[currentAddress] then break end

      visited[currentAddress] = true
      local currentName = objectName(currentAddress)

      if currentName == 'Class' or currentName == 'ScriptStruct' then
        kind = currentName
        break
      end

      currentAddress = readPointer( currentAddress + superOffset )
    end

  end

  -- false distinguishes a cached negative classification from a cache miss
  state.metaClassKinds[metaClassAddress] = kind or false
  return kind
end

--- Add one reflected type to incremental index
-- First occurrence wins, preserving previous GUObjectArray traversal
-- behavior when duplicate short names exist
-- @param state table @ incremental lookup state
-- @param typeAddress number @ UClass or UScriptStruct descriptor
-- @param kind string @ Class or ScriptStruct
-- @return string|nil @ reflected short name
local function indexReflectedType(state, typeAddress, kind)
  local name = Core.objectName(typeAddress)
  if not name then return nil end

  local kindIndex = state.byKind[kind]
  if kindIndex[name] == nil then kindIndex[name] = typeAddress end
  if state.any[name] == nil then state.any[name] = typeAddress end

  return name
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// REFLECTED TYPE LOOKUP

--- Find reflected class or script struct by name
-- @param name string @ short reflected name, e.g. "Character"
-- @param kind string|nil @ Class/ScriptStruct. nil to accept either
-- @return number|nil @ addr of the reflected type
function Module.Objects.findType(name, kind)
  assert( type(name) == 'string' and name ~= '' , 'type name must be a non-empty string' )

  local state = getTypeLookupState()
  if not state then return nil end

  local supportedKind = kind == nil or kind == 'Class' or kind == 'ScriptStruct'
  local requestedIndex

  if kind == nil then         requestedIndex = state.any
  elseif supportedKind then   requestedIndex = state.byKind[kind]
  end

  if requestedIndex and requestedIndex[name] then return requestedIndex[name] end

  -- keep support for undocumented metaclass names (avoid complicating Class/ScriptStruct index used by public API)
  if not supportedKind then
    local objectAtFromView = Module.Objects.objectAtFromView
    local objectName = Core.objectName

    for index = 0, state.view.count - 1 do
      local objectAddress = objectAtFromView( state.view, index )

      if isValidAddress(objectAddress) and objectName(objectAddress) == name and objectHasMetaClass(objectAddress, kind) then
        return objectAddress
      end
    end

    return nil
  end

  local view = state.view
  local objectAtFromView = Module.Objects.objectAtFromView
  local classOffset = view.definitions.UObject.Class

  while state.nextIndex < view.count do
    local objectAddress = objectAtFromView(view, state.nextIndex)
    state.nextIndex = state.nextIndex + 1

    if not isValidAddress(objectAddress) then goto continue end

    local metaClassAddress = readPointer(objectAddress + classOffset)
    
    local detectedKind = reflectedTypeKind(metaClassAddress, state)
    if not detectedKind then goto continue end

    local indexedName = indexReflectedType(state, objectAddress, detectedKind)

    if indexedName == name and (kind == nil or kind == detectedKind) then
      return objectAddress
    end

    ::continue::
  end

  return requestedIndex and requestedIndex[name] or nil
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// UFUNCTION

--- Enumerate UFunction children declared directly by UClass/UStruct
-- UFunctions remain UObject/UField nodes even on engines whose properties
-- moved to FField, so they are reached through UStruct::Children
-- @param typeAddress number @ owning UClass or UStruct descriptor
-- @return table<string, number> @ function names mapped to UFunction addresses
function Module.Functions.functions(typeAddress)
  assert( isValidAddress(typeAddress), 'type address must be non-zero' )

  local definitions = Core.definitions()
  local superOffset = definitions.UClass and definitions.UClass.SuperStruct

  if type(superOffset) ~= 'number' then return {}, 'UStruct.SuperStruct is unavailable' end

  local childrenOffset = definitions.UStruct and definitions.UStruct.Children or superOffset + PTR_SIZE
  local nameOffset = definitions.UObject and definitions.UObject.Name

  if type(nameOffset) ~= 'number' then return {}, 'UObject.Name is unavailable' end

  local nextOffset = definitions.UField and definitions.UField.Next or nameOffset + PTR_SIZE * 2
  local functionAddress = readPointer( typeAddress + childrenOffset )
  local functionsByName = {}
  local visited = {}

  for _ = 1, 0x10000 do

    if not isValidAddress(functionAddress) or visited[functionAddress] then break end

    visited[functionAddress] = true

    if objectHasMetaClass( functionAddress, 'Function' ) then
      local functionName = Module.Objects.objectName(functionAddress)
      if functionName then functionsByName[functionName] = functionAddress end
    end

    functionAddress = readPointer( functionAddress + nextOffset )
  end

  return functionsByName
end

--- Find inherited UFunction for UObject instance
-- The concrete class is searched first so overrides take precedence, then
-- each reflected superclass is inspected up to the root
-- @param objectAddress number @ live UObject this pointer
-- @param functionName string @ short reflected UFunction name
-- @return number|nil @ UFunction descriptor
-- @return string|nil @ lookup error
function Module.Functions.functionForObject(objectAddress, functionName)
  assert( isValidAddress(objectAddress), 'object address must be non-zero' )
  assert( type(functionName) == 'string' and functionName ~= '', 'function name must be non-empty' )

  local definitions = Core.definitions()
  local superOffset = definitions.UClass and definitions.UClass.SuperStruct
  local classAddress = Module.Objects.objectClass(objectAddress)
  local visitedClasses = {}

  if type(superOffset) ~= 'number' then return nil, 'UStruct.SuperStruct is unavailable' end

  for _ = 1, 128 do
    if not isValidAddress(classAddress) or visitedClasses[classAddress] then break end

    visitedClasses[classAddress] = true

    local functions, enumerationError = Module.Functions.functions(classAddress)
    if not functions then return nil, enumerationError end
    if functions[functionName] then return functions[functionName] end

    classAddress = readPointer( classAddress + superOffset )
  end

  return nil, 'Unreal function was not found: ' .. functionName
end

--- Resolve the standalone UObject::ProcessEvent entry point
-- @return number|nil @ executable function address
-- @return string|nil @ signature error
function Module.Functions.processEvent()
  return Core.processEvent()
end

--- Decode stable UFunction member group & inherited UStruct script array
-- Candidate starts cover stock UE4/UE5 + shifted layouts
-- First candidate satisfying parameter bounds, return bounds and a readable thunk selected
-- Deterministic
-- @param functionAddress number @ UFunction UObject address
-- @return table|nil @ function, bytecode and parameter metadata
-- @return string|nil @ layout error
function Module.Functions.functionMetadata(functionAddress)

  if not isValidAddress(functionAddress) or not objectHasMetaClass( functionAddress, 'Function' ) then
    return nil, 'Address is not a UFunction'
  end

  local definitions = Core.definitions()
  local propertyLink = definitions.UClass and definitions.UClass.PropertyLink
  local expectedStart = type(propertyLink) == 'number' and propertyLink + (propertyLink >= 0x68 and 0x40 or 0x30) or nil

  local starts = { expectedStart, 0xB0, 0xB8, 0xA0, 0x98, 0x88, 0xC0, 0xC8 }
  local seen = {}
  local selected

  for _, functionFlagsOffset in ipairs(starts) do

    if type(functionFlagsOffset) == 'number' and not seen[ functionFlagsOffset ] then
      seen[ functionFlagsOffset ] = true

      for _, numParmsDelta in ipairs({ 4, 6, 8 }) do
        local functionFlags = readInteger( functionAddress + functionFlagsOffset )
        local numParms = readBytes( functionAddress + functionFlagsOffset + numParmsDelta, 1, false )
        local parmsSize = readSmallInteger( functionAddress + functionFlagsOffset + numParmsDelta + 2 )
        local returnValueOffset = readSmallInteger( functionAddress + functionFlagsOffset + numParmsDelta + 4 )
        local shiftedTail = numParmsDelta == 8
        local firstPropertyDelta = shiftedTail and 0x18 or 0x10
        local eventGraphDelta = shiftedTail and 0x20 or 0x18
        local eventGraphCallDelta = shiftedTail and 0x28 or 0x20
        local functionPointerDelta = shiftedTail and 0x30 or 0x28
        local rpcIdDelta = shiftedTail and 0x12 or numParmsDelta + 6
        local rpcResponseIdDelta = shiftedTail and 0x14 or numParmsDelta + 8
        local functionPointer = readPointer( functionAddress + functionFlagsOffset + functionPointerDelta )
        local returnIsValid = returnValueOffset == 0xFFFF or returnValueOffset <= parmsSize

        if functionFlags and functionFlags ~= 0 and numParms and numParms <= 0x80
          and parmsSize and parmsSize <= 0x8000 and returnValueOffset and returnIsValid
          and isValidAddress(functionPointer) and readByte(functionPointer) ~= nil
        then
          selected =
          {
            address = functionAddress,
            name = Module.Objects.objectName(functionAddress),
            functionFlagsOffset = functionFlagsOffset,
            functionFlags = functionFlags,
            numParmsOffset = functionFlagsOffset + numParmsDelta,
            parmsSizeOffset = functionFlagsOffset + numParmsDelta + 2,
            returnValueOffsetOffset = functionFlagsOffset + numParmsDelta + 4,
            rpcIdOffset = functionFlagsOffset + rpcIdDelta,
            rpcResponseIdOffset = functionFlagsOffset + rpcResponseIdDelta,
            firstPropertyToInitOffset = functionFlagsOffset + firstPropertyDelta,
            eventGraphFunctionOffset = functionFlagsOffset + eventGraphDelta,
            eventGraphCallOffsetOffset = functionFlagsOffset + eventGraphCallDelta,
            functionPointerOffset = functionFlagsOffset + functionPointerDelta,
            numParms = numParms,
            parmsSize = parmsSize,
            returnValueOffset = returnValueOffset,
            rpcId = readSmallInteger( functionAddress + functionFlagsOffset + rpcIdDelta ),
            rpcResponseId = readSmallInteger( functionAddress + functionFlagsOffset + rpcResponseIdDelta ),
            firstPropertyToInit = readPointer( functionAddress + functionFlagsOffset + firstPropertyDelta ),
            eventGraphFunction = readPointer( functionAddress + functionFlagsOffset + eventGraphDelta ),
            eventGraphCallOffset = readInteger( functionAddress + functionFlagsOffset + eventGraphCallDelta ),
            functionPointer = functionPointer,
            native = functionFlags & 0x00000400 ~= 0,
            blueprintCallable = functionFlags & 0x04000000 ~= 0,
            blueprintEvent = functionFlags & 0x08000000 ~= 0,
            blueprintPure = functionFlags & 0x10000000 ~= 0,
          }
          break
        end

      end

    end

    if selected then break end
  end

  if not selected then return nil, 'UFunction member layout was not recognized' end

  if type(propertyLink) == 'number' then
    selected.scriptOffset = propertyLink - 0x10
    selected.bytecode = readPointer( functionAddress + selected.scriptOffset )
    selected.bytecodeSize = readInteger( functionAddress + selected.scriptOffset + PTR_SIZE )
    selected.bytecodeCapacity = readInteger( functionAddress + selected.scriptOffset + PTR_SIZE + 4 )
  end

  selected.parameters = Module.Reflection.properties(functionAddress) or {}
  return selected
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// REFLECTION

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// REFLECTION LAYOUT ACCESS

--- Resolve cached runtime FName comparison index
-- @param name string @ reflected name text
-- @return number|nil @ index in the validated runtime name pool
function Module.Reflection.nameIndex(name)
  local definitions = Core.definitions()
  return definitions.NameToIndex and definitions.NameToIndex[name] or nil
end

--- Get found UObject header offsets without exposing mutable core state
-- @return table @ known header offsets only
function Module.Reflection.objectHeaderLayout()
  local definitions = Core.definitions()
  local result = { VTable = 0 }

  for name, offset in pairs(definitions.UObject or {}) do
    if type(offset) == 'number' then result[name] = offset end
  end

  if type(result.Name) == 'number' then result.Outer = result.Outer or result.Name + PTR_SIZE end
  result.ObjectFlags = result.ObjectFlags or 0x8
  result.InternalIndex = result.InternalIndex or 0xC
  
  return result
end

--- Get found UClass/UStruct metadata offsets without exposing core state
-- UObject header offsets are included because every UClass is also a UObject
-- @return table @ known UClass metadata offsets
function Module.Reflection.classHeaderLayout()
  local definitions = Core.definitions()
  local result = Module.Reflection.objectHeaderLayout()

  for name, offset in pairs( definitions.UClass or {} ) do
    if type(offset) == 'number' then result[name] = offset end
  end

  if type(result.SuperStruct) == 'number' and type(result.Children) ~= 'number' then
    result.Children = result.SuperStruct + PTR_SIZE
  end

  if type(result.PropertyLink) == 'number' then
    result.Script = result.Script or result.PropertyLink - 0x10
    result.PropertiesSize = result.PropertiesSize or result.Children + PTR_SIZE * 2
    result.MinAlignment = result.MinAlignment or result.PropertiesSize + 4
  end

  return result
end

--- Get found UProperty/FProperty metadata offsets without exposing core state
-- @return table @ known property-descriptor offsets
function Module.Reflection.propertyHeaderLayout()
  local definitions = Core.definitions()
  local result = {}

  for name, offset in pairs( definitions.FProperty or {} ) do
    if type(offset) == 'number' then result[name] = offset end
  end

  if definitions.FField and type( definitions.FField.PropertyLinkNext ) == 'number' then
    result.PropertyLinkNextAlt = definitions.FField.PropertyLinkNext
  end

  return result
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// PROPERTY ENUMERATION

--- Add EPropertyFlags used to identify UFunction parameters
-- Return PropertyFlags preceding Offset_Internal by 0xC in supported UProperty and FProperty layouts
-- A found explicit offset takes precedence
-- @param property table @ decoded property metadata
-- @return table @ the same enriched metadata table
local function addPropertyFlags(property)
  if not property or not isValidAddress(property.propertyAddress) then return property end

  local definitions = Core.definitions()
  local propertyLayout = definitions.FProperty or {}
  local flagsOffset = propertyLayout.PropertyFlags

  if type(flagsOffset) ~= 'number' and type(propertyLayout.Offset) == 'number' then
    flagsOffset = propertyLayout.Offset - 0xC
  end

  if type(flagsOffset) ~= 'number' then return property end

  property.propertyFlags = readQword( property.propertyAddress + flagsOffset )
  local flags = property.propertyFlags or 0
  property.isParameter = flags & 0x80 ~= 0
  property.isOutParameter = flags & 0x100 ~= 0
  property.isReturnParameter = flags & 0x400 ~= 0
  property.isReferenceParameter = flags & 0x08000000 ~= 0
  property.isConstParameter = flags & 0x2 ~= 0
  property.isPlainOldData = flags & 0x40000000 ~= 0

  return property
end

--- Enumerate reflected properties, including inherited
-- @param typeAddress number @ UClass/UScriptStruct addr
-- @return table<string, table>|nil @ map containing offset, type, size, addr
-- @return string|nil @ error
function Module.Reflection.properties(typeAddress)
  assert( isValidAddress(typeAddress) , 'type address must be non-zero' )

  -- PropertyLink and ChildProperties can coexist, but one may be empty or incomplete for a particular engine layout
  -- enumerate both explicitly
  local propertyLinkProperties, propertyLinkError = Core.classProperties( typeAddress, false )
  local childProperties, childPropertiesError = Core.classProperties( typeAddress, true )

  local propertyLinkCount = countProperties(propertyLinkProperties)
  local childPropertyCount = countProperties(childProperties)

  if propertyLinkCount == 0 and childPropertyCount == 0 then
    local probed, err = Core.probeClassProperties(typeAddress)

    if countProperties(probed) > 0 then

      for _, property in pairs(probed) do
        addPropertyFlags(property)

        if property.propertyType == 'StructProperty' then
          property.structAddress, property.structError = Module.Reflection.propertyStruct( property.propertyAddress )
          goto continue
        end

        if property.propertyType == 'ArrayProperty' then
          property.innerProperty, property.innerError = Module.Reflection.propertyArrayInner( property.propertyAddress )
        end

        ::continue::
      end

      return probed
    end

    return nil, ('Reflected properties not found '
                .. '(PropertyLink: %s; ChildProperties: %s; probes: %s)')
                    :format( propertyLinkError or 'readable but empty', childPropertiesError or 'readable but empty', err or 'no probe' )
  end

  -- ChildProperties contains declarations; PropertyLink may supply additional
  -- inherited fields. Preserve their union, preferring declaration metadata
  local merged = {}

  for name, property in pairs(propertyLinkProperties or {}) do merged[name] = property end
  for name, property in pairs(childProperties or {}) do merged[name] = property end

  for _, property in pairs(merged) do
    addPropertyFlags(property)

    if property.propertyType == 'StructProperty' then
      property.structAddress, property.structError = Module.Reflection.propertyStruct( property.propertyAddress )
      goto continue
    end

    if property.propertyType == 'ArrayProperty' then
      property.innerProperty, property.innerError = Module.Reflection.propertyArrayInner( property.propertyAddress )
    end

    ::continue::
  end

  return merged
end

--- Resolve UScriptStruct referenced by a struct-property descriptor
-- Candidate slots accommodate legacy/modern FProperty sizes. Accept only a
-- unique ScriptStruct-typed target; never interpret inline data as a UObject
-- @param propertyAddress number @ FStructProperty/UStructProperty descriptor
-- @return number|nil @ referenced UScriptStruct
-- @return string|nil @ missing or ambiguous metadata
function Module.Reflection.propertyStruct(propertyAddress)
  local definitions = Core.definitions()
  local configured = definitions.FStructProperty and definitions.FStructProperty.Struct
  local candidates = {}
  local selected
  local firstOffset, lastOffset = 0x60, 0xB0

  if type(configured) == 'number' then firstOffset, lastOffset = configured, configured end

  for offset = firstOffset, lastOffset, 8 do
    local address = readPointer( propertyAddress + offset )

    if isValidAddress(address) and not candidates[address] then
      candidates[address] = true

      local metaClass = Module.Objects.objectClass(address)
      local visited = {}
      -- Blueprint-defined structs use a ScriptStruct-derived metaclass
      
      for depth = 1, 32 do

        if not isValidAddress(metaClass) or visited[metaClass] then break end

        visited[metaClass] = true

        if Module.Objects.objectName(metaClass) == 'ScriptStruct' then

          if selected and selected ~= address then return nil, 'Ambiguous struct type metadata' end
          selected = address
          break
        end

        local superOffset = definitions.UClass and definitions.UClass.SuperStruct

        if type(superOffset) ~= 'number' then break end

        metaClass = readPointer( metaClass + superOffset )
      end

    end

  end

  if not selected then return nil, 'Referenced UScriptStruct was not resolved' end
  
  return selected
end

--- Resolve and decode FArrayProperty::Inner
-- The inner descriptor is another FProperty/FField whose ElementSize is the
-- array stride. Candidate slots cover legacy UProperty and modern FProperty
-- layouts; the first structurally valid zero-offset property is selected
-- @param propertyAddress number @ FArrayProperty/UArrayProperty descriptor
-- @return table|nil @ decoded inner property metadata
-- @return string|nil @ missing metadata error
function Module.Reflection.propertyArrayInner(propertyAddress)
  local definitions = Core.definitions()
  local configuredOffset = definitions.FArrayProperty and definitions.FArrayProperty.Inner
  local candidateOffsets = {}

  if type(configuredOffset) == 'number' then
    candidateOffsets[1] = configuredOffset
  else
    -- Most UE4/UE5 layouts place Inner at 0x70 or 0x78. The remaining
    -- aligned slots retain compatibility with shifted/custom FProperty sizes
    candidateOffsets = { 0x70, 0x78, 0x80, 0x68, 0x88, 0x90, 0x98, 0xA0, 0xA8, 0xB0, 0x60 }
  end

  local propertyLayout = definitions.FProperty or {}
  local excludedPointers = {}
  local linkOffsets = {}

  if type(propertyLayout.PropertyLinkNext) == 'number' then
    linkOffsets[#linkOffsets + 1] = propertyLayout.PropertyLinkNext
  end

  if definitions.FField and type(definitions.FField.PropertyLinkNext) == 'number' then
    linkOffsets[#linkOffsets + 1] = definitions.FField.PropertyLinkNext
  end

  for _, nextOffset in ipairs(linkOffsets) do

    if type(nextOffset) == 'number' then
      local linkedProperty = readPointer( propertyAddress + nextOffset )
      
      if linkedProperty then excludedPointers[linkedProperty] = true end
    end

  end

  for _, memberOffset in ipairs(candidateOffsets) do
    local innerAddress = readPointer( propertyAddress + memberOffset )

    if isValidAddress(innerAddress) and not excludedPointers[innerAddress] then
      local innerName, innerProperty = Core.propertyMetadata(innerAddress)

      if innerProperty
          and type(innerProperty.propertyType) == 'string'
          and innerProperty.propertyType:sub(-8) == 'Property'
          and innerProperty.offset == 0
          and type(innerProperty.size) == 'number'
          and innerProperty.size > 0
          and innerProperty.size <= 0x100000
      then
        innerProperty.name = innerName
        innerProperty.innerAddress = innerAddress
        innerProperty.innerOffset = memberOffset

        if innerProperty.propertyType == 'StructProperty' then
          innerProperty.structAddress, innerProperty.structError = Module.Reflection.propertyStruct(innerAddress)
        end

        return innerProperty
      end
    end
  end

  return nil, 'FArrayProperty.Inner was not resolved'
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// BACKEND SETTINGS

--- If structure views should expand reflection descriptor internals
-- @return boolean @ current exploration option
function Module.Options.showsReflectionMetadata()
  return resources.options.showReflectionMetadata == true
end

--- Configure reflection descriptor expansion for newly generated structures
-- @param enabled boolean @ show UClass property chains when true
function Module.Options.setReflectionMetadataVisible(enabled)
  resources.options.showReflectionMetadata = enabled == true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// EXPORT

Module.ownsCustomType = Module.Resources.ownsCustomType
Module.canRegisterSymbol = Module.Resources.canRegisterSymbol
Module.registerOwnedSymbol = Module.Resources.registerOwnedSymbol
Module.unregisterOwnedSymbol = Module.Resources.unregisterOwnedSymbol

Module.isReady = Module.Lifecycle.isReady
Module.launch = Module.Lifecycle.launch
Module.configureSignatures = Module.Lifecycle.configureSignatures
Module.wait = Module.Lifecycle.wait
Module.status = Module.Lifecycle.status

Module.objectCount = Module.Objects.objectCount
Module.objectAt = Module.Objects.objectAt
Module.objectName = Module.Objects.objectName
Module.objectClass = Module.Objects.objectClass
Module.findType = Module.Objects.findType
Module.clearTypeLookupCache = Module.Objects.clearTypeLookupCache

Module.functions = Module.Functions.functions
Module.functionForObject = Module.Functions.functionForObject
Module.processEvent = Module.Functions.processEvent
Module.functionMetadata = Module.Functions.functionMetadata

Module.nameIndex = Module.Reflection.nameIndex
Module.objectHeaderLayout = Module.Reflection.objectHeaderLayout
Module.classHeaderLayout = Module.Reflection.classHeaderLayout
Module.propertyHeaderLayout = Module.Reflection.propertyHeaderLayout
Module.properties = Module.Reflection.properties
Module.propertyStruct = Module.Reflection.propertyStruct
Module.propertyArrayInner = Module.Reflection.propertyArrayInner

Module.showsReflectionMetadata = Module.Options.showsReflectionMetadata
Module.setReflectionMetadataVisible = Module.Options.setReflectionMetadataVisible

return Module
