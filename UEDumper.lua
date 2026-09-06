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

local Dumper =
{
  Portable = {},
  Helpers = {},
  Lifecycle = {},
  Reflection = {},
  Structures = {},
  MetadataViews = {},
  Offsets = {},
  Functions = {},
  Invocation = {},
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
local typeCache = Dumper.State.typeCache

local PORTABLE_FILES =
{
  { name = 'ceUEDumper',                  path = [[autorun\UEDumper.lua]] },
  { name = 'ceUEDumper.UEBackend',    path = [[autorun\ceUEDumperModules\UEBackend.lua]] },
  { name = 'ceUEDumper.UEDumperCore', path = [[autorun\ceUEDumperModules\UEDumperCore.lua]] },
  { name = 'ceUEDumper.UESignatures', path = [[autorun\ceUEDumperModules\UESignatures.lua]] },
}

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// PORTABLE MODULES

-- very cool registerStructureDissectOverride2 stuff
if getCEVersion() < CEVersionSupported then
  ShowMessage('Please update CE to' .. CEVersionSupported .. ' or newer')
  error( 'update to Cheat Engine ' .. CEVersionSupported )
end

--- Reads a lua script attached to the cheat table as a file
-- @param fileName string
-- @return string|nil @ Source text when an attachment exists
function Dumper.Portable.getScriptFileAttached(fileName)
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
  local files, readError = Dumper.Portable.readPortableFiles()
  if not files then return nil, readError end

  local attached, attachError = pcall(   function()  for _, file in ipairs(files) do Dumper.Portable.replaceTableFile(file.name, file.source) end  end   )

  if not attached then return nil, 'Could not attach ceUEDumper: ' .. tostring(attachError) end

  return true
end


Dumper.Portable.registerModuleResolver( 'ceUEDumperModules.UEBackend', 'UEBackend.lua', 'ceUEDumper.UEBackend' )
Dumper.Portable.registerModuleResolver( 'ceUEDumperModules.UESignatures', 'UESignatures.lua', 'ceUEDumper.UESignatures' )

local Backend = require('ceUEDumperModules.UEBackend')

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// DUMPER CODE

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// HELPERS

--- Resolve and cache a reflected type address
-- @param typeNameOrAddress string|number @ reflected name or address
-- @param kind string|nil @ expected reflected metaclass name
-- @return number|nil @ reflected type address
function Dumper.Helpers.resolveType(typeNameOrAddress, kind)
  if type(typeNameOrAddress) == 'number' then return typeNameOrAddress end
  assert( type(typeNameOrAddress) == 'string', 'type must be a name or address' )

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

  if not selected then return nil, 'Unreal property was not found: ' .. requested end
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

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// STRUCT OFFSET REGISTRATION

--- Register offsets including dotted embedded-struct paths
-- @param typeNameOrAddress string|number @ reflected class or script struct
-- @param propertyNames table|nil @ selected paths, nil for all fields
-- @param namespace string|nil @ symbol namespace
-- @return table|nil @ registered offsets
-- @return string|nil @ error
function Dumper.Offsets.ue_registerStructOffsets(typeNameOrAddress, propertyNames, namespace)

  local properties, err = Dumper.Structures.ue_enumFlattenedProperties(typeNameOrAddress)
  if not properties then return nil, err end

  local typeAddress = Dumper.Helpers.resolveType(typeNameOrAddress)

  local typeName = Backend.objectName(typeAddress) or ('Struct_%X'):format(typeAddress) -- not wanted though

  return Dumper.Offsets.registerProperties( properties, typeName, propertyNames, namespace or '' )
end

--- Register cumulative inline-struct offsets relative to UObject
-- @param objectAddress number @ containing UObject instance
-- @param propertyNames table|nil @ readable dotted paths, nil for all
-- @param symbolPrefix string|nil @ exact symbol prefix; defaults to runtime class name
-- @return table|nil @ registered symbol offsets (not addresses)
-- @return string|nil @ metadata/alias error
function Dumper.Offsets.ue_registerObjectStructOffsets(objectAddress, propertyNames, symbolPrefix)

  local typeAddress = Backend.objectClass(objectAddress)
  if not typeAddress or typeAddress == 0 then return nil, 'Runtime UObject class unavailable' end

  local properties, err = Dumper.Structures.ue_enumFlattenedProperties(typeAddress)
  if not properties then return nil, err end

  local prefix = symbolPrefix or Backend.objectName(typeAddress) or ('Class_%X'):format(typeAddress)
  assert( type(prefix) == 'string' and prefix ~= '', 'symbol prefix must be non-empty' )

  return Dumper.Offsets.registerProperties( properties, prefix, propertyNames, '' )
end

--- Resolve one reflected class property offset
-- @param classNameOrAddress string|number @ reflected name or UClass address
-- @param propertyName string @ reflected property name
-- @return number|nil @ offset to the property
-- @return string|nil @ error
function Dumper.Offsets.ue_getPropertyOffset(classNameOrAddress, propertyName)
  assert( type(propertyName) == 'string' and propertyName ~= '' ,  'property name must be a non-empty string' )
  local enumProperties = Dumper.Reflection.ue_enumProperties
  local resolveProperty = Dumper.Helpers.resolveProperty

  local typeAddress = Dumper.Helpers.resolveType(classNameOrAddress)
  if not typeAddress then return nil, 'Unreal type not found' end

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

--- Resolve a property offset using UObject addr
-- @param objectAddress number @ UObject instance addr
-- @param propertyName string @ reflected property name
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

--- Register selected offsets as CE symbol by a class name
-- @param className string @ reflected class name
-- @param propertyNames string[]|nil @ selected names, nil for every field
-- @param namespace string|nil @ optional symbol namespace
-- @return table<string, number>|nil @ registered symbol-to-offset map
-- @return string|nil @ error
function Dumper.Offsets.ue_registerClassOffsets(className, propertyNames, namespace)
  assert( type(className) == 'string' and className ~= '' , 'class name must be a non-empty string' )

  local properties, errorMessage = Dumper.Reflection.ue_enumProperties(className)
  if not properties then return nil, errorMessage end

  return Dumper.Offsets.registerProperties( properties, className, propertyNames, namespace or '')
end

--- Register selected offsets as CE symbol using a UObject addr
-- @param objectAddress number @ UObject instance addr
-- @param propertyNames string[]|nil @ selected names, nil for every field
-- @param namespace string|nil @ optional namespace
-- @return table<string, number>|nil @ registered symbol-to-offset map
-- @return string|nil @ error
function Dumper.Offsets.ue_registerObjectOffsets(objectAddress, propertyNames, namespace)
  local classAddress = Backend.objectClass(objectAddress)
  if not classAddress then return nil, 'Runtime UObject class wasnt found' end

  local className = Backend.objectName(classAddress) or ('Class_%X'):format(classAddress) -- a fallback for class name, unwanted

  local properties, errorMessage = Dumper.Reflection.ue_enumProperties(classAddress)
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
  Dumper.State.typeCache = {}
  typeCache = Dumper.State.typeCache
  Backend.clearTypeLookupCache()
  Dumper.State.classMetadataStructure = nil
  Dumper.State.propertyMetadataStructure = nil
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

--- Whether the configured init readiness requirement is satisfied
-- @param config table|nil
-- @return boolean @ true when initialization is complete
-- @return string|nil @ error
function Dumper.Lifecycle.checkInitStatus(config)
  if not Backend.isReady() then return false end
  local status = Backend.status()

  if config.requireNames ~= false and not (status and status.namesReady) then
    return false, 'Unreal layout was found, but runtime names are unavailable'
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

  -- on by default
  if config.launchScanner ~= false then Backend.launch() end

  Backend.wait( config.timeout or INIT_WAIT_TIME )

  complete, completionError = Dumper.Lifecycle.checkInitStatus(config)
  if complete then return true end

  -- failure case
  local status = Backend.status()
  local reason = completionError or status.error

  if not reason and status.log and status.log ~= '' then
    reason = status.log:sub(-2000)
  end

  return false, 'Unreal reflection querying failed: ' .. (reason or 'NO MEANINGFUL ERROR PRODUCED')
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// CLASS/PROPERTY QUERIES

--- Find UClass by its short reflected name
-- @param className string @ class name w/o path
-- @return number|nil @ UClass address
function Dumper.Reflection.ue_findClass(className)
  return Dumper.Helpers.resolveType( className, 'Class' )
end

--- Enumerate reflected properties of a class (inherited fields included)
-- @param classNameOrAddress string|number @ reflected name or UClass address
-- @return table<string, table>|nil @ property metadata keyed by name
-- @return string|nil @ error
function Dumper.Reflection.ue_enumProperties(classNameOrAddress)

  -- are we good?
  local status = Backend.status()
  if status and status.namesReady == false then
    return nil, 'Unreal reflection unavailable; FName issue'
  end

  local address = Dumper.Helpers.resolveType(classNameOrAddress)

  if not address then return nil, 'Unreal class or script struct not found' end

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


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// STRUCTURE DISSECT

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

  if not typeAddress then return nil, 'Unreal type not found' end

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

--- Add reflected field, expanding TArray headers & elements
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

  local element = structure.addElement()
  element.Name = property.expansionError and fieldName .. ' [unresolved struct]' or fieldName
  element.Offset = elementOffset
  Dumper.Structures.configurePropertyElement(element, property)
end

--- Build a CE structure with embedded fields flattened at their true offsets
-- Does not replace CE's global Unreal renderer or install automatic callbacks
-- @param typeNameOrAddress string|number @ reflected class or script struct
-- @return userdata|nil @ CE structure
-- @return string|nil @ metadata error
function Dumper.Structures.ue_createStructureFromType(typeNameOrAddress, baseAddress)
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
-- @param objectAddress number @ live UObject pointer
-- @return userdata|nil @ CE structure
-- @return string|nil @ error
function Dumper.Structures.ue_createStructureFromObject(objectAddress)
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


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// REFLECTION METADATA VIEWS

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
    { 'Script.Data [' .. scriptKind .. ']', metadata.scriptOffset, vtPointer },
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


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// UFUNCTION

--- Enumerate UFunctions declared directly byreflected class/struct
-- Inherited functions can be obtained by calling this for each SuperStruct
-- @param classNameOrAddress string|number @ owning UClass/UStruct
-- @return table<string, number>|nil @ names mapped to UFunction descriptors
-- @return string|nil @ error
function Dumper.Functions.ue_enumFunctions(classNameOrAddress)

  local typeAddress = Dumper.Helpers.resolveType(classNameOrAddress)
  if not typeAddress then return nil, 'Unreal class or script struct not found' end
  
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
-- Unreal-managed values requiring Ctors/Dtors are rejected before invocation
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
  ue_findStruct = Dumper.Reflection.ue_findStruct,
  ue_enumFlattenedProperties = Dumper.Structures.ue_enumFlattenedProperties,
  ue_registerStructOffsets = Dumper.Offsets.ue_registerStructOffsets,
  ue_registerObjectStructOffsets = Dumper.Offsets.ue_registerObjectStructOffsets,
  ue_createStructureFromType = Dumper.Structures.ue_createStructureFromType,
  ue_createStructureFromObject = Dumper.Structures.ue_createStructureFromObject,
  ue_enumProperties = Dumper.Reflection.ue_enumProperties,
  ue_getPropertyOffset = Dumper.Offsets.ue_getPropertyOffset,
  ue_enumObjectProperties = Dumper.Reflection.ue_enumObjectProperties,
  ue_getObjectPropertyOffset = Dumper.Offsets.ue_getObjectPropertyOffset,
  ue_resolveObjectPropertyPath = Dumper.Offsets.ue_resolveObjectPropertyPath,
  ue_enumFunctions = Dumper.Functions.ue_enumFunctions,
  ue_findFunction = Dumper.Functions.ue_findFunction,
  ue_getFunctionMetadata = Dumper.Functions.ue_getFunctionMetadata,
  ue_callFunction = Dumper.Invocation.ue_callFunction,
  ue_registerClassOffsets = Dumper.Offsets.ue_registerClassOffsets,
  ue_registerObjectOffsets = Dumper.Offsets.ue_registerObjectOffsets,
  ue_registerObjectPath = Dumper.Offsets.ue_registerObjectPath,
  ue_unregisterAllOffsets = Dumper.Offsets.ue_unregisterAllOffsets,
}

-- make api global
for functionName, implementation in pairs(Dumper.API) do

  if type( implementation ) == 'function' then
    _G[ functionName ] = implementation
  end

end

-- ceUEDumper = Dumper.API
