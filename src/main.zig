const std = @import("std");
const r4os = @import("r4os");
const font_tools = @import("font_tools");
const font_import = font_tools.font_import;
const font_format = font_tools.font_format;

const max_source_bytes: usize = 64 * 1024;
const max_catalog_fonts: usize = 64;
const max_fonts: usize = max_catalog_fonts + 1; // installed faces plus builtin
const path_capacity: usize = 128;
const label_capacity: usize = 80;
const source_preview_width: u16 = 192;
const source_preview_height: u16 = 32;

const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    allocator: std.mem.Allocator,

    fn init(app: *r4os.App) ?AppApi {
        return .{
            .sys = app.system(),
            .desk = app.desktop() orelse return null,
            .draw = app.drawing() orelse return null,
            .allocator = app.allocator() orelse return null,
        };
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(ctx.sys.argsRaw(), "/SELFTEST")) return runSelfTest(&ctx);
    var app = App{ .ctx = &ctx };
    return app.run();
}

const App = struct {
    ctx: *AppApi,
    width: i32 = 500,
    height: i32 = 350,
    source_path: [path_capacity]u8 = .{0} ** path_capacity,
    source_bytes: ?[]u8 = null,
    source_face: usize = 0,
    source_face_count: usize = 0,
    source_info: ?font_import.FaceInfo = null,
    source_preview: ?font_import.Preview = null,
    source_preview_pixels: [source_preview_width * source_preview_height]u32 = .{0x00FFFFFF} ** (source_preview_width * source_preview_height),
    font_ids: [max_fonts]u32 = .{0} ** max_fonts,
    font_labels: [max_fonts][label_capacity]u8 = .{.{0} ** label_capacity} ** max_fonts,
    font_count: usize = 0,
    selected_font: usize = 0,
    confirm_remove: bool = false,
    status: [80]u8 = .{0} ** 80,

    fn run(self: *App) i32 {
        defer self.freeSource();
        if (self.ctx.desk.programWindowId() < 0) {
            self.ctx.sys.println("FONTS is a desktop GUI application.");
            return 0;
        }
        _ = self.ctx.desk.guiSetTitle("Fonts");
        _ = self.ctx.desk.guiSetMinSize(420, 330);
        self.loadInstalled();
        self.loadSourceFromArgs();
        self.updateMetrics();
        self.render();

        while (!self.ctx.sys.programShouldClose()) {
            var event: r4os.abi.GuiEvent = .{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) self.handleEvent(event);
            self.ctx.sys.sleepTicks(2);
        }
        return 0;
    }

    fn handleEvent(self: *App, event: r4os.abi.GuiEvent) void {
        const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
        switch (kind) {
            .close => return,
            .resize => {
                self.updateMetrics();
                self.render();
            },
            .font_changed => {
                self.loadInstalled();
                self.render();
            },
            .key_down => self.handleKey(r4os.gui.eventKey(event)),
            .mouse_up => self.handleClick(event.x, event.y),
            else => {},
        }
    }

    fn handleKey(self: *App, key: u8) void {
        switch (key) {
            r4os.gui.Key.escape => _ = self.ctx.desk.guiSetTitle("Fonts"),
            r4os.gui.Key.left => self.changeSourceFace(-1),
            r4os.gui.Key.right => self.changeSourceFace(1),
            r4os.gui.Key.up => self.changeInstalledFont(-1),
            r4os.gui.Key.down => self.changeInstalledFont(1),
            r4os.gui.Key.enter => self.installAllFaces(),
            r4os.gui.Key.delete => self.removeSelectedFont(),
            else => return,
        }
        self.render();
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.width = clamp(canvas.w, 420, 900);
        self.height = clamp(canvas.h, 280, 700);
    }

    fn handleClick(self: *App, x: i32, y: i32) void {
        if (self.sourcePrevRect().contains(x, y)) {
            self.changeSourceFace(-1);
        } else if (self.sourceNextRect().contains(x, y)) {
            self.changeSourceFace(1);
        } else if (self.installRect().contains(x, y)) {
            self.installAllFaces();
        } else if (self.removeRect().contains(x, y)) {
            self.removeSelectedFont();
        } else if (self.fontListRect().contains(x, y)) {
            const row = @divTrunc(y - self.fontListRect().y, 18);
            if (row >= 0 and @as(usize, @intCast(row)) < self.visibleFontRows()) {
                self.selected_font = @intCast(row);
                self.confirm_remove = false;
            }
        }
        self.render();
    }

    fn loadSourceFromArgs(self: *App) void {
        const args = self.ctx.sys.argsRaw();
        const path = firstArg(args, self.source_path[0..]);
        if (path.len == 0) {
            self.setStatus("Open a .FON file from Explorer to install it");
            return;
        }
        const info = self.ctx.sys.fileInfo(zptr(self.source_path[0..])) orelse {
            self.setStatus("The selected font file could not be read");
            return;
        };
        if (info.is_dir != 0 or info.size == 0 or info.size > max_source_bytes) {
            self.setStatus("Font source is empty or too large");
            return;
        }
        const bytes = self.ctx.allocator.alloc(u8, @intCast(info.size)) catch {
            self.setStatus("Not enough memory for font source");
            return;
        };
        const read = self.ctx.sys.fileRead(zptr(self.source_path[0..]), bytes);
        if (read != @as(i32, @intCast(bytes.len))) {
            self.ctx.allocator.free(bytes);
            self.setStatus("Font source read failed");
            return;
        }
        self.source_bytes = bytes;
        self.source_face_count = font_import.faceCount(bytes);
        if (self.source_face_count == 0) {
            self.setStatus("This is not a supported FON/FNT file");
            return;
        }
        self.selectSourceFace();
    }

    fn selectSourceFace(self: *App) void {
        const bytes = self.source_bytes orelse return;
        self.source_preview = null;
        self.source_info = font_import.inspect(bytes, self.source_face) catch {
            self.setStatus("Font resource could not be inspected");
            return;
        };
        self.source_preview = font_import.rasterizePreview(
            self.ctx.allocator,
            bytes,
            self.source_face,
            "AaBbCc 123",
            self.source_preview_pixels[0..],
            source_preview_width,
            source_preview_height,
        ) catch {
            self.setStatus("Font preview conversion failed");
            return;
        };
        self.setStatus(if (self.source_info.?.vector)
            "Vector preview - Install adds every native size"
        else
            "Bitmap preview - Install adds every native size");
    }

    fn changeSourceFace(self: *App, direction: i32) void {
        if (self.source_face_count == 0) return;
        if (direction < 0) {
            self.source_face = if (self.source_face == 0) self.source_face_count - 1 else self.source_face - 1;
        } else {
            self.source_face = (self.source_face + 1) % self.source_face_count;
        }
        self.selectSourceFace();
    }

    fn changeInstalledFont(self: *App, direction: i32) void {
        if (self.font_count == 0) return;
        if (direction < 0) {
            self.selected_font = if (self.selected_font == 0) self.font_count - 1 else self.selected_font - 1;
        } else {
            self.selected_font = (self.selected_font + 1) % self.font_count;
        }
        self.confirm_remove = false;
    }

    fn installAllFaces(self: *App) void {
        const bytes = self.source_bytes orelse {
            self.setStatus("No FON source selected");
            return;
        };
        if (self.source_face_count == 0 or self.source_face_count > max_catalog_fonts) {
            self.setStatus("Unsupported number of font faces");
            return;
        }

        var targets: [max_catalog_fonts][path_capacity]u8 = .{.{0} ** path_capacity} ** max_catalog_fonts;
        var stages: [max_catalog_fonts][path_capacity]u8 = .{.{0} ** path_capacity} ** max_catalog_fonts;
        var backups: [max_catalog_fonts][path_capacity]u8 = .{.{0} ** path_capacity} ** max_catalog_fonts;
        var new_faces: usize = 0;
        var face_index: usize = 0;
        while (face_index < self.source_face_count) : (face_index += 1) {
            buildInstallPaths(baseName(spanZ(self.source_path[0..])), face_index, targets[face_index][0..], stages[face_index][0..], backups[face_index][0..]) orelse {
                self.setStatus("Cannot create target font file name");
                return;
            };
            if (self.ctx.sys.fileInfo(zptr(targets[face_index][0..])) == null) new_faces += 1;
        }
        const catalogue_count = @as(usize, @intCast(self.ctx.draw.fontCount())) -| 1;
        if (catalogue_count + new_faces > max_catalog_fonts) {
            self.setStatus("Not enough system font catalogue slots");
            return;
        }

        var installed: usize = 0;
        face_index = 0;
        while (face_index < self.source_face_count) : (face_index += 1) {
            const converted = font_import.convert(self.ctx.allocator, bytes, baseName(spanZ(self.source_path[0..])), face_index) catch |err| {
                self.finishPartialInstall(installed, switch (err) {
                    error.BadVectorPath, error.UnsupportedVectorFntVersion => "Vector FON conversion failed",
                    else => "FON conversion failed",
                });
                return;
            };
            defer self.ctx.allocator.free(converted);

            _ = self.ctx.sys.fileDelete(zptr(stages[face_index][0..]));
            _ = self.ctx.sys.fileDelete(zptr(backups[face_index][0..]));
            if (self.ctx.sys.fileWrite(zptr(stages[face_index][0..]), converted) != @as(i32, @intCast(converted.len))) {
                self.finishPartialInstall(installed, "Cannot stage R4F installation");
                return;
            }
            const replace = self.ctx.sys.fileReplaceAtomic(
                zptr(targets[face_index][0..]),
                zptr(stages[face_index][0..]),
                zptr(backups[face_index][0..]),
                r4os.r4sys.file_replace_atomic_flag_consume_stage,
            );
            if (replace != r4os.r4sys.file_replace_atomic_result_ok) {
                self.finishPartialInstall(installed, "Atomic R4F installation failed");
                return;
            }
            installed += 1;
        }

        if (self.ctx.draw.fontReload() < 0) {
            self.setStatus("Installed R4F but catalogue reload failed");
            return;
        }
        self.loadInstalled();
        face_index = 0;
        while (face_index < installed) : (face_index += 1) {
            if (!self.hasInstalledPath(spanZ(targets[face_index][0..]))) {
                self.setStatus("One or more native sizes were rejected");
                return;
            }
        }
        @memset(self.status[0..], 0);
        appendZ(self.status[0..], "Installed ");
        appendDec(self.status[0..], installed);
        appendZ(self.status[0..], if (installed == 1) " native size" else " native sizes");
    }

    fn finishPartialInstall(self: *App, installed: usize, message: []const u8) void {
        if (installed > 0) {
            _ = self.ctx.draw.fontReload();
            self.loadInstalled();
        }
        self.setStatus(message);
    }

    fn removeSelectedFont(self: *App) void {
        if (self.selected_font == 0 or self.selected_font >= self.font_count) {
            self.setStatus("The built-in font cannot be removed");
            return;
        }
        if (!self.confirm_remove) {
            self.confirm_remove = true;
            self.setStatus("Click Remove again to confirm");
            return;
        }
        var info: r4os.abi.GuiFontInfo = .{};
        if (self.ctx.draw.fontInfo(self.font_ids[self.selected_font], &info) <= 0) {
            self.setStatus("Selected font is no longer available");
            return;
        }
        var path: [path_capacity]u8 = .{0} ** path_capacity;
        copyZ(path[0..], fixedSpan(info.path[0..]));
        if (!hasSystemFontPrefix(spanZ(path[0..])) or self.ctx.sys.fileDelete(zptr(path[0..])) <= 0) {
            self.setStatus("Cannot remove this installed font");
            return;
        }
        _ = self.ctx.draw.fontReload();
        self.selected_font = 0;
        self.confirm_remove = false;
        self.loadInstalled();
        self.setStatus("Font removed");
    }

    fn loadInstalled(self: *App) void {
        self.font_count = 0;
        const count = @min(@as(usize, @intCast(self.ctx.draw.fontCount())), max_fonts);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            var info: r4os.abi.GuiFontInfo = .{};
            if (self.ctx.draw.fontInfo(@intCast(index), &info) <= 0) continue;
            if ((info.flags & r4os.abi.gui_font_flag_renderable) == 0) continue;
            self.font_ids[self.font_count] = info.id;
            formatFontLabel(self.font_labels[self.font_count][0..], info);
            self.font_count += 1;
        }
        if (self.font_count == 0) {
            self.font_ids[0] = r4os.abi.gui_font_builtin_id;
            copyZ(self.font_labels[0][0..], "R4OS Builtin 8x8");
            self.font_count = 1;
        }
        if (self.selected_font >= self.font_count) self.selected_font = 0;
    }

    fn hasInstalledPath(self: *const App, wanted: []const u8) bool {
        var index: usize = 0;
        while (index < self.font_count) : (index += 1) {
            var info: r4os.abi.GuiFontInfo = .{};
            if (self.ctx.draw.fontInfo(self.font_ids[index], &info) > 0 and
                equalsIgnoreCase(fixedSpan(info.path[0..]), wanted)) return true;
        }
        return false;
    }

    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.width, self.height)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [label_capacity]u8 = .{0} ** label_capacity;
        _ = canvas.clear(r4os.gui.default_palette.face);
        _ = canvas.groupBox(.{ .rect = self.fontListRect().inset(-4, -18), .title = "Installed system fonts" }, scratch[0..]);
        var row: usize = 0;
        while (row < self.visibleFontRows()) : (row += 1) {
            const rect = r4os.gui.Rect{ .x = self.fontListRect().x, .y = self.fontListRect().y + @as(i32, @intCast(row)) * 18, .w = self.fontListRect().w, .h = 18 };
            const selected = row == self.selected_font;
            _ = canvas.rect(rect, if (selected) r4os.gui.default_palette.select_bg else 0xFFFFFF);
            _ = canvas.textClipped(rect.x + 3, rect.y + 4, rect.w - 6, scratch[0..], spanZ(self.font_labels[row][0..]), if (selected) r4os.gui.default_palette.select_text else r4os.gui.default_palette.text, if (selected) r4os.gui.default_palette.select_bg else 0xFFFFFF);
        }

        const sample_rect = r4os.gui.Rect{ .x = 16, .y = self.fontListRect().bottom() + 10, .w = self.width - 32, .h = 40 };
        _ = canvas.groupBox(.{ .rect = sample_rect, .title = "Preview" }, scratch[0..]);
        const selected_id = self.font_ids[self.selected_font];
        _ = canvas.withFontId(selected_id).text(sample_rect.x + 8, sample_rect.y + 16, "The quick brown fox 123", r4os.gui.default_palette.text, r4os.gui.default_palette.face);

        const source_box = self.sourceRect();
        _ = canvas.groupBox(.{ .rect = source_box, .title = "Font source" }, scratch[0..]);
        if (self.source_info) |info| {
            _ = canvas.textClipped(source_box.x + 8, source_box.y + 12, source_box.w - 170, scratch[0..], info.family, r4os.gui.default_palette.text, r4os.gui.default_palette.face);
            var line: [64]u8 = .{0} ** 64;
            const label = formatFaceLine(line[0..], info);
            _ = canvas.textClipped(source_box.x + 8, source_box.y + 28, source_box.w - 170, scratch[0..], label, r4os.gui.default_palette.text, r4os.gui.default_palette.face);
            if (self.source_preview) |preview| {
                const pixel_count = @as(usize, preview.width) * preview.height;
                _ = canvas.raster(source_box.x + 8, source_box.y + 46, preview.width, preview.height, 1, self.source_preview_pixels[0..pixel_count]);
            }
        } else {
            _ = canvas.text(source_box.x + 8, source_box.y + 18, "Open a .FON file in Explorer", r4os.gui.default_palette.text, r4os.gui.default_palette.face);
        }
        _ = canvas.button(.{ .rect = self.sourcePrevRect(), .text = "<", .state = if (self.source_face_count > 1) .normal else .disabled }, scratch[0..]);
        _ = canvas.button(.{ .rect = self.sourceNextRect(), .text = ">", .state = if (self.source_face_count > 1) .normal else .disabled }, scratch[0..]);
        _ = canvas.button(.{ .rect = self.installRect(), .text = "Install All", .state = if (self.source_info != null) .normal else .disabled, .is_default = true }, scratch[0..]);
        _ = canvas.button(.{ .rect = self.removeRect(), .text = if (self.confirm_remove) "Confirm Remove" else "Remove", .state = if (self.selected_font > 0) .normal else .disabled }, scratch[0..]);
        _ = canvas.textClipped(12, self.height - 18, self.width - 24, scratch[0..], spanZ(self.status[0..]), r4os.gui.default_palette.text, r4os.gui.default_palette.face);
        _ = paint.present();
    }

    fn fontListRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 16, .y = 30, .w = self.width - 32, .h = @min(108, @max(54, @divTrunc(self.height, 3))) };
    }

    fn visibleFontRows(self: *const App) usize {
        return @min(self.font_count, @as(usize, @intCast(@divTrunc(self.fontListRect().h, 18))));
    }

    fn sourceRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 16, .y = @max(self.height - 130, self.fontListRect().bottom() + 82), .w = self.width - 32, .h = 88 };
    }

    fn sourcePrevRect(self: *const App) r4os.gui.Rect {
        const box = self.sourceRect();
        return .{ .x = box.right() - 152, .y = box.y + 12, .w = 22, .h = 22 };
    }

    fn sourceNextRect(self: *const App) r4os.gui.Rect {
        const rect = self.sourcePrevRect();
        return .{ .x = rect.right() + 2, .y = rect.y, .w = rect.w, .h = rect.h };
    }

    fn installRect(self: *const App) r4os.gui.Rect {
        const box = self.sourceRect();
        return .{ .x = box.right() - 100, .y = box.y + 12, .w = 92, .h = 22 };
    }

    fn removeRect(self: *const App) r4os.gui.Rect {
        return .{ .x = self.width - 116, .y = self.fontListRect().bottom() + 54, .w = 100, .h = 22 };
    }

    fn setStatus(self: *App, value: []const u8) void {
        copyZ(self.status[0..], value);
    }

    fn freeSource(self: *App) void {
        if (self.source_bytes) |bytes| self.ctx.allocator.free(bytes);
        self.source_bytes = null;
    }
};

