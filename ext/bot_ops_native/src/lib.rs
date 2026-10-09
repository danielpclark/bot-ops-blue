//! Bot Ops Blue native host.
//!
//! Ruby owns the data (store, comms, scene) and produces a frame as JSON:
//! a list of drawing commands, clickable hit regions and a drag region.
//! This crate opens a borderless egui window, paints the frame, routes
//! clicks back to Ruby, and executes the window commands Ruby asks for.
//!
//! Ruby API (see lib/bot_ops/native_host.rb):
//!   BotOps::Native.run(host)   # blocks until the window closes
//!   host.poll    -> JSON String, or "" when nothing changed
//!   host.hit(id) -> String command ("quit", "fullscreen:on", ...) or ""

use eframe::egui::{self, Align2, Color32, FontFamily, FontId, Pos2, Rect, Rounding, Stroke, Vec2};
use rutie::{AnyObject, Integer, Module, NilClass, Object, RString};
use serde::Deserialize;
use serde_json::Value;
use std::time::Duration;

#[derive(Deserialize, Default)]
struct Frame {
    #[serde(default)]
    cmds: Vec<Value>,
    #[serde(default)]
    hits: Vec<(f32, f32, f32, f32, u32)>,
    #[serde(default)]
    drag: Option<(f32, f32, f32, f32)>,
}

struct HubApp {
    host: AnyObject,
    frame: Frame,
    hits_rects: Vec<(Rect, u32)>,
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
    fonts.font_data.insert(
        "DejaVuSans".to_owned(),
        egui::FontData::from_static(include_bytes!("../fonts/DejaVuSans.ttf")),
    );
    fonts.font_data.insert(
        "DejaVuSans-Bold".to_owned(),
        egui::FontData::from_static(include_bytes!("../fonts/DejaVuSans-Bold.ttf")),
    );
    fonts.font_data.insert(
        "DejaVuSansMono".to_owned(),
        egui::FontData::from_static(include_bytes!("../fonts/DejaVuSansMono.ttf")),
    );
    fonts
        .families
        .entry(FontFamily::Proportional)
        .or_default()
        .insert(0, "DejaVuSans".to_owned());
    fonts
        .families
        .entry(FontFamily::Monospace)
        .or_default()
        .insert(0, "DejaVuSansMono".to_owned());
    fonts.families.insert(
        FontFamily::Name("bold".into()),
        vec!["DejaVuSans-Bold".to_owned(), "DejaVuSans".to_owned()],
    );
    ctx.set_fonts(fonts);
}

// ---- app -------------------------------------------------------------------

impl HubApp {
    fn poll_ruby(&mut self, ctx: &egui::Context) {
        match self.host.protect_send("poll", &[]) {
            Ok(obj) => {
                if obj.is_nil() {
                    return;
                }
                if let Ok(rs) = obj.try_convert_to::<RString>() {
                    let json = rs.to_string();
                    if json.is_empty() {
                        return;
                    }
                    match serde_json::from_str::<Frame>(&json) {
                        Ok(frame) => {
                            self.hits_rects = frame
                                .hits
                                .iter()
                                .map(|&(x, y, w, h, id)| (Rect::from_min_size(Pos2::new(x, y), Vec2::new(w, h)), id))
                                .collect();
                            self.frame = frame;
                        }
                        Err(e) => eprintln!("bot_ops_native: bad frame JSON: {e}"),
                    }
                }
            }
            Err(_) => {
                eprintln!("bot_ops_native: Ruby raised in poll; closing window");
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
        }
    }

    fn handle_press(&mut self, ctx: &egui::Context, pos: Pos2) {
        let hit = self.hits_rects.iter().rev().find(|(r, _)| r.contains(pos)).map(|(_, id)| *id);
        if let Some(id) = hit {
            let arg = Integer::new(id as i64).to_any_object();
            match self.host.protect_send("hit", &[arg]) {
                Ok(obj) => {
                    if let Ok(cmd) = obj.try_convert_to::<RString>() {
                        self.window_command(ctx, &cmd.to_string());
                    }
                }
                Err(_) => eprintln!("bot_ops_native: Ruby raised in hit"),
            }
            return;
        }
        if let Some((x, y, w, h)) = self.frame.drag {
            if Rect::from_min_size(Pos2::new(x, y), Vec2::new(w, h)).contains(pos) {
                ctx.send_viewport_cmd(egui::ViewportCommand::StartDrag);
            }
        }
    }

    fn window_command(&self, ctx: &egui::Context, cmd: &str) {
        match cmd {
            "quit" => ctx.send_viewport_cmd(egui::ViewportCommand::Close),
            "fullscreen:on" => ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(true)),
            "fullscreen:off" => ctx.send_viewport_cmd(egui::ViewportCommand::Fullscreen(false)),
            "decorations:on" => ctx.send_viewport_cmd(egui::ViewportCommand::Decorations(true)),
            "decorations:off" => ctx.send_viewport_cmd(egui::ViewportCommand::Decorations(false)),
            _ => {}
        }
    }

