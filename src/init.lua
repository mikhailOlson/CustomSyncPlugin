--[[
================================================================================================
                             CUSTOM SYNC WORKER PLUGIN
================================================================================================

This plugin facilitates synchronization between Roblox Studio and Firebase by sending data 
model hierarchies and real-time changes. The full hierarchy from all game children 
(including Workspace, Lighting, ServerScriptService, ReplicatedStorage, etc.) is serialized
for changes, ensuring the CustomSyncServer can generate clean .rbxmx files for Rojo sync.

================================================================================================
                                 TABLE OF CONTENTS
================================================================================================

1. SERVICES AND IMPORTS
   - Game Services
   - Plugin Reference
   - Environment Checks

2. CONFIGURATION AND CONSTANTS
   - Firebase Configuration
   - Sync Settings
   - Throttling Configuration
   - Event Deduplication
   - Service Lists

3. CATEGORY DEFINITIONS
   - Category Order
   - Sync Settings Structure
   - Class Filter Lookup

4. UTILITY FUNCTIONS
   - Safe Service Getter
   - Debug Print Function

5. FILTERING FUNCTIONS
   - shouldSyncInstance

6. UI FUNCTIONS
   - Toolbar Initialization
   - Settings UI Creation
   - Settings UI Toggle

7. SERIALIZATION FUNCTIONS
   - Property Serialization
   - Attribute Serialization
   - Lightweight Serialization
   - Full Instance Serialization
   - Full Hierarchy Serialization
   - Simple DataModel Serialization

8. FIREBASE FUNCTIONS
   - Connection Testing
   - Change Sending
   - DataModel Updates
   - Recent Changes Fetching
   - Setup Guidance
   - Change Application

9. EVENT HANDLING
   - Change Detection
   - Batch Processing
   - Event Listeners Setup
   - Deduplication Cleanup

10. MAIN INITIALIZATION
    - Firebase Connection Test
    - Toolbar Setup
    - Event Listeners
    - Initial Sync

11. STATUS OUTPUT
    - Final Status Display

================================================================================================
]]

print("TEST: Custom Sync Worker plugin script loaded. If you see this, the plugin script is running.")

-- ================================================================================================
-- 1. SERVICES AND IMPORTS
-- ================================================================================================

-- Game Services
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local Workspace = game:GetService("Workspace")

-- Plugin Reference
local plugin = script.Parent

-- Environment Checks
if not RunService:IsEdit() then
    print("Custom Sync Worker plugin only runs in Roblox Studio edit mode. Exiting.")
    return
end

print("Hello world, from Custom Sync Worker plugin! Plugin initialization started.")

-- ================================================================================================
-- 2. CONFIGURATION AND CONSTANTS
-- ================================================================================================

-- Firebase Configuration
local FIREBASE_BASE_URL = "https://customsyncworker-default-rtdb.firebaseio.com"
local PROJECT_ID = "default"
local DATAMODEL_URL = FIREBASE_BASE_URL .. "/projects/" .. PROJECT_ID .. "/datamodel.json"

-- Sync Settings
local SYNC_ENABLED = true
local DEBUG_MODE = false
local MAX_SERIALIZE_DEPTH = 50  -- Prevent stack overflow in deep hierarchies

-- Throttling Configuration
local BATCH_INTERVAL = 10         -- Seconds to batch changes before sending
local CHANGE_SETTLE_TIME = 2      -- Wait 2 seconds after last change before considering it "settled"
local MIN_SYNC_INTERVAL = 5       -- Minimum 5 seconds between Firebase pushes
local MAX_BATCH_SIZE = 50         -- Maximum changes per batch to avoid huge payloads

-- Event Deduplication Configuration
local EVENT_DEDUP_TIME = 0.1      -- 100ms deduplication window

-- State Variables
local pending_changes = {}        -- Dictionary keyed by instance path to store latest change state
local change_timestamps = {}      -- Track when each instance was last modified
local recentEvents = {}           -- Cache for recent events to prevent duplicates
local lastSyncTime = 0
local last_firebase_push = 0

-- List of Roblox services to sync
local RELEVANT_SERVICES = {
    "Workspace",
    "Players",
    "Lighting", 
    "MaterialService",
    "ReplicatedStorage",
    "ReplicatedFirst",
    "ServerScriptService",
    "ServerStorage",
    "StarterGui",
    "StarterPack",
    "StarterPlayer",
    "Teams",
    "SoundService",
    "TextChatService"
}

-- ================================================================================================
-- 3. CATEGORY DEFINITIONS
-- ================================================================================================

-- Category display order
local CATEGORY_ORDER = {"Abstract", "Scripts", "Values", "UI", "Lighting", "Geometry", "Physics", "Misc"}

-- Sync Settings Structure with ClassName Filters
local SYNC_SETTINGS = {
    Abstract = {
        Enabled = true,
        Classes = {
            "Part", "BasePart", "WedgePart", "CornerWedgePart",
            "TrussPart", "MeshPart", "UnionOperation", "NegateOperation",
            "IntersectOperation", "PartOperation", "VehicleSeat", "Seat",
            "SpawnLocation", "Platform", "SkateboardPlatform",
            "FlagStand", "Terrain", "TerrainRegion",
            "Model", "Folder", "WorldModel", "Actor",
            "SpecialMesh", "BlockMesh", "CylinderMesh", "FileMesh",
            "Decal", "Texture", "SurfaceAppearance", "BillboardGui", "SurfaceGui"
        }
    },
    Scripts = {
        Enabled = true,
        Classes = {
            "Script", "LocalScript", "ModuleScript", 
            "CoreScript", "StarterPlayerScripts", "StarterCharacterScripts",
            "PlayerScripts", "CharacterScripts", "Folder",
            "RemoteEvent", "RemoteFunction", "BindableEvent", "BindableFunction"
        }
    },
    Values = {
        Enabled = true,
        Classes = {
            "IntValue", "NumberValue", "BoolValue", "StringValue",
            "ObjectValue", "Vector3Value", "CFrameValue", "Color3Value",
            "RayValue", "BrickColorValue", "DoubleConstrainedValue", "Color3Value", "Folder"
        }
    },
    UI = {
        Enabled = true,
        Classes = {
            "ScreenGui", "BillboardGui", "SurfaceGui", "GuiMain",
            "Frame", "ScrollingFrame", "CanvasGroup",
            "TextLabel", "TextButton", "TextBox",
            "ImageLabel", "ImageButton", "VideoFrame",
            "ViewportFrame", "UIListLayout", "UIGridLayout", 
            "UITableLayout", "UIPageLayout", "UIPadding",
            "UIScale", "UISizeConstraint", "UITextSizeConstraint",
            "UIAspectRatioConstraint", "UICorner", "UIGradient",
            "UIStroke", "UIFlexItem", "Folder"
        }
    },
    Lighting = {
        Enabled = true,
        Classes = {
            "Atmosphere", "Sky", "Skybox", "Clouds",
            "BloomEffect", "BlurEffect", "ColorCorrectionEffect",
            "DepthOfFieldEffect", "SunRaysEffect", 
            "PointLight", "SpotLight", "SurfaceLight",
            "Lighting", "PostEffect", "Folder"
        }
    },
    Geometry = {
        Enabled = false,
        Classes = {
            "Part", "BasePart", "WedgePart", "CornerWedgePart",
            "TrussPart", "MeshPart", "UnionOperation", "NegateOperation",
            "IntersectOperation", "PartOperation", "VehicleSeat", "Seat",
            "SpawnLocation", "Platform", "SkateboardPlatform",
            "FlagStand", "Terrain", "TerrainRegion",
            "Model", "Folder", "WorldModel", "Actor",
            "SpecialMesh", "BlockMesh", "CylinderMesh", "FileMesh",
            "Decal", "Texture", "SurfaceAppearance", "Folder"
        }
    },
    Physics = {
        Enabled = false,
        Classes = {
            "Attachment", "Bone", "Motor", "Motor6D",
            "AlignOrientation", "AlignPosition", "AngularVelocity",
            "BallSocketConstraint", "CylindricalConstraint", "HingeConstraint",
            "LineForce", "LinearVelocity", "PlaneConstraint",
            "PrismaticConstraint", "RigidConstraint", "RodConstraint",
            "RopeConstraint", "SpringConstraint", "Torque",
            "TorsionSpringConstraint", "UniversalConstraint", "VectorForce",
            "WeldConstraint", "NoCollisionConstraint", "Weld",
            "Snap", "Glue", "ManualWeld", "ManualGlue",
            "BodyPosition", "BodyVelocity", "BodyGyro",
            "BodyThrust", "BodyAngularVelocity", "RocketPropulsion",
            "BodyMover", "Folder"
        }
    },
    Misc = {
        Enabled = false,
        Classes = {}  -- Empty, catches all uncategorized items
    }
}

