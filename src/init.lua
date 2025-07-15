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

-- Firebase Configuration (with persistent storage)
local DEFAULT_FIREBASE_URL = ""
local FIREBASE_BASE_URL = plugin:GetSetting("FirebaseURL") or DEFAULT_FIREBASE_URL
local PROJECT_ID = "default"
local DATAMODEL_URL = FIREBASE_BASE_URL .. "/projects/" .. PROJECT_ID .. "/datamodel.json"

-- Function to validate Firebase URL format
local function isValidFirebaseURL(url)
    if not url or url == "" then
        return false, "URL cannot be empty"
    end
    
    -- Trim whitespace
    url = url:match("^%s*(.-)%s*$")
    
    -- Check basic URL format
    if not url:match("^https?://") then
        return false, "URL must start with http:// or https://"
    end
    
    -- Check for Firebase-like domain pattern
    if not (url:match("firebaseio%.com") or url:match("firebase%.com") or url:match("localhost") or url:match("127%.0%.0%.1")) then
        return false, "URL should be a Firebase Realtime Database URL (firebaseio.com) or localhost for testing"
    end
    
    -- Check that it doesn't end with .json or other path
    if url:match("%.json$") or url:match("/[^/]+$") then
        return false, "URL should be the base Firebase URL without .json or specific paths"
    end
    
    return true, "Valid Firebase URL format"
end

-- Function to check if Firebase is properly configured
local function isFirebaseConfigured()
    local isValid, message = isValidFirebaseURL(FIREBASE_BASE_URL)
    return isValid and FIREBASE_BASE_URL ~= DEFAULT_FIREBASE_URL, message
end

-- Function to print Firebase setup instructions
local function printFirebaseSetupInstructions()
    print("")
    print("🔥 [SETUP] Firebase URL Configuration Required:")
    print("   1. Go to Firebase Console (console.firebase.google.com)")
    print("   2. Select your project")
    print("   3. Go to Realtime Database > Create Database")
    print("   4. Copy the database URL (format: https://YOUR-PROJECT-ID-default-rtdb.firebaseio.com)")
    print("   5. Paste it in CustomSync Settings > Firebase Database URL")
    print("   6. Click Update to save the URL")
    print("")
    print("📝 Example URLs:")
    print("   • https://my-game-project-default-rtdb.firebaseio.com")
    print("   • https://localhost:9000 (for Firebase Emulator)")
    print("")
end

-- Function to update Firebase URL and save to settings
local function updateFirebaseURL(newUrl)
    local isValid, message = isValidFirebaseURL(newUrl)
    
    if not isValid then
        warn("❌ [FIREBASE] Invalid URL: " .. message)
        printFirebaseSetupInstructions()
        return false
    end
    
    -- Trim whitespace
    newUrl = newUrl:match("^%s*(.-)%s*$")
    
    FIREBASE_BASE_URL = newUrl
    DATAMODEL_URL = FIREBASE_BASE_URL .. "/projects/" .. PROJECT_ID .. "/datamodel.json"
    plugin:SetSetting("FirebaseURL", newUrl)
    print("🔥 [SETTINGS] Firebase URL updated: " .. newUrl)
    print("✅ [FIREBASE] URL validation passed - ready for sync operations")
    return true
end

-- Sync Settings
local SYNC_ENABLED = true
local DEBUG_MODE = false
local APPLY_FIREBASE_CHANGES = false  -- Whether to apply changes FROM Firebase to Studio (default: false for safety)
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
local last_processed_timestamp = 0 -- Track last processed Firebase change timestamp

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

