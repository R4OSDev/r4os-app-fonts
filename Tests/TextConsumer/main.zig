//! Explicit headless fixture: execute the same application self-test source
//! without waiting for a hosted GUI launch before the first shell prompt.
const r4os = @import("r4os");
const fonts_app = @import("fonts_app");

pub fn r4_app_main(app: *r4os.App) i32 {
    return fonts_app.r4_app_main(app);
}