-- Class Filter Lookup Table
local CLASS_FILTER_LOOKUP = {}
for category, data in pairs(SYNC_SETTINGS) do
    for _, className in ipairs(data.Classes) do
        CLASS_FILTER_LOOKUP[className] = category
    end
end

-- ================================================================================================
-- 4. UTILITY FUNCTIONS
-- ================================================================================================

-- Safe Service Getter
function getSafeService(serviceName)
    local success, service = pcall(game.GetService, game, serviceName)
    return success and service or nil
end

-- Debug Print Function
local function debugPrint(message)
    if DEBUG_MODE then
        print("[DEBUG] " .. message)
    end
end

-- ================================================================================================
-- 5. FILTERING FUNCTIONS
-- ================================================================================================

-- Check if instance should be synced based on filter settings
function shouldSyncInstance(instance)
    if not instance then return false end
    
    local className = instance.ClassName
    
    -- Special case: BillboardGui needs both Geometry AND UI enabled
    if className == "BillboardGui" or className == "SurfaceGui" then
        local geometryEnabled = SYNC_SETTINGS.Geometry and SYNC_SETTINGS.Geometry.Enabled
        local uiEnabled = SYNC_SETTINGS.UI and SYNC_SETTINGS.UI.Enabled
        return geometryEnabled and uiEnabled
    end
    
    -- Special case: Abstract category requires "Abstract" tag
    local instanceTags = instance:GetTags()
    local hasAbstractTag = false
    for _, tag in ipairs(instanceTags) do
        if tag == "Abstract" then
            hasAbstractTag = true
            break
        end
    end
    
    if hasAbstractTag then
        -- Instance has Abstract tag, check Abstract category
        local abstractEnabled = SYNC_SETTINGS.Abstract and SYNC_SETTINGS.Abstract.Enabled
        if abstractEnabled then
            -- Check if class is in Abstract category
            for _, abstractClass in ipairs(SYNC_SETTINGS.Abstract.Classes) do
                if className == abstractClass then
                    return true
                end
            end
        end
        -- If Abstract is disabled or class not in Abstract, fall through to normal logic
    end
    
    -- Multi-category filtering: Check if ANY category containing this class is enabled
    local foundInAnyCategory = false
    for categoryName, categoryData in pairs(SYNC_SETTINGS) do
        if categoryData.Classes then
            for _, categoryClass in ipairs(categoryData.Classes) do
                if className == categoryClass then
                    foundInAnyCategory = true
                    -- If this category is enabled, instance should sync
                    if categoryData.Enabled then
                        return true
                    end
                end
            end
        end
    end
    
    -- If found in categories but none enabled, don't sync
    if foundInAnyCategory then
        return false
    end
    
    -- Instance is uncategorized, check if Misc category is enabled
    return SYNC_SETTINGS.Misc and SYNC_SETTINGS.Misc.Enabled
end

-- ================================================================================================
-- 6. UI FUNCTIONS
-- ================================================================================================

-- Initialize Toolbar
function initializeToolbar()
    local toolbar = plugin:CreateToolbar("Custom Sync")
    
    -- Toggle Sync Button with Cloud Sync Icon
    local toggleSyncButton = toolbar:CreateButton(
        "Toggle Sync", 
        "Enable/Disable real-time sync with Firebase", 
        "rbxassetid://113978563521546" 
    )
    toggleSyncButton:SetActive(SYNC_ENABLED)  -- Set initial state
    toggleSyncButton.Click:Connect(function()
        SYNC_ENABLED = not SYNC_ENABLED
        toggleSyncButton:SetActive(SYNC_ENABLED)  -- Update button state
        print("🔄 Sync " .. (SYNC_ENABLED and "ENABLED" or "DISABLED"))
    end)
    
    -- Debug Mode Button with Bug Icon
    local debugButton = toolbar:CreateButton(
        "Debug Mode", 
        "Toggle debug output and verbose logging", 
        "rbxassetid://121184283154540"
    )
    debugButton:SetActive(DEBUG_MODE)  -- Set initial state
    debugButton.Click:Connect(function()
        DEBUG_MODE = not DEBUG_MODE
        debugButton:SetActive(DEBUG_MODE)  -- Update button state
        print("🐛 Debug mode " .. (DEBUG_MODE and "ENABLED" or "DISABLED"))
    end)
    
    -- Full Sync Button with Upload Icon
    local fullSyncButton = toolbar:CreateButton(
        "Full Sync", 
        "Send complete datamodel to Firebase (manual override)", 
        "rbxassetid://92024040189974"
    )
    fullSyncButton.Click:Connect(function()
        print("💾 [MANUAL] Starting full datamodel sync...")
        updateDataModelInFirebase()
    end)
    
    -- Settings Button with Gear Icon
    local settingsButton = toolbar:CreateButton(
        "Settings",
        "Configure sync filters and options",
        "rbxassetid://78813896054621"
    )
    settingsButton.Click:Connect(function()
        toggleSettingsUI()
    end)
    
    debugPrint("CustomSync toolbar created with 4 buttons")
    return toggleSyncButton, debugButton, fullSyncButton, settingsButton
end

-- Settings UI Variables
local settingsWidget = nil
local settingsUI = nil

