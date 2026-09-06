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

  MIT License

  Copyright (c) 2022 Narknon

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is furnished
  to do so, subject to the following conditions:

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

-- ///---///--///---///--///---///--///--///---/// FNAMEPOOL / GNAMES SIGNATURES

--- FNamePool/GNames
Module.GNames =
{
  "48 8D * * * * * E8 * * * * 4C 8B * C6 * * * * * * 48 8B * * * 48 8B * 48 C1 * * 8D * * 49 03 * * * E8 * * * * 83 * * * 74 * 8B * * 48 89",
  "48 8B 05 * * * * 48 85 * 75 * B9 * * * * 48 89 * * * E8 * * * * 48 8B * 48 85 * 74",
  "48 83 * * 48 8B 05 * * * * 48 85 * 75 * B9 * * * * 48 89 * * * E8 * * * * 48 89",
  "48 8D * * * * * EB * 48 8D * * * * * E8 * * * * 48 8B * C6 * * * * * * 48 8B * * * 48 C1 * * 03 * 48 03 * * * 48 83 * * 5B C3",
  "48 83 * * 48 8B 05 * * * * 48 85 * 75 * 33 * 48 89 * * * B9 * * * * E8 * * * * 48 8B * 48 85 * 74 * 33 * 33",
  "48 8D * * * * * E8 * * * * 4C 8B * C6 * * * * * * 48 8B * * * 48 8B * 48 C1 * * C1 * * 49 03 * * * E8 * * * * 8B * * 85 * 74 * 48 8B * * 48 8D",
  "4C 8D 05 * * * * EB * 48 8D * * * * * E8 * * * * 4C 8B * C6 * * * * * * 8B * 8B * 0F * * C1 * * 89 * * * 89 * * * 48 8B * * * 48 C1 * * 03",
  "48 8B * 8B * 74 * 4C 8D * * * * * EB * 48 8D * * * * * E8 * * * * 4C 8B * C6 * * * * * * 8B * 0F * * C1 * * 89 * * * 89 * * * 48 8B",
  "48 8D * * * * * E8 * * * * C6 * * * * * * 8B * * * * * 4C 8D * * 45 33 * 89 * * 48 8D * * C7",
  "48 8D * * * * * E8 * * * * 4C 8B * C6 * * * * * * 48 8B",
  "4C 8D 05 * * * * EB * 48 8D * * * * * E8 * * * * 4C 8B * C6 * * * * * * 8B D3 0F B7 C3 89 44 24",
  "48 8D 05 * * * * EB * 48 8D 0D * * * * E8 * * * * C6 05 * * * * * * * * 4C 8D 44 24",
  "48 8D 05 * * * * EB * 48 8D 0D * * * * E8 * * * * C6 05 * * * * * 0F 28 45 * 4C 8D 45 * 48",
  "48 8D 05 * * * * EB * 48 8D 0D * * * * E8 * * * * C6 05 * * * * * 0F 28 44 24",
  "4C 8D 05 * * * * EB * 48 8D 0D * * * * E8 * * * * 4C 8B C0 C6 05 * * * * * 8B CB 0F B7 C3 C1 E9 * 89 4C 24",
  "48 8D 05 * * * * EB * 48 8D 0D * * * * E8 * * * * C6 05 * * * * * 48 8D 54 24",
  "48 8D 05 * * * * EB * 48 8D 0D * * * * E8 * * * * C6 05 * * * * * 8B 50",
  "48 8D 1D * * * * EB * 48 8D 0D * * * * E8 * * * * 48 8B D8 C6 05 * * * * * * * * 83 FE",
  "48 8D 0D * * * * 8B FA 75 * E8 * * * * 48 8B C8",
  "48 8D 1D * * * * EB * 48 8D 0D * * * * E8 * * * * 48 8B D8 C6 05 * * * * * 83 FE",
  "C3 * DB 48 89 1D * * * * * * 48 8B 5C 24 20",
  "48 8D 0D * * * * E8 * * * * 4C 8B C0 C6",
  "48 83 EC 28 48 8B 05 * * * * 48 85 C0 75 * B9 * * 00 00 48 89 5C 24 20 E8",
  "33 F6 89 35 * * * * 8B C6 5E",
  "48 8D 05 * * * * EB * 48 8D 0D * * * * E8 * * * * C6 05 * * * * * 0F 10 07",
}

