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

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// GLOBALS CONSTANTS

-- TODO: name all magic numbers across the project
-- TODO: search for properties by name
-- TODO: search for objects by fname
-- TODO: fname/object descryption
-- TODO: more option for limiting

local Dumper =
{
  Runtime = {},
  Portable = {},
  Helpers = {},
  Lifecycle = {},
  Reflection = {},
  Objects = {},
  References = {},
  Structures = {},
  MetadataViews = {},
  Bytecode = {},
  Patching = {},
  Offsets = {},
  Functions = {},
  Invocation = {},
  Dumps = {},
  StructureDissect = {},
  API = {},
  State = {},
}

local CEVersionSupported = 7.7

local PTR_SIZE = 0x8 -- targetIs64Bit() and 0x8 or 0x4 -- 32 bit unsupported, hardly any 32 app I've seen across UE4/5

local INIT_WAIT_TIME = 30000
local ceDirectory = getCheatEngineDir() or ''

-- { ["objName.property"] = true }
Dumper.State.registeredSymbols = {}
local registeredSymbols = Dumper.State.registeredSymbols

-- caches resolved UE type addresses
-- ["class:GameEngine"] = 0xBABE
-- ["struct:Vector"]    = 0xCAFE
-- ["*:Player"]         = 0xDEAD
Dumper.State.typeCache = {}
Dumper.State.classMetadataStructure = nil
Dumper.State.propertyMetadataStructure = nil
Dumper.State.classReferenceIndex = nil
Dumper.State.cacheProcessId = getOpenedProcessID()
local typeCache = Dumper.State.typeCache

local PORTABLE_FILES =
{
  { name = 'ceUEDumper',                  path = [[autorun\UEDumper.lua]] },
  { name = 'ceUEDumper.UEBackend',    path = [[autorun\ceUEDumperModules\UEBackend.lua]] },
  { name = 'ceUEDumper.UEBytecode',   path = [[autorun\ceUEDumperModules\UEBytecode.lua]] },
  { name = 'ceUEDumper.UEDumperCore', path = [[autorun\ceUEDumperModules\UEDumperCore.lua]] },
  { name = 'ceUEDumper.UESignatures', path = [[autorun\ceUEDumperModules\UESignatures.lua]] },
}

--- Execute operation on CE main thread
-- @param callback function @ operation with GUI/global-object affinity
-- @param ... any @ callback arguments
-- @return ... @ callback return values
function Dumper.Runtime.onMainThread(callback, ...)
  if inMainThread() then return callback(...) end
  return synchronize( callback, ... )
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// PORTABLE MODULES

-- very cool registerStructureDissectOverride2 stuff
if getCEVersion() < CEVersionSupported then
  Dumper.Runtime.onMainThread( ShowMessage, 'Please update CE to ' .. CEVersionSupported .. ' or newer' )
  error( 'update to Cheat Engine ' .. CEVersionSupported )
end

--- Reads a lua script attached to the cheat table as a file
-- @param fileName string
-- @return string|nil @ Source text when an attachment exists
function Dumper.Portable.getScriptFileAttached(fileName)
  if not inMainThread() then return Dumper.Runtime.onMainThread( Dumper.Portable.getScriptFileAttached, fileName ) end

  local tableFile = findTableFile(fileName)
  if tableFile == nil then return nil end -- error('attached file not found')
  local stringStream = createStringStream()
  stringStream.Position = 0
  stringStream.copyFrom(tableFile.Stream, tableFile.Stream.Size)
  local newScript = stringStream.DataString
  stringStream.destroy()

  return newScript
end

--- Defines installers for modules to be installed
-- @param moduleName string @ Lua module name passed to require
-- @param fileName string @ installed source filename
-- @param attachmentName string @ collision-resistant table-file name
function Dumper.Portable.registerModuleResolver(moduleName, fileName, attachmentName)
  package.preload[moduleName] = function()
    -- from the attached files
    local sourceText = Dumper.Portable.getScriptFileAttached(attachmentName)

    if sourceText then
      local chunk, parseError = load( sourceText )
      if not chunk then error(parseError) end
      return chunk()
    end

    -- from the path
    local installedPath = ceDirectory .. [[autorun\ceUEDumperModules\]] .. fileName
    local chunk, loadError = loadfile(installedPath)

    if not chunk then
      error( 'Unable to load ' .. moduleName, 2 ) -- caller
    end

    return chunk()
  end
end