-- Create Settings UI
function createSettingsUI()
    -- Create DockWidget
    local widgetInfo = DockWidgetPluginGuiInfo.new(
        Enum.InitialDockState.Float,
        false,  -- Initial enabled state
        false,  -- Override previous state
        400,    -- Default width
        300,    -- Default height
        300,    -- Minimum width
        200     -- Minimum height
    )
    
    settingsWidget = plugin:CreateDockWidgetPluginGui("CustomSyncSettings", widgetInfo)
    settingsWidget.Title = "CustomSync Settings"
    
    -- Main Frame
    local mainFrame = Instance.new("Frame")
    mainFrame.Size = UDim2.new(1, 0, 1, 0)
    mainFrame.BackgroundColor3 = Color3.fromRGB(46, 46, 46)
    mainFrame.BorderSizePixel = 0
    mainFrame.Parent = settingsWidget
    
    -- Title
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, -20, 0, 30)
    titleLabel.Position = UDim2.new(0, 10, 0, 10)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "Sync Filters"
    titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    titleLabel.TextScaled = true
    titleLabel.Font = Enum.Font.SourceSansBold
    titleLabel.Parent = mainFrame
    
    -- Scrolling Frame for checkboxes
    local scrollFrame = Instance.new("ScrollingFrame")
    scrollFrame.Size = UDim2.new(1, -20, 1, -60)
    scrollFrame.Position = UDim2.new(0, 10, 0, 50)
    scrollFrame.BackgroundColor3 = Color3.fromRGB(36, 36, 36)
    scrollFrame.BorderSizePixel = 0
    scrollFrame.ScrollBarThickness = 6
    scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 250)
    scrollFrame.Parent = mainFrame
    
    local yOffset = 10
    
    -- Create checkbox for each category in defined order
    for _, categoryName in ipairs(CATEGORY_ORDER) do
        local categoryData = SYNC_SETTINGS[categoryName]
        if not categoryData then continue end
        -- Category Frame
        local categoryFrame = Instance.new("Frame")
        categoryFrame.Size = UDim2.new(1, -20, 0, 40)
        categoryFrame.Position = UDim2.new(0, 10, 0, yOffset)
        categoryFrame.BackgroundColor3 = Color3.fromRGB(53, 53, 53)
        categoryFrame.BorderSizePixel = 0
        categoryFrame.Parent = scrollFrame
        
        -- Checkbox Button
        local checkButton = Instance.new("TextButton")
        checkButton.Size = UDim2.new(0, 30, 0, 30)
        checkButton.Position = UDim2.new(0, 5, 0, 5)
        checkButton.BackgroundColor3 = categoryData.Enabled and Color3.fromRGB(0, 162, 255) or Color3.fromRGB(70, 70, 70)
        checkButton.Text = categoryData.Enabled and "✓" or ""
        checkButton.TextColor3 = Color3.fromRGB(255, 255, 255)
        checkButton.TextScaled = true
        checkButton.Font = Enum.Font.SourceSansBold
        checkButton.Parent = categoryFrame
        
        -- Category Label
        local categoryLabel = Instance.new("TextLabel")
        categoryLabel.Size = UDim2.new(0.6, -45, 1, -10)
        categoryLabel.Position = UDim2.new(0, 40, 0, 5)
        categoryLabel.BackgroundTransparency = 1
        categoryLabel.Text = "Sync " .. categoryName
        categoryLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        categoryLabel.TextXAlignment = Enum.TextXAlignment.Left
        categoryLabel.TextScaled = true
        categoryLabel.Font = Enum.Font.SourceSans
        categoryLabel.Parent = categoryFrame
        
        -- Class count on right side, vertically centered
        local classCount = Instance.new("TextLabel")
        classCount.Size = UDim2.new(0.3, -10, 1, -10)
        classCount.Position = UDim2.new(0.7, 0, 0, 5)
        classCount.BackgroundTransparency = 1
        if categoryName == "Misc" then
            classCount.Text = "(all others)"
        else
            classCount.Text = "(" .. #categoryData.Classes .. " classes)"
        end
        classCount.TextColor3 = Color3.fromRGB(170, 170, 170)
        classCount.TextXAlignment = Enum.TextXAlignment.Right
        classCount.TextScaled = true
        classCount.Font = Enum.Font.SourceSans
        classCount.Parent = categoryFrame
        
        -- Toggle functionality
        checkButton.MouseButton1Click:Connect(function()
            categoryData.Enabled = not categoryData.Enabled
            checkButton.BackgroundColor3 = categoryData.Enabled and Color3.fromRGB(0, 162, 255) or Color3.fromRGB(70, 70, 70)
            checkButton.Text = categoryData.Enabled and "✓" or ""
            print("🔧 [SETTINGS] " .. categoryName .. " sync " .. (categoryData.Enabled and "ENABLED" or "DISABLED"))
        end)
        
        yOffset = yOffset + 50
    end
    
    scrollFrame.CanvasSize = UDim2.new(0, 0, 0, yOffset + 10)
    
    return settingsWidget
end

-- Toggle Settings UI
function toggleSettingsUI()
    if not settingsWidget then
        settingsUI = createSettingsUI()
    end
    
    settingsWidget.Enabled = not settingsWidget.Enabled
end

-- Check if instance should be synced based on filter settings (using CLASS_FILTER_LOOKUP)
function shouldSyncInstance(instance)
    if not instance then return false end
    
    local className = instance.ClassName
    
    -- First, check if the exact ClassName is in our filter lookup
    local category = CLASS_FILTER_LOOKUP[className]
    if category then
        local isEnabled = SYNC_SETTINGS[category].Enabled
        debugPrint(string.format("[FILTER] %s (%s category) - %s", 
            className, category, isEnabled and "ALLOWED" or "BLOCKED"))
        return isEnabled
    end
    
    -- If not in lookup, check each category's classes manually
    -- This handles inheritance and classes we might have missed
    for categoryName, categoryData in pairs(SYNC_SETTINGS) do
        if categoryData.Enabled then
            -- Check if instance matches any class in this category
            for _, allowedClass in ipairs(categoryData.Classes) do
                local success, result = pcall(function()
                    return instance:IsA(allowedClass)
                end)
                if success and result then
                    debugPrint(string.format("[FILTER] %s matches %s (%s category) - ALLOWED", 
                        className, allowedClass, categoryName))
                    return true
                end
            end
        end
    end
    
    -- Special inheritance checks for base classes not in our lists
    if SYNC_SETTINGS.Scripts.Enabled and instance:IsA("BaseScript") then
        debugPrint("[FILTER] " .. className .. " (BaseScript) - ALLOWED")
        return true
    end
    
    if SYNC_SETTINGS.UI.Enabled and (instance:IsA("GuiObject") or instance:IsA("GuiBase")) then
        debugPrint("[FILTER] " .. className .. " (GUI base) - ALLOWED")
        return true
    end
    
    if SYNC_SETTINGS.Geometry.Enabled and instance:IsA("BasePart") then
        debugPrint("[FILTER] " .. className .. " (BasePart) - ALLOWED")
        return true
    end
    
    if SYNC_SETTINGS.Physics.Enabled and (instance:IsA("Constraint") or instance:IsA("JointInstance")) then
        debugPrint("[FILTER] " .. className .. " (Physics base) - ALLOWED")
        return true
    end
    
    -- Check if Misc category is enabled for uncategorized items
    if SYNC_SETTINGS.Misc.Enabled then
        debugPrint("[FILTER] " .. className .. " (Misc category) - ALLOWED")
        return true
    else
        debugPrint("[FILTER] " .. className .. " (uncategorized) - BLOCKED")
        return false
    end
end

-- ================================================================================================
-- 7. SERIALIZATION FUNCTIONS
-- ================================================================================================

-- Smart Property Serialization (Only specific property)
function serializePropertyChange(instance, propertyName)
    debugPrint("Serializing property change: " .. instance.Name .. "." .. propertyName)
    
    local serialized = {
        Name = instance.Name,
        ClassName = instance.ClassName,
        Path = instance:GetFullName(),
        ParentPath = instance.Parent and instance.Parent:GetFullName() or nil,
        ChangedProperty = propertyName,
        Properties = {},
        Attributes = {}
    }
    
    -- Serialize only the changed property
    local success, value = pcall(function() return instance[propertyName] end)
    if success then
        -- Handle special property types
        if propertyName == "CFrame" and typeof(value) == "CFrame" then
            local x,y,z, r00,r01,r02, r10,r11,r12, r20,r21,r22 = value:components()
            serialized.Properties[propertyName] = {X=x, Y=y, Z=z, R00=r00, R01=r01, R02=r02, R10=r10, R11=r11, R12=r12, R20=r20, R21=r21, R22=r22}
        elseif propertyName == "Size" and typeof(value) == "Vector3" then
            serialized.Properties[propertyName] = {X = value.X, Y = value.Y, Z = value.Z}
        elseif propertyName == "Color" and typeof(value) == "Color3" then
            serialized.Properties[propertyName] = {R = value.R, G = value.G, B = value.B}
        elseif typeof(value) == "string" or typeof(value) == "number" or typeof(value) == "boolean" then
            serialized.Properties[propertyName] = value
        else
            serialized.Properties[propertyName] = tostring(value)
        end
    end
    
    return serialized