fn runSelfTest(ctx: *AppApi) i32 {
    const sources = [_]struct {
        path: [*:0]const u8,
        name: []const u8,
        vector: bool,
    }{
        .{ .path = "C:\\TEMP\\FONTS\\COURA.FON", .name = "COURA.FON", .vector = false },
        .{ .path = "C:\\TEMP\\FONTS\\HELVA.FON", .name = "HELVA.FON", .vector = false },
        .{ .path = "C:\\TEMP\\FONTS\\TMSRA.FON", .name = "TMSRA.FON", .vector = false },
        .{ .path = "C:\\TEMP\\FONTS\\MODERN.FON", .name = "MODERN.FON", .vector = true },
        .{ .path = "C:\\TEMP\\FONTS\\ROMAN.FON", .name = "ROMAN.FON", .vector = true },
        .{ .path = "C:\\TEMP\\FONTS\\SCRIPT.FON", .name = "SCRIPT.FON", .vector = true },
    };
    const baseline = ctx.draw.fontReload();
    if (baseline < 0) return fail(ctx, "catalogue-initial-reload");
    var expected_catalogue_count = baseline;
    var test_paths: [24][path_capacity]u8 = .{.{0} ** path_capacity} ** 24;
    var installed_count: usize = 0;
    defer {
        var cleanup: usize = 0;
        while (cleanup < installed_count) : (cleanup += 1) _ = ctx.sys.fileDelete(zptr(test_paths[cleanup][0..]));
        _ = ctx.draw.fontReload();
    }
    for (sources) |source| {
        const file = ctx.sys.fileInfo(source.path) orelse return fail(ctx, "source-missing");
        if (file.size == 0 or file.size > max_source_bytes) return fail(ctx, "source-size");
        const bytes = ctx.allocator.alloc(u8, @intCast(file.size)) catch return fail(ctx, "source-oom");
        defer ctx.allocator.free(bytes);
        if (ctx.sys.fileRead(source.path, bytes) != @as(i32, @intCast(bytes.len))) return fail(ctx, "source-read");
        const count = font_import.faceCount(bytes);
        if (count == 0) return fail(ctx, "fnt-faces");
        const source_start = installed_count;
        var face_index: usize = 0;
        while (face_index < count) : (face_index += 1) {
            const face = font_import.inspect(bytes, face_index) catch return fail(ctx, "fnt-inspect");
            if (face.vector != source.vector or face.pixel_height == 0) return fail(ctx, "fnt-kind");
            const converted = font_import.convert(ctx.allocator, bytes, source.name, face_index) catch return fail(ctx, "fnt-convert");
            defer ctx.allocator.free(converted);
            if (converted.len < 4 or !std.mem.eql(u8, converted[0..4], &font_format.MAGIC)) return fail(ctx, "r4f-magic");
            if (installed_count >= test_paths.len) return fail(ctx, "test-font-limit");
            selfTestInstallPath(installed_count, test_paths[installed_count][0..]) orelse return fail(ctx, "test-font-path");
            _ = ctx.sys.fileDelete(zptr(test_paths[installed_count][0..]));
            if (ctx.sys.fileWrite(zptr(test_paths[installed_count][0..]), converted) != @as(i32, @intCast(converted.len))) return fail(ctx, "r4f-write");
            installed_count += 1;
            expected_catalogue_count += 1;
        }
        const reloaded = ctx.draw.fontReload();
        if (reloaded < expected_catalogue_count) {
            ctx.sys.write("FONTS selftest catalogue rejected: ");
            ctx.sys.println(source.name);
            return fail(ctx, "r4f-catalogue");
        }
        var installed_index = source_start;
        while (installed_index < installed_count) : (installed_index += 1) {
            if (!catalogHasPath(ctx, spanZ(test_paths[installed_index][0..]))) return fail(ctx, "r4f-batch-path");
        }
    }
    ctx.sys.println("FONTS selftest: OK all bundled FON sources -> R4F");
    return 0;
}