--- GUObjectArray or one of its embedded fields
-- ///---///--///---///--///---///--///--///---/// GUOBJECTARRAY SIGNATURES

Module.GObjects =
{
  "48 8D * * * * * E8 * * * * 89 * * 48 83 * * 5B C3 C7 * * * * * C7 * * * * * * 48 83 * * 5B C3",
  "48 8D * * * * * 33 * 48 89 * 48 89 * * 45 8B * 41 B9 * * * * 48 8B * 44 89",
  "3B * * * * * 7D * 8B * 99 0F * * 03 * 8B * 0F * * 2B * 48 98 C1 * * 48 63 * 48 8D",
  "8B 05 * * * * 8B * * * * * 41 0F * * 2B * 44 89",
  "48 8B 05 * * * * 48 8B 0C * 48 8D 04 * EB * 33 * 8B * * C1 * * A8 * 75 * E8",
  "48 8D * * 48 8B * * * * * 48 8B * * 48 8D * * 48 85 * 74 * 44 39 * * 75 * F7 * * * * * * 75 * B0 * C3",
  "48 8B * * * * * 48 8B * * 48 8D * * 48 85 * 74 * 44 39 * * 75 * 8B * * * * * 8B * * 0F * * * 85 * 75 * B0 * C3",
  "48 8B 05 * * * * 48 8B 0C * 48 8D 04 * EB * 33 * 8B * * C1",
  "8B * * * * * 8B * * * * * 89 * * * * * 80 * * 0F * * 2B * FF",
  "48 8B 05 * * * * * * * * * * * * EB * 4C 8B C7 8B 15 * * * * F7 D2 81 E2 * * * * 74 * 49 8B C8 E8 * * * * EB",
  "48 8B 05 * * * * * * * * * * * * EB * 45 33 C0 41 8B 40 * 0F BA E0 * 72 * 0F 1F 40 * 8B C8 0F BA E9 * F0 41 0F B1 48 * 74 * 41 8B 40 * 0F BA E0 * 73 * B0",
  "48 8B 05 * * * * * * * * * * * * EB * 45 33 C0 41 8B 40 * 0F BA E0 * 72 * 8B C8 0F BA E9 * F0 41 0F B1 48 * 74 * 41 8B 40 * 0F BA E0 * 73 * 48 8B D6",
  "48 8B 05 * * * * * * * * * * * * EB * 45 33 C0 41 8B 40 * 0F BA E0 * 72 * 0F 1F 80 * * * * 8B C8 0F BA E9",
  "4C 8B 0D * * * * 41 3B C0 7D * 8B D0 0F B7 C0 48 C1 EA * * * * * * * * * * * * * EB * 4C 8B D3",
  "48 8B 05 * * * * * * * * * * * * * * * * EB * 4C 8B C6 8B 15 * * * * F7 D2 81 E2 * * * * 74",
  "48 8B 05 * * * * * * * * * * * * EB * 49 8B C7 8B 40 * C1 E8 * A8 * 0F 85 * * * * 41 8B 40",
  "48 8B 05 * * * * * * * * * * * * EB * 4D 8B C4 41 8B 40 * 0F BA E0 * 72 * 66 0F 1F 84 00",
  "48 8B 05 * * * * * * * * * * * * EB * 48 8B C3 8B 40 * 85 05 * * * * 75 * 48 8B D7",
  "48 8B 05 * * * * 48 8B 0C * 4C 8D 04 * EB * 45 33 C0 41 8B 40 08 0F BA E0 15 72 *",
  "48 8B 05 * * * * * * * * * * * * EB * 33 C0 8B 40 * C1 E8 * A8 * 74 * 48 8B * 48",
  "48 8B 05 * * * * * * * * * * * * * * * * EB * 4D 8B C7 41 8B 40 * 74 * 41 8B 40",
  "48 8B 05 * * * * * * * * * * * * EB * 33 C0 8B 40 * 85 05 * * * * 74 * 48 8D 4D",
  "48 8B 05 * * * * * * * * * * * * EB * 4D 8B C4 41 8B 40 * 0F BA E0 * 72 * 8B C8",
  "48 8B 05 * * * * * * * * * * * * EB * 33 C0 8B 40 * 85 05 * * * * 74 * 49 8D 4F",
  "48 8B 05 * * * * * * * * * * * * EB * 33 C0 8B 40 * C1 E8 * A8 * 74 * 49 8B D0",
  "48 8B 05 * * * * * * * * * * * * EB * 48 8B C5 8B 40 * C1 E8 * A8 * 75 * C6 46",
  "48 8B 05 * * * * * * * * * * * * EB * 33 C9 BA * * * * E8 * * * * 48 8B 8C 24",
  "48 8B 05 * * * * * * * * * * * * * * * * EB * 45 33 FF 45 8B C7 41 8B 40 *",
  "48 8B 05 * * * * * * * * * * * * EB * 33 C9 BA * * * * E8 * * * * 48 8B 76",
  "48 8B 05 * * * * * * * * * * * * EB * 33 C9 BA * * * * E8 * * * * 48 63 B3",
  "48 8B 05 * * * * * * * * * * * * BA * * * * 48 83 C4 * 5B E9 * * * * 33 C9",
  "48 8B 05 * * * * * * * * * * * * EB * 49 8B C4 8B 40 * C1 E8 * A8 * 0F 85",
  "48 8B 05 * * * * * * * * * * * * EB * 4D 8B C4 8B 15 * * * * F7 D2 81 E2",
  "48 8B 05 * * * * * * * * * * * * EB * 49 8B C7 8B 40 * C1 E8 * A8 * 75",
  "48 8B 05 * * * * * * * * * * * * * * * 48 8B 74 24 * 49 8B C2 48 8B 5C",
  "48 8B 05 * * * * * * * * * * * * * * * * EB * 48 8B C6 8B 40 * 85 47",
  "48 8B 05 * * * * * * * * * * * * EB * 45 33 FF 45 8B C7 41 8B 40 *",
  "4C 8B 0D * * * * 8B D0 C1 EA * 0F B7 C8 49 8B 14 D1 48 8D 0C 49",
  "48 8B 05 * * * * * * * * * * * * EB * 4D 8B C5 41 8B 40",
  "48 8B 05 * * * * * * * * * * * * EB * 48 8B CF 41 8B D0",
  "48 8B 05 * * * * * * * * * * * * * * * * EB * 48 8B C5",
  "48 8B 05 * * * * * * * * * * * * * * * EB * 45 33 F6",
  "48 8B 05 * * * * 41 8B C9 C1 E9 10 45 0F B7 C1",
  "48 8B 05 * * * * * * * * * * * * 41 8B 47 * 85",
  "40 53 48 83 EC 20 48 8B D9 48 85 D2 74 * 8B",
  "8B 44 24 04 56 8B F1 85 C0 74 17 8B 40 08",
  "4C 8B 05 * * * * 45 3B 88",
  "8B 15 * * * * 8B 04 82 85",
  "48 8B 05 * * * * 48 8B 0C C8 4C 8D 04 D1 EB 03 4C 8B C6 41 8B 40 08 0F BA E0 1E 72",
  "44 8B * * * 48 8D 05 * * * * * * * * * 48 89 71 10",
  "40 53 48 83 EC 20 48 8B D9 48 85 D2 74 * 8B 52 * 89 11 48 8D 0D * * * * E8 * * * * 89 43 * 48 83 C4 20 5B C3 33 C0 48 89 01 48 83 C4 20 5B",
}