end

-- Smart Attribute Serialization (Only specific attribute)
function serializeAttributeChange(instance, attributeName)
    debugPrint("Serializing attribute change: " .. instance.Name .. "." .. attributeName)
    
    local serialized = {
        Name = instance.Name,
        ClassName = instance.ClassName,
        Path = instance:GetFullName(),
        ParentPath = instance.Parent and instance.Parent:GetFullName() or nil,
        ChangedAttribute = attributeName,
        Attributes = {}
    }
    
    local value = instance:GetAttribute(attributeName)
    if value ~= nil then
        local valueType = typeof(value)
        if valueType == "Vector3" then
            serialized.Attributes[attributeName] = {X = value.X, Y = value.Y, Z = value.Z}
        elseif valueType == "Color3" then
            serialized.Attributes[attributeName] = {R = value.R, G = value.G, B = value.B}
        elseif valueType == "string" or valueType == "number" or valueType == "boolean" then
            serialized.Attributes[attributeName] = value
        else
            serialized.Attributes[attributeName] = tostring(value)
        end
    end
    
    return serialized
end

-- Lightweight Instance Serialization (No children, essential props only)
function serializeLightweight(instance)
    debugPrint("Lightweight serialization: " .. instance.Name)
    
    local serialized = {
        Name = instance.Name,
        ClassName = instance.ClassName,
        Path = instance:GetFullName(),
        ParentPath = instance.Parent and instance.Parent:GetFullName() or nil,
        Properties = {
            Archivable = instance.Archivable
        },
        Attributes = {}
    }
    
    -- Only essential properties based on type
    if instance:IsA("BasePart") then
        local x,y,z, r00,r01,r02, r10,r11,r12, r20,r21,r22 = instance.CFrame:components()
        serialized.Properties.CFrame = {X=x, Y=y, Z=z, R00=r00, R01=r01, R02=r02, R10=r10, R11=r11, R12=r12, R20=r20, R21=r21, R22=r22}
        serialized.Properties.Size = {X = instance.Size.X, Y = instance.Size.Y, Z = instance.Size.Z}
        serialized.Properties.Material = instance.Material.Value
    end
    
    -- Key attributes only
    for name, value in pairs(instance:GetAttributes()) do
        if typeof(value) == "string" or typeof(value) == "number" or typeof(value) == "boolean" then
            serialized.Attributes[name] = value
        end
    end
    
    return serialized
end