fn fail(ctx: *AppApi, label: []const u8) i32 {
    ctx.sys.write("FONTS selftest FAILED: ");
    ctx.sys.println(label);
    return 1;
}

fn catalogHasPath(ctx: *AppApi, wanted: []const u8) bool {
    const count: usize = @intCast(ctx.draw.fontCount());
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var info: r4os.abi.GuiFontInfo = .{};
        if (ctx.draw.fontInfo(@intCast(index), &info) > 0 and
            equalsIgnoreCase(fixedSpan(info.path[0..]), wanted)) return true;
    }
    return false;
}

fn formatFontLabel(out: []u8, info: r4os.abi.GuiFontInfo) void {
    @memset(out, 0);
    const family = fixedSpan(info.family[0..]);
    const face = fixedSpan(info.face[0..]);
    appendZ(out, family);
    if (face.len > 0 and !equalsIgnoreCase(face, family)) {
        appendZ(out, " ");
        appendZ(out, face);
    }
    appendZ(out, " ");
    appendZ(out, fixedSpan(info.style[0..]));
    appendZ(out, " ");
    appendDec(out, @intCast(info.height));
    appendZ(out, " px");
}

fn formatFaceLine(out: []u8, info: font_import.FaceInfo) []const u8 {
    @memset(out, 0);
    appendZ(out, info.style);
    appendZ(out, "  ");
    appendDec(out, info.pixel_height);
    appendZ(out, " px  ");
    appendDec(out, info.face_index + 1);
    appendZ(out, "/");
    appendDec(out, info.face_count);
    appendZ(out, if (info.vector) "  Vector FNT - rasterizes to R4F" else "  Bitmap FNT");
    return spanZ(out);
}

