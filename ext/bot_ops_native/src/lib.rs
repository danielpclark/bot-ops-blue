//! Bot Ops Blue native host.
//!
//! Ruby owns the data (store, comms, scene) and produces a frame as JSON:
//! a list of drawing commands, clickable hit regions and a drag region.
//! This crate opens a borderless egui window, paints the frame, routes
//! clicks back to Ruby, and executes the window commands Ruby asks for.
//!
//! Ruby API (see lib/bot_ops/native_host.rb):
//!   BotOps::Native.run(host, w, h, title, pos)   # blocks until the window closes
//!                                    # pos: "left,top" in screen points, or 
//!   host.poll    -> JSON String, or "" when nothing changed
//!   host.hit(id) -> String command ("quit", "fullscreen:toggle", ...) or ""
//!
//!   host.resize(w, h)          # window size in points changed; Ruby re-lays out
//!
//! Ruby lays out for a minimum design size. A larger window (fullscreen) is
//! zoomed until the design fits, and the spare points along the other axis are
//! handed to Ruby via host.resize so the panels stretch to fill the window.

use eframe::egui::{self, Align2, Color32, FontFamily, FontId, Key, Painter, Pos2, Rect, Rounding, Stroke, Vec2};
use rutie::{rubymodule, AnyObject, Integer, Object, RString, Thread};
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Deserialize, Default)]
struct Frame {
    #[serde(default)]
    cmds: Vec<Value>,
    #[serde(default)]
    hits: Vec<(f32, f32, f32, f32, u32)>,
    #[serde(default)]
    drag: Option<(f32, f32, f32, f32)>,
    #[serde(default)]
    resize: Option<(f32, f32, f32, f32)>,
    /// Where a drag pans the content (an open overlay's body).
    #[serde(default)]
    pan: Option<(f32, f32, f32, f32)>,
    /// Sessions waiting on the person (Dock badge).
    #[serde(default)]
    badge: u32,
}

struct HubApp {
    host: AnyObject,
    /// Named images Ruby can draw with "i" commands (see IMAGES).
    textures: HashMap<String, egui::TextureHandle>,
    frame: Frame,
    hits_rects: Vec<(Rect, u32)>,
    /// Minimum size Ruby lays out for, in points.
    design: Vec2,
    /// Size last reported to Ruby through host.resize.
    laid_out: Vec2,
    decorated: bool,
    /// BOT_OPS_FULLSCREEN=1: go fullscreen once the window is placed, so it
    /// fills the monitor it was positioned on rather than the main one.
    start_fullscreen: bool,
    /// Fullscreen state last reported to Ruby (host.fullscreen_changed).
    reported_fullscreen: Option<bool>,
    /// "minimize" from fullscreen: leave fullscreen first, then minimize
    /// once the exit animation has finished (macOS can't minimize a
    /// fullscreen window). Time (egui seconds) to minimize at, once known.
    minimize_pending: bool,
    minimize_at: Option<f64>,
    /// Consecutive polls in which Ruby raised.
    poll_failures: u32,
    /// Scrolling not yet sent to Ruby, in lines.
    scroll_lines: f32,
    /// Sideways scrolling not yet sent to Ruby, in points.
    scroll_x: f32,
    /// The Dock badge shown now.
    badge: u32,
    /// While dragging an overlay's body: the pointer position last sent.
    panning: Option<Pos2>,
    /// Monospace advance last reported to Ruby (thousandths of a point).
    mono_advance: Option<i64>,
    /// While the grip is held: window size minus pointer, in unzoomed points.
    resizing: Option<Vec2>,
    /// Focus last logged (BOT_OPS_DEBUG=1).
    last_focused: Option<bool>,
}

/// Images Ruby can draw by name, embedded at build time. lib/bot_ops/canvas.rb
/// reads the same files for SVG previews.
const IMAGES: &[(&str, &[u8])] = &[("logo", include_bytes!("../assets/logo.png"))];
const ICON_PNG: &[u8] = include_bytes!("../assets/icon.png");

/// The smallest window the resize grip allows, in points.
const MIN_SIZE: Vec2 = Vec2::new(768.0, 512.0);

const BACKGROUND: Color32 = Color32::from_rgb(5, 11, 20); // Theme::BG

/// BOT_OPS_DEBUG=1 logs presses, window commands and focus or fullscreen
/// changes to stderr, for chasing input problems.
fn debug() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| matches!(std::env::var("BOT_OPS_DEBUG").as_deref(), Ok("1") | Ok("true")))
}

// ---- helpers ---------------------------------------------------------------

fn num(v: &Value, i: usize) -> f32 {
    v.get(i).and_then(|x| x.as_f64()).unwrap_or(0.0) as f32
}

fn text(v: &Value, i: usize) -> &str {
    v.get(i).and_then(|x| x.as_str()).unwrap_or("")
}

fn color(v: &Value, i: usize) -> Option<Color32> {
    let c = v.get(i)?.as_array()?;
    if c.len() < 4 {
        return None;
    }
    let f = |j: usize| c[j].as_f64().unwrap_or(0.0);
    let a = (f(3).clamp(0.0, 1.0) * 255.0).round() as u8;
    Some(Color32::from_rgba_unmultiplied(f(0) as u8, f(1) as u8, f(2) as u8, a))
}

fn stroke(v: &Value, color_i: usize, width_i: usize) -> Stroke {
    match color(v, color_i) {
        Some(c) => Stroke::new(num(v, width_i).max(0.5), c),
        None => Stroke::NONE,
    }
}

