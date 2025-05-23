-- mouse_reactor_crossplatform.lua
-- Cross-platform OBS script: moves, wiggles & scales a source based on your mouse
-- Supports Windows, Linux (X11), and macOS via a unified Platform module

obs = obslua

-- Cache math functions and constants locally for performance
local sin, cos, floor = math.sin, math.cos, math.floor
local twopi = 2 * math.pi
local function round(x) return floor(x + 0.5) end
local vec2 = obs.vec2
local obs_get_source = obs.obs_get_source_by_name
local obs_source_release = obs.obs_source_release
local obs_scene_from_source = obs.obs_scene_from_source
local obs_scene_find_source = obs.obs_scene_find_source
local obs_timer_remove, obs_timer_add = obs.timer_remove, obs.timer_add
local obs_set_pos = obs.obs_sceneitem_set_pos
local obs_set_rot = obs.obs_sceneitem_set_rot
local obs_set_scale = obs.obs_sceneitem_set_scale
local obs_get_rot = obs.obs_sceneitem_get_rot
local obs_get_scale = obs.obs_sceneitem_get_scale

-- Pre-computed animation tables for wiggle optimization
local animation_table_size = 1000 -- Number of pre-computed points
local sin_table = {}
local cos_table = {}

-- Pre-computed animation cycles for different speeds
local wiggle_cycles = {}
local max_precalc_speed = 10 -- Maximum wiggle speed to pre-calculate
local cycle_duration = 1.0 -- Duration of one complete cycle in seconds

-- Initialize the pre-computed tables
for i = 1, animation_table_size do
    local angle = (i-1) * twopi / animation_table_size
    sin_table[i] = math.sin(angle)
    cos_table[i] = math.cos(angle)
end