fn buildInstallPaths(source: []const u8, face: usize, target: []u8, stage: []u8, backup: []u8) ?void {
    var stem: [6]u8 = .{0} ** 6;
    var written: usize = 0;
    for (baseName(source)) |ch| {
        if (written >= 5) break;
        if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9')) {
            stem[written] = upper(ch);
            written += 1;
        }
    }
    if (written == 0) return null;
    const prefix = "C:\\R4OS\\FONTS\\";
    writePath(target, prefix, stem[0..written], face, ".R4F") orelse return null;
    writePath(stage, prefix, stem[0..written], face, ".NEW") orelse return null;
    writePath(backup, prefix, stem[0..written], face, ".BAK") orelse return null;
}

fn selfTestInstallPath(index: usize, out: []u8) ?void {
    const prefix = "C:\\R4OS\\FONTS\\";
    return writePath(out, prefix, "FTEST", index, ".R4F");
}

fn writePath(out: []u8, prefix: []const u8, stem: []const u8, face: usize, extension: []const u8) ?void {
    @memset(out, 0);
    if (prefix.len + stem.len + 2 + extension.len + 1 > out.len) return null;
    var at: usize = 0;
    @memcpy(out[at .. at + prefix.len], prefix);
    at += prefix.len;
    @memcpy(out[at .. at + stem.len], stem);
    at += stem.len;
    out[at] = '0' + @as(u8, @intCast((face / 10) % 10));
    out[at + 1] = '0' + @as(u8, @intCast(face % 10));
    at += 2;
    @memcpy(out[at .. at + extension.len], extension);
}