fn wedge_mesh(cx: f32, cy: f32, r: f32, start_deg: f32, sweep_deg: f32, fill: Color32) -> egui::Shape {
    let mut mesh = egui::Mesh::default();
    let steps = ((sweep_deg.abs() / 4.0).ceil() as usize).max(2);
    let center = Pos2::new(cx, cy);
    let mut points = Vec::with_capacity(steps + 1);
    for i in 0..=steps {
        let a = (start_deg + sweep_deg * i as f32 / steps as f32).to_radians();
        points.push(Pos2::new(cx + r * a.cos(), cy + r * a.sin()));
    }
    let base = mesh.vertices.len() as u32;
    mesh.colored_vertex(center, fill);
    for p in &points {
        mesh.colored_vertex(*p, fill);
    }
    for i in 0..steps as u32 {
        mesh.add_triangle(base, base + 1 + i, base + 2 + i);
    }
    egui::Shape::mesh(mesh)
}

// Filled region between a polyline and a horizontal baseline (chart areas).
fn area_mesh(points: &[Pos2], base_y: f32, fill: Color32) -> egui::Shape {
    let mut mesh = egui::Mesh::default();
    for w in points.windows(2) {
        let (a, b) = (w[0], w[1]);
        let i = mesh.vertices.len() as u32;
        mesh.colored_vertex(a, fill);
        mesh.colored_vertex(b, fill);
        mesh.colored_vertex(Pos2::new(b.x, base_y), fill);
        mesh.colored_vertex(Pos2::new(a.x, base_y), fill);
        mesh.add_triangle(i, i + 1, i + 2);
        mesh.add_triangle(i, i + 2, i + 3);
    }
    egui::Shape::mesh(mesh)
}

fn install_fonts(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    let data = [
        ("Inter", &include_bytes!("../fonts/Inter-Regular.ttf")[..]),
        ("Inter-Medium", &include_bytes!("../fonts/Inter-Medium.ttf")[..]),
        ("Inter-SemiBold", &include_bytes!("../fonts/Inter-SemiBold.ttf")[..]),
        ("Inter-Bold", &include_bytes!("../fonts/Inter-Bold.ttf")[..]),
        ("Montserrat-ExtraBold", &include_bytes!("../fonts/Montserrat-ExtraBold.ttf")[..]),
        // Symbols Inter lacks (arrows, geometric shapes).
        ("DejaVuSans", &include_bytes!("../fonts/DejaVuSans.ttf")[..]),
        ("DejaVuSansMono", &include_bytes!("../fonts/DejaVuSansMono.ttf")[..]),
    ];
    for (name, bytes) in data {
        fonts.font_data.insert(name.to_owned(), egui::FontData::from_static(bytes));
    }
    let with_fallback = |name: &str| vec![name.to_owned(), "DejaVuSans".to_owned()];
    fonts.families.insert(FontFamily::Proportional, with_fallback("Inter"));
    fonts.families.insert(FontFamily::Monospace, vec!["DejaVuSansMono".to_owned(), "DejaVuSans".to_owned()]);
    for (family, name) in [("medium", "Inter-Medium"), ("semibold", "Inter-SemiBold"), ("bold", "Inter-Bold"),
                           ("display", "Montserrat-ExtraBold")] {
        fonts.families.insert(FontFamily::Name(family.into()), with_fallback(name));
    }
    ctx.set_fonts(fonts);
}

/// `a` blended toward `b` by t (0..1), unmultiplied.
fn lerp_color(a: [f32; 4], b: [f32; 4], t: f32) -> Color32 {
    let t = t.clamp(0.0, 1.0);
    let m = |i: usize| a[i] + (b[i] - a[i]) * t;
    Color32::from_rgba_unmultiplied(m(0) as u8, m(1) as u8, m(2) as u8, (m(3).clamp(0.0, 1.0) * 255.0).round() as u8)
}

fn color_parts(v: &Value, i: usize) -> Option<[f32; 4]> {
    let c = v.get(i)?.as_array()?;
    if c.len() < 4 {
        return None;
    }
    let f = |j: usize| c[j].as_f64().unwrap_or(0.0) as f32;
    Some([f(0), f(1), f(2), f(3)])
}

fn points(v: &Value, i: usize) -> Vec<Pos2> {
    v.get(i)
        .and_then(|p| p.as_array())
        .map(|arr| arr.iter().map(|p| Pos2::new(num(p, 0), num(p, 1))).collect())
        .unwrap_or_default()
}

/// A polygon filled with a linear gradient from `ca` at `from` to `cb` at
/// `to`, as a fan from `center` (its centroid unless given): convex, or at
/// least star-shaped around the centre. Vertex colours are exact for a
/// linear gradient; a ring of transparent vertices `feather` points outside
/// the edge anti-aliases it.
fn gradient_mesh(pts: &[Pos2], from: Pos2, to: Pos2, ca: [f32; 4], cb: [f32; 4], feather: f32,
                 center: Option<Pos2>) -> egui::Shape {
    let mut mesh = egui::Mesh::default();
    let n = pts.len();
    if n < 3 {
        return egui::Shape::Noop;
    }
    let axis = to - from;
    let len2 = axis.length_sq().max(1e-6);
    let at = |p: Pos2| lerp_color(ca, cb, (p - from).dot(axis) / len2);
    let clear = |p: Pos2| {
        let c = at(p);
        Color32::from_rgba_unmultiplied(c.r(), c.g(), c.b(), 0)
    };
    // Outward normals: flip if the polygon winds the other way.
    let area: f32 = (0..n).map(|i| { let (a, b) = (pts[i], pts[(i + 1) % n]); a.x * b.y - b.x * a.y }).sum();
    let sign = if area > 0.0 { 1.0 } else { -1.0 };
    let edge_normal = |a: Pos2, b: Pos2| { let d = (b - a).normalized(); Vec2::new(d.y, -d.x) * sign };
    let centroid = pts.iter().fold(Vec2::ZERO, |acc, p| acc + p.to_vec2()) / n as f32;
    let c = center.unwrap_or(centroid.to_pos2());
    mesh.colored_vertex(c, at(c));
    for p in pts {
        mesh.colored_vertex(*p, at(*p));
    }
    for i in 0..n as u32 {
        mesh.add_triangle(0, 1 + i, 1 + (i + 1) % n as u32);
    }
    let ring = mesh.vertices.len() as u32;
    for i in 0..n {
        let prev = pts[(i + n - 1) % n];
        let next = pts[(i + 1) % n];
        let normal = (edge_normal(prev, pts[i]) + edge_normal(pts[i], next)).normalized();
        let o = pts[i] + normal * feather;
        mesh.colored_vertex(o, clear(pts[i]));
    }
    for i in 0..n as u32 {
        let j = (i + 1) % n as u32;
        mesh.add_triangle(1 + i, 1 + j, ring + j);
        mesh.add_triangle(1 + i, ring + j, ring + i);
    }
    egui::Shape::mesh(mesh)
}