-- Full Serialization (Fallback for complex operations)
function serializeInstance(instance, depth)
    depth = depth or 0
    if depth > MAX_SERIALIZE_DEPTH then
        debugPrint("WARNING: Max serialization depth reached for " .. instance:GetFullName())
        return { Name = instance.Name, ClassName = instance.ClassName, _MaxDepthReached = true }
    end
    
    -- Services should always be serialized, but we filter their children
    local isService = instance.Parent == game
    if not isService and not shouldSyncInstance(instance) then
        debugPrint("Skipping sync for filtered instance: " .. instance.ClassName .. " - " .. instance.Name)
        return nil
    end
    
    print("Serializing instance: " .. instance.Name)
    local serialized = {
        Name = instance.Name,
        ClassName = instance.ClassName,
        Path = instance:GetFullName(),  -- Absolute path for hierarchy reconstruction
        ParentPath = instance.Parent and instance.Parent:GetFullName() or nil,  -- Extra parent info for server placement
        Properties = {},
        Attributes = {}, 
        Children = {},
        Tags = {}  -- Tags field
    }
    
    -- Serialize Tags
    local tags = instance:GetTags()
    if tags and #tags > 0 then
        serialized.Tags = tags
    end

    -- Serialize common properties
    serialized.Properties.Archivable = instance.Archivable

    -- Serialize Attributes (expanded type handling)
    local allAttributes = instance:GetAttributes()
    for name, value in pairs(allAttributes) do
        local valueType = typeof(value)
        if valueType == "string" or valueType == "number" or valueType == "boolean" then
            serialized.Attributes[name] = value
        elseif valueType == "Vector3" then
            serialized.Attributes[name] = {X = value.X, Y = value.Y, Z = value.Z}
        elseif valueType == "Vector2" then
            serialized.Attributes[name] = {X = value.X, Y = value.Y}
        elseif valueType == "Vector3int16" then
            serialized.Attributes[name] = {X = value.X, Y = value.Y, Z = value.Z}
        elseif valueType == "Color3" then
            serialized.Attributes[name] = {R = value.R, G = value.G, B = value.B}
        elseif valueType == "CFrame" then
            local x,y,z, r00,r01,r02, r10,r11,r12, r20,r21,r22 = value:components()
            serialized.Attributes[name] = {X=x, Y=y, Z=z, R00=r00, R01=r01, R02=r02, R10=r10, R11=r11, R12=r12, R20=r20, R21=r21, R22=r22}
        elseif valueType == "UDim2" then
            serialized.Attributes[name] = {X = {Scale = value.X.Scale, Offset = value.X.Offset}, Y = {Scale = value.Y.Scale, Offset = value.Y.Offset}}
        elseif valueType == "UDim" then
            serialized.Attributes[name] = {Scale = value.Scale, Offset = value.Offset}
        elseif valueType == "EnumItem" then
            serialized.Attributes[name] = {EnumType = value.EnumType.Name, Value = value.Value}
        elseif valueType == "BrickColor" then
            serialized.Attributes[name] = value.Number
        elseif valueType == "Rect" then
            serialized.Attributes[name] = {Min = {X = value.Min.X, Y = value.Min.Y}, Max = {X = value.Max.X, Y = value.Max.Y}}
        elseif valueType == "NumberSequence" then
            local keypoints = {}
            for _, kp in ipairs(value.Keypoints) do
                table.insert(keypoints, {Time = kp.Time, Value = kp.Value, Envelope = kp.Envelope})
            end
            serialized.Attributes[name] = keypoints
        elseif valueType == "ColorSequence" then
            local keypoints = {}
            for _, kp in ipairs(value.Keypoints) do
                table.insert(keypoints, {Time = kp.Time, Value = {R = kp.Value.R, G = kp.Value.G, B = kp.Value.B}})
            end
            serialized.Attributes[name] = keypoints
        elseif valueType == "NumberRange" then
            serialized.Attributes[name] = {Min = value.Min, Max = value.Max}
        elseif valueType == "PhysicalProperties" then
            serialized.Attributes[name] = {Density = value.Density, Friction = value.Friction, Elasticity = value.Elasticity, FrictionWeight = value.FrictionWeight, ElasticityWeight = value.ElasticityWeight}
        elseif valueType == "Instance" then
            serialized.Attributes[name] = value and value:GetFullName() or nil
        elseif valueType == "PathWaypoint" then
            serialized.Attributes[name] = {Position = {X = value.Position.X, Y = value.Position.Y, Z = value.Position.Z}, Action = value.Action.Value}
        elseif valueType == "Ray" then
            serialized.Attributes[name] = {Origin = {X = value.Origin.X, Y = value.Origin.Y, Z = value.Origin.Z}, Direction = {X = value.Direction.X, Y = value.Direction.Y, Z = value.Direction.Z}}
        elseif valueType == "Region3" then
            local min = value.CFrame.Position - (value.Size / 2)
            local max = value.CFrame.Position + (value.Size / 2)
            serialized.Attributes[name] = {Min = {X = min.X, Y = min.Y, Z = min.Z}, Max = {X = max.X, Y = max.Y, Z = max.Z}}
        elseif valueType == "Font" then
            serialized.Attributes[name] = {Family = value.Family, Weight = value.Weight.Value, Style = value.Style.Value}
        elseif valueType == "Axes" or valueType == "Faces" then
            serialized.Attributes[name] = tostring(value)
        else
            serialized.Attributes[name] = tostring(value)
            print("Fallback serialization for attribute '" .. name .. "' of type '" .. valueType .. "'.")
        end
    end

    -- Handle Quality attribute
    if serialized.Attributes.RLQuality == nil then
        serialized.Attributes.RLQuality = 50
        instance:SetAttribute("RLQuality", 50)
    elseif typeof(serialized.Attributes.RLQuality) == "number" then
        serialized.Attributes.RLQuality = math.clamp(serialized.Attributes.RLQuality, 0, 100)
    else
        warn("Invalid Quality type for " .. instance:GetFullName() .. ". Resetting to 50.")
        serialized.Attributes.RLQuality = 50
        instance:SetAttribute("RLQuality", 50)
    end

    -- Generic properties that most instances have
    local success, result = pcall(function()
        -- Always capture Name (except for services)
        if instance.Parent and instance.Parent ~= game then
            serialized.Properties.Name = instance.Name
        end
        
        -- Common properties safe to check
        if instance:FindFirstChild("Archivable") then
            serialized.Properties.Archivable = instance.Archivable
        end
    end)
    
    -- Instance-specific properties (standardized CFrame to components)
    if instance:IsA("BasePart") then
        local x,y,z, r00,r01,r02, r10,r11,r12, r20,r21,r22 = instance.CFrame:components()
        serialized.Properties.CFrame = {X=x, Y=y, Z=z, R00=r00, R01=r01, R02=r02, R10=r10, R11=r11, R12=r12, R20=r20, R21=r21, R22=r22}
        serialized.Properties.Size = {X = instance.Size.X, Y = instance.Size.Y, Z = instance.Size.Z}
        serialized.Properties.Color = {R = instance.Color.R, G = instance.Color.G, B = instance.Color.B}
        serialized.Properties.Material = instance.Material.Value
        serialized.Properties.Transparency = instance.Transparency
        serialized.Properties.Reflectance = instance.Reflectance
        serialized.Properties.CanCollide = instance.CanCollide
        serialized.Properties.Anchored = instance.Anchored
        serialized.Properties.CastShadow = instance.CastShadow
        serialized.Properties.Massless = instance.Massless
    elseif instance:IsA("Script") or instance:IsA("LocalScript") then
        serialized.Properties.Source = instance.Source
        serialized.Properties.Disabled = instance.Disabled
    elseif instance:IsA("Model") then
        serialized.Properties.PrimaryPart = instance.PrimaryPart and instance.PrimaryPart:GetFullName() or nil
        local px, py, pz = instance.WorldPivot.Position.X, instance.WorldPivot.Position.Y, instance.WorldPivot.Position.Z
        serialized.Properties.WorldPivot = {X = px, Y = py, Z = pz}
    elseif instance:IsA("Decal") then
        serialized.Properties.Face = instance.Face.Value
        serialized.Properties.Texture = instance.Texture
        serialized.Properties.Transparency = instance.Transparency
        serialized.Properties.Color3 = {R = instance.Color3.R, G = instance.Color3.G, B = instance.Color3.B}
    elseif instance:IsA("Texture") then
        serialized.Properties.Texture = instance.Texture
        serialized.Properties.StudsPerTileU = instance.StudsPerTileU
        serialized.Properties.StudsPerTileV = instance.StudsPerTileV
        serialized.Properties.OffsetStudsU = instance.OffsetStudsU
        serialized.Properties.OffsetStudsV = instance.OffsetStudsV
    elseif instance:IsA("MeshPart") then
        serialized.Properties.MeshId = instance.MeshId
        serialized.Properties.TextureId = instance.TextureID
        local x,y,z, r00,r01,r02, r10,r11,r12, r20,r21,r22 = instance.CFrame:components()
        serialized.Properties.CFrame = {X=x, Y=y, Z=z, R00=r00, R01=r01, R02=r02, R10=r10, R11=r11, R12=r12, R20=r20, R21=r21, R22=r22}
        serialized.Properties.Size = {X = instance.Size.X, Y = instance.Size.Y, Z = instance.Size.Z}
    elseif instance:IsA("Light") then
        serialized.Properties.Brightness = instance.Brightness
        serialized.Properties.Color = {R = instance.Color.R, G = instance.Color.G, B = instance.Color.B}
        serialized.Properties.Enabled = instance.Enabled
        serialized.Properties.Shadows = instance.Shadows
        if instance:IsA("PointLight") then
            serialized.Properties.Range = instance.Range
        elseif instance:IsA("SpotLight") then
            serialized.Properties.Angle = instance.Angle
            serialized.Properties.Range = instance.Range
        elseif instance:IsA("SurfaceLight") then
            serialized.Properties.Angle = instance.Angle
            serialized.Properties.Range = instance.Range
            serialized.Properties.Face = instance.Face.Value
        end
    elseif instance:IsA("Sound") then
        serialized.Properties.SoundId = instance.SoundId
        serialized.Properties.Volume = instance.Volume
        serialized.Properties.Pitch = instance.PlaybackSpeed
        serialized.Properties.PlayOnRemove = instance.PlayOnRemove
        serialized.Properties.Looped = instance.Looped
        serialized.Properties.IsPlaying = instance.IsPlaying
    elseif instance:IsA("GuiObject") then
        serialized.Properties.Position = {XScale = instance.Position.X.Scale, XOffset = instance.Position.X.Offset, YScale = instance.Position.Y.Scale, YOffset = instance.Position.Y.Offset}
        serialized.Properties.Size = {XScale = instance.Size.X.Scale, XOffset = instance.Size.X.Offset, YScale = instance.Size.Y.Scale, YOffset = instance.Size.Y.Offset}
        serialized.Properties.AnchorPoint = {X = instance.AnchorPoint.X, Y = instance.AnchorPoint.Y}
        serialized.Properties.BackgroundColor3 = {R = instance.BackgroundColor3.R, G = instance.BackgroundColor3.G, B = instance.BackgroundColor3.B}
        serialized.Properties.BackgroundTransparency = instance.BackgroundTransparency
        serialized.Properties.Visible = instance.Visible
        if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
            serialized.Properties.Text = instance.Text
            serialized.Properties.TextColor3 = {R = instance.TextColor3.R, G = instance.TextColor3.G, B = instance.TextColor3.B}
            serialized.Properties.TextTransparency = instance.TextTransparency
            serialized.Properties.TextSize = instance.TextSize
            serialized.Properties.Font = {Family = instance.Font.Family, Weight = instance.Font.Weight.Value, Style = instance.Font.Style.Value}
        elseif instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
            serialized.Properties.Image = instance.Image
            serialized.Properties.ImageColor3 = {R = instance.ImageColor3.R, G = instance.ImageColor3.G, B = instance.ImageColor3.B}
            serialized.Properties.ImageTransparency = instance.ImageTransparency
        end
    elseif instance:IsA("ParticleEmitter") then
        serialized.Properties.Lifetime = {Min = instance.Lifetime.Min, Max = instance.Lifetime.Max}
        serialized.Properties.Rate = instance.Rate
        serialized.Properties.Speed = {Min = instance.Speed.Min, Max = instance.Speed.Max}
    end
    
    -- Serialize all children recursively
    serialized.Children = {}
    for _, child in ipairs(instance:GetChildren()) do
        local childData = serializeInstance(child, depth + 1)
        if childData then  -- Only add if not filtered out
            table.insert(serialized.Children, childData)
        end
    end
    
    return serialized
