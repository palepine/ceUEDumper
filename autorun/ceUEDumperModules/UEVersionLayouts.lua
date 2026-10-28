--[[
  Versioned UE layouts
  
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

  UE4SS Copyright (c) 2022 Narknon

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

local Module = {}

local function copy(value)
  if type(value) ~= 'table' then return value end

  local result = {}

  for key, child in pairs(value) do
    result[key] = copy(child)
  end

  return result
end

local function merge(destination, source)

  for key, value in pairs( source or {} ) do

    if type(value) == 'table' then
      destination[ key ] = destination[ key ] or {}
      merge( destination[ key ], value )
    else
      destination[ key ] = value
    end

  end

  return destination
end

local function propertyTypes(baseOffset, arrayInnerOffset)
  local arrayInner = arrayInnerOffset or baseOffset

  return
  {
    FObjectPropertyBase =
    {
      PropertyClass = baseOffset
    },
    FStructProperty =
    {
      Struct = baseOffset
    },
    FArrayProperty =
    {
      Inner = arrayInner
    },
    FMapProperty =
    {
      KeyProp = baseOffset,
      ValueProp = baseOffset + 0x8,
      MapLayout = baseOffset + 0x10
    },
    FSetProperty =
    {
      ElementProp = baseOffset,
      SetLayout = baseOffset + 0x8
    },
    FBoolProperty =
    {
      FieldSize = baseOffset,
      ByteOffset = baseOffset + 0x1,
      ByteMask = baseOffset + 0x2,
      FieldMask = baseOffset + 0x3
    },
    FByteProperty =
    {
      Enum = baseOffset
    },
    FEnumProperty =
    {
      UnderlyingProp = baseOffset,
      Enum = baseOffset + 0x8
    },
    FClassProperty =
    {
      MetaClass = baseOffset + 0x8
    },
    FSoftClassProperty =
    {
      MetaClass = baseOffset + 0x8
    },
    FDelegateProperty =
    {
      SignatureFunction = baseOffset
    },
    FMulticastDelegateProperty =
    {
      SignatureFunction = baseOffset
    },
    FInterfaceProperty =
    {
      InterfaceClass = baseOffset
    },
    FFieldPathProperty =
    {
      PropertyClass = baseOffset
    },
  }
end

local function legacyProperty(offset, nextOffset, totalSize)
  return
  {
    Class = 0x10,
    Name = 0x18,
    Owner = 0x20,
    ArrayDim = 0x30,
    Size = 0x34,
    PropertyFlags = 0x38,
    Offset = offset,
    PropertyLinkNext = nextOffset,
    UEP_TotalSize = totalSize,
  }
end

local function modernProperty(field, offsets)
  return
  {
    Class = field.Class,
    Owner = field.Owner,
    Name = field.Name,
    ArrayDim = offsets.ArrayDim,
    Size = offsets.ElementSize,
    PropertyFlags = offsets.PropertyFlags,
    RepIndex = offsets.RepIndex,
    RepNotifyFunc = offsets.RepNotifyFunc,
    Offset = offsets.Offset_Internal,
    PropertyLinkNext = offsets.PropertyLinkNext,
    NextRef = offsets.NextRef,
    DestructorLinkNext = offsets.DestructorLinkNext,
    PostConstructLinkNext = offsets.PostConstructLinkNext,
    UEP_TotalSize = offsets.UEP_TotalSize,
  }
end

local function commonObject(casePreserving)
  return
  {
    ObjectFlags = 0x8,
    InternalIndex = 0xC,
    Class = 0x10,
    Name = 0x18,
    Outer = casePreserving and 0x28 or 0x20,
    UEP_TotalSize = casePreserving and 0x30 or 0x28,
  }
end

-- Byte offsets
-- from UE4SS VTableLayout templates
local VIRTUAL_OFFSETS =
{
  [4] =
  {
    [7]  =
    {
      ProcessEvent = 0x1A0,
      EngineTick = 0x218
    },
    [8]  =
    {
      ProcessEvent = 0x188,
      EngineTick = 0x200
    },
    [9]  =
    {
      ProcessEvent = 0x1A0,
      EngineTick = 0x218
    },
    [10] =
    {
      ProcessEvent = 0x1A0,
      EngineTick = 0x218
    },
    [11] =
    {
      ProcessEvent = 0x1B8,
      EngineTick = 0x228
    },
    [12] =
    {
      ProcessEvent = 0x1B8,
      EngineTick = 0x228
    },
    [13] =
    {
      ProcessEvent = 0x1B8,
      EngineTick = 0x230
    },
    [14] =
    {
      ProcessEvent = 0x1D8,
      EngineTick = 0x250
    },
    [15] =
    {
      ProcessEvent = 0x1E0,
      EngineTick = 0x258
    },
    [16] =
    {
      ProcessEvent = 0x200,
      EngineTick = 0x278
    },
    [17] =
    {
      ProcessEvent = 0x208,
      EngineTick = 0x280
    },
    [18] =
    {
      ProcessEvent = 0x208,
      EngineTick = 0x280
    },
    [19] =
    {
      ProcessEvent = 0x208,
      EngineTick = 0x280
    },
    [20] =
    {
      ProcessEvent = 0x218,
      EngineTick = 0x290
    },
    [21] =
    {
      ProcessEvent = 0x210,
      EngineTick = 0x288
    },
    [22] =
    {
      ProcessEvent = 0x210,
      EngineTick = 0x288
    },
    [23] =
    {
      ProcessEvent = 0x220,
      EngineTick = 0x298
    },
    [24] =
    {
      ProcessEvent = 0x220,
      EngineTick = 0x2A0
    },
    [25] =
    {
      ProcessEvent = 0x220,
      EngineTick = 0x2B8
    },
    [26] =
    {
      ProcessEvent = 0x228,
      EngineTick = 0x2C0
    },
    [27] =
    {
      ProcessEvent = 0x230,
      EngineTick = 0x2C8
    },
  },
  [5] =
  {
    [0] =
    {
      ProcessEvent = 0x268,
      EngineTick = 0x300
    },
    [1] =
    {
      ProcessEvent = 0x270,
      EngineTick = 0x308
    },
    [2] =
    {
      ProcessEvent = 0x278,
      EngineTick = 0x310
    },
    [3] =
    {
      ProcessEvent = 0x278,
      EngineTick = 0x310
    },
    [4] =
    {
      ProcessEvent = 0x278,
      EngineTick = 0x310
    },
    [5] =
    {
      ProcessEvent = 0x288,
      EngineTick = 0x320
    },
    [6] =
    {
      ProcessEvent = 0x270,
      EngineTick = 0x308
    },
    [7] =
    {
      ProcessEvent = 0x270,
      EngineTick = 0x308
    },
    [8] =
    {
      ProcessEvent = 0x260,
      EngineTick = 0x2F8
    },
  },
}

local function applyVirtualOffsets(profile, major, minor)
  local versionOffsets = VIRTUAL_OFFSETS[major] and VIRTUAL_OFFSETS[major][minor]
  if not versionOffsets then return profile end

  profile.UObject.ProcessEventVTableOffset = versionOffsets.ProcessEvent
  profile.UEngine = { TickVTableOffset = versionOffsets.EngineTick }
  return profile
end

local function legacyProfile(minor)
  local profile = { UObject = commonObject(false) }
  local struct
  local property
  local func

  if minor == 7 then
    struct =
    {
      SuperStruct = 0x30,
      Children = 0x38,
      PropertiesSize = 0x40,
      MinAlignment = 0x58,
      Script = 0x48,
      PropertyLink = 0x60,
      RefLink = 0x68,
      DestructorLink = 0x70,
      PostConstructLink = 0x78,
      UEP_TotalSize = 0x90
    }

    property = legacyProperty( 0x4C, 0x50, 0x70 )

    func =
    {
      FunctionFlags = 0x90,
      NumParms = 0x96,
      ParmsSize = 0x98,
      ReturnValueOffset = 0x9A,
      RPCId = 0x9C,
      RPCResponseId = 0x9E,
      FirstPropertyToInit = 0xA0,
      Func = 0xA8,
      UEP_TotalSize = 0xB0
    }
  elseif minor <= 10 then
    struct =
    {
      SuperStruct = 0x30,
      Children = 0x38,
      PropertiesSize = 0x40,
      MinAlignment = 0x44,
      Script = 0x48,
      PropertyLink = 0x58,
      RefLink = 0x60,
      DestructorLink = 0x68,
      PostConstructLink = 0x70,
      UEP_TotalSize = 0x88
    }

    property = legacyProperty( 0x4C, 0x50, 0x70 )
    
    func =
    {
      FunctionFlags = 0x88,
      NumParms = 0x8E,
      ParmsSize = 0x90,
      ReturnValueOffset = 0x92,
      RPCId = 0x94,
      RPCResponseId = 0x96,
      FirstPropertyToInit = 0x98,
      EventGraphFunction = 0xA0,
      EventGraphCallOffset = 0xA8,
      Func = 0xB0,
      UEP_TotalSize = 0xB8
    }
  elseif minor <= 17 then
    struct =
    {
      SuperStruct = 0x30,
      Children = 0x38,
      PropertiesSize = 0x40,
      MinAlignment = 0x44,
      Script = 0x48,
      PropertyLink = 0x58,
      RefLink = 0x60,
      DestructorLink = 0x68,
      PostConstructLink = 0x70,
      UEP_TotalSize = 0x88
    }

    property = legacyProperty( 0x50, 0x58, 0x78 )

    func =
    {
      FunctionFlags = 0x88,
      NumParms = 0x8E,
      ParmsSize = 0x90,
      ReturnValueOffset = 0x92,
      RPCId = 0x94,
      RPCResponseId = 0x96,
      FirstPropertyToInit = 0x98,
      EventGraphFunction = 0xA0,
      EventGraphCallOffset = 0xA8,
      Func = 0xB0,
      UEP_TotalSize = 0xB8
    }
  elseif minor <= 21 then
    struct =
    {
      SuperStruct = 0x30,
      Children = 0x38,
      PropertiesSize = 0x40,
      MinAlignment = 0x44,
      Script = 0x48,
      PropertyLink = 0x58,
      RefLink = 0x60,
      DestructorLink = 0x68,
      PostConstructLink = 0x70,
      UEP_TotalSize = 0x88
    }

    property = legacyProperty( 0x44, 0x50, 0x70 )
    
    func =
    {
      FunctionFlags = 0x88,
      NumParms = 0x8C,
      ParmsSize = 0x8E,
      ReturnValueOffset = 0x90,
      RPCId = 0x92,
      RPCResponseId = 0x94,
      FirstPropertyToInit = 0x98,
      EventGraphFunction = 0xA0,
      EventGraphCallOffset = 0xA8,
      Func = 0xB0,
      UEP_TotalSize = 0xB8
    }
  else
    struct =
    {
      SuperStruct = 0x40,
      Children = 0x48,
      PropertiesSize = 0x50,
      MinAlignment = 0x54,
      Script = 0x58,
      PropertyLink = 0x68,
      RefLink = 0x70,
      DestructorLink = 0x78,
      PostConstructLink = 0x80,
      UEP_TotalSize = 0x98
    }

    property = legacyProperty( 0x44, 0x50, 0x70 )

    func =
    {
      FunctionFlags = 0x98,
      NumParms = 0x9C,
      ParmsSize = 0x9E,
      ReturnValueOffset = 0xA0,
      RPCId = 0xA2,
      RPCResponseId = 0xA4,
      FirstPropertyToInit = 0xA8,
      EventGraphFunction = 0xB0,
      EventGraphCallOffset = 0xB8,
      Func = 0xC0,
      UEP_TotalSize = 0xC8
    }
  end

  profile.UStruct = struct
  profile.UClass = copy(struct)
  profile.UClass.PropertyLinkAlt = struct.Children
  profile.UField =
  {
    Next = 0x28,
    UEP_TotalSize = 0x30
  }
  profile.FFieldClass = { Name = profile.UObject.Name }
  profile.FField =
  {
    Class = profile.UObject.Class,
    Owner = profile.UObject.Outer,
    Name = profile.UObject.Name,
    PropertyLinkNext = 0x28
  }
  profile.FProperty = property
  profile.UFunction = func

  local propertyBase = property.UEP_TotalSize

  merge( profile, propertyTypes( propertyBase ) )

  if minor >= 11 then
    profile.FUObjectItem =
    {
      Object = 0x0,
      UEP_TotalSize = minor <= 12 and 0x10 or 0x18
    }
    profile.ObjectArrayEntryStructSize = profile.FUObjectItem.UEP_TotalSize
    profile.ObjectArrayObjectOffset = 0x0
  end

  if minor >= 20 then

    profile.FUObjectArray =
    {
      ObjObjects = 0x10
    }

    profile.TUObjectArray =
    {
      Objects = 0x0,
      PreAllocatedObjects = 0x8,
      MaxElements = 0x10,
      NumElements = 0x14,
      MaxChunks = 0x18,
      NumChunks = 0x1C,
      UEP_TotalSize = 0x20
    }
  end

  return applyVirtualOffsets( profile, 4, minor )
end

local function modernProfile(major, minor, casePreserving)
  local object = commonObject(casePreserving)
  local field
  local fieldClass
  local propertyOffsets
  local structShift = casePreserving and 0x8 or 0

  if casePreserving then
    field =
    {
      Class = 0x8,
      Owner = 0x10,
      PropertyLinkNext = 0x20,
      Name = 0x28,
      Flags = 0x34,
      UEP_TotalSize = 0x38
    }
    fieldClass =
    {
      Name = 0x0,
      Id = 0x10,
      CastFlags = 0x18,
      ClassFlags = 0x20,
      SuperClass = 0x28,
      UEP_TotalSize = 0x48
    }
    propertyOffsets =
    {
      ArrayDim = 0x38,
      ElementSize = 0x3C,
      PropertyFlags = 0x40,
      RepIndex = 0x48,
      Offset_Internal = 0x4C,
      RepNotifyFunc = 0x50,
      PropertyLinkNext = 0x60,
      NextRef = 0x68,
      DestructorLinkNext = 0x70,
      PostConstructLinkNext = 0x78,
      UEP_TotalSize = 0x80
    }
  elseif major == 5 and minor >= 3 then
    field =
    {
      Class = 0x8,
      Owner = 0x10,
      PropertyLinkNext = 0x18,
      Name = 0x20,
      Flags = 0x28,
      UEP_TotalSize = 0x30
    }
    fieldClass =
    {
      Name = major == 5 and minor >= 8 and 0x8 or 0x0,
      SuperClass = major == 5 and minor >= 8 and 0x28 or 0x20,
      UEP_TotalSize = major == 5 and minor >= 8 and 0x48 or 0x40
    }
    propertyOffsets =
    {
      ArrayDim = 0x30,
      ElementSize = 0x34,
      PropertyFlags = 0x38,
      RepIndex = 0x40,
      Offset_Internal = 0x44,
      PropertyLinkNext = 0x48,
      NextRef = 0x50,
      DestructorLinkNext = 0x58,
      PostConstructLinkNext = 0x60,
      RepNotifyFunc = 0x68,
      UEP_TotalSize = 0x70
    }
  else
    field =
    {
      Class = 0x8,
      Owner = 0x10,
      PropertyLinkNext = 0x20,
      Name = 0x28,
      Flags = 0x30,
      UEP_TotalSize = 0x38
    }
    fieldClass =
    {
      Name = 0x0,
      SuperClass = 0x20,
      UEP_TotalSize = 0x40
    }
    propertyOffsets =
    {
      ArrayDim = 0x38,
      ElementSize = 0x3C,
      PropertyFlags = 0x40,
      RepIndex = 0x48,
      Offset_Internal = 0x4C,
      RepNotifyFunc = 0x50,
      PropertyLinkNext = 0x58,
      NextRef = 0x60,
      DestructorLinkNext = 0x68,
      PostConstructLinkNext = 0x70,
      UEP_TotalSize = 0x78
    }
  end

  local struct =
  {
    SuperStruct = 0x40 + structShift,
    Children = 0x48 + structShift,
    ChildProperties = 0x50 + structShift,
    PropertiesSize = 0x58 + structShift,
    MinAlignment = 0x5C + structShift,
    Script = 0x60 + structShift,
    PropertyLink = 0x70 + structShift,
    RefLink = 0x78 + structShift,
    DestructorLink = 0x80 + structShift,
    PostConstructLink = 0x88 + structShift,
    UEP_TotalSize = 0xB0 + structShift,
  }

  local profile =
  {
    UObject = object,
    UStruct = struct,
    UClass = copy(struct),
    UField =
    {
      Next = 0x28,
      UEP_TotalSize = 0x30
    },
    FFieldClass = fieldClass,
    FField = field,
    FProperty = modernProperty( field, propertyOffsets ),
    UFunction =
    {
      FunctionFlags = 0xB0 + structShift,
      NumParms = 0xB4 + structShift,
      ParmsSize = 0xB6 + structShift,
      ReturnValueOffset = 0xB8 + structShift,
      RPCId = 0xBA + structShift,
      RPCResponseId = 0xBC + structShift,
      FirstPropertyToInit = 0xC0 + structShift,
      EventGraphFunction = 0xC8 + structShift,
      EventGraphCallOffset = 0xD0 + structShift,
      Func = 0xD8 + structShift,
      UEP_TotalSize = 0xE0 + structShift,
    },
    FUObjectItem =
    {
      Object = major == 5 and minor >= 7 and 0x8 or 0x0,
      UEP_TotalSize = 0x18
    },
    ObjectArrayEntryStructSize = 0x18,
    ObjectArrayObjectOffset = major == 5 and minor >= 7 and 0x8 or 0x0,
  }

  profile.UClass.PropertyLinkAlt = struct.ChildProperties

  if major == 5 and minor >= 8 then
    profile.FUObjectArray = { ObjObjects = 0x0 }
    profile.TUObjectArray =
    {
      Objects = 0x0,
      NumElements = 0x8,
      MaxElements = 0xC,
      NumChunks = 0x10,
      MaxChunks = 0x14,
      PreAllocatedObjects = 0x18,
      UEP_TotalSize = 0x20
    }
  else
    profile.FUObjectArray = { ObjObjects = 0x10 }
    profile.TUObjectArray =
    {
      Objects = 0x0,
      PreAllocatedObjects = 0x8,
      MaxElements = 0x10,
      NumElements = 0x14,
      MaxChunks = 0x18,
      NumChunks = 0x1C,
      UEP_TotalSize = 0x20
    }
  end

  local typeBase = propertyOffsets.UEP_TotalSize
  local arrayInner = major == 5 and minor >= 3 and typeBase + 0x8 or typeBase

  merge( profile, propertyTypes( typeBase, arrayInner ) )

  return applyVirtualOffsets( profile, major, minor )
end

--- Return ordered layout candidates for an engine version.
-- UE 4.27 has both ordinary & case-preserving FName builds
function Module.getCandidates(version)
  if type(version) ~= 'table' or type(version.major) ~= 'number' or type(version.minor) ~= 'number' then return {} end

  local candidates = {}

  if version.major == 4 and version.minor >= 7 and version.minor <= 24 then
    candidates[1] =
    {
      id = ('UE4.%d'):format( version.minor ),
      source = 'UE4SS MemberVariableLayout template',
      layout = legacyProfile( version.minor )
    }
  elseif version.major == 4 and version.minor >= 25 and version.minor <= 27 then
    candidates[1] =
    {
      id = ('UE4.%d'):format( version.minor ),
      source = 'UE4SS MemberVariableLayout template',
      layout = modernProfile( 4, version.minor, false )
    }

    if version.minor == 27 then
      candidates[2] =
      {
        id = 'UE4.27-case-preserving',
        source = 'UE4SS MemberVariableLayout_4_27_CasePreserving template',
        layout = modernProfile( 4, 27, true )
      }
    end

  elseif version.major == 5 and version.minor >= 0 and version.minor <= 8 then
    candidates[1] =
    {
      id = ('UE5.%d'):format( version.minor ),
      source = 'UE4SS MemberVariableLayout template',
      layout = modernProfile( 5, version.minor, false )
    }
  end

  return copy(candidates)
end

return Module