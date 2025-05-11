-- mouse_reactor_crossplatform.lua
-- Cross-platform OBS script: moves, wiggles & scales a source based on your mouse
-- Supports Windows, Linux (X11), and macOS via a unified Platform module

obs = obslua

-- Cache math functions and constants locally for performance
local sin, cos, floor = math.sin, math.cos, math.floor
local twopi = 2 * math.pi
local function round(x) return floor(x + 0.5) end
local vec2 = obs.vec2

-- Cache functions and constants for performance
local sin, cos, floor = math.sin, math.cos, math.floor
local twopi = math.pi * 2
local round = function(x) return floor(x + 0.5) end
local vec2 = obs.vec2
local obs_get_source = obs.obs_get_source_by_name
local obs_source_release = obs.obs_source_release
local obs_scene_from_source = obs.obs_scene_from_source
local obs_scene_find_source = obs.obs_scene_find_source
local obs_timer_remove, obs_timer_add = obs.timer_remove, obs.timer_add
local obs_set_pos = obs.obs_sceneitem_set_pos
local obs_set_rot = obs.obs_sceneitem_set_rot
local obs_set_scale = obs.obs_sceneitem_set_scale

-- ─── Platform helper module ─────────────────────────────────────────────────
local ffi = require("ffi")
local bit = require("bit")

-- Constants for magic numbers
local LEFT_MOUSE_BUTTON = 0x01
local RIGHT_MOUSE_BUTTON = 0x02
local KEY_PRESSED_MASK = 0x8000

-- Abstract platform-specific logic into a cleaner interface
local function initialize_platform()
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
      end
    }
  else
    error("Unsupported OS: " .. ffi.os)
  end
end

-- Initialize platform
local Platform = initialize_platform()

-- Internal state
frame       = 0
base_pos_x  = nil
base_pos_y  = nil
cur_pos_x   = nil
cur_pos_y   = nil
cur_rot     = nil
cur_scale   = nil

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

