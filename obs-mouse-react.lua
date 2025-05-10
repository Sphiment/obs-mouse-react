-- mouse_reactor_crossplatform.lua
-- Cross-platform OBS script: moves, wiggles & scales a source based on your mouse
-- Supports Windows, Linux (X11), and macOS via a unified Platform module

obs = obslua

-- ─── Platform helper module ─────────────────────────────────────────────────
local Platform = {}
local ffi = require("ffi")
local bit = require("bit")

if ffi.os == "Windows" then
  ffi.cdef[[
    typedef struct { long x; long y; } POINT;
    bool GetCursorPos(POINT *lpPoint);
    short GetAsyncKeyState(int vKey);
    int   GetSystemMetrics(int nIndex);
  ]]
  local lib = ffi.load("user32")
  function Platform.get_cursor_pos()
    local pt = ffi.new("POINT")
    lib.GetCursorPos(pt)
    return pt.x, pt.y
  end
  function Platform.left_pressed()
    return bit.band(lib.GetAsyncKeyState(0x01), 0x8000) ~= 0
  end
  function Platform.right_pressed()
    return bit.band(lib.GetAsyncKeyState(0x02), 0x8000) ~= 0
  end
  function Platform.get_screen_size()
    return lib.GetSystemMetrics(0), lib.GetSystemMetrics(1)
  end

elseif ffi.os == "Linux" then
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
  function Platform.get_cursor_pos()
    local root_ret, child_ret = ffi.new("Window[1]"), ffi.new("Window[1]")
    local rx, ry = ffi.new("int[1]"), ffi.new("int[1]")
    local wx, wy = ffi.new("int[1]"), ffi.new("int[1]")
    local mask = ffi.new("unsigned[1]")
    lib.XQueryPointer(dpy, root, root_ret, child_ret, rx, ry, wx, wy, mask)
    return rx[0], ry[0]
  end
  function Platform.left_pressed()
    local mask = ffi.new("unsigned[1]")
    lib.XQueryPointer(dpy, root, nil, nil, nil, nil, nil, nil, mask)
    return bit.band(mask[0], 1) ~= 0
  end
  function Platform.right_pressed()
    local mask = ffi.new("unsigned[1]")
    lib.XQueryPointer(dpy, root, nil, nil, nil, nil, nil, nil, mask)
    return bit.band(mask[0], 2) ~= 0
  end
  function Platform.get_screen_size()
    local screen = lib.XDefaultScreen(dpy)
    return lib.XDisplayWidth(dpy, screen), lib.XDisplayHeight(dpy, screen)
  end

elseif ffi.os == "OSX" then
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
  function Platform.get_cursor_pos()
    local ev = ffi.C.CGEventCreate(nil)
    local pt = ffi.C.CGEventGetLocation(ev)
    return pt.x, pt.y
  end
  function Platform.left_pressed()
    return ffi.C.CGEventSourceButtonState(ffi.C.kCGEventSourceStateHIDSystemState, ffi.C.kCGMouseButtonLeft) == 1
  end
  function Platform.right_pressed()
    return ffi.C.CGEventSourceButtonState(ffi.C.kCGEventSourceStateHIDSystemState, ffi.C.kCGMouseButtonRight) == 1
  end
  function Platform.get_screen_size()
    local d = ffi.C.CGMainDisplayID()
    return ffi.C.CGDisplayPixelsWide(d), ffi.C.CGDisplayPixelsHigh(d)
  end

else
  error("Unsupported OS: " .. ffi.os)
end

-- ─── User‐configurable settings ────────────────────────────────────────────────
scene_name          = ""
source_name         = ""
move_range_x        = 200
move_range_y        = 100
rotation_amp        = 10.0
scale_click_left    = 0.8
scale_click_right   = 1.2
update_interval_ms  = 20
start_mode          = 0
start_x             = 0
start_y             = 0
smoothing           = 0.2
-- ──────────────────────────────────────────────────────────────────────────────

-- Internal state
frame       = 0
base_pos_x  = nil
base_pos_y  = nil
cur_pos_x   = nil
cur_pos_y   = nil
cur_rot     = nil
cur_scale   = nil