--- Read every portable runtime file before modifying the current table
-- Preloading makes a missing or unreadable installation fail without
-- deleting an older usable attachment from the cheat table
-- @return table[]|nil @ attachment descriptors containing source text
-- @return string|nil @ error
function Dumper.Portable.readPortableFiles()
  local files = {}

  for _, descriptor in ipairs(PORTABLE_FILES) do
    local sourcePath = ceDirectory .. descriptor.path
    local sourceFile, openError = io.open(sourcePath, 'rb')

    if not sourceFile then return nil, 'Could not read portable dependency ' .. sourcePath .. ': ' .. tostring(openError) end

    local sourceText = sourceFile:read('*a')
    sourceFile:close()

    if not sourceText or sourceText == '' then return nil, 'Portable dependency is empty: ' .. sourcePath end

    files[#files + 1] =
    {
      name = descriptor.name,
      source = sourceText,
    }
  end

  return files
end

--- Replace one attached table file with validated source text
-- @param attachmentName string @ flat name stored in the cheat table
-- @param sourceText string @ complete Lua source
-- @return nil
function Dumper.Portable.replaceTableFile(attachmentName, sourceText)
  if not inMainThread() then return Dumper.Runtime.onMainThread( Dumper.Portable.replaceTableFile, attachmentName, sourceText ) end

  local existingFile = findTableFile(attachmentName)
  if existingFile then existingFile.delete() end

  local tableFile = assert( createTableFile(attachmentName), 'Could not create table file ' .. attachmentName )
  local sourceStream = createStringStream(sourceText)
  tableFile.Stream.Position = 0
  tableFile.Stream.CopyFrom(sourceStream, 0)
  sourceStream.destroy()
end

--- Attach / update the complete ceUEDumper runtime in the current table
-- @return boolean|nil @ true when every runtime file was attached
-- @return string|nil @ error
function Dumper.Portable.ue_attachToTable()
  if not inMainThread() then return Dumper.Runtime.onMainThread(Dumper.Portable.ue_attachToTable) end

  local files, readError = Dumper.Portable.readPortableFiles()
  if not files then return nil, readError end

  local attached, attachError = pcall(
    function()
      Dumper.Runtime.onMainThread(function()
        for _, file in ipairs(files) do
          Dumper.Portable.replaceTableFile( file.name, file.source )
        end
      end)
    end
  )

  if not attached then return nil, 'Could not attach ceUEDumper: ' .. tostring(attachError) end

  return true
end


Dumper.Portable.registerModuleResolver( 'ceUEDumperModules.UEBackend', 'UEBackend.lua', 'ceUEDumper.UEBackend' )
Dumper.Portable.registerModuleResolver( 'ceUEDumperModules.UEBytecode', 'UEBytecode.lua', 'ceUEDumper.UEBytecode' )
Dumper.Portable.registerModuleResolver( 'ceUEDumperModules.UESignatures', 'UESignatures.lua', 'ceUEDumper.UESignatures' )

local Backend = require('ceUEDumperModules.UEBackend')
local Bytecode = require('ceUEDumperModules.UEBytecode')
local sharedResources = package.loaded['ceUEDumper.resources']

sharedResources.structureDissectCallbacks = sharedResources.structureDissectCallbacks or {}
sharedResources.functionPatches = sharedResources.functionPatches or
{
  processId = getOpenedProcessID(),
  nextId = 1,
  active = {},
}

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// DUMPER CODE

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// HELPERS

--- Resolve and cache a reflected type address
-- @param typeNameOrAddress string|number @ reflected name or address
-- @param kind string|nil @ expected reflected metaclass name
-- @return number|nil @ reflected type address
function Dumper.Helpers.resolveType(typeNameOrAddress, kind)
  if type(typeNameOrAddress) == 'number' then return typeNameOrAddress end
  assert( type(typeNameOrAddress) == 'string', 'type must be a name or address' )

  local processId = getOpenedProcessID()

  if Dumper.State.cacheProcessId ~= processId then
    Dumper.State.cacheProcessId = processId
    Dumper.State.typeCache = {}
    typeCache = Dumper.State.typeCache
    Dumper.State.classMetadataStructure = nil
    Dumper.State.propertyMetadataStructure = nil
    Dumper.State.classReferenceIndex = nil
    Backend.clearTypeLookupCache()
  end

  local cacheKey = (kind or '*') .. ':' .. typeNameOrAddress
  if not typeCache[cacheKey] then
    typeCache[cacheKey] = Backend.findType(typeNameOrAddress, kind)
  end

  return typeCache[cacheKey]
end

--- Strip only a trailing Blueprint member ordinal and 32-digit GUID per segment
-- Ordinary underscores, numeric suffixes and short hexadecimal names are retained
-- @param path string @ raw member name or dotted path
-- @return string @ readable alias; raw metadata is never modified
function Dumper.Helpers.cleanPropertyPath(path)

  return (path:gsub('[^.]+',

              function(segment)
                local base, guid = segment:match('^(.+)_%d+_(%x+)$')
                if base and #guid == 32 then return base end
                return segment
              end
            )
          )
end

--- Resolve an exact generated name or an unambiguous readable alias
-- @param properties table @ raw-name-keyed metadata
-- @param requested string @ raw name/path or readable alias
-- @return table|nil @ matching property
-- @return string|nil @ missing or ambiguous alias error
function Dumper.Helpers.resolveProperty(properties, requested)
  local cleanPropertyPath = Dumper.Helpers.cleanPropertyPath

  if properties[requested] and cleanPropertyPath(requested) ~= requested then
    return properties[requested]
  end

  local selected

  for rawName, property in pairs(properties) do
    local alias = property.displayPath or cleanPropertyPath(rawName)

    if rawName == requested or alias == requested then

      if selected then
        return nil, 'Ambiguous property alias: ' .. requested .. '; use the raw generated name'
      end
      selected = property
    end

  end

  if not selected then return nil, 'Property was not found: ' .. requested end
  return selected
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// OFFSET SYMBOL HELPERS

--- Register selected fields from existing property map
-- @param properties table<string, table> @ reflected property metadata
-- @param objectName string @ type component used in symbol names
-- @param propertyNames string[]|nil @ selected names, nil for every field
-- @param namespace string @ optional namespace
-- @return table<string, number>|nil @ registered symbol-to-offset map
-- @return string|nil @ error
function Dumper.Offsets.registerProperties(properties, objectName, propertyNames, namespace)
  assert( propertyNames == nil or type(propertyNames) == 'table' , 'property names must be an array or nil' )
  
  local cleanPropertyPath = Dumper.Helpers.cleanPropertyPath
  local resolveProperty = Dumper.Helpers.resolveProperty
  namespace = (namespace and namespace ~= '' and namespace .. '.') or ''

  local selected = {}

  if propertyNames == nil then

    for propertyName in pairs(properties) do
      selected[#selected + 1] = properties[propertyName].displayPath or cleanPropertyPath(propertyName)
    end
    table.sort(selected)

  else

    for _, propertyName in ipairs(propertyNames) do
      selected[#selected + 1] = propertyName
    end

  end

  local result = {}

  for _, propertyName in ipairs(selected) do

    local property, lookupError = resolveProperty(properties, propertyName)

    if not property then
      return nil, lookupError
    end

    local name = namespace .. objectName .. '.' .. propertyName
    result[name] = property.offset

  end

  for name, offset in pairs(result) do
    Backend.registerSymbol(name, offset)
    registeredSymbols[name] = true
  end

  return result
end

--- Resolve one direct or embedded-struct property offset
-- @param typeNameOrAddress string|number @ reflected class/struct name or descriptor address
-- @param propertyName string @ reflected property name or dotted inline-struct path
-- @return number|nil @ offset to the property
-- @return string|nil @ error
function Dumper.Offsets.ue_getPropertyOffset(typeNameOrAddress, propertyName)
  assert( type(propertyName) == 'string' and propertyName ~= '' ,  'property name must be a non-empty string' )
  local enumProperties = Dumper.Reflection.ue_enumProperties
  local resolveProperty = Dumper.Helpers.resolveProperty

  local typeAddress = Dumper.Helpers.resolveType(typeNameOrAddress)
  if not typeAddress then return nil, 'Type not found' end

  local segments = {}

  for segment in propertyName:gmatch('[^.]+') do segments[#segments + 1] = segment end
  if #segments == 0 or #segments > 32 then return nil, 'Invalid or excessively deep property path' end

  local offset = 0

  for index, name in ipairs(segments) do

    local properties, errorMessage = enumProperties(typeAddress)
    if not properties then return nil, errorMessage end

    local property, lookupError = resolveProperty( properties, name )
    if not property then return nil, lookupError end

    offset = offset + property.offset

    if index < #segments then

      if property.propertyType ~= 'StructProperty' then
        return nil, 'Static offset paths can only cross embedded structs; use ue_resolveObjectPropertyPath for object pointers'
      end

      if not property.structAddress then return nil, property.structError or 'Struct type unavailable' end

      typeAddress = property.structAddress
    end

  end

  return offset
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// OBJECT OFFSET AND PATH QUERIES

--- Resolve a direct or embedded-struct property offset using a UObject addr
-- @param objectAddress number @ UObject instance addr
-- @param propertyName string @ reflected property name or dotted inline-struct path
-- @return number|nil @ field offset
-- @return string|nil error
function Dumper.Offsets.ue_getObjectPropertyOffset(objectAddress, propertyName)
  assert( type(propertyName) == 'string' and propertyName ~= '' , 'property name must be a non-empty string' )

  local typeAddress = Backend.objectClass(objectAddress)

  if not typeAddress or typeAddress == 0 then return nil, 'Runtime UObject class unavailable' end

  return Dumper.Offsets.ue_getPropertyOffset( typeAddress, propertyName )
end

--- Resolve property path across direct UObject ptrs and inline structs
-- @param rootObject number @ root UObject addr
-- @param propertyPath string|string[] @ dot-separated path or segment array
-- @return table|nil @ result with steps, final object and field address
-- @return string|nil @ error
function Dumper.Offsets.ue_resolveObjectPropertyPath(rootObject, propertyPath)
  assert( type(rootObject) == 'number' and rootObject ~= 0 , 'root object address must be non-zero' )
  local enumProperties = Dumper.Reflection.ue_enumProperties
  local resolveProperty = Dumper.Helpers.resolveProperty
  
  -- build segments
  local segments = {} -- TODO: a separate function?
  if type(propertyPath) == 'string' then

    -- split the path with dot-separator and store: a.b.c to a b c
    for segment in propertyPath:gmatch('[^.]+') do
      segments[#segments + 1] = segment
    end

  elseif type(propertyPath) == 'table' then

    for _, segment in ipairs(propertyPath) do
      segments[#segments + 1] = segment
    end

  else
    error('property path must be a dot-separated string or segment array', 2)
  end

  assert( #segments > 0 , 'property path must contain at least one segment' )


  local currentObject = rootObject
  local currentType = Backend.objectClass(rootObject)
  local result = { rootObject = rootObject, steps = {} }

  -- for each segment, collect property info
  for index, propertyName in ipairs(segments) do

    assert( type(propertyName) == 'string' and propertyName ~= '' , 'property path segments must be non-empty strings' )

    -- get UClass
    local classAddress = currentType

    if not classAddress then return nil, ('Failed to read runtime class before path segment %s') :format(propertyName) end

    -- reflected properties
    local properties, errorMessage = enumProperties(classAddress)
    if not properties then return nil, errorMessage end

    local property, lookupError = resolveProperty( properties, propertyName )
    
    if not property then return nil, lookupError end

    -- next in the path
    local fieldAddress = currentObject + property.offset

    result.steps[#result.steps + 1] =
    {
      name = propertyName,
      offset = property.offset,
      propertyType = property.propertyType,
      propertyAddress = property.propertyAddress,
      classAddress = classAddress,
      objectAddress = currentObject,
      fieldAddress = fieldAddress,
    }

    if index < #segments then -- stop on last

      if property.propertyType == 'StructProperty' then

        if not property.structAddress then return nil, property.structError or 'Struct type unavailable' end

        currentObject = fieldAddress
        currentType = property.structAddress

      elseif property.propertyType == 'ObjectProperty' or property.propertyType == 'ClassProperty' then
        local nextObject = readPointer(fieldAddress)

        if not nextObject or nextObject == 0 then return nil, ('Null or invalid UObject pointer at path segment %s'):format(propertyName) end

        currentObject = nextObject
        currentType = Backend.objectClass(nextObject)
      else
        
        return nil, ('Cannot traverse %s (%s)'):format( propertyName, tostring(property.propertyType) )
      end

    else

      result.objectAddress = currentObject
      result.fieldAddress = fieldAddress
      result.offset = property.offset

    end

  end

  return result
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// OFFSET SYMBOL REGISTRY

--- Selectively get property offsets.
-- @param typeAddress number @ UClass or UScriptStruct descriptor address
-- @param propertyNames string[]|nil @ selected names/paths, nil for every field
-- @return table<string, table>|nil @ registration-ready property metadata
-- @return string|nil @ error
function Dumper.Offsets.collectRegistrationProperties(typeAddress, propertyNames)
  assert( propertyNames == nil or type(propertyNames) == 'table', 'property names must be an array or nil' )

  if propertyNames == nil then
    return Dumper.Structures.ue_enumFlattenedProperties( typeAddress, true )
  end

  local properties = {}

  for _, propertyName in ipairs(propertyNames) do
    local offset, offsetError = Dumper.Offsets.ue_getPropertyOffset( typeAddress, propertyName )
    if offset == nil then return nil, offsetError end

    properties[propertyName] =
    {
      offset = offset,
      rawPath = propertyName,
      displayPath = propertyName,
    }
  end

  return properties
end

--- Register selected direct or embedded-struct offsets for a reflected type
-- Dotted embedded-struct paths are registered as added offsets
-- @param typeNameOrAddress string|number @ reflected class/struct name or descriptor address
-- @param propertyNames string[]|nil @ selected names/paths, nil for every field
-- @param namespace string|nil @ optional symbol namespace
-- @return table<string, number>|nil @ registered symbol-to-offset map
-- @return string|nil @ error
function Dumper.Offsets.ue_registerClassOffsets(typeNameOrAddress, propertyNames, namespace)
  local typeAddress = Dumper.Helpers.resolveType(typeNameOrAddress)
  if not typeAddress then return nil, 'UClass or script struct not found' end

  local properties, errorMessage = Dumper.Offsets.collectRegistrationProperties( typeAddress, propertyNames )
  if not properties then return nil, errorMessage end

  local typeName = Backend.objectName(typeAddress) or ('Type_%X'):format(typeAddress)

  return Dumper.Offsets.registerProperties( properties, typeName, propertyNames, namespace or '' )
end

--- Register selected direct or embedded-struct offsets using a UObject instance
-- @param objectAddress number @ UObject instance addr
-- @param propertyNames string[]|nil @ selected names/paths, nil for every field
-- @param namespace string|nil @ optional namespace
-- @param symbolPrefix string|nil @ optional type-name (class name) replacement in generated symbols
-- @return table<string, number>|nil @ registered symbol-to-offset map
-- @return string|nil @ error
function Dumper.Offsets.ue_registerObjectOffsets(objectAddress, propertyNames, namespace, symbolPrefix)
  local classAddress = Backend.objectClass(objectAddress)
  if not classAddress or classAddress == 0 then return nil, 'Runtime UObject class unavailable' end

  local className = symbolPrefix or Backend.objectName(classAddress) or ('Class_%X'):format(classAddress)
  assert( type(className) == 'string' and className ~= '', 'symbol prefix must be non-empty' )

  local properties, errorMessage = Dumper.Offsets.collectRegistrationProperties( classAddress, propertyNames )
  if not properties then return nil, errorMessage end

  return Dumper.Offsets.registerProperties( properties, className, propertyNames, namespace or '' )
end

--- Register every segment offset as CE symbol in a resolved UObject property path
-- @param rootObject number @ root UObject addr
-- @param propertyPath string|string[] @ dot-separated path or segment array
-- @param namespace string|nil @ optional namespace
-- @return table<string, number>|nil @ registered symbol-to-offset map
-- @return string|nil @ error
function Dumper.Offsets.ue_registerObjectPath(rootObject, propertyPath, namespace)

  -- per-segment data
  local resolved, errorMessage = Dumper.Offsets.ue_resolveObjectPropertyPath(rootObject, propertyPath)
  if not resolved then return nil, errorMessage end

  namespace = (namespace and namespace ~= '' and namespace .. '.') or ''
  local pathParts = {}
  local result = {}

  for _, step in ipairs(resolved.steps) do

    pathParts[ #pathParts + 1 ] = step.name
    local name = namespace .. table.concat( pathParts, '.' )
    result[name] = step.offset
  end

  for name, offset in pairs(result) do
    Backend.registerSymbol(name, offset)
    registeredSymbols[name] = true
  end

  return result
end

--- remove every CE registered symbol created by the script
function Dumper.Offsets.ue_unregisterAllOffsets()
  for name in pairs(registeredSymbols) do Backend.unregisterSymbol(name) end
  Dumper.State.registeredSymbols = {}
  registeredSymbols = Dumper.State.registeredSymbols
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// STATUS

--- is reflection layout is initialized?
-- @return boolean @ true when layout-based queries may be made
function Dumper.Lifecycle.ue_isReady()
  return Backend.isReady()
end

--- UE runtime names ready?
-- @return boolean @ true when name-based queries may be made
function Dumper.Lifecycle.ue_isNameReady()
  local status = Backend.status()
  return status ~= nil and status.namesReady == true
end

--- Get scan status
-- @return table @ status and log fields
function Dumper.Lifecycle.ue_getStatus()
  return Backend.status()
end

--- Clear cached type addresses and the incremental GUObjectArray type index
-- Registered Cheat Engine symbols are not removed.
function Dumper.Lifecycle.ue_clearCache()
  Dumper.State.cacheProcessId = getOpenedProcessID()
  Dumper.State.typeCache = {}
  typeCache = Dumper.State.typeCache
  Backend.clearTypeLookupCache()
  Dumper.State.classMetadataStructure = nil
  Dumper.State.propertyMetadataStructure = nil
  Dumper.State.classReferenceIndex = nil
end

--- Enable or disable UClass/UProperty metadata expansion in new structures
-- Existing CE structures retain the layout with which they were created
-- @param enabled boolean @ true to expose reflection descriptor chains
function Dumper.Lifecycle.ue_setReflectionMetadataVisible(enabled)
  assert( type(enabled) == 'boolean', 'enabled must be a boolean' )
  Backend.setReflectionMetadataVisible(enabled)
  Dumper.State.classMetadataStructure = nil
  Dumper.State.propertyMetadataStructure = nil
end

--- Return the current structure metadata-exploration option
-- @return boolean @ true when UProperty chains are exposed
function Dumper.Lifecycle.ue_isReflectionMetadataVisible()
  return Backend.showsReflectionMetadata()
end

--- Show/hide ceUEDumper root menu item
-- @param enabled boolean @ true to show the menu; false to hide it
-- @return boolean @ resulting configured visibility
function Dumper.Lifecycle.ue_setMenuVisible(enabled)
  assert( type(enabled) == 'boolean', 'enabled must be a boolean' )
  return Backend.setMenuVisible(enabled)
end

--- Return configured ceUEDumper root-menu visibility
-- @return boolean @ true when current and future menu instances are visible
function Dumper.Lifecycle.ue_isMenuVisible()
  return Backend.isMenuVisible()
end

--- Return internal dumper object
-- @return table @ internal Dumper namespace and state object
function Dumper.Lifecycle.ue_getDumper()
  return Dumper
end

--- Whether the configured init readiness requirement is satisfied
-- @param config table|nil
-- @return boolean @ true when initialization is complete
-- @return string|nil @ error
function Dumper.Lifecycle.checkInitStatus(config)
  if not Backend.isReady() then return false end
  local status = Backend.status()

  if config.requireNames ~= false and not (status and status.namesReady) then
    return false, 'UE layout was found, but runtime names are unavailable'
  end

  return true
end

--- Init dumper and wait for reflected layout data
-- @param config table|nil
-- @return boolean @ true when the requested option is available
-- @return string|nil @ error
function Dumper.Lifecycle.ue_initDumper(config)
  config = config or {}
  assert( type(config) == 'table', 'config must be a table or nil' )

  Backend.configureSignatures( config.signatureSelection or 'first' )

  -- clear names
  Dumper.Lifecycle.ue_clearCache()

  local complete, completionError = Dumper.Lifecycle.checkInitStatus(config)

  if complete then return true end

  if config.launchScanner == false then
    return false, 'UE reflection is not initialized and scanner launch was disabled'
  end

  -- it's blocking, perform scan in caller/main thread
  local initialized, initializationError = Backend.initialize()
  if not initialized then
    return false, 'UE reflection querying failed: ' .. tostring(initializationError or 'scanner returned no result')
  end

  complete, completionError = Dumper.Lifecycle.checkInitStatus(config)
  if complete then return true end

  -- failure case
  local status = Backend.status()
  local reason = completionError or status.error

  if not reason and status.log and status.log ~= '' then
    reason = status.log:sub(-2000)
  end

  return false, 'UE reflection querying failed: ' .. (reason or 'NO MEANINGFUL ERROR PRODUCED')
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// CLASS/PROPERTY QUERIES

--- Find UClass by its short reflected name
-- @param className string @ class name w/o path
-- @return number|nil @ UClass address
function Dumper.Reflection.ue_findClass(className)
  return Dumper.Helpers.resolveType( className, 'Class' )
end

--- Enumerate reflected properties of a class or script struct
-- Inherited fields are included when the supplied type has a superclass
-- @param typeNameOrAddress string|number @ reflected name or type descriptor address
-- @return table<string, table>|nil @ property metadata keyed by name
-- @return string|nil @ error
function Dumper.Reflection.ue_enumProperties(typeNameOrAddress)

  -- are we good?
  local status = Backend.status()
  if status and status.namesReady == false then
    return nil, 'UE reflection unavailable; FName issue'
  end

  local address = Dumper.Helpers.resolveType(typeNameOrAddress)

  if not address then return nil, 'UE class or script struct not found' end

  return Backend.properties(address)
end

--- Find a reflected script struct by name
-- @param structName string @ reflected struct name
-- @return number|nil @ UScriptStruct descriptor, not instance
function Dumper.Reflection.ue_findStruct(structName)
  return Dumper.Helpers.resolveType( structName, 'ScriptStruct' )
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// OBJECT & PROPERTY PATH QUERIES

--- Enumerate properties using UObject addr
-- @param objectAddress number @ UObject instance addr
-- @return table<string, table>|nil @ property metadata keyed by name
-- @return string|nil @ error
function Dumper.Reflection.ue_enumObjectProperties(objectAddress)
  assert( type(objectAddress) == 'number' and objectAddress ~= 0 , 'object address must be non-zero' )

  local classAddress = Backend.objectClass(objectAddress)
  if not classAddress then return nil, 'Runtime UObject class wasnt read' end

  return Dumper.Reflection.ue_enumProperties(classAddress)
end

--- Find runtime UObject instances whose class matches UClass/class name
-- exact class matches are returned by default
-- set includeSubclasses to include instances of any class derived from the requested UClass
-- GUObjectArray is scanned on every call
-- @param classNameOrAddress string|number @ target UClass name or descriptor
-- @param options table|nil @ includeSubclasses, excludeDefaultObjects, limit
-- @return table[]|nil @ object metadata records
-- @return string|nil @ query error
-- @return table|nil @ traversal statistics
function Dumper.Objects.ue_findObjectsOfClass(classNameOrAddress, options)
  options = options or {}
  assert( type(options) == 'table', 'options must be a table or nil' )

  local classAddress = Dumper.Helpers.resolveType( classNameOrAddress, 'Class' )
  if not classAddress then return nil, 'Target UClass was not found' end

  return Backend.findObjectsOfClass( classAddress, options )
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--/// CLASS REFERENCE INDEX

--- Copy wrapper path and append one property/container kind
-- @param wrappers string[] @ existing wrapper path
-- @param wrapper string @ enclosing property/container kind
-- @return string[] @ independent extended wrapper path
function Dumper.References.appendWrapper(wrappers, wrapper)
  local extended = {}

  for index, value in ipairs(wrappers) do extended[index] = value end
  extended[ #extended + 1 ] = wrapper

  return extended
end

--- Index class references reachable through one reflected property
-- Embedded structs are followed recursively
-- Containers retain a field path, yet their element reference has no fixed object-relative offset
-- @param index table @ reverse-reference index under construction
-- @param owner table @ declaring UClass metadata
-- @param propertyName string @ reflected leaf property name
-- @param property table @ decoded property metadata
-- @param path string @ readable path from the declaring class
-- @param parentStaticOffset number|nil @ parent embedded-struct offset
-- @param rootPropertyOffset number @ top-level class field offset
-- @param wrappers string[] @ enclosing property/container kinds
-- @param activeStructs table<number, boolean> @ recursion-cycle guard
-- @return nil
function Dumper.References.indexProperty(index, owner, propertyName, property, path, parentStaticOffset, rootPropertyOffset, wrappers, activeStructs)
  local propertyType = property.propertyType
  local staticOffset = parentStaticOffset and parentStaticOffset + (property.offset or 0) or nil
  local referencedClass, referenceMember, referenceMemberOffset = Backend.propertyClassReference( property.propertyAddress, propertyType )

  if referencedClass then
    local references = index.byReferencedClass[referencedClass]

    if not references then
      references = {}
      index.byReferencedClass[referencedClass] = references
    end

    references[ #references + 1 ] =
    {
      ownerClassAddress = owner.address,
      ownerClassName = owner.name,
      propertyName = propertyName,
      propertyAddress = property.propertyAddress,
      propertyType = propertyType,
      propertyOffset = property.offset,
      staticOffset = staticOffset,
      rootPropertyOffset = rootPropertyOffset,
      path = path,
      wrappers = wrappers,
      referencedClassAddress = referencedClass,
      referencedClassName = Backend.objectName(referencedClass),
      referenceMember = referenceMember,
      referenceMemberOffset = referenceMemberOffset,
    }

    index.referenceCount = index.referenceCount + 1
    return
  end

  if propertyType == 'StructProperty' then
    local structAddress = property.structAddress or Backend.propertyStruct( property.propertyAddress )

    if not structAddress or activeStructs[structAddress] then return end

    local structProperties = Backend.properties(structAddress)
    if not structProperties then return end

    activeStructs[structAddress] = true
    local nestedWrappers = Dumper.References.appendWrapper( wrappers, 'StructProperty' )

    for nestedName, nestedProperty in pairs(structProperties) do
      Dumper.References.indexProperty(
                                      index,
                                      owner,
                                      nestedName,
                                      nestedProperty,
                                      path .. '.' .. nestedName,
                                      staticOffset,
                                      rootPropertyOffset,
                                      nestedWrappers,
                                      activeStructs
                                    )
    end

    activeStructs[structAddress] = nil
    return
  end

  if propertyType == 'ArrayProperty' then
    local innerProperty = property.innerProperty or Backend.propertyArrayInner( property.propertyAddress )

    if innerProperty then
      Dumper.References.indexProperty(
                                      index,
                                      owner,
                                      innerProperty.name or propertyName,
                                      innerProperty,
                                      path .. '[]',
                                      nil,
                                      rootPropertyOffset,
                                      Dumper.References.appendWrapper( wrappers, 'ArrayProperty' ),
                                      activeStructs
                                    )
    end

    return
  end

  if propertyType == 'SetProperty' then
    local elementProperty = property.elementProperty or Backend.propertySetElement( property.propertyAddress )

    if elementProperty then
      Dumper.References.indexProperty(
                                      index,
                                      owner,
                                      elementProperty.name or propertyName,
                                      elementProperty,
                                      path .. '{}',
                                      nil,
                                      rootPropertyOffset,
                                      Dumper.References.appendWrapper( wrappers, 'SetProperty' ),
                                      activeStructs
                                    )
    end

    return
  end

  if propertyType ~= 'MapProperty' then return end

  local keyProperty = property.keyProperty
  local valueProperty = property.valueProperty

  if not keyProperty or not valueProperty then
    keyProperty, valueProperty = Backend.propertyMapMembers( property.propertyAddress )
  end

  if keyProperty then
    Dumper.References.indexProperty(
                                    index,
                                    owner,
                                    keyProperty.name or propertyName,
                                    keyProperty,
                                    path .. '{Key}',
                                    nil,
                                    rootPropertyOffset,
                                    Dumper.References.appendWrapper( wrappers, 'MapKey' ),
                                    activeStructs
                                  )
  end

  if valueProperty then
    Dumper.References.indexProperty(
                                    index,
                                    owner,
                                    valueProperty.name or propertyName,
                                    valueProperty,
                                    path .. '{Value}',
                                    nil,
                                    rootPropertyOffset,
                                    Dumper.References.appendWrapper( wrappers, 'MapValue' ),
                                    activeStructs
                                  )
  end
end

--- Build reverse index from referenced UClass to declaring properties
-- @param rebuild boolean|nil @ ignore the compatible cached index
-- @return table|nil @ reverse-reference index
-- @return string|nil @ scan error
function Dumper.References.buildClassReferenceIndex(rebuild)
  local classes, runtimeIdentity = Backend.reflectedTypes('Class')
  if not classes then return nil, 'UClass descriptors could not be enumerated' end

  -- only directly declared properties are rooted at each class to avoid inherited declarations from being duplicated for every derived class
  -- every UClass descriptor in GUObjectArray is visited once per runtime layout

  local cached = Dumper.State.classReferenceIndex

  if not rebuild and cached and cached.runtimeIdentity == runtimeIdentity and cached.classCount == #classes
  then
    return cached
  end

  local index =
  {
    runtimeIdentity = runtimeIdentity,
    byReferencedClass = {},
    classCount = #classes,
    scannedClassCount = 0,
    unresolvedClasses = {},
    referenceCount = 0,
  }
  local propertyCache = {}

  for _, classAddress in ipairs(classes) do
    local className = Backend.objectName(classAddress) or ('Class_%X'):format(classAddress)
    local properties, propertyError = Backend.declaredProperties( classAddress, propertyCache )

    if not properties then
      index.unresolvedClasses[ #index.unresolvedClasses + 1 ] =
      {
        classAddress = classAddress,
        className = className,
        error = propertyError,
      }
      goto continue
    end

    index.scannedClassCount = index.scannedClassCount + 1
    local owner = { address = classAddress, name = className }

    for propertyName, property in pairs(properties) do
      Dumper.References.indexProperty(
                                      index,
                                      owner,
                                      propertyName,
                                      property,
                                      propertyName,
                                      0,
                                      property.offset,
                                      {},
                                      {}
                                    )
    end

    ::continue::
  end

  Dumper.State.classReferenceIndex = index
  return index
end

--- Find reflected class fields whose declared type references a UClass
-- @param classNameOrAddress string|number @ target UClass
-- @param options table|nil @ rebuild, includeBaseDeclarations, includeDerivedDeclarations
-- @return table[]|nil @ reference metadata records
-- @return string|nil @ query error
-- @return table|nil @ index statistics
function Dumper.References.ue_findClassReferences(classNameOrAddress, options)
  options = options or {}
  assert( type(options) == 'table', 'options must be a table or nil' )
  
  -- exact declaration matches are returned by default.
  -- optional compatibility matching can include fields declared as ancestor/descendant class
  -- this queries reflection descriptors only
  
  local targetClass = Dumper.Helpers.resolveType( classNameOrAddress, 'Class' )
  if not targetClass then return nil, 'Target UClass was not found' end

  local index, indexError = Dumper.References.buildClassReferenceIndex(options.rebuild == true)
  if not index then return nil, indexError end

  local references = {}
  local seen = {}

  for referencedClass, records in pairs(index.byReferencedClass) do
    local matches = referencedClass == targetClass

    if not matches and options.includeBaseDeclarations == true then
      matches = Backend.classDerivesFrom( targetClass, referencedClass )
    end

    if not matches and options.includeDerivedDeclarations == true then
      matches = Backend.classDerivesFrom( referencedClass, targetClass )
    end

    if not matches then goto continue end

    for _, record in ipairs(records) do
      local key = ('%X:%X:%s'):format( record.ownerClassAddress, record.propertyAddress, record.path )

      if not seen[key] then
        seen[key] = true
        references[ #references + 1 ] = record
      end
    end

    ::continue::
  end

  table.sort(references,
    function(left, right)
      if left.ownerClassName == right.ownerClassName then return left.path < right.path end
      return left.ownerClassName < right.ownerClassName
    end
  )

  return references, nil,
  {
    targetClassAddress = targetClass,
    targetClassName = Backend.objectName(targetClass),
    classCount = index.classCount,
    scannedClassCount = index.scannedClassCount,
    unresolvedClassCount = #index.unresolvedClasses,
    referenceCount = index.referenceCount,
    runtimeIdentity = index.runtimeIdentity,
  }
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--/// STRUCTURE DISSECT

local SCALAR_PROPERTY_TYPES =
{
  Int8Property = vtByte, ByteProperty = vtByte, BoolProperty = vtByte,
  Int16Property = vtWord, UInt16Property = vtWord,
  IntProperty = vtDword, UInt32Property = vtDword,
  Int64Property = vtQword, UInt64Property = vtQword,
  FloatProperty = vtSingle, DoubleProperty = vtDouble,
  ObjectProperty = vtPointer, ClassProperty = vtPointer,
  ObjectPtrProperty = vtPointer, ClassPtrProperty = vtPointer,
  NameProperty = vtQword,
}

--- Flatten embedded struct fields into offsets relative to the supplied type
-- Object pointers and containers remain leaves. Cyclic/unresolved struct
-- metadata is an error rather than a silently incomplete offset table
-- @param typeNameOrAddress string|number @ UClass or UScriptStruct
-- @return table|nil @ metadata keyed by dotted field path
-- @return string|nil @ error
-- @param keepUnresolved boolean|nil @ display-only mode retaining unresolved structs as leaves
function Dumper.Structures.ue_enumFlattenedProperties(typeNameOrAddress, keepUnresolved)
  local enumProperties = Dumper.Reflection.ue_enumProperties
  local cleanPropertyPath = Dumper.Helpers.cleanPropertyPath
  local resolveProperty = Dumper.Helpers.resolveProperty
  local activeTypes = {}
  local flattened = {}

  --- Append one inline type's fields with cumulative offsets
  -- @param typeAddress number @ reflected descriptor
  -- @param prefix string @ enclosing dotted field path
  -- @param baseOffset number @ enclosing offset relative to the root
  -- @param depth number @ nesting depth
  -- @param displayPrefix string @ readable ancestor path, raw where ambiguous
  -- @return boolean|nil @ success
  -- @return string|nil @ metadata error
  local function visit(typeAddress, prefix, baseOffset, depth, displayPrefix)
    if depth > 32 or activeTypes[typeAddress] then return nil, 'Cyclic or excessively nested struct metadata' end

    activeTypes[ typeAddress ] = true

    local properties, err = enumProperties(typeAddress)
    if not properties then
      activeTypes[typeAddress] = nil
      return nil, err
    end

    for name, property in pairs(properties) do
      local path = prefix .. name
      local entry = {}
      local cleanName = cleanPropertyPath(name)
      local unambiguous = resolveProperty(properties, cleanName)
      local displayName = unambiguous == property and cleanName or name

      for key, value in pairs(property) do
        entry[key] = value
      end

      entry.offset = baseOffset + property.offset
      entry.rawPath = path
      entry.displayPath = displayPrefix .. displayName
      flattened[path] = entry

      if property.propertyType ~= 'StructProperty' then goto continue end

      if not property.structAddress then
        local expansionError = property.structError or 'Struct type unavailable'

        if not keepUnresolved then
          activeTypes[typeAddress] = nil
          return nil, path .. ': ' .. expansionError
        end

        entry.expansionError = expansionError
        goto continue
      end

      local complete, nestedError = visit( property.structAddress, path .. '.', entry.offset, depth + 1, entry.displayPath .. '.' )

      if not complete then

        if not keepUnresolved then
          activeTypes[typeAddress] = nil
          return nil, nestedError
        end

        entry.expansionError = nestedError
      end

      ::continue::
    end

    activeTypes[typeAddress] = nil
    return true
  end

  local typeAddress = Dumper.Helpers.resolveType(typeNameOrAddress)

  if not typeAddress then return nil, 'Type not found' end

  local complete, err = visit( typeAddress, '', 0, 0, '' )

  if not complete then return nil, err end

  return flattened
end

--- Return renderable properties in stable offset/name order
-- @param properties table @ reflected property metadata map
-- @return table[] @ ordered name/property pairs
function Dumper.Structures.orderRenderableProperties(properties)
  local ordered = {}

  for name, property in pairs(properties) do

    if property.propertyType ~= 'StructProperty' or property.expansionError then
      ordered[ #ordered + 1 ] = { name = property.displayPath or name, property = property }
    end

  end

  table.sort(ordered,
    function(left, right)
      if left.property.offset == right.property.offset then return left.name < right.name end
      return left.property.offset < right.property.offset
    end
  )

  return ordered
end

--- Build character view used by FString/TArray<TCHAR> data pointer
-- @return userdata @ CE child structure containing a bounded UTF-16 string
function Dumper.Structures.createWideStringDataStructure()
  local stringDataStructure = createStructure('ceUE.FString.Data')
  local stringElement = stringDataStructure.addElement()

  stringElement.Name = 'Characters'
  stringElement.Offset = 0
  stringElement.Vartype = vtUnicodeString
  stringElement.ByteSize = 0x800

  return stringDataStructure
end

--- Add FString inline header in object
-- FString uses same three-member storage header as TArray<TCHAR>
-- +0x00 Data, +0x08 ArrayNum, +0x0C ArrayMax
--
-- @param structure userdata|table @ destination CE structure
-- @param fieldName string @ displayed property name
-- @param fieldOffset number @ FString offset relative to the destination
function Dumper.Structures.addFStringProperty(structure, fieldName, fieldOffset)
  local dataElement = structure.addElement()
  dataElement.Name = fieldName
  dataElement.Offset = fieldOffset
  dataElement.Vartype = vtPointer
  dataElement.ChildStruct = Dumper.Structures.createWideStringDataStructure()

  local countElement = structure.addElement()
  countElement.Name = fieldName .. ' [ArrayNum]'
  countElement.Offset = fieldOffset + 8
  countElement.Vartype = vtDword
end

--- Test whether address contains plausible FString header
-- @param stringAddress number|nil @ possible inline FString address
-- @return boolean @ true when Data/ArrayNum/ArrayMax are coherent
function Dumper.Structures.isFStringHeader(stringAddress)
  if not stringAddress or stringAddress == 0 then return false end

  local dataAddress = readPointer(stringAddress)
  local characterCount = readInteger( stringAddress + 8 )
  local capacity = readInteger( stringAddress + 0xC )

  if type(characterCount) ~= 'number' or type(capacity) ~= 'number' then return false end
  if characterCount < 0 or capacity < characterCount or capacity > 0x1000000 then return false end
  if not dataAddress or dataAddress == 0 then return false end

  return readBytes( dataAddress, math.max(1, math.min(characterCount, 2)), false ) ~= nil
end

--- Locate FString inside live FTextData implementation
-- FText stores ptr to internal polymorphic ITextData object
-- The display string isnt part of stable public FText header & occurs at different offsets
-- @param textDataAddress number|nil @ live FText::Data pointer
-- @return number|nil @ offset of the embedded display FString
function Dumper.Structures.findFTextDisplayStringOffset(textDataAddress)
  local candidateOffsets = { 0x28, 0x88 }
  local isFStringHeader = Dumper.Structures.isFStringHeader

  for _, candidateOffset in ipairs(candidateOffsets) do
    if isFStringHeader( textDataAddress and textDataAddress + candidateOffset ) then return candidateOffset end
  end

  return nil
end

--- Build guarded view of live FTextData object
-- @param textDataAddress number|nil @ live FText::Data pointer
-- @return userdata|nil @ CE child structure when the display FString is found
function Dumper.Structures.createFTextDataStructure(textDataAddress)
  local displayStringOffset = Dumper.Structures.findFTextDisplayStringOffset(textDataAddress)
  if not displayStringOffset then return nil end

  local textDataStructure = createStructure('ceUE.FTextData')
  Dumper.Structures.addFStringProperty( textDataStructure, 'DisplayString', displayStringOffset )

  return textDataStructure
end

--- Add one FScriptDelegate invocation entry
-- FScriptDelegate
-- +0x00 FWeakObjectPtr.ObjectIndex
-- +0x04 FWeakObjectPtr.ObjectSerialNumber
-- +0x08 FName FunctionName
-- @param structure userdata|table @ destination invocation-list structure
-- @param entryName string @ displayed array-entry prefix
-- @param entryOffset number @ entry offset relative to the list data pointer
function Dumper.Structures.addScriptDelegateEntry(structure, entryName, entryOffset)
  local objectIndexElement = structure.addElement()
  objectIndexElement.Name = entryName .. '.ObjectIndex'
  objectIndexElement.Offset = entryOffset
  objectIndexElement.Vartype = vtDword

  local serialElement = structure.addElement()
  serialElement.Name = entryName .. '.ObjectSerialNumber'
  serialElement.Offset = entryOffset + 4
  serialElement.Vartype = vtDword

  local functionNameElement = structure.addElement()
  functionNameElement.Name = entryName .. '.FunctionName'
  functionNameElement.Offset = entryOffset + 8
  functionNameElement.Vartype = vtQword

  if Backend.hasCustomType('FName') then
    functionNameElement.Vartype = vtCustom
    functionNameElement.CustomTypeName = 'FName'
  end
end

--- Build pointed-to invocation list for inline multicast delegate
-- @param invocationCount number @ live FMulticastScriptDelegate ArrayNum
-- @return userdata|nil @ CE child structure, or nil for an invalid count
function Dumper.Structures.createMulticastDelegateDataStructure(invocationCount)
  if type(invocationCount) ~= 'number' or invocationCount < 0 or invocationCount > 0x1000000 then return nil end

  local invocationList = createStructure('ceUE.FMulticastScriptDelegate.InvocationList')
  local renderedCount = math.min( invocationCount, 256 )
  local addScriptDelegateEntry = Dumper.Structures.addScriptDelegateEntry

  for index = 0, renderedCount - 1 do
    addScriptDelegateEntry( invocationList, ('[%d]'):format(index), index * 0x10 )
  end

  return invocationList
end

--- Add inline FMulticastScriptDelegate/TArray<FScriptDelegate> header
-- @param structure userdata|table @ destination CE structure
-- @param fieldName string @ displayed reflected property name
-- @param fieldOffset number @ delegate offset relative to the destination
-- @param baseAddress number|nil @ live destination base, when available
function Dumper.Structures.addMulticastInlineDelegateProperty(structure, fieldName, fieldOffset, baseAddress)
  local arrayHeaderAddress = baseAddress and baseAddress + fieldOffset or nil

  local dataElement = structure.addElement()
  dataElement.Name = fieldName
  dataElement.Offset = fieldOffset
  dataElement.Vartype = vtPointer
  dataElement.OnCreateChild = function(_, dataAddress)
    if not dataAddress or dataAddress == 0 or not arrayHeaderAddress then return nil, true end

    local invocationCount = readInteger( arrayHeaderAddress + 8 )
    local childStructure = Dumper.Structures.createMulticastDelegateDataStructure(invocationCount)
    
    if childStructure then return childStructure end
    return nil, true
  end

  local countElement = structure.addElement()
  countElement.Name = fieldName .. ' [ArrayNum]'
  countElement.Offset = fieldOffset + 8
  countElement.Vartype = vtDword

  if arrayHeaderAddress then
    local dataAddress = readPointer(arrayHeaderAddress)
    local invocationCount = readInteger( arrayHeaderAddress + 8 )
    local maximumCount = readInteger( arrayHeaderAddress + 0xC )

    if dataAddress and dataAddress ~= 0
        and type(invocationCount) == 'number'
        and type(maximumCount) == 'number'
        and invocationCount >= 0
        and maximumCount >= invocationCount
        and maximumCount <= 0x1000000
    then
      dataElement.ChildStruct = Dumper.Structures.createMulticastDelegateDataStructure(invocationCount)
    end
  end
end

--- Configure one non-container CE element from reflected metadata
-- @param element userdata|table @ CE structure element
-- @param property table @ decoded reflected property
function Dumper.Structures.configurePropertyElement(element, property)
  element.Vartype = SCALAR_PROPERTY_TYPES[ property.propertyType ] or vtByteArray

  if element.Vartype == vtByteArray then element.ByteSize = property.size or 1 end

  if property.propertyType == 'NameProperty' and Backend.hasCustomType('FName') then
    element.Vartype = vtCustom
    element.CustomTypeName = 'FName'
  end

  if property.propertyType == 'BoolProperty' and property.byteMask then

    for bitIndex = 0, 7 do

      if property.byteMask == 1 << bitIndex then
        element.Vartype = vtBinary
        element.BitStart = bitIndex
        element.BitSize = 1
        break
      end

    end

  end

  if Backend.showsReflectionMetadata() and (property.propertyType == 'ClassProperty' or property.propertyType == 'ClassPtrProperty') then
    element.ChildStruct = Dumper.MetadataViews.getClassMetadataStructure()
  elseif element.Vartype == vtPointer then

    element.OnCreateChild = function(_, address)
      if not address or address == 0 then return nil, true end

      local child = Dumper.Structures.ue_createStructureFromObject(address)
      if child then return child end
      return nil, true
    end

  end

end

--- Build the pointed-to element layout for a live TArray
-- @param property table @ outer ArrayProperty metadata
-- @param arrayHeaderAddress number @ live FScriptArray/TArray address
-- @return userdata|nil @ child structure rooted at the Data pointer
-- @return string|nil @ metadata/header error
function Dumper.Structures.createArrayDataStructure(property, arrayHeaderAddress)
  local enumFlattenedProperties = Dumper.Structures.ue_enumFlattenedProperties
  local orderRenderableProperties = Dumper.Structures.orderRenderableProperties
  local addRenderedProperty = Dumper.Structures.addRenderedProperty
  local innerProperty, innerError = property.innerProperty, property.innerError

  if not innerProperty then
    innerProperty, innerError = Backend.propertyArrayInner( property.propertyAddress )
  end

  if not innerProperty then return nil, innerError end

  local dataAddress = readPointer( arrayHeaderAddress )
  local elementCount = readInteger( arrayHeaderAddress + 8 )
  local maximumCount = readInteger( arrayHeaderAddress + 0xC )

  if type(elementCount) ~= 'number'
      or type(maximumCount) ~= 'number'
      or elementCount < 0
      or maximumCount < elementCount
      or maximumCount > 0x1000000
  then
    return nil, 'TArray header is invalid'
  end

  local arrayStructure = createStructure('ceUE.TArray<' .. innerProperty.propertyType .. '>')

  if elementCount == 0 then return arrayStructure end

  if not dataAddress or dataAddress == 0 then return nil, 'TArray data pointer is null' end

  local renderedCount = math.min( elementCount, 256 )
  local elementStride = innerProperty.size

  for index = 0, renderedCount - 1 do
    local elementOffset = index * elementStride
    local elementName = ('[%d]'):format(index)

    if innerProperty.propertyType == 'StructProperty' and innerProperty.structAddress then

      local nestedProperties, nestedError = enumFlattenedProperties( innerProperty.structAddress, true )
      if not nestedProperties then return nil, nestedError end

      for _, nested in ipairs( orderRenderableProperties( nestedProperties ) ) do
        addRenderedProperty( arrayStructure, elementName .. '.' .. nested.name, nested.property, elementOffset, dataAddress )
      end

    else
      addRenderedProperty( arrayStructure, elementName, innerProperty, elementOffset, dataAddress )
    end

  end

  return arrayStructure
end

--- Align integer offset to power-of-two byte boundary
-- @param value number @ unaligned byte offset
-- @param alignment number @ positive power-of-two alignment
-- @return number @ aligned byte offset
function Dumper.Structures.alignOffset(value, alignment)
  return ( value + alignment - 1 ) & ~( alignment - 1 )
end

--- Resolve minimum alignment required by one reflected property value
-- @param property table @ decoded property metadata
-- @return number @ alignment used by FScriptSetLayout/FScriptMapLayout
function Dumper.Structures.propertyAlignment(property)

  if property.propertyType == 'StructProperty' and property.structAddress then
    local classLayout = Backend.classHeaderLayout()
    local alignmentOffset = classLayout.MinAlignment
    local alignment = type(alignmentOffset) == 'number' and readInteger( property.structAddress + alignmentOffset )

    if type(alignment) == 'number'
        and alignment > 0
        and alignment <= 0x100
        and alignment & ( alignment - 1 ) == 0
    then
      return alignment
    end
  end

  local propertyType = property.propertyType

  if propertyType == 'BoolProperty' or propertyType == 'ByteProperty' or propertyType == 'Int8Property' or propertyType == 'UInt8Property' then return 1 end
  
  if propertyType == 'Int16Property' or propertyType == 'UInt16Property' then return 2 end
  
  if propertyType == 'IntProperty'
     or propertyType == 'Int32Property'
     or propertyType == 'UInt32Property'
     or propertyType == 'FloatProperty'
     or propertyType == 'NameProperty'
     or propertyType == 'WeakObjectProperty'
     or propertyType == 'DelegateProperty'
  then
    return 4
  end

  local size = property.size or PTR_SIZE
  if size >= 8 then return 8 end
  if size >= 4 then return 4 end
  if size >= 2 then return 2 end
  return 1
end

--- Decode shared FScriptSet sparse-array header used by TSet/TMap
-- @param containerAddress number @ live inline FScriptSet/FScriptMap address
-- @return table|nil @ validated data pointer, counts and allocation-mask address
-- @return string|nil @ invalid-header error
function Dumper.Structures.readSparseContainerHeader(containerAddress)
  --[[
    FScriptSet / FScriptMap
    ├─ +0x00 Elements.Data  -- TArray storage pointer
    ├─ +0x08 Elements.Data.ArrayNum  -- sparse slot count (includes holes)
    ├─ +0x0C Elements.Data.ArrayMax
    ├─ +0x10 Elements.AllocationFlags  -- inline 128-bit allocation mask
    ├─ +0x20 AllocationFlags.SecondaryData  -- mask pointer when capacity > 128
    ├─ +0x28 AllocationFlags.NumBits
    ├─ +0x2C AllocationFlags.MaxBits
    ├─ +0x30 Elements.FirstFreeIndex
    └─ +0x34 Elements.NumFreeIndices
  ]]

  local header =
  {
    dataAddress = readPointer(containerAddress),
    slotCount = readInteger( containerAddress + 8 ),
    maximumSlotCount = readInteger( containerAddress + 0xC ),
    allocationBitCount = readInteger( containerAddress + 0x28 ),
    maximumAllocationBitCount = readInteger( containerAddress + 0x2C ),
    firstFreeIndex = readInteger( containerAddress + 0x30 ),
    freeIndexCount = readInteger( containerAddress + 0x34 ),
  }

  if type(header.slotCount) ~= 'number'
      or type(header.maximumSlotCount) ~= 'number'
      or type(header.allocationBitCount) ~= 'number'
      or type(header.maximumAllocationBitCount) ~= 'number'
      or type(header.freeIndexCount) ~= 'number'
      or header.slotCount < 0
      or header.maximumSlotCount < header.slotCount
      or header.maximumSlotCount > 0x100000
      or header.allocationBitCount < header.slotCount
      or header.maximumAllocationBitCount < header.allocationBitCount
      or header.maximumAllocationBitCount > 0x100000
      or header.freeIndexCount < 0
      or header.freeIndexCount > header.slotCount
  then
    return nil, 'FScriptSet/FScriptMap header is invalid'
  end

  header.elementCount = header.slotCount - header.freeIndexCount

  if header.slotCount == 0 then return header end
  if not header.dataAddress or header.dataAddress == 0 then return nil, 'Sparse container data pointer is null' end

  if header.maximumAllocationBitCount <= 128 then
    header.allocationFlagsAddress = containerAddress + 0x10
  else
    header.allocationFlagsAddress = readPointer( containerAddress + 0x20 )
  end

  if not header.allocationFlagsAddress or header.allocationFlagsAddress == 0 then
    return nil, 'Sparse container allocation flags are unavailable'
  end

  return header
end

--- Return occupied sparse indices using FScriptSet allocation flags
-- @param header table @ result of readSparseContainerHeader
-- @param maximumRenderedCount number|nil @ occupied-entry display limit
-- @return number[]|nil @ occupied sparse indices
-- @return string|nil @ allocation-bitset error
function Dumper.Structures.sparseContainerIndices(header, maximumRenderedCount)
  if header.slotCount == 0 then return {} end

  -- reading complete bitset once to avoid reads per possible slots
  local byteCount = ( header.slotCount + 7 ) >> 3
  local allocationBytes = readBytes( header.allocationFlagsAddress, byteCount, true )
  if type(allocationBytes) ~= 'table' or #allocationBytes < byteCount then return nil, 'Sparse container allocation flags are unreadable' end

  local indices = {}
  -- capped
  local renderedLimit = math.min( header.elementCount, maximumRenderedCount or 256 )
  if renderedLimit == 0 then return indices end

  for index = 0, header.slotCount - 1 do
    local allocationByte = allocationBytes[ (index >> 3) + 1 ]
    local allocationMask = 1 << ( index & 7 )

    if allocationByte & allocationMask ~= 0 then
      indices[ #indices + 1 ] = index
      if #indices >= renderedLimit then break end
    end
  end

  return indices
end

--- Calculate FScriptSet element metadata stored after reflected value
-- @param elementProperty table @ FSetProperty::ElementProp metadata
-- @return table|nil @ element alignment, hash offsets and sparse-slot stride
-- @return string|nil @ missing size error
function Dumper.Structures.createSetLayout(elementProperty)
  if type(elementProperty.size) ~= 'number' or elementProperty.size <= 0 then return nil, 'TSet element size is unavailable' end

  -- each sparse slot contains value followed by HashNextId and HashIndex
  local alignOffset = Dumper.Structures.alignOffset
  local elementAlignment = math.max( 4, Dumper.Structures.propertyAlignment(elementProperty) )
  local hashNextIdOffset = alignOffset( elementProperty.size, 4 )
  local hashIndexOffset = hashNextIdOffset + 4

  return
  {
    elementOffset = 0,
    hashNextIdOffset = hashNextIdOffset,
    hashIndexOffset = hashIndexOffset,
    stride = alignOffset( hashIndexOffset + 4, elementAlignment ),
  }
end

--- Calculate FScriptMap pair offsets and its enclosing sparse-slot stride
-- @param keyProperty table @ FMapProperty::KeyProp metadata
-- @param valueProperty table @ FMapProperty::ValueProp metadata
-- @return table|nil @ key/value/hash offsets and sparse-slot stride
-- @return string|nil @ missing size error
function Dumper.Structures.createMapLayout(keyProperty, valueProperty)
  if type(keyProperty.size) ~= 'number' or keyProperty.size <= 0 then return nil, 'TMap key size is unavailable' end
  if type(valueProperty.size) ~= 'number' or valueProperty.size <= 0 then return nil, 'TMap value size is unavailable' end

  -- UE links KeyProp/ValueProp against the pair
  -- their Offset_Internal values are FScriptMapLayout::KeyOffset/ValueOffset
  -- derive ValueOffset only when incomplete metadata leaves it at zero
  -- complete pair is wrapped in the hash metadata used by FScriptSet
  local alignOffset = Dumper.Structures.alignOffset
  local keyAlignment = Dumper.Structures.propertyAlignment(keyProperty)
  local valueAlignment = Dumper.Structures.propertyAlignment(valueProperty)
  local pairAlignment = math.max( 4, keyAlignment, valueAlignment )
  local computedValueOffset = alignOffset( keyProperty.size, valueAlignment )
  local valueOffset = type(valueProperty.offset) == 'number' and valueProperty.offset > 0
                      and valueProperty.offset
                      or computedValueOffset

  if valueOffset < keyProperty.size or valueOffset > 0x100000 then return nil, 'TMap value offset is invalid' end

  local hashNextIdOffset = alignOffset( valueOffset + valueProperty.size, 4 )
  local hashIndexOffset = hashNextIdOffset + 4

  return
  {
    keyOffset = 0,
    valueOffset = valueOffset,
    hashNextIdOffset = hashNextIdOffset,
    hashIndexOffset = hashIndexOffset,
    stride = alignOffset( hashIndexOffset + 4, pairAlignment ),
  }
end

--- Add one scalar, object, container or expanded struct value to container view
-- @param structure userdata|table @ sparse-container child structure
-- @param fieldName string @ displayed element/key/value name
-- @param property table @ reflected element property metadata
-- @param slotOffset number @ sparse slot base offset relative to container Data
-- @param dataAddress number @ live sparse Data pointer
-- @return boolean|nil @ success
-- @return string|nil @ struct metadata error
function Dumper.Structures.addContainerValue(structure, fieldName, property, slotOffset, dataAddress)
  if property.propertyType == 'StructProperty' and property.structAddress then
    local nestedProperties, nestedError = Dumper.Structures.ue_enumFlattenedProperties( property.structAddress, true )
    if not nestedProperties then return nil, nestedError end

    -- Struct flattening bypasses addRenderedProperty for the outer descriptor,
    -- so apply the container property's Offset_Internal here exactly once.
    local structOffset = slotOffset + property.offset

    for _, nested in ipairs( Dumper.Structures.orderRenderableProperties(nestedProperties) ) do
      Dumper.Structures.addRenderedProperty( structure, fieldName .. '.' .. nested.name, nested.property, structOffset, dataAddress )
    end

    return true
  end

  -- scalar/container rendering adds property.offset itself
  -- passing only the slot base prevents map values from receiving ValueOffset twice
  Dumper.Structures.addRenderedProperty( structure, fieldName, property, slotOffset, dataAddress )
  return true
end

--- Build pointed-to occupied-element layout for a TSet
-- @param property table @ outer SetProperty metadata
-- @param containerAddress number @ live inline FScriptSet address
-- @return userdata|nil @ child structure rooted at Elements.Data
-- @return string|nil @ metadata/header error
function Dumper.Structures.createSetDataStructure(property, containerAddress)
  local elementProperty, elementError = property.elementProperty, property.elementError

  if not elementProperty then
    elementProperty, elementError = Backend.propertySetElement( property.propertyAddress )
  end

  if not elementProperty then return nil, elementError end

  local header, headerError = Dumper.Structures.readSparseContainerHeader(containerAddress)
  if not header then return nil, headerError end

  local setLayout, layoutError = Dumper.Structures.createSetLayout(elementProperty)
  if not setLayout then return nil, layoutError end

  local setStructure = createStructure('ceUE.TSet<' .. elementProperty.propertyType .. '>')
  if header.elementCount == 0 then return setStructure end

  local indices, indexError = Dumper.Structures.sparseContainerIndices(header)
  if not indices then return nil, indexError end

  for _, sparseIndex in ipairs(indices) do
    local slotOffset = sparseIndex * setLayout.stride
    local added, addError = Dumper.Structures.addContainerValue( setStructure, ('[%d]'):format(sparseIndex), elementProperty, slotOffset, header.dataAddress )
    if not added then return nil, addError end
  end

  return setStructure
end

--- Build pointed-to occupied-pair layout for a TMap
-- @param property table @ outer MapProperty metadata
-- @param containerAddress number @ live inline FScriptMap address
-- @return userdata|nil @ child structure rooted at Elements.Data
-- @return string|nil @ metadata/header error
function Dumper.Structures.createMapDataStructure(property, containerAddress)
  local keyProperty, valueProperty, mapError = property.keyProperty, property.valueProperty, property.mapError

  if not keyProperty or not valueProperty then
    keyProperty, valueProperty, mapError = Backend.propertyMapMembers( property.propertyAddress )
  end

  if not keyProperty or not valueProperty then return nil, mapError end

  local header, headerError = Dumper.Structures.readSparseContainerHeader(containerAddress)
  if not header then return nil, headerError end

  local mapLayout, layoutError = Dumper.Structures.createMapLayout( keyProperty, valueProperty )
  if not mapLayout then return nil, layoutError end

  local mapStructure = createStructure( ('ceUE.TMap<%s,%s>'):format( keyProperty.propertyType, valueProperty.propertyType ) )
  if header.elementCount == 0 then return mapStructure end

  local indices, indexError = Dumper.Structures.sparseContainerIndices(header)
  if not indices then return nil, indexError end

  for _, sparseIndex in ipairs(indices) do
    local slotOffset = sparseIndex * mapLayout.stride
    local keyAdded, keyError = Dumper.Structures.addContainerValue( mapStructure, ('[%d].Key'):format(sparseIndex), keyProperty, slotOffset, header.dataAddress )
    if not keyAdded then return nil, keyError end

    local valueAdded, valueError = Dumper.Structures.addContainerValue( mapStructure, ('[%d].Value'):format(sparseIndex), valueProperty, slotOffset, header.dataAddress )
    if not valueAdded then return nil, valueError end
  end

  return mapStructure
end

--- Add inline FScriptSet/FScriptMap header and its live sparse-data view
-- @param structure userdata|table @ destination CE structure
-- @param fieldName string @ displayed reflected field name
-- @param property table @ SetProperty or MapProperty metadata
-- @param fieldOffset number @ container offset relative to destination
-- @param baseAddress number|nil @ live destination base
function Dumper.Structures.addSparseContainerProperty(structure, fieldName, property, fieldOffset, baseAddress)
  local dataElement = structure.addElement()
  dataElement.Name = fieldName
  dataElement.Offset = fieldOffset
  dataElement.Vartype = vtPointer

  local slotCountElement = structure.addElement()
  slotCountElement.Name = fieldName .. ' [ArrayNum]'
  slotCountElement.Offset = fieldOffset + 8
  slotCountElement.Vartype = vtDword

  local freeCountElement = structure.addElement()
  freeCountElement.Name = fieldName .. ' [NumFreeIndices]'
  freeCountElement.Offset = fieldOffset + 0x34
  freeCountElement.Vartype = vtDword

  if not baseAddress then return end

  local containerAddress = baseAddress + fieldOffset
  local createDataStructure = property.propertyType == 'MapProperty'
                                                        and Dumper.Structures.createMapDataStructure
                                                        or Dumper.Structures.createSetDataStructure

  dataElement.OnCreateChild = function(_, dataAddress)
    if not dataAddress or dataAddress == 0 then return nil, true end
    local childStructure = createDataStructure( property, containerAddress )
    if childStructure then return childStructure end
    return nil, true
  end

  local childStructure, containerError = createDataStructure( property, containerAddress )

  if childStructure then
    dataElement.ChildStruct = childStructure
  elseif containerError then
    dataElement.Name = dataElement.Name .. ' [unresolved: ' .. containerError .. ']'
  end
end

--- Add reflected field, expanding supported container headers and elements
-- @param structure userdata|table @ destination CE structure
-- @param fieldName string @ displayed field name
-- @param property table @ reflected property metadata
-- @param additionalOffset number @ containing array-element offset
-- @param baseAddress number|nil @ live base for container expansion
function Dumper.Structures.addRenderedProperty(structure, fieldName, property, additionalOffset, baseAddress)
  local elementOffset = additionalOffset + property.offset  -- TODO: extract to handlers

  if property.propertyType == 'MulticastInlineDelegateProperty' or property.propertyType == 'MulticastDelegateProperty'
  then
    Dumper.Structures.addMulticastInlineDelegateProperty( structure, fieldName, elementOffset, baseAddress )
    return
  end

  if property.propertyType == 'StrProperty' then
    Dumper.Structures.addFStringProperty( structure, fieldName, elementOffset )
    return
  end

  if property.propertyType == 'TextProperty' then
    local dataElement = structure.addElement()
    dataElement.Name = fieldName .. '.TextData.Object'
    dataElement.Offset = elementOffset
    dataElement.Vartype = vtPointer
    dataElement.OnCreateChild = function(_, textDataAddress)
      local childStructure = Dumper.Structures.createFTextDataStructure(textDataAddress)
      if childStructure then return childStructure end
      return nil, true
    end

    if baseAddress then
      local textDataAddress = readPointer( baseAddress + elementOffset )
      dataElement.ChildStruct = Dumper.Structures.createFTextDataStructure(textDataAddress)
    end

    -- local referenceElement = structure.addElement()
    -- referenceElement.Name = fieldName .. '.TextData.SharedReferenceCount.ReferenceController'
    -- referenceElement.Offset = elementOffset + 8
    -- referenceElement.Vartype = vtPointer

    -- local flagsElement = structure.addElement()
    -- flagsElement.Name = fieldName .. '.Flags'
    -- flagsElement.Offset = elementOffset + 0x10
    -- flagsElement.Vartype = vtDword
    return
  end
  
  if property.propertyType == 'ArrayProperty' then
    local dataElement = structure.addElement()
    dataElement.Name = fieldName --  .. ' [AllocatorInstance]'
    dataElement.Offset = elementOffset
    dataElement.Vartype = vtPointer

    local countElement = structure.addElement()
    countElement.Name = fieldName .. ' [ArrayNum]'
    countElement.Offset = elementOffset + 8
    countElement.Vartype = vtDword

    -- hide ArrayMax
    -- local capacityElement = structure.addElement()
    -- capacityElement.Name = fieldName .. ' [ArrayMax]'
    -- capacityElement.Offset = elementOffset + 0xC
    -- capacityElement.Vartype = vtDword

    if baseAddress then
      local childStructure, arrayError = Dumper.Structures.createArrayDataStructure(property, baseAddress + elementOffset)

      if childStructure then
        dataElement.ChildStruct = childStructure
      elseif arrayError then
        dataElement.Name = dataElement.Name .. ' [unresolved: ' .. arrayError .. ']'
      end
    end

    return
  end

  if property.propertyType == 'SetProperty' or property.propertyType == 'MapProperty' then
    Dumper.Structures.addSparseContainerProperty( structure, fieldName, property, elementOffset, baseAddress )
    return
  end

  local element = structure.addElement()
  element.Name = property.expansionError and fieldName .. ' [unresolved struct]' or fieldName
  element.Offset = elementOffset
  Dumper.Structures.configurePropertyElement(element, property)
end

--- Build a CE structure with embedded fields flattened at their true offsets
-- Does not replace CE's global UE renderer or install automatic callbacks
-- @param typeNameOrAddress string|number @ reflected class or script struct
-- @return userdata|nil @ CE structure
-- @return string|nil @ metadata error
function Dumper.Structures.ue_createStructureFromType(typeNameOrAddress, baseAddress)
  if not inMainThread() then return Dumper.Runtime.onMainThread( Dumper.Structures.ue_createStructureFromType, typeNameOrAddress, baseAddress ) end

  local enumFlattenedProperties = Dumper.Structures.ue_enumFlattenedProperties
  local orderRenderableProperties = Dumper.Structures.orderRenderableProperties
  local addRenderedProperty = Dumper.Structures.addRenderedProperty
  local properties, err = enumFlattenedProperties( typeNameOrAddress, true )

  if not properties then return nil, err end

  local typeAddress = Dumper.Helpers.resolveType(typeNameOrAddress)
  local structure = createStructure( 'ceUE.' .. (Backend.objectName(typeAddress) or ('Type_%X'):format(typeAddress)) )
  
  for _, field in ipairs( orderRenderableProperties(properties) ) do
    addRenderedProperty( structure, field.name, field.property, 0, baseAddress )
  end

  return structure
end

--- Build structure using the instance's actual runtime class
-- @param objectAddress number @ UObject instance
-- @return userdata|nil @ CE structure
-- @return string|nil @ error
function Dumper.Structures.ue_createStructureFromObject(objectAddress)
  if not inMainThread() then return Dumper.Runtime.onMainThread( Dumper.Structures.ue_createStructureFromObject, objectAddress ) end

  local typeAddress = Backend.objectClass(objectAddress)

  if not typeAddress or typeAddress == 0 then return nil, 'Runtime UObject class unavailable' end

  local structure, err = Dumper.Structures.ue_createStructureFromType(typeAddress, objectAddress)
  if not structure then return nil, err end
  
  local layout = Backend.objectHeaderLayout()
  
  -- only found offsets are used; embedded structs never get a UObject header
  local headers =
  {
    { 'vftable', layout.VTable, vtPointer },
    { 'Class', layout.Class, vtPointer },
    { 'Name', layout.Name, vtQword },
    { 'Outer', layout.Outer, vtPointer },
    { 'ObjectFlags', layout.ObjectFlags or layout.Flags, vtDword },
    { 'InternalIndex', layout.InternalIndex or layout.Index, vtDword },
  }

  for _, header in ipairs(headers) do
    
    if type( header[2] ) ~= 'number' then goto continue end

    local element = structure.addElement()
    element.Name, element.Offset, element.Vartype = header[1], header[2], header[3]

    if header[1] == 'Name' and Backend.hasCustomType('FName') then
      element.Vartype = vtCustom
      element.CustomTypeName = 'FName'
    end

    if header[1] == 'Class' and Backend.showsReflectionMetadata() then
      element.ChildStruct = Dumper.MetadataViews.getClassMetadataStructure()
      goto continue
    end

    if header[1] ~= 'Outer' then goto continue end

    element.OnCreateChild = function(_, address)
      if not address or address == 0 then return nil, true end

      local child = Dumper.Structures.ue_createStructureFromObject(address)
      if child then return child end

      return nil, true
    end

    ::continue::
  end
  return structure
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--/// STRUCTURE DISSECT OVERRIDE

--- Resolve UObject, runtime class and display name for an address
-- Passed addr can be a base or an addr inside the object
-- @param address number @ possible UObject address or address inside one
-- @return table|nil @ resolved object context
-- @return string|nil @ lookup error
function Dumper.StructureDissect.resolveObjectContext(address)
  if type(address) ~= 'number' or address == 0 then return nil, 'Address must be non-zero' end
  if not Backend.isReady() then return nil, 'UE reflection is not initialized' end

  local objectAddress, objectError = Backend.findContainingObject(address)
  if not objectAddress then return nil, objectError or 'Containing UObject was not found' end

  local classAddress = Backend.objectClass(objectAddress)
  if not classAddress or classAddress == 0 then return nil, 'Runtime UObject class unavailable' end

  local className = Backend.objectName(classAddress)
  if not className or className == 'None' then return nil, 'Runtime UObject class name unavailable' end

  local objectName = Backend.objectName(objectAddress)
  local displayName = 'ceUE.' .. className

  if objectName and objectName ~= 'None' and objectName ~= className then
    displayName = displayName .. ' [' .. objectName .. ']'
  end

  return
  {
    requestedAddress = address,
    objectAddress = objectAddress,
    classAddress = classAddress,
    className = className,
    objectName = objectName,
    displayName = displayName,
  }
end

--- Get UObject name and resolved base
-- @param address number @ address requested by Structure Dissect
-- @return string|nil @ inferred class/object display name
-- @return number|nil @ recovered UObject base
function Dumper.StructureDissect.structureNameLookup(address)
  local resolved, context = pcall( Dumper.StructureDissect.resolveObjectContext, address )
  if not resolved or not context then return nil end

  return context.displayName, context.objectAddress
end

--- Build a struct for a UObject
-- @param address number @ normalized Structure Dissect base address
-- @return userdata|nil @ generated CE structure
function Dumper.StructureDissect.structureDissectOverride(address)
  local resolved, context = pcall( Dumper.StructureDissect.resolveObjectContext, address )

  if not resolved or not context or context.objectAddress ~= address then return nil end

  if Backend.showsReflectionMetadata() and context.className == 'Function' then
    local functionStructure = Dumper.MetadataViews.getFunctionMetadataStructure(context.objectAddress)
    if functionStructure then return functionStructure end
  end

  local created, structure = pcall( Dumper.Structures.ue_createStructureFromObject, context.objectAddress )
  if not created or not structure then return nil end

  structure.Name = context.displayName
  return structure
end

--- Unregister ceUEDumper callbacks
-- @return void
function Dumper.StructureDissect.unregisterCallbacks()
  if not inMainThread() then return Dumper.Runtime.onMainThread(Dumper.StructureDissect.unregisterCallbacks) end

  local callbacks = sharedResources.structureDissectCallbacks

  if callbacks.nameLookup then
    pcall( unregisterStructureNameLookup, callbacks.nameLookup )
    callbacks.nameLookup = nil
  end

  if callbacks.dissectOverride then
    pcall( unregisterStructureDissectOverride2, callbacks.dissectOverride )
    callbacks.dissectOverride = nil
  end
end

--- Toggle UObject Struct Dissect resolvers
-- Unknown addresses are declined to pass down the chain
-- @param enabled boolean @ true to install the callbacks
-- @return boolean|nil @ true when the requested state was applied
-- @return string|nil @ error
function Dumper.StructureDissect.ue_setStructureDissectEnabled(enabled)
  if not inMainThread() then
    return Dumper.Runtime.onMainThread( Dumper.StructureDissect.ue_setStructureDissectEnabled, enabled )
  end

  assert( type(enabled) == 'boolean', 'enabled must be a boolean' )

  Dumper.StructureDissect.unregisterCallbacks()
  sharedResources.options.structureDissectEnabled = false

  if not enabled then return true end
  if not Backend.isReady() then return nil, 'UE reflection is not initialized' end

  local callbacks = sharedResources.structureDissectCallbacks
  callbacks.nameLookup = registerStructureNameLookup( Dumper.StructureDissect.structureNameLookup, true )

  if not callbacks.nameLookup then return nil, 'Could not register the UObject structure-name lookup' end

  callbacks.dissectOverride = registerStructureDissectOverride2( Dumper.StructureDissect.structureDissectOverride )

  if not callbacks.dissectOverride then
    Dumper.StructureDissect.unregisterCallbacks()
    return nil, 'Could not register the UObject structure dissector'
  end

  sharedResources.options.structureDissectEnabled = true
  return true
end

--- Are ceUEDumper Struct Dissect callbacks active
-- @return boolean @ current automatic-dissection state
function Dumper.StructureDissect.ue_isStructureDissectEnabled()
  local callbacks = sharedResources.structureDissectCallbacks

  return sharedResources.options.structureDissectEnabled == true
         and callbacks.nameLookup ~= nil
         and callbacks.dissectOverride ~= nil
end

-- Init
Dumper.StructureDissect.unregisterCallbacks()
sharedResources.options.structureDissectEnabled = false


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--/// REFLECTION METADATA VIEWS

--- Build structural metadata layout shared by UClass objects
-- Unlike an ordinary UObject instance, a UClass must expose its UStruct
-- links rather than the reflected gameplay fields described by that class
-- @return userdata @ reusable CE UClass metadata structure
function Dumper.MetadataViews.getClassMetadataStructure()
  if Dumper.State.classMetadataStructure then return Dumper.State.classMetadataStructure end

  local layout = Backend.classHeaderLayout()
  local structure = createStructure('ceUE.UClass metadata')
  Dumper.State.classMetadataStructure = structure

  local fields =
  {
    { 'vftable', layout.VTable, vtPointer },
    { 'ObjectFlags', layout.ObjectFlags or layout.Flags, vtDword },
    { 'InternalIndex', layout.InternalIndex or layout.Index, vtDword },
    { 'Class', layout.Class, vtPointer, 'class' },
    { 'Name', layout.Name, vtQword,   'name' },
    { 'Outer', layout.Outer, vtPointer },
    { 'SuperStruct', layout.SuperStruct, vtPointer, 'class' },
    { 'Children [UField/UFunction]', layout.Children, vtPointer, 'field' },
    { 'PropertyLink', layout.PropertyLink, vtPointer },
    { 'PropertyLink (alternate)', layout.PropertyLinkAlt, vtPointer },
  }

  for _, field in ipairs(fields) do
    if type( field[2] ) ~= 'number' then goto continue end

    local element = structure.addElement()
    element.Name, element.Offset, element.Vartype = field[1], field[2], field[3]

    if field[4] == 'class' then
      element.ChildStruct = structure

    elseif field[4] == 'field' and Backend.showsReflectionMetadata() then
      element.OnCreateChild = function(_, address)
        return Dumper.MetadataViews.getFieldMetadataStructure(address)
      end

    elseif field[4] == 'name' and Backend.hasCustomType('FName') then
      element.Vartype = vtCustom
      element.CustomTypeName = 'FName'

    elseif Backend.showsReflectionMetadata()

      and (field[1] == 'PropertyLink' or field[1] == 'PropertyLink (alt)')
    then
      element.ChildStruct = Dumper.MetadataViews.getPropertyMetadataStructure()
    end

    ::continue::
  end

  return structure
end

local FUNCTION_FLAGS =
{
  { 0x00000001, 'Final' }, { 0x00000002, 'RequiredAPI' },
  { 0x00000004, 'BlueprintAuthorityOnly' }, { 0x00000008, 'BlueprintCosmetic' },
  { 0x00000040, 'Net' }, { 0x00000080, 'NetReliable' },
  { 0x00000100, 'NetRequest' }, { 0x00000200, 'Exec' },
  { 0x00000400, 'Native' }, { 0x00000800, 'Event' },
  { 0x00001000, 'NetResponse' }, { 0x00002000, 'Static' },
  { 0x00004000, 'NetMulticast' }, { 0x00010000, 'MulticastDelegate' },
  { 0x00020000, 'Public' }, { 0x00040000, 'Private' },
  { 0x00080000, 'Protected' }, { 0x00100000, 'Delegate' },
  { 0x00200000, 'NetServer' }, { 0x00400000, 'HasOutParms' },
  { 0x00800000, 'HasDefaults' }, { 0x01000000, 'NetClient' },
  { 0x02000000, 'DLLImport' }, { 0x04000000, 'BlueprintCallable' },
  { 0x08000000, 'BlueprintEvent' }, { 0x10000000, 'BlueprintPure' },
  { 0x20000000, 'EditorOnly' }, { 0x40000000, 'Const' },
  { 0x80000000, 'NetValidate' },
}

--- Format selected EFunctionFlags for a structure-element caption
-- @param flags number @ raw EFunctionFlags
-- @return string @ pipe-separated flag names
function Dumper.MetadataViews.formatFunctionFlags(flags)
  local names = {}

  for _, entry in ipairs(FUNCTION_FLAGS) do
    if flags & entry[1] ~= 0 then names[ #names + 1 ] = entry[2] end
  end

  return #names > 0 and table.concat( names, '|' ) or 'None'
end

--- Build a UFunction descriptor view including execution and parameter data
-- Script.Data/Num expose Blueprint bytecode. Func is the native thunk when
-- FUNC_Native is set and normally the script VM thunk otherwise
-- @param functionAddress number @ live UFunction descriptor
-- @return userdata|nil @ CE metadata structure
-- @return boolean|nil @ let CE guess when the descriptor is unsupported
function Dumper.MetadataViews.getFunctionMetadataStructure(functionAddress)
  local metadata = Backend.functionMetadata(functionAddress)
  if not metadata then return nil, true end

  local layout = Backend.classHeaderLayout()
  local structure = createStructure( 'ceUE.UFunction metadata ' .. (metadata.name or '') )
  local implementation = metadata.native and 'native thunk' or 'script VM thunk'
  local scriptKind = metadata.bytecodeSize and metadata.bytecodeSize > 0 and 'Blueprint bytecode' or 'no bytecode'
  local fields =
  {
    { 'vftable', 0, vtPointer },
    { 'Class', layout.Class, vtPointer, 'class' },
    { 'Name', layout.Name, vtQword, 'name' },
    { 'Outer', layout.Outer, vtPointer },
    { 'Next', layout.Name and layout.Name + PTR_SIZE * 2, vtPointer, 'field' },
    { 'SuperStruct', layout.SuperStruct, vtPointer },
    { 'Children [parameters/functions]', layout.Children, vtPointer, 'field' },
    { 'ChildProperties [parameters]', layout.PropertyLinkAlt, vtPointer, 'property' },
    { 'PropertiesSize', layout.PropertiesSize, vtDword },
    { 'MinAlignment', layout.MinAlignment, vtWord },
    { 'Script.Data [' .. scriptKind .. ']', metadata.scriptOffset, vtPointer, 'script' },
    { 'Script.Num', metadata.scriptOffset and metadata.scriptOffset + PTR_SIZE, vtDword },
    { 'Script.Max', metadata.scriptOffset and metadata.scriptOffset + PTR_SIZE + 4, vtDword },
    { 'PropertyLink [parameters]', layout.PropertyLink, vtPointer, 'property' },
    { 'FunctionFlags [' .. Dumper.MetadataViews.formatFunctionFlags(metadata.functionFlags) .. ']', metadata.functionFlagsOffset, vtDword },
    { 'NumParms', metadata.numParmsOffset, vtByte },
    { 'ParmsSize', metadata.parmsSizeOffset, vtWord },
    { 'ReturnValueOffset', metadata.returnValueOffsetOffset, vtWord },
    { 'RPCId', metadata.rpcIdOffset, vtWord },
    { 'RPCResponseId', metadata.rpcResponseIdOffset, vtWord },
    { 'FirstPropertyToInit', metadata.firstPropertyToInitOffset, vtPointer, 'property' },
    { 'EventGraphFunction', metadata.eventGraphFunctionOffset, vtPointer, 'field' },
    { 'EventGraphCallOffset', metadata.eventGraphCallOffsetOffset, vtDword },
    { 'Func [' .. implementation .. ']', metadata.functionPointerOffset, vtPointer },
  }

  for _, field in ipairs(fields) do

    if type(field[2]) ~= 'number' then goto continue end

    local element = structure.addElement()
    element.Name, element.Offset, element.Vartype = field[1], field[2], field[3]

    if field[4] == 'class' then element.ChildStruct = Dumper.MetadataViews.getClassMetadataStructure()
    elseif field[4] == 'name' and Backend.hasCustomType('FName') then element.Vartype, element.CustomTypeName = vtCustom, 'FName'
    elseif field[4] == 'property' then element.ChildStruct = Dumper.MetadataViews.getPropertyMetadataStructure()
    elseif field[4] == 'field' then element.OnCreateChild = function(_, address) return Dumper.MetadataViews.getFieldMetadataStructure(address) end
    elseif field[4] == 'script' and metadata.bytecodeSize and metadata.bytecodeSize > 0 then
      element.OnCreateChild = function()
        local childStructure = Dumper.Bytecode.createStructure(metadata)
        return childStructure
      end
    end

    ::continue::
  end

  return structure
end

--- Build UFunction view or minimal traversable UField view
-- @param fieldAddress number @ UField child address
-- @return userdata|nil @ metadata structure
-- @return boolean|nil @ let CE guess when unreadable
function Dumper.MetadataViews.getFieldMetadataStructure(fieldAddress)
  if not fieldAddress or fieldAddress == 0 then return nil, true end

  local functionStructure = Dumper.MetadataViews.getFunctionMetadataStructure(fieldAddress)
  if functionStructure then return functionStructure end

  local layout = Backend.classHeaderLayout()
  local structure = createStructure('ceUE.UField metadata')
  local fields =
  {
    { 'vftable', 0, vtPointer }, { 'Class', layout.Class, vtPointer },
    { 'Name', layout.Name, vtQword }, { 'Outer', layout.Outer, vtPointer },
    { 'Next', layout.Name and layout.Name + PTR_SIZE * 2, vtPointer },
  }

  for _, field in ipairs(fields) do

    if type( field[2] ) == 'number' then
      local element = structure.addElement()
      element.Name, element.Offset, element.Vartype = field[1], field[2], field[3]

      if field[1] == 'Name' and Backend.hasCustomType('FName') then

        element.Vartype, element.CustomTypeName = vtCustom, 'FName'
      elseif field[1] == 'Next' then

        element.OnCreateChild = function(_, address) return Dumper.MetadataViews.getFieldMetadataStructure(address) end
      end

    end

  end

  return structure
end

--- Build the linked UProperty/FProperty descriptor layout for exploration
-- The layout uses found offsets and points PropertyLinkNext back to
-- itself, allowing CE to walk the property descriptor chain interactively
-- @return userdata @ reusable CE property metadata structure
function Dumper.MetadataViews.getPropertyMetadataStructure()
  if Dumper.State.propertyMetadataStructure then return Dumper.State.propertyMetadataStructure end

  local layout = Backend.propertyHeaderLayout()
  local structure = createStructure('ceUE.UProperty metadata')
  Dumper.State.propertyMetadataStructure = structure

  local fields =
  {
    { 'Class', layout.Class, vtPointer },
    { 'Owner', layout.Owner, vtPointer },
    { 'Name', layout.Name, vtQword, 'name' },
    { 'PropertyLinkNext', layout.PropertyLinkNext, vtPointer, 'property' },
    { 'PropertyLinkNext (alternate)', layout.PropertyLinkNextAlt, vtPointer, 'property' },
    { 'Offset_Internal', layout.Offset, vtDword },
    { 'PropertyFlags', layout.PropertyFlags or (layout.Offset and layout.Offset - 0xC), vtQword },
    { 'ElementSize', layout.Size, vtDword },
    { 'Type-specific metadata', layout.BitMaskField or layout.ObjectClassType, vtPointer },
  }

  for _, field in ipairs(fields) do
    if type(field[2]) ~= 'number' then goto continue end

    local element = structure.addElement()
    element.Name, element.Offset, element.Vartype = field[1], field[2], field[3]

    if field[4] == 'property' then
      element.ChildStruct = structure
      
    elseif field[4] == 'name' and Backend.hasCustomType('FName') then
      element.Vartype = vtCustom
      element.CustomTypeName = 'FName'
    end

    ::continue::
  end

  return structure
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// KISMET BYTECODE

--- Describe runtime-linked object/property operands embedded in Kismet bytecode
-- @param address number @ linked UObject or FField pointer
-- @return string|nil @ reflected operand name
function Dumper.Bytecode.describePointer(address)
  local propertyDecoded, propertyName, property = pcall( Backend.propertyMetadata, address )
  if propertyDecoded and property then return propertyName end

  local objectDecoded, objectName = pcall( Backend.objectName, address )
  return objectDecoded and objectName or nil
end

--- Build struct view for UFunction::Script bytecode
-- @param functionMetadata table @ validated UFunction metadata
-- @return userdata|nil @ CE child structure rooted at Script.Data
-- @return string|nil @ decoding feedback
function Dumper.Bytecode.createStructure(functionMetadata)
  local structure, feedback = Bytecode.Structures.create(
    functionMetadata,
    {
      describePointer = Dumper.Bytecode.describePointer,
      hasFNameCustomType = Backend.hasCustomType('FName'),
    }
  )

  if structure and feedback then structure.Name = structure.Name .. ' [partial]' end
  return structure, feedback
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// BYTECODE PATCHING

--- Return process-local reversible-patch registry
-- registry survives reloading, previous patches are discarded
-- @return table @ active-patch registry
function Dumper.Patching.registry()
  local registry = sharedResources.functionPatches
  local processId = getOpenedProcessID()

  if registry.processId ~= processId then
    registry.processId = processId
    registry.nextId = 1
    registry.active = {}
  end

  return registry
end

--- Find active patch overlapping proposed Script byte range
-- @param bytecodeAddress number @ Script.Data base
-- @param byteOffset number @ zero-based patch offset
-- @param byteCount number @ patch size
-- @return table|nil @ conflicting patch handle
function Dumper.Patching.findOverlap(bytecodeAddress, byteOffset, byteCount)
  local rangeAddress = bytecodeAddress + byteOffset

  for _, patch in pairs( Dumper.Patching.registry().active ) do
    if patch.active and Bytecode.Patches.rangesOverlap( rangeAddress, byteCount, patch.address, patch.size ) then return patch end
  end

  return nil
end

--- Patch bytes inside UFunction's Blueprint Script array
-- Patches bytes only, original bytes are saved as a handle for safely recovery
-- @param functionAddress number @ UFunction descriptor address
-- @param patchBytes number[] @ replacement byte values
-- @param byteOffset number|nil @ zero-based Script.Data offset, defaults to zero
-- @return table|nil @ reversible patch handle
-- @return string|nil @ error
function Dumper.Patching.ue_patchFunction(functionAddress, patchBytes, byteOffset)
  assert( type(functionAddress) == 'number' and functionAddress ~= 0, 'function address must be non-zero' )

  local metadata, metadataError = Backend.functionMetadata(functionAddress)
  if not metadata then return nil, metadataError end

  local validatedBytes, validationError = Bytecode.Patches.validateBytes(patchBytes)
  if not validatedBytes then return nil, validationError end

  byteOffset = byteOffset or 0
  if type(byteOffset) ~= 'number' or byteOffset % 1 ~= 0 or byteOffset < 0 then return nil, 'Patch offset must be a non-negative integer' end

  local conflictingPatch = metadata.bytecode and Dumper.Patching.findOverlap( metadata.bytecode, byteOffset, #validatedBytes )
  if conflictingPatch then return nil, ('Patch overlaps active patch #%d'):format(conflictingPatch.id) end

  local patch, patchError = Bytecode.Patches.apply( metadata, validatedBytes, byteOffset )
  if not patch then return nil, patchError end

  local registry = Dumper.Patching.registry()
  patch.id = registry.nextId
  patch.processId = registry.processId
  registry.nextId = registry.nextId + 1
  registry.active[patch.id] = patch

  return patch
end

--- NOP (void) Blueprint function body (inject return)
-- @param functionAddress number @ UFunction descriptor address
-- @param options table|nil @ { allowNonVoid=true } opts into an unsafe uninitialized return
-- @return table|nil @ reversible patch handle
-- @return string|nil @ error
function Dumper.Patching.ue_nopFunction(functionAddress, options)
  assert( type(functionAddress) == 'number' and functionAddress ~= 0, 'function address must be non-zero' )
  options = options or {}

  local metadata, metadataError = Backend.functionMetadata(functionAddress)
  if not metadata then return nil, metadataError end
  if metadata.native then return nil, 'Native UFunction thunks cannot be disabled by patching Blueprint bytecode' end

  local returnParameter
  for parameterName, property in pairs(metadata.parameters or {}) do
    if property.isReturnParameter then returnParameter = parameterName; break end
  end

  if returnParameter and not options.allowNonVoid then
    return nil, ('UFunction has return parameter %s; a void bytecode stub would leave it uninitialized'):format(returnParameter)
  end

  return Dumper.Patching.ue_patchFunction( functionAddress, Bytecode.Patches.VOID_RETURN, 0 )
end

--- Restore one reversible function patch
-- @param patch table @ handle returned by ue_patchFunction/ue_nopFunction
-- @param options table|nil @ { force=true } overwrites externally changed bytes
-- @return boolean|nil @ true when restored
-- @return string|nil @ error
function Dumper.Patching.ue_restoreFunctionPatch(patch, options)
  if type(patch) ~= 'table' then return nil, 'Function patch handle is required' end

  local registry = Dumper.Patching.registry()
  if patch.processId ~= registry.processId then return nil, 'Function patch belongs to another process' end
  if not patch.id or registry.active[patch.id] ~= patch then return nil, 'Function patch is not owned by this dumper instance' end

  local restored, restoreError = Bytecode.Patches.restore( patch, options and options.force == true )
  if not restored then return nil, restoreError end

  registry.active[patch.id] = nil
  return true
end

--- Restore every active function patch in reverse application order
-- @param options table|nil @ forwarded to ue_restoreFunctionPatch
-- @return number|nil @ number of restored patches
-- @return string|nil @ error
function Dumper.Patching.ue_restoreAllFunctionPatches(options)
  local registry = Dumper.Patching.registry()
  local patches = {}

  for _, patch in pairs(registry.active) do patches[ #patches + 1 ] = patch end
  table.sort( patches, function(left, right) return left.id > right.id end )

  local restoredCount = 0
  for _, patch in ipairs(patches) do
    local restored, restoreError = Dumper.Patching.ue_restoreFunctionPatch( patch, options )
    if not restored then return nil, ('Patch #%d: %s'):format( patch.id, restoreError ) end
    restoredCount = restoredCount + 1
  end

  return restoredCount
end

--- Enumerate active reversible function patches
-- @param functionAddress number|nil @ optional UFunction filter
-- @return table[] @ handles ordered by application id
function Dumper.Patching.ue_getFunctionPatches(functionAddress)
  local patches = {}

  for _, patch in pairs( Dumper.Patching.registry().active ) do
    if not functionAddress or patch.functionAddress == functionAddress then patches[ #patches + 1 ] = patch end
  end

  table.sort( patches, function(left, right) return left.id < right.id end )
  return patches
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// UFUNCTION

--- Enumerate UFunctions declared directly byreflected class/struct
-- Inherited functions can be obtained by calling this for each SuperStruct
-- @param classNameOrAddress string|number @ owning UClass/UStruct
-- @return table<string, number>|nil @ names mapped to UFunction descriptors
-- @return string|nil @ error
function Dumper.Functions.ue_enumFunctions(classNameOrAddress)

  local typeAddress = Dumper.Helpers.resolveType(classNameOrAddress)
  if not typeAddress then return nil, 'UClass or script struct not found' end
  
  return Backend.functions(typeAddress)
end

--- Find UFunction declared directly by class/struct
-- @param classNameOrAddress string|number @ owning reflected type
-- @param functionName string @ short reflected function name
-- @return number|nil @ UFunction descriptor address
-- @return string|nil @ error
function Dumper.Functions.ue_findFunction(classNameOrAddress, functionName)
  assert( type(functionName) == 'string' and functionName ~= '', 'function name must be non-empty' )

  local functions, functionsError = Dumper.Functions.ue_enumFunctions(classNameOrAddress)
  if not functions then return nil, functionsError end

  return functions[ functionName ], functions[ functionName ] and nil or 'UFunction wasnt found'
end

--- Decode execution, bytecode, RPC and parameter metadata for UFunction
-- Parameter entries include propertyFlags plus isParameter,
-- isOutParameter, isReturnParameter, isReferenceParameter,
-- isConstParameter bools
-- @param functionAddress number @ UFunction descriptor address
-- @return table|nil @ decoded UFunction metadata
-- @return string|nil @ error
function Dumper.Functions.ue_getFunctionMetadata(functionAddress)
  assert( type(functionAddress) == 'number' and functionAddress ~= 0, 'function address must be non-zero' )
  return Backend.functionMetadata(functionAddress)
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// FUNCTION INVOCATION

Dumper.Invocation.scalarSizes =
{
  ByteProperty = 1,
  Int8Property = 1,
  UInt8Property = 1,
  Int16Property = 2,
  UInt16Property = 2,
  IntProperty = 4,
  Int32Property = 4,
  UInt32Property = 4,
  Int64Property = 8,
  UInt64Property = 8,
  FloatProperty = 4,
  DoubleProperty = 8,
  EnumProperty = 4,
}

Dumper.Invocation.pointerTypes =
{
  ObjectProperty = true,
  ClassProperty = true,
  ClassPtrProperty = true,
}

--- Return reflected function parameters ordered by buffer offset
-- @param functionMetadata table @ decoded UFunction metadata
-- @return table[] @ entries containing name and property
function Dumper.Invocation.orderedParameters(functionMetadata)
  local ordered = {}

  for parameterName, property in pairs( functionMetadata.parameters or {} ) do

    if property.isParameter then
      ordered[ #ordered + 1 ] = { name = parameterName, property = property }
    end

  end
  
  -- sort by offset order
  table.sort( ordered, function(left, right) return left.property.offset < right.property.offset end )
  return ordered
end

--- Validate that property can be copied without UE livecycle
-- @param property table @ decoded FProperty metadata
-- @param visitedStructs table|nil @ recursive UScriptStruct cycle guard
-- @return boolean|nil @ true when direct buffer access is supported
-- @return string|nil @ unsupported-type reason
function Dumper.Invocation.validatePropertyType(property, visitedStructs)
  local propertyType = property.propertyType

  if Dumper.Invocation.scalarSizes[propertyType]
      or Dumper.Invocation.pointerTypes[propertyType]
      or propertyType == 'BoolProperty'
      or propertyType == 'NameProperty'
  then
    return true
  end

  if propertyType ~= 'StructProperty' then return nil, 'Managed or unsupported parameter type: ' .. tostring(propertyType) end

  if not property.isPlainOldData then return nil, 'Struct parameter is not marked CPF_IsPlainOldData' end

  if not property.structAddress then return nil, property.structError or 'Struct parameter type was not resolved' end

  visitedStructs = visitedStructs or {}
  if visitedStructs[ property.structAddress ] then return nil, 'Recursive struct metadata is unsupported' end

  visitedStructs[ property.structAddress ] = true
  local fields, fieldsError = Backend.properties( property.structAddress )

  if not fields then
    visitedStructs[ property.structAddress ] = nil
    return nil, fieldsError
  end

  for fieldName, field in pairs(fields) do
    local supported, supportError = Dumper.Invocation.validatePropertyType( field, visitedStructs )

    if not supported then
      visitedStructs[ property.structAddress ] = nil
      return nil, fieldName .. ': ' .. supportError
    end

  end

  visitedStructs[ property.structAddress ] = nil
  return true
end

--- Write one supported reflected value into parameter buffer
-- @param valueAddress number @ destination address
-- @param property table @ reflected property metadata
-- @param value any @ Lua value or nested struct table
-- @return boolean|nil @ true on success
-- @return string|nil @ conversion error
function Dumper.Invocation.writePropertyValue(valueAddress, property, value)
  local propertyType = property.propertyType

  if propertyType == 'BoolProperty' then
    local byteMask = property.byteMask or 1
    writeBytes( valueAddress, value and byteMask or 0 )
    return true
  end

  if propertyType == 'ByteProperty' or propertyType == 'Int8Property' or propertyType == 'UInt8Property' then
    if type(value) ~= 'number' then return nil, propertyType .. ' requires a number' end
    writeBytes( valueAddress, value & 0xFF )
    return true
  end

  if propertyType == 'Int16Property' or propertyType == 'UInt16Property' then
    if type(value) ~= 'number' then return nil, propertyType .. ' requires a number' end
    writeSmallInteger(valueAddress, value)
    return true
  end

  if propertyType == 'IntProperty' or propertyType == 'Int32Property'
    or propertyType == 'UInt32Property' or propertyType == 'EnumProperty'
  then
    if type(value) ~= 'number' then return nil, propertyType .. ' requires a number' end
    writeInteger(valueAddress, value)
    return true
  end

  if propertyType == 'Int64Property' or propertyType == 'UInt64Property' then
    if type(value) ~= 'number' then return nil, propertyType .. ' requires a number' end
    writeQword(valueAddress, value)
    return true
  end

  if propertyType == 'FloatProperty' then
    if type(value) ~= 'number' then return nil, 'FloatProperty requires a number' end
    writeFloat(valueAddress, value)
    return true
  end

  if propertyType == 'DoubleProperty' then
    if type(value) ~= 'number' then return nil, 'DoubleProperty requires a number' end
    writeDouble(valueAddress, value)
    return true
  end

  if Dumper.Invocation.pointerTypes[ propertyType ] then
    if value ~= nil and type(value) ~= 'number' then return nil, propertyType .. ' requires an address or nil' end
    writePointer(valueAddress, value or 0)
    return true
  end

  if propertyType == 'NameProperty' then
    local comparisonIndex
    local number = 0

    if type(value) == 'string' then
      comparisonIndex = Backend.nameIndex(value)
      if comparisonIndex == nil then return nil, 'FName is absent from the cached name pool: ' .. value end
    elseif type(value) == 'number' then
      comparisonIndex = value
    elseif type(value) == 'table' then
      comparisonIndex = value.comparisonIndex or value.index
      number = value.number or 0
    end

    if type(comparisonIndex) ~= 'number' then return nil, 'NameProperty requires a string, index, or FName table' end

    writeInteger(valueAddress, comparisonIndex)
    writeInteger(valueAddress + 4, number)
    return true
  end

  if propertyType == 'StructProperty' then
    if type(value) ~= 'table' then return nil, 'StructProperty requires a table' end

    local fields, fieldsError = Backend.properties(property.structAddress)
    if not fields then return nil, fieldsError end

    for requestedName, fieldValue in pairs(value) do
      local field, lookupError = Dumper.Helpers.resolveProperty(fields, requestedName)
      if not field then return nil, lookupError end

      local written, writeError = Dumper.Invocation.writePropertyValue( valueAddress + field.offset, field, fieldValue )
      if not written then return nil, requestedName .. ': ' .. writeError end
    end

    return true
  end

  return nil, 'Unsupported parameter type: ' .. tostring(propertyType)
end

--- Read one supported reflected value from parameter buffer
-- @param valueAddress number @ source address
-- @param property table @ reflected property metadata
-- @return any @ decoded Lua value
-- @return string|nil @ conversion error
function Dumper.Invocation.readPropertyValue(valueAddress, property)
  local propertyType = property.propertyType

  if propertyType == 'BoolProperty' then
    local byteValue = readBytes( valueAddress, 1, false ) or 0
    return byteValue & (property.byteMask or 1) ~= 0
  end

  if propertyType == 'ByteProperty' or propertyType == 'UInt8Property' then return readBytes( valueAddress, 1, false ) end

  if propertyType == 'Int8Property' then
    local result = readBytes( valueAddress, 1, false )
    return result and (result >= 0x80 and result - 0x100 or result) or nil
  end

  if propertyType == 'Int16Property' or propertyType == 'UInt16Property' then return readSmallInteger(valueAddress) end
  if propertyType == 'IntProperty' or propertyType == 'Int32Property' or propertyType == 'EnumProperty' then return readInteger(valueAddress) end

  if propertyType == 'UInt32Property' then
    local result = readInteger(valueAddress)
    return result and (result & 0xFFFFFFFF) or nil
  end

  if propertyType == 'Int64Property' or propertyType == 'UInt64Property' then return readQword(valueAddress) end
  if propertyType == 'FloatProperty' then return readFloat(valueAddress) end
  if propertyType == 'DoubleProperty' then return readDouble(valueAddress) end
  if Dumper.Invocation.pointerTypes[propertyType] then return readPointer(valueAddress) end

  if propertyType == 'NameProperty' then
    return
    {
      comparisonIndex = readInteger(valueAddress),
      number = readInteger(valueAddress + 4),
    }
  end

  if propertyType == 'StructProperty' then
    local fields, fieldsError = Backend.properties(property.structAddress)
    if not fields then return nil, fieldsError end

    local result = {}

    for fieldName, field in pairs(fields) do
      local fieldValue, readError = Dumper.Invocation.readPropertyValue( valueAddress + field.offset, field )
      if readError then return nil, fieldName .. ': ' .. readError end
      result[fieldName] = fieldValue
    end

    return result
  end

  return nil, 'Unsupported parameter type: ' .. tostring(propertyType)
end

--- Invoke a reflected UFunction on UObject through ProcessEvent
--
-- It supports scalar values, FName, raw UObject/UClass, ptrs, POD structs
-- UE-managed values requiring Ctors/Dtors are rejected before invocation
-- via CE calling API, not main thread
--
-- @param objectAddress number @ live target UObject this pointer
-- @param functionName string @ reflected UFunction name
-- @param arguments table|nil @ input values keyed by parameter name
-- @param options table|nil @ optional timeout in milliseconds
-- @return table|nil @ call metadata, returnValue, and outParameters
-- @return string|nil @ lookup, marshalling, or invocation error
function Dumper.Invocation.ue_callFunction(objectAddress, functionName, arguments, options)
  assert( type(objectAddress) == 'number' and objectAddress ~= 0, 'object address must be non-zero' )
  assert( type(functionName) == 'string' and functionName ~= '', 'function name must be non-empty' )
  assert( arguments == nil or type(arguments) == 'table', 'arguments must be a table or nil' )
  assert( options == nil or type(options) == 'table', 'options must be a table or nil' )

  arguments = arguments or {}
  options = options or {}

  local functionAddress, functionError = Backend.functionForObject( objectAddress, functionName )
  if not functionAddress then return nil, functionError end

  local metadata, metadataError = Backend.functionMetadata(functionAddress)
  if not metadata then return nil, metadataError end

  local processEventAddress, processEventError = Backend.processEvent()
  if not processEventAddress then return nil, processEventError end

  local orderedParameters = Dumper.Invocation.orderedParameters(metadata)
  local resolvedArguments = {}

  for argumentName, argumentValue in pairs(arguments) do
    local property, lookupError = Dumper.Helpers.resolveProperty( metadata.parameters, argumentName )
    if not property or not property.isParameter then return nil, lookupError or ('Not a function parameter: ' .. argumentName) end
    resolvedArguments[ property.propertyAddress ] = argumentValue
  end

  for _, parameter in ipairs(orderedParameters) do
    local property = parameter.property
    local supported, supportError = Dumper.Invocation.validatePropertyType(property)

    if not supported then return nil, parameter.name .. ': ' .. supportError end

    local propertySize = property.size or Dumper.Invocation.scalarSizes[property.propertyType] or 8

    if property.offset < 0 or property.offset + propertySize > metadata.parmsSize then
      return nil, ('Parameter %s lies outside the UFunction parameter buffer'):format(parameter.name)
    end

  end

  local allocationSize = math.max( metadata.parmsSize or 0, 1 )
  local parameterBuffer = allocateMemory(allocationSize)
  if not parameterBuffer or parameterBuffer == 0 then return nil, 'Failed allocating the UFunction parameter buffer' end

  local callResult
  local succeeded, invocationError = xpcall(
    function()
      -- local zeroBytes = {}
      -- for index = 1, allocationSize do zeroBytes[index] = 0 end
      -- writeBytes(parameterBuffer, zeroBytes)

      for _, parameter in ipairs(orderedParameters) do
        local argumentValue = resolvedArguments[ parameter.property.propertyAddress ]

        if argumentValue ~= nil then
          local written, writeError = Dumper.Invocation.writePropertyValue( parameterBuffer + parameter.property.offset, parameter.property, argumentValue )
          if not written then error(parameter.name .. ': ' .. writeError, 0) end

        end

      end

      local integerArgumentType = 0
      local timeout = options.timeout or INIT_WAIT_TIME

      executeCodeEx(
        0, -- stdcall
        timeout,
        processEventAddress,
        { type = integerArgumentType, value = objectAddress },
        { type = integerArgumentType, value = functionAddress },
        { type = integerArgumentType, value = parameterBuffer }
      )

      callResult =
      {
        -- functionAddress = functionAddress,
        -- processEventAddress = processEventAddress,
        outParameters = {},
      }

      for _, parameter in ipairs(orderedParameters) do
        local property = parameter.property

        if property.isOutParameter or property.isReturnParameter then
          local value, readError = Dumper.Invocation.readPropertyValue( parameterBuffer + property.offset, property )
          if readError then error( parameter.name .. ': ' .. readError, 0 ) end

          if property.isReturnParameter then callResult.returnValue = value end
          if property.isOutParameter then callResult.outParameters[ parameter.name ] = value end
        end

      end

    end,
    debug.traceback
  )

  deAlloc( parameterBuffer )

  if not succeeded then return nil, invocationError end
  return callResult
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// TEXT DUMPS

--- Get executable path
-- @param fileName string @ dump file name without a directory
-- @return string|nil @ absolute output path
-- @return string|nil @ path error
function Dumper.Dumps.defaultOutputPath(fileName)
  local modules = enumModules()
  local executable = modules and modules[1]
  local executablePath = executable and executable.PathToFile

  if type(executablePath) ~= 'string' or executablePath == '' then return nil, 'Target executable path is unavailable' end

  local directory = executablePath:match('^(.*[\\/])')
  if not directory then return nil, 'Target executable directory is unavailable' end
  return directory .. fileName
end

--- Write one CRLF-terminated dump line or raise a file error
-- @param file file* @ open Lua file
-- @param line string|nil @ line text
function Dumper.Dumps.writeLine(file, line)
  local written, writeError = file:write( line or '', '\r\n' )
  if not written then error( 'Dump write failed: ' .. tostring(writeError), 0 ) end
end

--- Open, populate, close a text dump
-- @param outputPath string|nil @ explicit path
-- @param defaultName string @ executable-directory file name
-- @param writer function @ callback receiving the open file
-- @return string|nil @ written absolute path
-- @return number|string|nil @ writer result, or error
function Dumper.Dumps.writeFile(outputPath, defaultName, writer)
  if outputPath ~= nil then assert( type(outputPath) == 'string' and outputPath ~= '', 'output path must be a non-empty string or nil' ) end

  local path, pathError = outputPath, nil
  if not path then path, pathError = Dumper.Dumps.defaultOutputPath(defaultName) end
  if not path then return nil, pathError end

  local file, openError = io.open( path, 'wb' )
  if not file then return nil, ('Unable to open %s: %s'):format( path, tostring(openError) ) end

  pcall( file.setvbuf, file, 'full', 0x100000 )

  local succeeded, result = xpcall( function() return writer(file) end, debug.traceback )
  local closed, closeError = file:close()

  if not succeeded then return nil, result end
  if not closed then return nil, ('Unable to close %s: %s'):format( path, tostring(closeError) ) end
  return path, result
end

--- Escape line-breaking characters in reflected names
-- @param value any @ reflected text
-- @return string @ single-line representation
function Dumper.Dumps.singleLine(value)
  return tostring(value or '<unnamed>'):gsub('\r', '\\r'):gsub('\n', '\\n')
end

--- Construct UObject path from Outer chain
-- Package/name topology is rendered as Package.TopLevel:Nested.Child.
-- @param objectAddress number @ UObject address
-- @return string @ best-effort full path
function Dumper.Dumps.objectPath(objectAddress)
  local layout = Backend.objectHeaderLayout()
  local outerOffset = layout.Outer
  local segments = {}
  local visited = {}
  local currentAddress = objectAddress

  if type(outerOffset) ~= 'number' then return Dumper.Dumps.singleLine( Backend.objectName(objectAddress) ) end

  for _ = 1, 128 do
    if type(currentAddress) ~= 'number' or currentAddress == 0 or visited[currentAddress] then break end

    visited[currentAddress] = true
    segments[ #segments + 1 ] = Dumper.Dumps.singleLine( Backend.objectName(currentAddress) )
    currentAddress = readPointer( currentAddress + outerOffset )
  end

  for left = 1, math.floor(#segments / 2) do
    local right = #segments - left + 1
    segments[left], segments[right] = segments[right], segments[left]
  end

  if #segments == 0 then return ('<object@0x%X>'):format(objectAddress) end
  if #segments == 1 then return segments[1] end

  local path = segments[1] .. '.' .. segments[2]
  if #segments >= 3 then path = path .. ':' .. table.concat( segments, '.', 3 ) end
  return path
end

--- Format property type (+ referenced and container types)
-- @param property table|nil @ decoded property metadata
-- @param active table|nil @ descriptor recursion guard
-- @param cppStyle boolean|nil @ use C++ scalar spellings
-- @return string @ readable type expression
function Dumper.Dumps.propertyType(property, active, cppStyle)
  if type(property) ~= 'table' then return '<?>' end

  local propertyType = property.propertyType or '<?Property>'
  local propertyAddress = property.propertyAddress or property.innerAddress
  active = active or {}

  if propertyAddress and active[propertyAddress] then return propertyType .. '<recursive>' end
  if propertyAddress then active[propertyAddress] = true end

  local cppScalarTypes =
  {
    BoolProperty = 'bool', ByteProperty = 'uint8', Int8Property = 'int8', UInt8Property = 'uint8',
    Int16Property = 'int16', UInt16Property = 'uint16', IntProperty = 'int32', Int32Property = 'int32',
    UInt32Property = 'uint32', Int64Property = 'int64', UInt64Property = 'uint64',
    FloatProperty = 'float', DoubleProperty = 'double', NameProperty = 'FName',
    StrProperty = 'FString', TextProperty = 'FText',
  }
  local formatted = cppStyle and cppScalarTypes[propertyType] or propertyType
  formatted = formatted or propertyType

  if propertyType == 'StructProperty' then
    local structAddress = property.structAddress or propertyAddress and Backend.propertyStruct(propertyAddress)
    formatted = ('StructProperty<%s>'):format( Backend.objectName(structAddress) or '?' )

  elseif propertyType == 'EnumProperty' or propertyType == 'ByteProperty' then
    local enumAddress = propertyAddress and Backend.propertyEnum( propertyAddress, propertyType )
    if enumAddress then formatted = ('%s<%s>'):format( propertyType, Backend.objectName(enumAddress) or '?' ) end

  elseif propertyType == 'ArrayProperty' then
    local inner = property.innerProperty or propertyAddress and Backend.propertyArrayInner(propertyAddress)
    formatted = ('TArray<%s>'):format( Dumper.Dumps.propertyType( inner, active, true ) )

  elseif propertyType == 'SetProperty' then
    local element = property.elementProperty or propertyAddress and Backend.propertySetElement(propertyAddress)
    formatted = ('TSet<%s>'):format( Dumper.Dumps.propertyType( element, active, true ) )

  elseif propertyType == 'MapProperty' then
    local keyProperty = property.keyProperty
    local valueProperty = property.valueProperty

    if (not keyProperty or not valueProperty) and propertyAddress then keyProperty, valueProperty = Backend.propertyMapMembers(propertyAddress) end

    formatted = ('TMap<%s, %s>'):format(
                                        Dumper.Dumps.propertyType( keyProperty, active, true ),
                                        Dumper.Dumps.propertyType( valueProperty, active, true )
                                      )

  elseif propertyAddress then
    local referencedClass = Backend.propertyClassReference( propertyAddress, propertyType )
    if referencedClass then formatted = ('%s<%s>'):format( propertyType, Backend.objectName(referencedClass) or '?' ) end
  end

  if propertyAddress then active[propertyAddress] = nil end
  return formatted
end

--- Return property entries ordered by internal offset and reflected name
-- @param properties table<string, table>|nil @ property map
-- @return table[] @ name/property records
function Dumper.Dumps.orderedProperties(properties)
  local ordered = {}
  for name, property in pairs(properties or {}) do ordered[ #ordered + 1 ] = { name = name, property = property } end

  table.sort( ordered,
    function(left, right)
      local leftOffset = left.property.offset or math.maxinteger
      local rightOffset = right.property.offset or math.maxinteger
      if leftOffset ~= rightOffset then return leftOffset < rightOffset end
      return left.name < right.name
    end
  )

  return ordered
end

--- Format UFunction
-- @param functionAddress number @ UFunction descriptor
-- @param functionName string @ reflected function name
-- @return string @ declaration and implementation annotation
function Dumper.Dumps.functionDeclaration(functionAddress, functionName)
  local metadata, metadataError = Backend.functionMetadata(functionAddress)

  if not metadata then
    return ('void %s(/* metadata unavailable */); // %s'):format(
                                                                  Dumper.Dumps.singleLine(functionName),
                                                                  Dumper.Dumps.singleLine(metadataError or 'unknown layout')
                                                                )
  end

  local returnType = 'void'
  local parameters = {}

  for _, entry in ipairs( Dumper.Invocation.orderedParameters(metadata) ) do
    local property = entry.property
    local formattedType = Dumper.Dumps.propertyType( property, nil, true )

    if property.isReturnParameter then
      returnType = formattedType
    else
      if property.isConstParameter then formattedType = 'const ' .. formattedType end
      if property.isOutParameter or property.isReferenceParameter then formattedType = formattedType .. '&' end
      parameters[ #parameters + 1 ] = formattedType .. ' ' .. Dumper.Dumps.singleLine( entry.name )
    end
  end

  local declaration = ('%s %s(%s)'):format( returnType, Dumper.Dumps.singleLine(functionName), table.concat( parameters, ', ' ) )
  if metadata.functionFlags and metadata.functionFlags & 0x40000000 ~= 0 then declaration = declaration .. ' const' end
  declaration = declaration .. ';'

  local annotations = {}
  if metadata.native then annotations[ #annotations + 1 ] = metadata.functionPointer and ('Native thunk=0x%X'):format(metadata.functionPointer) or 'Native' end
  if metadata.bytecodeSize and metadata.bytecodeSize > 0 then annotations[ #annotations + 1 ] = ('Blueprint bytecode=%d bytes'):format(metadata.bytecodeSize) end
  if #annotations > 0 then declaration = declaration .. ' // ' .. table.concat( annotations, ', ' ) end
  return declaration
end

--- Dump decoded FName strings in comparison-index order
-- @param outputPath string|nil @ optional output path; defaults beside target executable
-- @return string|nil @ written path
-- @return number|string|nil @ name count, or error
function Dumper.Dumps.ue_dumpFNames(outputPath)
  local namesByIndex = Backend.namesByIndex()
  if type(namesByIndex) ~= 'table' then return nil, 'Runtime FName cache is unavailable' end

  return Dumper.Dumps.writeFile( outputPath, 'ceUEDumper_FNames.txt',
    function(file)
      local entries = {}

      for nameIndex, name in pairs(namesByIndex) do
        if type(nameIndex) == 'number' and type(name) == 'string' then entries[ #entries + 1 ] = { index = nameIndex, name = name } end
      end

      table.sort( entries, function(left, right) return left.index < right.index end )
      for _, entry in ipairs(entries) do Dumper.Dumps.writeLine( file, Dumper.Dumps.singleLine(entry.name) ) end
      return #entries
    end
  )

end

--- Write one UClass/UScriptStruct declaration block
-- @param file file* @ output file
-- @param typeAddress number @ reflected type descriptor
-- @param kind string @ Class or ScriptStruct
-- @param propertyCache table @ shared declared-property cache
function Dumper.Dumps.writeStructuredType(file, typeAddress, kind, propertyCache)
  local writeLine = Dumper.Dumps.writeLine
  local layout = Backend.classHeaderLayout()
  local typeName = Backend.objectName(typeAddress) or ('Type_%X'):format(typeAddress)
  local superclass = type(layout.SuperStruct) == 'number' and readPointer( typeAddress + layout.SuperStruct ) or nil
  local superclassName = superclass and superclass ~= 0 and Backend.objectName(superclass) or nil
  local propertiesSize = type(layout.PropertiesSize) == 'number' and readInteger( typeAddress + layout.PropertiesSize ) or nil
  local keyword = kind == 'Class' and 'class' or 'struct'
  local declaration = keyword .. ' ' .. Dumper.Dumps.singleLine(typeName)

  if superclassName then declaration = declaration .. ' : ' .. Dumper.Dumps.singleLine(superclassName) end
  declaration = declaration .. (' // 0x%X, path=%s'):format( typeAddress, Dumper.Dumps.objectPath(typeAddress) )
  if propertiesSize then declaration = declaration .. (', size=0x%X'):format(propertiesSize) end

  writeLine(file, declaration)
  writeLine(file, '{')
  writeLine(file, '    // Fields')

  local properties, propertyError = Backend.declaredProperties( typeAddress, propertyCache )

  if not properties then
    writeLine( file, '    // Unavailable: ' .. Dumper.Dumps.singleLine(propertyError) )
  else
    for _, entry in ipairs( Dumper.Dumps.orderedProperties(properties) ) do
      local property = entry.property
      local offset = type(property.offset) == 'number' and ('0x%X'):format( property.offset ) or '?'
      local fieldSize = property.totalSize or property.size
      local size = type(fieldSize) == 'number' and ('0x%X'):format(fieldSize) or '?'
      local fieldName = Dumper.Dumps.singleLine(entry.name)

      if type(property.arrayDim) == 'number' and property.arrayDim > 1 then
        fieldName = ('%s[%d]'):format( fieldName, property.arrayDim )
      end

      writeLine( file, ('    [%s] [size=%s] %s %s;'):format( offset, size, Dumper.Dumps.propertyType( property, nil, true ), fieldName ) )
    end
  end

  writeLine(file, '')
  writeLine(file, '    // Functions')

  local functions, functionError = Backend.functions(typeAddress)

  if not functions then
    writeLine( file, '    // Unavailable: ' .. Dumper.Dumps.singleLine(functionError) )
  else
    local functionNames = {}
    for functionName in pairs(functions) do functionNames[ #functionNames + 1 ] = functionName end
    table.sort(functionNames)

    for _, functionName in ipairs(functionNames) do
      writeLine( file, '    ' .. Dumper.Dumps.functionDeclaration( functions[functionName], functionName ) )
    end
  end

  writeLine(file, '}')
  writeLine(file, '')
end

--- Write one UEnum declaration block
-- @param file file* @ output file
-- @param enumAddress number @ UEnum descriptor
function Dumper.Dumps.writeEnum(file, enumAddress)
  local writeLine = Dumper.Dumps.writeLine
  local enumName = Backend.objectName(enumAddress) or ('Enum_%X'):format(enumAddress)
  local values, valuesError = Backend.enumValues(enumAddress)

  writeLine( file, ('enum %s // 0x%X, path=%s'):format( Dumper.Dumps.singleLine(enumName), enumAddress, Dumper.Dumps.objectPath(enumAddress) ) )
  writeLine(file, '{')

  if not values then
    writeLine( file, '    // Unavailable: ' .. Dumper.Dumps.singleLine(valuesError) )
  else
    for _, entry in ipairs(values) do
      writeLine( file, ('    %s = %s,'):format( Dumper.Dumps.singleLine(entry.name), tostring(entry.value) ) )
    end
  end

  writeLine(file, '}')
  writeLine(file, '')
end

--- Dump UClass/UScriptStruct/UEnum/properties/UFunctions
-- @param outputPath string|nil @ optional output path; defaults beside target executable
-- @return string|nil @ written path
-- @return number|string|nil @ type count, or error
function Dumper.Dumps.ue_dumpTypes(outputPath)
  if not Backend.isReady() then return nil, 'UE reflection is not initialized' end

  local classes = Backend.reflectedTypes('Class')
  local structs = Backend.reflectedTypes('ScriptStruct')
  local enums = Backend.reflectedTypes('Enum')

  if not classes or not structs or not enums then return nil, 'Reflected types could not be enumerated' end

  return Dumper.Dumps.writeFile( outputPath, 'ceUEDumper_Types.txt',
    function(file)
      local records = {}

      for _, address in ipairs(classes) do records[ #records + 1 ] = { address = address, kind = 'Class' } end
      for _, address in ipairs(structs) do records[ #records + 1 ] = { address = address, kind = 'ScriptStruct' } end
      for _, address in ipairs(enums) do records[ #records + 1 ] = { address = address, kind = 'Enum' } end
      for _, record in ipairs(records) do record.path = Dumper.Dumps.objectPath(record.address) end

      table.sort( records,
        function(left, right)
          if left.path ~= right.path then return left.path < right.path end
          if left.kind ~= right.kind then return left.kind < right.kind end
          return left.address < right.address
        end
      )

      local propertyCache = {}

      for _, record in ipairs(records) do
        if record.kind == 'Enum' then Dumper.Dumps.writeEnum( file, record.address )
        else Dumper.Dumps.writeStructuredType( file, record.address, record.kind, propertyCache )
        end
      end

      return #records
    end
  )

end

--- Format runtime UObject type, enriching reflected property descriptors
-- @param objectAddress number @ UObject address
-- @return string @ reflected runtime type
function Dumper.Dumps.objectType(objectAddress)
  local classAddress = Backend.objectClass(objectAddress)
  local className = classAddress and Backend.objectName(classAddress)

  if type(className) ~= 'string' then return '<?>' end

  if className:sub(-8) == 'Property' then
    local _, property = Backend.propertyMetadata(objectAddress)
    if property then return Dumper.Dumps.propertyType(property) end
  end

  return className
end

--- Dump every readable GUObjectArray entry with address, type, full path
-- @param outputPath string|nil @ optional output path; defaults beside target executable
-- @return string|nil @ written path
-- @return number|string|nil @ dumped object count, or error
function Dumper.Dumps.ue_dumpObjects(outputPath)
  if not Backend.isReady() then return nil, 'UE reflection is not initialized' end

  local objectIterator, objectCountOrError = Backend.objectIterator()
  if not objectIterator then return nil, objectCountOrError end

  return Dumper.Dumps.writeFile( outputPath, 'ceUEDumper_UObjects.txt',
    function(file)
      local dumpedCount = 0

      for _, objectAddress in objectIterator do
        if type(objectAddress) == 'number' and objectAddress ~= 0 then
          Dumper.Dumps.writeLine( file, ('0x%016X  %s  %s'):format( objectAddress, Dumper.Dumps.objectType(objectAddress), Dumper.Dumps.objectPath(objectAddress) ) )
          dumpedCount = dumpedCount + 1
        end
      end

      return dumpedCount
    end
  )
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// API EXPORT

Dumper.API =
{
  ue_isReady = Dumper.Lifecycle.ue_isReady,
  ue_isNameReady = Dumper.Lifecycle.ue_isNameReady,
  ue_getStatus = Dumper.Lifecycle.ue_getStatus,
  ue_attachToTable = Dumper.Portable.ue_attachToTable,
  ue_setReflectionMetadataVisible = Dumper.Lifecycle.ue_setReflectionMetadataVisible,
  ue_isReflectionMetadataVisible = Dumper.Lifecycle.ue_isReflectionMetadataVisible,
  ue_clearCache = Dumper.Lifecycle.ue_clearCache,
  ue_initDumper = Dumper.Lifecycle.ue_initDumper,
  ue_findClass = Dumper.Reflection.ue_findClass,
  ue_findObjectsOfClass = Dumper.Objects.ue_findObjectsOfClass,
  ue_findClassReferences = Dumper.References.ue_findClassReferences,
  ue_findStruct = Dumper.Reflection.ue_findStruct,
  ue_enumFlattenedProperties = Dumper.Structures.ue_enumFlattenedProperties,
  ue_createStructureFromType = Dumper.Structures.ue_createStructureFromType,
  ue_createStructureFromObject = Dumper.Structures.ue_createStructureFromObject,
  ue_setStructureDissectEnabled = Dumper.StructureDissect.ue_setStructureDissectEnabled,
  ue_isStructureDissectEnabled = Dumper.StructureDissect.ue_isStructureDissectEnabled,
  ue_enumProperties = Dumper.Reflection.ue_enumProperties,
  ue_getPropertyOffset = Dumper.Offsets.ue_getPropertyOffset,
  ue_enumObjectProperties = Dumper.Reflection.ue_enumObjectProperties,
  ue_getObjectPropertyOffset = Dumper.Offsets.ue_getObjectPropertyOffset,
  ue_resolveObjectPropertyPath = Dumper.Offsets.ue_resolveObjectPropertyPath,
  ue_enumFunctions = Dumper.Functions.ue_enumFunctions,
  ue_findFunction = Dumper.Functions.ue_findFunction,
  ue_getFunctionMetadata = Dumper.Functions.ue_getFunctionMetadata,
  ue_patchFunction = Dumper.Patching.ue_patchFunction,
  ue_nopFunction = Dumper.Patching.ue_nopFunction,
  ue_restoreFunctionPatch = Dumper.Patching.ue_restoreFunctionPatch,
  ue_restoreAllFunctionPatches = Dumper.Patching.ue_restoreAllFunctionPatches,
  ue_getFunctionPatches = Dumper.Patching.ue_getFunctionPatches,
  ue_callFunction = Dumper.Invocation.ue_callFunction,
  ue_dumpFNames = Dumper.Dumps.ue_dumpFNames,
  ue_dumpTypes = Dumper.Dumps.ue_dumpTypes,
  ue_dumpObjects = Dumper.Dumps.ue_dumpObjects,
  ue_registerClassOffsets = Dumper.Offsets.ue_registerClassOffsets,
  ue_registerObjectOffsets = Dumper.Offsets.ue_registerObjectOffsets,
  ue_registerObjectPath = Dumper.Offsets.ue_registerObjectPath,
  ue_unregisterAllOffsets = Dumper.Offsets.ue_unregisterAllOffsets,
  ue_setMenuVisible = Dumper.Lifecycle.ue_setMenuVisible,
  ue_isMenuVisible = Dumper.Lifecycle.ue_isMenuVisible,
  ue_getDumper = Dumper.Lifecycle.ue_getDumper,
}

-- make api global
for functionName, implementation in pairs(Dumper.API) do

  if type( implementation ) == 'function' then
    _G[ functionName ] = implementation
  end

end

-- ceUEDumper = Dumper.API
