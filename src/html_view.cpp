/*
 * html_view.cpp - render an HTML/CSS page to the RGB565 framebuffer using
 * litehtml (layout/CSS) + FreeType (text). devui becomes a thin HTML shell:
 * the UI is authored in ui/index.html, this draws it.
 *
 * No JavaScript; CSS grid is unsupported by litehtml (falls back to block).
 *
 * SPDX-License-Identifier: MIT
 */
#include <litehtml.h>

#include <ft2build.h>
#include FT_FREETYPE_H

#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <sys/stat.h>

using namespace litehtml;

/* ---- target framebuffer (shared with drm_disp, 180° rotated panel) ---- */
static uint16_t *g_fb;
static int g_w, g_h, g_pitch_px, g_rotate = 1;
static int g_clip_top = 0;

static inline void put_px(int x, int y, int r, int g, int b, int a)
{
    if (y < g_clip_top) return;
    if (x < 0 || y < 0 || x >= g_w || y >= g_h || a <= 0) return;
    int dx = g_rotate ? (g_w - 1 - x) : x;
    int dy = g_rotate ? (g_h - 1 - y) : y;
    uint16_t *p = &g_fb[dy * g_pitch_px + dx];
    if (a < 255) {
        uint16_t o = *p;
        int orr = ((o >> 11) & 0x1F) << 3, og = ((o >> 5) & 0x3F) << 2, ob = (o & 0x1F) << 3;
        r = (r * a + orr * (255 - a)) / 255;
        g = (g * a + og * (255 - a)) / 255;
        b = (b * a + ob * (255 - a)) / 255;
        static const int8_t dither[2][2] = {{-2, 1}, {2, -1}};
        int q = dither[y & 1][x & 1];
        r = std::max(0, std::min(255, r + q));
        g = std::max(0, std::min(255, g + q));
        b = std::max(0, std::min(255, b + q));
    }
    *p = (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

static int round_coverage(int x, int y, int fx, int fy, int fw, int fh,
                          int rtl, int rtr, int rbr, int rbl)
{
    int r = 0;
    float cx = 0, cy = 0;
    if (x < fx || y < fy || x >= fx + fw || y >= fy + fh) return 0;
    if      (x < fx + rtl       && y < fy + rtl)       { r = rtl; cx = fx + rtl;      cy = fy + rtl; }
    else if (x >= fx + fw - rtr && y < fy + rtr)       { r = rtr; cx = fx + fw - rtr; cy = fy + rtr; }
    else if (x >= fx + fw - rbr && y >= fy + fh - rbr) { r = rbr; cx = fx + fw - rbr; cy = fy + fh - rbr; }
    else if (x < fx + rbl       && y >= fy + fh - rbl) { r = rbl; cx = fx + rbl;      cy = fy + fh - rbl; }
    if (r <= 0) return 255;
    static const float sample[4][2] = {{.25f,.25f},{.75f,.25f},{.25f,.75f},{.75f,.75f}};
    int inside = 0;
    float rr = (float)r * r;
    for (int i = 0; i < 4; i++) {
        float dx = x + sample[i][0] - cx, dy = y + sample[i][1] - cy;
        if (dx * dx + dy * dy <= rr) inside++;
    }
    return inside * 255 / 4;
}

static inline uint16_t get_px565(int x, int y)
{
    if (x < 0 || y < 0 || x >= g_w || y >= g_h || !g_fb) return 0;
    int dx = g_rotate ? (g_w - 1 - x) : x;
    int dy = g_rotate ? (g_h - 1 - y) : y;
    return g_fb[dy * g_pitch_px + dx];
}

/* Is (x,y) inside a rounded rectangle? Used by both rounded fill and rounded
 * border stroking (litehtml hands us radii but leaves the drawing to us). */
static bool pt_in_round(int x, int y, int fx, int fy, int fw, int fh,
                        int rtl, int rtr, int rbr, int rbl)
{
    if (x < fx || y < fy || x >= fx + fw || y >= fy + fh) return false;
    int r = 0, cx = 0, cy = 0;
    if      (x < fx + rtl       && y < fy + rtl)       { r = rtl; cx = fx + rtl;          cy = fy + rtl; }
    else if (x >= fx + fw - rtr && y < fy + rtr)       { r = rtr; cx = fx + fw - 1 - rtr; cy = fy + rtr; }
    else if (x >= fx + fw - rbr && y >= fy + fh - rbr) { r = rbr; cx = fx + fw - 1 - rbr; cy = fy + fh - 1 - rbr; }
    else if (x < fx + rbl       && y >= fy + fh - rbl) { r = rbl; cx = fx + rbl;          cy = fy + fh - 1 - rbl; }
    if (r > 0) { int dx = x - cx, dy = y - cy; if (dx * dx + dy * dy > r * r) return false; }
    return true;
}

/* ---- FreeType ---- */
static FT_Library g_ft;
static FT_Face    g_face;

struct ft_font { int size; int ascent, descent, height; };

/* UI base dir (for <link> CSS / images) and last-clicked anchor href. */
static std::string g_ui_dir = "/data/plugins/u60pro-devui/ui";
static std::string g_clicked;

static long long css_file_mtime_ns(const std::string &path)
{
    struct stat st;
    if (stat(path.c_str(), &st) != 0) return -1;
    return (long long)st.st_mtime * 1000000000LL + (long long)st.st_mtim.tv_nsec;
}

struct css_cache_entry {
    std::string path;
    std::string text;
    long long mtime = -1;
    bool used = false;
};

static css_cache_entry g_css_cache[4];
static int g_css_cache_next;

static int read_file_text(const char *path, std::string &out)
{
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    long n;
    int ok = 0;
    if (fseek(f, 0, SEEK_END) == 0) {
        n = ftell(f);
        if (n >= 0) {
            if (n > 0) {
                out.resize((size_t)n);
                fseek(f, 0, SEEK_SET);
                ok = (fread(&out[0], 1, (size_t)n, f) == (size_t)n);
            } else {
                out.clear();
                ok = 1;
            }
        }
    }
    fclose(f);
    if (!ok) out.clear();
    return ok;
}

static void css_get_cached(std::string &out, const std::string &path)
{
    long long mtime = css_file_mtime_ns(path);
    if (mtime < 0) return;

    for (int i = 0; i < 4; i++) {
        css_cache_entry &e = g_css_cache[i];
        if (!e.used || e.path != path) continue;
        if (e.mtime == mtime && !e.text.empty()) {
            out = e.text;
            return;
        }
        if (read_file_text(path.c_str(), e.text)) {
            e.mtime = mtime;
            out = e.text;
            return;
        }
        out = e.text;
        return;
    }

    css_cache_entry *e = nullptr;
    for (int i = 0; i < 4; i++) {
        if (!g_css_cache[i].used) { e = &g_css_cache[i]; break; }
    }
    if (!e) {
        e = &g_css_cache[g_css_cache_next];
        g_css_cache_next = (g_css_cache_next + 1) % 4;
    }
    std::string next;
    if (!read_file_text(path.c_str(), next)) return;
    e->path = path;
    e->text = std::move(next);
    e->mtime = mtime;
    e->used = true;
    out = e->text;
}

static unsigned utf8_next(const char *&s)
{
    unsigned c = (unsigned char)*s++;
    if (c < 0x80) return c;
    int n = (c >= 0xF0) ? 3 : (c >= 0xE0) ? 2 : 1;
    c &= (0x3F >> n);
    while (n-- && (*s & 0xC0) == 0x80) c = (c << 6) | (*s++ & 0x3F);
    return c;
}

/* ---- container ---- */
class fb_container : public document_container {
    std::vector<position> m_clip;

    position eff_clip() const {
        position r(0, 0, (pixel_t)g_w, (pixel_t)g_h);
        for (auto &c : m_clip) {
            pixel_t x1 = std::max(r.left(), c.left()), y1 = std::max(r.top(), c.top());
            pixel_t x2 = std::min(r.right(), c.right()), y2 = std::min(r.bottom(), c.bottom());
            r = position(x1, y1, std::max<pixel_t>(0, x2 - x1), std::max<pixel_t>(0, y2 - y1));
        }
        return r;
    }
    void fill(pixel_t fx, pixel_t fy, pixel_t fw, pixel_t fh, web_color c) {
        if (c.alpha == 0) return;
        position cl = eff_clip();
        int x1 = std::max((int)fx, (int)cl.left()),  y1 = std::max((int)fy, (int)cl.top());
        int x2 = std::min((int)(fx + fw), (int)cl.right()), y2 = std::min((int)(fy + fh), (int)cl.bottom());
        for (int y = y1; y < y2; y++)
            for (int x = x1; x < x2; x++)
                put_px(x, y, c.red, c.green, c.blue, c.alpha);
    }
    /* Filled rectangle with rounded corners. litehtml only hands us the radii;
     * it's up to the container to honor them, so a pixel inside one of the four
     * corner squares but outside its quarter-circle arc is skipped. */
    void fill_rounded(int fx, int fy, int fw, int fh, int rtl, int rtr, int rbr, int rbl, web_color c) {
        if (c.alpha == 0 || fw <= 0 || fh <= 0) return;
        int hw = fw / 2, hh = fh / 2;
        if (rtl > hw) rtl = hw; if (rtl > hh) rtl = hh;
        if (rtr > hw) rtr = hw; if (rtr > hh) rtr = hh;
        if (rbr > hw) rbr = hw; if (rbr > hh) rbr = hh;
        if (rbl > hw) rbl = hw; if (rbl > hh) rbl = hh;
        position cl = eff_clip();
        int x1 = std::max(fx, (int)cl.left()),  y1 = std::max(fy, (int)cl.top());
        int x2 = std::min(fx + fw, (int)cl.right()), y2 = std::min(fy + fh, (int)cl.bottom());
        for (int y = y1; y < y2; y++) {
            for (int x = x1; x < x2; x++) {
                int r = 0, cx = 0, cy = 0;
                if      (x < fx + rtl       && y < fy + rtl)       { r = rtl; cx = fx + rtl;          cy = fy + rtl; }
                else if (x >= fx + fw - rtr && y < fy + rtr)       { r = rtr; cx = fx + fw - 1 - rtr; cy = fy + rtr; }
                else if (x >= fx + fw - rbr && y >= fy + fh - rbr) { r = rbr; cx = fx + fw - 1 - rbr; cy = fy + fh - 1 - rbr; }
                else if (x < fx + rbl       && y >= fy + fh - rbl) { r = rbl; cx = fx + rbl;          cy = fy + fh - 1 - rbl; }
                int cov = r > 0 ? round_coverage(x, y, fx, fy, fw, fh, rtl, rtr, rbr, rbl) : 255;
                if (cov) put_px(x, y, c.red, c.green, c.blue, c.alpha * cov / 255);
            }
        }
    }
    /* Stroke a rounded-rect outline of uniform thickness t: a pixel inside the
     * outer rounded rect but outside the inner one (inset by t). */
    void stroke_rounded(int fx, int fy, int fw, int fh, int rtl, int rtr, int rbr, int rbl, int t, web_color c) {
        if (c.alpha == 0 || t <= 0 || fw <= 0 || fh <= 0) return;
        int hw = fw / 2, hh = fh / 2;
        if (rtl > hw) rtl = hw; if (rtl > hh) rtl = hh;
        if (rtr > hw) rtr = hw; if (rtr > hh) rtr = hh;
        if (rbr > hw) rbr = hw; if (rbr > hh) rbr = hh;
        if (rbl > hw) rbl = hw; if (rbl > hh) rbl = hh;
        int itl = rtl - t > 0 ? rtl - t : 0, itr = rtr - t > 0 ? rtr - t : 0;
        int ibr = rbr - t > 0 ? rbr - t : 0, ibl = rbl - t > 0 ? rbl - t : 0;
        position cl = eff_clip();
        int x1 = std::max(fx, (int)cl.left()),  y1 = std::max(fy, (int)cl.top());
        int x2 = std::min(fx + fw, (int)cl.right()), y2 = std::min(fy + fh, (int)cl.bottom());
        for (int y = y1; y < y2; y++)
            for (int x = x1; x < x2; x++)
                {
                    int outer = round_coverage(x, y, fx, fy, fw, fh, rtl, rtr, rbr, rbl);
                    int inner = round_coverage(x, y, fx + t, fy + t, fw - 2 * t, fh - 2 * t,
                                               itl, itr, ibr, ibl);
                    int cov = outer > inner ? outer - inner : 0;
                    if (cov) put_px(x, y, c.red, c.green, c.blue, c.alpha * cov / 255);
                }
    }

    void fill_background_box(const background_layer &layer, web_color c) {
        const position &b = layer.border_box;
        const border_radiuses &br = layer.border_radius;
        if (br.top_left_x > 0 || br.top_right_x > 0 || br.bottom_right_x > 0 || br.bottom_left_x > 0)
            fill_rounded(b.x, b.y, b.width, b.height,
                         (int)br.top_left_x, (int)br.top_right_x,
                         (int)br.bottom_right_x, (int)br.bottom_left_x, c);
        else
            fill(b.x, b.y, b.width, b.height, c);
    }

public:
    uint_ptr create_font(const font_description &d, const document *, font_metrics *fm) override {
        auto *f = new ft_font();
        f->size = (int)d.size;
        FT_Set_Pixel_Sizes(g_face, 0, f->size);
        f->ascent  = g_face->size->metrics.ascender >> 6;
        f->descent = -(g_face->size->metrics.descender >> 6);
        f->height  = g_face->size->metrics.height >> 6;
        if (fm) {
            fm->font_size = d.size;
            fm->ascent = f->ascent; fm->descent = f->descent;
            fm->height = f->height ? f->height : f->size;
            fm->x_height = f->size / 2; fm->ch_width = f->size / 2;
            fm->draw_spaces = true;
        }
        return (uint_ptr)f;
    }
    void delete_font(uint_ptr h) override { delete (ft_font *)h; }

    pixel_t text_width(const char *text, uint_ptr h) override {
        auto *f = (ft_font *)h;
        FT_Set_Pixel_Sizes(g_face, 0, f->size);
        FT_Pos pen = 0;
        for (const char *s = text; *s; ) {
            unsigned cp = utf8_next(s);
            if (FT_Load_Char(g_face, cp, FT_LOAD_DEFAULT)) continue;
            pen += g_face->glyph->advance.x;
        }
        return (pixel_t)((pen + 32) >> 6);
    }

    void draw_text(uint_ptr, const char *text, uint_ptr h, web_color color, const position &pos) override {
        auto *f = (ft_font *)h;
        FT_Set_Pixel_Sizes(g_face, 0, f->size);
        FT_Pos pen = (FT_Pos)pos.x << 6;
        int base = (int)pos.y + f->ascent;
        position cl = eff_clip();
        for (const char *s = text; *s; ) {
            unsigned cp = utf8_next(s);
            if (FT_Load_Char(g_face, cp, FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT)) continue;
            FT_GlyphSlot gl = g_face->glyph;
            FT_Bitmap &bm = gl->bitmap;
            int ox = (int)(pen >> 6) + gl->bitmap_left, oy = base - gl->bitmap_top;
            for (int r = 0; r < (int)bm.rows; r++) {
                int yy = oy + r;
                if (yy < (int)cl.top() || yy >= (int)cl.bottom()) continue;
                for (int cx = 0; cx < (int)bm.width; cx++) {
                    int xx = ox + cx;
                    if (xx < (int)cl.left() || xx >= (int)cl.right()) continue;
                    int a = bm.buffer[r * bm.pitch + cx];
                    if (a) put_px(xx, yy, color.red, color.green, color.blue, a * color.alpha / 255);
                }
            }
            pen += gl->advance.x;
        }
    }

    pixel_t pt_to_px(float pt) const override { return (pixel_t)(pt * 96.0f / 72.0f + 0.5f); }
    pixel_t get_default_font_size() const override { return 16; }
    const char *get_default_font_name() const override { return "sans-serif"; }

    void draw_solid_fill(uint_ptr, const background_layer &layer, const web_color &color) override {
        fill_background_box(layer, color);
    }
    /* Approximate gradients with a representative flat dark color. */
    void draw_linear_gradient(uint_ptr, const background_layer &l, const background_layer::linear_gradient &) override {
        fill_background_box(l, web_color(45, 46, 50));
    }
    void draw_radial_gradient(uint_ptr, const background_layer &l, const background_layer::radial_gradient &) override {
        fill_background_box(l, web_color(45, 46, 50));
    }
    void draw_conic_gradient(uint_ptr, const background_layer &l, const background_layer::conic_gradient &) override {
        fill_background_box(l, web_color(45, 46, 50));
    }

    void draw_borders(uint_ptr, const borders &b, const position &p, bool) override {
        /* Rounded outline for the common case: all four sides equal width, same
         * color, with a corner radius (cards, the battery frame, ...). */
        int rtl = (int)b.radius.top_left_x, rtr = (int)b.radius.top_right_x;
        int rbr = (int)b.radius.bottom_right_x, rbl = (int)b.radius.bottom_left_x;
        const web_color &tc = b.top.color;
        bool same_w = b.top.width == b.left.width && b.top.width == b.right.width && b.top.width == b.bottom.width;
        bool same_c = tc.red == b.left.color.red && tc.green == b.left.color.green && tc.blue == b.left.color.blue && tc.alpha == b.left.color.alpha
                   && tc.red == b.right.color.red && tc.green == b.right.color.green && tc.blue == b.right.color.blue && tc.alpha == b.right.color.alpha
                   && tc.red == b.bottom.color.red && tc.green == b.bottom.color.green && tc.blue == b.bottom.color.blue && tc.alpha == b.bottom.color.alpha;
        bool all_solid = b.top.style != border_style_none && b.left.style != border_style_none
                      && b.right.style != border_style_none && b.bottom.style != border_style_none;
        if ((rtl || rtr || rbr || rbl) && same_w && same_c && all_solid && b.top.width > 0) {
            stroke_rounded(p.x, p.y, p.width, p.height, rtl, rtr, rbr, rbl, b.top.width, tc);
            return;
        }
        if (b.top.width > 0    && b.top.style    != border_style_none) fill(p.x, p.y, p.width, b.top.width, b.top.color);
        if (b.bottom.width > 0 && b.bottom.style != border_style_none) fill(p.x, p.bottom() - b.bottom.width, p.width, b.bottom.width, b.bottom.color);
        if (b.left.width > 0   && b.left.style   != border_style_none) fill(p.x, p.y, b.left.width, p.height, b.left.color);
        if (b.right.width > 0  && b.right.style  != border_style_none) fill(p.right() - b.right.width, p.y, b.right.width, p.height, b.right.color);
    }

    void draw_list_marker(uint_ptr, const list_marker &) override {}

    /* images: not supported (the example uses none) */
    void load_image(const char *, const char *, bool) override {}
    void get_image_size(const char *, const char *, size &sz) override { sz.width = sz.height = 0; }
    void draw_image(uint_ptr, const background_layer &, const std::string &, const std::string &) override {}

    void set_clip(const position &pos, const border_radiuses &) override { m_clip.push_back(pos); }
    void del_clip() override { if (!m_clip.empty()) m_clip.pop_back(); }
    void reset_state() { m_clip.clear(); }

    void get_viewport(position &v) const override { v = position(0, 0, (pixel_t)g_w, (pixel_t)g_h); }
    void get_media_features(media_features &m) const override {
        m.type = media_type_screen;
        m.width = m.device_width = (pixel_t)g_w;
        m.height = m.device_height = (pixel_t)g_h;
        m.color = 8; m.resolution = 96;
    }
    void get_language(string &, string &) const override {}

    /* trivial stubs */
    void set_caption(const char *) override {}
    void set_base_url(const char *) override {}
    void link(const std::shared_ptr<document> &, const element::ptr &) override {}
    void on_anchor_click(const char *url, const element::ptr &) override { g_clicked = url ? url : ""; }
    void on_mouse_event(const element::ptr &, mouse_event) override {}
    void set_cursor(const char *) override {}
    void transform_text(string &, text_transform) override {}
    void import_css(string &text, const string &url, string &) override {
        std::string path = g_ui_dir + "/" + url;
        css_get_cached(text, path);
    }
    element::ptr create_element(const char *, const string_map &, const std::shared_ptr<document> &) override { return nullptr; }
};

/* ---- C interface for the (C) main harness ---- */
static fb_container   *g_container;
static document::ptr   g_doc;
static int             g_scroll_y;   /* vertical scroll offset (logical px) */
static int             g_doc_overlay; /* overlay docs are already in screen coords */

extern "C" void html_view_init(uint16_t *fb, int w, int h, int pitch_px, int rotate, const char *font_path)
{
    g_fb = fb; g_w = w; g_h = h; g_pitch_px = pitch_px; g_rotate = rotate;
    FT_Init_FreeType(&g_ft);
    if (FT_New_Face(g_ft, font_path, 0, &g_face))
        fprintf(stderr, "html_view: cannot load font %s\n", font_path);
    g_container = new fb_container();
}

/* Parse + lay out + paint an HTML string into the framebuffer. Returns height. */
extern "C" int html_view_render_html(const char *html)
{
    if (!html || !g_container) return -1;
    g_container->reset_state();
    g_doc.reset();
    document::ptr doc = document::createFromString(html, g_container);
    if (!doc) return -1;

    g_doc = doc;
    g_doc_overlay = 0;
    g_doc->render((pixel_t)g_w);
    for (int i = 0; i < g_pitch_px * g_h; i++) g_fb[i] = 0;
    position clip(0, 0, (pixel_t)g_w, (pixel_t)g_h);
    g_doc->draw((uint_ptr)0, 0, -g_scroll_y, &clip);   /* shift up by scroll */
    element::ptr root = g_doc->root();                 /* full content height */
    return root ? (int)root->get_placement().height : g_h;
}

/* Render an overlay on top of the current framebuffer (no clear): the body must
 * be transparent so only its boxes paint. g_doc is set to the overlay so taps
 * hit it. Used for modal dialogs. */
extern "C" int html_view_render_overlay(const char *html)
{
    if (!html || !g_container) return -1;
    g_container->reset_state();
    g_doc.reset();
    document::ptr doc = document::createFromString(html, g_container);
    if (!doc) return -1;

    g_doc = doc;
    g_doc_overlay = 1;
    g_doc->render((pixel_t)g_w);
    position clip(0, 0, (pixel_t)g_w, (pixel_t)g_h);
    g_doc->draw((uint_ptr)0, 0, 0, &clip);
    return 0;
}

/* Render into a plain logical W*H RGB565 buffer (no rotation) for animations. */
extern "C" int html_view_render_to(uint16_t *buf, const char *html)
{
    uint16_t *sfb = g_fb; int sw = g_w, sh = g_h, sp = g_pitch_px, sr = g_rotate, ssc = g_scroll_y;
    g_fb = buf; g_w = sw; g_h = sh; g_pitch_px = sw; g_rotate = 0; g_scroll_y = 0;
    int hh = html_view_render_html(html);
    g_fb = sfb; g_w = sw; g_h = sh; g_pitch_px = sp; g_rotate = sr; g_scroll_y = ssc;
    return hh;
}

extern "C" int html_view_render_to_scroll(uint16_t *buf, const char *html, int scroll)
{
    uint16_t *sfb = g_fb; int sw = g_w, sh = g_h, sp = g_pitch_px, sr = g_rotate, ssc = g_scroll_y;
    g_fb = buf; g_w = sw; g_h = sh; g_pitch_px = sw; g_rotate = 0; g_scroll_y = scroll < 0 ? 0 : scroll;
    int hh = html_view_render_html(html);
    g_fb = sfb; g_w = sw; g_h = sh; g_pitch_px = sp; g_rotate = sr; g_scroll_y = ssc;
    return hh;
}

static uint16_t *g_saved_fb = nullptr;
static int g_saved_w = 0, g_saved_h = 0, g_saved_pitch = 0, g_saved_rotate = 0, g_saved_scroll = 0;

extern "C" void html_view_target_begin(uint16_t *buf, int scroll)
{
    if (g_saved_fb) return;
    g_saved_fb = g_fb; g_saved_w = g_w; g_saved_h = g_h;
    g_saved_pitch = g_pitch_px; g_saved_rotate = g_rotate; g_saved_scroll = g_scroll_y;
    g_fb = buf; g_pitch_px = g_w; g_rotate = 0; g_scroll_y = scroll < 0 ? 0 : scroll;
}

extern "C" void html_view_target_begin_size(uint16_t *buf, int h, int scroll)
{
    if (g_saved_fb || !buf || h <= 0) return;
    g_saved_fb = g_fb; g_saved_w = g_w; g_saved_h = g_h;
    g_saved_pitch = g_pitch_px; g_saved_rotate = g_rotate; g_saved_scroll = g_scroll_y;
    g_fb = buf; g_h = h; g_pitch_px = g_w; g_rotate = 0;
    g_scroll_y = scroll < 0 ? 0 : scroll;
}

extern "C" void html_view_target_end(void)
{
    if (!g_saved_fb) return;
    g_fb = g_saved_fb; g_w = g_saved_w; g_h = g_saved_h;
    g_pitch_px = g_saved_pitch; g_rotate = g_saved_rotate; g_scroll_y = g_saved_scroll;
    g_saved_fb = nullptr;
}

extern "C" int html_view_render_to_size(uint16_t *buf, int w, int h, const char *html)
{
    uint16_t *sfb = g_fb; int sw = g_w, sh = g_h, sp = g_pitch_px, sr = g_rotate, ssc = g_scroll_y;
    g_fb = buf; g_w = w; g_h = h; g_pitch_px = w; g_rotate = 0; g_scroll_y = 0;
    int hh = html_view_render_html(html);
    g_fb = sfb; g_w = sw; g_h = sh; g_pitch_px = sp; g_rotate = sr; g_scroll_y = ssc;
    return hh;
}

extern "C" void html_view_set_uidir(const char *d) { g_ui_dir = d; }
extern "C" void html_view_set_scroll(int y) { g_scroll_y = y < 0 ? 0 : y; }
extern "C" void html_view_set_clip_top(int y) { g_clip_top = y < 0 ? 0 : y; }

/* Render the full page (no rotation, no clip to 480) into a tall W*bufh logical
 * buffer, for smooth windowed scrolling. Returns content height. */
extern "C" int html_view_render_tall(uint16_t *buf, const char *html, int bufh)
{
    uint16_t *sfb = g_fb; int sh = g_h, sp = g_pitch_px, sr = g_rotate, ssc = g_scroll_y;
    g_fb = buf; g_h = bufh; g_pitch_px = g_w; g_rotate = 0; g_scroll_y = 0;
    int hh = html_view_render_html(html);
    g_fb = sfb; g_h = sh; g_pitch_px = sp; g_rotate = sr; g_scroll_y = ssc;
    return hh;
}

/* Paint the already parsed and laid-out document into a tall logical buffer.
 * This is the vertical-drag fast path: no HTML parsing and no second layout. */
extern "C" int html_view_draw_current_tall(uint16_t *buf, int bufh)
{
    if (!buf || !g_doc || !g_container || bufh <= 0) return -1;
    uint16_t *sfb = g_fb;
    int sh = g_h, sp = g_pitch_px, sr = g_rotate, ssc = g_scroll_y;
    g_fb = buf; g_h = bufh; g_pitch_px = g_w; g_rotate = 0; g_scroll_y = 0;
    std::fill(buf, buf + (size_t)g_w * bufh, 0);
    g_container->reset_state();
    position clip(0, 0, (pixel_t)g_w, (pixel_t)bufh);
    g_doc->draw((uint_ptr)0, 0, 0, &clip);
    element::ptr root = g_doc->root();
    int hh = root ? (int)root->get_placement().height : sh;
    g_fb = sfb; g_h = sh; g_pitch_px = sp; g_rotate = sr; g_scroll_y = ssc;
    return hh;
}

extern "C" void html_view_suspend(void)
{
    g_doc.reset();
    g_clicked.clear();
    if (g_container) g_container->reset_state();
    for (auto &e : g_css_cache) {
        e.path.clear();
        e.text.clear();
        e.text.shrink_to_fit();
        e.mtime = -1;
        e.used = false;
    }
}

/* Fill a rect directly (used for the scrollbar overlay). */
extern "C" void html_view_fill_rect(int x, int y, int w, int h, int r, int g, int b, int a)
{
    for (int yy = y; yy < y + h; yy++)
        for (int xx = x; xx < x + w; xx++)
            put_px(xx, yy, r, g, b, a);
}

/* Fill an arbitrary (possibly concave) polygon via scanline parity. Used by the
 * host to draw shapes litehtml/CSS can't — e.g. the battery charging bolt. */
extern "C" void html_view_fill_poly(const int *xs, const int *ys, int n, int r, int g, int b, int a)
{
    if (n < 3) return;
    int ymin = ys[0], ymax = ys[0];
    for (int i = 1; i < n; i++) { if (ys[i] < ymin) ymin = ys[i]; if (ys[i] > ymax) ymax = ys[i]; }
    for (int y = ymin; y <= ymax; y++) {
        int xi[16], cnt = 0;
        for (int i = 0; i < n && cnt < 16; i++) {
            int j = (i + 1) % n;
            int y0 = ys[i], y1 = ys[j], x0 = xs[i], x1 = xs[j];
            if (y0 == y1) continue;
            if ((y >= y0 && y < y1) || (y >= y1 && y < y0))
                xi[cnt++] = x0 + (int)((long)(y - y0) * (x1 - x0) / (y1 - y0));
        }
        for (int i = 0; i < cnt; i++)            /* sort intersections ascending */
            for (int k = i + 1; k < cnt; k++)
                if (xi[k] < xi[i]) { int t = xi[i]; xi[i] = xi[k]; xi[k] = t; }
        for (int i = 0; i + 1 < cnt; i += 2)
            for (int x = xi[i]; x <= xi[i + 1]; x++)
                put_px(x, y, r, g, b, a);
    }
}

/* Filled rounded rectangle directly (host overlays like the lock icon). */
extern "C" void html_view_fill_round_rect(int x, int y, int w, int h, int rad, int r, int g, int b, int a)
{
    if (w <= 0 || h <= 0) return;
    for (int yy = y; yy < y + h; yy++)
        for (int xx = x; xx < x + w; xx++)
            {
                int cov = round_coverage(xx, yy, x, y, w, h, rad, rad, rad, rad);
                if (cov) put_px(xx, yy, r, g, b, a * cov / 255);
            }
}

extern "C" int html_view_text_width_px(const char *text, int size)
{
    if (!g_face || !text) return 0;
    FT_Set_Pixel_Sizes(g_face, 0, size);
    int w = 0;
    for (const char *s = text; *s; ) {
        unsigned cp = utf8_next(s);
        if (FT_Load_Char(g_face, cp, FT_LOAD_DEFAULT)) continue;
        w += g_face->glyph->advance.x >> 6;
    }
    return w;
}

extern "C" void html_view_text_bounds_px(const char *text, int size,
                                         int *x0, int *y0, int *x1, int *y1)
{
    if (x0) *x0 = 0;
    if (y0) *y0 = 0;
    if (x1) *x1 = 0;
    if (y1) *y1 = 0;
    if (!g_face || !text) return;
    FT_Set_Pixel_Sizes(g_face, 0, size);
    int ascent = g_face->size->metrics.ascender >> 6;
    FT_Pos pen = 0;
    int minx = 0, miny = 0, maxx = 0, maxy = 0, seen = 0;
    for (const char *s = text; *s; ) {
        unsigned cp = utf8_next(s);
        if (FT_Load_Char(g_face, cp, FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT)) continue;
        FT_GlyphSlot gl = g_face->glyph;
        int gx0 = (int)(pen >> 6) + gl->bitmap_left;
        int gy0 = ascent - gl->bitmap_top;
        int gx1 = gx0 + (int)gl->bitmap.width;
        int gy1 = gy0 + (int)gl->bitmap.rows;
        if (!seen) {
            minx = gx0; miny = gy0; maxx = gx1; maxy = gy1; seen = 1;
        } else {
            if (gx0 < minx) minx = gx0;
            if (gy0 < miny) miny = gy0;
            if (gx1 > maxx) maxx = gx1;
            if (gy1 > maxy) maxy = gy1;
        }
        pen += gl->advance.x;
    }
    if (!seen) return;
    if (x0) *x0 = minx;
    if (y0) *y0 = miny;
    if (x1) *x1 = maxx;
    if (y1) *y1 = maxy;
}

extern "C" void html_view_draw_text_px(int x, int y, const char *text, int size, int bold,
                                       int r, int g, int b, int a)
{
    if (!g_face || !text) return;
    FT_Set_Pixel_Sizes(g_face, 0, size);
    int ascent = g_face->size->metrics.ascender >> 6;
    FT_Pos pen = (FT_Pos)x << 6;
    int base = y + ascent;
    for (const char *s = text; *s; ) {
        unsigned cp = utf8_next(s);
        if (FT_Load_Char(g_face, cp, FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT)) continue;
        FT_GlyphSlot gl = g_face->glyph;
        FT_Bitmap &bm = gl->bitmap;
        for (int pass = 0; pass < (bold ? 2 : 1); pass++) {
            int ox = (int)(pen >> 6) + gl->bitmap_left + pass, oy = base - gl->bitmap_top;
            for (int row = 0; row < (int)bm.rows; row++)
                for (int col = 0; col < (int)bm.width; col++) {
                    int aa = bm.buffer[row * bm.pitch + col];
                    if (aa) put_px(ox + col, oy + row, r, g, b, aa * a / 255);
                }
        }
        pen += gl->advance.x;
    }
}

extern "C" void html_view_draw_text_contrast_px(int x, int y, const char *text, int size, int bold,
                                                int dr, int dg, int db, int lr, int lg, int lb, int a)
{
    if (!g_face || !text) return;
    FT_Set_Pixel_Sizes(g_face, 0, size);
    int ascent = g_face->size->metrics.ascender >> 6;
    FT_Pos pen = (FT_Pos)x << 6;
    int base = y + ascent;
    for (const char *s = text; *s; ) {
        unsigned cp = utf8_next(s);
        if (FT_Load_Char(g_face, cp, FT_LOAD_RENDER | FT_LOAD_TARGET_LIGHT)) continue;
        FT_GlyphSlot gl = g_face->glyph;
        FT_Bitmap &bm = gl->bitmap;
        for (int pass = 0; pass < (bold ? 2 : 1); pass++) {
            int ox = (int)(pen >> 6) + gl->bitmap_left + pass, oy = base - gl->bitmap_top;
            for (int row = 0; row < (int)bm.rows; row++)
                for (int col = 0; col < (int)bm.width; col++) {
                    int aa = bm.buffer[row * bm.pitch + col];
                    if (!aa) continue;
                    uint16_t bg = get_px565(ox + col, oy + row);
                    int br = ((bg >> 11) & 0x1F) * 255 / 31;
                    int bgc = ((bg >> 5) & 0x3F) * 255 / 63;
                    int bb = (bg & 0x1F) * 255 / 31;
                    int luma = (br * 299 + bgc * 587 + bb * 114) / 1000;
                    int r = luma > 116 ? dr : lr;
                    int g = luma > 116 ? dg : lg;
                    int b = luma > 116 ? db : lb;
                    put_px(ox + col, oy + row, r, g, b, aa * a / 255);
                }
        }
        pen += gl->advance.x;
    }
}

/* Hit-test a tap; returns the clicked anchor href ("" if none). */
extern "C" const char *html_view_click(float x, float y)
{
    g_clicked.clear();
    if (g_doc) {
        position::vector rb;
        float yy = y + (g_doc_overlay ? 0 : g_scroll_y);
        g_doc->on_lbutton_down(x, yy, x, yy, rb);
        g_doc->on_lbutton_up(x, yy, x, yy, rb);
    }
    return g_clicked.c_str();
}

/* ---- custom chart drawing: native polylines into a litehtml placeholder ----
 * Flow: render the page (which lays out an empty <div id="chart-..">), query the
 * div's box with html_view_rect(), then draw series into it with html_view_polyline().
 * Coords are logical (pre-rotation); put_px maps to the panel. */

/* Bresenham line, thick px wide, clipped to [rx,rx+rw) x [ry,ry+rh). */
static void chart_line(int x0, int y0, int x1, int y1,
                       int rx, int ry, int rw, int rh, int r, int g, int b, int thick)
{
    if (thick == 1 && x0 != x1 && y0 != y1) {
        bool steep = std::abs(y1 - y0) > std::abs(x1 - x0);
        if (steep) { std::swap(x0, y0); std::swap(x1, y1); }
        if (x0 > x1) { std::swap(x0, x1); std::swap(y0, y1); }
        float grad = (float)(y1 - y0) / (float)(x1 - x0);
        float yy = (float)y0;
        for (int xx = x0; xx <= x1; xx++, yy += grad) {
            int iy = (int)std::floor(yy);
            int a0 = (int)((1.0f - (yy - iy)) * 255.0f);
            int a1 = 255 - a0;
            int px0 = steep ? iy : xx, py0 = steep ? xx : iy;
            int px1 = steep ? iy + 1 : xx, py1 = steep ? xx : iy + 1;
            if (px0 >= rx && px0 < rx + rw && py0 >= ry && py0 < ry + rh)
                put_px(px0, py0, r, g, b, a0);
            if (px1 >= rx && px1 < rx + rw && py1 >= ry && py1 < ry + rh)
                put_px(px1, py1, r, g, b, a1);
        }
        return;
    }
    int dx = std::abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -std::abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    for (;;) {
        for (int ty = 0; ty < thick; ty++)
            for (int tx = 0; tx < thick; tx++) {
                int px = x0 + tx, py = y0 + ty;
                if (px >= rx && px < rx + rw && py >= ry && py < ry + rh)
                    put_px(px, py, r, g, b, 255);
            }
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

/* Coverage-based stroke for small chart lines. The geometry remains a straight
 * segment; only edge pixels are blended, so this does not smooth the data. */
static void chart_line_aa(int x0, int y0, int x1, int y1,
                          int rx, int ry, int rw, int rh,
                          int r, int g, int b, int thick)
{
    float vx = (float)(x1 - x0), vy = (float)(y1 - y0);
    float len2 = vx * vx + vy * vy;
    float half = std::max(0.5f, thick * 0.5f);
    int pad = (int)std::ceil(half + 0.5f);
    int left = std::max(rx, std::min(x0, x1) - pad);
    int right = std::min(rx + rw - 1, std::max(x0, x1) + pad);
    int top = std::max(ry, std::min(y0, y1) - pad);
    int bottom = std::min(ry + rh - 1, std::max(y0, y1) + pad);

    for (int py = top; py <= bottom; py++) {
        for (int px = left; px <= right; px++) {
            float qx = px + 0.5f - x0, qy = py + 0.5f - y0;
            float t = len2 > 0.0f ? (qx * vx + qy * vy) / len2 : 0.0f;
            t = std::max(0.0f, std::min(1.0f, t));
            float dx = qx - t * vx, dy = qy - t * vy;
            float coverage = half + 0.5f - std::sqrt(dx * dx + dy * dy);
            if (coverage <= 0.0f) continue;
            int alpha = (int)(std::min(1.0f, coverage) * 255.0f + 0.5f);
            put_px(px, py, r, g, b, alpha);
        }
    }
}

/* Find an element by CSS selector and return its laid-out box. 1 if found. */
extern "C" int html_view_rect(const char *sel, int *x, int *y, int *w, int *h)
{
    if (!g_doc) return 0;
    element::ptr root = g_doc->root();
    if (!root) return 0;
    element::ptr el = root->select_one(sel);
    if (!el) return 0;
    position p = el->get_placement();
    int sy = g_doc_overlay ? 0 : g_scroll_y;
    *x = (int)p.x; *y = (int)p.y - sy; *w = (int)p.width; *h = (int)p.height;
    return (*w > 1 && *h > 1);
}

/* Draw a value series as a polyline inside the rect. vals normalized by
 * [vmin,vmax]; top = vmax. fill_a>0 fills the area under the line at that alpha. */
extern "C" void html_view_polyline(int x, int y, int w, int h,
                                   const int *vals, int n, int vmin, int vmax,
                                   int r, int g, int b, int thick, int fill_a)
{
    if (n <= 0 || w <= 1 || h <= 1) return;
    if (vmax <= vmin) vmax = vmin + 1;

    if (fill_a > 0) {
        for (int col = 0; col < w; col++) {
            double t = (n > 1) ? (double)col / (w - 1) * (n - 1) : 0.0;
            int i0 = (int)t; double fr = t - i0;
            int v0 = vals[i0], v1 = (i0 + 1 < n) ? vals[i0 + 1] : v0;
            double v = v0 + (v1 - v0) * fr;
            if (v < vmin) v = vmin; if (v > vmax) v = vmax;
            int py = y + (h - 1) - (int)((v - vmin) * (h - 1) / (vmax - vmin));
            for (int yy = py; yy < y + h; yy++)
                if (((col + yy) & 1) == 0) put_px(x + col, yy, r, g, b, fill_a);
        }
    }

    int px = 0, py = 0;
    for (int i = 0; i < n; i++) {
        int v = vals[i]; if (v < vmin) v = vmin; if (v > vmax) v = vmax;
        int cx = x + (n > 1 ? i * (w - 1) / (n - 1) : 0);
        int cy = y + (h - 1) - (int)((long)(v - vmin) * (h - 1) / (vmax - vmin));
        if (i > 0) chart_line(px, py, cx, cy, x, y, w, h, r, g, b, thick);
        px = cx; py = cy;
    }
}


struct chart_column {
    bool used = false;
    int first_y = 0, min_y = 0, max_y = 0, last_y = 0;
    uint32_t first_ts = 0, min_ts = 0, max_ts = 0, last_ts = 0;
};

/* Timestamp-aware chart renderer. Samples are mapped to a fixed time window,
 * partial history stays right-aligned, and missing seconds remain visible. */
extern "C" void html_view_timed_polyline(int x, int y, int w, int h,
                                          const uint32_t *times, const int *vals, int n,
                                          uint32_t now_sec, int window_sec,
                                          int vmin, int vmax, int r, int g, int b,
                                          int thick, int fill_a)
{
    if (!times || !vals || n <= 0 || w <= 1 || h <= 1 || window_sec <= 0) return;
    if (vmax <= vmin) vmax = vmin + 1;
    uint32_t left_sec = now_sec > (uint32_t)window_sec ? now_sec - (uint32_t)window_sec : 0;
    std::vector<chart_column> cols((size_t)w);

    for (int i = 0; i < n; i++) {
        uint32_t ts = times[i];
        int v = vals[i];
        int col, py;
        chart_column *c;
        if (ts < left_sec || ts > now_sec) continue;
        if (v < vmin) v = vmin;
        if (v > vmax) v = vmax;
        col = (int)(((uint64_t)(ts - left_sec) * (uint32_t)(w - 1)) /
                    (uint32_t)window_sec);
        py = y + (h - 1) - (int)((int64_t)(v - vmin) * (h - 1) / (vmax - vmin));
        c = &cols[(size_t)col];
        if (!c->used) {
            c->used = true;
            c->first_y = c->min_y = c->max_y = c->last_y = py;
            c->first_ts = c->min_ts = c->max_ts = c->last_ts = ts;
        } else {
            if (py < c->min_y) { c->min_y = py; c->min_ts = ts; }
            if (py > c->max_y) { c->max_y = py; c->max_ts = ts; }
            c->last_y = py;
            c->last_ts = ts;
        }
    }

    if (fill_a > 0) {
        bool have_prev = false;
        int prev_col = 0, prev_y = 0;
        uint32_t prev_ts = 0;
        for (int i = 0; i < n; i++) {
            uint32_t ts = times[i];
            int v = vals[i];
            int col, py, from, to;
            if (ts < left_sec || ts > now_sec) continue;
            if (v < vmin) v = vmin;
            if (v > vmax) v = vmax;
            col = (int)(((uint64_t)(ts - left_sec) * (uint32_t)(w - 1)) /
                        (uint32_t)window_sec);
            py = y + (h - 1) - (int)((int64_t)(v - vmin) * (h - 1) / (vmax - vmin));
            from = col;
            to = col;
            /* One missed scheduler second is common during a full page redraw.
             * Keep that continuous; two consecutive misses remain a real gap. */
            if (have_prev && ts >= prev_ts && ts - prev_ts <= 2) from = prev_col;
            for (int cc = from; cc <= to; cc++) {
                int top_y = py;
                if (to > from)
                    top_y = prev_y + (py - prev_y) * (cc - from) / (to - from);
                for (int yy = top_y; yy < y + h; yy++)
                    if (((cc + yy) & 1) == 0) put_px(x + cc, yy, r, g, b, fill_a);
            }
            prev_col = col;
            prev_y = py;
            prev_ts = ts;
            have_prev = true;
        }
    }

    bool have_prev = false;
    int prev_x = 0, prev_y = 0;
    uint32_t prev_ts = 0;
    for (int col = 0; col < w; col++) {
        const chart_column &c = cols[(size_t)col];
        struct point { int y; uint32_t ts; } p[4] = {
            {c.first_y, c.first_ts}, {c.min_y, c.min_ts},
            {c.max_y, c.max_ts}, {c.last_y, c.last_ts}
        };
        if (!c.used) continue;
        std::sort(p, p + 4, [](const point &a, const point &b) { return a.ts < b.ts; });
        for (int k = 0; k < 4; k++) {
            if (k > 0 && p[k].ts == p[k - 1].ts && p[k].y == p[k - 1].y) continue;
            int cx = x + col;
            if (have_prev && p[k].ts >= prev_ts && p[k].ts - prev_ts <= 2)
                chart_line_aa(prev_x, prev_y, cx, p[k].y,
                              x, y, w, h, r, g, b, thick);
            prev_x = cx;
            prev_y = p[k].y;
            prev_ts = p[k].ts;
            have_prev = true;
        }
    }
}