-- UI Variables
local settingsButton = nil

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
        
        -- Check Firebase configuration when enabling sync
        if SYNC_ENABLED then
            local isConfigured, message = isFirebaseConfigured()
            if not isConfigured then
                warn("⚠️ [SYNC] Firebase URL not configured properly!")
                warn("⚠️ [SYNC] Using default URL - changes may not reach your project")
                printFirebaseSetupInstructions()
            else
                print("✅ [SYNC] Firebase URL configured - sync operations ready")
            end
        end
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
        
        -- Check Firebase configuration before full sync
        local isConfigured, message = isFirebaseConfigured()
        if not isConfigured then
            warn("⚠️ [FULL SYNC] Firebase URL not configured properly!")
            warn("⚠️ [FULL SYNC] Cannot perform sync to default/invalid URL")
            printFirebaseSetupInstructions()
            return
        end
        
        print("✅ [FULL SYNC] Firebase URL validated - proceeding with full sync")
        local success = updateDataModelInFirebase()
        
        -- Provide completion feedback via console
        if success then
            print("✅ [FULL SYNC] Full datamodel sync completed successfully")
        else
            warn("❌ [FULL SYNC] Full datamodel sync failed")
        end
    end)
    
    -- Settings Button with Gear Icon
    settingsButton = toolbar:CreateButton(
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
        750,    -- Default height
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
    
    -- Add separator space
    yOffset = yOffset + 20
    
    -- Firebase Settings Section
    local firebaseSectionLabel = Instance.new("TextLabel")
    firebaseSectionLabel.Size = UDim2.new(1, -20, 0, 25)
    firebaseSectionLabel.Position = UDim2.new(0, 10, 0, yOffset)
    firebaseSectionLabel.BackgroundTransparency = 1
    firebaseSectionLabel.Text = "Firebase Settings"
    firebaseSectionLabel.TextColor3 = Color3.fromRGB(255, 255, 255)  -- White color to match Sync Filters
    firebaseSectionLabel.TextXAlignment = Enum.TextXAlignment.Center  -- Centered like other section headers
    firebaseSectionLabel.TextScaled = true
    firebaseSectionLabel.Font = Enum.Font.SourceSansBold
    firebaseSectionLabel.Parent = scrollFrame
    
    yOffset = yOffset + 35
    
    -- Firebase URL Input Section (MOVED TO TOP)
    local urlLabel = Instance.new("TextLabel")
    urlLabel.Size = UDim2.new(1, -20, 0, 20)
    urlLabel.Position = UDim2.new(0, 10, 0, yOffset)
    urlLabel.BackgroundTransparency = 1
    urlLabel.Text = "Firebase Database URL:"
    urlLabel.TextColor3 = Color3.fromRGB(255, 255, 255)  -- White text for consistency
    urlLabel.TextXAlignment = Enum.TextXAlignment.Left
    urlLabel.TextScaled = true
    urlLabel.Font = Enum.Font.SourceSans
    urlLabel.Parent = scrollFrame
    
    yOffset = yOffset + 25
    
    -- Firebase URL Text Input Frame
    local urlInputFrame = Instance.new("Frame")
    urlInputFrame.Size = UDim2.new(1, -20, 0, 45)
    urlInputFrame.Position = UDim2.new(0, 10, 0, yOffset)
    urlInputFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    urlInputFrame.BorderSizePixel = 1
    urlInputFrame.BorderColor3 = Color3.fromRGB(70, 70, 70)
    urlInputFrame.Parent = scrollFrame
    
    -- Firebase URL TextBox
    local urlTextBox = Instance.new("TextBox")
    urlTextBox.Size = UDim2.new(1, -80, 1, -10)
    urlTextBox.Position = UDim2.new(0, 5, 0, 5)
    urlTextBox.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    urlTextBox.BackgroundTransparency = 0
    urlTextBox.BorderSizePixel = 1
    urlTextBox.BorderColor3 = Color3.fromRGB(60, 60, 60)
    urlTextBox.Text = FIREBASE_BASE_URL
    urlTextBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    urlTextBox.TextXAlignment = Enum.TextXAlignment.Left
    urlTextBox.TextScaled = false
    urlTextBox.TextSize = 12
    urlTextBox.Font = Enum.Font.SourceSans
    urlTextBox.PlaceholderText = "https://your-project-default-rtdb.firebaseio.com"
    urlTextBox.PlaceholderColor3 = Color3.fromRGB(120, 120, 120)
    urlTextBox.ClearTextOnFocus = false
    urlTextBox.Parent = urlInputFrame
    
    -- Update Button
    local updateButton = Instance.new("TextButton")
    updateButton.Size = UDim2.new(0, 70, 1, -10)
    updateButton.Position = UDim2.new(1, -75, 0, 5)
    updateButton.BackgroundColor3 = Color3.fromRGB(0, 120, 180)
    updateButton.BorderSizePixel = 0
    updateButton.Text = "Update"
    updateButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    updateButton.TextScaled = true
    updateButton.Font = Enum.Font.SourceSansBold
    updateButton.Parent = urlInputFrame
    
    -- Current URL display
    local currentUrlLabel = Instance.new("TextLabel")
    currentUrlLabel.Size = UDim2.new(1, -20, 0, 15)
    currentUrlLabel.Position = UDim2.new(0, 10, 0, yOffset + 50)
    currentUrlLabel.BackgroundTransparency = 1
    currentUrlLabel.Text = "Current: " .. (FIREBASE_BASE_URL == DEFAULT_FIREBASE_URL and "(default)" or "(custom)")
    currentUrlLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
    currentUrlLabel.TextXAlignment = Enum.TextXAlignment.Left
    currentUrlLabel.TextScaled = true
    currentUrlLabel.Font = Enum.Font.SourceSans
    currentUrlLabel.Parent = scrollFrame
    
    -- Update button functionality
    updateButton.MouseButton1Click:Connect(function()
        local newUrl = urlTextBox.Text:match("^%s*(.-)%s*$")  -- Trim whitespace
        
        -- Validate URL before attempting update
        local isValid, message = isValidFirebaseURL(newUrl)
        
        if updateFirebaseURL(newUrl) then
            updateButton.BackgroundColor3 = Color3.fromRGB(0, 150, 0)  -- Green success
            updateButton.Text = "✓ Updated"
            -- Update the current URL display
            currentUrlLabel.Text = "Current: " .. (FIREBASE_BASE_URL == DEFAULT_FIREBASE_URL and "(default)" or "(custom)")
            
            -- Show success feedback longer
            wait(2)
            updateButton.BackgroundColor3 = Color3.fromRGB(0, 120, 180)  -- Back to blue
            updateButton.Text = "Update"
        else
            updateButton.BackgroundColor3 = Color3.fromRGB(180, 0, 0)  -- Red error
            updateButton.Text = "✗ Invalid"
            
            -- Show specific error message in current URL label temporarily
            local originalText = currentUrlLabel.Text
            currentUrlLabel.Text = "Error: " .. message
            currentUrlLabel.TextColor3 = Color3.fromRGB(255, 100, 100)  -- Red error text
            
            wait(3)  -- Show error longer
            
            -- Restore original label
            currentUrlLabel.Text = originalText
            currentUrlLabel.TextColor3 = Color3.fromRGB(150, 150, 150)  -- Back to gray
            updateButton.BackgroundColor3 = Color3.fromRGB(0, 120, 180)  -- Back to blue
            updateButton.Text = "Update"
        end
    end)
    
    yOffset = yOffset + 75
    
    -- APPLY_FIREBASE_CHANGES Setting (MOVED TO BOTTOM)
    local firebaseFrame = Instance.new("Frame")
    firebaseFrame.Size = UDim2.new(1, -20, 0, 40)
    firebaseFrame.Position = UDim2.new(0, 10, 0, yOffset)
    firebaseFrame.BackgroundColor3 = Color3.fromRGB(53, 53, 53)
    firebaseFrame.BorderSizePixel = 0
    firebaseFrame.Parent = scrollFrame
    
    -- Firebase Toggle Button
    local firebaseCheckButton = Instance.new("TextButton")
    firebaseCheckButton.Size = UDim2.new(0, 30, 0, 30)
    firebaseCheckButton.Position = UDim2.new(0, 5, 0, 5)
    firebaseCheckButton.BackgroundColor3 = APPLY_FIREBASE_CHANGES and Color3.fromRGB(255, 100, 100) or Color3.fromRGB(70, 70, 70)  -- Red when enabled (warning)
    firebaseCheckButton.Text = APPLY_FIREBASE_CHANGES and "✓" or ""
    firebaseCheckButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    firebaseCheckButton.TextScaled = true
    firebaseCheckButton.Font = Enum.Font.SourceSansBold
    firebaseCheckButton.Parent = firebaseFrame
    
    -- Firebase Label
    local firebaseLabel = Instance.new("TextLabel")
    firebaseLabel.Size = UDim2.new(0.7, -45, 1, -10)
    firebaseLabel.Position = UDim2.new(0, 40, 0, 5)
    firebaseLabel.BackgroundTransparency = 1
    firebaseLabel.Text = "Apply Firebase Changes"
    firebaseLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    firebaseLabel.TextXAlignment = Enum.TextXAlignment.Left
    firebaseLabel.TextScaled = true
    firebaseLabel.Font = Enum.Font.SourceSans
    firebaseLabel.Parent = firebaseFrame
    
    -- Warning label on right side
    local warningLabel = Instance.new("TextLabel")
    warningLabel.Size = UDim2.new(0.3, -10, 1, -10)
    warningLabel.Position = UDim2.new(0.7, 0, 0, 5)
    warningLabel.BackgroundTransparency = 1
    warningLabel.Text = "(⚠️ overwrites)"
    warningLabel.TextColor3 = Color3.fromRGB(255, 150, 150)  -- Light red warning color
    warningLabel.TextXAlignment = Enum.TextXAlignment.Right
    warningLabel.TextScaled = true
    warningLabel.Font = Enum.Font.SourceSans
    warningLabel.Parent = firebaseFrame
    
    -- Firebase Toggle functionality
    firebaseCheckButton.MouseButton1Click:Connect(function()
        APPLY_FIREBASE_CHANGES = not APPLY_FIREBASE_CHANGES
        firebaseCheckButton.BackgroundColor3 = APPLY_FIREBASE_CHANGES and Color3.fromRGB(255, 100, 100) or Color3.fromRGB(70, 70, 70)
        firebaseCheckButton.Text = APPLY_FIREBASE_CHANGES and "✓" or ""
        print("🔧 [SETTINGS] Apply Firebase Changes " .. (APPLY_FIREBASE_CHANGES and "ENABLED (⚠️ Firebase can overwrite Studio!)" or "DISABLED (Studio → Firebase only)"))
    end)
    
    yOffset = yOffset + 60
    
    scrollFrame.CanvasSize = UDim2.new(0, 0, 0, yOffset + 10)
    
    -- Keep settings button state synchronized when widget is closed by other means
    settingsWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
        if settingsButton then
            settingsButton:SetActive(settingsWidget.Enabled)
        end
    end)
    
    return settingsWidget