function script_description()
  return "React to mouse and wiggle (:"
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
  obs.obs_properties_add_group(p, "position_react", "Position React", obs.OBS_GROUP_CHECKABLE, pos_props)

  -- Scale React group
  local scale_props = obs.obs_properties_create()
  obs.obs_properties_add_float(scale_props, "scale_click_left", "Scale on Left-Click", 0.0, 10.0, 0.01)
  obs.obs_properties_add_float(scale_props, "scale_click_right", "Scale on Right-Click", 0.0, 10.0, 0.01)
  obs.obs_properties_add_float_slider(scale_props, "scale_smoothing", "Smoothing Factor (Scale)", 0.0, 1.0, 0.01)
  obs.obs_properties_add_group(p, "scale_react", "Scale React", obs.OBS_GROUP_CHECKABLE, scale_props)

  -- Wiggle group
  local wig_props = obs.obs_properties_create()
  obs.obs_properties_add_float(wig_props, "rotation_amp", "Rotation Amplitude (°)", 0.0, 180.0, 1.0)
  obs.obs_properties_add_float(wig_props, "rotation_speed", "Rotations per Second", 0.0, 10.0, 0.1)
  obs.obs_properties_add_float_slider(wig_props, "rotation_smoothing", "Smoothing Factor (Rotation)", 0.0, 1.0, 0.01)
  obs.obs_properties_add_int(wig_props, "wiggle_pos_amp_x", "Position Wiggle Amp X (px)", 0, 1000, 1)
  obs.obs_properties_add_int(wig_props, "wiggle_pos_amp_y", "Position Wiggle Amp Y (px)", 0, 1000, 1)
  obs.obs_properties_add_float(wig_props, "wiggle_pos_speed", "Position Wiggle Speed (Hz)", 0.0, 10.0, 0.1)
  obs.obs_properties_add_float_slider(wig_props, "wiggle_pos_smoothing", "Position Wiggle Smoothing", 0.0, 1.0, 0.01)
  obs.obs_properties_add_float(wig_props, "wiggle_scale_amp", "Scale Wiggle Amp", 0.0, 10.0, 0.1)
  obs.obs_properties_add_float(wig_props, "wiggle_scale_speed", "Scale Wiggle Speed (Hz)", 0.0, 10.0, 0.1)
  obs.obs_properties_add_float_slider(wig_props, "wiggle_scale_smoothing", "Scale Wiggle Smoothing", 0.0, 1.0, 0.01)
  obs.obs_properties_add_group(p, "wiggle", "Wiggle", obs.OBS_GROUP_CHECKABLE, wig_props)

  -- Update Interval
  obs.obs_properties_add_int(p, "update_interval_ms", "Update Interval (ms)", 1, 1000, 1)

  -- Visibility Callbacks
  obs.obs_property_set_modified_callback(position_react, function(props, property, settings)
    local enabled = obs.obs_data_get_bool(settings, "position_react")
    obs.obs_property_set_visible(obs.obs_properties_get(props, "start_mode"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "start_x"), enabled and obs.obs_data_get_int(settings, "start_mode") == 1)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "start_y"), enabled and obs.obs_data_get_int(settings, "start_mode") == 1)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "move_range_x"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "move_range_y"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "smoothing"), enabled)
    return true
  end)

  obs.obs_property_set_modified_callback(scale_react, function(props, property, settings)
    local enabled = obs.obs_data_get_bool(settings, "scale_react")
    obs.obs_property_set_visible(obs.obs_properties_get(props, "scale_click_left"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "scale_click_right"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "scale_smoothing"), enabled)
    return true
  end)

  obs.obs_property_set_modified_callback(wiggle, function(props, property, settings)
    local enabled = obs.obs_data_get_bool(settings, "wiggle")
    obs.obs_property_set_visible(obs.obs_properties_get(props, "rotation_amp"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "rotation_speed"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "rotation_smoothing"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "wiggle_pos_amp_x"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "wiggle_pos_amp_y"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "wiggle_pos_speed"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "wiggle_pos_smoothing"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "wiggle_scale_amp"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "wiggle_scale_speed"), enabled)
    obs.obs_property_set_visible(obs.obs_properties_get(props, "wiggle_scale_smoothing"), enabled)
    return true
  end)

  -- Initialize visibility based on current settings
  obs.obs_properties_apply_settings(p, my_settings)

  return p
end