/// Filled region between a polyline and a horizontal baseline, fading from
/// `top` (at y = top_y) to `bottom` (at the baseline).
fn gradient_area_mesh(pts: &[Pos2], base_y: f32, top_y: f32, top: [f32; 4], bottom: [f32; 4]) -> egui::Shape {
    let mut mesh = egui::Mesh::default();
    let at = |y: f32| lerp_color(top, bottom, (y - top_y) / (base_y - top_y).max(1e-3));
    for w in pts.windows(2) {
        let (a, b) = (w[0], w[1]);
        let i = mesh.vertices.len() as u32;
        mesh.colored_vertex(a, at(a.y));
        mesh.colored_vertex(b, at(b.y));
        mesh.colored_vertex(Pos2::new(b.x, base_y), at(base_y));
        mesh.colored_vertex(Pos2::new(a.x, base_y), at(base_y));
        mesh.add_triangle(i, i + 1, i + 2);
        mesh.add_triangle(i, i + 2, i + 3);
    }
    egui::Shape::mesh(mesh)
}

// ---- images ----------------------------------------------------------------

fn decode_png(bytes: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let img = image::load_from_memory_with_format(bytes, image::ImageFormat::Png).ok()?.to_rgba8();
    Some((img.width(), img.height(), img.into_raw()))
}

fn load_textures(ctx: &egui::Context) -> HashMap<String, egui::TextureHandle> {
    IMAGES
        .iter()
        .filter_map(|(name, bytes)| {
            let (w, h, rgba) = decode_png(bytes)?;
            let img = egui::ColorImage::from_rgba_unmultiplied([w as usize, h as usize], &rgba);
            Some((name.to_string(), ctx.load_texture(*name, img, egui::TextureOptions::LINEAR)))
        })
        .collect()
}

// A texture mapped onto a disc (a triangle fan), for the round portrait.
fn image_circle_mesh(tex: egui::TextureId, c: Pos2, r: f32) -> egui::Shape {
    use egui::epaint::{Mesh, Vertex};
    let steps = 96u32;
    let mut mesh = Mesh::with_texture(tex);
    mesh.vertices.push(Vertex { pos: c, uv: egui::pos2(0.5, 0.5), color: Color32::WHITE });
    for i in 0..=steps {
        let (sin, cos) = (i as f32 / steps as f32 * std::f32::consts::TAU).sin_cos();
        mesh.vertices.push(Vertex {
            pos: Pos2::new(c.x + r * cos, c.y + r * sin),
            uv: egui::pos2(0.5 + 0.5 * cos, 0.5 + 0.5 * sin),
            color: Color32::WHITE,
        });
    }
    for i in 1..=steps {
        mesh.indices.extend_from_slice(&[0, i, i + 1]);
    }
    egui::Shape::mesh(mesh)
}

// ---- window placement --------------------------------------------------------

/// Moves the (still invisible) window so its top-left corner is at `left,
/// top`: global screen points, origin at the primary screen's top-left.
///
/// Done through AppKit rather than ViewportBuilder::with_position: egui-winit
/// 0.29 multiplies that position by its pixels_per_point (1.0 before the
/// window exists) and hands it to winit as *physical* pixels, which winit then
/// divides by the main screen's Retina factor, so the window first appeared at
/// half the coordinates, straddling the MacBook's screen and the external one.
#[cfg(target_os = "macos")]
fn place_window(cc: &eframe::CreationContext<'_>, left: f64, top: f64) {
    use objc2_app_kit::{NSScreen, NSView};
    use objc2_foundation::{MainThreadMarker, NSPoint};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let Some(mtm) = MainThreadMarker::new() else { return };
    let Ok(handle) = cc.window_handle() else { return };
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else { return };
    let view: &NSView = unsafe { appkit.ns_view.cast().as_ref() };
    let Some(window) = view.window() else { return };
    // AppKit's origin is the primary screen's bottom-left, with y going up.
    let Some(primary) = (unsafe { NSScreen::screens(mtm).firstObject() }) else { return };
    let primary_height = primary.frame().size.height;
    window.setFrameTopLeftPoint(NSPoint::new(left, primary_height - top));
}

/// Where the pointer is, in egui points, straight from AppKit.
///
/// Used for presses instead of the position egui was given: after
/// `toggleFullScreen` on a second display, winit hands egui the clicks in
/// screen coordinates (the NSEvent carries no window, so its location is
/// relative to the screen) until the window loses and regains focus, so
/// every click landed off by the display's origin and missed its target.
#[cfg(target_os = "macos")]
fn appkit_pointer(frame: &eframe::Frame, zoom: f32) -> Option<Pos2> {
    use objc2_app_kit::{NSEvent, NSView};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let handle = frame.window_handle().ok()?;
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else { return None };
    let view: &NSView = unsafe { appkit.ns_view.cast().as_ref() };
    let window = view.window()?;
    // AppKit's y runs up from the window's bottom; egui's down from the top.
    let in_window = window.convertPointFromScreen(unsafe { NSEvent::mouseLocation() });
    let height = view.frame().size.height;
    Some(Pos2::new(in_window.x as f32 / zoom, (height - in_window.y) as f32 / zoom))
}

// ---- Dock ------------------------------------------------------------------

