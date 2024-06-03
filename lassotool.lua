label = "Lasso Select"
about = [[
Implementation of a Lasso Selection Tool

By Marian Braendle
]]

---Settings
local LASSO_COLOR = { 1.0, 0, 1.0 }
local LASSO_FIDELITY = 1
local POLYLINE_FIDELITY = 1

-- shortcuts.ipelet_1_lassotool = "Ctrl+Shift+D"

---Global constants/functions
_, _, MAJOR, MINOR, PATCH = string.find(config.version, "(%d+).(%d+).(%d+)")
IPELIB_VERSION = 10000*MAJOR + 100*MINOR + PATCH
V = ipe.Vector
R = ipe.Rect
M = ipe.Matrix
S = ipe.Segment
B = ipe.Bezier
EYE = M()

local SELECT_TYPE = { notSelected = nil, primarySelected = 1, secondarySelected = 2 }

------------------ Helper Functions ------------------
---Ramer-Douglas-Peucker algorithm (https://en.wikipedia.org/wiki/Ramer%E2%80%93Douglas%E2%80%93Peucker_algorithm)
local function rpd(points, iStart, iEnd, epsilon)
    local dMax, iMax = 0, 0
    for i = iStart, iEnd - 1 do
        local d = S(points[iStart], points[iEnd]):distance(points[i])
        if d > dMax then dMax, iMax = d, i end
    end
    if dMax > epsilon then
        local res1, res2 = rpd(points, iStart, iMax, epsilon), rpd(points, iMax, iEnd, epsilon)
        res1[#res1] = nil
        for i = 1, #res2 do
            res1[#res1 + 1] = res2[i]
        end
        return res1
    end
    return { points[iStart], points[iEnd] }
end

local function simplifyPolyLine(path, model)
    -- Only works for paths with line segments only!
    local points = {}
    for _, seg in ipairs(path) do points[#points + 1] = seg[1] end
    points[#points + 1] = path[#path][2] -- add last point

    local poinsOpt = rpd(points, 1, #points, POLYLINE_FIDELITY / model.ui:zoom())
    local newPath = { type = "curve", closed = true }
    for i = 2, #poinsOpt do
        newPath[#newPath + 1] = { type = "segment", poinsOpt[i - 1], poinsOpt[i] }
    end
    return newPath
end

--------------------- Lasso Tool ---------------------
LASSOTOOL = {}
LASSOTOOL.__index = LASSOTOOL

function LASSOTOOL:new(model)
    local tool = {}
    _G.setmetatable(tool, LASSOTOOL)
    tool.model = model
    tool.page = model:page()
    model.ui:shapeTool(tool)
    tool.setColor(table.unpack(LASSO_COLOR))

    tool.path = { type = "curve", closed = true }
    tool.nonDestructive= true

    return tool
end

function LASSOTOOL:finish()
    self.model.ui:finishTool()
end

function LASSOTOOL:mouseButton(button, modifiers, press)
    self.drawing = false
    if button == 1 then
        if press then
            self.lastP = self.model.ui:unsnappedPos()
            self.nonDestructive = modifiers.shift
            self.drawing = true
        else
            if #self.path > 1 then
                -- Explicitly add closing segment needed for ray casting
                local firstP, lastP = self.path[1][1], self.path[#self.path][2]
                self.path[#self.path + 1] = { type = "segment", lastP, firstP }

                -- self.model:creation("Original Lasso Path", ipe.Path(self.model.attributes, {self.path}))
                self.path = simplifyPolyLine(self.path, self.model)
                -- self.model:creation("Simplified Lasso Path", ipe.Path(self.model.attributes, {self.path}))

                self:applySelection()

                self:finish()
            end
            return
        end
    else -- Abort if any other button is pressed
        self:finish()
        return
    end
end

function LASSOTOOL:mouseMove()
    if self.drawing then
        local p = self.model.ui:unsnappedPos()
        if (p - self.lastP):len() * self.model.ui:zoom() > LASSO_FIDELITY then
            self.path[#self.path + 1] = { type = "segment", self.lastP, p }
            self.setShape({ self.path })
            self.model.ui:update(false) -- Update tool
            self.lastP = p
        end
    end
end

function LASSOTOOL:key(text, modifiers)
    if text == "\027" then -- Esc
        self:finish()
        return true
    else -- Not consumed
        return false
    end
end

function LASSOTOOL:containsPoint(p)
    -- Simple ray casting (O(#path_edges))
    local count = 0
    for _, e in ipairs(self.path) do
        if (p.y < e[1].y) ~= (p.y < e[2].y) and p.x < e[1].x + ((p.y - e[1].y) / (e[2].y - e[1].y)) * (e[2].x - e[1].x) then
            count = count + 1
        end
    end
    return count % 2 == 1
end

function LASSOTOOL:containsShape(shape)
    -- "brute force" line intersection + single point detection (O(#segments x #path_edges))
    for _, path in ipairs(shape) do
        if path.type == "curve" then
            if path.closed then -- Add closing segment
                local pStart, pEnd = path[1][1], path[#path][#path[#path]]
                path[#path + 1] = { type = "segment", pEnd, pStart }
            end
            for _, subpath in ipairs(path) do
                if subpath.type == "segment" then
                    for _, e in ipairs(self.path) do
                        if S(e[1], e[2]):intersects(S(subpath[1], subpath[2])) then
                            return false
                        end
                    end
                elseif subpath.type == "spline" or subpath.type == "oldspline" or subpath.type == "cardinal" or subpath.type == "spiro" then
                    local beziers = ipe.splineToBeziers(subpath, false)
                    for _, ctrls in ipairs(beziers) do
                        local bez = B(table.unpack(ctrls))
                        for _, e in ipairs(self.path) do
                            if #bez:intersect(S(e[1], e[2])) > 0 then
                                return false
                            end
                        end
                    end
                elseif subpath.type == "arc" then
                    for _, e in ipairs(self.path) do
                        if #subpath.arc:intersect(S(e[1], e[2])) > 0 then
                            return false
                        end
                    end
                else
                    print("[ERROR] Unsupported subpath type: ", subpath.type)
                end
            end
            return self:containsPoint(path[1][1]) -- At least one point has to lie inside (path[1][1] is a valid point for segments, splines & arcs)
        elseif path.type == "closedspline" then
            local beziers = ipe.splineToBeziers(path, true)
            for _, ctrls in ipairs(beziers) do
                local bez = B(table.unpack(ctrls))
                for _, e in ipairs(self.path) do
                    if #bez:intersect(S(e[1], e[2])) > 0 then
                        return false
                    end
                end
            end
            return self:containsPoint(beziers[1][1]) -- At least one point (not control point!) has to lie inside
        elseif path.type == "ellipse" then
            local arc = ipe.Arc(path[1])
            for _, e in ipairs(self.path) do
                if #arc:intersect(S(e[1], e[2])) > 0 then
                    return false
                end
            end
            return self:containsPoint(path[1]:translation()) -- Mid point has to be inside
        else
            print("[ERROR] Unsupported path type: " .. path.type)
        end
    end
    return true
end

---Calculate corrected matrix respecting the transformation type
local function correctedObjectMatrix(obj, m)
    -- This correction is important for objects that have been transformed but whose transformation
    -- types are not "affine", for example a rotated object with "translations" type or a "rigid" object
    -- with applied non-uniform scaling
    local trafoType = obj:get("transformations")
    if trafoType == "translations" then
        return ipe.Translation(m:translation())
    elseif trafoType == "rigid" then
        local el = m:elements()
        return ipe.Translation(m:translation()) * ipe.Rotation(V(el[1], el[2]):angle())
    else -- "affine"
        return m
    end
end

function LASSOTOOL:containsObjectExact(obj, m)
    local objType = obj:type()
    if objType == "path" then
        local shape = obj:shape()
        _G.transformShape(correctedObjectMatrix(obj, m * obj:matrix()), shape)
        return self:containsShape(shape)
    elseif objType == "reference" then
        return self:containsPoint(m * obj:matrix() * obj:position())
    elseif objType == "group" then
        -- Recursively check objects inside group (and pass along the applied transformation matrix)
        for _, el in ipairs(obj:elements()) do
            if not self:containsObjectExact(el, correctedObjectMatrix(obj, m * obj:matrix())) then
                return false -- As soon as one element is outside the polygon, the group cannot be completely inside
            end
        end
        return true
    elseif objType == "text" then
        -- Construct outline of a text object by taking into account vertical & horizontal alignment
        local width, height, depth = obj:dimensions()
        local totalHeight = height + depth
        local vAlign, hAlign = obj:get("verticalalignment"), obj:get("horizontalalignment")
        local hOffset = { left = 0, right = width, hcenter = 0.5 * width }
        local vOffset = { top = totalHeight, bottom = 0, vcenter = 0.5 * totalHeight, baseline = depth }
        local pos = ipe.Vector(-hOffset[hAlign], -vOffset[vAlign])
        local shape = { {
            type = "curve", closed = true,
            { type = "segment", pos,                                  pos + ipe.Vector(width, 0) },
            { type = "segment", pos + ipe.Vector(width, 0),           pos + ipe.Vector(width, totalHeight) },
            { type = "segment", pos + ipe.Vector(width, totalHeight), pos + ipe.Vector(0, totalHeight) }
        } }
        local trafo = correctedObjectMatrix(obj, m * obj:matrix() * ipe.Translation(obj:position()))
        _G.transformShape(trafo, shape)
        return self:containsShape(shape)
    elseif objType == "image" then
        -- Get bbox of untransformed image & apply forward transform again
        local mImage = obj:matrix()
        local bbox = R()
        obj:addToBBox(bbox, mImage:inverse())
        local bottomLeft, topRight = bbox:bottomLeft(), bbox:topRight()
        local shape = { {
            type = "curve", closed = true,
            { type = "segment", bottomLeft,                  V(topRight.x, bottomLeft.y) },
            { type = "segment", V(topRight.x, bottomLeft.y), topRight },
            { type = "segment", topRight,                    V(bottomLeft.x, topRight.y) }
        } }
        _G.transformShape(correctedObjectMatrix(obj, m * mImage), shape)
        return self:containsShape(shape)
    else
        print("[ERROR] unsupported type " .. objType)
    end
end

function LASSOTOOL:applySelection()
    local lassoBbox = R()
    for _, seg in ipairs(self.path) do
        lassoBbox:add(seg[2])
    end

    -- Here, we mimic the behavior of the SelectTool (see ipetool.cpp)
    local newPrim = nil
    if not self.nonDestructive then self.page:deselectAll() end
    for i, obj, sel, layer in self.page:objects() do
        -- Object is in view and not in a locked layer
        if self.page:visible(self.model.vno, i) and not self.page:isLocked(layer) then
            local objBbox = R()
            obj:addToBBox(objBbox, EYE)
            -- For optimization, ignore objects whose bbox is not completely within the bbox of the lasso tool
            -- Unfortunately, correct behavior of bounding boxes is only guaranteed from version 7.2.29 onward (see https://github.com/otfried/ipe/issues/493)
            if IPELIB_VERSION < 70229 or lassoBbox:contains(objBbox) then
                if self:containsObjectExact(obj, EYE) then
                    if sel then
                        self.page:setSelect(i, SELECT_TYPE.notSelected)
                    else
                        self.page:setSelect(i, SELECT_TYPE.secondarySelected)
                        newPrim = i
                    end
                end
            end
        end
    end
    if newPrim ~= nil then
        local oldPrim = self.page:primarySelection()
        if oldPrim ~= nil then
            self.page:setSelect(oldPrim, SELECT_TYPE.secondarySelected)
        end
        self.page:setSelect(newPrim, SELECT_TYPE.primarySelected)
    else
        self.page:ensurePrimarySelection()
    end
end

------------------------------------------------------
function run(model)
    LASSOTOOL:new(model)
end
