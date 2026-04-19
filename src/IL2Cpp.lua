-- [[ 
       This script is from Apex, i just changed it a lil bit.
       ok
-- ]]

local IL2Cpp = {}
IL2Cpp.__index = IL2Cpp

local _is64 = false
local _libBase = nil
local _methods = {}
local _backups = {}
local _classBackup = {}
local _fastBackup = {}
local _methodCount = 0
local _xtrue, _xfalse, _xEND

local function Pointer(address)
    local flag = _is64 and gg.TYPE_QWORD or gg.TYPE_DWORD
    return gg.getValues({{address = address, flags = flag}})[1].value
end

local function CString(address, str)
    local bytes = gg.bytes(str)
    for i = 1, #bytes do
        local v = gg.getValues({{address = address + i - 1, flags = gg.TYPE_BYTE}})[1].value
        if v & 0xFF ~= bytes[i] then return false end
    end
    return gg.getValues({{address = address + #bytes, flags = gg.TYPE_BYTE}})[1].value == 0
end

local function GetIl2Cpp()
    local valid = {}
    for _, v in ipairs(gg.getRangesList("libil2cpp.so")) do
        if v.state == "Xa" then table.insert(valid, v) end
    end

    if #valid == 1 then return valid[1].start end

    if #valid >= 2 then
        for _, lib in ipairs(valid) do
            local size = (lib["end"] - lib.start) / 1048576
            if size > 10 and size < 100 then return lib.start end
        end
        return valid[#valid].start
    end

    local allRanges = gg.getRangesList()
    local splits = {}
    for _, v in ipairs(allRanges) do
        if v.state == "Xa" and string.match(v.name, "split_config.*%.so") then
            table.insert(splits, {start = v.start, size = v["end"] - v.start})
        end
    end
    if #splits > 0 then
        local max = splits[1]
        for _, s in ipairs(splits) do
            if s.size > max.size then max = s end
        end
        return max.start
    end

    local largest = nil
    local largestSize = 0
    for _, v in ipairs(allRanges) do
        if v.state == "Xa" then
            local size = v["end"] - v.start
            if size > largestSize then
                largestSize = size
                largest = v.start
            end
        end
    end

    return largest
end

local function DeepSearch(class, method)
    local result = {}
    local pSize = _is64 and 0x8 or 0x4

    gg.clearResults()
    gg.setRanges(gg.REGION_C_ALLOC | gg.REGION_ANONYMOUS | gg.REGION_OTHER)
    gg.searchNumber(string.format("Q 00 '%s' 00", method), gg.TYPE_BYTE)

    local count = gg.getResultsCount()
    if count > 0 then
        gg.refineNumber(method:byte(), gg.TYPE_BYTE)
        local t = gg.getResults(count)
        gg.searchPointer(0)
        t = gg.getResults(count)
        for _, v in ipairs(t) do
            if CString(Pointer(Pointer(v.address + pSize) + pSize * 2), class) then
                table.insert(result, Pointer(v.address - pSize * 2))
            end
        end
        gg.clearResults()
    end

    return result
end

function IL2Cpp:Attach()
    local info = gg.getTargetInfo()
    if not info then
        gg.toast("No process selected")
        return false
    end

    _is64 = info.x64
    _G.processInfo = info

    if _is64 then
        _xtrue  = "h200080D2"
        _xfalse = "h000080D2"
        _xEND   = "hC0035FD6"
    else
        _xtrue  = "h0100A0E3"
        _xfalse = "h0000A0E3"
        _xEND   = "h1EFF2FE1"
    end

    _libBase = GetIl2Cpp()
    if not _libBase then
        gg.toast("No lib found!")
        return false
    end

    _G.xAPEXx = {_libBase}
    _methods = {}
    _backups = {}
    _classBackup = {}
    _fastBackup = {}
    _methodCount = 0

    return true
end

function IL2Cpp:SearchMethod(class, method)
    _methodCount = _methodCount + 1
    local id = _methodCount

    local pct = math.floor((id * 100) / math.max(_methodCount, 1))
    gg.toast(string.format("Loading [ %d%% ]", pct))

    local addrs = DeepSearch(class, method)
    if #addrs > 0 then
        local offset = addrs[1] - _libBase
        if offset > 0 and offset < 0xA000000 then
            _methods[id] = {class = class, method = method, offset = offset, ok = true}
            return id
        end
    end

    _methods[id] = {class = class, method = method, offset = nil, ok = false}
    gg.toast(string.format("%s::%s not found", class, method))
    return id
end

function IL2Cpp:ResolveAll(list)
    local total = #list
    for i, entry in ipairs(list) do
        gg.toast(string.format("Loading [ %d%% ]", math.floor(i * 100 / total)))
        _methodCount = _methodCount + 1
        local id = _methodCount
        local addrs = DeepSearch(entry[1], entry[2])
        if #addrs > 0 then
            local offset = addrs[1] - _libBase
            if offset > 0 and offset < 0xA000000 then
                _methods[id] = {class = entry[1], method = entry[2], offset = offset, ok = true}
            else
                _methods[id] = {class = entry[1], method = entry[2], offset = nil, ok = false}
            end
        else
            _methods[id] = {class = entry[1], method = entry[2], offset = nil, ok = false}
        end
    end
end

function IL2Cpp:Save(id)
    local m = _methods[id]
    if not m or not m.ok then return end
    local vals = {}
    local k = 1
    for _, base in ipairs(_G.xAPEXx) do
        for i = 0, 16, 4 do
            vals[k] = {address = base + m.offset + i, flags = 4}
            k = k + 1
        end
    end
    _backups[id] = gg.getValues(vals)
end

function IL2Cpp:Revert(id)
    if id then
        local b = _backups[id]
        if not b then gg.toast("Nothing to revert!"); return end
        local list = {}
        local k = 1
        local m = _methods[id]
        for _, base in ipairs(_G.xAPEXx) do
            for i = 0, 16, 4 do
                local addr = base + m.offset + i
                for _, orig in ipairs(b) do
                    if orig.address == addr then
                        list[k] = {address = orig.address, flags = 4, value = orig.value}
                        k = k + 1
                        break
                    end
                end
            end
        end
        if #list > 0 then gg.setValues(list) end
    else
        for i, b in pairs(_backups) do
            self:Revert(i)
        end
    end
end

function IL2Cpp:Patch(id, value)
    local m = _methods[id]
    if not m or not m.ok then
        gg.toast("Method not available!")
        return
    end
    local offset = m.offset
    for _, base in ipairs(_G.xAPEXx) do
        local xdump = {}
        if type(value) ~= "table" then
            xdump[1] = {address = base + offset, flags = 4}
            if value == false or value == 0 then
                xdump[1].value = _xfalse
            elseif value == true or value == 1 then
                xdump[1].value = _xtrue
            else
                xdump[1].value = tostring(value)
            end
            xdump[2] = {address = base + offset + 4, flags = 4, value = _xEND}
        else
            local cc = 0
            for c = 1, #value do
                xdump[c] = {address = base + offset + cc, flags = 4, value = tostring(value[c])}
                cc = cc + 4
            end
        end
        gg.setValues(xdump)
    end
end

function IL2Cpp:FindClass(className, offset, typeFlag)
    gg.toast("Please Wait..")
    gg.clearResults()
    gg.setRanges(gg.REGION_OTHER | gg.REGION_C_ALLOC | gg.REGION_ANONYMOUS)
    gg.searchNumber(":" .. className, 1)
    if gg.getResultsCount() == 0 then return false end

    local u = gg.getResults(1)
    gg.getResults(gg.getResultsCount())
    gg.refineNumber(tonumber(u[1].value), 1)
    u = gg.getResults(gg.getResultsCount())
    gg.clearResults()

    for i = 1, #u do u[i].address = u[i].address - 1; u[i].flags = 1 end
    u = gg.getValues(u)

    local nulls = {}
    local k = 1
    for i = 1, #u do
        if u[i].value == 0 then nulls[k] = {address = u[i].address, flags = 1}; k = k + 1 end
    end
    if #nulls == 0 then gg.clearResults(); return false end

    for i = 1, #nulls do nulls[i].address = nulls[i].address + #className + 1; nulls[i].flags = 1 end
    nulls = gg.getValues(nulls)

    local starts = {}
    k = 1
    for i = 1, #nulls do
        if nulls[i].value == 0 then starts[k] = {address = nulls[i].address, flags = 1}; k = k + 1 end
    end
    if #starts == 0 then gg.clearResults(); return false end

    for i = 1, #starts do starts[i].address = starts[i].address - #className; starts[i].flags = 1 end
    gg.loadResults(starts)
    gg.searchPointer(0)
    if gg.getResultsCount() == 0 then return false end

    local Pointers = gg.getResults(gg.getResultsCount())
    gg.clearResults()

    local o1, o2, vt
    if _is64 then o1=48; o2=56; vt=32 else o1=24; o2=28; vt=4 end

    local candidates = {}
    local retry = false

    ::RETRY::
    local py, pz = {}, {}
    for i = 1, #Pointers do
        py[i] = {address = Pointers[i].address + o1, flags = vt}
        pz[i] = {address = Pointers[i].address + o2, flags = vt}
    end
    py = gg.getValues(py)
    pz = gg.getValues(pz)

    candidates = {}; k = 1
    for i = 1, #py do
        if py[i].value == pz[i].value and #tostring(py[i].value) >= 8 then
            candidates[k] = py[i].value; k = k + 1
        end
    end

    if #candidates == 0 and not retry then
        if _is64 then o1=32; o2=40 else o1=16; o2=20 end
        retry = true
        goto RETRY
    end
    if #candidates == 0 then gg.clearResults(); return false end

    gg.setRanges(gg.REGION_ANONYMOUS)
    gg.clearResults()

    local loaded = 0
    for i = 1, #candidates do
        gg.searchNumber(tonumber(candidates[i]), vt)
        if gg.getResultsCount() ~= 0 then
            local r = gg.getResults(gg.getResultsCount())
            gg.clearResults()
            for j = 1, #r do r[j].name = "_IL2CPP_" end
            gg.addListItems(r)
            loaded = loaded + 1
        end
        gg.clearResults()
    end

    if loaded == 0 then gg.clearResults(); return false end

    local items = gg.getListItems()
    local toLoad, toRemove = {}, {}
    k = 1
    for i = 1, #items do
        if items[i].name == "_IL2CPP_" then
            toLoad[k] = {address = items[i].address + offset, flags = typeFlag}
            toRemove[k] = items[i]
            k = k + 1
        end
    end

    toLoad = gg.getValues(toLoad)
    gg.loadResults(toLoad)
    gg.removeListItems(toRemove)
    return true
end

function IL2Cpp:SaveClass(...)
    local offsets = {...}
    local base = gg.getResults(99999)
    for i = 1, #base do table.insert(_classBackup, base[i]) end
    if #offsets > 0 then
        local extra = {}
        for _, off in ipairs(offsets) do
            for i = 1, #base do
                table.insert(extra, {address = base[i].address + off, flags = 4})
            end
        end
        local ev = gg.getValues(extra)
        for i = 1, #ev do table.insert(_classBackup, ev[i]) end
    end
end

function IL2Cpp:RevertClass()
    if #_classBackup > 0 then
        gg.setValues(_classBackup)
        _classBackup = {}
    end
end

function IL2Cpp:FindValue(pattern, typeFlag)
    gg.clearResults()
    gg.searchNumber(pattern[1], typeFlag)
    if gg.getResultsCount() == 0 then return {} end

    for i = 2, #pattern do
        local relOffset = pattern[i][2]
        local refineVal = pattern[i][1]
        local r = gg.getResults(gg.getResultsCount())
        gg.clearResults()
        local shifted = {}
        for j = 1, #r do shifted[j] = {address = r[j].address + relOffset, flags = typeFlag} end
        gg.loadResults(shifted)
        gg.refineNumber(refineVal, typeFlag)
        if gg.getResultsCount() == 0 then return {} end
        r = gg.getResults(gg.getResultsCount())
        gg.clearResults()
        local unshifted = {}
        for j = 1, #r do unshifted[j] = {address = r[j].address - relOffset, flags = typeFlag} end
        gg.loadResults(unshifted)
    end

    return gg.getResults(gg.getResultsCount())
end

function IL2Cpp:EditValue(results, relOffset, typeFlag, newValue)
    local targets = {}
    for i = 1, #results do
        targets[i] = {address = results[i].address + relOffset, flags = typeFlag}
    end
    gg.loadResults(targets)
    gg.editAll(tostring(newValue), typeFlag)
end

function IL2Cpp:SaveFast(tag, results, relOffset, typeFlag)
    local targets = {}
    for i = 1, #results do
        targets[i] = {address = results[i].address + relOffset, flags = typeFlag}
    end
    _fastBackup[tag] = gg.getValues(targets)
end

function IL2Cpp:RevertFast(tag)
    local saved = _fastBackup[tag]
    if saved and #saved > 0 then
        gg.setValues(saved)
        _fastBackup[tag] = nil
    end
end

function IL2Cpp:Refine(value, typeFlag)
    gg.refineNumber(value, typeFlag)
end

function IL2Cpp:Edit(value, typeFlag)
    gg.getResults(gg.getResultsCount())
    gg.editAll(tostring(value), typeFlag)
end

function IL2Cpp:Shift(offset, typeFlag)
    offset = tonumber(offset)
    local r = gg.getResults(gg.getResultsCount())
    for i = 1, #r do r[i].address = r[i].address + offset; r[i].flags = typeFlag end
    gg.loadResults(r)
end

function IL2Cpp:Clear()
    gg.getResults(gg.getResultsCount())
    gg.clearResults()
end

function IL2Cpp:GetMethod(id)
    return _methods[id]
end

function IL2Cpp:Is64()
    return _is64
end

function IL2Cpp:LibBase()
    return _libBase
end

return IL2Cpp