/// Shows `count` on the Dock icon (nothing for 0) and, when it went up,
/// bounces the icon once: a session started waiting on the person.
#[cfg(target_os = "macos")]
fn show_waiting(count: u32, previous: u32) {
    use objc2_app_kit::{NSApplication, NSRequestUserAttentionType};
    use objc2_foundation::{MainThreadMarker, NSString};
    let Some(mtm) = MainThreadMarker::new() else { return };
    let app = NSApplication::sharedApplication(mtm);
    let label = (count > 0).then(|| NSString::from_str(&count.to_string()));
    unsafe { app.dockTile().setBadgeLabel(label.as_deref()) };
    if count > previous {
        app.requestUserAttention(NSRequestUserAttentionType::NSInformationalRequest);
    }
}

#[cfg(not(target_os = "macos"))]
fn show_waiting(_count: u32, _previous: u32) {}

// ---- snapshots ---------------------------------------------------------------

/// For checking the real rendering without screen-recording permission:
/// with BOT_OPS_SNAPSHOT_DIR set, creating <dir>/request makes the window
/// capture its own frame to <dir>/window.png. Off unless the variable is set.
fn snapshot(ctx: &egui::Context) {
    let Some(dir) = std::env::var_os("BOT_OPS_SNAPSHOT_DIR").map(std::path::PathBuf::from) else { return };
    if std::fs::remove_file(dir.join("request")).is_ok() {
        ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot);
    }
    ctx.input(|i| {
        for e in &i.raw.events {
            if let egui::Event::Screenshot { image, .. } = e {
                let [w, h] = image.size;
                let bytes: Vec<u8> = image.pixels.iter().flat_map(|c| c.to_srgba_unmultiplied()).collect();
                if let Some(img) = image::RgbaImage::from_raw(w as u32, h as u32, bytes) {
                    let tmp = dir.join("window.tmp.png");
                    if img.save(&tmp).is_ok() {
                        let _ = std::fs::rename(&tmp, dir.join("window.png"));
                    }
                }
            }
        }
    });
}

// ---- links -------------------------------------------------------------------

/// Opens a cloud session's page in the default browser. Only
/// https://claude.ai/code/<id> is accepted (Ruby checks the same), so a
/// frame can never make the dashboard open anything else.
fn open_session_url(url: &str) {
    let id = url.strip_prefix("https://claude.ai/code/").unwrap_or("");
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
        eprintln!("bot_ops_native: refusing to open {url:?}");
        return;
    }
    #[cfg(target_os = "macos")]
    let opener = std::process::Command::new("open").arg(url).spawn();
    #[cfg(target_os = "windows")]
    let opener = std::process::Command::new("cmd").args(["/C", "start", "", url]).spawn();
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let opener = std::process::Command::new("xdg-open").arg(url).spawn();
    if let Err(e) = opener {
        eprintln!("bot_ops_native: could not open {url}: {e}");
    }
}

// ---- app -------------------------------------------------------------------

fn is_fullscreen(ctx: &egui::Context) -> bool {
    ctx.input(|i| i.viewport().fullscreen.unwrap_or(false))
}

impl HubApp {
    /// Calls `host.<method>(*ints)` and returns its String result ("" for nil).
    /// The window loop runs without the GVL so Ruby's own threads (the probe,
    /// the collector) keep running; every touch of a Ruby object happens here,
    /// with the GVL re-acquired.
    fn call_host(&self, method: &str, ints: &[i64]) -> Result<String, ()> {
        let host = &self.host;
        Thread::call_with_gvl(|| {
            let args: Vec<AnyObject> = ints.iter().map(|&i| Integer::new(i).to_any_object()).collect();
            match host.protect_send(method, &args) {
                Ok(obj) => Ok(obj.try_convert_to::<RString>().map(|s| s.to_string()).unwrap_or_default()),
                Err(_) => Err(()),
            }
        })
    }

    /// Like call_host, with one String argument.
    fn call_host_text(&self, method: &str, text: &str) -> Result<String, ()> {
        let host = &self.host;
        Thread::call_with_gvl(|| match host.protect_send(method, &[RString::new_utf8(text).to_any_object()]) {
            Ok(obj) => Ok(obj.try_convert_to::<RString>().map(|s| s.to_string()).unwrap_or_default()),
            Err(_) => Err(()),
        })
    }