function script_description()
  return ([[Cross-platform mouse reactor for OBS:
• Windows, Linux (X11), macOS support
• Follow mouse X/Y
• Wiggle rotation
• Scale on clicks
• Optional custom start position
• Smoothing]])
end

function script_properties()
  local p = obs.obs_properties_create()
  obs.obs_properties_add_text   (p, "scene_name",         "Scene Name",               obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_text   (p, "source_name",        "Source Name",              obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_int    (p, "move_range_x",       "Movement Range X (px)",    0, 1000, 1)
  obs.obs_properties_add_int    (p, "move_range_y",       "Movement Range Y (px)",    0, 1000, 1)
  obs.obs_properties_add_float  (p, "rotation_amp",       "Rotation Amplitude (°)",   0.0, 180.0, 1.0)
  obs.obs_properties_add_float  (p, "scale_click_left",   "Scale on Left-Click",      0.0, 10.0, 0.01)
  obs.obs_properties_add_float  (p, "scale_click_right",  "Scale on Right-Click",     0.0, 10.0, 0.01)
  obs.obs_properties_add_int    (p, "update_interval_ms","Update Interval (ms)",     1, 1000, 1)
  local m = obs.obs_properties_add_list(p,
    "start_mode", "Start Mode",
    obs.OBS_COMBO_TYPE_LIST,
    obs.OBS_COMBO_FORMAT_INT)
  obs.obs_property_list_add_int(m, "Current Position", 0)
  obs.obs_property_list_add_int(m, "Custom Position",  1)
  obs.obs_properties_add_int(p, "start_x", "Start X (px)", -10000, 10000, 1)
  obs.obs_properties_add_int(p, "start_y", "Start Y (px)", -10000, 10000, 1)
  obs.obs_properties_add_float(p, "smoothing", "Smoothing Factor (0–1)", 0.0, 1.0, 0.01)
  return p
end

function script_update(s)
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

  base_pos_x, base_pos_y = nil, nil
  cur_pos_x, cur_pos_y   = nil, nil
  cur_rot                = nil
  cur_scale              = nil

  obs.timer_remove(on_tick)
  obs.timer_add(on_tick, update_interval_ms)
end

function script_load(s)
  script_update(s)
end

function on_tick()
  local src = obs.obs_get_source_by_name(scene_name)
  if not src then return end
  local scn = obs.obs_scene_from_source(src)
  obs.obs_source_release(src)
  local item = obs.obs_scene_find_source(scn, source_name)
  if not item then return end

  if base_pos_x == nil then
    if start_mode == 0 then
      local init = obs.vec2()
      obs.obs_sceneitem_get_pos(item, init)
      base_pos_x, base_pos_y = init.x, init.y
    else
      base_pos_x, base_pos_y = start_x, start_y
    end
  end

  local mx, my = Platform.get_cursor_pos()
  local sw, sh = Platform.get_screen_size()
  local tx = ((mx/sw)-0.5)*2*move_range_x + base_pos_x
  local ty = ((my/sh)-0.5)*2*move_range_y + base_pos_y
  local trot = math.sin(frame/10.0)*rotation_amp
  local tscale = Platform.left_pressed() and scale_click_left
                 or Platform.right_pressed() and scale_click_right
                 or 1.0

  if cur_pos_x == nil then cur_pos_x,cur_pos_y=tx,ty end
  if cur_rot   == nil then cur_rot   = trot end
  if cur_scale == nil then cur_scale = tscale end

  cur_pos_x = cur_pos_x + (tx      - cur_pos_x ) * smoothing
  cur_pos_y = cur_pos_y + (ty      - cur_pos_y ) * smoothing
  cur_rot   = cur_rot   + (trot    - cur_rot   ) * smoothing
  cur_scale = cur_scale + (tscale  - cur_scale ) * smoothing

  local pos = obs.vec2()
  pos.x, pos.y = math.floor(cur_pos_x+0.5), math.floor(cur_pos_y+0.5)
  obs.obs_sceneitem_set_pos(item, pos)
  obs.obs_sceneitem_set_rot(item, cur_rot)
  local sc = obs.vec2() sc.x, sc.y = cur_scale, cur_scale
  obs.obs_sceneitem_set_scale(item, sc)

  frame = frame + 1
end