--- GEngine
-- ///---///--///---///--///---///--///--///---/// GENGINE SIGNATURES

Module.GEngine =
{
  "F0 * * * * 48 8B * * * * * 48 8B * * * * * 48 8B * * 48 8B * * E8 * * * * 66 * * * * * * * 4C 8B * 0F * * * * * 8B * * 4C 8D * * 44 0F * * * * * * 85 * 7E * 49 8B",
  "48 8B 0D * * * * E8 * * * * 48 85 * 74 * F3 * * * * * * * 48 83 * * C3 0F * * 48 83 * * C3",
  "48 83 * * * * * * 49 8B * 4C 8B * 48 8B * 75 * 33 * E9 * * * * 48 8B",
  "4C 8B * * * * * 48 8B * 49 8B * * * * * 49 63 * * * * * 48 8D * * 48 3B",
  "48 8B * * * * * 48 85 * 74 * F3 * * * * * * * EB * F3 * * * * * * * 0F * * F3 * * * * * * * * 66",
  "48 8B * * * * * 48 8B * E8 * * * * 84 * 75 * 48 8B * E8 * * * * 84 * 74 * F6",
  "48 8B * * * * * E8 * * * * 4C 8B * 48 85 * 0F * * * * * 4C 8B * * * * * 4D 85 * 74",
  "41 B8 01 00 00 00 * * * 48 8B 0D * * * * E8 * * * * 48 85 C0",
  "48 8B 1D * * * * 48 85 DB 74 * 48 8D",
  "56 8B 35 * * * * 85 F6 74",
}

