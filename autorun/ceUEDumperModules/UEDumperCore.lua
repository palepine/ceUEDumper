--[[
  This file is part of ceUEDumperModules supplying the reflection backend.
  
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

  Derived from Dark Byte's (Eric Heijnen) UnrealEngineTools.

  Copyright (c) 2026 Dark Byte

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
]]

--[[
  Thats a modified version of Dark Byte's UETools script which I have heavily refactored and tweaked with an LLM
  The original function names are left unchanged with some changes made to the implementations
]]

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.STATE AND DEPENDENCIES

local dependencies = ... or {}
local UESignatures = dependencies.UESignatures
local ceUEDumperResources = dependencies.ceUEDumperResources
local ceUEDumperRegisterSymbol = dependencies.ceUEDumperRegisterSymbol

local Core =
{
  Runtime = {}, -- logging, thread/debug execution helpers
  Modules = {}, -- module bounds, address ownership, classification
  Reflection = {}, -- names, properties, inheritance
  PropertyLayout = {}, -- reflection member-layout inference
  Engine = {}, -- GEngine/GWorld scan
  Memory = {}, -- vtable and executable-address validation
  Objects = {}, -- GUObjectArray, UObject scan
  Names = {}, -- name decoding, caching
  NameScan = {}, -- signature/structural/legacy FNamePool scan
  Signatures = {}, -- AOB signatures, target decoding
  CustomTypes = {}, -- CE FName, verifier custom types
  Persistence = {}, -- saved-layout loading, storage
  Menu = {}, -- GUI behavior
  Scanner = {}, -- initialization pipeline orchestration
  Process = {}, -- process detection/open hook
  API = {}, -- exports
  State = {}, -- core status
}

local debugUEInfoScanner = false
local PTR_SIZE = 0x8

Core.State.lastScannerError = nil
Core.State.scannerRunning = false
Core.State.signatureSelection = 'first'

local CUEDEFS -- UEDEFS

local UObjectArray_Verifier_Type

local resources = ceUEDumperResources or { customTypes = {} }
resources.options = resources.options or { showReflectionMetadata = false }

local PROPERTY_LAYOUTS =
  {
    {
      label = 'UE4 UProperty PropertyLink', -- for feedback
      root = 0x58, -- offset in UClass/UStruct containing the first property pointer
      next = 0x48, -- offset in each property node containing the next-property pointer
      name = 0x18, -- offset in the property node containing its FName
      class = 0x10, -- offset containing UClass* or FFieldClass*
      offset = 0x44, -- offset containing FProperty::Offset_Internal
      objectClass = true, -- identifies how the property-type name must be resolved
      alternateChain = false, -- identifies whether root belongs to PropertyLinkAlt/ChildProperties
    },
    {
      label = 'UE4 UField Children',
      root = 0x38,
      next = 0x28,
      name = 0x18,
      class = 0x10,
      offset = 0x44,
      objectClass = true,
      alternateChain = true,
    },
    {
      label = 'UE4.22-4.24 UProperty PropertyLink',
      root = 0x68,
      next = 0x50,
      name = 0x18,
      class = 0x10,
      offset = 0x44,
      objectClass = true,
      alternateChain = false,
    },
    {
      label = 'UE4 shifted UField Children',
      root = 0x48,
      next = 0x28,
      name = 0x18,
      class = 0x10,
      offset = 0x44,
      objectClass = true,
      alternateChain = true,
    },
    {
      label = 'Compact FField ChildProperties',
      root = 0x50,
      next = 0x18,
      name = 0x20,
      class = 0x8,
      offset = 0x44,
      fieldClass = true,
      alternateChain = true,
    },
    {
      label = 'Compact FField PropertyLink',
      root = 0x70,
      next = 0x48,
      name = 0x20,
      class = 0x8,
      offset = 0x44,
      fieldClass = true,
      alternateChain = false,
    },
    {
      label = 'UE4.25+/UE5 ChildProperties',
      root = 0x50,
      next = 0x20,
      name = 0x28,
      class = 0x8,
      offset = 0x4C,
      fieldClass = true,
      alternateChain = true,
    },
    {
      label = 'UE4.25+/UE5 PropertyLink',
      root = 0x70,
      next = 0x58,
      name = 0x28,
      class = 0x8,
      offset = 0x4C,
      fieldClass = true,
      alternateChain = false,
    },
    {
      label = 'Case-preserving FProperty PropertyLink',
      root = 0x70,
      next = 0x60,
      name = 0x28,
      class = 0x8,
      offset = 0x4C,
      fieldClass = true,
      alternateChain = false,
    },
  }

local MODERN_FIELD_LISTS =
  {
    {
      rootOffset = 0x50,
      nextOffset = 0x20,
      label = 'ChildProperties'
    },
    {
      rootOffset = 0x70,
      nextOffset = 0x58,
      label = 'PropertyLink'
    },
  }



local cUObjectArrayVerifierType = [[{$c}
//returns 1 if the type matches
char TypeName[]="ceUEDumper UObjectArray Verifier";
int ByteSize=16;
char CallMethod=1; //cdecl

int PreferedAlignment=0x10;


#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct
{
  int val1;
  int val2;
  int val3;
  int zero;
} *pdata;

__cdecl size_t ConvertRoutine(pdata data, unsigned long long address)
{
  int r=1;
  //if (data->val1<100) return 0; //no tiny games
  if (data->zero) return 0;
  if (data->val3!=data->val1) return 0;
  if ((data->val2) != ((data->val1)-1)) return 0;

  //still here
  return 1;
}

__cdecl void ConvertBackRoutine(size_t input, unsigned long long address, unsigned char *output)
{
  //nope
}

{$asm}]]


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.MODULES

--- Return bounds for the process main module
-- @return number|nil @ module start addr
-- @return number|nil @ exclusive module end addr
function Core.Modules.ue_getMainModuleBoundsInternal()
  local modules = enumModules()

  local mainModule = modules and modules[1]

  if not mainModule or not mainModule.Address or not mainModule.Size then
    return nil, nil
  end

  return mainModule.Address, mainModule.Address + mainModule.Size
end

--- Get the address module
-- @param address number|nil @ target addr
-- @return table|nil @ module descriptor by enumModules
function Core.Modules.ue_getAddressModuleInternal(address)
  if type(address) ~= 'number' then return nil end

  for _, module in ipairs( enumModules() or {} ) do

    if module.Address and module.Size and address >= module.Address and address < module.Address + module.Size then
      return module
    end

  end

  return nil
end

--- categorize module for signature scanning
-- The executable is scanned first, other recognized modules follow
-- @param module table|nil @ module descriptor returned by enumModules
-- @return string @ main, unreal, thirdparty, unknown
function Core.Modules.ue_classifyModuleInternal(module)
  if not module then return 'unknown' end

  local modules = enumModules() or {}
  -- main first
  if modules[1] and module.Address == modules[1].Address then return 'main' end

  -- second
  local name = ( extractFileName( module.PathToFile or '' ) or '' ):lower()
  if name:find( 'coreuobject' , 1 , true ) or name:find( 'unrealeditor' , 1 , true ) or name:find( 'engine%-win64' ) then return 'unreal' end

  -- avoiding these
  local thirdPartyMarkers =
  {
    'eossdk','opengl32','d3dscache','wshbth','dxcore','propsys',
    'kernel32','kernelbase','ntdll','user32','ucrtbase','msvcp','vcruntime',
  }

  for _, marker in ipairs(thirdPartyMarkers) do
    if name:find( marker , 1 , true ) then return 'thirdparty' end
  end

  return 'unknown'
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.RUNTIME

--- logger
function Core.Runtime.log(str)

  if CUEDEFS == nil then
    CUEDEFS = {}
    CUEDEFS.processid = getOpenedProcessID()
  end

  if CUEDEFS.log == nil then
    CUEDEFS.log = ''
  end

  CUEDEFS.log = CUEDEFS.log .. str .. '\n\r'
end

--- Waits for a CE thread
-- @param thread userdata @ CE thread object
-- @param timeout number @ max wait in millis
-- @return boolean|nil @ wait result
function Core.Runtime.ue_waitForThreadInternal(thread, timeout)
  if type(thread.waitForThread) == 'function' then
    return thread.waitForThread(timeout)
  elseif type(thread.waitfor) == 'function' then
    return thread.waitfor(timeout)
  elseif type(thread.waitFor) == 'function' then
    return thread.waitFor(timeout)
  end
  error('No supported thread wait method in CE')
end

--- Execute func with Lua debugging suspended for performance reasons
-- @param callback function @ func to exec
-- @return any @ callback return values
function Core.Runtime.withoutLuaDebug(callback)
  -- as stated "disabling debug here for performance reasons"
  
  local originalState = disableLuaDebug()
  local results = table.pack( pcall( callback ) )
  restoreLuaDebug( originalState )

  if not results[1] then error( results[2] , 0 ) end
  
  return table.unpack( results , 2 , results.n )
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.REFLECTION

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// UOBJECT ACCESS

--- Return UObject name
-- @param objectAddress number @ UObject address
-- @return string|nil @ reflected object name
-- @return string|nil @ error
function Core.Reflection.UObject_getName(UObjectAddress)

  if not CUEDEFS or not CUEDEFS.UObject or CUEDEFS.UObject.Name == nil or not CUEDEFS.IndexToName then
    return nil, 'CUEDEFS.UObject.Name not initialized yet'
  end

  if type(UObjectAddress) ~= 'number' or UObjectAddress == 0 then return nil end

  -- Validate the virtual call chain, previously vtable had to just live in the main module
  local vftableptr = readPointer(UObjectAddress)
  if not vftableptr or vftableptr == 0 then return nil end

  local firstFunction = readPointer(vftableptr) -- TODO: executable mem
  if not firstFunction or firstFunction == 0 or readByte(firstFunction) == nil then return nil end

  local value = readQword( UObjectAddress + CUEDEFS.UObject.Name )
  if value == nil then return nil end

  local index = value & 0xFFFFFFFF -- low
  local number = value >> 32
  local name = CUEDEFS.IndexToName[index]

  if name and number > 0 then
    name = name .. '_' .. number
  end

  return name
end

--- Enumerate UObject instance reflected properties
-- @param objectAddress number @ UObject address
-- @return table<string, table>|nil @ property metadata indexed by name
-- @return string|nil @ error
function Core.Reflection.UObject_enumProperties(address)
  local class = readPointer( address + CUEDEFS.UObject.Class )

  if class then   return Core.Reflection.UClass_enumProperties(class)
  else            return nil , 'Failure to read class field'
  end
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// PROPERTY ENUMERATION

--- Parse property-list head and offset linking its nodes
-- @param classAddress number @ UClass address
-- @param useAlternatePropertyChain boolean @ select the alternate chain
-- @return number|nil @ first property address
-- @return number|nil @ next-pointer offset
-- @return string|nil @ error
function Core.Reflection.parsePropertyChainHead(classAddress, useAlternatePropertyChain)
  
  -- Select the linked-list root in the UClass/UStruct
  -- The primary chain normally represents PropertyLink
  -- The alternate chain normally represents ChildProperties or another found field-list root
  local chainName = 'Primary'
  local rootOffset = CUEDEFS.UClass.PropertyLink

  if useAlternatePropertyChain then
    chainName = 'Alternate'
    rootOffset = CUEDEFS.UClass.PropertyLinkAlt
  end

  if type(rootOffset) ~= 'number' then return nil, nil, chainName .. ' property-list root offset is unavailable' end

  local firstPropertyAddress = readPointer( classAddress + rootOffset )

  if not firstPropertyAddress or firstPropertyAddress == 0 then return nil, nil, chainName .. ' property list is empty or unreadable' end

  -- Use the alternate link only when its found offset is usable
  local nextOffset = CUEDEFS.FProperty.PropertyLinkNext
  local alternateNextOffset = CUEDEFS.FField and CUEDEFS.FField.PropertyLinkNext

  if useAlternatePropertyChain and type(alternateNextOffset) == 'number' then
    nextOffset = alternateNextOffset
  end

  if type(nextOffset) ~= 'number' then
    return nil, nil, 'Property-list next-pointer offset is unavailable'
  end

  return firstPropertyAddress, nextOffset
end

--- Read one reflected property name and metadata
-- Unresolved property name is skipped without an error
-- @param propertyAddress number @ reflected property node address
-- @return string|nil @ property name
-- @return table|nil @ offset, address, reflected type, and optional size
-- @return string|nil @ error
function Core.Reflection.readPropertyMetadata(propertyAddress)
  local layout = CUEDEFS.FProperty
  local namesByIndex = CUEDEFS.IndexToName

  -- read the property's FName index and resolve it through FNamePool
  local propertyNameIndex = readInteger( propertyAddress + layout.Name )
  local propertyName = propertyNameIndex and namesByIndex[propertyNameIndex]

  -- ignore nodes whose names cannot be decoded
  if not propertyName then return nil end

  -- Offset_Internal is relative to the owning object/struct
  local propertyOffset = readInteger( propertyAddress + layout.Offset )

  -- the property node's class describes its reflected property type
  -- such as IntProperty, FloatProperty or ObjectProperty
  local propertyClassAddress = readPointer( propertyAddress + layout.Class )
  if not propertyClassAddress or propertyClassAddress == 0 then return nil, nil, ('Property class unreadable: %s'):format(propertyName) end

  local propertyTypeNameIndex = readInteger( propertyClassAddress + CUEDEFS.FFieldClass.Name )
  if propertyTypeNameIndex == nil then return nil, nil, ('Property type name index unreadable: %s'):format(propertyName) end

  local propertyMetadata =
  {
    offset = propertyOffset, -- 0x...
    propertyAddress = propertyAddress, -- 0x...
    propertyType = namesByIndex[ propertyTypeNameIndex ], -- e.g. IntProperty
  }

  -- some found layouts expose ElementSize, others don't
  if type(layout.Size) == 'number' then
    propertyMetadata.size = readInteger( propertyAddress + layout.Size )
  end

  if propertyMetadata.propertyType == 'BoolProperty' and type(layout.BitMaskField) == 'number' then
    propertyMetadata.byteMask = readByte( propertyAddress + layout.BitMaskField + 2 )
  end

  return propertyName, propertyMetadata
end

--- Append named properties from a linked list to the result map
-- Stops at a null ptr, repeated address or traversal limit
-- @param firstPropertyAddress number @ first property node
-- @param nextOffset number @ next-pointer offset within each node
-- @param propertiesByName table @ result map to extend
-- @return boolean|nil @ true when traversal completes without a decoding error
-- @return string|nil @ error
function Core.Reflection.collectPropertyChain(firstPropertyAddress, nextOffset, propertiesByName)
  local readPropertyMetadata = Core.Reflection.readPropertyMetadata
  
  -- Prevent malformed reflection data from causing an infinite traversal
  local visitedAddresses = {}
  local currentAddress = firstPropertyAddress
  local maximumPropertyCount = 0x10000

  for propertyIndex = 1, maximumPropertyCount do

    if not currentAddress or currentAddress == 0 then break end

    if visitedAddresses[currentAddress] then break end

    visitedAddresses[currentAddress] = true

    local propertyName, propertyMetadata, errorMessage = readPropertyMetadata(currentAddress)
    if errorMessage then return nil, errorMessage end

    -- later entries replace inherited properties with the same name
    if propertyName then
      -- because superclasses were processed first,
      -- this assignment lets a property declared by the derived class
      -- replace an inherited entry
      propertiesByName[ propertyName ] = propertyMetadata
    end

    -- advance to the next reflected property node
    currentAddress = readPointer( currentAddress + nextOffset )
  end

  return true
end