end

-- ================================================================================================
-- 8. FIREBASE FUNCTIONS
-- ================================================================================================

-- Test Firebase Connection
function testFirebaseConnection()
    debugPrint("Testing Firebase connection...")
    local testUrl = FIREBASE_BASE_URL .. "/projects/.json"
    local success, response = pcall(HttpService.GetAsync, HttpService, testUrl)
    
    if success then
        debugPrint("✅ Firebase connection successful")
        return true
    else
        warn("❌ Firebase connection failed: " .. tostring(response))
        warn("Check Firebase URL: " .. FIREBASE_BASE_URL)
        warn("Ensure HttpService is enabled in game settings")
        return false
    end
end

-- Send Changes to Firebase (individual change tracking)
function sendChangesToFirebase(data)
    if not SYNC_ENABLED then return end
    
    -- Use timestamp as the key for this change
    local timestamp = os.time()
    local changeUrl = FIREBASE_BASE_URL .. "/projects/" .. PROJECT_ID .. "/changes/" .. timestamp .. ".json"
    
    -- Add connection metadata (but not timestamp since it's the key)
    data.PluginVersion = "3.0"
    data.ProjectId = PROJECT_ID
    
    local jsonData = HttpService:JSONEncode(data)
    debugPrint("Sending " .. string.len(jsonData) .. " characters to Firebase changes/" .. timestamp)
    debugPrint("Data preview: " .. jsonData:sub(1, 150) .. "...")
    
    -- Use PUT to set data at specific timestamp key
    local success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = changeUrl,
            Method = "PUT",
            Body = jsonData
        })
    end)
    
    if success then
        print("✅ [FIREBASE] Data pushed successfully. Response: " .. tostring(response):sub(1, 100))
        return true
    else
        warn("❌ [FIREBASE] Push failed: " .. tostring(response))
        
        -- Specific error diagnostics
        local errorMsg = tostring(response):lower()
        if errorMsg:find("http 403") or errorMsg:find("forbidden") then
            warn("Firebase Security Rules may be blocking writes. Check database rules.")
        elseif errorMsg:find("http 401") or errorMsg:find("unauthorized") then
            warn("Firebase Authentication required. Check if auth is properly configured.")
        elseif errorMsg:find("http 404") or errorMsg:find("not found") then
            warn("Firebase URL incorrect. Check: " .. FIREBASE_BASE_URL)
        elseif errorMsg:find("http disabled") or errorMsg:find("httpservice") then
            warn("HttpService is disabled. Enable 'Allow HTTP Requests' in Game Settings.")
        end
        
        return false
    end
end

-- Serialize Full Hierarchy
function serializeFullHierarchy()
    print("🔍 [DATAMODEL] Starting full hierarchy serialization...")
    
    local dataModel = {
        Timestamp = os.time(),
        PluginVersion = "3.0",
        ProjectId = PROJECT_ID,
        Services = {}
    }
    
    -- Track serialization progress
    local totalInstances = 0
    local filteredOut = 0
    
    -- Serialize each service
    for _, serviceName in ipairs(RELEVANT_SERVICES) do
        local service = getSafeService(serviceName)
        if service then
            print("📂 [DATAMODEL] Serializing " .. serviceName .. "...")
            local serviceData = serializeInstance(service, 0)
            if serviceData then
                dataModel.Services[serviceName] = serviceData
                -- Count instances
                local function countInstances(data)
                    if data then
                        totalInstances = totalInstances + 1
                        if data.Children then
                            for _, child in ipairs(data.Children) do
                                countInstances(child)
                            end
                        end
                    end
                end
                countInstances(serviceData)
            else
                print("⚠️ [DATAMODEL] Failed to serialize " .. serviceName)
            end
        else
            print("❌ [DATAMODEL] Service not found: " .. serviceName)
        end
    end
    
    print(string.format("✅ [DATAMODEL] Serialized %d instances across %d services", 
        totalInstances, #RELEVANT_SERVICES))
    
    return dataModel
end

-- Update Complete DataModel in Firebase
function updateDataModelInFirebase()
    if not SYNC_ENABLED then return end
    
    debugPrint("Updating complete datamodel in Firebase...")
    
    local fullData = serializeFullHierarchy()
    local jsonData = HttpService:JSONEncode(fullData)
    
    debugPrint("Sending " .. string.len(jsonData) .. " characters to Firebase datamodel")
    
    local success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = DATAMODEL_URL,
            Method = "PUT",
            Body = jsonData
        })
    end)
    
    if success then
        print("Complete datamodel updated successfully")
        return true
    else
        warn("Failed to update datamodel: " .. tostring(response))
        return false
    end
end

-- Fetch Recent Changes from Firebase  
function fetchRecentChanges()
    if not SYNC_ENABLED then return end
    
    debugPrint("Fetching recent changes from Firebase...")
    -- Get last 10 changes ordered by timestamp (key)
    local queryUrl = FIREBASE_BASE_URL .. "/projects/" .. PROJECT_ID .. "/changes.json?orderBy=\"$key\"&limitToLast=10"
    local success, response = pcall(HttpService.GetAsync, HttpService, queryUrl)
    
    if success then
        if response and response ~= "null" and response ~= "{}" then
            local decodeSuccess, jsonResponse = pcall(HttpService.JSONDecode, HttpService, response)
            if decodeSuccess and jsonResponse then
                print("✅ [FIREBASE] Recent changes fetched successfully")
                processRecentChanges(jsonResponse)
            else
                warn("❌ [FIREBASE] JSON decode failed. Response: " .. tostring(response):sub(1, 100))
            end
        else
            debugPrint("💭 [FIREBASE] No recent changes found (empty response)")
        end
    else
        warn("❌ [FIREBASE] Fetch failed: " .. tostring(response))
    end
end

-- Suggest Firebase Rules (Enhanced Setup Guide)
function suggestFirebaseRules()
    print("\n🔥 [FIREBASE SETUP GUIDE] Setting up Firebase Realtime Database")
    print("=" .. string.rep("=", 60))
    print("📍 STEP 1: Go to Firebase Console → Your Project → Realtime Database")
    print("📍 STEP 2: Click 'Rules' tab")
    print("📍 STEP 3: Replace rules with:")
    print("\n{")
    print('  "rules": {')
    print('    ".read": true,')
    print('    ".write": true')
    print('  }')
    print("}")
    print("\n📍 STEP 4: Click 'Publish' to save")
    print("=" .. string.rep("=", 60))
    print("⚠️  WARNING: These are permissive rules for DEVELOPMENT only!")
    print("🔒 For production, implement proper authentication.")
    print("🔗 Your Firebase URL: " .. FIREBASE_BASE_URL)
    print("📝 Test by making a change to a selected object in Studio")
    print("")