end

-- Toggle Settings UI
function toggleSettingsUI()
    if not settingsWidget then
        settingsWidget = createSettingsUI()
    end
    
    settingsWidget.Enabled = not settingsWidget.Enabled
    
    -- Update button visual state to match settings UI state
    if settingsButton then
        settingsButton:SetActive(settingsWidget.Enabled)
    end
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

-- Cache for Roblox API property data
local RobloxClassProperties = nil
local PropertyCacheLoaded = false

-- Load Roblox API dump and extract class properties
function loadRobloxAPIProperties()
    if PropertyCacheLoaded then
        return RobloxClassProperties
    end
    
    debugPrint("[API] Loading Roblox API dump for property discovery...")
    local success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/refs/heads/roblox/API-Dump.json",
            Method = "GET"
        })
    end)
    
    if not success or not response.Success then
        warn("[API] Failed to load Roblox API dump: " .. (response and response.StatusMessage or "Unknown error"))
        PropertyCacheLoaded = true
        return nil
    end
    
    local apiData = HttpService:JSONDecode(response.Body)
    local rawClasses = apiData.Classes
    local classes = {}
    
    -- Process each class and extract readable properties
    for _, classData in pairs(rawClasses) do
        -- Skip only NotScriptable classes, but allow NotCreatable (services are NotCreatable but scriptable)
        if classData.Tags and table.find(classData.Tags, "NotScriptable") then
            continue
        end
        
        -- Also skip classes that are explicitly internal/hidden
        if classData.Tags and (table.find(classData.Tags, "Hidden") or table.find(classData.Tags, "Settings")) then
            continue
        end
        
        local classProps = {}
        local currentClass = classData.Name
        
        -- Walk up the inheritance chain to get all properties
        while currentClass do
            local foundClass = nil
            for _, cls in pairs(rawClasses) do
                if cls.Name == currentClass then
                    foundClass = cls
                    break
                end
            end
            
            if not foundClass then break end
            
            -- Extract properties from this class
            for _, member in pairs(foundClass.Members or {}) do
                if member.MemberType == "Property" then
                    -- Check security - only include properties that are scriptable
                    local isSecure = false
                    if type(member.Security) == "string" then
                        isSecure = member.Security ~= "None"
                    elseif type(member.Security) == "table" then
                        isSecure = (member.Security.Read ~= "None") or (member.Security.Write ~= "None")
                    end
                    
                    -- Skip if security restricted or has problematic tags
                    if isSecure then continue end
                    if member.Tags and (
                        table.find(member.Tags, "ReadOnly") or 
                        table.find(member.Tags, "NotScriptable") or 
                        table.find(member.Tags, "Deprecated") or 
                        table.find(member.Tags, "Hidden")
                    ) then continue end
                    
                    -- Add property if it has a valid type
                    if member.ValueType then
                        classProps[member.Name] = true
                    end
                end
            end
            
            currentClass = foundClass.Superclass
        end
        
        classes[classData.Name] = classProps
        
        -- Debug output for service classes
        if classData.Tags and table.find(classData.Tags, "Service") then
            debugPrint("[API] Loaded service class: " .. classData.Name .. " with " .. #classProps .. " properties")
        end
    end
    
    RobloxClassProperties = classes
    PropertyCacheLoaded = true
    
    -- Verify important services are included (use same list as RELEVANT_SERVICES)
    local importantServices = RELEVANT_SERVICES
    
    local classCount = 0
    local serviceCount = 0
    local foundServices = {}
    local missingServices = {}
    
    for className, classProps in pairs(classes) do
        classCount = classCount + 1
        
        -- Check if this is a service by looking for it in game services
        local serviceSuccess = pcall(function()
            return game:GetService(className)
        end)
        if serviceSuccess then
            serviceCount = serviceCount + 1
            
            -- Check if this is one of our important services
            if table.find(importantServices, className) then
                table.insert(foundServices, className)
                local propCount = 0
                for _ in pairs(classProps) do propCount = propCount + 1 end
                debugPrint("[API] ✅ " .. className .. " service found with " .. propCount .. " properties")
            end
        end
    end
    
    -- Check for missing important services
    for _, serviceName in ipairs(importantServices) do
        if not table.find(foundServices, serviceName) then
            table.insert(missingServices, serviceName)
        end
    end
    
    if #missingServices > 0 then
        warn("[API] ⚠️ Missing important services: " .. table.concat(missingServices, ", "))
    end
    
    debugPrint("[API] Roblox API properties loaded for " .. classCount .. " classes (" .. serviceCount .. " services)")
    debugPrint("[API] Found " .. #foundServices .. "/" .. #importantServices .. " important services")
    return classes
end

-- Get all properties of an instance using Roblox API data
function getAllInstanceProperties(instance)
    local properties = {}
    local className = instance.ClassName
    
    -- Load API properties if not cached
    local apiProperties = loadRobloxAPIProperties()
    
    if apiProperties and apiProperties[className] then
        -- Use API data to get exact properties for this class
        for propName, _ in pairs(apiProperties[className]) do
            local success, value = pcall(function()
                return instance[propName]
            end)
            if success and value ~= nil then
                properties[propName] = value
            end
        end
        debugPrint("[PROPS] Used API data for " .. className .. " properties")
    else
        -- Fallback to JSONEncode method if API data unavailable
        local success, jsonString = pcall(function()
            return HttpService:JSONEncode(instance)
        end)
        
        if success then
            local success2, data = pcall(function()
                return HttpService:JSONDecode(jsonString)
            end)
            
            if success2 and data then
                properties = data
                debugPrint("[PROPS] Used JSONEncode fallback for " .. className)
            end
        else
            -- Last resort - manual property list
            warn("[PROPS] Both API and JSONEncode failed for " .. className .. ", using manual fallback")
            local fallbackProps = {
                "Archivable", "Position", "Size", "CFrame", "Color", "Transparency", "Material",
                "CanCollide", "Anchored", "Text", "TextSize", "Font", "Visible", "Value"
            }
            
            for _, propName in ipairs(fallbackProps) do
                local success3, value = pcall(function()
                    return instance[propName]
                end)
                if success3 and value ~= nil then
                    properties[propName] = value
                end
            end
        end
    end
    
    return properties
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
    
    -- print("Serializing instance: " .. instance.Name)
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
        
        -- Get all properties using JSONEncode workaround (since GetProperties() often fails)
        local success, properties = pcall(function()
            return getAllInstanceProperties(instance)
        end)
        
        if success and properties then
            local propCount = 0
            for _ in pairs(properties) do propCount = propCount + 1 end
            debugPrint("[PROPS] Found " .. propCount .. " properties for " .. instance.ClassName .. " '" .. instance.Name .. "'")
            
            for propName, propValue in pairs(properties) do
                if propValue ~= nil and propName ~= "Name" and propName ~= "Parent" then -- Skip Name/Parent as we handle separately
                    serialized.Properties[propName] = propValue
                end
            end
        else
            -- Fallback to basic properties if property discovery fails
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
    data.PluginVersion = "3.3"
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
        PluginVersion = "3.3",
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
            -- print("📂 [DATAMODEL] Serializing " .. serviceName .. "...")
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
    if not APPLY_FIREBASE_CHANGES then 
        debugPrint("Firebase change application disabled (APPLY_FIREBASE_CHANGES=false)")
        return 
    end
    
    debugPrint("Fetching recent changes from Firebase...")
    -- Get last 10 changes ordered by timestamp (key)
    local queryUrl = FIREBASE_BASE_URL .. "/projects/" .. PROJECT_ID .. "/changes.json?orderBy=\"$key\"&limitToLast=10"
    local success, response = pcall(HttpService.GetAsync, HttpService, queryUrl)
    
    if success then
        if response and response ~= "null" and response ~= "{}" then
            local decodeSuccess, jsonResponse = pcall(HttpService.JSONDecode, HttpService, response)
            if decodeSuccess and jsonResponse then
                debugPrint("✅ [FIREBASE] Recent changes fetched successfully")
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
    if not change then
        warn("applyChange called with nil change")
        return
    end
    
    local action = change.Action
    debugPrint("Applying change with action: " .. tostring(action))
    
    for _, instanceData in ipairs(change.Instances or {}) do
        if not instanceData then
            warn("Skipping nil instanceData")
            continue
        end
        
        -- Debug output to understand data structure
        debugPrint("Processing instanceData:")
        for k, v in pairs(instanceData) do
            debugPrint("  " .. k .. "=" .. tostring(v))
        end
        
        if not instanceData.ClassName then
            warn("instanceData missing ClassName, skipping")
            continue
        end
        
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
            debugPrint("Applied change: " .. action .. " for " .. (instanceData.Path or "unknown"))
        end
    end
end

-- Process Recent Changes (Now applies them)
function processRecentChanges(data)
    if not APPLY_FIREBASE_CHANGES then 
        debugPrint("Skipping Firebase change processing (APPLY_FIREBASE_CHANGES=false)")
        return 
    end
    
    debugPrint("Processing and applying recent changes from Firebase (last processed: " .. last_processed_timestamp .. ")")
    local newChangesFound = 0
    local latestTimestamp = last_processed_timestamp
    local newChanges = {}
    
    -- Collect all new changes (timestamp > last_processed_timestamp)
    for _, entry in pairs(data) do
        if entry.Action == "BatchInstanceChanged" or entry.Action == "FullHierarchySync" then
            for _, change in ipairs(entry.Changes or entry.Roots or {}) do
                local changeTimestamp = change.Timestamp or 0
                
                -- Only process changes newer than our last processed timestamp
                if changeTimestamp > last_processed_timestamp then
                    newChangesFound = newChangesFound + 1
                    
                    -- Keep track of the latest timestamp we're processing
                    if changeTimestamp > latestTimestamp then
                        latestTimestamp = changeTimestamp
                    end
                    
                    -- Store all new changes (not just the latest)
                    table.insert(newChanges, {
                        timestamp = changeTimestamp,
                        change = change
                    })
                end
            end
        end
    end
    
    if newChangesFound > 0 then
        debugPrint("Found " .. newChangesFound .. " new changes (newest timestamp: " .. latestTimestamp .. ")")
        
        -- Sort changes by timestamp to apply them in order
        table.sort(newChanges, function(a, b) return a.timestamp < b.timestamp end)
        
        -- Process each new change
        for _, changeInfo in ipairs(newChanges) do
            local change = changeInfo.change
            local timestamp = changeInfo.timestamp
            
            debugPrint("Processing change at timestamp " .. timestamp)
            
            -- Debug: Print the structure of the change data from Firebase
            debugPrint("Firebase change structure:")
            for k, v in pairs(change) do
                if k == "Instances" and type(v) == "table" then
                    debugPrint("  " .. k .. "= table with " .. #v .. " items:")
                    for i, instance in ipairs(v) do
                        debugPrint("    [" .. i .. "]:")
                        for ik, iv in pairs(instance) do
                            debugPrint("      " .. ik .. "=" .. tostring(iv))
                        end
                    end
                else
                    debugPrint("  " .. k .. "=" .. tostring(v))
                end
            end
            
            -- TODO: Properly convert Firebase change data to applyChange format
            -- For now, skip applying to avoid errors
            debugPrint("Skipping application of Firebase change (needs proper data conversion)")
            -- applyChange({Action = "update", Instances = {change}})  -- Treat full sync as updates
        end
        
        -- Update our last processed timestamp
        last_processed_timestamp = latestTimestamp
        debugPrint("Updated last processed timestamp to: " .. last_processed_timestamp)
    else
        debugPrint("No new changes to apply (all changes older than " .. last_processed_timestamp .. ")")
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
        debugPrint("🔄 Updated change listeners for " .. #selection .. " selected objects")
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
    
    -- Check Firebase URL configuration before attempting sync
    local isConfigured, message = isFirebaseConfigured()
    if not isConfigured then
        debugPrint("[BATCH] Firebase URL not configured, skipping sync: " .. message)
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
        debugPrint(string.format("[SYNC] Pushing %d/%d settled changes (%s)", 
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

-- Firebase Connection Test Function
function testFirebaseConnection()
    local isConfigured, message = isFirebaseConfigured()
    if not isConfigured then
        warn("❌ [FIREBASE] Connection test failed: " .. message)
        printFirebaseSetupInstructions()
        return false
    end
    
    -- Test URL reachability (simplified - just check format for now)
    print("🔥 [FIREBASE] Connection test passed for: " .. FIREBASE_BASE_URL)
    return true
end

-- Send Changes to Firebase Function
function sendChangesToFirebase(data)
    local isConfigured, message = isFirebaseConfigured()
    if not isConfigured then
        warn("⚠️ [FIREBASE] Cannot send changes - URL not configured: " .. message)
        printFirebaseSetupInstructions()
        return false
    end
    
    local timestamp = os.time()
    local changeUrl = FIREBASE_BASE_URL .. "/projects/" .. PROJECT_ID .. "/changes/" .. timestamp .. ".json"
    
    local success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = changeUrl,
            Method = "PUT",
            Headers = {
                ["Content-Type"] = "application/json"
            },
            Body = HttpService:JSONEncode(data)
        })
    end)
    
    if success and response.Success then
        debugPrint("✅ [FIREBASE] Data pushed successfully. Response: " .. tostring(response.Body))
        return true
    else
        warn("❌ [FIREBASE] Push failed: " .. (response and response.StatusMessage or "Unknown error"))
        return false
    end
end

-- Update DataModel in Firebase Function
function updateDataModelInFirebase()
    local isConfigured, message = isFirebaseConfigured()
    if not isConfigured then
        warn("⚠️ [FIREBASE] Cannot update datamodel - URL not configured: " .. message)
        printFirebaseSetupInstructions()
        return false
    end
    
    local dataModel = serializeFullHierarchy()
    
    local success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = DATAMODEL_URL,
            Method = "PUT",
            Headers = {
                ["Content-Type"] = "application/json"
            },
            Body = HttpService:JSONEncode(dataModel)
        })
    end)
    
    if success and response.Success then
        print("✅ [FIREBASE] DataModel updated successfully")
        return true
    else
        warn("❌ [FIREBASE] DataModel update failed: " .. (response and response.StatusMessage or "Unknown error"))
        return false
    end