fn firstArg(raw: [*:0]const u8, out: []u8) []const u8 {
    @memset(out, 0);
    var at: usize = 0;
    while (raw[at] == ' ' or raw[at] == '\t') : (at += 1) {}
    const quote = raw[at] == '"';
    if (quote) at += 1;
    var written: usize = 0;
    while (written + 1 < out.len and raw[at] != 0 and (if (quote) raw[at] != '"' else raw[at] != ' ' and raw[at] != '\t')) : ({
        at += 1;
        written += 1;
    }) out[written] = raw[at];
    return out[0..written];
}

fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, index| {
        if (ch == '\\' or ch == '/') start = index + 1;
    }
    var end = path.len;
    if (end >= 4 and path[end - 4] == '.') end -= 4;
    return path[start..end];
}

fn hasSystemFontPrefix(path: []const u8) bool {
    const prefix = "C:\\R4OS\\FONTS\\";
    if (path.len < prefix.len + 4) return false;
    var index: usize = 0;
    while (index < prefix.len) : (index += 1) if (upper(path[index]) != upper(prefix[index])) return false;
    return upper(path[path.len - 3]) == 'R' and path[path.len - 2] == '4' and upper(path[path.len - 1]) == 'F';
}

fn copyZ(out: []u8, value: []const u8) void {
    @memset(out, 0);
    const count = @min(value.len, out.len - 1);
    if (count > 0) @memcpy(out[0..count], value[0..count]);
}