--- GWorld
-- Patterns supplied by the project's UE offset signature collection.
-- ///---///--///---///--///---///--///--///---/// GWORLD SIGNATURES

Module.GWorld =
{
  "48 8B 1D * * * * 48 85 DB 74 * 41 B0 01",
  "48 8B 05 * * * * 4C 8D 44 24 * 48 8D 54 24 * 48 89 44 24 * 48 C7 44 24",
  "48 8B * * * * * 48 85 D2 74 * 48 8B 0D * * * * 48 85 C9 74 * E8",
  "48 39 3D * * * * 75 * 48 89 1D * * * * E8 * * * * 48 8B 97",
  "48 8B 05 * * * * 48 8B 88 * * * * 48 85 C9 74 * 4C 8B 83",
  "48 8B 05 * * * * 48 85 C0 74 * 48 8B C8 E8 * * * * 83 F8",
  "48 8B 05 * * * * 48 8D 95 * * * * 48 8B 48 * 48 89 8D",
  "48 8B 0D * * * * E8 * * * * 4C 8B F0 48 89 44 24",
  "48 8B 05 * * * * 48 8B 88 * * * * 48 8B BC 24",
  "48 8B 05 * * * * 48 85 C0 75 * 48 83 C4 * 5B",
  "48 8B 15 * * * * 48 8D 4F * 4C 0F 45 44 24",
  "48 89 3D * * * * 48 85 FF 74 * 41 83 BC 24",
  "48 8B 0D * * * * 48 85 C9 74 * * * * 33 C0",
  "48 8B 05 * * * * 4C 8B C3 * * * 48 39 81",
  "48 8B 0D * * * * 48 85 C9 74 * 48 8D 93",
  "48 8B 05 * * * * EB * 48 8B CF FF D2",
  "48 8B 15 * * * * 48 8D 4F * 4C 8B C8",
  "48 8B 0D * * * * 48 8B D8 48 8B 51",
  "48 8B 0D * * * * 48 8B D8 48 8B 91",
  "48 85 C0 75 * 48 8B 05 * * * * C3",
  "48 8B 3D * * * * 48 8B 5C 24",
  "48 89 05 * * * * 49 8B 74 24",
  "48 8B 15 * * * * 49 8D 4C 24",
  "48 89 05 * * * * 0F 28 D6",
  "48 89 0D * * * * 48 85 F6",
  "48 89 15 * * * * 8B DA",
  "4D 85 ED 4C 0F 44 2D",
  "0F 57 C9 0F 2E C1 74 * 48 8B 1D",
  "41 B0 * 33 D2 48 8B CB E8 * * * * F3 0F 10 05 * * * * 0F 2E 80",
  "F3 0F 10 05 * * * * 0F 57 C9 0F 2E C1",
}

--- UE4SS-derived sigs for FName::ToString(FString&) const
-- callOffset resolves the function through the relative CALL at that byte offset; entries w/o it point at the function
-- ///---///--///---///--///---///--///--///---/// FNAME CONVERSION SIGNATURES

Module.FNameToString =
{
  {
    pattern = "C3 33 C0 48 8D 54 24 20 48 8B CF 48 89 44 24 20 48 89 44 24 28 E8 * * * *",
    callOffset = 0x15,
  },
  {
    pattern = "48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 57 48 83 EC 20 48 8B DA 48 8B F1 E8 * * * * 44 8B 46 04",
  },
  {
    pattern = "48 89 5C 24 10 48 89 6C 24 18 48 89 74 24 20 57 48 83 EC 20 8B 01",
  },
  {
    -- Kingdom Hearts 3 UE4SS override
    pattern = "48 89 5C 24 08 48 89 7C 24 18 41 56 48 83 EC 20 48 8B DA 4C 8B F1 * * * * * 4C 8B C8 41 8B 06 99",
  },
}