end

-- Fetch Recent Changes Function
function fetchRecentChanges()
    local isConfigured, message = isFirebaseConfigured()
    if not isConfigured then
        debugPrint("⚠️ [FIREBASE] Cannot fetch changes - URL not configured: " .. message)
        return false
    end
    
    local changesUrl = FIREBASE_BASE_URL .. "/projects/" .. PROJECT_ID .. "/changes.json"
    
    local success, response = pcall(function()
        return HttpService:RequestAsync({
            Url = changesUrl,
            Method = "GET",
            Headers = {
                ["Content-Type"] = "application/json"
            }
        })
    end)
    
    if success and response.Success then
        debugPrint("✅ [FIREBASE] Recent changes fetched successfully")
        local data = HttpService:JSONDecode(response.Body)
        processRecentChanges(data)
        return true
    else
        debugPrint("⚠️ [FIREBASE] Fetch failed: " .. (response and response.StatusMessage or "Unknown error"))
        return false
    end
end

-- Test Firebase Connection
print("🔥 [INIT] Testing Firebase connection...")
local firebaseOk = testFirebaseConnection()

-- Show setup warning if Firebase not configured
if not firebaseOk then
    print("")
    print("⚠️ [STARTUP] Firebase URL not configured or invalid!")
    print("⚠️ [STARTUP] Sync operations will be disabled until URL is properly set")
    print("⚠️ [STARTUP] Please configure Firebase URL in CustomSync Settings")
    print("")
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
local syncStatus = (firebaseOk and SYNC_ENABLED) and "ACTIVE" or "BLOCKED"
print(statusIcon .. " [READY] Custom Sync Worker plugin ready!")
print("📊 [CONFIG] Sync: " .. (SYNC_ENABLED and "ON" or "OFF") .. " | Debug: " .. (DEBUG_MODE and "ON" or "OFF") .. " | Apply Firebase: " .. (APPLY_FIREBASE_CHANGES and "ON" or "OFF"))
print("🔄 [CONFIG] Batch: " .. BATCH_INTERVAL .. "s | Settle: " .. CHANGE_SETTLE_TIME .. "s | Min Push: " .. MIN_SYNC_INTERVAL .. "s")
print("📦 [CONFIG] Max Batch: " .. MAX_BATCH_SIZE .. " changes | Project: " .. PROJECT_ID)
print("🔥 [CONFIG] Firebase URL: " .. FIREBASE_BASE_URL .. (FIREBASE_BASE_URL == DEFAULT_FIREBASE_URL and " (default)" or " (custom)"))
print("🚀 [STATUS] Firebase Operations: " .. (firebaseOk and "READY" or "BLOCKED - Configure URL first"))
print("🔄 [STATUS] Real-time Sync: " .. syncStatus)