--- Enumerate reflected properties of a UClass and its superclasses
-- parent properties are collected first; derived properties override them
-- @param classAddress number @ UClass address
-- @param useAlternatePropertyChain boolean @ select the alternate property chain
-- @param propertiesByName table|nil @ shared recursive result map
-- @param visitedTypes table|nil @ shared ancestry cycle/depth guard
-- @return table<string, table>|nil @ property metadata indexed by name
-- @return string|nil @ error
function Core.Reflection.UClass_enumProperties(classAddress, useAlternatePropertyChain, propertiesByName, visitedTypes)
  local propertyLayout = CUEDEFS and CUEDEFS.FProperty

  -- FProperty::Offset_Internal must be known before field offsets can be read
  if not propertyLayout or propertyLayout.Offset == nil then return nil, 'CUEDEFS.FProperty.Offset is nil' end

  --get the parent fields as well? (remove duplicates)
  -- create the result map on the initial call. Recursive calls share it
  propertiesByName = propertiesByName or {}
  visitedTypes = visitedTypes or {}

  if visitedTypes[classAddress] then return nil, 'Cyclic SuperStruct chain' end
  if #visitedTypes >= 128 then return nil, 'SuperStruct depth limit exceeded' end

  visitedTypes[classAddress] = true
  visitedTypes[#visitedTypes + 1] = classAddress

  local enumProperties = Core.Reflection.UClass_enumProperties
  local parsePropertyChainHead = Core.Reflection.parsePropertyChainHead
  local collectPropertyChain = Core.Reflection.collectPropertyChain

  -- collect inherited fields first. distinguish a null list from unreadable metadata
  -- so an incomplete ancestry is not presented as a complete result
  local superStructOffset = CUEDEFS.UClass.SuperStruct

  if superStructOffset then
    local superclassAddress = readPointer( classAddress + superStructOffset )
    if superclassAddress == nil then return nil, 'SuperStruct pointer is unreadable' end

    if superclassAddress and superclassAddress ~= 0 then
      -- a root or intermediate superclass may legitimately have an empty list
      -- its ancestors are still collected before the concrete type
      local inherited, inheritanceError = enumProperties( superclassAddress, useAlternatePropertyChain, propertiesByName, visitedTypes )

      if not inherited then return nil, inheritanceError end
    end

  end

  local firstPropertyAddress, nextOffset, chainError = parsePropertyChainHead( classAddress, useAlternatePropertyChain )

  -- a derived type can declare no fields while still inheriting many
  -- null list heads are empty, not a reason to discard the parent map
  if chainError then
    local rootOffset = CUEDEFS.UClass.PropertyLink

    if useAlternatePropertyChain then rootOffset = CUEDEFS.UClass.PropertyLinkAlt end

    if type(rootOffset) == 'number' and readPointer( classAddress + rootOffset ) == 0 then
      return propertiesByName
    end

    return nil, chainError
  end

  local collected, collectionError = collectPropertyChain( firstPropertyAddress, nextOffset, propertiesByName )
  if not collected then return nil, collectionError end
  
  -- byteMask, offset, propertyAddress, propertyType, size
  return propertiesByName
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// PROPERTY-LAYOUT PROBING

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// FIELD-TYPE RESOLUTION

--- Resolve the reflected metaclass name for a candidate field
-- @param field number @ candidate UProperty/FProperty addr
-- @param layout table @ candidate layout descriptor
-- @return string|nil @ reflected property class name
function Core.Reflection.resolveFieldTypeName(field, layout)
  --[[ layouts
    UProperty < UE4.25 legacy
    ├─ UObject
    │  ├─ vtable
    │  ├─ ObjectFlags
    │  ├─ InternalIndex
    │  ├─ UClass* ClassPrivate -- UClass named eg 'IntProperty'
    │  ├─ FName NamePrivate
    │  └─ UObject* OuterPrivate
    ├─ UField
    │  └─ UField* Next
    └─ UProperty
      ├─ ArrayDim
      ├─ ElementSize
      ├─ PropertyFlags
      ├─ ...
      ├─ Offset_Internal
      ├─ PropertyLinkNext
      ├─ NextRef
      └─ ...

    FField - new
    ├─ vtable
    ├─ FFieldClass* ClassPrivate -- whose first FName identifies eg 'IntProperty'
    ├─ FFieldVariant Owner
    ├─ ...
    ├─ FName NamePrivate
    ├─ EObjectFlags FlagsPrivate
    FProperty : FField
    ├─ ArrayDim
    ├─ ElementSize
    ├─ PropertyFlags
    ├─ ...
    ├─ Offset_Internal
    ├─ PropertyLinkNext
    ├─ NextRef
    └─ ...
  ]]

  local classAddress = readPointer( field + layout.class )
  if not classAddress or classAddress == 0 then return nil end

  -- legacy (<4.25) UProperty derives from UObject. ClassPrivate: UClass, its UObject name identifies property type
  if layout.objectClass then return Core.Reflection.UObject_getName(classAddress) end

  -- 4.25+ FProperty derives from FField, not UObject
  -- FField::ClassPrivate points to FFieldClass that begins with an FName property
  local classNameIndex = readInteger(classAddress)
  return classNameIndex and CUEDEFS.IndexToName[ classNameIndex ] or nil
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// SUPERCLASS-CHAIN VALIDATION

--- Follow a SuperStruct chain and validate its class relationships
-- @param classAddress number @ starting UClass addr
-- @param superStructOffset number @ candidate SuperStruct byte offset
-- @return number[]|nil @ ordered class addresses, or nil when invalid
function Core.Reflection.buildSuperclassChain(classAddress, superStructOffset)
  local classPointerOffset = CUEDEFS.UObject.Class

  -- every UClass object should have the same runtime metaclass normally UClass itself
  -- this value is used to validate every parent in the chain
  local expectedMetaClass = readPointer( classAddress + classPointerOffset )
  if not expectedMetaClass or expectedMetaClass == 0 then return nil end

  -- the first entry is the class whose inheritance layout is being tested
  local classAddresses = { classAddress }

  -- track every class address to reject circular superclass relationships
  local visitedAddresses = { [classAddress] = true }
  local currentClassAddress = classAddress
  local maximumInheritanceDepth = 32

  for _=1, maximumInheritanceDepth do
    local superclassAddress = readPointer( currentClassAddress + superStructOffset )

    -- a null superclass marks a properly terminated root class
    if not superclassAddress or superclassAddress == 0 then
      return classAddresses
    end

    -- a repeated address means this candidate offset
    -- produced a cycle rather than a valid inheritance chain
    if visitedAddresses[superclassAddress] then return nil end

    -- each entry in a UClass inheritance chain must itself be a UClass object
    -- therefore its UObject::Class pointer must match the starting class's metaclass pointer
    local superclassMetaClass = readPointer( superclassAddress + classPointerOffset )
    if superclassMetaClass ~= expectedMetaClass then return nil end

    visitedAddresses[ superclassAddress ] = true
    classAddresses[ #classAddresses + 1 ] = superclassAddress
    currentClassAddress = superclassAddress
  end

  -- the candidate did not terminate within the traversal limit
  return nil
end

--- Build & score a candidate UClass inheritance chain (heuristic)
-- Object base is quite fair, kind of overkill
-- @param classAddress number @ starting UClass address
-- @param candidateSuperStructOffset number @ candidate SuperStruct byte offset
-- @return number[]|nil @ ordered class addresses, beginning with classAddress
-- @return number @ confidence score, zero when invalid
function Core.Reflection.evaluateSuperclassChain(classAddress, candidateSuperStructOffset)

  local superclassChain = Core.Reflection.buildSuperclassChain( classAddress, candidateSuperStructOffset )

  if not superclassChain then return nil, 0 end

  local rootClassAddress = superclassChain[ #superclassChain ]
  local rootClassName = Core.Reflection.UObject_getName(rootClassAddress)

  local rootObjectBonus = 1000
  local knownOffsetBonus = 100

  -- a longer chain is slightly stronger evidence than a single isolated class
  local confidenceScore = #superclassChain

  -- normal UClass should have Object as a base (what we are interested in, ok)
  if rootClassName == 'Object' then
    confidenceScore = confidenceScore + rootObjectBonus
  end

  -- prefer the already found SuperStruct offset when it remains valid
  local knownSuperStructOffset = CUEDEFS.UClass and CUEDEFS.UClass.SuperStruct

  if candidateSuperStructOffset == knownSuperStructOffset then
    confidenceScore = confidenceScore + knownOffsetBonus
  end

  return superclassChain, confidenceScore
end

--- Select the highest-scoring superclass chain for property probing
--
-- Fall back to the starting class when no candidate chain is accepted
-- @param classAddress number @ starting UClass/UScriptStruct address
-- @return number[] @ selected class hierarchy
-- @return number|nil @ selected SuperStruct offset
function Core.Reflection.selectProbeClassHierarchy(classAddress)
  local evaluateSuperclassChain = Core.Reflection.evaluateSuperclassChain
  local candidateSuperStructOffsets = { 0x30, 0x40 }
  local knownOffset = CUEDEFS.UClass and CUEDEFS.UClass.SuperStruct

  if type(knownOffset) == 'number' then
    table.insert( candidateSuperStructOffsets, 1, knownOffset )
  end

  local testedSuperStructOffsets = {}
  local selectedSuperclassHierarchy = { classAddress }
  local selectedSuperStructOffset
  local highestScore = 0

  for _, candidateOffset in ipairs( candidateSuperStructOffsets ) do

    if not testedSuperStructOffsets[candidateOffset] then
      testedSuperStructOffsets[candidateOffset] = true

      local hierarchy, score = evaluateSuperclassChain( classAddress, candidateOffset )

      if hierarchy and score > highestScore then
        selectedSuperclassHierarchy = hierarchy
        selectedSuperStructOffset = candidateOffset
        highestScore = score
      end
    end

  end

  return selectedSuperclassHierarchy, selectedSuperStructOffset
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// PROPERTY-CHAIN PROBES

--- Inspect one field & update the current layout's evidence and results
-- Fields contribute feedback evidence even when they are not accepted
-- @param fieldAddress number @ candidate field node address
-- @param layout table @ candidate reflection layout
-- @param probe table @ mutable counters and property map for this layout
-- @return nil
function Core.Reflection.probePropertyField(fieldAddress, layout, probe)
  local fieldNameIndex = readInteger( fieldAddress + layout.name )
  local fieldName = fieldNameIndex and CUEDEFS.IndexToName[fieldNameIndex]

  local propertyTypeName = Core.Reflection.resolveFieldTypeName( fieldAddress, layout )
  local propertyOffset = readInteger( fieldAddress + layout.offset )

  local hasPropertyType = propertyTypeName and propertyTypeName:endsWith('Property')

  local hasValidOffset = type(propertyOffset) == 'number' and propertyOffset >= 0 and propertyOffset < 0x100000

  -- count each kind of evidence independently
  if fieldName then probe.namedFieldCount = probe.namedFieldCount + 1 end

  if hasPropertyType then probe.typedFieldCount = probe.typedFieldCount + 1 end

  if hasValidOffset then
    probe.validOffsetFieldCount = probe.validOffsetFieldCount + 1
  end

  -- only fully validated fields become resolved properties
  if not fieldName then return end
  if not hasPropertyType then return end
  if not hasValidOffset then return end

  probe.propertiesByName[fieldName] =
  {
    offset = propertyOffset,
    propertyAddress = fieldAddress,
    propertyType = propertyTypeName,
  }
end

--- Traverse one class's candidate field list
-- All classes in a layout probe share the visited set and 4096-node limit
-- @param classAddress number @ class owning the candidate list
-- @param layout table @ candidate reflection layout
-- @param probe table @ mutable traversal state and results
-- @return nil
function Core.Reflection.probePropertyChain(classAddress, layout, probe)
  local probePropertyField = Core.Reflection.probePropertyField
  local fieldAddress = readPointer( classAddress + layout.root )
  local maximumFieldCount = 4096

  while probe.traversedFieldCount < maximumFieldCount do
    if not fieldAddress or fieldAddress == 0 then return end
    if probe.visitedFieldAddresses[fieldAddress] then return end

    probe.visitedFieldAddresses[fieldAddress] = true
    probe.traversedFieldCount = probe.traversedFieldCount + 1

    probePropertyField( fieldAddress, layout, probe )

    fieldAddress = readPointer( fieldAddress + layout.next )
  end
end

--- Probe and score one property layout across the selected class hierarchy
-- @param classHierarchy number[] @ ordered class addresses to inspect
-- @param layout table @ candidate reflection layout
-- @return table @ property map, evidence counters, confidence score
function Core.Reflection.probePropertyLayout(classHierarchy, layout)
  local probePropertyChain = Core.Reflection.probePropertyChain
  
  local probe =
  {
    propertiesByName = {},
    visitedFieldAddresses = {},
    traversedFieldCount = 0,
    namedFieldCount = 0,
    typedFieldCount = 0,
    validOffsetFieldCount = 0,
    resolvedPropertyCount = 0,
  }

  for index = #classHierarchy, 1, -1 do
    -- root first, concrete type last: derived declarations win name clashes
    probePropertyChain( classHierarchy[index], layout, probe )
  end

  -- count unique names, not individual field nodes
  for _ in pairs(probe.propertiesByName) do
    probe.resolvedPropertyCount = probe.resolvedPropertyCount + 1
  end

  probe.score = probe.resolvedPropertyCount * 100
                + probe.typedFieldCount * 10
                + probe.validOffsetFieldCount

  return probe
end

--- Probe known UObject/UField and FField property layouts for a class
-- Unreal 4.23/4.24 can use the modern FNamePool
-- while reflection properties are still UObject-based UProperty instances
--
-- FNamePool format alone cannot select between legacy UProperty and modern FProperty layouts
-- It's used when PropertyLink and Alt doesn't produce properties
-- @param classAddress number @ UClass/UScriptStruct address
-- @return table<string, table>|nil @ best named property map
-- @return string @ feedback, including the selected layout when successful
function Core.Reflection.probeClassProperties(classAddress)
  --[[ the flow of this fallback
    selectProbeClassHierarchy
    ├─ obtain candidate SuperStruct offsets
    ├─ evaluateSuperclassChain for every candidate
    │  ├─ buildSuperclassChain
    │  │  ├─ follow the candidate superclass pointer
    │  │  ├─ reject cycles
    │  │  ├─ require every parent to have the same UClass metaclass
    │  │  └─ require the chain to terminate at a null superclass
    │  └─ assign confidence
    │     ├─ longer valid inheritance chains are favored
    │     ├─ chain ending in Object is are definitive
    │     └─ already-known SuperStruct offset increments guess
    └─ return the selected class hierarchy and SuperStruct offset

    for each PROPERTY_LAYOUTS entry
    └─ probePropertyLayout
        ├─ walk the selected hierarchy from base class to derived class
        ├─ probePropertyChain for each class
        │  ├─ read the candidate root property pointer
        │  ├─ stop at repeated property addrs / after the hard limit
        │  └─ probePropertyField for each property node
        │     ├─ resolve the field name through IndexToName
        │     ├─ resolve the property type through UClass or FFieldClass
        │     ├─ read Offset_Internal
        │     ├─ collect independent evidence counters
        │     └─ retain only completely validated named properties
        ├─ count unique resolved property names
        └─ calc layout confidence score

    ─ select the best layout (resolved at least one property); reject on no produced usable properties
  ]]
  
  local probePropertyLayout = Core.Reflection.probePropertyLayout
  local classHierarchy, superStructOffset = Core.Reflection.selectProbeClassHierarchy(classAddress)
  
  local feedback = {}

  if superStructOffset then
    feedback[#feedback + 1] = ('SuperStruct 0x%X selected with %d classes'):format( superStructOffset, #classHierarchy )
  end

  local selectedProbe
  local selectedLayout
  local selectedLayoutLabel
  local highestScore = 0

  for _, layout in ipairs( PROPERTY_LAYOUTS ) do
    local probe = probePropertyLayout( classHierarchy, layout )

    feedback[ #feedback + 1 ] = ( '%s=%d traversed/%d named/%d typed/%d valid offsets/%d properties' )
    :format( layout.label, probe.traversedFieldCount, probe.namedFieldCount, probe.typedFieldCount, probe.validOffsetFieldCount, probe.resolvedPropertyCount )

    if probe.resolvedPropertyCount > 0 and probe.score > highestScore then
      selectedProbe = probe
      selectedLayout = layout
      selectedLayoutLabel = layout.label
      highestScore = probe.score
    end

  end

  local feedbackText = table.concat( feedback, '; ' )

  if not selectedProbe then return nil, feedbackText end

  -- keep underlying reflection layout selected by the probe, should not do it again
  CUEDEFS.UClass = CUEDEFS.UClass or {}
  CUEDEFS.FProperty = CUEDEFS.FProperty or {}
  CUEDEFS.FField = CUEDEFS.FField or {}
  CUEDEFS.FFieldClass = CUEDEFS.FFieldClass or {}

  CUEDEFS.UClass.SuperStruct = superStructOffset or CUEDEFS.UClass.SuperStruct
  CUEDEFS.FProperty.Class = selectedLayout.class
  CUEDEFS.FProperty.Name = selectedLayout.name
  CUEDEFS.FProperty.Offset = selectedLayout.offset

  if selectedLayout.alternateChain then
    CUEDEFS.UClass.PropertyLinkAlt = selectedLayout.root
    CUEDEFS.FField.PropertyLinkNext = selectedLayout.next
  else
    CUEDEFS.UClass.PropertyLink = selectedLayout.root
    CUEDEFS.FProperty.PropertyLinkNext = selectedLayout.next
  end

  if selectedLayout.objectClass then    CUEDEFS.FFieldClass.Name = CUEDEFS.UObject.Name
  else                                  CUEDEFS.FFieldClass.Name = 0 -- immediate
  end
  CUEDEFS.ProbedPropertyLayout = selectedLayout.label

  return  selectedProbe.propertiesByName, 'Selected ' .. selectedLayoutLabel .. '; ' .. feedbackText
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// SUPERSTRUCT SCAN

--- Return the reflected inheritance names for FField class descriptor
-- @param fieldAddress number @ FField/UProperty address
-- @return string[]|nil @ ordered class names beginning with the concrete type
function Core.Reflection.getSuperListFromField(fieldAddress)
  if not Core.Memory.isVTable( readPointer(fieldAddress) ) then return nil end

  local nameIndex = readQword( fieldAddress + CUEDEFS.FField.Name )
  local className = CUEDEFS.IndexToName[nameIndex]

  if not className then return nil end

  local superclassNames = {}
  local fieldClassAddress = readPointer( fieldAddress + CUEDEFS.FField.Class )

  while fieldClassAddress and fieldClassAddress ~= 0 do
    nameIndex = readQword( fieldClassAddress + CUEDEFS.FFieldClass.Name )
    
    if not nameIndex then return nil end

    className = CUEDEFS.IndexToName[nameIndex]
    
    if not className then return nil end

    table.insert( superclassNames, className )

    fieldClassAddress = readPointer( fieldClassAddress + CUEDEFS.FFieldClass.SuperClass )
  end

  return superclassNames
end

--- Test whether offset produces readable named superclass chain
-- @param classAddress number @ starting UClass address
-- @param candidateSuperStructOffset number @ possible UStruct::SuperStruct offset
-- @return string[]|nil @ ordered superclass names, excluding the starting class
function Core.Reflection.testIfSuperStructOffset(classAddress, candidateSuperStructOffset)
  local objectGetName = Core.Reflection.UObject_getName
  local inheritanceDepth = 0
  local superclassNames = {}
  local currentClassAddress = readPointer( classAddress + candidateSuperStructOffset )

  while currentClassAddress and (currentClassAddress ~= 0) do
    local currentClassName = objectGetName(currentClassAddress)

    if currentClassName then
      table.insert( superclassNames, currentClassName )
    else
      return nil --a bad classname
    end

    local nextSuperclassAddress = readPointer( currentClassAddress + candidateSuperStructOffset )
    if nextSuperclassAddress == currentClassAddress then return nil end --points to itself (found Class, needed SuperClass)

    currentClassAddress = nextSuperclassAddress
    inheritanceDepth = inheritanceDepth + 1

    if inheritanceDepth > 20 then return nil end --endless loop
  end

  return superclassNames
end

--- Evaluate a candidate superclass-pointer offset
-- @param classAddress number @ starting UClass address
-- @param superStructOffset number @ candidate superclass-pointer offset
-- @param classPointerOffset number @ UObject::Class offset
-- @param expectedMetaClassAddress number @ required superclass metaclass
-- @return number @ validated superclass count, zero when rejected
function Core.Reflection.probeSuperclassDepth( classAddress, superStructOffset, classPointerOffset, expectedMetaClassAddress )
  local currentClassAddress = readPointer( classAddress + superStructOffset )
  local visitedAddresses = { [classAddress] = true }
  local inheritanceDepth = 0
  local maximumInheritanceDepth = 32

  while currentClassAddress and currentClassAddress ~= 0 do
    if visitedAddresses[ currentClassAddress ] then return 0 end

    visitedAddresses[ currentClassAddress ] = true

    -- check if class has a readable vtable entry
    local vtableAddress = readPointer( currentClassAddress )
    local firstFunctionAddress = vtableAddress and readPointer(vtableAddress)
    if not firstFunctionAddress or readByte(firstFunctionAddress) == nil then return 0 end

    local metaClassAddress = readPointer( currentClassAddress + classPointerOffset )

    if metaClassAddress ~= expectedMetaClassAddress then return 0 end

    inheritanceDepth = inheritanceDepth + 1
    if inheritanceDepth > maximumInheritanceDepth then return 0 end

    currentClassAddress = readPointer( currentClassAddress + superStructOffset )
  end

  return inheritanceDepth
end

--- Infer UStruct::SuperStruct using superclass metaclass and vtable checks
-- Every superclass of a UClass is another UClass and
-- therefore has the same UObject::Class pointer as the starting class
-- Stripped or incomplete FName pool cannot provide ancestry names
-- @param classAddress number @ address of a non-root UClass
-- @return number|nil @ inferred SuperStruct byte offset
-- @return string|nil @ error
function Core.Reflection.ue_inferSuperStructOffsetInternal(classAddress)
  local probeSuperclassDepth = Core.Reflection.probeSuperclassDepth
  local writeLog = Core.Runtime.log

  local objectLayout = CUEDEFS and CUEDEFS.UObject
  local classPointerOffset = objectLayout and objectLayout.Class
  local invalidLayoutError = 'invalid UClass or UObject.Class layout'

  if type(classAddress) ~= 'number' or classAddress == 0 or type(classPointerOffset) ~= 'number' then return nil, invalidLayoutError end

  local expectedMetaClassAddress = readPointer( classAddress + classPointerOffset )

  if not expectedMetaClassAddress or expectedMetaClassAddress == 0 then return nil, 'UClass metaclass is unreadable' end

  local selectedOffset
  local selectedDepth = 0

  for candidateOffset = 0x28, 0x100, 8 do

    local candidateDepth = probeSuperclassDepth( classAddress, candidateOffset, classPointerOffset, expectedMetaClassAddress )

    if candidateDepth > 0 then
      writeLog( ('SuperStruct inference: offset 0x%X produced a %d-class chain'):format( candidateOffset, candidateDepth ) )

      if candidateDepth > selectedDepth then
        selectedOffset = candidateOffset
        selectedDepth = candidateDepth
      end

    end
  end

  if not selectedOffset then return nil, 'no terminating same-metaclass superclass chain was found' end

  writeLog( ('SuperStruct inference: selected offset 0x%X (depth %d)'):format( selectedOffset, selectedDepth ) )

  return selectedOffset
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// OBJECT CLASS-HIERARCHY LOOKUP

--- Return the reflected class ancestry for a UObject instance
-- The first entry is the object's concrete class. Each following entry is its
-- superclass, ending with Object when the runtime layout is complete
-- @param objectAddress number @ live UObject this pointer
-- @return string[]|nil @ ordered reflected class names
-- @return string|nil @ error
function Core.Reflection.getObjectClassHierarchy(objectAddress)
  local objectGetName = Core.Reflection.UObject_getName

  local superclassNames = {}
  local currentClassAddress = readPointer( objectAddress + CUEDEFS.UObject.Class )
  local visitedClassAddresses = {}

  while currentClassAddress and currentClassAddress ~= 0 do
    
    if visitedClassAddresses[currentClassAddress] then return nil, 'UClass superclass chain contains a cycle' end

    visitedClassAddresses[currentClassAddress] = true

    local currentClassName = objectGetName(currentClassAddress)
    
    if not currentClassName then return nil, 'Unable to resolve a class name in the superclass chain' end

    table.insert( superclassNames, currentClassName )
    currentClassAddress = readPointer( currentClassAddress + CUEDEFS.UClass.SuperStruct )
  end

  return superclassNames
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.PROPERTYLAYOUT

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// STRUCT HELPERS LINKED-LIST

--- Count readable nodes after the head of a linked list
-- @param headAddress number @ first linked-list node
-- @param nextPointerOffset number @ byte offset of the next-node pointer
-- @return number @ number of readable nodes after the head
function Core.PropertyLayout.countLinkedListNodes(headAddress, nextPointerOffset)
  local currentNodeAddress = headAddress
  local linkedNodeCount = 0
  local visitedNodeAddresses = { [headAddress] = true }

  repeat
    currentNodeAddress = readPointer( currentNodeAddress + nextPointerOffset )

    if currentNodeAddress and currentNodeAddress ~= 0 then
      if visitedNodeAddresses[currentNodeAddress] then break end

      visitedNodeAddresses[currentNodeAddress] = true
      linkedNodeCount = linkedNodeCount + 1
    end

  until not currentNodeAddress or currentNodeAddress == 0 or linkedNodeCount > 100000

  return linkedNodeCount
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// FIELD-OWNER RECOVERY

--- Find the nearest preceding vtable-backed structure base
-- @param targetAddress number @ address believed to reside in the structure
-- @return number|nil @ aligned structure base address
-- @return string|nil @ error
function Core.PropertyLayout.findFieldOwnerStart(targetAddress)
  local isVTable = Core.Memory.isVTable

  local candidateStructureAddress = targetAddress & 0xfffffffffffffff8
  local inspectedAddressCount = 0

  while inspectedAddressCount < 100 do
    local candidateVTableAddress = readPointer(candidateStructureAddress)

    if candidateVTableAddress == nil then return nil, 'Encountered unreadable memory while locating structure base' end

    if isVTable(candidateVTableAddress) then
      return candidateStructureAddress
    end

    candidateStructureAddress = candidateStructureAddress - 8
    inspectedAddressCount = inspectedAddressCount + 1
  end
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// MODERN FIELD-LAYOUT FALLBACK

--- Apply & validate the common UE4.25+/UE5 FField reflection layout
-- Per UE4SS's versioned member layouts. UStruct::SuperStruct at 0x40
-- Used as a fallback when runtime name-based scanner cannot locate GameInstance
-- @return boolean @ true when at least one reflected field root is coherent
-- @return string|nil @ error on validation failure
function Core.PropertyLayout.applyModernFieldLayout()
  if not CUEDEFS.UStruct or CUEDEFS.UStruct.SuperStruct ~= 0x40 then return false, 'Modern field fallback requires UStruct.SuperStruct = 0x40' end

  local validatedFieldListCount = 0

  for _, candidateLayout in ipairs(MODERN_FIELD_LISTS) do
    local firstFieldAddress = readPointer( CUEDEFS.GameEngineClass + candidateLayout.rootOffset )

    if not firstFieldAddress or firstFieldAddress == 0 then goto continue end

    local fieldClassAddress = readPointer( firstFieldAddress + 0x8 )

    if not fieldClassAddress or fieldClassAddress == 0 then goto continue end

    local fieldClassNameIndex = readQword(fieldClassAddress)
    local propertyOffset = readInteger( firstFieldAddress + 0x4C )
    local nextFieldAddress = readPointer( firstFieldAddress + candidateLayout.nextOffset )

    local layoutIsValid = fieldClassNameIndex ~= nil and propertyOffset ~= nil
          and propertyOffset >= 0 and propertyOffset < 0x100000
          and (not nextFieldAddress or nextFieldAddress == 0 or nextFieldAddress ~= firstFieldAddress )

    if layoutIsValid then
      validatedFieldListCount = validatedFieldListCount + 1
      Core.Runtime.log( ('Modern field layout: validated UStruct.%s at 0x%X'):format( candidateLayout.label, candidateLayout.rootOffset ) )
    end

    ::continue::
  end

  if validatedFieldListCount == 0 then return false, 'No coherent ChildProperties or PropertyLink root was found' end

  -- publish the validated UE4.25+/UE5 reflection member layout
  CUEDEFS.UClass.PropertyLink = 0x70
  CUEDEFS.UClass.PropertyLinkAlt = 0x50

  CUEDEFS.FFieldClass =
  {
    Name = 0x0,
    SuperClass = 0x20,
  }

  CUEDEFS.FField =
  {
    Class = 0x8,
    Owner = 0x10,
    PropertyLinkNext = 0x20,
    Name = 0x28,
  }

  CUEDEFS.FProperty =
  {
    Class = 0x8,
    Owner = 0x10,
    Name = 0x28,
    Size = 0x3C,
    Offset = 0x4C,
    PropertyLinkNext = 0x58,
  }

  Core.Runtime.log('Modern field layout: selected UE4.25+/UE5 core reflection offsets')
  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// GAMEINSTANCE PROPERTY SEARCH

--- Scan for references to the GameInstance FName index
-- @param nameIndex number @ GameInstance name index
-- @return number[]|nil @ matching addresses
-- @return string|nil @ error
function Core.PropertyLayout.scanGameInstanceReferences(nameIndex)
  local memoryScan = createMemScan() --todo: make aobscanarrays (multiple) allow multiple results
  memoryScan.VarType = vtQword
  memoryScan.ScanValue = nameIndex
  memoryScan.Fastscanmethod = fsmAligned
  memoryScan.Fastscanparameter = 4

  Core.Runtime.log('scanning GameInstance')
  memoryScan.scan()

  local results = memoryScan.Results
  local scanError = memoryScan.ErrorString
  memoryScan.destroy()

  if scanError ~= '' then return nil, scanError end

  if #results == 0 then return nil, 'Failure finding references to the GameInstance FProperty' end

  return results
end

--- Find the property whose owner points to GameEngineClass
-- Prefer the candidate with the lowest owner-member offset
-- @param scanResults number[] @ GameInstance name references
-- @return number|nil @ selected property address
-- @return number|nil @ owner-member offset
function Core.PropertyLayout.findGameInstanceProperty(scanResults)
  local findStructureStart = Core.PropertyLayout.findFieldOwnerStart

  local gameInstancePropertyAddress
  local propertyOwnerOffset

  for _, referenceAddress in ipairs(scanResults) do
    local propertyAddress = findStructureStart(referenceAddress)

    if not propertyAddress then goto continue end

    for ownerOffset = 8, 0x100, 8 do
      local ownerValue = readPointer( propertyAddress + ownerOffset )

      --ue 4.26 and 5 (UE5 used the lowest bits to set if it's an Object or Field, 4.26 used a byte with padding
      local ownerAddress = ownerValue and (ownerValue & 0xfffffffffffffff8)

      if ownerAddress == CUEDEFS.GameEngineClass then

        if not propertyOwnerOffset or ownerOffset < propertyOwnerOffset then
          gameInstancePropertyAddress = propertyAddress
          propertyOwnerOffset = ownerOffset
        end

        break
      end

    end

    ::continue::
  end

  return gameInstancePropertyAddress, propertyOwnerOffset
end

--- Test whether an engine member points to a GameInstance-derived object
-- @param objectOffset number @ candidate offset within UGameEngine
-- @param ownerObjectAddress number|nil @ containing UObject; defaults to UGameEngine
-- @return boolean @ true when the object's ancestry includes GameInstance
function Core.PropertyLayout.isGameInstanceObjectOffset(objectOffset, ownerObjectAddress)
  if objectOffset <= 8 or objectOffset >= 0x9000 then return false end
  if (objectOffset & 7) ~= 0 then return false end

  ownerObjectAddress = ownerObjectAddress or CUEDEFS.UGameEngine -- UWorld is fine too
  if not ownerObjectAddress or ownerObjectAddress == 0 then return false end

  local objectAddress = readPointer( ownerObjectAddress + objectOffset )
  if not Core.Reflection.UObject_getName(objectAddress) then return false end

  --at least it has a name, check if it inherits from GameInstance
  local superclassNames = Core.Reflection.getObjectClassHierarchy(objectAddress)
  if not superclassNames then return false end

  for _, className in ipairs(superclassNames) do
    if className == 'GameInstance' then return true end
  end

  return false
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// FFIELDCLASS RESOLUTION

--- Find a reflected property-type name within a candidate FFieldClass
-- @param classAddress number @ candidate FFieldClass address
-- @return number|nil @ name-member offset
function Core.PropertyLayout.findFieldClassNameOffset(classAddress)
  
  --scan it for a name ending with Property (spoiler, it's ObjectProperty)
  for nameOffset = 0, 0x40, 4 do
    local nameIndex = readQword( classAddress + nameOffset )
    local className = CUEDEFS.IndexToName[nameIndex]

    if className and className:endsWith('Property') then
      return nameOffset
    end
  end

  return nil
end

--- Check whether a name is accepted as an FFieldClass ancestor
-- @param className string|nil @ reflected class name
-- @return boolean @ true for Field or a supported property-class name
function Core.PropertyLayout.isFieldClassAncestorName(className)
  if not className then return false end
  if className == 'Field' then return true end
  if className:endsWith('Property') then return true end

  return className:endsWith('PropertyBase')
end


--- Locate the superclass pointer within a found FFieldClass
-- @param classAddress number @ FFieldClass address
-- @param nameOffset number @ found name-member offset
-- @return number|nil @ superclass-member offset
function Core.PropertyLayout.findFieldClassSuperOffset(classAddress, nameOffset)
  local isFieldClassAncestorName = Core.PropertyLayout.isFieldClassAncestorName

  for superOffset = 0, 0x80, 8 do
    local superclassAddress = readPointer(classAddress + superOffset)

    if not superclassAddress then goto continue end

    local nameIndex = readQword(superclassAddress + nameOffset)
    local className = nameIndex and CUEDEFS.IndexToName[nameIndex]

    if isFieldClassAncestorName(className) then
      return superOffset -- found it
    end

    ::continue::
  end

  return nil
end

--- Test one pointer member as the property's FFieldClass reference
-- Updates the found class layout when a property-type name is found
-- @param memberOffset number @ pointer-member offset within the property
-- @param classAddress number @ candidate FFieldClass address
-- @return void
function Core.PropertyLayout.findPropertyClassMember(memberOffset, classAddress)
  if CUEDEFS.FProperty.Class ~= nil then return end

  local nameOffset = Core.PropertyLayout.findFieldClassNameOffset(classAddress)
  if nameOffset == nil then return end

  CUEDEFS.FProperty.Class = memberOffset

  CUEDEFS.FFieldClass =
  {
    Name = nameOffset,
    SuperClass = Core.PropertyLayout.findFieldClassSuperOffset( classAddress, nameOffset ),
  }
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// PROPERTY MEMBER RESOLUTION

--- Inspect GameInstance property for names, offsets, pointer members
-- @param gameInstancePropertyAddress number @ GameInstance property address
-- @param nameIndex number @ GameInstance FName index
-- @param ownerObjectAddress number|nil @ object containing the GameInstance pointer
-- @return number[]|nil @ candidate property-list link offsets
-- @return string|nil @ error
function Core.PropertyLayout.inspectGameInstanceProperty(gameInstancePropertyAddress, nameIndex, ownerObjectAddress)
  local isVTable = Core.Memory.isVTable
  local isGameInstanceObjectOffset = Core.PropertyLayout.isGameInstanceObjectOffset
  local findPropertyClassMember = Core.PropertyLayout.findPropertyClassMember

  local FPropertyLayout = CUEDEFS.FProperty
  local candidateLinkOffsets = {} --FProperties have multiple lists

  for memberOffset = 4, 0x100, 4 do
    local memberValue = readPointer( gameInstancePropertyAddress + memberOffset )

    if memberValue == nil then return nil, ('Unreadable GameInstance property member at 0x%X'):format( memberOffset ) end

    -- a subsequent vtable marks the beginning of another allocated object
    if isVTable(memberValue) then break end

    local memberLowDword = memberValue & 0xffffffff

    if FPropertyLayout.Name == nil and memberLowDword == nameIndex then
      FPropertyLayout.Name = memberOffset
    end

    if FPropertyLayout.Offset == nil and isGameInstanceObjectOffset( memberLowDword, ownerObjectAddress ) then
      FPropertyLayout.Offset = memberOffset
    end

    -- only aligned pointer members are candidates for classes and list links
    local isAlignedMember = (memberOffset & 7) == 0
    local isAlignedPointer = (memberValue & 7) == 0

    if isAlignedMember and isAlignedPointer then
      findPropertyClassMember( memberOffset, memberValue )
      candidateLinkOffsets[#candidateLinkOffsets + 1] = memberOffset
    end
  end

  return candidateLinkOffsets
end

--- Check whether enough property metadata exists to inspect linked lists
-- @return boolean @ true when all required members have been found
function Core.PropertyLayout.hasRequiredPropertyLayout()
  local propertyLayout = CUEDEFS.FProperty
  local fieldClassLayout = CUEDEFS.FFieldClass

  if not propertyLayout or not fieldClassLayout then return false end
  if fieldClassLayout.Name == nil then return false end

  for _, memberName in ipairs( { 'Class', 'Name', 'Offset', 'Owner' } ) do
    if propertyLayout[memberName] == nil then return false end
  end

  return true
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// PROPERTY LIST RESOLUTION

--- Check for ancestry ending in Property -> Field [-> Object]
-- @param fieldAddress number @ candidate reflected field
-- @return boolean @ true when the expected ancestry suffix is present
function Core.PropertyLayout.hasPropertyFieldAncestry(fieldAddress)

  local superclassNames = Core.Reflection.getSuperListFromField(fieldAddress) --handle P as a field
  if not superclassNames then return false end
  --UE5 : Property->Field (Done)
  --UE4 : Property->Field->Objec

  local lastIndex = #superclassNames

  -- normalize the legacy UObject-based ancestry suffix
  if superclassNames[lastIndex] == 'Object' then
    lastIndex = lastIndex - 1
  end

  if lastIndex < 2 then return false end
  if superclassNames[lastIndex] ~= 'Field' then return false end

  return superclassNames[lastIndex - 1] == 'Property'
end

--- Select the candidate next-pointer offset producing the longest list
-- Equal-length candidates retain the earlier selection
-- @param propertyAddress number @ GameInstance property address
-- @param candidateOffsets number[] @ candidate next-pointer offsets
-- @return number|nil @ selected next-pointer offset
function Core.PropertyLayout.findPropertyLinkNextOffset(gameInstancePropertyAddr, candidatePropertyListOffsets)
  local hasPropertyFieldAncestry = Core.PropertyLayout.hasPropertyFieldAncestry
  local getLinkedListSize = Core.PropertyLayout.countLinkedListNodes

  local propertyLinkNextOffset
  local largestPropertyCount = 0

  for _, candidateOffset in ipairs(candidatePropertyListOffsets) do
    --scan, but stop when a vtable is encountered (most properties are allocated next to eachother)
    local nextFieldAddress = readPointer( gameInstancePropertyAddr + candidateOffset )

    if hasPropertyFieldAncestry(nextFieldAddress) then
      local propertyCount = getLinkedListSize( gameInstancePropertyAddr, candidateOffset )

      if propertyLinkNextOffset == nil or propertyCount > largestPropertyCount then
        propertyLinkNextOffset = candidateOffset
        largestPropertyCount = propertyCount
      end

    end

  end

  return propertyLinkNextOffset
end

--- Find property-list roots within GameEngineClass
-- Equal-length candidates replace primary root
-- Alternate root is the previous primary, not necessarily the runner-up
-- @param nextOffset number @ found property next-pointer offset
-- @return number|nil @ primary root-member offset
-- @return number|nil @ alternate root-member offset
function Core.PropertyLayout.findClassPropertyListOffsets(nextOffset)
  local isVTable = Core.Memory.isVTable
  local hasPropertyFieldAncestry = Core.PropertyLayout.hasPropertyFieldAncestry
  local getLinkedListSize = Core.PropertyLayout.countLinkedListNodes

  local propertyLinkOffset
  local alternatePropertyLinkOffset
  local largestPropertyCount = 0

  for rootOffset = 8, 0x320, 8 do
    local fieldAddress = readPointer( CUEDEFS.GameEngineClass + rootOffset )

    if isVTable(fieldAddress) then break end

    if hasPropertyFieldAncestry(fieldAddress) then
      local propertyCount = getLinkedListSize( fieldAddress, nextOffset )

      if propertyLinkOffset == nil or propertyCount >= largestPropertyCount then
        alternatePropertyLinkOffset = propertyLinkOffset
        propertyLinkOffset = rootOffset
        largestPropertyCount = propertyCount
      end
    end
  end

  return propertyLinkOffset, alternatePropertyLinkOffset
end

--- Find the field links and class-level property-list roots
-- @param propertyAddress number @ GameInstance property address
-- @param candidateOffsets number[] @ candidate property-list link offsets
-- @return boolean|nil @ true when the required links were found
-- @return string|nil @ error
function Core.PropertyLayout.findPropertyLists(propertyAddress, candidateOffsets)
  
  CUEDEFS.FField =
  {
    Class = CUEDEFS.FProperty.Class,
    Owner = CUEDEFS.FProperty.Owner,
    Name = CUEDEFS.FProperty.Name,
  }

  local nextOffset = Core.PropertyLayout.findPropertyLinkNextOffset( propertyAddress, candidateOffsets )

  if nextOffset == nil then
    return nil, 'Property-list next-pointer offset was not found'
  end

  CUEDEFS.FProperty.PropertyLinkNext = nextOffset

  --scan the GameEngineClass for properties  (todo: maybe also add a few others)
  local primaryOffset, alternateOffset = Core.PropertyLayout.findClassPropertyListOffsets(nextOffset)

  if primaryOffset == nil then
    return nil, 'GameEngineClass property-list root was not found'
  end

  CUEDEFS.UClass.PropertyLink = primaryOffset
  CUEDEFS.UClass.PropertyLinkAlt = alternateOffset

  return true
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// PROPERTY SIZE SAMPLES

--- Group known properties by expected size and boolean object offset
-- Retains at most ten size samples per group, but every boolean sample
-- @param propertiesByName table @ enumerated property metadata
-- @return table @ sample addresses indexed by expected size
-- @return table @ boolean property addresses indexed by object offset
function Core.PropertyLayout.collectPropertyMetadataSamples(propertiesByName)
  
  local propertyExpectedSizes =
  {
    FloatProperty = 4,
    IntProperty = 4,
    ObjectProperty = 8,
    ClassProperty = 8,
    BoolProperty = 1,
  }

  local sizeSamples = { [1] = {}, [4] = {}, [8] = {} }
  local booleanGroups = {}

  for _, property in pairs(propertiesByName) do
    local expectedSize = propertyExpectedSizes[ property.propertyType ]

    if expectedSize then
      local samples = sizeSamples[ expectedSize ]

      if #samples < 10 then
        samples[ #samples + 1 ] = property.propertyAddress
      end

    end

    if property.propertyType == 'BoolProperty' then
      local group = booleanGroups[ property.offset ] or {}

      group[ #group + 1 ] = property.propertyAddress
      booleanGroups[ property.offset ] = group
    end

  end

  return sizeSamples, booleanGroups
end

--- Check a candidate size-member offset against every collected sample
-- @param sizeSamples table @ property addresses indexed by expected size
-- @param memberOffset number @ candidate size-member offset
-- @return boolean @ true when every sample matches
function Core.PropertyLayout.matchesPropertySizeSamples(sizeSamples, memberOffset)

  for expectedSize, addresses in pairs(sizeSamples) do

    for _, propertyAddress in ipairs(addresses) do

      if readInteger( propertyAddress + memberOffset ) ~= expectedSize then return false end

    end

  end

  return true
end

--- Find the first size-member offset matching all samples
-- @param sizeSamples table @ property addresses indexed by expected size
-- @return number|nil @ found size-member offset
function Core.PropertyLayout.findPropertySizeOffset(sizeSamples)
  local matchesPropertySizeSamples = Core.PropertyLayout.matchesPropertySizeSamples

  for memberOffset = 8, 0x100, 4 do

    if matchesPropertySizeSamples( sizeSamples, memberOffset ) then
      return memberOffset
    end

  end

  return nil
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// BOOLEAN METADATA

--- Prefer boolean groups sharing an object offset
-- If none share an offset, use all groups and permit full-byte masks
-- @param booleanGroups table @ boolean addresses indexed by object offset
-- @return table[] @ selected sample groups
-- @return boolean @ whether 0xFF masks are permitted
function Core.PropertyLayout.selectBooleanMetadataSamples(booleanGroups)
  local sharedBooleanPropertyGroups = {}

  for offset, addresses in pairs(booleanGroups) do

    if #addresses > 1 then
      --guaranteed to have 1 bit sized entries
      sharedBooleanPropertyGroups[ #sharedBooleanPropertyGroups + 1 ] = addresses
    end

  end

  if #sharedBooleanPropertyGroups > 0 then return sharedBooleanPropertyGroups, false end

  --bah, it's all single bit fields... Just use these then
  for offset, addresses in pairs(booleanGroups) do
    sharedBooleanPropertyGroups[ #sharedBooleanPropertyGroups + 1 ] = addresses
  end
  
  return sharedBooleanPropertyGroups, true
end

--- Check whether an eight-bit mask contains one bit or an allowed full byte
-- @param mask number @ mask byte
-- @param allowFullByte boolean @ permit 0xFF
-- @return boolean @ true when accepted
function Core.PropertyLayout.isAcceptedBooleanMask(mask, allowFullByte)
  if mask == 0xff then return allowFullByte end
  if mask == 0 then return false end

  return (mask & (mask - 1)) == 0
end

--- Validate the four packed bytes used by the existing boolean-layout probe
-- @param packedMetadata number|nil @ packed metadata DWORD
-- @param allowFullByte boolean @ permit 0xFF masks
-- @return boolean @ true when all four bytes match the expected pattern
function Core.PropertyLayout.matchesBooleanMetadata(packedMetadata, allowFullByte)
  if packedMetadata == nil then return false end

  local fieldSize = packedMetadata & 0xff
  local byteOffset = (packedMetadata >> 8) & 0xff
  local byteMask = (packedMetadata >> 16) & 0xff
  local fieldMask = (packedMetadata >> 24) & 0xff

  if fieldSize ~= 1 then return false end
  if byteOffset ~= 0 then return false end

  if not Core.PropertyLayout.isAcceptedBooleanMask( byteMask, allowFullByte ) then return false end

  return Core.PropertyLayout.isAcceptedBooleanMask( fieldMask, allowFullByte )
end

--- Validate one boolean-metadata offset against every selected sample
-- @param sampleGroups table[] @ boolean property address groups
-- @param memberOffset number @ candidate metadata-member offset
-- @param allowFullByte boolean @ permit 0xFF masks
-- @return boolean @ true when all samples match
function Core.PropertyLayout.matchesBooleanSamples(sampleGroups, memberOffset, allowFullByte)
  local matchesBooleanMetadata = Core.PropertyLayout.matchesBooleanMetadata

  for _, addresses in ipairs(sampleGroups) do

    for _, propertyAddress in ipairs(addresses) do
      local metadata = readInteger( propertyAddress + memberOffset )

      if not matchesBooleanMetadata( metadata, allowFullByte ) then return false end

    end

  end

  return true
end

--- Find the first boolean-metadata offset accepted by the sample groups
-- @param booleanGroups table @ boolean addresses indexed by object offset
-- @return number|nil @ found metadata-member offset
function Core.PropertyLayout.findBooleanMetadataOffset(booleanGroups)
  local matchesBooleanSamples = Core.PropertyLayout.matchesBooleanSamples
  
  local samples, allowFullByteBooleanMask = Core.PropertyLayout.selectBooleanMetadataSamples(booleanGroups)

  local firstIndex = CUEDEFS.FProperty.PropertyLinkNext // 8 + 1

  for memberIndex = firstIndex, 64 do
    local memberOffset = memberIndex * 4

    if matchesBooleanSamples( samples, memberOffset, allowFullByteBooleanMask ) then
      return memberOffset
    end

  end

  return nil
end

--- Infer size and boolean metadata using enumerated GameEngine properties
-- @return boolean|nil @ true when property enumeration succeeded
-- @return string|nil @ error
function Core.PropertyLayout.findPropertyMetadata()

  local properties, errorMessage = Core.Reflection.UClass_enumProperties(CUEDEFS.GameEngineClass)

  if not properties then return nil, errorMessage or 'Failed enumerating GameEngine properties' end

  local sizeSamples, booleanGroups = Core.PropertyLayout.collectPropertyMetadataSamples(properties)

  local sizeOffset = Core.PropertyLayout.findPropertySizeOffset(sizeSamples)
  if sizeOffset then CUEDEFS.FProperty.Size = sizeOffset end

  --now try to find the bitfields
  local booleanMetadataOffset = Core.PropertyLayout.findBooleanMetadataOffset(booleanGroups)

  if booleanMetadataOffset then
    CUEDEFS.FProperty.BitMaskField = booleanMetadataOffset
    --same offset  (e.g ObjectClassType for the property GameInstance is a pointer to the GameInstanceClass
    CUEDEFS.FProperty.ObjectClassType = booleanMetadataOffset
  end

  return true
end

--- Find owner-member offset of a reflected property descriptor
-- Modern FFieldVariant owners may use low bits as tags
-- remove them before comparing stored owner with the expected UClass
-- @param propertyAddress number @ FProperty/UProperty descriptor address
-- @param ownerClassAddress number|number[] @ accepted owning UClass address(es)
-- @return number|nil @ owner-member byte offset
function Core.PropertyLayout.findPropertyOwnerOffset(propertyAddress, ownerClassAddress)
  local acceptedOwnerAddresses = {}

  if type(ownerClassAddress) == 'table' then
    for _, classAddress in ipairs(ownerClassAddress) do acceptedOwnerAddresses[classAddress] = true end
  else
    acceptedOwnerAddresses[ownerClassAddress] = true
  end

  for ownerOffset = 8, 0x100, 8 do
    local ownerValue = readPointer( propertyAddress + ownerOffset )
    local untaggedOwnerAddress = ownerValue and (ownerValue & 0xFFFFFFFFFFFFFFF8)

    if acceptedOwnerAddresses[untaggedOwnerAddress] then return ownerOffset end
  end

  return nil
end

--- UWorld::OwningGameInstance resolution
-- @return number|nil @ OwningGameInstance property descriptor
-- @return number|nil @ descriptor owner-member offset
-- @return number|nil @ live UWorld instance
-- @return string|nil @ diagnostic when no direct anchor is available
function Core.PropertyLayout.findWorldGameInstanceProperty()
  if not CUEDEFS.GWorld or CUEDEFS.GWorld == 0 then return nil, nil, nil, 'GWorld is unavailable' end

  local worldObjectAddress = readPointer(CUEDEFS.GWorld)
  if not worldObjectAddress or worldObjectAddress == 0 then return nil, nil, nil, 'GWorld instance is null' end

  local worldClassAddress = readPointer( worldObjectAddress + CUEDEFS.UObject.Class )
  if not worldClassAddress or worldClassAddress == 0 then return nil, nil, nil, 'UWorld class is unreadable' end

  local classHierarchy = Core.Reflection.selectProbeClassHierarchy(worldClassAddress)
  local probePropertyLayout = Core.Reflection.probePropertyLayout
  local findOwnerOffset = Core.PropertyLayout.findPropertyOwnerOffset

  for _, candidateLayout in ipairs(PROPERTY_LAYOUTS) do
    local probe = probePropertyLayout( classHierarchy, candidateLayout )
    local property = probe.propertiesByName.OwningGameInstance
    local ownerOffset

    if property then
      local isObjectProperty = property.propertyType == 'ObjectProperty' or property.propertyType == 'ObjectPtrProperty'

      if isObjectProperty then
        ownerOffset = findOwnerOffset( property.propertyAddress, classHierarchy )
      end
    end

    if ownerOffset then
      Core.Runtime.log( ('Property layout: UWorld.OwningGameInstance selected through %s'):format(candidateLayout.label) )

      return property.propertyAddress, ownerOffset, worldObjectAddress
    end
  end

  return nil, nil, nil, 'No UWorld.OwningGameInstance descriptor with a matching class owner was found'
end

--- Complete reflection-layout discovery from one known GameInstance property
-- @param propertyAddress number @ GameInstance/OwningGameInstance descriptor
-- @param propertyNameIndex number @ exact descriptor FName comparison index
-- @param ownerOffset number @ descriptor owner-member offset
-- @param ownerObjectAddress number @ live object containing the property value
-- @return boolean|nil @ true when the complete property layout is ready
-- @return string|nil @ error
function Core.PropertyLayout.resolveFromGameInstanceProperty(propertyAddress, propertyNameIndex, ownerOffset, ownerObjectAddress)
  CUEDEFS.FProperty = { Owner = ownerOffset }
  CUEDEFS.FFieldClass = nil

  local candidateLinks, inspectionError = Core.PropertyLayout.inspectGameInstanceProperty( propertyAddress, propertyNameIndex, ownerObjectAddress )

  if not candidateLinks then return nil, inspectionError end
  if not Core.PropertyLayout.hasRequiredPropertyLayout() then return nil, 'Not all needed fields were found' end

  local listsReady, listError = Core.PropertyLayout.findPropertyLists( propertyAddress, candidateLinks )
  if not listsReady then return nil, listError end

  local metadataReady, metadataError = Core.PropertyLayout.findPropertyMetadata()
  if not metadataReady then return nil, metadataError end

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// RESOLUTION ENTRY POINT

--- Find the FField/FProperty layout using the GameInstance property
-- Falls back to the modern structural profile when its name is unavailable
-- @param cancellationThread table|nil @ reserved; not polled by this implementation
-- @return boolean|nil @ true when scan completes
-- @return string|nil @ success message or error
function Core.PropertyLayout.findGameInstanceFPropertyAndFields(cancellationThread)

  if not CUEDEFS.UGameEngine then return nil, 'Find UGameEngine and GameEngineClass first' end
  if not CUEDEFS.GameEngineClass then return nil, 'Find the GameEngineClass first' end

  local owningGameInstanceNameIndex = CUEDEFS.NameToIndex.OwningGameInstance

  if owningGameInstanceNameIndex then
    local worldPropertyAddress, worldOwnerOffset, worldObjectAddress, worldAnchorError =
      Core.PropertyLayout.findWorldGameInstanceProperty()

    if worldPropertyAddress then
      local ready, layoutError = Core.PropertyLayout.resolveFromGameInstanceProperty(
        worldPropertyAddress,
        owningGameInstanceNameIndex,
        worldOwnerOffset,
        worldObjectAddress
      )

      if ready then return true, 'success through UWorld.OwningGameInstance' end

      Core.Runtime.log(
        'Property layout: UWorld.OwningGameInstance anchor was incomplete; using GameInstance scan fallback: '
        .. tostring(layoutError)
      )
    elseif worldAnchorError then
      Core.Runtime.log('Property layout: direct UWorld anchor unavailable: ' .. worldAnchorError)
    end
  end

  local gameInstanceNameIndex = CUEDEFS.NameToIndex.GameInstance

  if gameInstanceNameIndex == nil then
    Core.Runtime.log('GameInstance name is unavailable; trying the modern structural field layout')
    return Core.PropertyLayout.applyModernFieldLayout()
  end

  local references, scanError = Core.PropertyLayout.scanGameInstanceReferences(gameInstanceNameIndex) -- TODO: via UWorld
  if not references then return nil, scanError end

  local gameInstancePropertyAddress, propertyOwnerOffset = Core.PropertyLayout.findGameInstanceProperty(references)

  if not gameInstancePropertyAddress then return nil, 'Failed finding GameInstanceFProperty' end

  return Core.PropertyLayout.resolveFromGameInstanceProperty(
    gameInstancePropertyAddress,
    gameInstanceNameIndex,
    propertyOwnerOffset,
    CUEDEFS.UGameEngine
  )
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.MEMORY

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// MEMSCAN

--- Execute a memory scan and release its scanner before returning
-- A non-nil refinement delay requests a second scan after the initial scan
-- Cancellation is checked before and after scanning, not during a blocking scan
-- @param settings table @ memory scanner property values
-- @param cancellationThread table|nil @ scan worker
-- @param refinementDelay number|nil @ delay before refinement, in milliseconds
-- @return number[]|nil @ matching addresses
-- @return string|nil @ error
function Core.Memory.scan(settings, cancellationThread, refinementDelay)
  
  if cancellationThread and cancellationThread.terminated then return nil, 'GEngine scan cancelled' end

  local memoryScan = createMemScan()

  -- setup arguments
  for propertyName, value in pairs(settings) do
    memoryScan[propertyName] = value
  end

  memoryScan.scan()
  memoryScan.waitTillDone()

  Core.Runtime.log('Core.Engine.FindGEngine: Scan finished')

  if memoryScan.ErrorString ~= '' then
    local scanError = memoryScan.ErrorString
    memoryScan.destroy()
    return nil, scanError
  end

  if refinementDelay ~= nil then

    if refinementDelay > 0 then sleep(refinementDelay) end

    memoryScan.nextScan()
    memoryScan.waitTillDone()
    Core.Runtime.log( 'Core.Engine.FindGEngine: Next scan finished' )
  end

  local GEngineScanResults = memoryScan.Results
  local scanError = memoryScan.ErrorString

  memoryScan.destroy()
  memoryScan = nil
  
  Core.Runtime.log( 'Core.Engine.FindGEngine: Next scan finished' )

  if cancellationThread and cancellationThread.terminated then
    return nil, 'GEngine scan cancelled'
  end

  if scanError and scanError ~= '' then return nil, scanError end
  if not GEngineScanResults then return nil, 'GEngine scan returned no result list' end

  return GEngineScanResults
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// EXECUTABLE RANGES AND VTABLES

  --- Resolve the module executable mem ranges
function Core.Memory.initializeExecutableRanges()
  if CUEDEFS.ExecutableRanges ~= nil then return end

  CUEDEFS.ExecutableRanges = {}

  local shouldEnumerateModuleSections = type(enumSectionsOfModule) == 'function'
                                        and (CUEDEFS.VFTableInExecutableMemoryMethod == nil or CUEDEFS.VFTableInExecutableMemoryMethod == 2 )

  if shouldEnumerateModuleSections then
    
    for _, section in ipairs(enumSectionsOfModule(process) or {}) do

      if not (section.IsCode and section.IsExecutable) then goto continue end

      table.insert(CUEDEFS.ExecutableRanges, { start = section.Address, stop = section.Address + section.Size, } )

      -- nil means only the first executable section; mode 2 keeps all
      if CUEDEFS.VFTableInExecutableMemoryMethod == nil then break end

      ::continue::
    end

  end

  if #CUEDEFS.ExecutableRanges > 0 then return end

  if type(enumMemoryRegions) ~= 'function' then return end

  local executableProtectionFlags =
  {
    [PAGE_EXECUTE] = true,
    [PAGE_EXECUTE_READ] = true,
    [PAGE_EXECUTE_READWRITE] = true,
    [PAGE_EXECUTE_WRITECOPY] = true,
  }

  for _, memoryRegion in ipairs(enumMemoryRegions() or {}) do

    if not executableProtectionFlags[memoryRegion.Protect] then goto continue end

    table.insert(CUEDEFS.ExecutableRanges, { start = memoryRegion.BaseAddress, stop = memoryRegion.BaseAddress + memoryRegion.RegionSize, } )

    ::continue::
  end
  
end

--- Check whether an address resides in executable process memory
-- Executable ranges are collected once and cached in CUEDEFS
-- Module section metadata is preferred; process memory regions are the compatibility fallback
-- @param address number|nil @ target-process address
-- @return boolean @ true when the address lies in a cached executable range
function Core.Memory.isInExecutableMainModuleMemory(address)
  if not address or address == 0 then return false end

  Core.Memory.initializeExecutableRanges()

  for _, executableRange in ipairs(CUEDEFS.ExecutableRanges) do

    if address > executableRange.start and address < executableRange.stop then
      return true
    end

  end

  return false
end

--- Validate a possible vtable address
-- A candidate is accepted when its first nine entries are readable pointers
-- into executable memory. pcall converts invalid target reads into false
-- @param vtableAddress number|nil @ possible vtable address
-- @return boolean|nil @ true when the candidate resembles a vtable
-- @return string|nil @ error for a missing address
function Core.Memory.isVTable(vtableAddress)
  if vtableAddress == nil then return nil, 'Invalid vtable address' end

  local isInExecutableMemory = Core.Memory.isInExecutableMainModuleMemory

  for functionIndex=0, 8 do
    local functionAddress = readPointer( vtableAddress + functionIndex * 8 )

    if not isInExecutableMemory(functionAddress) then return false end
  end

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.ENGINE

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// ENGINE-OBJECT GROUP SCAN

--- Scan writable memory for a grouped Unreal object pattern
-- @param expression string @ grouped scan expression
-- @param cancellationThread table|nil @ scan worker
-- @param refinementDelay number|nil @ optional refinement delay
-- @return number[]|nil @ matching addresses
-- @return string|nil @ error
function Core.Engine.scanEngineObjects(expression, cancellationThread, refinementDelay)
  Core.Runtime.log( 'Core.Engine.FindGEngine: scanning for ' .. expression )

  local settings =
  {
    VarType = vtGrouped,
    ScanValue = expression,
    Fastscanmethod = fsmAligned,
    Fastscanparameter = 8,
    ScanWritable = 'scanInclude',
    ScanExecutable = 'scanExclude',
    ScanCopyOnWrite = 'scanExclude',
  }

  return Core.Memory.scan( settings, cancellationThread, refinementDelay )
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// GENGINE CANDIDATE VALIDATION

--- Retain objects whose first pointer is a recognized vtable
-- @param addresses number[] @ scan results
-- @return number[] @ validated candidate addresses
function Core.Engine.filterEngineVTableCandidates(addresses)
  local isVTable = Core.Memory.isVTable
  local validatedAddresses = {}

  for _, address in ipairs(addresses) do

    if isVTable( readPointer(address) ) then
      --todo: check classname for the name 'GameEngine' which itself has a classname of 'Class'  (or the Superclasses named Engine->Object->nil pointer
      --still here
      validatedAddresses[#validatedAddresses + 1] = address
    end

  end

  return validatedAddresses
end

--- Retain candidates with a readable, nonzero FName number
-- @param addresses number[] @ candidate UObject addresses
-- @return number[] @ possible live engine instances
function Core.Engine.filterNumberedEngineInstances(addresses)
  local instanceAddresses = {}
  local nameNumberOffset = CUEDEFS.UObject.Name + 4

  for _, address in ipairs(addresses) do
    --the instantiated GEngine has a number for the name
    local nameNumber = readInteger( address + nameNumberOffset )

    if nameNumber ~= nil and nameNumber ~= 0 then
      instanceAddresses[#instanceAddresses + 1] = address
    end

  end

  return instanceAddresses
end

--- Validate a candidate UClass through its metaclass
-- @param classAddress number @ candidate GameEngine UClass
-- @return number|nil @ metaclass address when named Class with a valid vtable
function Core.Engine.getEngineClassMetaClass(classAddress)
  local metaClassAddress = readPointer( classAddress + CUEDEFS.UObject.Class )

  if not metaClassAddress or metaClassAddress == 0 then return nil end
  if not Core.Memory.isVTable( readPointer(metaClassAddress) ) then return nil end
  if Core.Reflection.UObject_getName(metaClassAddress) ~= 'Class' then return nil end

  return metaClassAddress
end

--- Find the GameEngine superclass member by looking for Engine
-- Retains an existing SuperStruct offset if this scan finds no replacement
-- @param classAddress number @ GameEngine UClass address
-- @return number|nil @ found or previously known SuperStruct offset
function Core.Engine.findEngineSuperStructOffset(classAddress)
  local objectGetName = Core.Reflection.UObject_getName

  CUEDEFS.UClass = CUEDEFS.UClass or
  {
    Name = CUEDEFS.UObject.Name,
    Class = CUEDEFS.UObject.Class,
  }

  for memberOffset = 8, 0x100, 8 do
    local superclassAddress = readPointer( classAddress + memberOffset )

    if objectGetName(superclassAddress) == 'Engine' then
      --found the superstruc
      CUEDEFS.UClass.SuperStruct = memberOffset
      break
    end
  end

  return CUEDEFS.UClass.SuperStruct
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// DERIVED ENGINE SEARCH

--- Build a scan expression matching a metaclass and direct superclass
-- Members are emitted in address order so padding is calculated correctly
-- @param vtableRange string @ grouped vtable-address range expression
-- @param baseClassAddress number @ required direct superclass
-- @param metaClassAddress number @ required UClass metaclass
-- @return string @ grouped scan expression
function Core.Engine.buildDerivedEngineClassScan( vtableRange, baseClassAddress, metaClassAddress )
  
  local firstOffset = CUEDEFS.UClass.Class
  local firstValue = metaClassAddress
  local secondOffset = CUEDEFS.UClass.SuperStruct
  local secondValue = baseClassAddress

  if firstOffset >= secondOffset then
    firstOffset, secondOffset = secondOffset, firstOffset
    firstValue, secondValue = secondValue, firstValue
  end

  local firstPadding = firstOffset - 8
  local secondPadding = secondOffset - (firstOffset + 8)

  return 'BA:8 ' .. vtableRange
          .. ' w:' .. firstPadding .. ' 8:' .. firstValue
          .. ' w:' .. secondPadding .. ' 8:' .. secondValue
end

--- Find numbered instances of one reflected engine class
-- @param classAddress number @ concrete engine UClass address
-- @param vtableRange string @ grouped vtable-address range expression
-- @param cancellationThread table|nil @ scan worker
-- @return number[]|nil @ candidate instances
-- @return string|nil @ error
function Core.Engine.findEngineClassInstances( classAddress, vtableRange, cancellationThread )
  
  local expression = 'BA:8 ' .. vtableRange
                      .. ' w:' .. (CUEDEFS.UClass.Class - 8)
                      .. ' 8:' .. classAddress

  local addresses, scanError = Core.Engine.scanEngineObjects( expression, cancellationThread )

  if not addresses then return nil, scanError end

  return Core.Engine.filterNumberedEngineInstances(addresses)
end

--- Search immediate subclasses of one validated GameEngine base class
-- @param baseClassAddress number @ GameEngine UClass address
-- @param metaClassAddress number @ validated UClass metaclass address
-- @param vtableRange string @ grouped vtable-address range expression
-- @param cancellationThread table|nil @ scan worker
-- @return number|nil @ first selected live instance
-- @return number|nil @ its concrete UClass address
-- @return string|nil @ scan error
function Core.Engine.findDerivedEngineInstance( baseClassAddress, metaClassAddress, vtableRange, cancellationThread )
  local findEngineClassInstances = Core.Engine.findEngineClassInstances
  
  local expression = Core.Engine.buildDerivedEngineClassScan( vtableRange, baseClassAddress, metaClassAddress )

  local derivedClasses, scanError = Core.Engine.scanEngineObjects( expression, cancellationThread, 0 )

  if not derivedClasses then return nil, nil, scanError end

  for _, derivedClassAddress in ipairs(derivedClasses) do

    local instances, instanceError = findEngineClassInstances( derivedClassAddress, vtableRange, cancellationThread )

    if not instances then return nil, nil, instanceError end

    if #instances > 0 then
      return instances[1], derivedClassAddress
    end

  end

  return nil
end

--- Try each named candidate as the GameEngine base UClass
-- @param candidateAddresses number[] @ vtable-validated named candidates
-- @param vtableRange string @ grouped vtable-address range expression
-- @param cancellationThread table|nil @ scan worker
-- @return number|nil @ selected live instance
-- @return number|nil @ its concrete UClass address
-- @return string|nil @ scan error
function Core.Engine.searchDerivedEngineInstances( candidateAddresses, vtableRange, cancellationThread )
  local getEngineClassMetaClass = Core.Engine.getEngineClassMetaClass
  local findEngineSuperStructOffset = Core.Engine.findEngineSuperStructOffset
  local findDerivedEngineInstance = Core.Engine.findDerivedEngineInstance

  for _, baseClassAddress in ipairs(candidateAddresses) do

    --there is GameEngine , likely a GameEngine Class (Confirm by checking the class pointer name to be 'Class')
    local metaClassAddress = getEngineClassMetaClass(baseClassAddress)
    if not metaClassAddress then goto continue end
    
    local superOffset = findEngineSuperStructOffset(baseClassAddress)
    if not superOffset then goto continue end
    
    local instanceAddress, concreteClassAddress, scanError = findDerivedEngineInstance( baseClassAddress, metaClassAddress, vtableRange, cancellationThread )

    if scanError then return nil, nil, scanError end
    if instanceAddress then return instanceAddress, concreteClassAddress end

    ::continue::
  end

  return nil
end

--- Select a direct engine instance or search immediate derived classes
-- @param candidateAddresses number[] @ vtable-validated named candidates
-- @param vtableRange string @ grouped vtable-address range expression
-- @param cancellationThread table|nil @ scan worker
-- @return number|nil @ selected live instance
-- @return number|nil @ concrete class address when found through the fallback
-- @return string|nil @ error
function Core.Engine.resolveLiveEngineInstance( candidateAddresses, vtableRange, cancellationThread )
  
  local directInstances = Core.Engine.filterNumberedEngineInstances(candidateAddresses)

  if #directInstances > 1 then return nil, nil, 'Core.Engine.FindGEngine needs more refining' end

  if #directInstances == 1 then return directInstances[1] end

  Core.Runtime.log('Core.Engine.FindGEngine: No direct GEngine found')

  --no instance found, maybe it created a subclass
  if #candidateAddresses == 0 then return nil, nil, 'No GameEngine found' end

  Core.Runtime.log('Searching deeper')

  local instanceAddress, classAddress, scanError = Core.Engine.searchDerivedEngineInstances( candidateAddresses, vtableRange, cancellationThread )

  if scanError then return nil, nil, scanError end

  if not instanceAddress then return nil, nil, 'No GameEngine instance found' end

  return instanceAddress, classAddress
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// GENGINE POINTER REGISTRATION

--- Register matching globals as pGEngine, pGEngine2, and subsequent aliases
-- @param addresses number[] @ module addresses pointing to the engine instance
-- @return nil
function Core.Engine.registerEngineGlobalSymbols(addresses)

  for index, address in ipairs(addresses) do
    local definitionName = 'GEngine'

    if index > 1 then definitionName = definitionName .. index end

    CUEDEFS[definitionName] = address
    local symbolName = 'p' .. definitionName

    local relocatableAddress = getNameFromAddress( address, true, false, false )

    ceUEDumperRegisterSymbol( symbolName, relocatableAddress )
  end

end

--- Locate module globals pointing to the selected engine instance
-- @param instanceAddress number @ selected live engine object
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when at least one global was registered
-- @return string|nil @ error
function Core.Engine.findEngineGlobals(instanceAddress, cancellationThread)
  local moduleStart, moduleEnd = Core.Modules.ue_getMainModuleBoundsInternal()

  if not moduleStart then return nil, 'Unable to determine main module bounds' end

  local settings =
  {
    VarType = vtQword,
    ScanValue = instanceAddress,
    Startaddress = moduleStart,
    Stopaddress = moduleEnd,
  }

  local addresses, scanError = Core.Memory.scan( settings, cancellationThread )

  if not addresses then return nil, scanError end

  if #addresses == 0 then return nil, 'No GEngine global pointer found' end

  Core.Engine.registerEngineGlobalSymbols(addresses)

  return true
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// GENGINE SCAN ENTRY POINT

--- Locate a live GameEngine instance and register its module-global pointers
--
-- The fallback first searches for GameEngine objects. If only the base class
-- is present, it finds derived UClasses and then live instances of those
-- classes. Finally, it searches module globals that point to the selected
-- engine instance and registers the GEngine symbol
--
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when a GEngine global was registered
-- @return string|nil @ error
function Core.Engine.FindGEngine(cancellationThread)
  if CUEDEFS.UObject.Name == nil then return nil, 'CUEDEFS.UObject.Name==nil' end

  local nameIndex = CUEDEFS.NameToIndex['GameEngine']

  if nameIndex == nil then return nil, 'failure finding GameEngine string' end

  local moduleStart, moduleEnd = Core.Modules.ue_getMainModuleBoundsInternal()

  if not moduleStart then return nil, 'Unable to determine main module bounds' end

  local vtableRange = '8r:' .. moduleStart .. '-' .. moduleEnd

  local expression = vtableRange ..
                      ' w:' .. (CUEDEFS.UObject.Name - 8) ..
                      ' 4:' .. nameIndex

  local addresses, scanError = Core.Engine.scanEngineObjects( expression, cancellationThread, 1000 )

  if not addresses then return nil, scanError end

  local candidates = Core.Engine.filterEngineVTableCandidates(addresses)

  local instanceAddress, classAddress, instanceError = Core.Engine.resolveLiveEngineInstance( candidates, vtableRange, cancellationThread )

  if not instanceAddress then return nil, instanceError end

  CUEDEFS.UGameEngine = instanceAddress

  -- Store the actual derived class, rather than its GameEngine base class
  if classAddress then CUEDEFS.GameEngineClass = classAddress end

  return Core.Engine.findEngineGlobals( instanceAddress, cancellationThread )
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.CUSTOMTYPES

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// GUOBJECTARRAY VERIFIER TYPE

--- Register GUObjectArray header verifier type
-- The custom type validates the common NumElements/MaxElements/count tuple during structural scans
function Core.CustomTypes.initializeObjectArrayVerifierType()

  local typeName = 'ceUEDumper UObjectArray Verifier'
  local existing = getCustomType(typeName)
  if existing then
    UObjectArray_Verifier_Type = existing
    return
  end

  local registrationError

  UObjectArray_Verifier_Type, registrationError = registerCustomTypeAutoAssembler(cUObjectArrayVerifierType)

  if UObjectArray_Verifier_Type == nil and registrationError then
    error(registrationError)
  end

  UObjectArray_Verifier_Type.InternalOnly = true
  resources.customTypes[typeName] = UObjectArray_Verifier_Type
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// FNAME DISPLAY TYPE

--- Convert an eight-byte FName value into its displayed string
-- @return string @ resolved name with its optional numeric suffix
function Core.CustomTypes.fnameBytesToValue(b1, b2, b3, b4, b5, b6, b7, b8, address)
  local nameIndex = (b4 << 24) + (b3 << 16) + (b2 << 8) + b1
  local nameNumber = (b8 << 24) + (b7 << 16) + (b6 << 8) + b5

  if CUEDEFS and CUEDEFS.IndexToName then

    local resolvedName = CUEDEFS.IndexToName[nameIndex]

    if resolvedName == nil then
      resolvedName = '<noname>'
    end

    if nameNumber > 0 then
      return string.format( "%s_%d", resolvedName, nameNumber )
    else
      return resolvedName
    end

  else
    return 'noindex'
  end

end

--- valueToBytes readonly
function Core.CustomTypes.fnameValueToBytes(i,address) -- TODO: implement FName substitution using the cache
  --maybe use StringToFName, but for now I see no reason for this
end

--- Register the CE custom value type for FName to string
--
-- The eight input bytes are decoded as ComparisonIndex and Number
-- The index is resolved through the validated cached FNamePool
function Core.CustomTypes.setupFName()
  
  local existing = getCustomType('FName')

  -- The stable dispatcher follows the current core after reloads
  resources.fnameConverter = Core.CustomTypes.fnameBytesToValue
  if existing then
    resources.customTypes.FName = existing
    return
  end

  if not existing then

    synchronize(function()
      resources.customTypes.FName =
      registerCustomTypeLua(
                              'FName',
                              8,
                              function(...) return resources.fnameConverter(...) end,
                              Core.CustomTypes.fnameValueToBytes,
                              false,
                              true
                            )

      assert(resources.customTypes.FName, 'Failed to register FName custom type')
    end)
  end
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.OBJECTS

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// OBJECT DISSECT GUESS

--- Test if UObject candidate contains requested address
-- @param candidateObjectAddress number @ possible UObject base address
-- @param targetAddress number @ address expected inside a reflected field
-- @return boolean|nil @ true when a reflected field spans targetAddress
-- @return string|nil @ unreadable-memory error
function Core.Objects.isContainingObjectCandidate(candidateObjectAddress, targetAddress)
  local candidateVTableAddress = readPointer(candidateObjectAddress)

  if candidateVTableAddress == nil then return nil, 'Encountered unreadable memory while locating UObject base' end

  if not Core.Memory.isVTable( candidateVTableAddress ) then return false end

  local objectNameIndex = readInteger( candidateObjectAddress + CUEDEFS.UObject.Name )

  if not objectNameIndex or objectNameIndex == 0 then return false end
  if not Core.Reflection.UObject_getName( candidateObjectAddress ) then return false end

  local propertiesByName = Core.Reflection.UObject_enumProperties( candidateObjectAddress )
  if not propertiesByName then return false end

  for _, propertyMetadata in pairs( propertiesByName ) do
    local propertySize = propertyMetadata.size or 0
    local propertyEndAddress = candidateObjectAddress + propertyMetadata.offset + propertySize

    if propertyEndAddress > targetAddress then return true end
  end

  return false
end

--- Find UObject base containing target address
-- The search moves backwards through aligned addresses, validates possible
-- UObject headers & confirms that one reflected property spans the target
-- @param targetAddress number @ address believed to reside inside a UObject
-- @return number|nil @ containing UObject base address
-- @return string|nil @ error
function Core.Objects.findContainingObject(startAddress) -- TODO: adapt in struct dissect view
  if not (CUEDEFS.UObject and CUEDEFS.UObject.Class and CUEDEFS.UObject.Name) then return nil end

  local isContainingObjectCandidate = Core.Objects.isContainingObjectCandidate
  local targetAddress = startAddress
  local candidateObjectAddress = targetAddress & 0xfffffffffffffff8

  for _ = 1, 4000 do -- inspectedAddressCount
    local isContainingObject, validationError = isContainingObjectCandidate( candidateObjectAddress, targetAddress )

    if validationError then return nil, validationError end
    if isContainingObject then return candidateObjectAddress end

    candidateObjectAddress = candidateObjectAddress - 8
  end

  return nil
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// OBJECT-ITEM / UOBJECT-LAYOUT INFERENCE

--- Count coherent UObject chains for a possible x64 FUObjectItem size
-- @param firstItemAddress number @ first item in the first object chunk
-- @param candidateItemSize number @ candidate FUObjectItem byte size
-- @return number @ number of coherent object/vtable/function chains
function Core.Objects.ue_guessObjectItemStrideInternal(firstItemAddress, candidateItemSize)
  local validObjectCount = 0

  for objectIndex = 0, 31 do
    local objectAddress = readPointer( firstItemAddress + objectIndex * candidateItemSize )

    if not objectAddress or objectAddress == 0 then goto continue end

    objectAddress = objectAddress & 0xFFFFFFFFFFFFFFF8

    local vtableAddress = readPointer(objectAddress)

    if not vtableAddress or vtableAddress == 0 then goto continue end

    local firstFunctionAddress = readPointer(vtableAddress)

    if not firstFunctionAddress or firstFunctionAddress == 0 then goto continue end

    if readByte(firstFunctionAddress) == nil then goto continue end

    validObjectCount = validObjectCount + 1

    ::continue::
  end

  return validObjectCount
end

--- Infer FUObjectItem size from several known layout candidates
-- @param firstItemAddress number @ first item in the first object chunk
-- @return number|nil @ best validated item stride
function Core.Objects.ue_inferObjectItemSizeInternal(firstItemAddress)
  local guessObjectItemStride = Core.Objects.ue_guessObjectItemStrideInternal
  local writeLog = Core.Runtime.log

  local candidateItemSizes = { 0x18, 0x20, 0x10, 0x28, 0x30 }
  local bestItemSize, bestValidObjectCount = nil, 0

  for _, candidateItemSize in ipairs( candidateItemSizes ) do
    local validObjectCount = guessObjectItemStride( firstItemAddress, candidateItemSize )

    writeLog( ('Core.Objects.FindObjectArray: FUObjectItem stride 0x%X scored %d/32'):format( candidateItemSize, validObjectCount ) )

    if validObjectCount > bestValidObjectCount then
      bestItemSize = candidateItemSize
      bestValidObjectCount = validObjectCount
    end

  end

  if bestValidObjectCount >= 2 then
    writeLog( ( 'Core.Objects.FindObjectArray: selected FUObjectItem stride 0x%X' ):format( bestItemSize ) )
    return bestItemSize
  end

  return nil
end

--- Collect UObject addresses from the first 128 FUObjectItem slots
-- @param firstItemAddress number @ first item address
-- @param objectItemSize number @ item stride in bytes
-- @return number[] @ sampled object addresses with pointer flags removed
function Core.Objects.collectUObjectSamples(firstItemAddress, objectItemSize)
  local objectAddresses = {}

  for index = 0, 127 do
    local itemAddress = firstItemAddress + index * objectItemSize
    local objectAddress = readPointer(itemAddress)

    if objectAddress and objectAddress ~= 0 then
      objectAddresses[ #objectAddresses + 1 ] = objectAddress & 0xFFFFFFFFFFFFFFF8
    end
  end

  return objectAddresses
end

--- Select UObject::NamePrivate using UClass metaclass as anchor
-- @param objectAddresses number[] @ sampled UObject addresses
-- @param classOffset number @ selected UObject::ClassPrivate offset
-- @param minimumMatches number @ required match count
-- @return number|nil @ selected FName offset
function Core.Objects.selectUObjectNameOffset(objectAddresses, classOffset, minimumMatches)
  local writeLog = Core.Runtime.log
  local fallbackOffset
  local highestFallbackMatchCount = 0
  local anchoredOffset
  local highestAnchoredMatchCount = 0

  local firstObjectAddress = objectAddresses[1]
  local firstClassAddress = firstObjectAddress and readPointer( firstObjectAddress + classOffset )

  if firstClassAddress then firstClassAddress = firstClassAddress & 0xFFFFFFFFFFFFFFF8 end

  local metaClassAddress = firstClassAddress and readPointer( firstClassAddress + classOffset )

  if metaClassAddress then metaClassAddress = metaClassAddress & 0xFFFFFFFFFFFFFFF8 end

  for candidateOffset = 0x8, 0x40, 4 do

    local overlapsClassPointer = candidateOffset < classOffset + PTR_SIZE and candidateOffset + 8 > classOffset

    if overlapsClassPointer then
      writeLog( ('Core.Objects.FindObjectArray: UObject name offset 0x%X rejected; overlaps ClassPrivate at 0x%X'):format( candidateOffset, classOffset ) )
      goto continue
    end

    -- count name matches
    local matchCount = 0
    for _, objectAddress in ipairs(objectAddresses) do
      local nameIndex = readInteger( objectAddress + candidateOffset )
      local hasNonzeroIndex = nameIndex ~= nil and nameIndex ~= 0

      if hasNonzeroIndex and CUEDEFS.IndexToName[ nameIndex ] then matchCount = matchCount + 1 end
    end

    writeLog( ('Core.Objects.FindObjectArray: UObject name offset 0x%X scored %d/%d'):format( candidateOffset, matchCount, #objectAddresses ) )

    if matchCount > highestFallbackMatchCount then
      fallbackOffset = candidateOffset
      highestFallbackMatchCount = matchCount
    end

    local metaClassNameIndex = metaClassAddress and readInteger( metaClassAddress + candidateOffset )
    local metaClassName = metaClassNameIndex and CUEDEFS.IndexToName[ metaClassNameIndex ]

    if metaClassName == 'Class' and matchCount >= minimumMatches and matchCount > highestAnchoredMatchCount then
      anchoredOffset = candidateOffset
      highestAnchoredMatchCount = matchCount
    end

    ::continue::
  end

  if anchoredOffset then
    writeLog( ('Core.Objects.FindObjectArray: UObject name offset 0x%X anchored by metaclass name Class'):format(anchoredOffset) )
    return anchoredOffset
  end

  if highestFallbackMatchCount < minimumMatches then return nil end

  writeLog('Core.Objects.FindObjectArray: metaclass name anchor unavailable; using aggregate name-match fallback')
  return fallbackOffset
end

--- Sum structural class-pointer confidence across sampled objects
-- 1 point for a readable UClass vtable,
-- 4 points when the candidate reaches the self-referential UClass metaclass
-- @param objectAddresses number[] @ sampled UObject addresses
-- @param classOffset number @ candidate UObject::Class offset
-- @return number @ total confidence score
function Core.Objects.scoreUObjectClassOffset(objectAddresses, classOffset)
  local totalConfidence = 0

  for _, objectAddress in ipairs(objectAddresses) do

    local classAddress = readPointer( objectAddress + classOffset )
    if not classAddress or classAddress == 0 then goto continue end

    classAddress = classAddress & 0xFFFFFFFFFFFFFFF8

    local classVTableAddress = readPointer(classAddress)
    local firstClassFunctionAddress = classVTableAddress and readPointer(classVTableAddress)
    if not firstClassFunctionAddress or readByte(firstClassFunctionAddress) == nil then goto continue end

    totalConfidence = totalConfidence + 1

    local metaClassAddress = readPointer( classAddress + classOffset )
    if not metaClassAddress or metaClassAddress == 0 then goto continue end

    metaClassAddress = metaClassAddress & 0xFFFFFFFFFFFFFFF8

    local metaMetaClassAddress = readPointer( metaClassAddress + classOffset )

    if metaMetaClassAddress then
      metaMetaClassAddress = metaMetaClassAddress & 0xFFFFFFFFFFFFFFF8
    end

    if metaMetaClassAddress == metaClassAddress then
      totalConfidence = totalConfidence + 4 -- metaclass's class ptr refers back to itself
    end

    ::continue::
  end

  return totalConfidence
end

--- Select highest-scoring structurally valid class-pointer offset
-- Equal scores retain the earlier candidate
-- @param objectAddresses number[] @ sampled UObject addresses
-- @param minimumConfidence number @ required confidence score
-- @return number|nil @ selected class-pointer offset
function Core.Objects.selectUObjectClassOffset(objectAddresses, minimumConfidence)
  local scoreClassOffset = Core.Objects.scoreUObjectClassOffset
  local writeLog = Core.Runtime.log
  local selectedOffset
  local highestConfidence = 0

  for candidateOffset = 0x8, 0x40, 8 do
    
    local confidence = scoreClassOffset( objectAddresses, candidateOffset )

    writeLog( ('Core.Objects.FindObjectArray: UObject class offset 0x%X scored %d'):format( candidateOffset, confidence ) )

    if confidence > highestConfidence then
      selectedOffset = candidateOffset
      highestConfidence = confidence
    end

  end

  if highestConfidence < minimumConfidence then return nil end

  return selectedOffset
end

--- Infer UObject::NamePrivate and UObject::ClassPrivate offsets
-- @param firstItemAddress number @ first FUObjectItem address
-- @param objectItemSize number @ selected FUObjectItem byte size
-- @return number|nil @ class-pointer offset
-- @return number|nil @ FName offset
function Core.Objects.ue_inferUObjectOffsetsInternal(firstItemAddress, objectItemSize)

  local objectAddresses = Core.Objects.collectUObjectSamples( firstItemAddress, objectItemSize )  -- TODO: any better?

  local acceptanceThreshold = math.min( 8, #objectAddresses )

  local classOffset = Core.Objects.selectUObjectClassOffset( objectAddresses, acceptanceThreshold )

  if not classOffset then return nil, nil end

  local nameOffset = Core.Objects.selectUObjectNameOffset( objectAddresses, classOffset, acceptanceThreshold )

  if not nameOffset then return nil, nil end

  Core.Runtime.log( ('Core.Objects.FindObjectArray: selected UObject Class=0x%X Name=0x%X'):format( classOffset, nameOffset ) )

  return classOffset, nameOffset
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// OBJECT ARRAY SEARCH

--- Scan the main module for possible FUObjectArray headers
-- @return number[]|nil @ candidate header addresses
-- @return string|nil @ error
function Core.Objects.scanObjectArrayHeaders()

  local modules = enumModules()
  local mainModule = modules and modules[1]

  if not mainModule or not mainModule.Address or not mainModule.Size then return nil, 'Unable to determine main module bounds' end

  local memoryScan = createMemScan()
  memoryScan.VarType = vtGrouped --custom type only also works
  memoryScan.Fastscanmethod = fsmAligned
  memoryScan.Fastscanparameter = 10
  memoryScan.ScanValue = 'BA:8 c(ceUEDumper UObjectArray Verifier):1 p:D'
  memoryScan.Startaddress = mainModule.Address
  memoryScan.Stopaddress = mainModule.Address + mainModule.Size

  memoryScan.scan()
  memoryScan.waitTillDone()

  local results = memoryScan.Results
  local scanError = memoryScan.ErrorString

  memoryScan.destroy()

  if not results or #results == 0 then return nil, 'Failed finding anything (' .. (scanError or '') .. ')' end

  return results
end

--- Filter headers using first-DWORD heuristic
-- @param addresses number[] @ candidate header addresses
-- @param allowZero boolean @ accept zero as well as values above 100
-- @return number[] @ retained candidates
function Core.Objects.filterObjectArrayHeaderValues(addresses, allowZero)
  local filteredAddresses = {}

  for _, address in ipairs(addresses) do
    local headerValue = readInteger(address)
    local accepted = false

    if headerValue ~= nil then
      accepted = headerValue > 100 or (allowZero and headerValue == 0)
    end

    if accepted then
      filteredAddresses[#filteredAddresses + 1] = address
    end
  end

  return filteredAddresses
end

--- Narrow ambiguous array headers. Single candidates bypass further filtering
-- @param addresses number[] @ scanned header candidates
-- @return number[] @ remaining candidates
function Core.Objects.refineObjectArrayHeaders(addresses)
  if #addresses <= 1 then return addresses end

  addresses = Core.Objects.filterObjectArrayHeaderValues( addresses, true )
  if #addresses <= 1 then return addresses end

  addresses = Core.Objects.filterObjectArrayHeaderValues( addresses, false )

  local filteredAddresses = {}

  for _, address in ipairs(addresses) do
    --check if the first pointer pointed at is valid
    -- (there are currently 2 known types. Both both have a pointer at the first entry)
    local storageAddress = readPointer( address + 0x10 )
    if not storageAddress or storageAddress == 0 then goto continue end

    local firstPointer = readPointer(storageAddress)
    if not firstPointer or firstPointer == 0 then goto continue end

    if readPointer(firstPointer) ~= nil then
      filteredAddresses[#filteredAddresses + 1] = address
    end

    ::continue::
  end

  return filteredAddresses
end

--- Resolve existing or scanned FUObjectArray header
-- @param cancellationThread table|nil @ scan worker
-- @return number|nil @ selected array address
-- @return string|nil @ error
-- @return number[]|nil @ remaining ambiguous candidates
function Core.Objects.locateObjectArray(cancellationThread)
  local candidates

  if CUEDEFS.ObjectArray ~= nil then -- found already
    candidates = { CUEDEFS.ObjectArray }
  else

    local scanError
    candidates, scanError = Core.Objects.scanObjectArrayHeaders()

    if cancellationThread and cancellationThread.Terminated then return nil, 'ueScannerThread terminated' end

    if not candidates then return nil, scanError end

    candidates = Core.Objects.refineObjectArrayHeaders(candidates)

    if #candidates > 1 then return nil, 'Needs more refining', candidates end

  end

  if cancellationThread and cancellationThread.Terminated then return nil, 'ueScannerThread terminated' end

  if #candidates ~= 1 then return nil, 'Core.Objects.FindObjectArray needs more filtering' end

  return candidates[1]
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// GOBJECT STORAGE LAYOUT

--- Test possible single chunk through its first object's virtual functions
-- @param chunkAddress number|nil @ candidate chunk address
-- @return boolean @ true when its first three virtual functions are executable
function Core.Objects.looksLikeSingleObjectChunk(chunkAddress)
  if not chunkAddress or chunkAddress == 0 then return false end

  local objectAddress = readPointer(chunkAddress)
  if not objectAddress or objectAddress == 0 then return false end

  local vtableAddress = readPointer(objectAddress)
  if not vtableAddress or vtableAddress == 0 then return false end

  for functionOffset = 0, 16, 8 do
    local functionAddress = readPointer( vtableAddress + functionOffset )

    --3 valid pointers to executable memory. Guess it's just a small list  (single)
    if not functionAddress then return false end
    if not Core.Memory.isInExecutableMainModuleMemory(functionAddress) then return false end
  end

  return true
end

--- Distinguish chunked storage from a contiguous FUObjectItem array
-- two-readable-pointers and single-chunk heuristics
-- @param arrayAddress number @ FUObjectArray header
-- @return number|nil @ first FUObjectItem address
-- @return number|nil @ storage type. zero for chunked, one for contiguous
-- @return string|nil @ error
function Core.Objects.resolveObjectItemStorage(arrayAddress)
  --get the first block
  --test what type of list this is. pointer list, or a (huge) list of ObjectArray entries
  local storageAddress = readPointer( arrayAddress + 0x10 )
  if not storageAddress or storageAddress == 0 then return nil, nil, 'Object array storage is unreadable' end

  local firstPointer = readPointer(storageAddress)
  local secondPointer = readPointer( storageAddress + 8 )

  local firstReadable = firstPointer and readByte(firstPointer) ~= nil
  local secondReadable = secondPointer and readByte(secondPointer) ~= nil

  if firstReadable and secondReadable then
    return firstPointer, 0
  end

  -- a chunked array with only one initialized chunk can fail the first test
  if Core.Objects.looksLikeSingleObjectChunk(firstPointer) then
    return firstPointer, 0
  end

  --list of Object entries (or the list is just 1 long. Maybe launched too soon?)
  return storageAddress, 1
end

--- Feedback only. Log if the first object's virtual-function chain looks usable
-- @param firstItemAddress number @ first FUObjectItem address
-- @return nil
function Core.Objects.logFirstObjectVTable(firstItemAddress) -- TODO: debugging
  -- validate the first vtable function
  -- use PE sections when available & executable memory regions
  local objectAddress = readPointer(firstItemAddress)
  local vtableAddress = objectAddress and readPointer(objectAddress)
  local functionAddress = vtableAddress and readPointer(vtableAddress)

  if not functionAddress then
    Core.Runtime.log('Core.Objects.FindObjectArray: doesn\'t look like a valid object')
    return
  end

  if not Core.Memory.isInExecutableMainModuleMemory(functionAddress) then
    Core.Runtime.log('Core.Objects.FindObjectArray: first object vtable is outside executable module memory')
  end

end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// FUOBJECTITEM STRIDE

--- Locate possible object-pointer slots using the current vtable validator
-- @param firstItemAddress number @ beginning of object-item storage
-- @return number[] @ matching byte offsets relative to firstItemAddress
function Core.Objects.findLegacyObjectItemOffsets(firstItemAddress)
  local isVTable = Core.Memory.isVTable
  local itemOffsets = {}

  for candidateOffset = 0, 0x80, 4 do
    local objectAddress = readPointer( firstItemAddress + candidateOffset )
    local vtableAddress = objectAddress and readPointer(objectAddress)

    if vtableAddress and isVTable(vtableAddress) then
      itemOffsets[#itemOffsets + 1] = candidateOffset
    end

  end

  return itemOffsets
end

--- Infer item stride, falling back to progressively broader vtable checks
-- A fallback mode is tried only when the previous mode found no slots
-- @param firstItemAddress number @ first FUObjectItem address
-- @return number|nil @ inferred item stride
-- @return number[]|nil @ item offsets available for legacy UObject inference
-- @return string|nil @ error
function Core.Objects.findObjectItemStride(firstItemAddress)

  local inferredSize = Core.Objects.ue_inferObjectItemSizeInternal(firstItemAddress)

  if inferredSize then return inferredSize, { 0, inferredSize } end

  local itemOffsets = Core.Objects.findLegacyObjectItemOffsets(firstItemAddress)

  for _, validationMethod in ipairs ( { 2, 3 } ) do
    if #itemOffsets > 0 then break end

    CUEDEFS.VFTableInExecutableMemoryMethod = validationMethod
    CUEDEFS.ExecutableRanges = nil

    itemOffsets = Core.Objects.findLegacyObjectItemOffsets(firstItemAddress)
  end

  if #itemOffsets <= 1 then return nil, nil, 'Unable to infer ObjectArrayEntryStruct size' end

  return itemOffsets[2] - itemOffsets[1], itemOffsets
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// LEGACY UOBJECT INFERENCE

--- Follow repeated member offset until object points to itself
-- @param objectAddress number @ starting UObject
-- @param classOffset number @ candidate class-pointer offset
-- @return number|nil @ self-referencing metaclass address
function Core.Objects.findSelfReferencingMetaClass(objectAddress, classOffset)
  local currentAddress = readPointer( objectAddress + classOffset )

  for _ = 1, 20 do

    if not currentAddress or currentAddress == 0 then return nil end

    local nextAddress = readPointer( currentAddress + classOffset )
    if not nextAddress or nextAddress == 0 then return nil end

    if nextAddress == currentAddress then return currentAddress end

    currentAddress = nextAddress
  end

  return nil
end

--- Record name & class-offset evidence from candidate metaclass
-- Each matching name member receives a vote; the class offset receives one
-- vote when at least one matching name member exists
-- @param metaClassAddress number @ self-referencing candidate metaclass
-- @param classOffset number @ candidate UObject::Class offset
-- @param classNameIndex number @ FName index for Class
-- @param classVotes table @ mutable class-offset vote counts
-- @param nameVotes table @ mutable name-offset vote counts
-- @return nil
function Core.Objects.recordMetaClassOffsetVotes( metaClassAddress, classOffset, classNameIndex, classVotes, nameVotes )
  local foundClassName = false

  for nameOffset = 8, 0x50, 4 do
    local nameIndex = readInteger( metaClassAddress + nameOffset )

    if nameIndex == classNameIndex then
      foundClassName = true
      nameVotes[nameOffset] = (nameVotes[nameOffset] or 0) + 1
    end

  end

  if foundClassName then
    classVotes[classOffset] = (classVotes[classOffset] or 0) + 1
  end

end

--- Collect legacy class/name offset votes from one UObject
-- @param objectAddress number @ sampled UObject address
-- @param classNameIndex number @ FName index for Class
-- @param classVotes table @ mutable class-offset vote counts
-- @param nameVotes table @ mutable name-offset vote counts
-- @return nil
function Core.Objects.collectLegacyUObjectVotes( objectAddress, classNameIndex, classVotes, nameVotes )
  local findMetaClass = Core.Objects.findSelfReferencingMetaClass
  local recordVotes = Core.Objects.recordMetaClassOffsetVotes

  for classOffset = 8, 0x50, 8 do

    local metaClassAddress = findMetaClass( objectAddress, classOffset )
    if metaClassAddress then
      recordVotes( metaClassAddress, classOffset, classNameIndex, classVotes, nameVotes )
    end

  end

end

--- Select offset with highest vote count
-- Equal counts retain the first entry encountered by pairs
-- @param votes table<number, number> @ vote count indexed by byte offset
-- @return number|nil @ highest-voted offset
function Core.Objects.selectHighestVotedOffset(votes)
  local selectedOffset
  local highestCount = 0

  for offset, count in pairs(votes) do

    if count > highestCount then
      selectedOffset = offset
      highestCount = count
    end

  end

  return selectedOffset
end

--- Infer UObject members using self-referencing metaclasses named Class
-- @param firstItemAddress number @ beginning of object-item storage
-- @param itemOffsets number[] @ known candidate item offsets
-- @return number|nil @ class-pointer offset
-- @return number|nil @ FName offset
-- @return string|nil @ error
function Core.Objects.inferLegacyUObjectOffsets(firstItemAddress, itemOffsets)
  local classNameIndex = CUEDEFS.NameToIndex['Class']
  if classNameIndex == nil then return nil, nil, 'There is no Class class' end
  
  local collectVotes = Core.Objects.collectLegacyUObjectVotes
  local selectHighestVotedOffset = Core.Objects.selectHighestVotedOffset

  local classVotes = {}
  local nameVotes = {}

  for _, itemOffset in ipairs(itemOffsets) do

    local objectAddress = readPointer( firstItemAddress + itemOffset )
    if objectAddress and objectAddress ~= 0 then
      collectVotes( objectAddress, classNameIndex, classVotes, nameVotes )
    end

  end

  local classOffset = selectHighestVotedOffset(classVotes)
  local nameOffset = selectHighestVotedOffset(nameVotes)

  if not classOffset or not nameOffset then return nil, nil, 'Legacy UObject class/name offset inference failed' end

  return classOffset, nameOffset
end

--- Infer & store fundamental UObject member offsets
-- direct inference is main, structural guessing - fallback
-- @param firstItemAddress number @ first FUObjectItem address
-- @param itemSize number @ inferred FUObjectItem stride
-- @param itemOffsets number[] @ candidate offsets for legacy sampling
-- @return boolean @ true when both required offsets were found
-- @return string|nil @ error
function Core.Objects.findUObjectLayout(firstItemAddress, itemSize, itemOffsets)
  
  local classOffset, nameOffset = Core.Objects.ue_inferUObjectOffsetsInternal( firstItemAddress, itemSize )

  if not classOffset or not nameOffset then
    local inferenceError

    classOffset, nameOffset, inferenceError = Core.Objects.inferLegacyUObjectOffsets( firstItemAddress, itemOffsets )

    if not classOffset or not nameOffset then return false, inferenceError end
  end

  CUEDEFS.UObject =
  {
    Class = classOffset, -- UClass
    Name = nameOffset, -- Fname
  }

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// GOBJECTS SEARCH ENTRY POINT

--- Find GUObjectArray, its storage layout, and fundamental UObject members
--
-- 1. Locate or validate the FUObjectArray header
-- 2. Determine chunked versus contiguous object storage
-- 3. Infer FUObjectItem stride from readable UObject/vtable chains
-- 4. Infer UObject::ClassPrivate and UObject::NamePrivate
-- 5. Retain legacy structural inference when direct inference is inconclusive
--
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when the required layout is ready
-- @return string|nil @ error
-- @return number[]|nil @ ambiguous array candidates
function Core.Objects.FindObjectArray(cancellationThread)
  --[[ layout
    FUObjectArray/GUObjectArray
    ├─ +0x10 ObjObjects.Objects
    │
    │  Chunked storage (case 0)
    │  └─ FUObjectItem** chunkPointers
    │     ├─ chunkPointers[0] -> FUObjectItem[]
    │     ├─ chunkPointers[1] -> FUObjectItem[]
    │     └─ ...
    │
    │  Contiguous storage (case 1)
    │  └─ FUObjectItem* items
    │     ├─ items[0]
    │     ├─ items[1]
    │     └─ ...
    │
    ├─ +0x20 MaxElements
    ├─ +0x24 NumElements
    ├─ +0x28 MaxChunks
    └─ +0x2C NumChunks

    FUObjectItem entry (size varies)
    ├─ UObject* Object
    ├─ object flags / bookkeeping
    └─ ...

    UObject
    ├─ +0x00 vtable table
    ├─ EObjectFlags ObjectFlags
    ├─ int32 InternalIndex
    ├─ UClass* ClassPrivate   (what we infer here)
    ├─ FName NamePrivate      (what we infer here)
    └─ UObject* OuterPrivate
  ]]

  --[[ inference flow
    
    locateObjectArray
    ├─ if found by sig finder, use CUEDEFS.ObjectArray
    └─ otherwise use struct scan fallback
      ├─ scanObjectArrayHeaders
      │  └─ scan main module using verifier type
      └─ refineObjectArrayHeaders
          ├─ reject implausible first DWORD values
          ├─ inspect storage pointer at candidate + 0x10
          ├─ verify that its first pointer is readable
          └─ require exactly 1 surviving candidate
  
    resolveObjectItemStorage
    ├─ read ObjObjects.Objects (ObjectArray+0x10)
    ├─ inspect first two pointers in that storage
    ├─ both point to readable memory?
    │  └─ classify it as chunked storage (case 0)
    ├─ looksLikeSingleObjectChunk?
    │  └─ test a chunked array with only one inited chunk by checking first object v_funcs
    └─ otherwise classify storage as one contiguous item array (case 1)
    
    findObjectItemStride
    ├─ inferObjectItemSize
    │  ├─ test known FUObjectItem sizes
    │  │  ├─ 0x18
    │  │  ├─ 0x20
    │  │  ├─ 0x10
    │  │  ├─ 0x28
    │  │  └─ 0x30
    │  └─ guessObjectItemStride
    │     ├─ walk the first 32 proposed item slots
    │     ├─ read each proposed UObject pointer
    │     ├─ read its vtable and first v_func
    │     └─ select stride producing most coherent objects
    └─ if known-size inference fails (original fallback heuristic)
      ├─ findLegacyObjectItemOffsets
      │  ├─ scan first 0x80 bytes for UObject-like pointers
      │  └─ keep offsets whose objects have recognized vtables
      ├─ retry with broader executable-memory validation modes
      └─ derive the stride from the diff of first 2 accepted object-item positions
    
    findUObjectLayout
    ├─ direct UObject-layout inference
    │  └─ inferUObjectOffsets
    │     ├─ collectUObjectSamples
    │     │  └─ collect up to 128 UObject ptrs using FUObjectItem stride
    │     ├─ selectUObjectNameOffset
    │     │  ├─ test aligned offsets (0x08...0x40)
    │     │  ├─ interpret each val as FName index
    │     │  └─ choose offset hitting most cached names
    │     └─ selectUObjectClassOffset
    │        ├─ test ptr-aligned offsets (0x08...0x40)
    │        ├─ scoreUObjectClassOffset
    │        │  ├─ require readable class pts
    │        │  ├─ favor resolvable class names
    │        │  └─ strongly favor self-referencing UClass metaclass invariant:
    │        │       object.Class -> class.Class -> UClass.Class -> UClass
    │        └─ strongest guess wins
    └─ direct inference inconclusive? Using original legacy inference:
      └─ inferLegacyUObjectOffsets
          ├─ obtain cached FName index of 'Class'
          ├─ sample UObject ptrs with inferred offsets
          ├─ collectLegacyUObjectVotes
          │  ├─ try possible class offsets (0x08...0x50)
          │  ├─ findSelfReferencingMetaClass
          │  │  └─ follow each candidate member until reaching
          │  │     UClass whose Class pointer references itself
          │  └─ recordMetaClassOffsetVotes
          │     ├─ search that metaclass for 'Class' FName
          │     ├─ vote for matching name offsets
          │     └─ vote for class offsets producing valid metaclasses
          └─ select the strongest class & name offsets
  ]]

  if UObjectArray_Verifier_Type == nil then
    -- this type recognizes the common FUObjectArray count/header relationship
    Core.CustomTypes.initializeObjectArrayVerifierType()
    if UObjectArray_Verifier_Type == nil then return nil, 'No verifier type' end
  end

  local arrayAddress, arrayError, candidates = Core.Objects.locateObjectArray( cancellationThread )
  if not arrayAddress then return false, arrayError, candidates end
  CUEDEFS.ObjectArray = arrayAddress -- addr of the global FUObjectArray header

  local firstItemAddress, storageType, storageError = Core.Objects.resolveObjectItemStorage( arrayAddress )
  if not firstItemAddress then return false, storageError end
  CUEDEFS.ObjectArrayListType = storageType -- whether its FUObjectItem storage is chunked/contiguous
  
  -- Core.Objects.logFirstObjectVTable(firstItemAddress)

  local itemSize, itemOffsets, strideError = Core.Objects.findObjectItemStride( firstItemAddress )
  if not itemSize then return false, strideError end
  CUEDEFS.ObjectArrayEntryStructSize = itemSize -- for iterating objects
  
  -- CUEDEFS.UObject.Class -- offset to UObject::ClassPrivate
  -- CUEDEFS.UObject.Name -- offset to UObject::NamePrivate
  return Core.Objects.findUObjectLayout( firstItemAddress, itemSize, itemOffsets )
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.NAMES

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// LEGACY STRING REGIONS

--- Determine how many bytes to cache for a legacy string region
-- Extends across adjacent committed regions, up to 64 KiB plus overlap
-- @param blockBaseAddress number @ aligned string-region address
-- @return number @ readable region size, or zero when unavailable
function Core.Names.getLegacyStringRegionSize(blockBaseAddress)
  
  local committedState = 4096 --4096 is commited memory
  local maximumCacheSize = 0x10000 + 0x100 --0x100 for overlap
  local region = getMemoryRegionInfo(blockBaseAddress)

  if not region or region.State ~= committedState then return 0 end

  local regionSize = region.RegionSize

  while regionSize < maximumCacheSize do
    local nextRegionAddress = region.BaseAddress + regionSize
    local nextRegion = getMemoryRegionInfo(nextRegionAddress)

    if not nextRegion or nextRegion.State ~= committedState then break end
    if nextRegion.RegionSize <= 0 then break end

    regionSize = regionSize + nextRegion.RegionSize
  end

  return math.min( regionSize, maximumCacheSize )
end

--- Retrieve or populate a cached region containing legacy string bytes
-- An empty stream represents an unreadable region and prevents repeated reads
-- @param blockBaseAddress number @ aligned region address
-- @param regionStreams table @ stream cache indexed by region address
-- @return userdata @ cached memory stream
function Core.Names.getLegacyStringRegion(blockBaseAddress, regionStreams)
  local cachedStream = regionStreams[ blockBaseAddress ]
  if cachedStream then return cachedStream end

  cachedStream = createMemoryStream() -- we free them later
  cachedStream.Size = 0

  -- cache the stream before reading so cleanup also covers read errors
  regionStreams[ blockBaseAddress ] = cachedStream

  local regionSize = Core.Names.getLegacyStringRegionSize(blockBaseAddress)
  if regionSize == 0 then return cachedStream end

  cachedStream.Size = regionSize

  local copied = copyMemory( blockBaseAddress, regionSize, cachedStream.Memory, 1 )

  if copied == nil then cachedStream.Size = 0 end

  return cachedStream
end

--- Decode a legacy name entry using its cached string region
-- @param entryAddress number @ FNameEntry address
-- @param stringOffset number @ string-member offset within FNameEntry
-- @param regionStreams table @ per-chunk memory-region cache
-- @return string|nil @ decoded name
function Core.Names.readLegacyEntryName(entryAddress, stringOffset, regionStreams)

  --get the memory p+StringOffset points to
  local blockBaseAddress = entryAddress & 0xFFFFFFFFFFFF0000 --allocation granularity of windows
  local cachedStream = Core.Names.getLegacyStringRegion( blockBaseAddress, regionStreams )

  local stringPosition = entryAddress - blockBaseAddress + stringOffset
  local remainingBytes = cachedStream.Size - stringPosition

  if remainingBytes <= 0 then return nil end

  cachedStream.Position = stringPosition

  return cachedStream.readString( math.min( 100, remainingBytes ) )
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// LEGACY NAME CHUNKS

--- Copy & decode one legacy name chunk
-- Unreadable chunks are skipped
-- @param chunkAddress number @ target-process chunk address
-- @param chunkIndex number @ zero-based chunk index
-- @param chunkStream userdata @ reusable entry-pointer stream
-- @param stringOffset number @ FNameEntry string-member offset
-- @param nameMaps table @ mutable forward and reverse name maps
-- @return nil
function Core.Names.cacheLegacyNameChunk( chunkAddress, chunkIndex, chunkStream, stringOffset, nameMaps )
  local readLegacyEntryName = Core.Names.readLegacyEntryName
  chunkStream.Position = 0

  --entrystart is always aligned on a 2 byte boundary.
  local copied = copyMemory( chunkAddress, chunkStream.Size, chunkStream.Memory, 1 )

  if not copied then return end

  local entriesPerChunk = 16384 -- 0x20000 / 8-byte pointer = 16384 FNameEntry pointers
  local firstNameIndex = chunkIndex * entriesPerChunk
  local regionStreams = {}

  for entryIndex = 0, entriesPerChunk - 1 do
    
    --list of pointers, some can be 0
    local entryAddress = chunkStream.readQword()

    if entryAddress == nil then break end

    if entryAddress == 0 then goto continue end

    local decodedName = readLegacyEntryName( entryAddress, stringOffset, regionStreams )

    if not decodedName then goto continue end

    local nameIndex = firstNameIndex + entryIndex

    nameMaps.nameToIndex[decodedName] = nameIndex
    nameMaps.indexToName[nameIndex] = decodedName

    ::continue::
  end

  -- free all allocated streams
  for _, cachedStream in pairs(regionStreams) do
    cachedStream.destroy()
  end

end

--- Read the chunk-pointer table and populate both legacy name maps
-- @param pointerListStream userdata @ reusable chunk-pointer stream
-- @param chunkStream userdata @ reusable entry-pointer stream
-- @param nameMaps table @ mutable forward and reverse name maps
-- @return boolean|nil @ true when traversal completes
-- @return string|nil @ error
function Core.Names.populateLegacyNameMaps(pointerListStream, chunkStream, nameMaps)
  local cacheLegacyNameChunk = Core.Names.cacheLegacyNameChunk
  local maximumChunkCount = 1000
  local stringOffset = CUEDEFS.FNameEntry.String
  
  --each block is 0x20000 bytes long
  --the list ends with a NULL pointer
  pointerListStream.Size = 8 * maximumChunkCount
  pointerListStream.Position = 0
  chunkStream.Size = 0x20000

  local copied = copyMemory( CUEDEFS.NamePoolData, pointerListStream.Size, pointerListStream.Memory, 1 )

  if copied == nil then return nil, 'copyMemory Failed' end

  for chunkIndex = 0, maximumChunkCount - 1 do
    local chunkAddress = pointerListStream.readQword()

    if chunkAddress == 0 then break end

    cacheLegacyNameChunk( chunkAddress, chunkIndex, chunkStream, stringOffset, nameMaps )
  end

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// BLOCK DECODING

--- Decode one copied modern FNamePool block
-- Entry identifiers combine the block index and the two-byte entry offset
-- @param blockStream userdata @ copied block, positioned at its beginning
-- @param blockIndex number @ zero-based block index
-- @param nameMaps table @ mutable forward and reverse name maps
-- @param validByteCount number @ initialized bytes available in this block
-- @return number @ number of decoded entries
function Core.Names.decodeNamePoolBlock(blockStream, blockIndex, nameMaps, validByteCount)
  local decodedCount = 0
  local headerShift = CUEDEFS.FNameHeaderShift or 6
  local blockNameIndex = blockIndex << 16
  local blockLimit = math.min( validByteCount, blockStream.Size )

  while blockStream.Position + 2 <= blockLimit do

    local entryOffset = blockStream.Position >> 1
    local entryHeader = blockStream.readWord()

    local isWideName = (entryHeader & 1) == 1
    local nameLength = entryHeader >> headerShift

    if nameLength == 0 then break end

    local payloadSize = isWideName and nameLength * 2 or nameLength

    -- CurrentBlock is only initialized through CurrentByteCursor
    -- reject a truncated or garbage header instead of asking the CE stream to overread
    if blockStream.Position + payloadSize > blockLimit then break end

    local decodedName

    if isWideName then  decodedName = blockStream.readWideString(nameLength)
    else                decodedName = blockStream.readString(nameLength)
    end

    if decodedName ~= nil then
      local nameIndex = blockNameIndex + entryOffset

      nameMaps.nameToIndex[decodedName] = nameIndex
      nameMaps.indexToName[nameIndex] = decodedName
      decodedCount = decodedCount + 1
    end

    -- Each subsequent entry begins on a two-byte boundary
    if (blockStream.Position & 1) ~= 0 and blockStream.Position < blockLimit then
      blockStream.readByte()
    end

  end

  return decodedCount
end

--- Copy & decode one block using a reusable memory stream
-- Unreadable blocks are reported and skipped
-- @param blockAddress number @ target-process block address
-- @param blockIndex number @ zero-based block index
-- @param blockStream userdata @ reusable block buffer
-- @param nameMaps table @ mutable forward and reverse name maps
-- @param validByteCount number @ initialized bytes to copy and decode
-- @return nil
function Core.Names.cacheNamePoolBlock(blockAddress, blockIndex, blockStream, nameMaps, validByteCount)
  local decodeNamePoolBlock = Core.Names.decodeNamePoolBlock
  local writeLog = Core.Runtime.log
  blockStream.Position = 0

  local decodedCount = 0
  local copied = true

  if validByteCount > 0 then
    copied = copyMemory( blockAddress, validByteCount, blockStream.Memory, 1 )
  end

  if copied then  decodedCount = decodeNamePoolBlock( blockStream, blockIndex, nameMaps, validByteCount )
  else            print('Failure reading strings')
  end

  writeLog( ('Core.Names.CacheNamePool: block %d cached %d names; parser stopped at 0x%X'):format( blockIndex, decodedCount, blockStream.Position ) )
end

--- Read initialized block pointers and populate the modern name maps
-- Cancellation is checked before processing each block
-- @param blockCount number @ number of initialized block pointers
-- @param pointerList userdata @ reusable block-pointer buffer
-- @param blockStream userdata @ reusable block buffer
-- @param nameMaps table @ mutable forward and reverse name maps
-- @param currentBlockIndex number @ zero-based partially populated block index
-- @param currentBlockByteCursor number @ initialized byte count in current block
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when traversal completes
-- @return string|nil @ error
function Core.Names.populateNamePoolMaps( blockCount, pointerList, blockStream, nameMaps, currentBlockIndex, currentBlockByteCursor, cancellationThread )
  local cacheNamePoolBlock = Core.Names.cacheNamePoolBlock
  pointerList.Size = 8 * blockCount
  pointerList.Position = 0
  blockStream.Size = 0x20000

  local copied = copyMemory( CUEDEFS.NamePoolData + 0x10, pointerList.Size, pointerList.Memory, 1 )

  if copied == nil then return nil, 'Read Failed' end

  for blockIndex = 0, blockCount - 1 do
    if cancellationThread and cancellationThread.Terminated then return false, 'ueScannerThread terminated' end

    local blockAddress = pointerList.readQword()
    if blockAddress == 0 then break end

    local validByteCount = blockStream.Size

    if blockIndex == currentBlockIndex then
      validByteCount = currentBlockByteCursor
    end

    cacheNamePoolBlock( blockAddress, blockIndex, blockStream, nameMaps, validByteCount )
  end

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// BUFFER LIFETIME

--- Populate name maps while ensuring both temporary streams are released
-- @param blockCount number @ initialized block count
-- @param nameMaps table @ mutable forward and reverse name maps
-- @param currentBlockIndex number @ zero-based partially populated block index
-- @param currentBlockByteCursor number @ initialized byte count in current block
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ traversal result
-- @return string|nil @ error
function Core.Names.readNamePoolMaps(blockCount, nameMaps, currentBlockIndex, currentBlockByteCursor, cancellationThread)
  local pointerList
  local blockStream

  --each block is 0x20000 bytes long
  -- FNameEntryAllocator+0x8 is CurrentBlock, a zero-based block index
  -- the number of initialized block pointers is CurrentBlock+1
  pointerList = createMemoryStream()
  blockStream = createMemoryStream()

  local populated, cacheError
  = Core.Names.populateNamePoolMaps(
                                    blockCount,
                                    pointerList,
                                    blockStream,
                                    nameMaps,
                                    currentBlockIndex,
                                    currentBlockByteCursor,
                                    cancellationThread
                                  )

  blockStream.destroy()
  pointerList.destroy()

  return populated, cacheError
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// CACHE PUBLICATION

--- Publish decoded names
-- CachedNameCount counts unique names, not decoded entries
-- @param nameMaps table @ completed forward and reverse name maps
-- @return nil
function Core.Names.publishNamePoolMaps(nameMaps)
  local nameToIndex = nameMaps.nameToIndex
  local uniqueNameCount = 0

  for _ in pairs(nameToIndex) do
    uniqueNameCount = uniqueNameCount + 1
  end

  CUEDEFS.NameToIndex = nameToIndex
  CUEDEFS.IndexToName = nameMaps.indexToName
  CUEDEFS.CachedNameCount = uniqueNameCount
  CUEDEFS.NamePoolValidated = uniqueNameCount > 355 and nameToIndex.Class ~= nil and nameToIndex.Object ~= nil -- heuristic validation

  Core.Runtime.log(
        ('Core.Names.CacheNamePool: cached %d names with header shift %d; GameEngine=%s')
        :format( uniqueNameCount, CUEDEFS.FNameHeaderShift or 6, tostring( nameToIndex['GameEngine'] ~= nil ) )
      )
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// CACHE ENTRY POINT

--- Decode and cache the legacy pointer-based GNames layout
-- Publishes the new maps only after traversal completes successfully
-- @return boolean|nil @ true when traversal completes
-- @return string|nil @ error
function Core.Names.CacheNamePool_old()
  Core.Runtime.log('Core.Names.CacheNamePool_old')
  if CUEDEFS.NamePoolData == nil then return nil, 'CUEDEFS.NamePoolData not defined yet' end
  --[[
    Each entry-pointer chunk is 0x20000 bytes
    0x20000 / 8-byte pointer = 16384 FNameEntry pointers
    FName indices are reconstructed from their position:
    nameIndex = chunkIndex * 16384 + entryIndex
  ]]

  -- by ref
  local nameMaps =
  {
    nameToIndex = {},
    indexToName = {},
  }
  -- allocate two reusable local memory streams
  local pointerListStream = createMemoryStream() -- pointerList receives the top-level GNames chunk pointers
  local chunkStream = createMemoryStream() -- receives one 0x20000-byte entry-pointer chunk at a time

  --[[
    copy up to 1k ptr from the GNames block-pointer list; stop at the first null chunk pointer
    cacheLegacyNameChunk() for every initialized chunk
    ├─ copy its 0x20000 bytes into chunkStream
    ├─ iterate through its 16384 FNameEntry pointers
    ├─ skip null or unreadable entry pointers
    └─ readLegacyEntryName
       ├─ locate/cache the entry's surrounding memory region
       ├─ add CUEDEFS.FNameEntry.String to the entry address
       └─ decode the null-terminated legacy name
  ]]
  local populated, cacheError = Core.Names.populateLegacyNameMaps( pointerListStream, chunkStream, nameMaps )

  chunkStream.destroy()
  pointerListStream.destroy()

  if not populated then return nil, cacheError end

  CUEDEFS.NameToIndex = nameMaps.nameToIndex -- CUEDEFS.NameToIndex["None"] = 0
  CUEDEFS.IndexToName = nameMaps.indexToName -- CUEDEFS.IndexToName[0] = "None"

  return true
end

--- Decode the active name pool and publish its name maps
-- Legacy pointer-based pools use their separate decoder
-- Successful traversal does not necessarily mean name-pool validation passed
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when cache traversal completes
-- @return string|nil @ error
function Core.Names.CacheNamePool(cancellationThread)
  Core.Runtime.log('Core.Names.CacheNamePool')

  if CUEDEFS.NamePoolData == nil then return false, 'Core.Names.CacheNamePool: CUEDEFS.NamePoolData is still undefined' end
  if CUEDEFS.NamePoolData_old then    return Core.Names.CacheNamePool_old(cancellationThread)   end

  --[[ read & validate the modern name allocator's block state
    FNameEntryAllocator
    ├─ +0x08 CurrentBlock (zero-based)
    ├─ +0x0C CurrentByteCursor (bounds its initialized data)
    └─ +0x10 Blocks[]
      ├─ Blocks[0] → name block 0
      │               ├─ FNameEntryHeader
      │               ├─ "None"
      │               ├─ alignment padding
      │               ├─ FNameEntryHeader
      │               ├─ "ByteProperty"
      │               └─ ...
      ├─ Blocks[1] → name block 1
      └─ Blocks[CurrentBlock] → partially populated current block

    Each block reserves 0x20000 bytes & stores FNameEntry values inline
      name block
      ├─ entry header
      ├─ ANSI/UTF-16 name data
      ├─ optional alignment byte
      ├─ next entry header
      ├─ next name data
      └─ ...

    Completed blocks may be decoded through their entire 0x20000-byte capacity

    The active block must stop at CurrentByteCursor
      Blocks[CurrentBlock]
      ├─ 0x00000 .. CurrentByteCursor → initialized FNameEntry data
      └─ CurrentByteCursor .. 0x20000 → unused memory; we don't touch it to avoid stream failure

    FNameEntryId combines block index & entry's two-byte offset
      entryOffset = entryByteOffset >> 1
      nameIndex = blockIndex << 16 | entryOffset
  ]]
  local currentBlockIndex = readInteger( CUEDEFS.NamePoolData + 8 )
  local currentBlockByteCursor = readInteger( CUEDEFS.NamePoolData + 0xC ) -- avoiding read errors

  if currentBlockIndex == nil then return false, 'Core.Names.CacheNamePool: invalid CurrentBlock value nil' end
  if currentBlockIndex < 0 or currentBlockIndex > 8191 then return false, 'Core.Names.CacheNamePool: invalid CurrentBlock value ' .. currentBlockIndex end
  if type(currentBlockByteCursor) ~= 'number' or currentBlockByteCursor < 0 or currentBlockByteCursor > 0x20000 then
    return false, 'Core.Names.CacheNamePool: invalid CurrentByteCursor value ' .. tostring(currentBlockByteCursor)
  end
  
  local initializedBlockCount = currentBlockIndex + 1
  Core.Runtime.log( ('Core.Names.CacheNamePool: parsing %d inited blocks; Block=%d ByteCursor=0x%X'):format( initializedBlockCount, currentBlockIndex, currentBlockByteCursor ) )
  local nameMaps = {   nameToIndex = {}, indexToName = {},   }

  --[[
      readNamePoolMaps
      ├─ allocate the temporary pointer & block streams
      ├─ populateNamePoolMaps
      │  ├─ copy initialized Blocks[] pointers
      │  ├─ process every completed block with a 0x20000-byte limit
      │  └─ process CurrentBlock with CurrentByteCursor as its limit
      ├─ cacheNamePoolBlock
      │  ├─ copy only the initialized portion of the block
      │  └─ call decodeNamePoolBlock
  ]]
  local populated, cacheError = Core.Names.readNamePoolMaps( initializedBlockCount, nameMaps, currentBlockIndex, currentBlockByteCursor, cancellationThread )
  if not populated then return populated, cacheError end
  -- publish lookups, calculate CachedNameCount, validate expected engine names
  Core.Names.publishNamePoolMaps(nameMaps)

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.NAMESCAN

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// LEGACY NAMEPOOL SCAN
--[[
  e.g 4.19: The occupation
  FNameEntry is formatted as : index, FNameEntry (hash?), Core.Signatures.ascii string (None, ByteProperty, InrProperty, BoolProperty,...)
  Each FnameEntry is pointed at by another block of memory of 0x20000 bytes (16384 pointers) to each individual string
  and that list itself is pointed at by another one , which has a pointer to it from a memory addres in the game (Call it GNames)

  example:
    2454CB90000 = 0, pointer, "None"
    2454CB90018 = 2, pointer, "ByteProperty"

    apparently if the first bit is 1 the string is a WideString (rare)

    address 2454B600000 holds 0x20000 bytes, all pointers. The first pointer points to 2454CB90000. There can be null pointers in that memory block

    address 2454B5F0080 holds some(9 in this case) pointers as well. First pointer is 2454B600000  (block[0]=2454B600000, block[1]=2454B600008, block[2]=2454B600010)


    Secondary for next run optimization:
    There are 2 static pointers to 2454B5F0080
    First one: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "80 00 5F 4B 45 02 00 00" 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 3A A7 67 45 02 00 00 0A 00 00 00 18 00 00 00
    Second one:00 00 00 00 00 00 00 00 00 00 00 00 88 00 00 80 "80 00 5F 4B 45 02 00 00" 40 00 5E 4B 45 02 00 00 01 00 00 00 00 00 00 00 09 00 00 80 00 00 00 00 00 00 00 00 00 00 00 00 00 00 36 D6 F6 7F 00 00 E3 36 EA 41 00 00 01 00 98 EF 1B D8 F6 7F 00 00

--]]

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// LEGACY SCAN HELPER

--- Execute a legacy name-pool scan and release its scanner
-- @param settings table @ scanner property values
-- @return number[]|nil @ scan results
function Core.NameScan.scanLegacyNamePoolMemory(settings)
  local memoryScan = createMemScan()

  for propertyName, value in pairs(settings) do
    memoryScan[propertyName] = value
  end

  memoryScan.scan()

  local results = memoryScan.Results

  memoryScan.destroy()

  return results
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// LEGACY FIRST STRING BLOCK

--- Locate the initial legacy string block using None and ByteProperty
-- Multiple matches are filtered by allocation-size heuristic
-- @param cancellationThread table|nil @ scan worker
-- @return number|nil @ selected string-block address
-- @return string|nil @ error
function Core.NameScan.findLegacyFirstStringBlock(cancellationThread)
  
  local scanSettings = 
  {
    VarType = vtGrouped,
    ScanValue = [[BA:4096 BS:128 OOO:U 1:* s:'None' s:'ByteProperty']],
  }

  local candidates = Core.NameScan.scanLegacyNamePoolMemory( scanSettings ) or {}

  if cancellationThread and cancellationThread.Terminated then return nil, 'ueScannerThread terminated' end

  if #candidates == 0 then return nil, 'No known stringpool found' end

  if #candidates == 1 then return candidates[1] end

  --refine more. Some options: #,pointer,None, (variable) #, pointer,ByteProperty
  --or, the block is allocated as a 0x10000 size
  local filteredCandidates = {}

  for _, candidateAddress in ipairs(candidates) do

    local memoryRegion = getMemoryRegionInfo(candidateAddress)

    -- if several matches are found, retain candidates whose containing memory region
    -- has the expected legacy allocation size
    if memoryRegion and memoryRegion.RegionSize == 0x10000 then
      filteredCandidates[#filteredCandidates + 1] = candidateAddress
    end

  end

  if #filteredCandidates == 0 then return nil, 'No known stringpool found (2)' end

  if #filteredCandidates > 1 then return nil, 'Core.NameScan.FindNamePoolData_older needs more refining' end

  return filteredCandidates[1]
end

--- Locate the string member "None" within the first legacy FNameEntry
-- @param entryAddress number @ first entry, expected to contain None
-- @return number|nil @ string-member byte offset
function Core.NameScan.findLegacyNameStringOffset(entryAddress)

  for stringOffset = 0, 128 do

    if readString( entryAddress + stringOffset, 4 ) == 'None' then --find the first string offset
      return stringOffset
    end

  end

  return nil
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// LEGACY POINTER LIST SEARCHES

--- Locate the aligned entry-pointer block referencing the first FNameEntry
-- @param firstEntryAddress number @ first legacy name entry
-- @param cancellationThread table|nil @ scan worker
-- @return number|false|nil @ block address, false for cancellation
-- @return string|nil @ error
function Core.NameScan.findLegacyEntryPointerBlock(firstEntryAddress, cancellationThread)
  --find a pointer to this table (The pointer is not located in static memory)
  local scanSettings = 
  {
    VarType = vtQword,
    ScanValue = firstEntryAddress,
    FastScanMethod = fsmLastDigits,
    FastScanparameter = '0000', --the first pointer of a 0x20000 bytes long block, alliged
  }
  local candidates = Core.NameScan.scanLegacyNamePoolMemory( scanSettings )

  if cancellationThread and cancellationThread.Terminated then return false, 'ueScannerThread terminated' end

  if #candidates == 0 then return nil, 'no list found' end
  if #candidates > 1 then return nil, 'needs more refining' end

  return candidates[1]
end

--- Locate the pointer list referencing the first entry-pointer block
-- @param entryPointerBlockAddress number @ first entry-pointer block
-- @return number|nil @ block-pointer list address
-- @return string|nil @ error
function Core.NameScan.findLegacyBlockPointerList(entryPointerBlockAddress)
  --check for a pointer to this address.  Normally aligned.  todo: if more than 1 result, check the following pointers if they point to other blocks of 0x20000 bytes all pointing to a FNameEntry or null
  local scanSettings = 
  {
    VarType = vtQword,
    ScanValue = entryPointerBlockAddress,
    FastScanMethod = fsmAligned,
    FastScanparameter = '8', --the first pointer of a 0x20000 bytes long block, alliged
  }

  local candidates = Core.NameScan.scanLegacyNamePoolMemory( scanSettings )

  if #candidates == 0 then return nil, 'No list found' end

  if #candidates > 1 then return nil, 'todo: check other pointers for valid stringblocks' end

  return candidates[1]
end

--- Decorates a legacy pointer-based GNames layout finder
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ result from legacy scan or bootstrap selection
-- @return string|nil @ feedback or error
function Core.NameScan.selectLegacyNamePool(cancellationThread)
  --maybe an older version
  Core.Runtime.log('FindNamePoolData: trying legacy NamePool layout')

  --[[ legacy layout wasn't contiguous
    GNames / block-pointer list
    │
    ├─ pointer to entry-pointer block 0
    │  ├─ pointer to FNameEntry 0 → "None"
    │  ├─ pointer to FNameEntry 1 → "ByteProperty"
    │  ├─ pointer to FNameEntry 2
    │  └─ ...
    │
    ├─ pointer to entry-pointer block 1
    └─ ...

    selectLegacyNamePool
    └─ FindNamePoolData_older
      ├─ findLegacyFirstStringBlock -- find the first FNameEntry via a groupscan
      ├─ findLegacyNameStringOffset -- determine where the string lives inside an FNameEntry (offset to name)
      ├─ findLegacyEntryPointerBlock -- find the block containing pointers to entries
      └─ findLegacyBlockPointerList -- find the top-level block-pointer list, hence GNames
  ]]

  local legacyResult, scannerError = Core.NameScan.FindNamePoolData_older(cancellationThread)

  if legacyResult then
    CUEDEFS.NamePoolSourceModule = nil
    CUEDEFS.NamePoolScanMethod = 'legacy-structural-scan'
    return legacyResult, scannerError
  end

  return false, scannerError
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// STRING-PREFIX SCAN

--- Scan one serialized FName prefix and copy results before disposal
-- @param pattern string @ AOB scan pattern
-- @param cancellationThread table|userdata|nil @ scanner cancellation owner
-- @return number[] @ candidate entry addr
function Core.NameScan.scanNamePrefix(pattern, cancellationThread)
  local scan = createMemScan()
  scan.VarType = vtByteArray
  scan.Hexadecimal = true
  scan.Scanvalue = pattern
  scan.Fastscanmethod = fsmAligned
  scan.Fastscanparameter = '2'
  scan.scan()

  while scan.waitTillDone(1000) == false do

    if cancellationThread and cancellationThread.Terminated then
      scan.terminateScan()
    end

  end

  local copied = {}
  local results = scan.Results

  if results then
    for i=1, #results do copied[ #copied + 1 ] = results[i] end
  end

  scan.destroy()
  return copied
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// MODERN STRUCT SCAN

--- Find distinct first-name blocks matching the supported header profiles
-- @param cancellationThread table|userdata|nil @ scanner cancellation owner
-- @return number[] @ candidate block addresses
function Core.NameScan.findModernNameBlockCandidates(cancellationThread)
  local scanNamePrefix = Core.NameScan.scanNamePrefix
  -- UE4 commonly stores Len in header bits 6..15. Newer UE versions use a
  -- compact header with Len in bits 1..15. Both begin with the hardcoded
  -- names None and ByteProperty, but their two-byte headers differ
  local nameHeaderPatterns =
  {
    '* 01 4E 6F 6E 65 * 03 42 79 74 65 50 72 6F 70 65 72 74 79', -- * 01 "None" * 03 "ByteProperty"
    '08 00 4E 6F 6E 65 18 00 42 79 74 65 50 72 6F 70 65 72 74 79',
  }

  local blockAddresses = {}
  local seenAddresses = {}

  for _, pattern in ipairs( nameHeaderPatterns ) do

    -- memscan for every supported header representation
    for _, address in ipairs( scanNamePrefix( pattern, cancellationThread ) ) do

      if not seenAddresses[address] then
        seenAddresses[address] = true
        blockAddresses[#blockAddresses + 1] = address
      end

    end

  end

  Core.Runtime.log(
        ('Core.NameScan.findNamePoolData: %d modern candidate block(s) across %d header profiles')
        :format( #blockAddresses, #nameHeaderPatterns )
      )

  return blockAddresses
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// REFERENCE SCANS

--- Create and launch one main-module pointer scan per candidate block
-- Scanners are recorded before configuration so cleanup covers setup errors
-- @param blockAddresses number[] @ candidate first-name blocks
-- @param activeScans table @ caller-owned scanner collection
-- @return nil
function Core.NameScan.startNameBlockReferenceScans(blockAddresses, activeScans)
  --find references to this address in the target process
  for index, blockAddress in ipairs(blockAddresses) do
    local memoryScan = createMemScan()
    activeScans[index] = memoryScan

    memoryScan.VarType = vtQword
    memoryScan.Fastscanmethod = fsmAligned
    memoryScan.Fastscanparameter = 8
    memoryScan.ScanValue = blockAddress

    memoryScan.Startaddress, memoryScan.Stopaddress = Core.Modules.ue_getMainModuleBoundsInternal()

    memoryScan.scan()
  end

end

--- Wait for all reference scans and collect their matching addresses
-- Duplicate references are retained
-- @param activeScans table @ launched memory scanners
-- @param scanCount number @ number of launched scans
-- @return number[] @ possible allocator block-pointer references
function Core.NameScan.collectNameBlockReferences(activeScans, scanCount)
  local references = {}

  for index = 1, scanCount do
    local memoryScan = activeScans[index]
    memoryScan.waitTillDone()

    for _, address in ipairs(memoryScan.Results) do
      references[#references + 1] = address
    end

    memoryScan.destroy()
    activeScans[index] = nil
  end

  return references
end

--- Find allocator references while ensuring scanners are released on errors
-- @param blockAddresses number[] @ candidate first-name blocks
-- @return number[] @ possible allocator block-pointer references
function Core.NameScan.scanNameBlockReferences(blockAddresses)
  local activeScans = {}

  Core.NameScan.startNameBlockReferenceScans( blockAddresses, activeScans )

  local referencesOrError = Core.NameScan.collectNameBlockReferences( activeScans, #blockAddresses )

  for _, memoryScan in pairs(activeScans) do
    memoryScan.destroy()
  end

  return referencesOrError
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// REFERENCE VALIDATION

--- Check neighboring pointers against the legacy block-size heuristic
-- @param referenceAddress number @ candidate first-block pointer location
-- @return boolean @ true when all three neighboring pointers are accepted
function Core.NameScan.hasExpectedNameBlockNeighbors(referenceAddress)

  --the pointer after it points to another string list and before it looks like a number of strings and a number of pointers to stringlists
  --the pointers it points to also have an allocation size of 0x20000
  for pointerOffset = 8, 24, 8 do
    local blockAddress = readPointer( referenceAddress + pointerOffset )

    if blockAddress == nil then return false end

    if blockAddress ~= 0 then -- allow empty pointers for compatibility
      local memoryRegion = getMemoryRegionInfo(blockAddress)

      if not memoryRegion then return false end

      if memoryRegion.RegionSize ~= 0x20000 then return false end
    end

  end

  return true
end

--- Filter ambiguous allocator references by neighboring block pointers
-- A single reference bypasses this refinement
-- @param references number[] @ candidate first-block pointer locations
-- @return number[] @ remaining references
function Core.NameScan.refineNamePoolReferences(references)
  if #references <= 1 then return references end

  local hasExpectedNeighbors = Core.NameScan.hasExpectedNameBlockNeighbors
  local validatedReferences = {}

  for _, referenceAddress in ipairs(references) do

    if hasExpectedNeighbors(referenceAddress) then
      validatedReferences[ #validatedReferences + 1 ] = referenceAddress
    end

  end

  return validatedReferences
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// NAME-BLOCK VALIDATION

--- Validate None and ByteProperty names in a FName block
-- @param block number @ candidate Blocks[0] addr
-- @return boolean @ true when a supported header profile decodes correctly
function Core.NameScan.validateNameBlock(block)
  if not block or block == 0 then return false end

  -- 2-byte header + 4-byte "None"
  -- 2-byte header + 12-byte "ByteProperty"
  local bytes = readBytes( block, 20, true )

  if type(bytes) ~= 'table' or #bytes < 20 then return false end

  local function ascii(start,text) -- compare an ASCII string with bytes
    for i=1, #text do   if bytes[ start + i-1 ] ~= text:byte(i) then return false end   end
    return true
  end

  -- With 6bit header profile, nameLen at bit 6. "None"(4): 4 << 6 = 0x0100. "ByteProperty"(12): 12 << 6 = 0x0300. High header bytes are checked only
  -- With 1bit header profile. "None": 4 << 1 = 0x0008. "ByteProperty": 12 << 1 = 0x0018
  local shiftedSix = bytes[2] == 0x01 and bytes[8] == 0x03 and ascii( 3, 'None' ) and ascii( 9, 'ByteProperty' )
  local shiftedOne = bytes[1] == 0x08 and bytes[2] == 0x00 and bytes[7] == 0x18 and bytes[8] == 0x00 and ascii( 3, 'None' ) and ascii( 9, 'ByteProperty' )
  --[[
    Shift-six profile
    Offset  Size  Meaning
    0x00    2     Header for "None"; Len = header >> 6
    0x02    4     None
    0x06    2     Header for "ByteProperty"; Len = header >> 6
    0x08    12    ByteProperty
    Shift-one profile
    Offset  Bytes       Meaning
    0x00    08 00       4 << 1
    0x02    4E 6F 6E 65 None
    0x06    18 00       12 << 1
    0x08    ...         ByteProperty
  ]]

  if shiftedSix then
    CUEDEFS.FNameHeaderShift = 6
    return true
  elseif shiftedOne then
    CUEDEFS.FNameHeaderShift = 1
    return true
  end

  return false
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// GNAMES STRUCT FALLBACK

--- Select a unique structurally found allocator reference
-- @param references number[] @ refined allocator block-pointer references
-- @return boolean|nil @ whether a usable pool was selected
-- @return string|nil @ feedback or error
function Core.NameScan.selectStructuralNamePool(references)

  if #references > 1 then
    return false, 'too many found. Needs more refining'
  end

  if #references == 0 then
    return false, 'not found'
  end

  local referenceAddress = references[1]

  -- re-validate the selected block and retain its detected header profile
  Core.NameScan.validateNameBlock( readPointer(referenceAddress) )

  CUEDEFS.NamePoolData = referenceAddress - 0x10
  local sourceModule = Core.Modules.ue_getAddressModuleInternal(CUEDEFS.NamePoolData)
  CUEDEFS.NamePoolSourceModule = sourceModule and extractFileName( sourceModule.PathToFile or '' ) or nil
  CUEDEFS.NamePoolScanMethod = 'structural-scan'

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// GNAMES SEARCH ENTRY POINT

--- Find the legacy pointer-based GNames layout
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when the block-pointer list was located
-- @return string|nil @ error
function Core.NameScan.FindNamePoolData_older(cancellationThread)
  if CUEDEFS.NamePoolData then return true end

  CUEDEFS.NamePoolData_old = true --todo: if more than 2 formats, change it to an identifier number

  local firstEntryAddress, blockError = Core.NameScan.findLegacyFirstStringBlock( cancellationThread )

  if not firstEntryAddress then return false, blockError end

  --check the format
  CUEDEFS.FNameEntry = {}
  CUEDEFS.FNameEntry.String = Core.NameScan.findLegacyNameStringOffset(firstEntryAddress) -- TODO: error checking

  local entryPointerBlock, entryListError = Core.NameScan.findLegacyEntryPointerBlock( firstEntryAddress, cancellationThread )

  if not entryPointerBlock then return entryPointerBlock, entryListError end

  local blockPointerList, blockListError = Core.NameScan.findLegacyBlockPointerList( entryPointerBlock )

  if not blockPointerList then return nil, blockListError end

  CUEDEFS.NamePoolData = blockPointerList

  return true
end

--- Select & validate the runtime FNamePool
--
-- Module-scoped signatures are tried first
-- Structural and legacy pointer-based GNames heuristics remain fallbacks
--
-- @param cancellationThread table|nil @ CE worker thread used for cancellation
-- @return boolean|nil @ true when a usable name source was selected
-- @return string|nil @ error
function Core.NameScan.findNamePoolData(cancellationThread)
  if CUEDEFS.NamePoolData then return true end --already found

  -- signatures first
  if Core.Signatures.selectNamePoolFromSignature() then return true end

  Core.Runtime.log('Core.NameScan.findNamePoolData: signature resolution failed; using structural fallback')
  --[[
    FNamePool / FNameEntryAllocator
    ├─ +0x08 CurrentBlock
    ├─ +0x0C CurrentByteCursor
    └─ +0x10 Blocks
        ├─ Blocks[0] → first name-entry block
        │               ├─ FNameEntry 0 → "None"
        │               ├─ FNameEntry 1 → "ByteProperty"
        │               └─ ...
        ├─ Blocks[1] → second name-entry block
        └─ ...
  ]]
  -- possible addresses of the first name-entry block
  local blockCandidates = Core.NameScan.findModernNameBlockCandidates(cancellationThread) -- find None/Byteproperty block in modern layouts

  if cancellationThread and cancellationThread.Terminated then return false, 'ueScannerThread terminated' end

  if #blockCandidates == 0 then -- legacy fallback
    return Core.NameScan.selectLegacyNamePool(cancellationThread)
  end

  -- scanNameBlockReferences
  -- ├─ scan main-module memory for pointers to every candidate block
  -- ├─ collect addresses of matching pointer slots
  -- └─ return possible FNameEntryAllocator::Blocks[0] locations
  local references = Core.NameScan.scanNameBlockReferences( blockCandidates )

  if cancellationThread and cancellationThread.Terminated then return false, 'ueScannerThread terminated' end

  -- when several results, inspect neighboring Blocks[] pointers,
  -- accept candidates whose following block pointers are null/point to allocations having the expected block size
  references = Core.NameScan.refineNamePoolReferences(references)
  -- revalidate the selected Blocks[0] target
  -- subtract 0x10 from the Blocks[0] pointer-slot address and recover the FNameEntryAllocator base
  return Core.NameScan.selectStructuralNamePool(references)
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.SIGNATURES

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// PROCESS EVENT AND GLOBAL HELPERS

--- Find native function prologue
-- @param collectionName string @ key in UESignatures
-- @return number|nil @ first readable executable hit
function Core.Signatures.findFunctionEntryBySignatures(collectionName)
  local signatures = type(UESignatures) == 'table' and UESignatures[collectionName]

  if type(signatures) ~= 'table' then return nil end

  Core.Runtime.log( ('SIG: testing %d %s patterns'):format( #signatures, collectionName ) )

  for patternIndex, signature in ipairs(signatures) do
    local pattern = type(signature) == 'table' and (signature.pattern or signature.Sign) or signature
    local results = type(pattern) == 'string' and AOBScan( pattern, '+X-W-C' ) or nil

    if results then
      local selectedAddress

      for hitIndex = 0, results.Count - 1 do
        local candidateAddress = getAddress( results[hitIndex] )

        if candidateAddress and readByte(candidateAddress) ~= nil then
          selectedAddress = candidateAddress
          break
        end
      end

      results.destroy()

      if selectedAddress then
        Core.Runtime.log( ('SIG: %s pattern %d resolved 0x%X') :format( collectionName, patternIndex, selectedAddress ) )

        return selectedAddress
      end

    end

  end

  return nil
end

--- Resolve and cache UObject::ProcessEvent
-- @return number|nil @ executable UObject::ProcessEvent entry point
-- @return string|nil @ error
function Core.Signatures.resolveProcessEvent()
  if CUEDEFS and CUEDEFS.ProcessEvent and readByte(CUEDEFS.ProcessEvent) ~= nil then return CUEDEFS.ProcessEvent end

  local processEventAddress = Core.Signatures.findFunctionEntryBySignatures('ProcessEvent')

  if not processEventAddress then return nil, 'UObject::ProcessEvent signature was not found' end

  CUEDEFS.ProcessEvent = processEventAddress
  return processEventAddress
end

--- Convert an unsigned DWORD to a signed x64 displacement
-- @param value number @ unsigned 32-bit value
-- @return number @ signed value
function Core.Signatures.ue_signedDwordInternal(value)
  if value >= 0x80000000 then return value - 0x100000000 end
  return value
end

--- Decode RIP-relative memory targets near an AOB hit
-- a lightweight instruction recognizer
-- @param hit number @ addr of the matching instruction sequence
-- @return number[] @ candidate global addresses
function Core.Signatures.ue_decodeRipTargetsInternal(hit)
  local signedDword = Core.Signatures.ue_signedDwordInternal
  local targets = {}
  -- examine every byte position within 96 bytes of the signature match

  for offset=0, 96 do -- TODO: maybe use CE disassemble API?
    -- REX prefix, opcode, ModR/M, 32-bit displacement
    local rex = readByte( hit + offset )
    local opcode = readByte( hit + offset + 1 )
    local modrm = readByte( hit + offset + 2 )
    -- bytes 0x40–0x4F are x86-64 REX prefixes
    -- OPCODES
    -- 8B — MOV register, memory
    -- 8D — LEA register, memory address
    -- 89 — MOV memory, register
    -- ModR/M has 3 fields which we mask mask 0xC7 (11000111) to get mod and r/m
    -- ModR/M: mm rrr mmm -- mod | reg | r/m respectively
    -- Mask:   11 000 111
    -- The expected 0x05 is 00 xxx 101, which 64 targets mean RIP + displacement

    if rex and rex >= 0x40 and rex <= 0x4F and (opcode == 0x8B or opcode == 0x8D or opcode == 0x89) and modrm and (modrm & 0xC7) == 0x05 then
      
      local displacement = readInteger( hit + offset + 3 ) -- eg 48 89 05 ?? ?? ?? ??
      
      if displacement then
        targets[ #targets + 1 ] = hit + offset + 7 + signedDword( displacement ) -- 7byte instr
      end

    end

  end

  return targets
end

--- Verify a UObject through its internal GUObjectArray index
-- @param object number @ candidate UObject addr
-- @return boolean @ true when an indexed object-array slot points back to it
function Core.Signatures.ue_objectMatchesArrayIndexInternal(object)
  
  if not object or object == 0 or not CUEDEFS.ObjectArray or not CUEDEFS.ObjectArrayEntryStructSize then
    return false
  end

  local objects = readPointer( CUEDEFS.ObjectArray + 0x10 )
  local count = readInteger( CUEDEFS.ObjectArray + 0x24 )

  if not objects or objects == 0 or not count or count <= 0 then return false end

  -- InternalIndex is normally the DWORD at +0xC
  -- Nearby aligned DWORDs are checked as a compatibility fallback
  -- but the resolved slot must point back to this exact UObject
  for _, offset in ipairs( { 0xC, 0x8, 0x10, 0x14 } ) do
    local index = readInteger(object + offset)

    if not index or index < 0 or index >= count then goto continue end

    local item

    if CUEDEFS.ObjectArrayListType == 0 then

      local chunk = readPointer(objects + math.floor( index / 0x10000 ) * 8)

      if not chunk or chunk == 0 then goto continue end

      item = chunk + (index % 0x10000) * CUEDEFS.ObjectArrayEntryStructSize

    else
      item = objects + index * CUEDEFS.ObjectArrayEntryStructSize
    end

    local listed = readPointer(item)

    if listed and (listed & 0xFFFFFFFFFFFFFFF8) == object then return true end

    ::continue::
  end

  return false
end

--- Validate a RIP-relative global as a possible UObject pointer
-- @param address number @ candidate addr of the global pointer
-- @param expectedClassName string|nil @ exact reflected class name when required
-- @return number|nil @ validated instance
-- @return number|nil @ runtime class
function Core.Signatures.ue_validateUObjectGlobalInternal(address, expectedClassName)
  
  if not address or address <= 0 or not CUEDEFS.UObject or type(CUEDEFS.UObject.Class) ~= 'number' then
    return nil
  end

  local instance = readPointer(address)

  if not instance or instance == 0 then return nil end

  local vtable = readPointer(instance)
  local firstFunction = vtable and readPointer(vtable)

  if not firstFunction or readByte(firstFunction) == nil then return nil end

  local class = readPointer( instance + CUEDEFS.UObject.Class )

  if not class or class == 0 or class == instance then return nil end

  local classVtable = readPointer(class)
  local classFunction = classVtable and readPointer(classVtable)

  if not classFunction or readByte(classFunction) == nil then return nil end

  if not Core.Signatures.ue_objectMatchesArrayIndexInternal(instance) then return nil end

  if expectedClassName and type(CUEDEFS.UObject.Name) == 'number' and CUEDEFS.IndexToName then
    local classNameIndex = readInteger( class + CUEDEFS.UObject.Name )
    local className = classNameIndex and CUEDEFS.IndexToName[classNameIndex]

    if className ~= expectedClassName then return nil end
  end

  return instance, class
end

--- Rank a validated UObject-global candidate only in optional scored mode
-- @param address number @ global pointer address
-- @param expectedClassName string|nil @ exact reflected class name when required
-- @return number @ confidence, zero for invalid candidates
function Core.Signatures.ue_scoreUObjectGlobalInternal(address, expectedClassName)
  local instance, class = Core.Signatures.ue_validateUObjectGlobalInternal(address, expectedClassName)
  if not instance then return 0 end

  local score = 8

  if type(CUEDEFS.UObject.Name) ~= 'number' or not CUEDEFS.IndexToName then
    return score
  end

  local instanceIndex = readInteger( instance + CUEDEFS.UObject.Name )
  local classIndex = readInteger( class + CUEDEFS.UObject.Name )

  if instanceIndex and CUEDEFS.IndexToName[instanceIndex] then
    score = score + 1
  end

  if classIndex and CUEDEFS.IndexToName[classIndex] then
    score = score + 1
  end

  return score
end

--- Resolve a global UObject pointer using maintained signatures
-- @param signatureName string @ UESignatures collection name
-- @param expectedClassName string|nil @ exact reflected class name when required
-- @return number|nil @ addr of the global ptr
function Core.Signatures.ue_findUObjectGlobalBySignaturesInternal(signatureName, expectedClassName)

  local signatures = type(UESignatures) == 'table' and UESignatures[signatureName]
  if type(signatures) ~= 'table' then
    Core.Runtime.log('SIG: no ' .. signatureName .. ' signature provider loaded')
    return nil
  end

  local decodeRipTargets = Core.Signatures.ue_decodeRipTargetsInternal
  local validateGlobal = Core.Signatures.ue_validateUObjectGlobalInternal
  local scoreGlobal = Core.Signatures.ue_scoreUObjectGlobalInternal
  local writeLog = Core.Runtime.log

  writeLog( ('SIG: testing %d %s patterns'):format( #signatures, signatureName ) )

  local bestAddress
  local bestScore = 0
  local bestPattern

  for index, signature in ipairs(signatures) do
    local results = AOBScan(signature, '+X-W-C')

    if not results then goto continue end

    if results.Count > 0 then
      writeLog( ('SIG: %s pattern %d produced %d hit(s)'):format( signatureName, index, results.Count ) )
    end

    for hitIndex = 0, results.Count - 1 do
      local hit = getAddress( results[hitIndex] )

      for _, target in ipairs( decodeRipTargets(hit) ) do

        if Core.State.signatureSelection == 'first' then

          if validateGlobal( target, expectedClassName ) then
            results.destroy()
            
            writeLog( ('SIG: first valid %s pattern %d target 0x%X'):format( signatureName, index, target ) )

            return target
          end

        else -- fallback

          local score = scoreGlobal( target, expectedClassName )

          if score > bestScore then
            bestAddress = target
            bestScore = score
            bestPattern = index
          end

        end

      end

    end

    results.destroy()

    ::continue::
  end

  if not bestAddress then
    writeLog('SIG: no validated ' .. signatureName .. ' target')
    return nil
  end

  writeLog( ('SIG: %s pattern %d resolved global 0x%X (score %d)'):format( signatureName, bestPattern, bestAddress, bestScore ) )

  return bestAddress
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// FNAME::TOSTRING GUESS

--- Return the existing confidence weight for a module role
-- @param role string|nil @ classification returned by the module classifier
-- @return number @ confidence contribution
function Core.Signatures.getFNameFunctionModuleScore(role)
  local roleScores =
  {
    main = 20,
    unreal = 15,
    thirdparty = -100,
  }

  return roleScores[role] or 1
end

--- Log the module containing the current FNamePool
-- @return void
function Core.Signatures.logFNamePoolModule() -- TODO: debugging
  local poolModule = Core.Modules.ue_getAddressModuleInternal( CUEDEFS.NamePoolData )
  if not poolModule then return end

  local moduleName = extractFileName( poolModule.PathToFile or '' )

  Core.Runtime.log( ('SIG: FNamePool in %s [0x%X-0x%X]'):format( moduleName or '<?module>', poolModule.Address, poolModule.Address + poolModule.Size ) )
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// FNAME EXPORT SEARCH

--- Build the supported symbol spellings for the FName::ToString export
-- Includes unqualified and module-qualified forms
-- @return string[] @ candidate export names
function Core.Signatures.getFNameToStringExportNames()
  -- per ue4ss, builds may export this decorated C++ method
  local decoratedName = '?ToString@FName@@QEBAXAEAVFString@@@Z'
  local exportNames = { decoratedName }

  for _, module in ipairs( enumModules() or {} ) do
    local role = Core.Modules.ue_classifyModuleInternal(module)
    local moduleName = extractFileName( module.PathToFile or '' )
    local isEngineModule = role == 'main' or role == 'unreal'

    if isEngineModule and moduleName and moduleName ~= '' then
      exportNames[#exportNames + 1] = moduleName .. '.' .. decoratedName
      exportNames[#exportNames + 1] = moduleName .. '!' .. decoratedName
    end

  end

  return exportNames
end

--- Add candidates resolved through exported symbol names
-- Each resolved spelling contributes independently
-- @param candidates table<number, number> @ accumulated scores by address
-- @return nil
function Core.Signatures.collectFNameToStringExports(candidates)
  local getExportNames = Core.Signatures.getFNameToStringExportNames
  local getAddressModule = Core.Modules.ue_getAddressModuleInternal
  local classifyModule = Core.Modules.ue_classifyModuleInternal
  local getModuleScore = Core.Signatures.getFNameFunctionModuleScore

  for _, symbolName in ipairs( getExportNames() ) do
    local address = getAddressSafe(symbolName)

    if address and address ~= 0 then

      local module = getAddressModule(address)
      local role = classifyModule(module)
      local score = getModuleScore(role)

      Core.Runtime.log( ('SIG: FName::ToString export %s. 0x%X role=%s score=%d'):format( symbolName, address, role, score ) )

      candidates[address] = (candidates[address] or 0) + score
    end

  end

end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// FNAME SIGNATURE TARGETS

--- Get the function addr from signature
-- @param hitAddress number @ signature match address
-- @param signatureEntry string|table @ pattern and optional call offset
-- @return number|nil @ resolved target address
function Core.Signatures.resolveFNameSignatureTarget(hitAddress, signatureEntry)

  if type(signatureEntry) ~= 'table' then return hitAddress end
  if not signatureEntry.callOffset then return hitAddress end

  local callAddress = hitAddress + signatureEntry.callOffset

  if readByte(callAddress) ~= 0xE8 then return nil end

  local displacement = readInteger( callAddress + 1 )
  if displacement == nil then return nil end

  return callAddress + 5 + Core.Signatures.ue_signedDwordInternal(displacement)
end

--- Guess one readable function target produced by a signature
-- @param targetAddress number|nil @ resolved target address
-- @param patternIndex number @ signature index used for feedback
-- @param candidates table<number, number> @ accumulated scores by address
-- @return nil
function Core.Signatures.recordFNameSignatureTarget(targetAddress, patternIndex, candidates)
  
  if not targetAddress then return end
  if readByte(targetAddress) == nil then return end

  local module = Core.Modules.ue_getAddressModuleInternal(targetAddress)
  local moduleName = '<unknown>'

  if module then
    moduleName = extractFileName( module.PathToFile or '' )
  end

  local role = Core.Modules.ue_classifyModuleInternal(module)

  if Core.State.signatureSelection == 'first' then
    if role == 'main' or role == 'unreal' then return targetAddress end
    return nil
  end

  local score = Core.Signatures.getFNameFunctionModuleScore(role)

  Core.Runtime.log( ('SIG: FName::ToString pattern %d target 0x%X module=%s score=%d') :format( patternIndex, targetAddress, moduleName, score ) )

  candidates[targetAddress] = (candidates[targetAddress] or 0) + score
end

--- Decode & guess the matches returned by one signature scan
-- @param results userdata @ Cheat Engine AOB result list
-- @param signatureEntry string|table @ pattern and optional call offset
-- @param patternIndex number @ signature index
-- @param candidates table<number, number> @ accumulated scores by address
-- @return void
function Core.Signatures.processFNameSignatureHits( results, signatureEntry, patternIndex, candidates )
  if results.Count > 0 then
    Core.Runtime.log( ('SIG: FName::ToString pattern %d produced %d hit(s)'):format( patternIndex, results.Count ) )
  end

  local resolveTarget = Core.Signatures.resolveFNameSignatureTarget
  local recordTarget = Core.Signatures.recordFNameSignatureTarget

  for hitIndex = 0, results.Count - 1 do
    local hitAddress = getAddress( results[hitIndex] )
    local targetAddress = resolveTarget( hitAddress, signatureEntry )

    local accepted = recordTarget( targetAddress, patternIndex, candidates )
    if accepted then return accepted end
  end

end

--- Scan one FName::ToString signature and release its result list
-- @param signatureEntry string|table @ pattern and optional call offset
-- @param patternIndex number @ signature index
-- @param candidates table<number, number> @ accumulated scores by address
-- @return void
function Core.Signatures.scanFNameToStringSignature(signatureEntry, patternIndex, candidates)
  
  local pattern = type(signatureEntry) == 'table' and signatureEntry.pattern or signatureEntry

  local results = pattern and AOBScan( pattern, '+X-W-C' ) or nil
  
  if not results then return end

  local accepted = Core.Signatures.processFNameSignatureHits( results, signatureEntry, patternIndex, candidates )

  results.destroy()
  return accepted
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// FNAME SELECTION

--- Select a unique highest-scoring candidate meeting the minimum score
-- @param candidates table<number, number> @ accumulated scores by address
-- @return number|nil @ accepted function address
function Core.Signatures.selectFNameToStringCandidate(candidates)
  local selectedAddress
  local highestScore = 0
  local highestScoreCount = 0
  local candidateCount = 0

  for address, score in pairs(candidates) do
    candidateCount = candidateCount + 1

    Core.Runtime.log( ('SIG: FName::ToString candidate 0x%X scored %d'):format( address, score ) )

    if score > highestScore then
      selectedAddress = address
      highestScore = score
      highestScoreCount = 1
    elseif score == highestScore then
      highestScoreCount = highestScoreCount + 1
    end

  end

  local hasUniqueWinner = selectedAddress ~= nil and highestScoreCount == 1

  if hasUniqueWinner and highestScore >= 15 then
    Core.Runtime.log( ('SIG: selected FName::ToString 0x%X (score %d)'):format( selectedAddress, highestScore ) )

    return selectedAddress
  end

  if candidateCount > 1 then
    Core.Runtime.log( ('SIG: rejected %d FName::ToString; best score %d shared by %d') :format( candidateCount, highestScore, highestScoreCount ) )
  else
    Core.Runtime.log('SIG: no FName::ToString candidate found')
  end

  return nil
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// FNAME RESOLVER

--- Resolve FName::ToString through UE4SS signatures
-- This stage deliberately resolves only the function address
-- Calling natively may crash, checking has to be done first
-- @return number|nil @ resolved native function address
function Core.Signatures.ue_findFNameToStringBySignaturesInternal()
  local signatures
  if type(UESignatures) == 'table' then   signatures = UESignatures.FNameToString   end
  if type(signatures) ~= 'table' then
    Core.Runtime.log('SIG: no FName::ToString signature provider loaded')
    return nil
  end

  Core.Runtime.log( ('SIG: test %d FName::ToString patterns'):format( #signatures ) )

  -- Core.Signatures.logFNamePoolModule()
  
  -- by ref
  local candidates = {}

  if Core.State.signatureSelection == 'scored' then Core.Signatures.collectFNameToStringExports(candidates) end

  for patternIndex, signatureEntry in ipairs(signatures) do

    local accepted = Core.Signatures.scanFNameToStringSignature( signatureEntry, patternIndex, candidates )

    if accepted then
      Core.Runtime.log( ('SIG: first valid FName::ToString pattern %d target 0x%X'):format(patternIndex, accepted) )
      return accepted
    end

  end

  if Core.State.signatureSelection == 'scored' then return Core.Signatures.selectFNameToStringCandidate(candidates) end
  return nil
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// CORE.SIGNATURES: GNames CANDIDATES

--- Return modules eligible for FNamePool signature scanning
--
-- The process image is always first. Recognized modular Unreal images
-- follow in loader order. SDK, system and unknown DLLs are not scanned
-- @return table[] @ ordered module descriptors
function Core.Signatures.getNamePoolScanModules()
  local modules = enumModules() or {}
  local selectedModules = {}

  if modules[1] then selectedModules[1] = modules[1] end

  for moduleIndex = 2, #modules do
    local module = modules[moduleIndex]

    if Core.Modules.ue_classifyModuleInternal(module) == 'unreal' then
      selectedModules[#selectedModules + 1] = module
    end
  end

  return selectedModules
end

--- Normalize and validate one possible name-pool target
-- @param targetAddress number @ address decoded from a signature hit
-- @param patternIndex number @ matching signature index
-- @param sourceModuleName string @ module containing the signature hit
-- @return table|nil @ validated pool address and source metadata
function Core.Signatures.evaluateNamePoolTarget(targetAddress, patternIndex, sourceModuleName)
  if not targetAddress or targetAddress <= 0 then return nil end
  local indirect = readPointer(targetAddress)
  
  -- we might land on FNameEntryAllocator directly, we might not (hence 0x10 offset to get allocator)
  -- in case we landed on enclosing FNamePool. We test all four interpretations
  local candidates = { targetAddress, targetAddress - 0x10 }

  if indirect and indirect ~= 0 then
    candidates[ #candidates + 1 ] = indirect
    candidates[ #candidates + 1 ] = indirect - 0x10
  end

  -- direct/indirect interpretations may produce the same address
  local visitedAddresses = {}
  local selectedAllocatorAddress

  for _, candidate in ipairs(candidates) do
    
    if not candidate or candidate <= 0 or visitedAddresses[candidate] then goto continue end
    visitedAddresses[ candidate ] = true

    -- FNameEntryAllocator::Blocks begins at allocator + 0x10. Blocks[0] should point to the first FName entry block
    local block = readPointer( candidate + 0x10 )
    -- block begins with a plausible sequence of known Unreal names? also determine the appropriate FName header shift
    if not Core.NameScan.validateNameBlock( block ) then goto continue end

    selectedAllocatorAddress = candidate -- good
    break

    ::continue::
  end

  if not selectedAllocatorAddress then return nil end

  Core.Runtime.log( ('Signature: GNames pattern %d resolved 0x%X in %s'):format( patternIndex, selectedAllocatorAddress, sourceModuleName ) )
  return
  {
    address = selectedAllocatorAddress,
    patternIndex = patternIndex,
    sourceModule = sourceModuleName,
    scanMethod = 'module-signature',
  }
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// SIGNATURE SCANNING

--- Scan one GNames signature inside one selected module
-- @param signature string @ executable-code pattern
-- @param patternIndex number @ signature index
-- @param module table @ selected module descriptor
-- @return table|nil @ first structurally valid decoded pool
function Core.Signatures.scanNamePoolSignature(signature, patternIndex, module)
  local moduleName = extractFileName( module.PathToFile or '' )
  if not moduleName or moduleName == '' then return nil end

  local hitAddress = AOBScanModuleUnique( moduleName, signature, '+X-W-C' )
  if not hitAddress then return nil end

  for _, targetAddress in ipairs( Core.Signatures.ue_decodeRipTargetsInternal(hitAddress) ) do

    local candidate = Core.Signatures.evaluateNamePoolTarget( targetAddress, patternIndex, moduleName )

    if candidate then return candidate end
  end

  return nil
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// SELECTED POOL STATE

--- Publish the selected pool and its found source
-- @param candidate table @ validated name-pool candidate
-- @return number|nil @ selected allocator address
function Core.Signatures.publishNamePoolCandidate(candidate)
  CUEDEFS.NamePoolSourceModule = candidate.sourceModule
  CUEDEFS.NamePoolScanMethod = candidate.scanMethod
  CUEDEFS.NamePoolData = candidate.address

  Core.Runtime.log( ('SIG: got GNames; pattern %d sig %s'):format( candidate.patternIndex, candidate.sourceModule or '<unknown>' ) )
  Core.Runtime.log( ('SIG: chose FName header shift %d'):format( CUEDEFS.FNameHeaderShift or 6 ) )
  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// GOBJECTS SIGNATURE RESOLUTION

--- Validate common x64 FUObjectArray/chunked-array layout
-- @param address number @ candidate FUObjectArray base
-- @return boolean @ true when counts and first object pointers are coherent
function Core.Signatures.ue_validateObjectArrayInternal(address)
  if not address or address <= 0 then return false end

  local objects = readPointer(address + 0x10)
  local maxElements = readInteger(address + 0x20)
  local numElements = readInteger(address + 0x24)
  local maxChunks = readInteger(address + 0x28)
  local numChunks = readInteger(address + 0x2C)

  if not objects or objects == 0 or not maxElements or not numElements or not maxChunks or not numChunks then return false end

  if numElements < 1 or maxElements < numElements or maxElements > 0x10000000 then return false end

  if numChunks < 1 or maxChunks < numChunks or maxChunks > 0x10000 then return false end

  local firstChunk = readPointer(objects)

  if not firstChunk or firstChunk == 0 then return false end

  local firstObject = readPointer(firstChunk)

  if not firstObject or firstObject == 0 then return false end

  local firstVtable = readPointer(firstObject)

  return firstVtable ~= nil and firstVtable ~= 0
end

--- Normalize RIP target referencing GUObjectArray or an embedded field
-- @param address number @ decoded global target
-- @return number|nil @ validated FUObjectArray base
function Core.Signatures.ue_normalizeObjectArrayInternal(address)
  if not address or address <= 0 then return nil end

  local candidates =
  {
    address,
    address - 0x10,
    address - 0x24
  }

  local indirect = readPointer(address)

  if indirect and indirect > 0 then
    candidates[ #candidates + 1 ] = indirect
    candidates[ #candidates + 1 ] = indirect - 0x10
    candidates[ #candidates + 1 ] = indirect - 0x24
  end

  local seenAddr = {}

  for _, candidate in ipairs(candidates) do

    if candidate > 0 and not seenAddr[candidate] then
      seenAddr[candidate] = true

      if Core.Signatures.ue_validateObjectArrayInternal(candidate) then return candidate end
    end

  end

  return nil
end

--- Resolve GUObjectArray using code signatures
-- @return number|nil @ validated FUObjectArray base
function Core.Signatures.ue_findObjectArrayBySignaturesInternal()
  if type(UESignatures) ~= 'table' or type(UESignatures.GObjects) ~= 'table'
  then
    Core.Runtime.log('SIG: no GObjects signature provider loaded')
    return nil
  end

  local decodeRipTargets = Core.Signatures.ue_decodeRipTargetsInternal
  local normalizeObjectArray = Core.Signatures.ue_normalizeObjectArrayInternal
  local writeLog = Core.Runtime.log

  writeLog( ('SIG: testing %d GObjects patterns'):format( #UESignatures.GObjects ) )

  for index, signature in ipairs(UESignatures.GObjects) do
    local results = AOBScan( signature, '+X-W-C' )

    if not results then goto continue end

    if results.Count > 0 then
      writeLog( ('SIG: GObjects pattern %d produced %d hit(s)'):format( index, results.Count ) )
    end

    for hitIndex = 0, results.Count - 1 do
      local hit = getAddress( results[hitIndex] )

      for _, target in ipairs( decodeRipTargets(hit) ) do
        local objectArray = normalizeObjectArray(target)

        if objectArray then
          writeLog( ('SIG: GObjects pattern %d resolved 0x%X'):format( index, objectArray ) )

          results.destroy()
          return objectArray
        end

      end

    end

    results.destroy()

    ::continue::
  end

  writeLog('SIG: no validated GObjects target')
  return nil
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// GNAMES SELECTION

--- Either sets the found FNamePool via signatures or passes inference to fallbacks
-- @return boolean @ true when a valid pool was selected
function Core.Signatures.selectNamePoolFromSignature()
  local signatures

  if type(UESignatures) == 'table' then   signatures = UESignatures.GNames    end
  if type(signatures) ~= 'table' then
    Core.Runtime.log('SIG: no GNames sigs loaded')
    return false
  end

  -- get modules where to search (main and some potential owner modules)
  local scanModules = Core.Signatures.getNamePoolScanModules()
  Core.Runtime.log( ('SIG: query %d GNames sigs across %d modules'):format( #signatures, #scanModules ) )

  for _, module in ipairs(scanModules) do

    for patternIndex, signature in ipairs(signatures) do

      local candidate = Core.Signatures.scanNamePoolSignature( signature, patternIndex, module ) -- hits/shift are evaluated inside
      if candidate then -- the happy
        return Core.Signatures.publishNamePoolCandidate(candidate)
      end

    end

  end

  Core.Runtime.log('SIG: no validated module-scoped GNames target')
  return false
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.MENU

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// MENU LIFETIME

--- Remove main menu items. Must run on the CE main thread
-- @return void
function Core.Menu.destroyUEMenu()
  local menuRoot = MainForm.Menu.Items

  for index = menuRoot.Count - 1, 0, -1 do
    local menuItem = menuRoot[index]

    if menuItem.Name == 'miCeUEDumper' or menuItem.Name == 'miStandaloneUEDumper' then -- TODO: export name to a scoped global
      menuItem.destroy()
    end
    
  end

  if CUEDEFS then CUEDEFS.GUI = nil end
end

--- Create a menu item
-- @param scanning boolean|nil @ show worker progress controls when true
-- @return void
function Core.Menu.createUEMenu(scanning)
  Core.Runtime.log('Creating menuitem')

  --- Invoke the public portable-table packager from the isolated core
  local function attachDumperToTable(menuItem)

    if type( ue_attachToTable ) ~= 'function' then -- from main 
      messageDialog( 'ceUEDumper public API is unavailable', mtError, mbOK )
      return
    end

    local attached, attachmentError = ue_attachToTable()

    if not attached then
      messageDialog( attachmentError or 'Could not attach ceUEDumper', mtError, mbOK )
      return
    end

    if menuItem then menuItem.Caption = 'Attach script to table (upd)' end
  end

  --- Add main menu items
  local function addPersistentMenuActions(gui)
    gui.miAttach = createMenuItem(gui.miUnrealEngine)
    gui.miAttach.Name = 'miCeUEDumperAttach'
    gui.miAttach.Caption = 'Attach script to table'
    gui.miAttach.OnClick = attachDumperToTable
    gui.miUnrealEngine.add( gui.miAttach )

    gui.miReflectionMetadata = createMenuItem( gui.miUnrealEngine )
    gui.miReflectionMetadata.Name = 'miCeUEDumperReflectionMetadata'
    gui.miReflectionMetadata.Caption = 'Dissect UClass/UProperty metadata?'
    gui.miReflectionMetadata.Checked = resources.options.showReflectionMetadata == true
    gui.miReflectionMetadata.OnClick = function(menuItem)
      local enabled = not menuItem.Checked
      if type( ue_setReflectionMetadataVisible ) ~= 'function' then -- from main
        messageDialog( 'ceUEDumper public API is unavailable', mtError, mbOK )
        return
      end
      ue_setReflectionMetadataVisible(enabled)
      menuItem.Checked = enabled
    end

    gui.miUnrealEngine.add(gui.miReflectionMetadata)

    gui.miSupport = createMenuItem( gui.miUnrealEngine )
    gui.miSupport.Name = 'miCeUEDumperSupportDevelopment'
    gui.miSupport.Caption = 'Support development'
    gui.miSupport.OnClick = function() shellExecute('https://ko-fi.com/vesperpallens') end
    gui.miUnrealEngine.add(gui.miSupport)
  end

  --- Add menu item trigger to start scan worker
  local function addStartTrigger(gui)
    gui.miInitialize = createMenuItem( gui.miUnrealEngine )
    gui.miInitialize.Name = 'miCeUEDumperInitialize'
    gui.miInitialize.Caption = 'Initialize UE reflection'
    gui.miInitialize.OnClick = function() Core.Scanner.LaunchUEInfoScanner() end
    gui.miUnrealEngine.add(gui.miInitialize)
  end

  --- Add menu item for progress control for the scan worker
  local function addScanningMenuActions(gui)
    gui.miStatus = createMenuItem(gui.miUnrealEngine)
    gui.miStatus.Name = 'miCeUEDumperStatus'
    gui.miStatus.Caption = 'Working (click to cancel)'
    gui.miStatus.OnClick = function()
      if ueScannerThread and ( messageDialog( 'Cancel the UE data collection?', mtConfirmation, mbYes, mbNo ) == mrYes ) then
        ueScannerThread.Terminate()
      end
    end
    gui.miUnrealEngine.add(gui.miStatus)

    gui.miHurry = createMenuItem(gui.miUnrealEngine)
    gui.miHurry.Name = 'miCeUEDumperHurry'
    gui.miHurry.Caption = 'Boost priority'
    gui.miHurry.OnClick = function()
      if ueScannerThread then ueScannerThread.Priority = 'tpHigher' end
      gui.miHurry.destroy()
      gui.miHurry = nil
    end
    gui.miUnrealEngine.add(gui.miHurry)
  end

  synchronize(function()

    Core.Menu.destroyUEMenu()
    CUEDEFS.GUI = {}

    CUEDEFS.GUI.miUnrealEngine = createMenuItem( MainForm.Menu )
    CUEDEFS.GUI.miUnrealEngine.Caption = 'ceUEDumper'
    CUEDEFS.GUI.miUnrealEngine.Name = 'miCeUEDumper'

    addPersistentMenuActions( CUEDEFS.GUI ) -- TODO: separator?
    
    if scanning then
      addScanningMenuActions( CUEDEFS.GUI )
    else
      addStartTrigger( CUEDEFS.GUI )
    end

    MainForm.Menu.Items.insert( MainForm.miHelp.MenuIndex, CUEDEFS.GUI.miUnrealEngine )
  end)

end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// SCAN STATUS DISPLAY

--- Update the scanner status in menu item
-- @param caption string @ status text
-- @return nil
function Core.Menu.setScannerStatus(caption)
  synchronize( function() CUEDEFS.GUI.miStatus.Caption = caption end )
end

--- Replace scan controls with the completed dumper menu
-- @return nil
function Core.Menu.showCompletedState()
  
  synchronize(function()
    local gui = CUEDEFS.GUI

    if gui.miStatus then
      gui.miStatus.destroy()
      gui.miStatus = nil
    end

    if gui.miHurry then
      gui.miHurry.destroy()
      gui.miHurry = nil
    end

    gui.miUnrealEngine.Caption = 'ceUEDumper'

    if gui.miInitialize then
      gui.miInitialize.destroy()
    end

    gui.miInitialize = createMenuItem( gui.miUnrealEngine )
    gui.miInitialize.Name = 'miCeUEDumperInitialize'
    gui.miInitialize.Caption = 'Rescan reflection data'
    gui.miInitialize.OnClick = function() Core.Scanner.LaunchUEInfoScanner() end
    gui.miUnrealEngine.add( gui.miInitialize )

    if gui.miDissectGEngine then
      gui.miDissectGEngine.destroy()
    end

    gui.miDissectGEngine = createMenuItem( gui.miUnrealEngine ) -- TODO: submenu with dissect options
    gui.miDissectGEngine.Caption = 'Dissect GEngine'
    gui.miDissectGEngine.Name = 'miCeUEDumperDissectGEngine'
    gui.miDissectGEngine.OnClick = function() Core.Menu.dissectGlobal( 'pGEngine' ) end

    gui.miUnrealEngine.add( gui.miDissectGEngine )

    if CUEDEFS.GWorld and getAddressSafe('pGWorld') == CUEDEFS.GWorld then
      if gui.miDissectGWorld then gui.miDissectGWorld.destroy() end

      gui.miDissectGWorld = createMenuItem( gui.miUnrealEngine )
      gui.miDissectGWorld.Caption = 'Dissect GWorld'
      gui.miDissectGWorld.Name = 'miCeUEDumperDissectUWorld'
      gui.miDissectGWorld.OnClick = function() Core.Menu.dissectGlobal( 'pGWorld' ) end
      gui.miUnrealEngine.add( gui.miDissectGWorld )
    end

  end)

end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// STRUCT DISSECT

--- Open a structure-dissection form for a registered UObject global
-- @param globalSymbol string @ symbol containing the UObject pointer
-- @return nil
function Core.Menu.dissectGlobal(globalSymbol)
  local pointerExpression = '[' .. globalSymbol .. ']'
  local instanceAddress = getAddressSafe(pointerExpression)

  if not instanceAddress then
    error(globalSymbol .. ' is unavailable')
  end

  local structureForm = createStructureForm()
  structureForm.Column[0].AddressText = pointerExpression

  local structure, structureError = ue_createStructureFromObject(instanceAddress)

  if not structure then
    structureForm.destroy()
    error(structureError or 'Could not build reflected structure')
  end
  structureForm.MainStruct = structure
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.PERSISTENCE

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// EXECUTABLE IDENTITY

--- Generate exe identifier used for persisted layouts
-- @return string|nil @ executable version identifier
function Core.Persistence.getVersionIdentifier()
  local versionIdentifier

  --get the md5 from the first bytes of the file. That's enough to see if anything changed (pe crc field)
  --'some' games get the loaded memory PE file tampered with (prefered image base gets set) so prefer the file for this
  local fileBinStream

  pcall(function()
    fileBinStream = createFileStream( enumModules()[1].PathToFile, fmOpenRead or fmShareDenyNone )

    local executableHeaderBytes = fileBinStream.read(1024)
    fileBinStream.destroy()
    fileBinStream = nil

    local executableHeaderText = byteTableToString(executableHeaderBytes)
    versionIdentifier = stringToMD5String(executableHeaderText)
  end)

  if fileBinStream then --in case read fails, then fs is still valid
    fileBinStream.destroy()
  end

  if versionIdentifier == nil then
    versionIdentifier = md5memory( getAddressSafe(process), 4096 )
  end

  return versionIdentifier
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// LAYOUT LOAD

--- Restore numeric definition members from flattened settings keys
-- @param savedSettings table|userdata @ persisted scanner settings
function Core.Persistence.restoreDefinitions(savedSettings)
  --load all fields and offsets
  --load the CUEDEFS data from the registry
  local savedDefinitions = savedSettings.getValueList()

  for settingName, value in pairs( savedDefinitions ) do

    -- Other settings share this list; skip them without stopping restoration
    if settingName:startsWith('CUEDEFS.') then

      local pathParts = table.pack( settingName:split('.') )
      local destination = CUEDEFS

      for partIndex = 2, #pathParts - 1 do
        local memberName = pathParts[partIndex]

        if destination[memberName] == nil then
          destination[memberName] = {}
        end

        destination = destination[memberName]
      end

      destination[pathParts[#pathParts]] = tonumber(value)
    end

  end

end

--- Restore saved global addresses and the relocatable GEngine symbol
-- @param savedSettings table|userdata @ persisted scanner settings
-- @return nil
function Core.Persistence.restoreGlobalAddresses(savedSettings)
  CUEDEFS.NamePoolData = getAddressSafe( savedSettings.NamePoolData )
  CUEDEFS.ObjectArray = getAddressSafe( savedSettings.ObjectArray )
  CUEDEFS.GEngine = getAddressSafe( savedSettings.GEngine )
  CUEDEFS.GWorld = getAddressSafe( savedSettings.GWorld )

  if CUEDEFS.NamePoolData then
    local sourceModule = Core.Modules.ue_getAddressModuleInternal(CUEDEFS.NamePoolData)
    CUEDEFS.NamePoolSourceModule = sourceModule and extractFileName( sourceModule.PathToFile or '' ) or nil
    CUEDEFS.NamePoolScanMethod = 'saved-layout'
  end

  if CUEDEFS.GEngine then
    local symbolName = getNameFromAddress( CUEDEFS.GEngine, true, false, false )
    local processName = extractFileNameWithoutExt(process)

    if symbolName:find( processName, nil, true ) then
      ceUEDumperRegisterSymbol( 'pGEngine', symbolName )
    end
  end

  if CUEDEFS.GWorld then
    local symbolName = getNameFromAddress( CUEDEFS.GWorld, true, false, false )
    local processName = extractFileNameWithoutExt(process)

    if symbolName:find( processName, nil, true ) then
      ceUEDumperRegisterSymbol( 'pGWorld', symbolName )
    end
  end

end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// LAYOUT STORE

--- Flatten one definition table into the supplied settings object
-- @param savedSettings table|userdata @ destination settings
-- @param tableName string @ dotted key prefix
-- @param sourceTable table|nil @ definitions to persist
-- @return void
function Core.Persistence.saveDefinitionTable(savedSettings, tableName, sourceTable)
  if not sourceTable then return end
  local saveDefinitionTable = Core.Persistence.saveDefinitionTable

  for memberName, value in pairs(sourceTable) do

    local settingName = tableName .. '.' .. memberName

    if type(value) == 'table' then
      saveDefinitionTable( savedSettings, settingName, value )
    else
      savedSettings[settingName] = tostring(value)
    end

  end

end

--- Persist a newly completed layout
-- @param savedSettings table|userdata @ destination settings
-- @return nil
function Core.Persistence.saveLayout(savedSettings)
  if savedSettings.fullyParsed ~= nil then return end
  local saveDefinitionTable = Core.Persistence.saveDefinitionTable

  --save all offsets
  local UE_DEFINITION_TABLE =
  {
    'FNameEntry',
    'UObject',
    'UStruct',
    'UClass',
    'FProperty',
    'FFieldClass',
    'FField',
  }

  for _, tableName in ipairs(UE_DEFINITION_TABLE) do
    
    saveDefinitionTable( savedSettings, 'CUEDEFS.' .. tableName, CUEDEFS[tableName] )
  end

  savedSettings['CUEDEFS.VFTableInExecutableMemoryMethod'] = CUEDEFS.VFTableInExecutableMemoryMethod

  savedSettings['CUEDEFS.ObjectArrayListType'] = CUEDEFS.ObjectArrayListType

  savedSettings['CUEDEFS.ObjectArrayEntryStructSize'] = CUEDEFS.ObjectArrayEntryStructSize

  savedSettings['CUEDEFS.NamePoolData_old'] = CUEDEFS.NamePoolData_old

  savedSettings.fullyParsed = true
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.SCANNER

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// STATE INITIALIZATION

--- Configure the worker & reset definitions when the attached process changes
-- @param cancellationThread table|nil @ scan worker
-- @return nil
function Core.Scanner.initializeScannerState(cancellationThread)
  
  --get data from the registry if available
  if cancellationThread then
    Core.Runtime.log( 'Info Scanner threading start' )
    cancellationThread.FreeOnTerminate(false)
    cancellationThread.Name = 'ueScannerThread'
  end

  local processId = getOpenedProcessID()

  if CUEDEFS and CUEDEFS.processid == processId then return end

  --start from scratch
  synchronize(Core.Menu.destroyUEMenu)

  CUEDEFS = {}
  CUEDEFS.processid = processId
  Core.Menu.createUEMenu(true)
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// SHARED NAME INITIALIZATION

--- Cache names, make it available via custom type
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when caching succeeds
-- @return string|nil @ error
function Core.Scanner.cacheScannerNames(cancellationThread)
  
  local ready, cacheError = Core.Runtime.withoutLuaDebug( function() return Core.Names.CacheNamePool(cancellationThread) end )

  if not ready then return nil, 'Core.Names.CacheNamePool failed:' .. tostring(cacheError) end

  Core.CustomTypes.setupFName() --the cache is done. make it available to the user

  return true
end

--- Resolve the optional native FName::ToString address when still unknown
-- @return nil
function Core.Scanner.findScannerNameConversion()
  if CUEDEFS.FNameToString ~= nil then return end

  --[[ independently finds FName::ToString(FString& output). Native conversion relationship:
      FName value
      ├─ ComparisonIndex
      └─ Number
          │
          ▼
      FName::ToString
          └─ writes an Unreal FString

    ue_findFNameToStringBySignaturesInternal
    ├─ obtain FNameToString signatures
    ├─ optionally collect exported function symbols with a heuristic
    ├─ scan every signature
    │  ├─ direct signature
    │  │  └─ signature hit itself is the function address
    │  └─ call-site signature
    │     ├─ locate the E8 relative CALL near the signature
    │     ├─ decode its signed displacement
    │     └─ resolve the called function address
    ├─ first-selection mode (returns the first readable target)
    └─ scored-selection mode
        ├─ combine signature and exported-symbol candidates
        ├─ assign confidence according to the containing module
        └─ require one unique candidate with sufficient confidence
  ]]

  CUEDEFS.FNameToString = Core.Signatures.ue_findFNameToStringBySignaturesInternal()
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// COMPLETED-LAYOUT RESTORATION

--- Restore a completed layout and rebuild its runtime name cache
-- @param savedSettings table|userdata @ persisted scanner settings
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when restoration succeeds
-- @return string|nil @ error
function Core.Scanner.restoreScannerRuntime(savedSettings, cancellationThread)
  Core.Runtime.log('The state was fully parsed. Using it')

  Core.Persistence.restoreDefinitions(savedSettings)

  --cache the namepool data
  Core.Menu.createUEMenu(true)
  Core.Persistence.restoreGlobalAddresses(savedSettings)

  --todo: use the function method instead until specifically requested to cache the names
  Core.Runtime.log('Loading FName table')

  Core.Menu.setScannerStatus('Loading FName table')

  if CUEDEFS.NamePoolData == nil then
    --can happen in the old stringpool forma
    local ready, scanError = Core.NameScan.findNamePoolData(cancellationThread)
    if not ready then return nil, scanError end
  end

  local ready, cacheError = Core.Scanner.cacheScannerNames(cancellationThread)
  if not ready then return nil, cacheError end

  Core.Scanner.findScannerNameConversion() -- TODO: make use FName::ToString as a fallback

  if not CUEDEFS.GWorld then
    CUEDEFS.GWorld = Core.Signatures.ue_findUObjectGlobalBySignaturesInternal( 'GWorld', 'World' )

    if CUEDEFS.GWorld then
      local relocatableAddress = getNameFromAddress( CUEDEFS.GWorld, true, false, false )
      savedSettings.GWorld = relocatableAddress
      ceUEDumperRegisterSymbol( 'pGWorld', relocatableAddress )
    end

  end

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// INCOMPLETE NAMES

--- Restore/scan fname pool, then init names when needed
-- @param savedSettings table|userdata @ persisted scanner settings
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when this stage succeeds
-- @return string|nil @ error
function Core.Scanner.findScannerNames(savedSettings, cancellationThread)
  -- try restore from persisted setting key
  if CUEDEFS.NamePoolData == nil then
    local savedSymbol = savedSettings.NamePoolData
    if savedSymbol then
      CUEDEFS.NamePoolData = getAddressSafe(savedSymbol)
      Core.Runtime.log( 'NamePoolData was previously at ' .. savedSymbol .. ' . Using that' )

      if CUEDEFS.NamePoolData then
        local sourceModule = Core.Modules.ue_getAddressModuleInternal(CUEDEFS.NamePoolData)
        CUEDEFS.NamePoolSourceModule = sourceModule and extractFileName( sourceModule.PathToFile or '' ) or nil
        CUEDEFS.NamePoolScanMethod = 'saved-layout'
      end
    end
  end

  -- find FNamePool
  if CUEDEFS.NamePoolData == nil then
    Core.Runtime.log( 'Searching for NamePool' )
    local ready, scanError = Core.NameScan.findNamePoolData(cancellationThread)
    if not ready then
      local reason = tostring(scanError)
      Core.Runtime.log( 'NamePool scan failed:' .. reason )
      return nil, 'Core.NameScan.findNamePoolData failed:' .. reason
    end

    local symbolName = getNameFromAddress( CUEDEFS.NamePoolData, true, false, false )
    if symbolName:find( extractFileNameWithoutExt(process), nil, true ) then
      savedSettings.NamePoolData = getNameFromAddress( CUEDEFS.NamePoolData ) -- It is a module address; save it as a relocatable symbol
    end

  end

  if cancellationThread and cancellationThread.Terminated then return nil, 'UEInfoScanner terminated' end

  --still here, notify that there is some unreal info available
  Core.Menu.createUEMenu(true)

  if CUEDEFS.NameToIndex == nil then
    Core.Runtime.log( 'Building FName lookup table' )

    Core.Menu.setScannerStatus( 'Building FName lookup table' )

    local ready, cacheError = Core.Scanner.cacheScannerNames( cancellationThread )
    if not ready then return nil, cacheError end
  end

  -- resolve FName::ToString
  Core.Scanner.findScannerNameConversion()

  if cancellationThread and cancellationThread.Terminated then return nil, 'UEInfoScanner terminated' end

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// INCOMPLETE RUNTIME

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// OBJECT REGISTRY

--- Restore/scan GUObjectArray and its UObject layout
-- @param savedSettings table|userdata @ persisted scanner settings
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when this stage succeeds
-- @return string|nil @ error
function Core.Scanner.findScannerObjects(savedSettings, cancellationThread)
  -- restore
  if CUEDEFS.ObjectArray == nil then
    local savedSymbol = savedSettings.ObjectArray
    if savedSymbol then
      CUEDEFS.ObjectArray = getAddressSafe(savedSymbol)
    end
  end
  if CUEDEFS.ObjectArray ~= nil and CUEDEFS.UObject ~= nil then return true end

  Core.Runtime.log('Scanning for object table')
  Core.Menu.setScannerStatus('Scanning for object table')

  -- signature
  if CUEDEFS.ObjectArray == nil then
    CUEDEFS.ObjectArray = Core.Signatures.ue_findObjectArrayBySignaturesInternal()
  end

  --[[
    ue_findObjectArrayBySignaturesInternal
    ├─ scan GObjects sigs
    ├─ decode RIP relative addrs
    ├─ normalize object array
    │  ├─ test decoded addr directly
    │  ├─ test common embedded-field shifts
    │  │  ├─ target
    │  │  ├─ target - 0x10
    │  │  └─ target - 0x24
    │  └─ repeat the interpretations through one pointer indirection
    └─ validate object array
      ├─ validate element and chunk counts
      ├─ obtain the first chunk
      ├─ obtain the first UObject
      └─ verify object has a non-null vtable
  ]]
  local ready, scanError = Core.Objects.FindObjectArray(cancellationThread)
  if not ready then   return nil, 'Core.Objects.FindObjectArray failed: ' .. (scanError or 'No error given')    end

  savedSettings.ObjectArray = getNameFromAddress( CUEDEFS.ObjectArray, true, false, false )

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--/// ENGINE GLOBALS

--- Find the engine global and live instance
-- @param savedSettings table|userdata @ persisted scanner settings
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when this stage succeeds
-- @return string|nil @ error
function Core.Scanner.findScannerEngine(savedSettings, cancellationThread)
  if CUEDEFS.UGameEngine ~= nil then return true end

  Core.Runtime.log('Searching for GEngine')
  Core.Menu.setScannerStatus('Searching for GEngine')

  CUEDEFS.GEngine = Core.Signatures.ue_findUObjectGlobalBySignaturesInternal('GEngine')

  if CUEDEFS.GEngine then
    CUEDEFS.UGameEngine = readPointer(CUEDEFS.GEngine)

    Core.Runtime.log( ('SIG: GEngine instance is 0x%X'):format( CUEDEFS.UGameEngine ) )

  else

    Core.Runtime.log('SIG: using name-based GEngine fallback')

    local ready, scanError = Core.Engine.FindGEngine(cancellationThread)
    Core.Runtime.log('Core.Engine.FindGEngine returned')

    if not ready then
      local message = 'Core.Engine.FindGEngine failed'

      if scanError then message = message .. ':' .. scanError end
      Core.Runtime.log(message)

      return nil, 'Core.Engine.FindGEngine failed:' .. tostring(scanError)
    end

  end

  if CUEDEFS.GEngine and CUEDEFS.GEngine ~= 0 then
    local relocatableAddress = getNameFromAddress( CUEDEFS.GEngine, true, false, false )
    savedSettings.GEngine = relocatableAddress
    ceUEDumperRegisterSymbol( 'pGEngine', relocatableAddress )
  end

  Core.Runtime.log('Searching for GWorld')
  Core.Menu.setScannerStatus('Searching for GWorld')

  CUEDEFS.GWorld = Core.Signatures.ue_findUObjectGlobalBySignaturesInternal('GWorld', 'World')

  if CUEDEFS.GWorld and CUEDEFS.GWorld ~= 0 then
    local relocatableAddress = getNameFromAddress( CUEDEFS.GWorld, true, false, false )
    savedSettings.GWorld = relocatableAddress
    ceUEDumperRegisterSymbol( 'pGWorld', relocatableAddress )
    Core.Runtime.log( ('SIG: GWorld instance is 0x%X'):format( readPointer( CUEDEFS.GWorld ) or 0 ) )
  else
    Core.Runtime.log('SIG: no validated GWorld target; UWorld dissection is unavailable')
  end

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// ENGINE CLASS

--- Resolve the runtime Engine UClass & find the class-pointer offset if needed
-- @return boolean|nil @ true when the class member is known
-- @return string|nil @ error
function Core.Scanner.resolveScannerEngineClass()
  local objectGetName = Core.Reflection.UObject_getName

  if CUEDEFS.UObject.Class == nil then --normal situation
    Core.Runtime.log('Figuring out the "class" offset')

    for index = 1, 32 do --skip 0 as it's the vftable
      local memberOffset = index * 4
      local candidateClass = readPointer( CUEDEFS.UGameEngine + memberOffset )

      if objectGetName(candidateClass) == 'GameEngine' then
        CUEDEFS.UObject.Class = memberOffset
        break
      end

    end

  end

  if CUEDEFS.UObject.Class == nil then
    Core.Runtime.log('Failed finding the "class" offset')
    return nil, 'UObject.Class not found'
  end

  CUEDEFS.GameEngineClass = readPointer( CUEDEFS.UGameEngine + CUEDEFS.UObject.Class )

  local instanceName = objectGetName(CUEDEFS.UGameEngine)
  local className = objectGetName(CUEDEFS.GameEngineClass)

  Core.Runtime.log(
        ('GEngine layout: instance name=%s class=0x%X class name=%s')
        :format( tostring(instanceName), CUEDEFS.GameEngineClass, tostring(className) )
      )

  return true
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// SUPERSTRUCT / PROPERTY LAYOUT

--- Find the direct Engine superclass pointer in GameEngine
-- @return number|nil @ candidate SuperStruct offset
function Core.Scanner.findNamedEngineSuperOffset()
  local objectGetName = Core.Reflection.UObject_getName

  for index = 0, 32 do
    local memberOffset = index * 8
    local parentAddress = readPointer( CUEDEFS.GameEngineClass + memberOffset )

    if objectGetName(parentAddress) == 'Engine' then --the super of Gameengbine is Engine
      return memberOffset
    end

  end

  return nil
end

--- Find an inheritance chain containing Engine for a derived engine class
-- @return number|nil @ candidate SuperStruct offset
function Core.Scanner.findDerivedEngineSuperOffset()
  local testSuperStructOffset = Core.Reflection.testIfSuperStructOffset

  --it's not a GameEngine class so not sure that comes after (could be more inheritance)
  for index = 1, 32 do
    local memberOffset = index * 8
    local superclassNames = testSuperStructOffset( CUEDEFS.GameEngineClass, memberOffset )

    if superclassNames and #superclassNames > 2 then

      for _, className in ipairs(superclassNames) do
        if className == 'Engine' then return memberOffset end
      end

    end

  end

  return nil
end

--- Find SuperStruct and synchronize the UClass and UStruct layouts
-- @return boolean|nil @ true when a superclass offset was found
-- @return string|nil @ error
function Core.Scanner.findScannerSuperStruct()

  CUEDEFS.UStruct =
  {
    Name = CUEDEFS.UObject.Name,
    Class = CUEDEFS.UObject.Class,
  }

  --gather more info in case it was missed earlier (some paths don't need it yet)

  --the superstruct (UStruct) name of the GameEngine class is Engine
  --so find a pointer inside the class that leads to an UObject with the name Engine

  --if the game uses an inherited class onject, like OakEngine, then first comes GameEngine (or whatever comes first)
  --the superlist will end with Engine->Objec

  CUEDEFS.UClass = CUEDEFS.UClass or
  {
    Name = CUEDEFS.UObject.Name,
    Class = CUEDEFS.UObject.Class,
  }

  if CUEDEFS.UClass.SuperStruct then --already obtained earlier
    CUEDEFS.UStruct.SuperStruct = CUEDEFS.UClass.SuperStruct
  else

    --superstruct not yet found
    if Core.Reflection.UObject_getName(CUEDEFS.GameEngineClass) == 'GameEngine' then
      CUEDEFS.UStruct.SuperStruct = Core.Scanner.findNamedEngineSuperOffset()
    else
      CUEDEFS.UStruct.SuperStruct = Core.Scanner.findDerivedEngineSuperOffset()
    end

  end

  if CUEDEFS.UStruct.SuperStruct == nil then
    local inferredOffset, reason = Core.Reflection.ue_inferSuperStructOffsetInternal( CUEDEFS.GameEngineClass )

    CUEDEFS.UStruct.SuperStruct = inferredOffset

    if not inferredOffset then return nil, 'Failed finding the SuperStruct field: ' .. tostring(reason) end
  end

  CUEDEFS.UClass.Name = CUEDEFS.UStruct.Name
  CUEDEFS.UClass.Class = CUEDEFS.UStruct.Class
  CUEDEFS.UClass.SuperStruct = CUEDEFS.UStruct.SuperStruct

  return true
end

--- Retain the concrete engine class and select its named GameEngine base
-- @return void
function Core.Scanner.selectScannerGameEngineBase()
  local objectGetName = Core.Reflection.UObject_getName
  CUEDEFS.RealGameEngineClass = CUEDEFS.GameEngineClass

  --CUEDEFS.GameEngineClass might not be the base "GameEngine" class.  Find it if that's the case (to make some assumptions come true)
  local currentClassAddress = CUEDEFS.GameEngineClass

  while currentClassAddress and currentClassAddress ~= 0 do

    if objectGetName(currentClassAddress) == 'GameEngine' then
      CUEDEFS.GameEngineClass = currentClassAddress
      return
    end

    currentClassAddress = readPointer( currentClassAddress + CUEDEFS.UClass.SuperStruct )
  end

  Core.Runtime.log( 'GameEngine base name is unavailable; retaining the resolved concrete engine class' )
end

--- Find remaining reflected property layout
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when reflection scan succeeds
-- @return string|nil @ error
function Core.Scanner.findScannerPropertyLayout(cancellationThread)

  if cancellationThread and cancellationThread.Terminated then return nil, 'ueScannerThread terminated' end

  --everything ok so far. Try to find the layout of Property Field objects.  Can be either UProperty or FProperty. Doesn't matter
  Core.Runtime.log( 'Figuring out the other offsets (Core.PropertyLayout.findGameInstanceFPropertyAndFields) ' )
  Core.Menu.setScannerStatus('Figuring out offsets')

  local ready, layoutError = Core.PropertyLayout.findGameInstanceFPropertyAndFields(cancellationThread)

  if not ready then
    return nil, 'Reflection field layout scanner failed: ' .. tostring(layoutError or 'no error was produced')
  end

  return ready
end

--- Complete missing name, object, engine, reflection layouts
-- Branches to get reflection essentials
-- @param savedSettings table|userdata @ persisted scanner settings
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when scan succeeds
-- @return string|nil @ error
function Core.Scanner.findIncompleteScannerRuntime(savedSettings, cancellationThread)
  Core.Runtime.log( 'New or incomplete state' )

  local ready, stageError = Core.Scanner.findScannerNames(savedSettings, cancellationThread)
  if not ready then return nil, stageError end

  ready, stageError = Core.Scanner.findScannerObjects(savedSettings, cancellationThread)
  if not ready then return nil, stageError end

  ready, stageError = Core.Scanner.findScannerEngine(savedSettings, cancellationThread)
  if not ready then return nil, stageError end

  ready, stageError = Core.Scanner.resolveScannerEngineClass()
  if not ready then return nil, stageError end

  ready, stageError = Core.Scanner.findScannerSuperStruct()
  if not ready then return nil, stageError end

  Core.Scanner.selectScannerGameEngineBase()

  return Core.Scanner.findScannerPropertyLayout(cancellationThread)
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// SCANNER ENTRY POINT

--- Restore/scan UE reflection layout
--
-- It restores saved defines when possible, revalidates names,
-- finds missing globals/layout members, registers CE symbols and menus
-- Thus also stores the layout
--
-- @param cancellationThread table|nil @ scan worker
-- @return boolean|nil @ true when initialization succeeds
-- @return string|nil @ error
function Core.Scanner.UEInfoScanner(cancellationThread)
  --can be called directly or with a thread
  Core.Runtime.log('UEInfoScanner start')

  if process == nil then return false, 'No process selected' end

  -- calculate hash for a chunk of file data
  local versionIdentifier = Core.Persistence.getVersionIdentifier()

  if versionIdentifier == nil then
    Core.Runtime.log('file and main module unreadable')
    return false
  end

  local settingsKey = 'ceUEDumper\\Layouts\\CUEDEFS\\' .. process .. '-' .. versionIdentifier
  Core.Runtime.log( 'Settings key: ' .. settingsKey)
  local savedSettings = getSettings( settingsKey, true )

  Core.Scanner.initializeScannerState(cancellationThread)

  --[[
  check the settings if everything has already been found, or if only a subset was found so far.
  If only a subset, go through the whole thing, but if everything was found then load all from the registry, but still
  go through the string cache system
  --]]

  local ready, initializationError

  if savedSettings.fullyParsed then
    ready, initializationError = Core.Scanner.restoreScannerRuntime( savedSettings, cancellationThread )
  else
    ready, initializationError = Core.Scanner.findIncompleteScannerRuntime( savedSettings, cancellationThread )
  end

  if not ready then return ready, initializationError end

  -- store the layout for quick repeated lookups (reruns)
  Core.Persistence.saveLayout(savedSettings)

  Core.Runtime.log('success. Runtime initialized; external structure callbacks are not adopted')
  
  Core.Menu.showCompletedState()

  return ready
end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// SCAN WORKER INIT

--- Wait for the active scanner worker, increases task priority
-- @param timeout number @ maximum wait in milliseconds
-- @return boolean|nil @ CE thread wait result
function Core.Scanner.WaitForUnrealEngineInfo(timeout)
  if ueScannerThread then
    ueScannerThread.Priority = 'tpHigher' -- poke scheduler
    return Core.Runtime.ue_waitForThreadInternal( ueScannerThread, timeout )
  end

  return true
end

--- Spawn a worker to scan UE runtime. entry point
function Core.Scanner.LaunchUEInfoScanner()
  
  if ueScannerThread and Core.State.scannerRunning then
    ueScannerThread.Priority = 'tpHigher' -- increase scheduler priority if not finished
    return
  end

  -- not running, should terminate
  if ueScannerThread then
    ueScannerThread.Terminate()
    
    if Core.Runtime.ue_waitForThreadInternal( ueScannerThread, 5000 ) then
      ueScannerThread.destroy()
      ueScannerThread = nil
    end
    ueScannerThread = nil
  end

  Core.State.scannerRunning = true
  Core.Menu.createUEMenu(true)

  ueScannerThread = createThread(function(t)
    Core.State.lastScannerError = nil

    Core.Runtime.log('ueScannerThread started')

    t.Priority = 'tpIdle' -- runs when other processes are idle

    local scannerResult, scannerError
    local succeeded

    succeeded, scannerResult, scannerError = xpcall( function() return Core.Scanner.UEInfoScanner(t) end, debug.traceback )

    if not succeeded then
      scannerError = scannerResult
      scannerResult = nil
    end


    Core.Runtime.log('ueScannerThread finished')
    Core.State.scannerRunning = false

    if scannerResult then
      Core.Runtime.log('UEInfoScanner: Success')
      synchronize( function() CUEDEFS.GUI.miUnrealEngine.Caption = 'ceUEDumper' end )
    else
      Core.State.lastScannerError = scannerError or 'UEInfoScanner returned no result'
      
      if scannerError then
        Core.Runtime.log('UEInfoScanner failure:' .. scannerError)
      else
        Core.Runtime.log('UEInfoScanner failure (???)')
      end

      Core.Menu.createUEMenu(false)
    end

  end)
end


-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.PROCESS

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// DETECTION

--- Check whether the process is UE
-- @return boolean @ true when imports, version metadata or module names match UE
function Core.Process.couldBeUnrealEngine()
  local processName = extractFileNameWithoutExt(process) -- TODO: any way to improve immediate inference?

  if not processName then return false end

  if getAddressSafe(processName .. '.agsInit') or getAddressSafe(processName .. '.agsInitialize') or processName:lower():endsWith('shipping') then
    return true
  end

  local loadedModules = enumModules()

  if not loadedModules or #loadedModules == 0 then return false end

  local fileVersionText, fileVersionComponents = getFileVersion( loadedModules[1].PathToFile )

  if not fileVersionComponents then return false end

  local productVersion = fileVersionComponents.ProductVersion

  if productVersion and ( productVersion:find('%+UE4') or productVersion:find('%+UE5') ) then return true end

  local originalFilename = fileVersionComponents.OriginalFilename

  if not originalFilename then return false end

  local originalProcessName = extractFileNameWithoutExt(originalFilename)

  return originalProcessName and originalProcessName:lower():endsWith('shipping') or false
end

--- Spawn a worker to check if the target is UE-ish
-- @param processId number
-- @return void
function Core.Process.detectUnrealProcess(processId)

  createThread(function(detectionThread)
    detectionThread.Name = 'ceUEDumper UE checker'
    waitForExports()

    local isUnreal = Core.Process.couldBeUnrealEngine()

    if not isUnreal and getProcessAge then
      local processAge = getProcessAge()

      if processAge and processAge < 30000 then -- fresh, try again for it's new
        sleep(30000) -- wait for the game to load
        isUnreal = getOpenedProcessID() == processId and Core.Process.couldBeUnrealEngine()
      end
    end

    if isUnreal and getOpenedProcessID() == processId then Core.Menu.createUEMenu(false) end
  end)
end

--- Install a reload-safe OnProcessOpened listener
-- @return void
function Core.Process.installProcessOpenedListener()

  -- we preserve the hook state through it
  local hookState = package.loaded[ 'ceUEDumper.processOpenedHook' ]

  -- first time?
  if not hookState then
    hookState = {}
    package.loaded['ceUEDumper.processOpenedHook'] = hookState
  end

  -- just store the callback in the state
  hookState.callback = function(processid, processhandle, caption)
    -- local processId = getOpenedProcessID()
    Core.Menu.destroyUEMenu()
    if type(processid) ~= 'number' or processid <= 0 or processid == 0xFFFFFFFF or processid == 0xFFFFFFFE then return end
    if ueScannerThread then ueScannerThread.Terminate() end
    Core.Process.detectUnrealProcess(processid)
  end

  -- installing once
  if not hookState.installed then
    -- old handler to be preserved
    local previousHandler = MainForm.OnProcessOpened

    MainForm.OnProcessOpened = function(processid, processhandle, caption) -- per lua doc
      if previousHandler then previousHandler(processid, processhandle, caption) end
      if hookState.callback then hookState.callback(processid, processhandle, caption) end
    end

    hookState.installed = true
  end

  -- spawn a checker anyway for the function is called
  local processId = getOpenedProcessID()
  if type(processId) == 'number' and processId > 0 and processId ~= 0xFFFFFFFF and processId ~= 0xFFFFFFFE then
    Core.Process.detectUnrealProcess(processId)
  end
end

Core.Process.installProcessOpenedListener()

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--///--///--///--///--/// CORE.API

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// CORE STATUS

--- Get UE explored layout definitions
-- @return table|nil @ CUEDEFS table
function Core.API.ue_getDefinitionsInternal()
  return CUEDEFS
end

--- Returns scanner state for last run
-- @return table @ status containing running, error, Core.Runtime.log, ready
function Core.API.ue_getScannerStatusInternal()

  local ready = type(CUEDEFS) == 'table'
                and type( CUEDEFS.UObject ) == 'table'
                and type( CUEDEFS.UClass ) == 'table'
                and type( CUEDEFS.FProperty ) == 'table'
                and CUEDEFS.ObjectArray ~= nil
                and CUEDEFS.UObject.Class ~= nil
                and CUEDEFS.FProperty.Offset ~= nil
  
  return
  {
    running = Core.State.scannerRunning,
    signatureSelection = Core.State.signatureSelection,
    error = Core.State.lastScannerError,
    log = type(CUEDEFS) == 'table' and CUEDEFS.log or '',
    ready = ready,
    namesReady = ready and CUEDEFS.NamePoolValidated == true,
    namePool = type(CUEDEFS) == 'table' and CUEDEFS.NamePoolData or nil,
    namePoolValidated = type(CUEDEFS) == 'table' and CUEDEFS.NamePoolValidated == true,
    namePoolSourceModule = type(CUEDEFS) == 'table' and CUEDEFS.NamePoolSourceModule or nil,
    namePoolScanMethod = type(CUEDEFS) == 'table' and CUEDEFS.NamePoolScanMethod or nil,
    cachedNameCount = type(CUEDEFS) == 'table' and CUEDEFS.CachedNameCount or 0,
    fnameToString = type(CUEDEFS) == 'table' and CUEDEFS.FNameToString or nil,
  }

end

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--///--///--///--///--///--/// EXPORT

Core.API.configureSignatures =
  function(mode)
    assert(mode == 'first' or mode == 'scored', 'signatureSelection must be first or scored')
    assert(not Core.State.scannerRunning or mode == Core.State.signatureSelection, 'Cannot change signature selection during scan')
    Core.State.signatureSelection = mode
  end

Core.API.definitions = Core.API.ue_getDefinitionsInternal
Core.API.launch = Core.Scanner.LaunchUEInfoScanner -- Core.API.ue_scannerLaunchInternal
Core.API.wait = Core.Scanner.WaitForUnrealEngineInfo -- Core.API.ue_scannerWaitInternal
Core.API.objectName = Core.Reflection.UObject_getName -- Core.API.ue_objectGetNameInternal
Core.API.objectProperties = Core.Reflection.UObject_enumProperties -- Core.API.ue_objectEnumPropertiesInternal
Core.API.classProperties = Core.Reflection.UClass_enumProperties -- Core.API.ue_classEnumPropertiesInternal
Core.API.scan = Core.Scanner.UEInfoScanner -- Core.API.ue_findRuntimeInternal
Core.API.probeClassProperties = Core.Reflection.probeClassProperties
Core.API.propertyMetadata = Core.Reflection.readPropertyMetadata
Core.API.status = Core.API.ue_getScannerStatusInternal
Core.API.processEvent = Core.Signatures.resolveProcessEvent
Core.API.subsystems = Core

return Core.API
