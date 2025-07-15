# Custom Sync Worker Plugin
**Version 3.0** - Advanced Roblox Studio ↔ Firebase Synchronization

A sophisticated Roblox Studio plugin that enables real-time bidirectional synchronization between Roblox Studio and Firebase Realtime Database, with intelligent change detection, batching, and filtering capabilities.

## 🚀 Features

### **Real-Time Synchronization**
- **📤 Smart Change Detection** - Monitors properties, attributes, hierarchy changes
- **📥 Bidirectional Sync** - Fetches external changes every 15 seconds
- **⚡ Intelligent Batching** - Optimized Firebase writes with settable delays
- **🎯 Selective Filtering** - Category-based instance filtering (Scripts, UI, Geometry, etc.)

### **Advanced Architecture**
- **🔥 Firebase Integration** - Direct Firebase Realtime Database connectivity
- **📊 Comprehensive Serialization** - Full property and attribute support
- **🛠️ Studio UI Integration** - Toolbar buttons and settings panel
- **🔍 Debug Mode** - Extensive logging and monitoring capabilities

### **Workflow Integration**
- **🔄 Rojo Compatible** - Generates clean .rbxmx files via CustomSyncServer
- **💻 VS Code Extension Support** - API integration for development workflows
- **🐍 Python Listener** - Server-side change processing and merging

## 📋 How It Works

### **Plugin Architecture**
1. **Plugin Startup** → Send complete datamodel snapshot to Firebase
2. **Change Detection** → Monitor Studio events (properties, hierarchy, attributes)
3. **Smart Batching** → Accumulate and settle changes before Firebase push
4. **Firebase Sync** → Push batched changes with timestamp-based keys
5. **Periodic Fetch** → Pull external changes every 15 seconds

### **Full Integration**
1. **CustomSync Plugin** → Send FULL datamodel once
2. **Roblox Studio** → Send ONLY individual changes to Firebase
3. **CustomSync Server** → Maintains authoritative datamodel in memory
4. **CustomSync Server** → Applies incremental changes
5. **CustomSync Extension** → Queries Python API for .rbxmx generation

## 🛠️ Configuration

### **Firebase Setup**
- **Base URL**: `https://customsyncworker-default-rtdb.firebaseio.com`
- **Project Structure**: `/projects/{PROJECT_ID}/datamodel.json`
- **Changes Path**: `/projects/{PROJECT_ID}/changes/{timestamp}.json`

### **Sync Categories**
- **Abstract** - Tagged instances with special handling
- **Scripts** - LocalScript, Script, ModuleScript, RemoteEvents
- **Values** - IntValue, StringValue, BoolValue, etc.
- **UI** - GUI elements and interface components  
- **Lighting** - Lighting service and related objects
- **Geometry** - Parts, Models, MeshParts, Unions
- **Physics** - Constraints, Joints, physics objects
- **Misc** - Uncategorized instances

### **Timing Configuration**
- **Batch Interval**: 10 seconds (configurable)
- **Change Settle Time**: 2 seconds before considering changes "ready"
- **Min Sync Interval**: 5 seconds between Firebase pushes
- **Fetch Interval**: 15 seconds for external change polling
- **Max Batch Size**: 50 changes per push

## 🏗️ Installation

### **Build Plugin**
```bash
# Build plugin to local plugins folder
rojo build -p "CustomSyncPlugin.rbxm"

# Watch mode for development
rojo build -p "CustomSyncPlugin.rbxm" --watch
```

### **Firebase Configuration**
1. Enable **Allow HTTP Requests** in Game Settings → Security
2. Configure Firebase Realtime Database with proper read/write rules
3. Verify database URL matches plugin configuration

### **Python Listener Setup**
```bash
# Install dependencies
pip install requests firebase-admin

# Run CustomSync server
python3 fetch_recent_changes.py listen

# Run in background
nohup python3 fetch_recent_changes.py listen &

# Stop background process
ps aux | grep python3
kill <PID>
```

## 🎮 Usage

### **Studio Interface**
- **🔄 Toggle Sync** - Enable/disable synchronization
- **🐛 Debug Mode** - View detailed logging information
- **📤 Full Sync** - Force complete datamodel push
- **⚙️ Settings** - Configure sync categories and filters

### **Debug Output**
- `[FILTER]` - Instance filtering decisions
- `[CHANGE]` - Change detection and storage
- `[BATCH]` - Batch processing status
- `[FIREBASE]` - Firebase communication
- `[SYNC]` - Synchronization operations

## 🔧 Development

### **File Structure**
```
CustomSyncPlugin/
├── src/
│   └── init.lua          # Main plugin code (1,500+ lines)
├── README.md             # This documentation
└── default.project.json  # Rojo project configuration
```

### **Key Functions**
- `batchSync()` - Processes pending changes
- `shouldSyncInstance()` - Category-based filtering
- `serializeInstance()` - Complete instance serialization
- `fetchRecentChanges()` - External change polling
- `onChangeDetected()` - Change event handler

For more help, check out [the Rojo documentation](https://rojo.space/docs).