fn appendZ(out: []u8, value: []const u8) void {
    const at = spanZ(out).len;
    const count = @min(value.len, out.len - at - 1);
    if (count > 0) @memcpy(out[at .. at + count], value[0..count]);
}

fn appendDec(out: []u8, value: usize) void {
    var digits: [20]u8 = undefined;
    var n = value;
    var count: usize = 0;
    if (n == 0) {
        appendZ(out, "0");
        return;
    }
    while (n > 0) : (n /= 10) {
        digits[count] = '0' + @as(u8, @intCast(n % 10));
        count += 1;
    }
    while (count > 0) {
        count -= 1;
        var one: [1]u8 = .{digits[count]};
        appendZ(out, one[0..]);
    }
}

fn fixedSpan(value: []const u8) []const u8 {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn spanZ(value: []const u8) []const u8 {
    return fixedSpan(value);
}

fn zptr(value: []const u8) [*:0]const u8 {
    return @ptrCast(value.ptr);
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < 256 and args[cursor] != 0) {
        while (cursor < 256 and (args[cursor] == ' ' or args[cursor] == '\t')) : (cursor += 1) {}
        const start = cursor;
        while (cursor < 256 and args[cursor] != 0 and args[cursor] != ' ' and args[cursor] != '\t') : (cursor += 1) {}
        if (equalsIgnoreCase(args[start..cursor], wanted)) return true;
    }
    return false;
}

fn equalsIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, 0..) |ch, index| if (upper(ch) != upper(right[index])) return false;
    return true;
}

fn upper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}

fn clamp(value: i32, min: i32, max: i32) i32 {
    return @min(max, @max(min, value));
}