    fn poll_ruby(&mut self, ctx: &egui::Context) {
        match self.call_host("poll", &[]) {
            Ok(json) if json.is_empty() => self.poll_failures = 0,
            // Ruby was interrupted (Ctrl+C, TERM) during a callback.
            Ok(json) if json == "quit" => ctx.send_viewport_cmd(egui::ViewportCommand::Close),
            Ok(json) => match serde_json::from_str::<Frame>(&json) {
                Ok(frame) => {
                    self.poll_failures = 0;
                    if frame.badge != self.badge {
                        show_waiting(frame.badge, self.badge);
                        self.badge = frame.badge;
                    }
                    self.hits_rects = frame
                        .hits
                        .iter()
                        .map(|&(x, y, w, h, id)| (Rect::from_min_size(Pos2::new(x, y), Vec2::new(w, h)), id))
                        .collect();
                    self.frame = frame;
                }
                Err(e) => eprintln!("bot_ops_native: bad frame JSON: {e}"),
            },
            // Keep showing the last good frame; only a Ruby side that keeps
            // failing closes the window (NativeHost logs each exception).
            Err(()) => {
                self.poll_failures += 1;
                if self.poll_failures >= 20 {
                    eprintln!("bot_ops_native: Ruby raised in poll 20 times in a row; closing window");
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
                return;
            }
        }
    }

    /// A press at `pos`. `drag_origin` is where egui itself puts the pointer,
    /// so a pan or resize that follows measures its movement against egui's
    /// own later positions (see appkit_pointer).
    fn handle_press(&mut self, ctx: &egui::Context, pos: Pos2, drag_origin: Pos2) {
        if let Some((x, y, w, h)) = self.frame.pan {
            if Rect::from_min_size(Pos2::new(x, y), Vec2::new(w, h)).contains(pos) {
                self.panning = Some(drag_origin);
                return;
            }
        }
        let hit = self.hits_rects.iter().rev().find(|(r, _)| r.contains(pos)).map(|(_, id)| *id);
        if debug() {
            eprintln!("bot_ops_native: press at ({:.0}, {:.0}) hit={:?} fullscreen={} focused={:?} zoom={:.3} screen={:?} hits={}",
                      pos.x, pos.y, hit, is_fullscreen(ctx), ctx.input(|i| i.viewport().focused), ctx.zoom_factor(),
                      ctx.screen_rect().size(), self.hits_rects.len());
        }
        if let Some(id) = hit {
            match self.call_host("hit", &[id as i64]) {
                Ok(cmd) => self.window_command(ctx, &cmd),
                Err(()) => eprintln!("bot_ops_native: Ruby raised in hit"),
            }
            return;
        }
        if is_fullscreen(ctx) {
            return;
        }
        if let Some((x, y, w, h)) = self.frame.resize {
            if Rect::from_min_size(Pos2::new(x, y), Vec2::new(w, h)).contains(pos) {
                // Remember where in the corner it was grabbed, in unzoomed points.
                let zoom = ctx.zoom_factor();
                self.resizing = Some(ctx.screen_rect().size() * zoom - drag_origin.to_vec2() * zoom);
                return;
            }
        }
        if let Some((x, y, w, h)) = self.frame.drag {
            if Rect::from_min_size(Pos2::new(x, y), Vec2::new(w, h)).contains(pos) {
                ctx.send_viewport_cmd(egui::ViewportCommand::StartDrag);
            }
        }
    }

    // Toggles act on the window's real state, so they cannot drift out of sync
    // with it (e.g. after leaving fullscreen with Esc or the green button).
    fn window_command(&mut self, ctx: &egui::Context, cmd: &str) {
        if debug() {
            eprintln!("bot_ops_native: command {cmd:?} fullscreen={}", is_fullscreen(ctx));
        }
        match cmd {
            "quit" => ctx.send_viewport_cmd(egui::ViewportCommand::Close),
            cmd if cmd.starts_with("open:") => open_session_url(&cmd["open:".len()..]),
            "minimize" => {
                if is_fullscreen(ctx) {
                    self.minimize_pending = true;
                    ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(false));
                } else {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(true));
                }
            }
            "fullscreen:toggle" => ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(!is_fullscreen(ctx))),
            "decorations:toggle" => {
                self.decorated = !self.decorated;
                ctx.send_viewport_cmd(egui::ViewportCommand::Decorations(self.decorated));
            }
            _ => {}
        }
    }

    // Dragging the bottom-right grip: the window's size follows the pointer
    // (top-left stays put). winit can't start a native resize from a grip on
    // macOS, so this sets the size itself. Sizes are worked out in unzoomed
    // points because the zoom changes as the window does.
    fn handle_resize(&mut self, ctx: &egui::Context) {
        let over_grip = |p: Pos2| {
            self.frame.resize.map_or(false, |(x, y, w, h)| Rect::from_min_size(Pos2::new(x, y), Vec2::new(w, h)).contains(p))
        };
        if self.resizing.is_some() || ctx.input(|i| i.pointer.hover_pos()).map_or(false, over_grip) {
            ctx.set_cursor_icon(egui::CursorIcon::ResizeNwSe);
        }
        let Some(grab) = self.resizing else { return };
        if !ctx.input(|i| i.pointer.primary_down()) {
            self.resizing = None;
            return;
        }
        if let Some(p) = ctx.input(|i| i.pointer.latest_pos()) {
            let zoom = ctx.zoom_factor();
            let target = (p.to_vec2() * zoom + grab).max(MIN_SIZE);
            ctx.send_viewport_cmd(egui::ViewportCommand::InnerSize(target / zoom));
        }
    }

    // Tells Ruby the real width of a 10pt monospace character at the current
    // zoom (in thousandths of a point), averaged over 100 so pixel rounding
    // counts: wrapping text from a nominal 0.602em could overflow at some
    // window sizes.
    fn report_mono_advance(&mut self, ctx: &egui::Context) {
        let width = ctx.fonts(|f| {
            f.layout_no_wrap("0".repeat(100), FontId::new(10.0, FontFamily::Monospace), Color32::WHITE).size().x
        });
        let milli = (width * 10.0).round() as i64; // width / 100 chars * 1000
        if self.mono_advance != Some(milli) {
            self.mono_advance = Some(milli);
            if self.call_host("mono_advance", &[milli]).is_err() {
                eprintln!("bot_ops_native: Ruby raised in mono_advance");
            }
        }
    }

    // Dragging inside an overlay's body moves its text with the pointer
    // (sideways for long lines, and up and down), sent in whole points.
    fn handle_pan(&mut self, ctx: &egui::Context) {
        let Some(last) = self.panning else { return };
        if !ctx.input(|i| i.pointer.primary_down()) {
            self.panning = None;
            return;
        }
        let Some(now) = ctx.input(|i| i.pointer.latest_pos()) else { return };
        let moved = now - last;
        let (dx, dy) = (moved.x.round(), moved.y.round());
        if dx != 0.0 || dy != 0.0 {
            self.panning = Some(last + Vec2::new(dx, dy));
            if self.call_host("pan", &[-dx as i64, -dy as i64]).is_err() {
                eprintln!("bot_ops_native: Ruby raised in pan");
            }
        }
    }

    // Mouse wheel and trackpad scrolling, sent to Ruby in whole lines (it
    // scrolls an open detail overlay). egui's y is positive when scrolling up.
    fn handle_scroll(&mut self, ctx: &egui::Context) {
        let (mut dx, mut dy, shift) = ctx.input(|i| (i.raw_scroll_delta.x, i.raw_scroll_delta.y, i.modifiers.shift));
        if shift && dx == 0.0 {
            (dx, dy) = (dy, 0.0); // Shift + wheel scrolls sideways
        }
        if dx != 0.0 {
            self.scroll_x += -dx;
            let points = self.scroll_x.trunc();
            if points != 0.0 {
                self.scroll_x -= points;
                if self.call_host("pan", &[points as i64, 0]).is_err() {
                    eprintln!("bot_ops_native: Ruby raised in pan");
                }
            }
        }
        if dy == 0.0 {
            return;
        }
        self.scroll_lines += -dy / 16.0;
        let lines = self.scroll_lines.trunc();
        if lines != 0.0 {
            self.scroll_lines -= lines;
            if self.call_host("scroll", &[lines as i64]).is_err() {
                eprintln!("bot_ops_native: Ruby raised in scroll");
            }
        }
    }

    // Tells Ruby when fullscreen starts or ends (so the header's control can
    // show what it will do), and finishes a minimize that had to leave
    // fullscreen first.
    fn sync_window_state(&mut self, ctx: &egui::Context) {
        let fullscreen = is_fullscreen(ctx);
        if debug() {
            let focused = ctx.input(|i| i.viewport().focused);
            if self.last_focused != focused {
                self.last_focused = focused;
                eprintln!("bot_ops_native: focused={focused:?} fullscreen={fullscreen}");
            }
        }
        if self.reported_fullscreen != Some(fullscreen) {
            self.reported_fullscreen = Some(fullscreen);
            if debug() {
                eprintln!("bot_ops_native: fullscreen={fullscreen} screen={:?} zoom={:.3}", ctx.screen_rect().size(), ctx.zoom_factor());
            }
            if self.call_host("fullscreen_changed", &[fullscreen as i64]).is_err() {
                eprintln!("bot_ops_native: Ruby raised in fullscreen_changed");
            }
        }
        if self.minimize_pending && !fullscreen {
            let now = ctx.input(|i| i.time);
            let at = *self.minimize_at.get_or_insert(now + 0.8);
            if now >= at {
                self.minimize_pending = false;
                self.minimize_at = None;
                ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(true));
            } else {
                ctx.request_repaint_after(Duration::from_secs_f64(at - now));
            }
        }
    }

    // Esc goes to Ruby first (it closes an open detail overlay); otherwise it
    // leaves fullscreen. F11 or Ctrl+Cmd+F toggles fullscreen, as does the
    // header's fullscreen control.
    fn handle_keys(&mut self, ctx: &egui::Context) {
        let (esc, toggle) = ctx.input(|i| {
            let ctrl_cmd_f = i.modifiers.ctrl && i.modifiers.mac_cmd && i.key_pressed(Key::F);
            (i.key_pressed(Key::Escape), i.key_pressed(Key::F11) || ctrl_cmd_f)
        });
        let esc = esc && self.call_host("key", &[27]).map(|r| r != "handled").unwrap_or(true);
        // Navigation keys and typed text go to Ruby (search, session list).
        let (keys, typed) = ctx.input(|i| {
            let keys: Vec<i64> = [(Key::ArrowUp, 38), (Key::ArrowDown, 40), (Key::Enter, 13), (Key::Backspace, 8)]
                .iter()
                .filter(|(k, _)| i.key_pressed(*k))
                .map(|(_, code)| *code)
                .collect();
            let typed: String = i
                .events
                .iter()
                .filter_map(|e| if let egui::Event::Text(t) = e { Some(t.as_str()) } else { None })
                .collect();
            (keys, typed)
        });
        for code in keys {
            let _ = self.call_host("key", &[code]);
        }
        if !typed.is_empty() {
            let _ = self.call_host_text("text", &typed);
        }
        if esc && is_fullscreen(ctx) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(false));
        } else if toggle {
            self.window_command(ctx, "fullscreen:toggle");
        }
    }

    // Zooms until the design size fits the window, then tells Ruby the window
    // size in points so it lays the panels out to fill it (no letterboxing).
    fn fit_to_window(&mut self, ctx: &egui::Context) {
        let zoom = ctx.zoom_factor();
        let window = ctx.screen_rect().size() * zoom;
        let fit = (window.x / self.design.x).min(window.y / self.design.y).max(0.25);
        if (fit - zoom).abs() > 0.002 {
            ctx.set_zoom_factor(fit);
            return; // screen_rect reflects the new zoom on the next frame
        }
        let size = (window / zoom).floor();
        if size != self.laid_out {
            self.laid_out = size;
            if self.call_host("resize", &[size.x as i64, size.y as i64]).is_err() {
                eprintln!("bot_ops_native: Ruby raised in resize");
            }
        }
    }

    fn paint(&self, base: &Painter) {
        // "k" clips what follows to a rectangle (cut to the enclosing clip)
        // until its matching "K".
        let mut painter = base.clone();
        let mut clips: Vec<Rect> = Vec::new();
        for cmd in &self.frame.cmds {
            match text(cmd, 0) {
                "k" => {
                    let r = Rect::from_min_size(Pos2::new(num(cmd, 1), num(cmd, 2)), Vec2::new(num(cmd, 3), num(cmd, 4)));
                    clips.push(painter.clip_rect());
                    painter = base.with_clip_rect(r.intersect(painter.clip_rect()));
                }
                "K" => {
                    if let Some(previous) = clips.pop() {
                        painter = base.with_clip_rect(previous);
                    }
                }
                "r" => {
                    let rect = Rect::from_min_size(Pos2::new(num(cmd, 1), num(cmd, 2)), Vec2::new(num(cmd, 3), num(cmd, 4)));
                    let rounding = Rounding::same(num(cmd, 7));
                    if let Some(f) = color(cmd, 5) {
                        painter.rect_filled(rect, rounding, f);
                    }
                    if color(cmd, 6).is_some() {
                        painter.rect_stroke(rect, rounding, stroke(cmd, 6, 8));
                    }
                }
                "c" => {
                    let center = Pos2::new(num(cmd, 1), num(cmd, 2));
                    let r = num(cmd, 3);
                    if let Some(f) = color(cmd, 4) {
                        painter.circle_filled(center, r, f);
                    }
                    if color(cmd, 5).is_some() {
                        painter.circle_stroke(center, r, stroke(cmd, 5, 6));
                    }
                }
                "l" => {
                    painter.line_segment(
                        [Pos2::new(num(cmd, 1), num(cmd, 2)), Pos2::new(num(cmd, 3), num(cmd, 4))],
                        stroke(cmd, 5, 6),
                    );
                }
                "w" => {
                    if let Some(f) = color(cmd, 6) {
                        painter.add(wedge_mesh(num(cmd, 1), num(cmd, 2), num(cmd, 3), num(cmd, 4), num(cmd, 5), f));
                    }
                }
                "a" => {
                    // ["a", pts, base_y, fill] or, fading, ["a", pts, base_y, top, bottom, top_y]
                    let pts = points(cmd, 1);
                    match (color_parts(cmd, 3), color_parts(cmd, 4)) {
                        (Some(top), Some(bottom)) => {
                            painter.add(gradient_area_mesh(&pts, num(cmd, 2), num(cmd, 5), top, bottom));
                        }
                        _ => {
                            if let Some(f) = color(cmd, 3) {
                                painter.add(area_mesh(&pts, num(cmd, 2), f));
                            }
                        }
                    }
                }
                "g" => {
                    // ["g", pts (convex), [x1, y1, x2, y2], color_a, color_b, [cx, cy]?]
                    let pts = points(cmd, 1);
                    let axis = cmd.get(2).cloned().unwrap_or_default();
                    let center = cmd.get(5).filter(|c| c.is_array()).map(|c| Pos2::new(num(c, 0), num(c, 1)));
                    if let (Some(ca), Some(cb)) = (color_parts(cmd, 3), color_parts(cmd, 4)) {
                        let feather = 0.5 / painter.ctx().pixels_per_point().max(0.5) * 2.0;
                        painter.add(gradient_mesh(&pts, Pos2::new(num(&axis, 0), num(&axis, 1)),
                                                  Pos2::new(num(&axis, 2), num(&axis, 3)), ca, cb, feather, center));
                    }
                }
                "s" => {
                    // ["s", x, y, w, h, curve, blur, spread, color]: a soft glow
                    if let Some(c) = color(cmd, 8) {
                        let rect = Rect::from_min_size(Pos2::new(num(cmd, 1), num(cmd, 2)), Vec2::new(num(cmd, 3), num(cmd, 4)));
                        let shadow = egui::epaint::Shadow { offset: Vec2::ZERO, blur: num(cmd, 6), spread: num(cmd, 7), color: c };
                        painter.add(shadow.as_shape(rect, Rounding::same(num(cmd, 5))));
                    }
                }
                "p" => {
                    // ["p", [[x, y], ...], stroke, width, closed]
                    let pts = points(cmd, 1);
                    if pts.len() >= 2 {
                        let st = stroke(cmd, 2, 3);
                        let closed = cmd.get(4).and_then(|c| c.as_bool()).unwrap_or(false);
                        // Round caps and corners (icons): a dot at each end and
                        // at every corner sharper than ~50 degrees.
                        if cmd.get(5).and_then(|c| c.as_bool()).unwrap_or(false) {
                            let r = st.width / 2.0;
                            let n = pts.len();
                            for i in 0..n {
                                let end = !closed && (i == 0 || i == n - 1);
                                let corner = (closed || (i > 0 && i < n - 1)) && {
                                    let a = (pts[i] - pts[(i + n - 1) % n]).normalized();
                                    let b = (pts[(i + 1) % n] - pts[i]).normalized();
                                    a.dot(b) < 0.64
                                };
                                if end || corner {
                                    painter.circle_filled(pts[i], r, st.color);
                                }
                            }
                        }
                        if closed {
                            painter.add(egui::Shape::closed_line(pts, st));
                        } else {
                            painter.add(egui::Shape::line(pts, st));
                        }
                    }
                }
                "i" => {
                    // ["i", name, cx, cy, r]
                    if let Some(tex) = self.textures.get(text(cmd, 1)) {
                        painter.add(image_circle_mesh(tex.id(), Pos2::new(num(cmd, 2), num(cmd, 3)), num(cmd, 4)));
                    }
                }
                "t" => {
                    // ["t", str, x, y, size, color, weight, family, width, align, kerning]
                    let family = match (text(cmd, 7), text(cmd, 6)) {
                        ("mono", _) => FontFamily::Monospace,
                        ("display", _) => FontFamily::Name("display".into()),
                        (_, w @ ("medium" | "semibold" | "bold")) => FontFamily::Name(w.into()),
                        _ => FontFamily::Proportional,
                    };
                    let col = color(cmd, 5).unwrap_or(Color32::WHITE);
                    let mut job = egui::text::LayoutJob::default();
                    job.append(
                        text(cmd, 1),
                        0.0,
                        egui::TextFormat {
                            font_id: FontId::new(num(cmd, 4), family),
                            color: col,
                            extra_letter_spacing: num(cmd, 10),
                            ..Default::default()
                        },
                    );
                    let width = cmd.get(8).and_then(|w| w.as_f64()).map(|w| w as f32);
                    // Left-aligned text with a width wraps inside it; aligned text
                    // uses the width only as an anchor box.
                    job.wrap.max_width = match (text(cmd, 9), width) {
                        ("left", Some(w)) => w,
                        _ => f32::INFINITY,
                    };
                    let galley = painter.layout_job(job);
                    let x = num(cmd, 2);
                    let y = num(cmd, 3);
                    let (anchor, ax) = match (text(cmd, 9), width) {
                        ("right", Some(w)) => (Align2::RIGHT_TOP, x + w),
                        ("center", Some(w)) => (Align2::CENTER_TOP, x + w / 2.0),
                        _ => (Align2::LEFT_TOP, x),
                    };
                    let rect = anchor.anchor_size(Pos2::new(ax, y), galley.size());
                    painter.galley(rect.min, galley, col);
                }
                _ => {}
            }
        }
    }
}