    fn paint(&self, ui: &egui::Ui) {
        let painter = ui.painter();
        for cmd in &self.frame.cmds {
            match text(cmd, 0) {
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
                    let pts: Vec<Pos2> = cmd
                        .get(1)
                        .and_then(|p| p.as_array())
                        .map(|arr| arr.iter().map(|p| Pos2::new(num(p, 0), num(p, 1))).collect())
                        .unwrap_or_default();
                    if let Some(f) = color(cmd, 3) {
                        painter.add(area_mesh(&pts, num(cmd, 2), f));
                    }
                }
                "t" => {
                    // ["t", str, x, y, size, color, weight, family, width, align, kerning]
                    let family = match (text(cmd, 7), text(cmd, 6)) {
                        ("mono", _) => FontFamily::Monospace,
                        (_, "bold") => FontFamily::Name("bold".into()),
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
                    let galley = ui.fonts(|f| f.layout_job(job));
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
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll_ruby(ctx);

        if ctx.input(|i| i.pointer.primary_pressed()) {
            if let Some(pos) = ctx.input(|i| i.pointer.interact_pos()) {
                self.handle_press(ctx, pos);
                self.poll_ruby(ctx);
            }
        }

        egui::CentralPanel::default()
            .frame(egui::Frame::none().fill(Color32::from_rgb(5, 11, 20)))
            .show(ctx, |ui| self.paint(ui));

        ctx.request_repaint_after(Duration::from_millis(250));
    }
}

// ---- Ruby binding -----------------------------------------------------------

rutie::class!(BotOpsNativeClass);

rutie::methods!(
    BotOpsNativeClass,
    _rtself,
    fn native_run(host: AnyObject, width: Integer, height: Integer, title: RString) -> NilClass {
        let host = host.expect("host object required");
        let w = width.map(|v| v.to_i64() as f32).unwrap_or(1536.0);
        let h = height.map(|v| v.to_i64() as f32).unwrap_or(1024.0);
        let title = title.map(|t| t.to_string()).unwrap_or_else(|_| "Bot Ops Blue".to_owned());

        let options = eframe::NativeOptions {
            viewport: egui::ViewportBuilder::default()
                .with_title(title.clone())
                .with_decorations(false)
                .with_resizable(false)
                .with_inner_size([w, h]),
            ..Default::default()
        };
        let result = eframe::run_native(
            &title,
            options,
            Box::new(move |cc| {
                install_fonts(&cc.egui_ctx);
                Ok(Box::new(HubApp { host, frame: Frame::default(), hits_rects: Vec::new() }))
            }),
        );
        if let Err(e) = result {
            eprintln!("bot_ops_native: window error: {e}");
        }
        NilClass::new()
    }
);

#[no_mangle]
pub extern "C" fn Init_bot_ops_native() {
    let mut module = Module::from_existing("BotOps");
    module.define(|m| {
        m.define_nested_class("Native", None).define(|klass| {
            klass.def_self("run", native_run);
        });
    });
}