-- ///---///--///---///--///---///--///--///---///--///---///--///---///--///--///--/// PROCESS EVENT SIGNATURES

--- UObject::ProcessEvent prologue
Module.ProcessEvent =
{
  "40 * 56 57 41 54 41 55 41 56 41 57 48 81 * * * * * 48 8D * * * 48 89 * * * * * 48 8B * * * * * 48 33 * 48 89 * * * * * 4C 8B * 45 33 * 8B",
  "40 * 56 57 41 54 41 55 41 56 41 57 48 81 * * * * * 48 8D * * * 48 89 * * * * * 48 8B * * * * * 48 33 * 48 89 * * * * * 8B * * 45 33 * 3B",
  "40 * 56 57 41 54 41 55 41 56 41 57 48 81 * * * * * 48 8D * * * 48 89 * * * * * 48 8B * * * * * 48 33 * 48 89 * * * * * 4D 8B",
  "40 * 56 57 41 54 41 55 41 56 41 57 48 81 * * * * * 48 8D * * * 48 89 * * * * * 48 8B * * * * * 48 33 * 48 89 * * * * * 8B * * 4D 8B",
  "40 * 56 57 41 54 41 55 41 56 41 57 48 81 * * * * * 48 8D * * * 48 C7 * * * * * * 48 89 * * * * * 48 8B * * * * * 48 33 * 48 89 * * * * * 4D 8B * 48 8B * 4C 8B",
  "40 * 56 57 41 54 41 55 41 56 41 57 48 81 * * * * * 48 8D * * * 48 89 * * * * * 48 8B * * * * * 48 33 * 48 89 * * * * * 44 8B * * 45 33 * 44 8B * * * * * 4D 8B",
  "40 * 56 57 41 54 41 55 41 56 41 57 48 81 * * * * * 48 8D * * * 48 89 * * * * * 48 8B * * * * * 48 33 * 48 89 * * * * * 48 63 * * 45 33",
  "55 56 57 41 54 41 55 41 56 41 57 48 81 * * * * * 48 8D * * * 48 89 * * * * * 48 8B * * * * * 48 31 * 48 89 * * * * * 8B * * 45 31 * 01 * 4D 89 * D1 * 48 89",
  "40 * 56 57 41 54 41 55 41 56 41 57 48 81 * * * * * 48 8D * * * 48 89 * * * * * 48 8B * * * * * 48 33 * 48 89 * * * * * 8B * * 48 8D",
  "40 * 56 57 41 54 41 55 41 56 41 57 48 81 * * * * * 48 8D * * * 48 89 * * * * * 48 8B * * * * * 48 33 * 48 89 * * * * * 48 89 * * 4D 8B",
  "40 * 56 57 41 56 41 57 48 81 * * * * * 48 8D * * * 48 89 * * * * * 48 8B * * * * * 48 33",
}

--- AActor::ProcessEvent fallbacks
Module.ActorProcessEvent =
{
  "48 89 * * * 48 89 * * * 48 89 * * * 57 48 83 * * 48 8B * 49 8B * 0F * * * * * * 48 8B * 48 8B * FF * * * * * 48 85",
  "48 89 * * * 48 89 * * * 57 48 83 * * F7 * * * * * * * * * 49 8B * 48 8B * 48 8B * 75 * 83 * * * 74 * 48 8B",
  "48 89 * * * 48 89 * * * 48 89 * * * 57 48 83 * * F7 * * * * * * * * * 49 8B * 48 8B * 48 8B * 75 * 83 * * * 74 * 48 89",
  "48 89 * * * 48 89 * * * 48 89 * * * 57 48 83 * * F7 * * * * * * * * * 49 8B * 48 8B * 48 8B * 75 * 83 * * * * * * 74",
  "48 8B * 48 89 * * 48 89 * * 48 89 * * 48 89 * * 41 56 48 83 * * 45 33 * 49 8B * F7",
  "48 8B * 48 81 * * * * * 80 * * * * * * 48 89 * * 48 8B * 48 89 * * 48 89 * * 48 8B",
}

-- ///---///--///---///--///---///--///--///---/// EXPORT

return Module