impl eframe::App for HubApp {
    fn update(&mut self, ctx: &egui::Context, frame: &mut eframe::Frame) {
        snapshot(ctx);
        if std::mem::take(&mut self.start_fullscreen) {
            ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(true));
        }
        self.fit_to_window(ctx);
        self.sync_window_state(ctx);
        self.report_mono_advance(ctx);
        self.handle_keys(ctx);
        self.handle_scroll(ctx);
        self.handle_pan(ctx);
        self.handle_resize(ctx);
        self.poll_ruby(ctx);

        if ctx.input(|i| i.pointer.primary_pressed()) {
            let reported = ctx.input(|i| i.pointer.interact_pos());
            #[cfg(target_os = "macos")]
            let pos = appkit_pointer(frame, ctx.zoom_factor()).or(reported);
            #[cfg(not(target_os = "macos"))]
            let pos = reported;
            if let Some(pos) = pos {
                if debug() {
                    if let Some(r) = reported.filter(|r| (*r - pos).length() > 2.0) {
                        eprintln!("bot_ops_native: egui had the press at ({:.0}, {:.0}); AppKit at ({:.0}, {:.0})", r.x, r.y, pos.x, pos.y);
                    }
                }
                self.handle_press(ctx, pos, reported.unwrap_or(pos));
                self.poll_ruby(ctx);
            } else if debug() {                eprintln!("bot_ops_native: press with no pointer position");
            }
        }