end

-- Deserialize and Apply Change (Stub; expand for full two-way if needed beyond Rojo)
function applyChange(change)
    local action = change.Action
    for _, instanceData in ipairs(change.Instances or {}) do
        local path = instanceData.Path
        local existing = game:FindFirstChildWhichIsA(instanceData.ClassName, true)
        if action == "delete" then
            if existing then existing:Destroy() end
        elseif action == "add" or action == "update" then
            if not existing then
                existing = Instance.new(instanceData.ClassName)
                local parent = instanceData.ParentPath and game:FindFirstChild(instanceData.ParentPath, true) or Workspace
                existing.Parent = parent
            end
            for prop, value in pairs(instanceData.Properties or {}) do
                if prop == "CFrame" then
                    existing.CFrame = CFrame.new(value.X, value.Y, value.Z, value.R00, value.R01, value.R02, value.R10, value.R11, value.R12, value.R20, value.R21, value.R22)
                elseif prop == "Size" then
                    existing.Size = Vector3.new(value.X, value.Y, value.Z)
                else
                    pcall(function() existing[prop] = value end)
                end
            end
            for attr, value in pairs(instanceData.Attributes or {}) do
                existing:SetAttribute(attr, value)
            end
            existing.Name = instanceData.Name
            for _, childData in ipairs(instanceData.Children or {}) do
                applyChange({Action = "add", Instances = {childData}})
            end
            print("Applied change: " .. action .. " for " .. (instanceData.Path or "unknown"))
        end
    end
end

-- Process Recent Changes (Now applies them)
function processRecentChanges(data)
    print("Processing and applying recent changes from Firebase")
    local latestTimestamp = 0
    local latestChanges = {}
    
    for _, entry in pairs(data) do
        if entry.Action == "BatchInstanceChanged" or entry.Action == "FullHierarchySync" then
            for _, change in ipairs(entry.Changes or entry.Roots or {}) do
                local changeTimestamp = change.Timestamp or 0
                if changeTimestamp > latestTimestamp then
                    latestTimestamp = changeTimestamp
                    latestChanges = {change}
                elseif changeTimestamp == latestTimestamp then
                    table.insert(latestChanges, change)
                end
            end
        end
    end
    
    if #latestChanges > 0 then
        print("Applying most recent changes at timestamp " .. latestTimestamp)
        for _, change in ipairs(latestChanges) do
            applyChange({Action = "update", Instances = {change}})  -- Treat full sync as updates
        end
    else
        print("No recent changes to apply")
    end
end

-- ================================================================================================
-- 9. EVENT HANDLING
-- ================================================================================================

-- Deduplication tracking
local recentEvents = {}
local EVENT_DEDUP_TIME = 0.1  -- 100ms deduplication window

-- Handle Changes
function onChangeDetected(instance, action, detail)
    if not SYNC_ENABLED then return end
    if not instance or not instance:IsA("Instance") then
        debugPrint("onChangeDetected skipped for invalid instance (e.g., Undo/Redo waypoint). Relying on property events.")
        return
    end
    
    -- Deduplication: prevent multiple events for same instance within short time window
    local instancePath = instance:GetFullName()
    local eventKey = instancePath .. "|" .. action .. "|" .. (detail or "")
    local currentTime = tick()
    
    if recentEvents[eventKey] and (currentTime - recentEvents[eventKey]) < EVENT_DEDUP_TIME then
        debugPrint("[DEDUP] Skipping duplicate event: " .. eventKey)
        return
    end
    recentEvents[eventKey] = currentTime

    -- Check if we should sync this instance (filter check replaces service check)
    if not shouldSyncInstance(instance) then
        debugPrint("Ignoring filtered instance: " .. instance.ClassName .. " - " .. instance.Name)
        return
    end

    local instancePath = instance:GetFullName()
    debugPrint(string.format("Change Detected: Action=%s, Instance=%s, Detail=%s", action, instancePath, tostring(detail or "N/A")))

    -- Smart serialization based on change type
    local changeData
    if action == "PropertyChanged" and detail then
        -- Use targeted property serialization
        changeData = serializePropertyChange(instance, detail)
        changeData.ChangeType = "Property"
    elseif action == "AttributeChanged" and detail then
        -- Use targeted attribute serialization
        changeData = serializeAttributeChange(instance, detail)
        changeData.ChangeType = "Attribute"
    elseif action == "DescendantAdded" then
        -- Use lightweight serialization for new instances
        changeData = serializeLightweight(instance)
        changeData.ChangeType = "Add"
    else
        -- Fallback to lightweight for other changes
        changeData = serializeLightweight(instance)
        changeData.ChangeType = "Other"
    end

    -- Update pending_changes with priority: delete > add/update
    if action == "DescendantAdded" then
        pending_changes[instancePath] = { action = "add", data = changeData }
        debugPrint("[CHANGE] Added to pending: " .. instancePath .. " (ADD)")
    elseif action == "DescendantRemoving" then
        pending_changes[instancePath] = { action = "delete", path = instancePath }
        debugPrint("[CHANGE] Added to pending: " .. instancePath .. " (DELETE)")
    elseif action == "PropertyChanged" or action == "AttributeChanged" or action == "Undo" or action == "Redo" then
        local current = pending_changes[instancePath]
        if current and current.action == "delete" then
            debugPrint("Ignoring update for deleted instance: " .. instancePath)
        else
            local effectiveAction = (current and current.action == "add") and "add" or "update"
            pending_changes[instancePath] = { action = effectiveAction, data = changeData }
            -- Track when this instance was last changed
            change_timestamps[instancePath] = os.time()
            debugPrint("[CHANGE] Added to pending: " .. instancePath .. " (" .. effectiveAction:upper() .. ")")
        end
    else
        debugPrint("Unknown action: " .. action)
    end
end

-- Clean old deduplication entries periodically
local lastDedupCleanup = 0
local function cleanupDeduplication()
    local currentTime = tick()
    if currentTime - lastDedupCleanup > 30 then  -- Cleanup every 30 seconds
        local cleaned = 0
        for eventKey, timestamp in pairs(recentEvents) do
            if currentTime - timestamp > EVENT_DEDUP_TIME * 10 then  -- Keep 10x the dedup window
                recentEvents[eventKey] = nil
                cleaned = cleaned + 1
            end
        end
        if cleaned > 0 then
            debugPrint("[DEDUP] Cleaned " .. cleaned .. " old deduplication entries")
        end
        lastDedupCleanup = currentTime
    end
end