-- Set default settings on first load
function script_defaults(settings)
  -- Default update interval (ms)
  obs.obs_data_set_default_int(settings, "update_interval_ms", 10)
  -- Default checkboxes off
  obs.obs_data_set_default_bool(settings, "position_react", false)
  obs.obs_data_set_default_bool(settings, "scale_react", false)
  obs.obs_data_set_default_bool(settings, "wiggle", false)
  -- Default smoothing factors to 1.0
  obs.obs_data_set_default_double(settings, "smoothing", 1.0)
  obs.obs_data_set_default_double(settings, "scale_smoothing", 1.0)
  obs.obs_data_set_default_double(settings, "rotation_smoothing", 1.0)
  -- Default wiggle extras
  obs.obs_data_set_default_int(settings, "wiggle_pos_amp_x", 0)
  obs.obs_data_set_default_int(settings, "wiggle_pos_amp_y", 0)
  obs.obs_data_set_default_double(settings, "wiggle_pos_speed", 1.0)
  obs.obs_data_set_default_double(settings, "wiggle_pos_smoothing", 1.0)
  obs.obs_data_set_default_double(settings, "wiggle_scale_amp", 0.0)
  obs.obs_data_set_default_double(settings, "wiggle_scale_speed", 1.0)
  obs.obs_data_set_default_double(settings, "wiggle_scale_smoothing", 1.0)
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
  update_interval_ms = obs.obs_data_get_int    (s, "update_interval_ms")
  start_mode         = obs.obs_data_get_int    (s, "start_mode")
  start_x            = obs.obs_data_get_int    (s, "start_x")
  start_y            = obs.obs_data_get_int    (s, "start_y")
  smoothing          = obs.obs_data_get_double (s, "smoothing")
  position_react      = obs.obs_data_get_bool   (s, "position_react")
  scale_react         = obs.obs_data_get_bool   (s, "scale_react")
  wiggle              = obs.obs_data_get_bool   (s, "wiggle")
  scale_smoothing     = obs.obs_data_get_double (s, "scale_smoothing")
  rotation_speed      = obs.obs_data_get_double (s, "rotation_speed")
  rotation_smoothing  = obs.obs_data_get_double (s, "rotation_smoothing")
  wiggle_pos_amp_x    = obs.obs_data_get_int    (s, "wiggle_pos_amp_x")
  wiggle_pos_amp_y    = obs.obs_data_get_int    (s, "wiggle_pos_amp_y")
  wiggle_pos_speed    = obs.obs_data_get_double (s, "wiggle_pos_speed")
  wiggle_pos_smoothing = obs.obs_data_get_double(s, "wiggle_pos_smoothing")
  wiggle_scale_amp    = obs.obs_data_get_double (s, "wiggle_scale_amp")
  wiggle_scale_speed  = obs.obs_data_get_double (s, "wiggle_scale_speed")
  wiggle_scale_smoothing = obs.obs_data_get_double(s, "wiggle_scale_smoothing")

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
  end

  -- Reset rotation state only when wiggle toggles
  if wiggle ~= prev_wiggle then
    cur_rot = nil
  end

  -- Reset scale state only when scale reaction toggles
  if scale_react ~= prev_scale_react then
    cur_scale = nil
  end

  -- Store current settings for next update
  prev_scene_name = scene_name
  prev_source_name = source_name
  prev_start_mode = start_mode
  prev_start_x, prev_start_y = start_x, start_y
  prev_position_react = position_react
  prev_scale_react = scale_react
  prev_wiggle = wiggle

  obs.timer_remove(on_tick)
  obs.timer_add(on_tick, update_interval_ms)
end

function script_load(s)
  script_update(s)
end

function on_tick()
  local src = obs_get_source(scene_name)
  if not src then return end
  local scn = obs_scene_from_source(src)
  obs_source_release(src)
  local item = obs_scene_find_source(scn, source_name)
  if not item then return end

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

  -- Position
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
  pos.x, pos.y = round(cur_pos_x), round(cur_pos_y)

  if wiggle then
    pos.x = pos.x + round(sin(time * wiggle_pos_speed * twopi) * wiggle_pos_amp_x)
    pos.y = pos.y + round(cos(time * wiggle_pos_speed * twopi) * wiggle_pos_amp_y)
  end
  obs_set_pos(item, pos)

  -- Rotation
  local rot = 0
  if wiggle then
    local target_rot = sin(time * rotation_speed * twopi) * rotation_amp
    if cur_rot == nil then cur_rot = target_rot end
    cur_rot = cur_rot + (target_rot - cur_rot) * rotation_smoothing
    rot = cur_rot
  else
    cur_rot = 0
  end
  obs_set_rot(item, rot)

  -- Scale
  local scale_val = 1.0
  if scale_react then
    local target = Platform.left_pressed() and scale_click_left or Platform.right_pressed() and scale_click_right or 1.0
    if cur_scale == nil then cur_scale = target end
    cur_scale = cur_scale + (target - cur_scale) * scale_smoothing
    scale_val = cur_scale
  end
  if wiggle and wiggle_scale_amp > 0 then
    scale_val = scale_val + sin(time * wiggle_scale_speed * twopi) * wiggle_scale_amp
  end
  local sc = vec2()
  sc.x, sc.y = scale_val, scale_val
  obs_set_scale(item, sc)

  frame = frame + 1
end