        egui::CentralPanel::default()
            .frame(egui::Frame::none().fill(BACKGROUND))
            .show(ctx, |ui| self.paint(ui.painter()));

        ctx.request_repaint_after(Duration::from_millis(250));
    }
}

// ---- Ruby binding -----------------------------------------------------------

/// `BotOps::Native.run(host, width, height, title, position)`: opens the
/// window and blocks until it is closed. `position` is "left,top" in global
/// screen points, or "" to leave placement to the OS. A wrong argument
/// type raises TypeError in Ruby.
#[rubymodule(path = "BotOps::Native")]
mod native {
    use rutie::AnyObject;

    pub fn run(host: &AnyObject, width: i64, height: i64, title: String, position: String) {
        super::run_window(host.clone(), width as f32, height as f32, title, position);
    }
}

fn run_window(host: AnyObject, w: f32, h: f32, title: String, position: String) {
    let position = position.split_once(',').and_then(|(x, y)| {
        Some((x.trim().parse::<f32>().ok()?, y.trim().parse::<f32>().ok()?))
    });

    let mut viewport = egui::ViewportBuilder::default()
        .with_title(title.clone())
        .with_decorations(false)
        .with_resizable(true)
        .with_min_inner_size([MIN_SIZE.x, MIN_SIZE.y])
        .with_inner_size([w, h]);
    // On macOS the window is placed through AppKit before it is first
    // shown (see place_window); elsewhere egui positions it.
    #[cfg(not(target_os = "macos"))]
    if let Some((x, y)) = position {
        viewport = viewport.with_position([x, y]);
    }
    if let Some((iw, ih, rgba)) = decode_png(ICON_PNG) {
        viewport = viewport.with_icon(Arc::new(egui::IconData { rgba, width: iw, height: ih }));
    }
    let start_fullscreen = matches!(std::env::var("BOT_OPS_FULLSCREEN").as_deref(), Ok("1") | Ok("true"));
    let options = eframe::NativeOptions { viewport, ..Default::default() };
    // Run the window loop without the GVL: holding it here would starve
    // every Ruby thread for as long as the window is open.
    let mut once = Some((options, host));
    // Ruby calls the unblock function whenever it wants this thread back
    // to handle an interrupt: a TERM or Ctrl+C, but also routine ones such
    // as SIGCHLD from the probe's sysctl/df runs, many times a minute.
    // So it only wakes the loop: the next frame calls into Ruby, which
    // handles the interrupt there (a TERM comes back as "quit" from poll).
    let window_ctx: Arc<Mutex<Option<egui::Context>>> = Arc::new(Mutex::new(None));
    let ctx_for_loop = Arc::clone(&window_ctx);
    let unblock = move || {
        if let Some(ctx) = window_ctx.lock().ok().and_then(|c| c.clone()) {
            ctx.request_repaint();
        }
    };
    let result = Thread::call_without_gvl(
        move || {
            let (options, host) = once.take().expect("window loop runs once");
            let ctx_for_loop = Arc::clone(&ctx_for_loop);
            eframe::run_native(
                &title,
                options,
                Box::new(move |cc| {
                    if let Ok(mut slot) = ctx_for_loop.lock() {
                        *slot = Some(cc.egui_ctx.clone());
                    }
                    #[cfg(target_os = "macos")]
                    if let Some((x, y)) = position {
                        place_window(cc, x as f64, y as f64);
                    }
                    install_fonts(&cc.egui_ctx);
                    // Zoom is driven by fit_to_window; Cmd +/- would fight it.
                    cc.egui_ctx.options_mut(|o| o.zoom_with_keyboard = false);
                    Ok(Box::new(HubApp {
                        host,
                        textures: load_textures(&cc.egui_ctx),
                        frame: Frame::default(),
                        hits_rects: Vec::new(),
                        design: Vec2::new(w, h),
                        laid_out: Vec2::new(w, h),
                        decorated: false,
                        start_fullscreen,
                        reported_fullscreen: None,
                        minimize_pending: false,
                        minimize_at: None,
                        poll_failures: 0,
                        scroll_lines: 0.0,
                        scroll_x: 0.0,
                        badge: 0,
                        panning: None,
                        mono_advance: None,
                        resizing: None,
                        last_focused: None,
                    }))
                }),
            )
        },
        Some(unblock),
    );
    if let Err(e) = result {
        eprintln!("bot_ops_native: window error: {e}");
    }
}

#[no_mangle]
pub extern "C" fn Init_bot_ops_native() {
    native::define_ruby();
}