-- Setup Event Listeners (Optimized to reduce duplicates)
function setupEventListeners()
    -- Primary change detection - use DescendantAdded/Removing for comprehensive coverage
    -- This captures all hierarchy changes without duplicates
    Workspace.DescendantAdded:Connect(function(descendant)
        onChangeDetected(descendant, "DescendantAdded")
    end)
    Workspace.DescendantRemoving:Connect(function(descendant)
        onChangeDetected(descendant, "DescendantRemoving")
    end)
    
    -- Also listen to undo/redo for property changes that might not trigger above events
    ChangeHistoryService.OnUndo:Connect(function(waypoint)
        onChangeDetected(nil, "Undo", waypoint)
    end)
    ChangeHistoryService.OnRedo:Connect(function(waypoint)
        onChangeDetected(nil, "Redo", waypoint)
    end)
    
    -- Listen for selection changes to update listeners on selected objects
    local currentConnections = {}
    Selection.SelectionChanged:Connect(function()
        -- Disconnect previous listeners
        for _, connection in pairs(currentConnections) do
            if connection then
                connection:Disconnect()
            end
        end
        currentConnections = {}
        
        -- Connect Changed event to current selection
        local selection = Selection:Get()
        for _, selected in ipairs(selection) do
            -- Only track changes for instances that pass the filter
            if shouldSyncInstance(selected) then
                local connection = selected.Changed:Connect(function(property)
                    onChangeDetected(selected, "PropertyChanged", property)
                end)
                table.insert(currentConnections, connection)
            else
                debugPrint("Skipping property tracking for filtered instance: " .. selected.ClassName)
            end
        end
        print("🔄 Updated change listeners for " .. #selection .. " selected objects")
    end)
    
    debugPrint("Change detection event listeners connected for Workspace, History, and Selection")
end

-- Main Initialization
print("🚀 [INIT] Starting Custom Sync Worker plugin initialization...")

-- Test Firebase Connection First
local firebaseOk = testFirebaseConnection()
if not firebaseOk then
    warn("⚠️  Firebase connection issues detected. Plugin will continue but sync may fail.")
    warn("Common fixes:")
    warn("1. Enable 'Allow HTTP Requests' in Game Settings > Security")
    warn("2. Check Firebase Database URL: " .. FIREBASE_BASE_URL)
    warn("3. Verify Firebase Database Rules allow writes")
    warn("\n🔧 Running Firebase setup guide...")
    suggestFirebaseRules()
end

-- ================================================================================================
-- 10. MAIN INITIALIZATION
-- ================================================================================================

-- Batch Sync Function (missing critical function!)
function batchSync()
    if not SYNC_ENABLED then 
        debugPrint("[BATCH] Sync disabled, skipping")
        return 
    end
    
    if next(pending_changes) == nil then 
        debugPrint("[BATCH] No pending changes, skipping")
        return 
    end
    
    local pendingCount = 0
    for _ in pairs(pending_changes) do
        pendingCount = pendingCount + 1
    end
    debugPrint("[BATCH] Running batch sync with " .. pendingCount .. " pending changes")
    
    local currentTime = os.time()
    local timeSinceLastPush = currentTime - last_firebase_push
    
    -- Count pending and settled changes
    local pendingCount = 0
    local settledCount = 0
    local settledChanges = {}
    
    for path, changeInfo in pairs(pending_changes) do
        pendingCount = pendingCount + 1
        local lastChangeTime = change_timestamps[path] or 0
        local timeSinceChange = currentTime - lastChangeTime
        
        -- Consider a change "settled" if no new changes for CHANGE_SETTLE_TIME
        if timeSinceChange >= CHANGE_SETTLE_TIME then
            settledCount = settledCount + 1
            settledChanges[path] = changeInfo
        end
    end
    
    if pendingCount > 0 then
        debugPrint(string.format("[BATCH] %d pending, %d settled, last push: %ds ago", 
            pendingCount, settledCount, timeSinceLastPush))
    end
    
    -- Determine if we should push changes
    local shouldPush = false
    local changesToPush = {}
    
    if settledCount > 0 and timeSinceLastPush >= MIN_SYNC_INTERVAL then
        -- Push settled changes if minimum interval has passed
        shouldPush = true
        changesToPush = settledChanges
    elseif settledCount >= MAX_BATCH_SIZE then
        -- Force push if we have too many settled changes
        shouldPush = true
        changesToPush = settledChanges
    elseif currentTime - lastSyncTime >= BATCH_INTERVAL and settledCount > 0 then
        -- Regular batch interval reached with settled changes
        shouldPush = true
        changesToPush = settledChanges
    end
    
    if shouldPush then
        local count = 0
        local changeTypes = {}
        for _, change_info in pairs(changesToPush) do 
            count = count + 1
            local changeType = change_info.data and change_info.data.ChangeType or change_info.action
            changeTypes[changeType] = (changeTypes[changeType] or 0) + 1
        end
        
        -- Show change breakdown
        local typeBreakdown = {}
        for changeType, typeCount in pairs(changeTypes) do
            table.insert(typeBreakdown, changeType .. ":" .. typeCount)
        end
        print(string.format("[SYNC] Pushing %d/%d settled changes (%s)", 
            count, pendingCount, table.concat(typeBreakdown, ", ")))
 
        local batch = {}
        for instancePath, change_info in pairs(changesToPush) do
            local changeData = {
                Action = change_info.action,
                InstancePath = instancePath,
                Instances = {}
            }
            if change_info.action ~= "delete" then
                table.insert(changeData.Instances, change_info.data)
            else
                table.insert(changeData.Instances, { Path = change_info.path })
            end
            table.insert(batch, changeData)
        end
 
        if #batch > 0 then
            sendChangesToFirebase({ Action = "BatchInstanceChanged", Changes = batch, BatchId = os.time() })
            
            -- Remove pushed changes from pending
            for path, _ in pairs(changesToPush) do
                pending_changes[path] = nil
                change_timestamps[path] = nil
            end
            
            last_firebase_push = currentTime
            lastSyncTime = currentTime
        end
    end
end

-- Missing Firebase Functions
function serializeDataModel()
    -- Simple datamodel serialization - returns basic structure
    local dataModel = {
        timestamp = os.time(),
        services = {}
    }
    
    -- Serialize relevant services
    for _, serviceName in ipairs(RELEVANT_SERVICES) do
        local service = getSafeService(serviceName)
        if service then
            dataModel.services[serviceName] = {
                Name = service.Name,
                ClassName = service.ClassName,
                ChildCount = #service:GetChildren()
            }
        end
    end
    
    return dataModel
end

-- Initialize UI
print("🎛️  [INIT] Setting up toolbar...")
local toggleSyncButton, debugButton, fullSyncButton, settingsButton = initializeToolbar()

-- Setup Event Listeners
print("📡 [INIT] Setting up event listeners...")
setupEventListeners()

-- Batch Processing
print("⏱️  [INIT] Starting batch sync (" .. BATCH_INTERVAL .. "s intervals)...")
RunService.Heartbeat:Connect(batchSync)

-- Periodic Firebase Fetch
local lastFetchTime = 0
local FETCH_INTERVAL = 15 -- seconds
print("📥 [INIT] Starting periodic fetch (" .. FETCH_INTERVAL .. "s intervals)...")
RunService.Heartbeat:Connect(function()
    local currentTime = os.time()
    if currentTime - lastFetchTime >= FETCH_INTERVAL then
        lastFetchTime = currentTime
        fetchRecentChanges()
    end
end)

-- Initial DataModel Sync
if firebaseOk and SYNC_ENABLED then
    print("💾 [INIT] Sending initial datamodel to Firebase...")
    updateDataModelInFirebase()
else
    print("⚠️ [INIT] Skipping initial datamodel sync (Firebase issues or sync disabled)")
end

-- ================================================================================================
-- 11. STATUS OUTPUT
-- ================================================================================================

-- Final Status
local statusIcon = firebaseOk and "✅" or "⚠️"
print(statusIcon .. " [READY] Custom Sync Worker plugin ready!")
print("📊 [CONFIG] Sync: " .. (SYNC_ENABLED and "ON" or "OFF") .. " | Debug: " .. (DEBUG_MODE and "ON" or "OFF"))
print("🔄 [CONFIG] Batch: " .. BATCH_INTERVAL .. "s | Settle: " .. CHANGE_SETTLE_TIME .. "s | Min Push: " .. MIN_SYNC_INTERVAL .. "s")
print("📦 [CONFIG] Max Batch: " .. MAX_BATCH_SIZE .. " changes | Project: " .. PROJECT_ID)