-- Pre-calculate complete animation cycles for different speeds
local function initialize_wiggle_cycles()
    for speed_val = 0.1, max_precalc_speed, 0.1 do
        -- Round to one decimal place to avoid floating point errors
        local speed = math.floor(speed_val * 10) / 10
        local speed_key = tostring(math.floor(speed * 10))
        
        wiggle_cycles[speed_key] = {
            position = {},
            rotation = {},
            scale = {}
        }
        
        -- Pre-calculate values for one complete cycle
        for step = 1, animation_table_size do
            local t = (step-1) / animation_table_size
            local sin_val = sin_table[step]
            local cos_val = cos_table[step]
            
            -- Store pre-calculated values for this step
            wiggle_cycles[speed_key].position[step] = {sin_val, cos_val}
            wiggle_cycles[speed_key].rotation[step] = sin_val
            wiggle_cycles[speed_key].scale[step] = {sin_val, cos_val}
        end
    end
    
    -- Log successful initialization
    obs.script_log(obs.LOG_INFO, "Pre-calculated " .. tostring(#wiggle_cycles) .. " animation cycles")
end

-- Call this once to initialize all the animation cycles
initialize_wiggle_cycles()

-- Debug function to print all keys in the wiggle_cycles table
local function debug_wiggle_cycles()
    local keys = {}
    local count = 0
    for k, _ in pairs(wiggle_cycles) do
        table.insert(keys, k)
        count = count + 1
    end
    table.sort(keys)
    local key_str = table.concat(keys, ", ")
    obs.script_log(obs.LOG_INFO, "Wiggle cycles has " .. count .. " keys: " .. key_str)
end

-- Run debug
debug_wiggle_cycles()

-- Get pre-computed sin/cos values (much faster than calculating in real-time)
local function get_sin(t)
    local index = math.floor((t % 1.0) * animation_table_size) + 1
    return sin_table[index]
end

local function get_cos(t)
    local index = math.floor((t % 1.0) * animation_table_size) + 1
    return cos_table[index]
end

-- Get values from pre-calculated animation cycles
local function get_wiggle_values(time, speed, effect_type)
    -- Make sure speed is within our pre-calculated range
    local clamped_speed = math.min(math.max(speed, 0.1), max_precalc_speed)
    
    -- Round to nearest 0.1 to match our pre-calculated speeds
    local rounded_speed = math.floor(clamped_speed * 10 + 0.5) / 10
    local speed_key = tostring(math.floor(rounded_speed * 10))
    
    -- Double-check that the key exists, fall back to default if not
    if not wiggle_cycles[speed_key] then
        speed_key = "10" -- Default to 1.0 Hz if the specific speed isn't found
    end
    
    -- Calculate the current position in the cycle based on time and speed
    local cycle_position = (time * speed) % 1.0
    local index = math.floor(cycle_position * animation_table_size) + 1
    
    -- Make sure index is within range
    if index < 1 then index = 1 end
    if index > animation_table_size then index = animation_table_size end
    
    -- Return the pre-calculated values
    return wiggle_cycles[speed_key][effect_type][index]
end

-- Additional helper variables for optimization
local last_update_time = 0
local is_cpu_saver_enabled = false
local cpu_saver_threshold_ms = 100
local prev_mouse_x, prev_mouse_y = 0, 0
local mouse_move_threshold = 5  -- pixels
local cpu_saver_active = false

-- Variables for inactivity timeout
local use_inactivity_timeout = false
local inactivity_timeout_ms = 1000
local last_mouse_movement_time = 0
local is_inactivity_timeout_reached = false

-- Cache mouse state for optimization
local current_mouse_x, current_mouse_y = 0, 0
local mouse_has_moved = true

-- ─── Platform helper module ─────────────────────────────────────────────────
local ffi = require("ffi")
local bit = require("bit")

-- Constants for magic numbers
local LEFT_MOUSE_BUTTON = 0x01
local RIGHT_MOUSE_BUTTON = 0x02
local KEY_PRESSED_MASK = 0x8000

-- Abstract platform-specific logic into a cleaner interface
local function initialize_platform()
  local status, result = pcall(function()
    if ffi.os == "Windows" then
      ffi.cdef[[
        typedef struct { long x; long y; } POINT;
        bool GetCursorPos(POINT *lpPoint);
        short GetAsyncKeyState(int vKey);
        int   GetSystemMetrics(int nIndex);
      ]]
      local lib = ffi.load("user32")
      return {
        get_cursor_pos = function()
          local pt = ffi.new("POINT")
          lib.GetCursorPos(pt)
          return pt.x, pt.y
        end,
        left_pressed = function()
          return bit.band(lib.GetAsyncKeyState(LEFT_MOUSE_BUTTON), KEY_PRESSED_MASK) ~= 0
        end,
        right_pressed = function()
          return bit.band(lib.GetAsyncKeyState(RIGHT_MOUSE_BUTTON), KEY_PRESSED_MASK) ~= 0
        end,
        get_screen_size = function()
          return lib.GetSystemMetrics(0), lib.GetSystemMetrics(1)
        end
      }
    elseif ffi.os == "Linux" then
    -- Linux-specific implementation
    ffi.cdef[[
      typedef int Bool;
      typedef unsigned long Window;
      typedef struct _XDisplay Display;
      Display*    XOpenDisplay(const char*);
      Window      XDefaultRootWindow(Display*);
      Bool        XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned*);
      int         XDefaultScreen(Display*);
      int         XDisplayWidth(Display*, int);
      int         XDisplayHeight(Display*, int);
    ]]
    local lib = ffi.load("X11")
    local dpy = lib.XOpenDisplay(nil)
    local root = lib.XDefaultRootWindow(dpy)
    return {
      get_cursor_pos = function()
        local root_ret, child_ret = ffi.new("Window[1]"), ffi.new("Window[1]")
        local rx, ry = ffi.new("int[1]"), ffi.new("int[1]")
        local wx, wy = ffi.new("int[1]"), ffi.new("int[1]")
        local mask = ffi.new("unsigned[1]")
        lib.XQueryPointer(dpy, root, root_ret, child_ret, rx, ry, wx, wy, mask)
        return rx[0], ry[0]
      end,
      left_pressed = function()
        local mask = ffi.new("unsigned[1]")
        lib.XQueryPointer(dpy, root, nil, nil, nil, nil, nil, nil, mask)
        return bit.band(mask[0], 1) ~= 0
      end,
      right_pressed = function()
        local mask = ffi.new("unsigned[1]")
        lib.XQueryPointer(dpy, root, nil, nil, nil, nil, nil, nil, mask)
        return bit.band(mask[0], 2) ~= 0
      end,
      get_screen_size = function()
        local screen = lib.XDefaultScreen(dpy)
        return lib.XDisplayWidth(dpy, screen), lib.XDisplayHeight(dpy, screen)
      end
    }
  elseif ffi.os == "OSX" then
    -- macOS-specific implementation
    ffi.cdef[[
      typedef struct { double x; double y; } CGPoint;
      typedef void* CGEventRef;
      typedef int CGEventSourceStateID;
      typedef int CGMouseButton;
      CGEventRef  CGEventCreate(void*);
      CGPoint     CGEventGetLocation(CGEventRef event);
      CGEventSourceStateID CGEventSourceButtonState(CGEventSourceStateID, CGMouseButton);
      unsigned    CGMainDisplayID(void);
      size_t      CGDisplayPixelsWide(unsigned);
      size_t      CGDisplayPixelsHigh(unsigned);
      enum { kCGEventSourceStateHIDSystemState = 1 };
      enum { kCGMouseButtonLeft = 0, kCGMouseButtonRight = 1 };
    ]]
    return {
      get_cursor_pos = function()
        local ev = ffi.C.CGEventCreate(nil)
        local pt = ffi.C.CGEventGetLocation(ev)
        return pt.x, pt.y
      end,
      left_pressed = function()
        return ffi.C.CGEventSourceButtonState(ffi.C.kCGEventSourceStateHIDSystemState, ffi.C.kCGMouseButtonLeft) == 1
      end,
      right_pressed = function()
        return ffi.C.CGEventSourceButtonState(ffi.C.kCGEventSourceStateHIDSystemState, ffi.C.kCGMouseButtonRight) == 1
      end,
      get_screen_size = function()
        local d = ffi.C.CGMainDisplayID()
        return ffi.C.CGDisplayPixelsWide(d), ffi.C.CGDisplayPixelsHigh(d)
      end    }
  else
    error("Unsupported OS: " .. ffi.os)
  end
  end)
  
  if not status then
    obs.script_log(obs.LOG_ERROR, "Failed to initialize platform: " .. tostring(result))
    -- Provide a fallback implementation that does nothing but doesn't crash
    return {
      get_cursor_pos = function() return 0, 0 end,
      left_pressed = function() return false end,
      right_pressed = function() return false end,
      get_screen_size = function() return 1920, 1080 end
    }
  end
  
  return result
end

-- Initialize platform
local Platform = initialize_platform()

-- Additional helper functions
function get_scene_item()
  if not scene_name or scene_name == "" or not source_name or source_name == "" then
    return nil
  end
  
  local src = obs_get_source(scene_name)
  if not src then return nil end
  
  local scn = obs_scene_from_source(src)
  if not scn then 
    obs_source_release(src)
    return nil 
  end
  
  local item = obs_scene_find_source(scn, source_name)
  obs_source_release(src)
  return item
end

-- Check if mouse has moved enough to trigger an update
function has_mouse_moved_significantly()
  local mx, my = Platform.get_cursor_pos()
  local dx = math.abs(mx - prev_mouse_x)
  local dy = math.abs(my - prev_mouse_y)
  
  if dx > mouse_move_threshold or dy > mouse_move_threshold then
    prev_mouse_x, prev_mouse_y = mx, my
    -- Update last mouse movement time when significant movement is detected
    last_mouse_movement_time = os.clock() * 1000
    is_inactivity_timeout_reached = false
    return true
  end
  
  return false
end

-- Internal state
frame       = 0
base_pos_x  = nil
base_pos_y  = nil
cur_pos_x   = nil
cur_pos_y   = nil
cur_rot     = nil
cur_scale   = nil
base_scale  = nil
base_rot    = nil

-- State for scaling (always using non-uniform scaling)
base_scale_x = nil
base_scale_y = nil
cur_scale_x = nil
cur_scale_y = nil
non_uniform_scale = true  -- Always use non-uniform scaling

-- State for scale start mode
scale_start_mode = 0  -- 0 = Current Scale, 1 = Custom Scale
custom_scale_x = 1.0
custom_scale_y = 1.0

-- Store current settings for initializing visibility
local my_settings = nil

-- Store previous settings for conditional resets
local prev_scene_name = nil
local prev_source_name = nil
local prev_start_mode = nil
local prev_start_x, prev_start_y = nil, nil
local prev_position_react = nil
local prev_wiggle = nil
local prev_scale_react = nil
local prev_scale_start_mode = nil
local prev_custom_scale_x, prev_custom_scale_y = nil, nil

function script_description()
  local desc = [[<h2>Mouse React</h2>
  <p>Make your OBS sources react to mouse movements, clicks, and add wiggle effects!</p>
  
  <p><a href="https://github.com/Sphiment/obs-mouse-react">View on GitHub</a></p>
  ]]
  return desc
end

function script_properties()
  local p = obs.obs_properties_create()

  -- Target group: Scene & Source
  local target_props = obs.obs_properties_create()

  -- Scene Dropdown within Target
  local scene_list = obs.obs_properties_add_list(target_props, "scene_name", "Scene", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
  local scenes = obs.obs_frontend_get_scenes()
  if scenes then
    for _, scene in ipairs(scenes) do
      obs.obs_property_list_add_string(scene_list, obs.obs_source_get_name(scene), obs.obs_source_get_name(scene))
    end
    obs.source_list_release(scenes)
  end

  -- Source Dropdown within Target
  local source_list = obs.obs_properties_add_list(target_props, "source_name", "Source", obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
  local sources = obs.obs_enum_sources()
  if sources then
    for _, source in ipairs(sources) do
      obs.obs_property_list_add_string(source_list, obs.obs_source_get_name(source), obs.obs_source_get_name(source))
    end
    obs.source_list_release(sources)
  end

  obs.obs_properties_add_group(p, "target", "Target", obs.OBS_GROUP_NORMAL, target_props)

  -- Position React group
  local pos_props = obs.obs_properties_create()
  -- Start Mode List inside Position React group
  local start_mode_prop = obs.obs_properties_add_list(pos_props, "start_mode", "Start Mode", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
  obs.obs_property_list_add_int(start_mode_prop, "Current Position", 0)
  obs.obs_property_list_add_int(start_mode_prop, "Custom Position", 1)
  -- Callback to show/hide custom X/Y
  obs.obs_property_set_modified_callback(start_mode_prop, function(props, property, settings)
    local sm = obs.obs_data_get_int(settings, "start_mode")
    obs.obs_property_set_visible(obs.obs_properties_get(pos_props, "start_x"), sm == 1)
    obs.obs_property_set_visible(obs.obs_properties_get(pos_props, "start_y"), sm == 1)
    return true
  end)
  -- Custom Position X and Y
  local start_x = obs.obs_properties_add_int(pos_props, "start_x", "Custom X (px)", -10000, 10000, 1)
  local start_y = obs.obs_properties_add_int(pos_props, "start_y", "Custom Y (px)", -10000, 10000, 1)
  -- Initially hide these until needed
  obs.obs_property_set_visible(start_x, false)
  obs.obs_property_set_visible(start_y, false)
  obs.obs_properties_add_int(pos_props, "move_range_x", "X Range (px)", 0, 1000, 1)
  obs.obs_properties_add_int(pos_props, "move_range_y", "Y Range (px)", 0, 1000, 1)
  obs.obs_properties_add_float_slider(pos_props, "smoothing", "Smoothing Factor (Position)", 0.0, 1.0, 0.01)
  obs.obs_properties_add_group(p, "position_react", "Position React", obs.OBS_GROUP_CHECKABLE, pos_props)  -- Scale React group
  local scale_props = obs.obs_properties_create()
    -- Scale Start Mode List
  local scale_start_mode_prop = obs.obs_properties_add_list(scale_props, "scale_start_mode", "Start Mode", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
  obs.obs_property_list_add_int(scale_start_mode_prop, "Current Scale", 0)
  obs.obs_property_list_add_int(scale_start_mode_prop, "Custom Scale", 1)
  
  -- Callback to show/hide custom scale inputs
  obs.obs_property_set_modified_callback(scale_start_mode_prop, function(props, property, settings)
    local sm = obs.obs_data_get_int(settings, "scale_start_mode")
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "custom_scale_x"), sm == 1)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "custom_scale_y"), sm == 1)
    return true
  end)
  -- Custom Scale inputs
  local custom_scale_x = obs.obs_properties_add_float(scale_props, "custom_scale_x", "Custom X Scale", 0.1, 10.0, 0.01)
  local custom_scale_y = obs.obs_properties_add_float(scale_props, "custom_scale_y", "Custom Y Scale", 0.1, 10.0, 0.01)
  
  -- Initially hide these until needed
  obs.obs_property_set_visible(custom_scale_x, false)
  obs.obs_property_set_visible(custom_scale_y, false)
    -- Basic scale controls
  obs.obs_properties_add_bool(scale_props, "scale_left_enabled", "Enable Left-Click Scale")
  obs.obs_properties_add_float(scale_props, "scale_click_left_x", "X Scale on Left-Click", 0.0, 10.0, 0.01)
  obs.obs_properties_add_float(scale_props, "scale_click_left_y", "Y Scale on Left-Click", 0.0, 10.0, 0.01)
  obs.obs_properties_add_bool(scale_props, "scale_right_enabled", "Enable Right-Click Scale")
  obs.obs_properties_add_float(scale_props, "scale_click_right_x", "X Scale on Right-Click", 0.0, 10.0, 0.01)
  obs.obs_properties_add_float(scale_props, "scale_click_right_y", "Y Scale on Right-Click", 0.0, 10.0, 0.01)
  
  -- Add scale smoothing
  obs.obs_properties_add_float_slider(scale_props, "scale_smoothing", "Smoothing Factor (Scale)", 0.0, 1.0, 0.01)
  
  -- Add the main scale group to properties
  obs.obs_properties_add_group(p, "scale_react", "Scale React", obs.OBS_GROUP_CHECKABLE, scale_props)  -- Wiggle group
  local wig_props = obs.obs_properties_create()
  
  -- Add wiggle method selection
  local wiggle_method_prop = obs.obs_properties_add_list(wig_props, "wiggle_method", "Animation Method", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
  obs.obs_property_list_add_int(wiggle_method_prop, "Pre-computed (CPU Efficient)", 0)
  obs.obs_property_list_add_int(wiggle_method_prop, "Real-time (Higher Quality)", 1)
  obs.obs_property_set_long_description(wiggle_method_prop, "Pre-computed method uses less CPU but has slightly less smooth animation. Real-time uses more CPU but has smoother animation.")
  
  obs.obs_properties_add_float(wig_props, "rotation_amp", "Rotation Amplitude (°)", 0.0, 180.0, 1.0)
  obs.obs_properties_add_float(wig_props, "rotation_speed", "Rotations per Second", 0.0, 10.0, 0.1)
  obs.obs_properties_add_int(wig_props, "wiggle_pos_amp_x", "Position Wiggle Amp X (px)", 0, 1000, 1)
  obs.obs_properties_add_int(wig_props, "wiggle_pos_amp_y", "Position Wiggle Amp Y (px)", 0, 1000, 1)
  obs.obs_properties_add_float(wig_props, "wiggle_pos_speed", "Position Wiggle Speed (Hz)", 0.0, 10.0, 0.1)
  obs.obs_properties_add_float(wig_props, "wiggle_scale_amp", "Scale Wiggle Amp", 0.0, 10.0, 0.1)
  obs.obs_properties_add_float(wig_props, "wiggle_scale_speed", "Scale Wiggle Speed (Hz)", 0.0, 10.0, 0.1)
  obs.obs_properties_add_group(p, "wiggle", "Wiggle", obs.OBS_GROUP_CHECKABLE, wig_props)
  -- Update Interval
  obs.obs_properties_add_int(p, "update_interval_ms", "Update Interval (ms)", 1, 1000, 1)
  
  -- Add CPU saving options
  local perf_props = obs.obs_properties_create()
    -- Add CPU saver option with tooltip
  local cpu_saver_prop = obs.obs_properties_add_bool(perf_props, "cpu_saver", "Enable CPU Saver")
  obs.obs_property_set_long_description(cpu_saver_prop, "Reduces CPU usage by only updating when mouse moves or after a time threshold")
  
  -- Add inactivity timeout setting with tooltip
  local inactivity_prop = obs.obs_properties_add_bool(perf_props, "use_inactivity_timeout", "Enable Inactivity Timeout")
  obs.obs_property_set_long_description(inactivity_prop, "Activates CPU saver mode after mouse hasn't moved for specified time")
  
  local inactivity_time_prop = obs.obs_properties_add_int(perf_props, "inactivity_timeout_ms", "Inactivity Timeout (ms)", 100, 10000, 100)
  obs.obs_property_set_long_description(inactivity_time_prop, "Time in milliseconds before CPU saver activates when mouse isn't moving")
  
  -- Add CPU saver threshold with tooltip
  local threshold_prop = obs.obs_properties_add_int(perf_props, "cpu_saver_threshold", "CPU Saver Threshold (ms)", 10, 1000, 10)
  obs.obs_property_set_long_description(threshold_prop, "Minimum time between updates when mouse isn't moving")
  
  -- Add mouse movement threshold with a more descriptive name and tooltip
  local mouse_threshold_prop = obs.obs_properties_add_int(perf_props, "mouse_move_threshold", "Mouse Movement Threshold (px)", 1, 50, 1)
  obs.obs_property_set_long_description(mouse_threshold_prop, "Number of pixels the mouse must move to trigger an update when CPU Saver is enabled")
    -- Add callback to show/hide CPU saver options based on whether it's enabled
  obs.obs_property_set_modified_callback(cpu_saver_prop, function(props, property, settings)
    local enabled = obs.obs_data_get_bool(settings, "cpu_saver")
    obs.obs_property_set_visible(threshold_prop, enabled)
    obs.obs_property_set_visible(mouse_threshold_prop, enabled)
    obs.obs_property_set_visible(inactivity_prop, enabled)
    
    -- Only show inactivity timeout if both CPU saver and inactivity timeout are enabled
    local inactivity_enabled = obs.obs_data_get_bool(settings, "use_inactivity_timeout")
    obs.obs_property_set_visible(inactivity_time_prop, enabled and inactivity_enabled)
    return true
  end)
  
  -- Add callback for inactivity timeout toggle
  obs.obs_property_set_modified_callback(inactivity_prop, function(props, property, settings)
    local cpu_saver_enabled = obs.obs_data_get_bool(settings, "cpu_saver")
    local inactivity_enabled = obs.obs_data_get_bool(settings, "use_inactivity_timeout")
    obs.obs_property_set_visible(inactivity_time_prop, cpu_saver_enabled and inactivity_enabled)
    return true  end)
    obs.obs_properties_add_group(p, "performance", "Performance Options", obs.OBS_GROUP_NORMAL, perf_props)

  local position_react = obs.obs_properties_get(p, "position_react") 
  local scale_react = obs.obs_properties_get(p, "scale_react")
  local wiggle = obs.obs_properties_get(p, "wiggle")
  
  -- Visibility Callbacks
  obs.obs_property_set_modified_callback(position_react, function(props, property, settings)
    local enabled = obs.obs_data_get_bool(settings, "position_react")
    local start_mode_value = obs.obs_data_get_int(settings, "start_mode")
    
    obs.obs_property_set_visible(obs.obs_properties_get(pos_props, "start_mode"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(pos_props, "start_x"), enabled and start_mode_value == 1)
    obs.obs_property_set_visible(obs.obs_properties_get(pos_props, "start_y"), enabled and start_mode_value == 1)
    obs.obs_property_set_visible(obs.obs_properties_get(pos_props, "move_range_x"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(pos_props, "move_range_y"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(pos_props, "smoothing"), enabled)
    return true
  end)
  local scale_react = obs.obs_properties_get(p, "scale_react")
  local wiggle = obs.obs_properties_get(p, "wiggle")
  -- Scale checkboxes callbacks
  local scale_left_enabled_prop = obs.obs_properties_get(scale_props, "scale_left_enabled")
  local scale_right_enabled_prop = obs.obs_properties_get(scale_props, "scale_right_enabled")
  
  -- Callback for the left-click scale enabled checkbox
  obs.obs_property_set_modified_callback(scale_left_enabled_prop, function(props, property, settings)
    local left_enabled = obs.obs_data_get_bool(settings, "scale_left_enabled")    -- Enable/disable the left-click scale value fields based on checkbox state
    obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_left_x"), left_enabled)
    obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_left_y"), left_enabled)
    return true
  end)
    -- Callback for the right-click scale enabled checkbox
  obs.obs_property_set_modified_callback(scale_right_enabled_prop, function(props, property, settings)
    local right_enabled = obs.obs_data_get_bool(settings, "scale_right_enabled")
    -- Enable/disable the right-click scale value fields based on checkbox state
    obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_right_x"), right_enabled)
    obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_right_y"), right_enabled)
    return true
  end)
  
  -- Main scale react callback
  obs.obs_property_set_modified_callback(scale_react, function(props, property, settings)
    local enabled = obs.obs_data_get_bool(settings, "scale_react")
    local left_enabled = obs.obs_data_get_bool(settings, "scale_left_enabled")
    local right_enabled = obs.obs_data_get_bool(settings, "scale_right_enabled")
    local scale_start_mode_value = obs.obs_data_get_int(settings, "scale_start_mode")
    
    -- Make basic scale controls visible when enabled
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_start_mode"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "custom_scale_x"), enabled and scale_start_mode_value == 1)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "custom_scale_y"), enabled and scale_start_mode_value == 1)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_left_enabled"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_right_enabled"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_smoothing"), enabled)
    
    -- Always show X and Y scale controls (non-uniform is now the default)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_click_left_x"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_click_left_y"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_click_right_x"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_click_right_y"), enabled)
      -- Set enabled state based on checkbox state
    if enabled then      obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_left_x"), left_enabled)
      obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_left_y"), left_enabled)
      obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_right_x"), right_enabled)
      obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_right_y"), right_enabled)
    end
      return true
  end)
  
  obs.obs_property_set_modified_callback(wiggle, function(props, property, settings)
    local enabled = obs.obs_data_get_bool(settings, "wiggle")
    obs.obs_property_set_visible(obs.obs_properties_get(wig_props, "rotation_amp"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(wig_props, "rotation_speed"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(wig_props, "wiggle_pos_amp_x"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(wig_props, "wiggle_pos_amp_y"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(wig_props, "wiggle_pos_speed"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(wig_props, "wiggle_scale_amp"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(wig_props, "wiggle_scale_speed"), enabled)
    return true
  end)-- Initialize visibility based on current settings
  obs.obs_properties_apply_settings(p, my_settings)  -- Make sure the scale controls are correctly shown/hidden on startup if settings exist
  if my_settings then
    local scale_react_enabled = obs.obs_data_get_bool(my_settings, "scale_react")
    local non_uniform_enabled = obs.obs_data_get_bool(my_settings, "non_uniform_scale")
    local left_enabled = obs.obs_data_get_bool(my_settings, "scale_left_enabled")
    local right_enabled = obs.obs_data_get_bool(my_settings, "scale_right_enabled")
    local scale_start_mode_value = obs.obs_data_get_int(my_settings, "scale_start_mode")
    
    -- Initialize CPU Saver settings visibility
    local cpu_saver_enabled = obs.obs_data_get_bool(my_settings, "cpu_saver")
    local inactivity_enabled = obs.obs_data_get_bool(my_settings, "use_inactivity_timeout")
    
    obs.obs_property_set_visible(obs.obs_properties_get(perf_props, "cpu_saver_threshold"), cpu_saver_enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(perf_props, "mouse_move_threshold"), cpu_saver_enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(perf_props, "use_inactivity_timeout"), cpu_saver_enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(perf_props, "inactivity_timeout_ms"), cpu_saver_enabled and inactivity_enabled)
      -- Make basic scale controls visible when enabled
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_start_mode"), scale_react_enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "custom_scale_x"), scale_react_enabled and scale_start_mode_value == 1)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "custom_scale_y"), scale_react_enabled and scale_start_mode_value == 1)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_left_enabled"), scale_react_enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_right_enabled"), scale_react_enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_smoothing"), scale_react_enabled)
      -- Make non-uniform scale controls visible when appropriate
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_click_left_x"), scale_react_enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_click_left_y"), scale_react_enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_click_right_x"), scale_react_enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(scale_props, "scale_click_right_y"), scale_react_enabled)
      -- Apply enabled/disabled states based on checkboxes
    if scale_react_enabled then
      obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_left_x"), left_enabled)
      obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_left_y"), left_enabled)
      obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_right_x"), right_enabled)
      obs.obs_property_set_enabled(obs.obs_properties_get(scale_props, "scale_click_right_y"), right_enabled)
    end
  end

  return p
end

-- Set default settings on first load
function script_defaults(settings)
  -- Default update interval (ms)
  obs.obs_data_set_default_int(settings, "update_interval_ms", 10)  -- Default checkboxes off
  obs.obs_data_set_default_bool(settings, "position_react", false)
  obs.obs_data_set_default_bool(settings, "scale_react", false)
  obs.obs_data_set_default_bool(settings, "scale_left_enabled", true)
  obs.obs_data_set_default_bool(settings, "scale_right_enabled", true)
  obs.obs_data_set_default_bool(settings, "wiggle", false)  -- Default smoothing factors to 1.0
  
  -- Default wiggle method (0 = Pre-computed, 1 = Real-time)
  obs.obs_data_set_default_int(settings, "wiggle_method", 0)
  
  obs.obs_data_set_default_double(settings, "smoothing", 1.0)
  obs.obs_data_set_default_double(settings, "scale_smoothing", 1.0)
  -- Default wiggle extras
  obs.obs_data_set_default_int(settings, "wiggle_pos_amp_x", 0)
  obs.obs_data_set_default_int(settings, "wiggle_pos_amp_y", 0)
  obs.obs_data_set_default_double(settings, "wiggle_pos_speed", 1.0)
  obs.obs_data_set_default_double(settings, "wiggle_scale_amp", 0.0)
  obs.obs_data_set_default_double(settings, "wiggle_scale_speed", 1.0)
  
  -- Default CPU saver settings
  obs.obs_data_set_default_bool(settings, "cpu_saver", false)
  obs.obs_data_set_default_int(settings, "cpu_saver_threshold", 100)
  obs.obs_data_set_default_int(settings, "mouse_move_threshold", 5)  -- How many pixels mouse must move to trigger update when CPU saver is on
  
  -- Default inactivity timeout settings
  obs.obs_data_set_default_bool(settings, "use_inactivity_timeout", false)
  obs.obs_data_set_default_int(settings, "inactivity_timeout_ms", 1000)  -- Default 1 second
  -- Always use non-uniform scaling
  obs.obs_data_set_default_bool(settings, "non_uniform_scale", true)
  -- X and Y specific scale values
  obs.obs_data_set_default_double(settings, "scale_click_left_x", 1.2)
  obs.obs_data_set_default_double(settings, "scale_click_left_y", 1.2)
  obs.obs_data_set_default_double(settings, "scale_click_right_x", 0.8)
  obs.obs_data_set_default_double(settings, "scale_click_right_y", 0.8)
  -- Default uniform scale settings (kept for backward compatibility)
  obs.obs_data_set_default_double(settings, "scale_click_left", 1.2)
  obs.obs_data_set_default_double(settings, "scale_click_right", 0.8)
  -- Default scale start mode settings
  obs.obs_data_set_default_int(settings, "scale_start_mode", 0)
  obs.obs_data_set_default_double(settings, "custom_scale_x", 1.0)
  obs.obs_data_set_default_double(settings, "custom_scale_y", 1.0)
end

function script_update(s)
  my_settings = s
  scene_name         = obs.obs_data_get_string (s, "scene_name")
  source_name        = obs.obs_data_get_string (s, "source_name")
  move_range_x       = obs.obs_data_get_int    (s, "move_range_x")
  move_range_y       = obs.obs_data_get_int    (s, "move_range_y")
  rotation_amp       = obs.obs_data_get_double (s, "rotation_amp")  
  scale_click_left   = obs.obs_data_get_double (s, "scale_click_left")
  scale_click_right  = obs.obs_data_get_double (s, "scale_click_right")
    -- X and Y specific scale values
  scale_click_left_x  = obs.obs_data_get_double (s, "scale_click_left_x")
  scale_click_left_y  = obs.obs_data_get_double (s, "scale_click_left_y")
  scale_click_right_x = obs.obs_data_get_double (s, "scale_click_right_x")
  scale_click_right_y = obs.obs_data_get_double (s, "scale_click_right_y")
  
  scale_left_enabled = obs.obs_data_get_bool   (s, "scale_left_enabled")
  scale_right_enabled = obs.obs_data_get_bool  (s, "scale_right_enabled")
  update_interval_ms = obs.obs_data_get_int    (s, "update_interval_ms")
  start_mode         = obs.obs_data_get_int    (s, "start_mode")
  start_x            = obs.obs_data_get_int    (s, "start_x")
  start_y            = obs.obs_data_get_int    (s, "start_y")
  smoothing          = obs.obs_data_get_double (s, "smoothing")
  position_react      = obs.obs_data_get_bool   (s, "position_react")  scale_react         = obs.obs_data_get_bool   (s, "scale_react")
  wiggle              = obs.obs_data_get_bool   (s, "wiggle")
  scale_smoothing     = obs.obs_data_get_double (s, "scale_smoothing")
  rotation_speed      = obs.obs_data_get_double (s, "rotation_speed")
  wiggle_pos_amp_x    = obs.obs_data_get_int    (s, "wiggle_pos_amp_x")
  wiggle_pos_amp_y    = obs.obs_data_get_int    (s, "wiggle_pos_amp_y")  wiggle_pos_speed    = obs.obs_data_get_double (s, "wiggle_pos_speed")
  wiggle_scale_amp    = obs.obs_data_get_double (s, "wiggle_scale_amp")  
  wiggle_scale_speed  = obs.obs_data_get_double (s, "wiggle_scale_speed")
  
  -- Get wiggle method
  wiggle_method        = obs.obs_data_get_int    (s, "wiggle_method")
  
  -- CPU saver settings
  is_cpu_saver_enabled = obs.obs_data_get_bool(s, "cpu_saver")
  cpu_saver_threshold_ms = obs.obs_data_get_int(s, "cpu_saver_threshold")
  mouse_move_threshold = obs.obs_data_get_int(s, "mouse_move_threshold")
  
  -- Inactivity timeout settings
  use_inactivity_timeout = obs.obs_data_get_bool(s, "use_inactivity_timeout")
  inactivity_timeout_ms = obs.obs_data_get_int(s, "inactivity_timeout_ms")
  
  -- Reset inactivity tracking when settings change
  last_mouse_movement_time = os.clock() * 1000
  is_inactivity_timeout_reached = false
  non_uniform_scale = obs.obs_data_get_bool(s, "non_uniform_scale")
  scale_start_mode = obs.obs_data_get_int(s, "scale_start_mode")
  custom_scale_x = obs.obs_data_get_double(s, "custom_scale_x")
  custom_scale_y = obs.obs_data_get_double(s, "custom_scale_y")
  
  -- Reset only position state when position or scene/source/start settings change
  if scene_name ~= prev_scene_name
     or source_name ~= prev_source_name
     or start_mode ~= prev_start_mode
     or start_x ~= prev_start_x
     or start_y ~= prev_start_y
     or position_react ~= prev_position_react then
    base_pos_x, base_pos_y = nil, nil
    cur_pos_x, cur_pos_y = nil, nil
    frame = 0
  end    -- Reset rotation and scale only when scene or source changes, not when toggles change
  if scene_name ~= prev_scene_name or source_name ~= prev_source_name then
    cur_rot = nil
    cur_scale = nil
    base_scale = nil
    base_rot = nil
    base_scale_x = nil
    base_scale_y = nil
    cur_scale_x = nil
    cur_scale_y = nil
    
    -- If the previous source was different, we'll check the current source's scales
    -- during process_scale on the next tick
  end
  
  -- Reset scale when the scale start mode or custom scale values change
  if scale_start_mode ~= prev_scale_start_mode or 
     custom_scale_x ~= prev_custom_scale_x or 
     custom_scale_y ~= prev_custom_scale_y then
    base_scale = nil
    base_scale_x = nil
    base_scale_y = nil
    cur_scale = nil
    cur_scale_x = nil
    cur_scale_y = nil
  end
  
  -- We don't reset rotation or scale when wiggle or scale_react toggles anymore  -- Store current settings for next update
  prev_scene_name = scene_name
  prev_source_name = source_name
  prev_start_mode = start_mode
  prev_start_x, prev_start_y = start_x, start_y
  prev_position_react = position_react
  prev_scale_react = scale_react
  prev_wiggle = wiggle
  prev_scale_start_mode = scale_start_mode
  prev_custom_scale_x, prev_custom_scale_y = custom_scale_x, custom_scale_y

  obs.timer_remove(on_tick)
  obs.timer_add(on_tick, update_interval_ms)
end

function script_load(s)
  script_update(s)
end

function on_tick()
  -- Error handling wrapper
  local status, err = pcall(function()
    local item = get_scene_item()
    if not item then return end

    local current_time = os.clock() * 1000 -- Convert to ms

    -- Check if we should enable CPU saver due to inactivity
    if is_cpu_saver_enabled and use_inactivity_timeout and not is_inactivity_timeout_reached then
      local time_since_last_mouse_move = current_time - last_mouse_movement_time
      
      if time_since_last_mouse_move >= inactivity_timeout_ms then
        is_inactivity_timeout_reached = true
      end
    end

    -- CPU saver: skip processing if it's been less than the threshold time and mouse hasn't moved
    if is_cpu_saver_enabled then
      local time_since_last_update = current_time - last_update_time
      
      -- Only update if sufficient time has passed or mouse has moved significantly
      -- When inactivity timeout is reached, always use CPU saver logic regardless of mouse movement
      if time_since_last_update < cpu_saver_threshold_ms and 
         (is_inactivity_timeout_reached or not has_mouse_moved_significantly()) then
        return
      end
      
      -- Update the last update time
      last_update_time = current_time
    end

    if base_pos_x == nil then
      if start_mode == 0 then
        local init = vec2()
        obs.obs_sceneitem_get_pos(item, init)
        base_pos_x, base_pos_y = init.x, init.y
      else
        base_pos_x, base_pos_y = start_x, start_y
      end
    end

    -- Precompute time
    local time = frame * update_interval_ms * 0.001

    -- Process position, rotation, and scale
    process_position(item, time)
    process_rotation(item, time)
    process_scale(item, time)

    frame = frame + 1
  end)
  
  if not status then
    -- Log the error but don't crash the script
    obs.script_log(obs.LOG_ERROR, "Error in on_tick: " .. tostring(err))
  end
end

-- Apply position effects
function process_position(item, time)
  local pos = vec2()
  if position_react then
    local mx, my = Platform.get_cursor_pos()
    local sw, sh = Platform.get_screen_size()
    local tx = ((mx/sw) - 0.5) * 2 * move_range_x + base_pos_x
    local ty = ((my/sh) - 0.5) * 2 * move_range_y + base_pos_y
    if cur_pos_x == nil then cur_pos_x, cur_pos_y = tx, ty end
    cur_pos_x = cur_pos_x + (tx - cur_pos_x) * smoothing
    cur_pos_y = cur_pos_y + (ty - cur_pos_y) * smoothing
  else
    if cur_pos_x == nil then
      local init = vec2()
      obs.obs_sceneitem_get_pos(item, init)
      cur_pos_x, cur_pos_y = init.x, init.y
    end
  end
  pos.x, pos.y = round(cur_pos_x), round(cur_pos_y)  if wiggle then
    if wiggle_method == 0 then -- Pre-computed (CPU Efficient)
      -- Use the pre-computed animation cycles for position wiggle
      local wiggle_values
      local success, result = pcall(function()
        return get_wiggle_values(time, wiggle_pos_speed, "position")
      end)
      
      if success then
        wiggle_values = result
        pos.x = pos.x + round(wiggle_values[1] * wiggle_pos_amp_x)
        pos.y = pos.y + round(wiggle_values[2] * wiggle_pos_amp_y)
      else
        -- Fallback to real-time calculation if lookup fails
        pos.x = pos.x + round(sin(time * wiggle_pos_speed * twopi) * wiggle_pos_amp_x)
        pos.y = pos.y + round(cos(time * wiggle_pos_speed * twopi) * wiggle_pos_amp_y)
      end
    else -- Real-time (Higher Quality)
      -- Use traditional sin/cos calculations
      pos.x = pos.x + round(sin(time * wiggle_pos_speed * twopi) * wiggle_pos_amp_x)
      pos.y = pos.y + round(cos(time * wiggle_pos_speed * twopi) * wiggle_pos_amp_y)
    end
  end
  obs_set_pos(item, pos)
end

-- Apply rotation effects
function process_rotation(item, time)
  local rot = 0
  if wiggle then
    -- Get the base rotation value if we don't have it
    if base_rot == nil then
      base_rot = obs_get_rot(item) -- Get current rotation from the item
    end
    
    -- Calculate the wiggle offset based on selected method
    local wiggle_offset
    if wiggle_method == 0 then -- Pre-computed (CPU Efficient)
      local success, result = pcall(function()
        return get_wiggle_values(time, rotation_speed, "rotation") * rotation_amp
      end)
      
      if success then
        wiggle_offset = result
      else
        -- Fallback to real-time calculation if lookup fails
        wiggle_offset = sin(time * rotation_speed * twopi) * rotation_amp
      end
    else -- Real-time (Higher Quality)
      wiggle_offset = sin(time * rotation_speed * twopi) * rotation_amp
    end
    
    -- Apply wiggle effect on top of base rotation
    rot = base_rot + wiggle_offset
  else
    if cur_rot == nil then
      cur_rot = obs_get_rot(item) -- Get current rotation from the item
    end
    -- When wiggle is off, maintain the current rotation
    rot = cur_rot
  end
  obs_set_rot(item, rot)
end

-- Apply scale effects
function process_scale(item, time)
  -- Always use non-uniform scaling
  process_non_uniform_scale(item, time)
end

-- Handle uniform scaling (same value for X and Y)
function process_uniform_scale(item, time)
  local scale_val
  if scale_react then
    -- Get the base scale value
    if cur_scale == nil then
      -- Get the current scale from the item
      local init_scale = vec2()
      obs_get_scale(item, init_scale)
      -- Use x value for uniform scaling
      cur_scale = init_scale.x
    end
      
    -- Apply scale reaction based on mouse clicks
    local target
    if Platform.left_pressed() and scale_left_enabled then
      target = scale_click_left
    elseif Platform.right_pressed() and scale_right_enabled then
      target = scale_click_right
    else
      -- Get the original scale if we don't have it
      if base_scale == nil then
        if scale_start_mode == 0 then
          -- Use current source scale
          local init_scale = vec2()
          obs_get_scale(item, init_scale)
          base_scale = init_scale.x
        else
          -- Use custom scale
          base_scale = custom_scale_x
        end
      end
      target = base_scale
    end
    
    -- Apply smoothing
    cur_scale = cur_scale + (target - cur_scale) * scale_smoothing
    scale_val = cur_scale
  else
    if cur_scale == nil then
      -- Get the current scale from the item
      local init_scale = vec2()
      obs_get_scale(item, init_scale)
      -- Use x value for uniform scaling
      cur_scale = init_scale.x
    end
    scale_val = cur_scale
  end
  
  if wiggle and wiggle_scale_amp > 0 then
    scale_val = scale_val + sin(time * wiggle_scale_speed * twopi) * wiggle_scale_amp
  end
  
  local sc = vec2()
  sc.x, sc.y = scale_val, scale_val
  obs_set_scale(item, sc)
end

-- Handle non-uniform scaling (separate X and Y values)
function process_non_uniform_scale(item, time)
  -- Initialize scale components if not already done
  if cur_scale_x == nil or cur_scale_y == nil then
    local init_scale = vec2()
    obs_get_scale(item, init_scale)
    cur_scale_x = init_scale.x
    cur_scale_y = init_scale.y
  end
  
  if base_scale_x == nil or base_scale_y == nil then
    if scale_start_mode == 0 then
      -- Use current source scale
      local init_scale = vec2()
      obs_get_scale(item, init_scale)
      base_scale_x = init_scale.x
      base_scale_y = init_scale.y
    else
      -- Use custom scale
      base_scale_x = custom_scale_x
      base_scale_y = custom_scale_y
    end
  end
  
  local scale_x, scale_y = cur_scale_x, cur_scale_y
  
  if scale_react then
    -- Handle mouse button reactions for X and Y separately
    local target_x, target_y
    
    if Platform.left_pressed() and scale_left_enabled then
      -- Apply X and Y specific scales when left button is pressed
      target_x = scale_click_left_x
      target_y = scale_click_left_y
    elseif Platform.right_pressed() and scale_right_enabled then
      -- Apply X and Y specific scales when right button is pressed
      target_x = scale_click_right_x
      target_y = scale_click_right_y
    else
      -- No clicks, return to base scales
      target_x = base_scale_x
      target_y = base_scale_y
    end
    
    -- Apply smoothing to X and Y independently
    cur_scale_x = cur_scale_x + (target_x - cur_scale_x) * scale_smoothing
    cur_scale_y = cur_scale_y + (target_y - cur_scale_y) * scale_smoothing
    
    scale_x = cur_scale_x
    scale_y = cur_scale_y
  end  -- Apply wiggle to both X and Y if enabled
  if wiggle and wiggle_scale_amp > 0 then
    if wiggle_method == 0 then -- Pre-computed (CPU Efficient)
      -- Use the pre-computed animation cycles for scale wiggle
      local success, wiggle_values = pcall(function()
        return get_wiggle_values(time, wiggle_scale_speed, "scale")
      end)
      
      if success then
        -- Apply pre-computed values
        local wiggle_offset_x = wiggle_values[1] * wiggle_scale_amp
        scale_x = scale_x + wiggle_offset_x
        
        local wiggle_offset_y = wiggle_values[2] * wiggle_scale_amp
        scale_y = scale_y + wiggle_offset_y
      else
        -- Fallback to real-time calculation if lookup fails
        local wiggle_offset_x = sin(time * wiggle_scale_speed * twopi) * wiggle_scale_amp
        scale_x = scale_x + wiggle_offset_x
        
        local wiggle_offset_y = cos(time * wiggle_scale_speed * twopi) * wiggle_scale_amp
        scale_y = scale_y + wiggle_offset_y
      end
    else -- Real-time (Higher Quality)
      -- Use sine for X wiggle
      local wiggle_offset_x = sin(time * wiggle_scale_speed * twopi) * wiggle_scale_amp
      scale_x = scale_x + wiggle_offset_x
      
      -- Use cosine for Y wiggle (phase shifted) to create elliptical motion
      local wiggle_offset_y = cos(time * wiggle_scale_speed * twopi) * wiggle_scale_amp
      scale_y = scale_y + wiggle_offset_y
    end
  end
    -- Apply the new scales
  local sc = vec2()
  sc.x, sc.y = scale_x, scale_y
  obs_set_scale(item, sc)
end
