//! tustat — update status for tbzos (Bazzite-based).
//! Shows when image / Flatpak / AppImage updates were last applied and what changed.
//! Read-only apart from ${XDG_STATE_HOME:-~/.local/state}/tustat (AppImage snapshot + change log).
//! Built against Zig 0.16.0, links libc (for local time).

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const version = "0.3.0";

// ─────────────────────────────────────────────────────────────── libc time
const Tm = extern struct {
    sec: c_int = 0,
    min: c_int = 0,
    hour: c_int = 0,
    mday: c_int = 0,
    mon: c_int = 0,
    year: c_int = 0,
    wday: c_int = 0,
    yday: c_int = 0,
    isdst: c_int = -1,
    gmtoff: c_long = 0,
    zone: ?[*:0]const u8 = null,
};
extern "c" fn localtime_r(t: *const i64, tm: *Tm) ?*Tm;
extern "c" fn mktime(tm: *Tm) i64;
extern "c" fn tzset() void;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

fn localTm(t: i64) Tm {
    var tm: Tm = .{};
    _ = localtime_r(&t, &tm);
    return tm;
}

// ─────────────────────────────────────────────────────────────── globals
var A: Allocator = undefined;
var io: std.Io = undefined;
var env: *std.process.Environ.Map = undefined;
var out: *std.Io.Writer = undefined;
var use_color = true;
var now: i64 = 0;
var width: usize = 80;
var home: []const u8 = "";

const Opts = struct { check: bool = false, all: bool = false, days: u32 = 30 };
var opts: Opts = .{};
const max_items = 20;

// ─────────────────────────────────────────────────────────────── style
const Style = enum { reset, bold, dim, red, green, yellow, blue, magenta, cyan, grey };

fn st(s: Style) []const u8 {
    if (!use_color) return "";
    return switch (s) {
        .reset => "\x1b[0m",
        .bold => "\x1b[1m",
        .dim => "\x1b[2m",
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .blue => "\x1b[34m",
        .magenta => "\x1b[35m",
        .cyan => "\x1b[36m",
        .grey => "\x1b[90m",
    };
}

fn w(s: []const u8) !void {
    try out.writeAll(s);
}
fn p(comptime f: []const u8, args: anytype) !void {
    try out.print(f, args);
}
fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(A, f, args) catch "?";
}
fn rep(s: []const u8, n: usize) !void {
    for (0..n) |_| try out.writeAll(s);
}
fn spaces(n: usize) !void {
    try rep(" ", n);
}

/// Visible width: counts UTF-8 code points (no escapes are ever passed here).
fn dispLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

fn trunc(s: []const u8, n: usize) []const u8 {
    if (n == 0) return "";
    if (dispLen(s) <= n) return s;
    var cps: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] & 0xC0 != 0x80) {
            if (cps == n - 1) break;
            cps += 1;
        }
    }
    return fmt("{s}…", .{s[0..i]});
}

fn padTo(s: []const u8, n: usize) !void {
    const t = trunc(s, n);
    try w(t);
    try spaces(n - dispLen(t));
}

fn tilde(path: []const u8) []const u8 {
    if (home.len > 0 and mem.startsWith(u8, path, home)) return fmt("~{s}", .{path[home.len..]});
    return path;
}

// ─────────────────────────────────────────────────────────────── panels
fn panelOpen(icon: []const u8, title: []const u8, right: []const u8, right_style: Style) !void {
    try w("\n");
    try p("  {s}╭─{s} {s}{s}{s} {s}{s}{s} ", .{ st(.grey), st(.reset), st(.magenta), icon, st(.reset), st(.bold), title, st(.reset) });
    const used = 2 + 2 + 1 + dispLen(icon) + 1 + dispLen(title) + 1;
    const rlen = if (right.len > 0) dispLen(right) + 2 else 0;
    const fill = if (width > used + rlen + 2) width - used - rlen - 2 else 3;
    try w(st(.grey));
    try rep("─", fill);
    try w(st(.reset));
    if (right.len > 0) try p(" {s}{s}{s}", .{ st(right_style), right, st(.reset) });
    try w("\n");
}
fn gut() !void {
    try p("  {s}│{s}  ", .{ st(.grey), st(.reset) });
}
fn blank() !void {
    try p("  {s}│{s}\n", .{ st(.grey), st(.reset) });
}
fn panelClose() !void {
    try p("  {s}╰─{s}\n", .{ st(.grey), st(.reset) });
}
fn kv(key: []const u8, comptime f: []const u8, args: anytype) !void {
    try gut();
    try w(st(.dim));
    try padTo(key, 11);
    try w(st(.reset));
    try p(f, args);
    try w("\n");
}
fn note(style: Style, comptime f: []const u8, args: anytype) !void {
    try gut();
    try w(st(style));
    try p(f, args);
    try w(st(.reset));
    try w("\n");
}
fn heading(text: []const u8, extra: []const u8) !void {
    try gut();
    try p("{s}{s}{s}", .{ st(.bold), text, st(.reset) });
    if (extra.len > 0) try p("  {s}{s}{s}", .{ st(.dim), extra, st(.reset) });
    try w("\n");
}

// ─────────────────────────────────────────────────────────────── time text
const wd = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const mn = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn u(v: c_int) u32 {
    return @intCast(@max(v, 0));
}

fn ix(v: c_int) usize {
    return @intCast(@max(v, 0));
}

fn when(t: i64) []const u8 {
    const tm = localTm(t);
    if (tm.year == localTm(now).year)
        return fmt("{s} {d} {s} {d:0>2}:{d:0>2}", .{ wd[ix(tm.wday) % 7], u(tm.mday), mn[ix(tm.mon) % 12], u(tm.hour), u(tm.min) });
    return fmt("{d} {s} {d} {d:0>2}:{d:0>2}", .{ u(tm.mday), mn[ix(tm.mon) % 12], u(tm.year + 1900), u(tm.hour), u(tm.min) });
}

fn dayLabel(t: i64) []const u8 {
    const tm = localTm(t);
    return fmt("{s} {d} {s}", .{ wd[ix(tm.wday) % 7], u(tm.mday), mn[ix(tm.mon) % 12] });
}

fn span(d: i64) []const u8 {
    if (d < 3600) return fmt("{d} min", .{@divFloor(d, 60)});
    if (d < 86400) return fmt("{d}h", .{@divFloor(d, 3600)});
    const days = @divFloor(d, 86400);
    if (days < 14) return fmt("{d} day{s}", .{ days, if (days == 1) "" else "s" });
    if (days < 60) return fmt("{d} weeks", .{@divFloor(days, 7)});
    return fmt("{d} months", .{@divFloor(days, 30)});
}

fn ago(t: i64) []const u8 {
    const d = now - t;
    if (d < -60) return fmt("in {s}", .{span(-d)});
    if (d < 60) return "just now";
    return fmt("{s} ago", .{span(d)});
}

fn ageStyle(t: i64) Style {
    const d = now - t;
    if (d < 7 * 86400) return .green;
    if (d < 30 * 86400) return .yellow;
    return .red;
}

// ─────────────────────────────────────────────────────────────── processes
const RunOut = struct { ok: bool, stdout: []const u8, stderr: []const u8 };

fn run(argv: []const []const u8) RunOut {
    const r = std.process.run(A, io, .{ .argv = argv, .stdout_limit = .limited(16 << 20), .stderr_limit = .limited(1 << 20) }) catch
        return .{ .ok = false, .stdout = "", .stderr = "" };
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = r.stdout, .stderr = r.stderr };
}

fn have(name: []const u8) bool {
    const path = env.get("PATH") orelse return false;
    var it = mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(A, &.{ dir, name }) catch continue;
        std.Io.Dir.accessAbsolute(io, full, .{}) catch continue;
        return true;
    }
    return false;
}

fn firstLine(s: []const u8) []const u8 {
    const t = mem.trim(u8, s, " \n\t");
    const nl = mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return t[0..nl];
}

/// Epoch of the newest journal line for `unit` matching regex `re`.
fn journalLast(unit: []const u8, re: []const u8) ?i64 {
    const r = run(&.{ "journalctl", "-u", unit, "-o", "short-unix", "-q", "-r", "-n", "1", "--no-pager", "-g", re });
    const line = mem.trim(u8, r.stdout, " \n");
    if (line.len == 0) return null;
    const end = mem.indexOfAny(u8, line, ". ") orelse line.len;
    return std.fmt.parseInt(i64, line[0..end], 10) catch null;
}

// ─────────────────────────────────────────────────────────────── changes
const Kind = enum { up, down, add, rm };
const Change = struct { kind: Kind, name: []const u8, from: []const u8 = "", to: []const u8 = "" };

fn lessChange(_: void, a: Change, b: Change) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return mem.lessThan(u8, a.name, b.name);
}

const archs = [_][]const u8{ "x86_64", "noarch", "i686", "aarch64" };

fn splitNevra(s: []const u8) [2][]const u8 {
    var v = s;
    if (mem.lastIndexOfScalar(u8, v, '.')) |d| {
        for (archs) |a| {
            if (mem.eql(u8, v[d + 1 ..], a)) {
                v = v[0..d];
                break;
            }
        }
    }
    const r = mem.lastIndexOfScalar(u8, v, '-') orelse return .{ s, "" };
    const n = mem.lastIndexOfScalar(u8, v[0..r], '-') orelse return .{ v[0..r], v[r + 1 ..] };
    return .{ v[0..n], v[n + 1 ..] };
}

/// Parses `rpm-ostree db diff` block output.
fn parseDiff(text: []const u8) []Change {
    var list: std.ArrayList(Change) = .empty;
    var kind: ?Kind = null;
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        if (raw[0] != ' ' and raw[0] != '\t') {
            kind = if (mem.startsWith(u8, raw, "Upgraded")) .up //
                else if (mem.startsWith(u8, raw, "Downgraded")) .down //
                else if (mem.startsWith(u8, raw, "Added")) .add //
                else if (mem.startsWith(u8, raw, "Removed")) .rm //
                else null;
            continue;
        }
        const k = kind orelse continue;
        const l = mem.trim(u8, raw, " \t");
        if (mem.indexOf(u8, l, " -> ")) |arrow| {
            const left = l[0..arrow];
            if (mem.lastIndexOfScalar(u8, left, ' ')) |sp| {
                list.append(A, .{ .kind = k, .name = left[0..sp], .from = left[sp + 1 ..], .to = l[arrow + 4 ..] }) catch {};
                continue;
            }
        }
        const nv = splitNevra(l);
        list.append(A, .{ .kind = k, .name = nv[0], .to = nv[1] }) catch {};
    }
    std.mem.sort(Change, list.items, {}, lessChange);
    return list.items;
}

fn marker(k: Kind) !void {
    switch (k) {
        .up => try p("{s}↑{s}", .{ st(.cyan), st(.reset) }),
        .down => try p("{s}↓{s}", .{ st(.magenta), st(.reset) }),
        .add => try p("{s}+{s}", .{ st(.green), st(.reset) }),
        .rm => try p("{s}−{s}", .{ st(.red), st(.reset) }),
    }
}

fn renderCounts(list: []const Change) !void {
    var c = [_]usize{ 0, 0, 0, 0 };
    for (list) |x| c[@intFromEnum(x.kind)] += 1;
    const labels = [_][]const u8{ "upgraded", "downgraded", "added", "removed" };
    const kinds = [_]Kind{ .up, .down, .add, .rm };
    try gut();
    var first = true;
    for (kinds, 0..) |k, i| {
        if (c[i] == 0) continue;
        if (!first) try p("{s}  ·  {s}", .{ st(.grey), st(.reset) });
        first = false;
        try marker(k);
        try p(" {s}{d}{s} {s}", .{ st(.bold), c[i], st(.reset), labels[i] });
    }
    try w("\n");
}

fn renderChanges(list: []const Change, err_text: []const u8) !void {
    if (list.len == 0) {
        if (err_text.len > 0) {
            try note(.yellow, "! {s}", .{firstLine(err_text)});
        } else {
            try note(.dim, "no package changes", .{});
        }
        return;
    }
    try renderCounts(list);
    var namew: usize = 0;
    for (list) |c| namew = @max(namew, dispLen(c.name));
    namew = @min(namew, 30);
    const fixed = 2 + 4 + 2 + namew + 2 + 3;
    const avail = if (width > fixed + 16) width - fixed else 16;
    const half = avail / 2;
    const limit = if (opts.all) list.len else @min(list.len, max_items);
    for (list[0..limit]) |c| {
        try gut();
        try w("  ");
        try marker(c.kind);
        try w(" ");
        try padTo(c.name, namew);
        try w("  ");
        if (c.from.len > 0) {
            try p("{s}{s}{s} {s}→{s} {s}", .{ st(.dim), trunc(c.from, half), st(.reset), st(.grey), st(.reset), trunc(c.to, half) });
        } else if (c.kind == .rm) {
            try p("{s}{s}{s}", .{ st(.dim), trunc(c.to, avail), st(.reset) });
        } else {
            try w(trunc(c.to, avail));
        }
        try w("\n");
    }
    if (limit < list.len) try note(.dim, "    … {d} more  (tustat -a shows all)", .{list.len - limit});
}

// ─────────────────────────────────────────────────────────────── image
const Dep = struct { ver: []const u8, built: i64, ref: []const u8, digest: []const u8, csum: []const u8 };

const Image = struct {
    err: ?[]const u8 = null,
    booted: Dep = undefined,
    applied: ?i64 = null,
    prev: ?Dep = null,
    changes: []const Change = &.{},
    diff_err: []const u8 = "",
    staged: ?Dep = null,
    staged_at: ?i64 = null,
    staged_changes: []const Change = &.{},
    check: ?[]const u8 = null,
};

fn jget(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}
fn jstr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = jget(v, key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}
fn jint(v: std.json.Value, key: []const u8) ?i64 {
    const x = jget(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}
fn jbool(v: std.json.Value, key: []const u8) bool {
    const x = jget(v, key) orelse return false;
    return switch (x) {
        .bool => |b| b,
        else => false,
    };
}

fn toDep(v: std.json.Value) Dep {
    var digest = jstr(v, "container-image-reference-digest") orelse "";
    if (digest.len == 0) {
        if (jget(v, "base-commit-meta")) |m| digest = jstr(m, "ostree.manifest-digest") orelse "";
    }
    return .{
        .ver = jstr(v, "version") orelse "?",
        .built = jint(v, "timestamp") orelse 0,
        .ref = jstr(v, "container-image-reference") orelse jstr(v, "origin") orelse "?",
        .digest = digest,
        .csum = jstr(v, "checksum") orelse "",
    };
}

fn gatherImage() Image {
    var r: Image = .{};
    if (!have("rpm-ostree")) {
        r.err = "rpm-ostree not found";
        return r;
    }
    const s = run(&.{ "rpm-ostree", "status", "--json" });
    if (!s.ok) {
        r.err = "rpm-ostree status failed";
        return r;
    }
    const root = std.json.parseFromSliceLeaky(std.json.Value, A, s.stdout, .{}) catch {
        r.err = "couldn't parse rpm-ostree status JSON";
        return r;
    };
    const deps = jget(root, "deployments") orelse {
        r.err = "no deployments in rpm-ostree status";
        return r;
    };
    if (deps != .array) {
        r.err = "unexpected rpm-ostree status JSON";
        return r;
    }
    var booted: ?Dep = null;
    for (deps.array.items) |d| {
        if (jbool(d, "booted")) {
            booted = toDep(d);
        } else if (jbool(d, "staged")) {
            r.staged = toDep(d);
        } else if (booted != null and r.prev == null) {
            r.prev = toDep(d);
        }
    }
    r.booted = booted orelse {
        r.err = "no booted deployment found";
        return r;
    };

    // Applied = staged deployment finalized at shutdown (rpm-ostree and bootc alike).
    r.applied = journalLast("ostree-finalize-staged.service", "Bootloader updated");

    if (r.prev) |pv| {
        const d = run(&.{ "rpm-ostree", "db", "diff", pv.csum, r.booted.csum });
        r.changes = parseDiff(d.stdout);
        if (!d.ok) r.diff_err = if (d.stderr.len > 0) d.stderr else "rpm-ostree db diff failed";
    }
    if (r.staged) |sd| {
        r.staged_at = journalLast("rpm-ostreed.service", "Txn \\S+ on \\S+ successful");
        const d = run(&.{ "rpm-ostree", "db", "diff", r.booted.csum, sd.csum });
        r.staged_changes = parseDiff(d.stdout);
    }
    if (opts.check) {
        const c = run(&.{ "rpm-ostree", "upgrade", "--check" });
        r.check = mem.trim(u8, if (c.stdout.len > 0) c.stdout else c.stderr, " \n");
    }
    return r;
}

fn shortDigest(d: []const u8) []const u8 {
    if (d.len == 0) return "";
    const colon = mem.indexOfScalar(u8, d, ':') orelse return trunc(d, 19);
    return fmt("{s}{s}", .{ d[0 .. colon + 1], d[colon + 1 .. @min(d.len, colon + 13)] });
}

fn renderImage(im: Image) !void {
    if (im.err) |e| {
        try panelOpen("◆", "IMAGE", "", .dim);
        try note(.yellow, "! {s}", .{e});
        try panelClose();
        return;
    }
    const right = if (im.applied) |t| fmt("applied {s}", .{ago(t)}) else "applied ?";
    try panelOpen("◆", "IMAGE", right, if (im.applied) |t| ageStyle(t) else .dim);

    const b = im.booted;
    try kv("Booted", "{s}{s}{s}", .{ st(.bold), b.ver, st(.reset) });

    const signed = mem.startsWith(u8, b.ref, "ostree-image-signed");
    const ref = if (mem.indexOf(u8, b.ref, "://")) |i| b.ref[i + 3 ..] else b.ref;
    if (signed) {
        try kv("Image", "{s}  {s}✓ signed{s}", .{ ref, st(.green), st(.reset) });
    } else {
        try kv("Image", "{s}", .{ref});
    }
    if (b.digest.len > 0) try kv("Digest", "{s}{s}{s}", .{ st(.dim), shortDigest(b.digest), st(.reset) });
    if (b.built > 0) try kv("Built", "{s}  {s}{s}{s}", .{ when(b.built), st(.dim), ago(b.built), st(.reset) });
    if (im.applied) |t| {
        try kv("Applied", "{s}{s}{s}  {s}{s} · finalized at reboot{s}", .{ st(ageStyle(t)), when(t), st(.reset), st(.dim), ago(t), st(.reset) });
    } else {
        try kv("Applied", "{s}unknown — journal rotated or unreadable{s}", .{ st(.yellow), st(.reset) });
    }
    if (im.staged) |sd| {
        try kv("Staged", "{s}⟳ {s}{s}  {s}reboot to apply{s}", .{ st(.yellow), sd.ver, st(.reset), st(.dim), st(.reset) });
        if (im.staged_at) |t| try kv("Staged at", "{s}  {s}{s}{s}", .{ when(t), st(.dim), ago(t), st(.reset) });
    } else {
        try kv("Staged", "{s}✓ nothing pending{s}", .{ st(.green), st(.reset) });
    }

    if (im.prev) |pv| {
        try blank();
        try heading("What was applied", fmt("{s} → {s}", .{ pv.ver, b.ver }));
        try renderChanges(im.changes, im.diff_err);
    } else {
        try blank();
        try note(.dim, "no previous deployment to compare against", .{});
    }
    if (im.staged) |sd| {
        try blank();
        try heading("Pending after reboot", fmt("{s} → {s}", .{ b.ver, sd.ver }));
        try renderChanges(im.staged_changes, "");
    }
    if (im.check) |c| {
        try blank();
        try heading("Available", "rpm-ostree upgrade --check");
        var it = mem.splitScalar(u8, c, '\n');
        while (it.next()) |l| try note(.reset, "  {s}", .{l});
    }
    try panelClose();
}

// ─────────────────────────────────────────────────────────────── flatpak
const FEntry = struct { t: i64, day: []const u8, kind: Kind, app: []const u8, branch: []const u8, inst: []const u8, clock: []const u8 };

const Flatpak = struct {
    err: ?[]const u8 = null,
    entries: []const FEntry = &.{},
    versions: std.StringHashMap([]const u8) = undefined,
    check: ?[]const u8 = null,
};

fn num(tok: ?[]const u8) c_int {
    const s = tok orelse return 0;
    return std.fmt.parseInt(c_int, s, 10) catch 0;
}

/// Accepts "Oct 14 10:23:01" (no year; assumes the most recent past one) or "2026-10-14 10:23:01".
fn parseFlatTime(s: []const u8) i64 {
    var tm: Tm = .{};
    var it = mem.tokenizeAny(u8, s, " -:T");
    if (s.len >= 10 and std.ascii.isDigit(s[0])) {
        tm.year = num(it.next()) - 1900;
        tm.mon = num(it.next()) - 1;
        tm.mday = num(it.next());
        tm.hour = num(it.next());
        tm.min = num(it.next());
        tm.sec = num(it.next());
        return mktime(&tm);
    }
    const ms = it.next() orelse return 0;
    var mon: ?usize = null;
    for (mn, 0..) |m, i| {
        if (std.ascii.eqlIgnoreCase(ms, m)) mon = i;
    }
    const mi = mon orelse return 0;
    tm.mon = @intCast(mi);
    tm.mday = num(it.next());
    tm.hour = num(it.next());
    tm.min = num(it.next());
    tm.sec = num(it.next());
    tm.year = localTm(now).year;
    const saved = tm;
    var t = mktime(&tm);
    if (t > now + 86400) {
        tm = saved;
        tm.year -= 1;
        t = mktime(&tm);
    }
    return t;
}

fn dayKey(t: i64, raw: []const u8) []const u8 {
    if (t > 0) {
        const tm = localTm(t);
        return fmt("{d}-{d:0>2}-{d:0>2}", .{ u(tm.year + 1900), u(tm.mon + 1), u(tm.mday) });
    }
    const sp = mem.lastIndexOfScalar(u8, raw, ' ') orelse return raw;
    return raw[0..sp];
}

fn gatherFlatpak() Flatpak {
    var r: Flatpak = .{};
    r.versions = std.StringHashMap([]const u8).init(A);
    if (!have("flatpak")) {
        r.err = "flatpak not installed";
        return r;
    }
    const tm = localTm(now - @as(i64, opts.days) * 86400);
    const since = fmt("--since={d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ u(tm.year + 1900), u(tm.mon + 1), u(tm.mday), u(tm.hour), u(tm.min), u(tm.sec) });
    const h = run(&.{ "flatpak", "history", since, "--columns=time,change,application,branch,installation" });

    var list: std.ArrayList(FEntry) = .empty;
    var it = mem.splitScalar(u8, h.stdout, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var f = mem.splitScalar(u8, line, '\t');
        const time = f.next() orelse continue;
        const change = f.next() orelse continue;
        const kind: Kind = if (mem.indexOf(u8, change, "uninstall") != null) .rm //
            else if (mem.indexOf(u8, change, "update") != null) .up //
            else if (mem.indexOf(u8, change, "install") != null) .add //
            else continue;
        const t = parseFlatTime(time);
        const clock = if (mem.lastIndexOfScalar(u8, time, ' ')) |sp| time[sp + 1 ..] else time;
        list.append(A, .{
            .t = t,
            .day = dayKey(t, time),
            .kind = kind,
            .app = mem.trim(u8, f.next() orelse "", " "),
            .branch = mem.trim(u8, f.next() orelse "", " "),
            .inst = mem.trim(u8, f.next() orelse "", " "),
            .clock = if (clock.len >= 5) clock[0..5] else clock,
        }) catch {};
    }
    r.entries = list.items;

    const l = run(&.{ "flatpak", "list", "--columns=application,version" });
    var li = mem.splitScalar(u8, l.stdout, '\n');
    while (li.next()) |line| {
        var f = mem.splitScalar(u8, line, '\t');
        const app = f.next() orelse continue;
        const ver = f.next() orelse "";
        if (app.len > 0 and ver.len > 0) r.versions.put(app, ver) catch {};
    }

    if (opts.check) {
        const c = run(&.{ "flatpak", "remote-ls", "--updates", "--columns=application,version,branch" });
        r.check = mem.trim(u8, c.stdout, " \n");
    }
    return r;
}

fn renderFlatpak(fp: Flatpak) !void {
    if (fp.err) |e| {
        try panelOpen("▣", "FLATPAK", "", .dim);
        try note(.yellow, "! {s}", .{e});
        try panelClose();
        return;
    }
    if (fp.entries.len == 0) {
        try panelOpen("▣", "FLATPAK", "nothing recent", .dim);
        try note(.dim, "no changes in the last {d} days (or the system journal isn't readable)", .{opts.days});
    } else {
        const last = fp.entries[fp.entries.len - 1];
        const right = if (last.t > 0) fmt("applied {s}", .{ago(last.t)}) else "applied";
        try panelOpen("▣", "FLATPAK", right, if (last.t > 0) ageStyle(last.t) else .dim);
        if (last.t > 0) {
            try kv("Last run", "{s}{s}{s}  {s}{s}{s}", .{ st(ageStyle(last.t)), when(last.t), st(.reset), st(.dim), ago(last.t), st(.reset) });
        } else {
            try kv("Last run", "{s}", .{last.day});
        }

        // entries from the most recent day
        var n: usize = 0;
        var namew: usize = 0;
        for (fp.entries) |e| {
            if (!mem.eql(u8, e.day, last.day)) continue;
            n += 1;
            namew = @max(namew, dispLen(e.app));
        }
        namew = @min(namew, 40);
        try blank();
        try heading("What was applied", fmt("{s} · {d} change{s}", .{ if (last.t > 0) dayLabel(last.t) else last.day, n, if (n == 1) "" else "s" }));
        for (fp.entries) |e| {
            if (!mem.eql(u8, e.day, last.day)) continue;
            try gut();
            try w("  ");
            try marker(e.kind);
            try w(" ");
            try padTo(e.app, namew);
            try p("  {s}", .{st(.dim)});
            try padTo(e.branch, 8);
            try padTo(e.inst, 8);
            try w(st(.reset));
            try padTo(fp.versions.get(e.app) orelse "", 14);
            try p("{s}{s}{s}\n", .{ st(.grey), e.clock, st(.reset) });
        }

        // earlier days: day → count, newest first
        var days: std.ArrayList([]const u8) = .empty;
        var counts: std.ArrayList(usize) = .empty;
        var stamps: std.ArrayList(i64) = .empty;
        for (fp.entries) |e| {
            if (mem.eql(u8, e.day, last.day)) continue;
            if (days.items.len > 0 and mem.eql(u8, days.items[days.items.len - 1], e.day)) {
                counts.items[counts.items.len - 1] += 1;
            } else {
                days.append(A, e.day) catch {};
                counts.append(A, 1) catch {};
                stamps.append(A, e.t) catch {};
            }
        }
        try blank();
        try heading("Earlier", fmt("last {d} days", .{opts.days}));
        if (days.items.len == 0) try note(.dim, "  none", .{});
        var shown: usize = 0;
        var i = days.items.len;
        while (i > 0) : (i -= 1) {
            if (!opts.all and shown == 8) {
                try note(.dim, "  … {d} more days  (tustat -a)", .{i});
                break;
            }
            shown += 1;
            const lbl = if (stamps.items[i - 1] > 0) dayLabel(stamps.items[i - 1]) else days.items[i - 1];
            const c = counts.items[i - 1];
            try gut();
            try w("  ");
            try padTo(lbl, 12);
            try p("{s}", .{st(.cyan)});
            try rep("▪", @min(c, 24));
            try p("{s} {s}{d}{s}\n", .{ st(.reset), st(.dim), c, st(.reset) });
        }
    }
    if (fp.check) |c| {
        try blank();
        try heading("Available", "flatpak remote-ls --updates");
        if (c.len == 0) try note(.green, "  ✓ everything up to date", .{});
        var it = mem.splitScalar(u8, c, '\n');
        while (it.next()) |l| {
            if (l.len == 0) continue;
            var f = mem.tokenizeScalar(u8, l, '\t');
            try gut();
            try w("  ");
            try marker(.up);
            try w(" ");
            try padTo(f.next() orelse "", 40);
            try p("  {s}\n", .{f.next() orelse ""});
        }
    }
    try panelClose();
}

// ─────────────────────────────────────────────────────────────── appimage
const AppImg = struct { path: []const u8, file: []const u8, name: []const u8, ver: []const u8, mtime: i64, size: u64 };

const AppImages = struct {
    items: []AppImg = &.{},
    dirs: []const []const u8 = &.{},
    first_run: bool = false,
    log_path: []const u8 = "",
    log_tail: []const []const u8 = &.{},
    check: ?[]const u8 = null,
};

fn lineVal(content: []const u8, key: []const u8) ?[]const u8 {
    var it = mem.splitScalar(u8, content, '\n');
    while (it.next()) |l| {
        if (mem.startsWith(u8, l, key)) return mem.trim(u8, l[key.len..], " \r");
    }
    return null;
}

fn scan(list: *std.ArrayList(AppImg), path: []const u8, depth: u8) void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        const full = std.fs.path.join(A, &.{ path, e.name }) catch continue;
        switch (e.kind) {
            .directory => if (depth > 0) scan(list, full, depth - 1),
            .file, .sym_link => {
                if (!std.ascii.endsWithIgnoreCase(e.name, ".appimage")) continue;
                const s = dir.statFile(io, e.name, .{}) catch continue;
                list.append(A, .{
                    .path = full,
                    .file = A.dupe(u8, e.name) catch continue,
                    .name = "",
                    .ver = "-",
                    .mtime = s.mtime.toSeconds(),
                    .size = s.size,
                }) catch {};
            },
            else => {},
        }
    }
}

fn readFile(path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, A, .limited(4 << 20)) catch null;
}

fn appendFile(path: []const u8, data: []const u8) void {
    // log is small: read, concatenate, rewrite
    const old = readFile(path) orelse "";
    const all = mem.concat(A, u8, &.{ old, data }) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = all }) catch {};
}

fn stamp(t: i64) []const u8 {
    const tm = localTm(t);
    return fmt("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ u(tm.year + 1900), u(tm.mon + 1), u(tm.mday), u(tm.hour), u(tm.min) });
}

fn lessAppImg(_: void, a: AppImg, b: AppImg) bool {
    return a.mtime > b.mtime;
}

fn gatherAppImages() AppImages {
    var r: AppImages = .{};

    // dirs
    var dirs: std.ArrayList([]const u8) = .empty;
    const dirs_env = env.get("TUSTAT_APPIMAGE_DIRS") orelse
        fmt("{s}/AppImages:{s}/Applications:{s}/.local/bin", .{ home, home, home });
    var di = mem.splitScalar(u8, dirs_env, ':');
    while (di.next()) |d| {
        if (d.len > 0) dirs.append(A, d) catch {};
    }
    r.dirs = dirs.items;

    var list: std.ArrayList(AppImg) = .empty;
    for (r.dirs) |d| scan(&list, d, 1);

    // desktop entries → name + version (Gear Lever writes X-AppImage-Version)
    var desktops: std.ArrayList([]const u8) = .empty;
    const appdir = fmt("{s}/.local/share/applications", .{home});
    if (std.Io.Dir.openDirAbsolute(io, appdir, .{ .iterate = true })) |dir_| {
        var dir = dir_;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (!mem.endsWith(u8, e.name, ".desktop")) continue;
            const c = dir.readFileAlloc(io, e.name, A, .limited(256 << 10)) catch continue;
            desktops.append(A, c) catch {};
        }
    } else |_| {}
    for (list.items) |*a| {
        for (desktops.items) |c| {
            if (mem.indexOf(u8, c, a.path) == null) continue;
            a.name = lineVal(c, "Name=") orelse "";
            a.ver = lineVal(c, "X-AppImage-Version=") orelse "-";
            break;
        }
        if (a.name.len == 0) a.name = a.file;
    }

    // snapshot compare → change log
    const sdir = if (env.get("XDG_STATE_HOME")) |x| fmt("{s}/tustat", .{x}) else fmt("{s}/.local/state/tustat", .{home});
    std.Io.Dir.cwd().createDirPath(io, sdir) catch {};
    const snap_path = fmt("{s}/appimages.tsv", .{sdir});
    r.log_path = fmt("{s}/appimage-history.log", .{sdir});

    const Old = struct { mtime: []const u8, size: []const u8, ver: []const u8, seen: bool };
    var old = std.StringHashMap(Old).init(A);
    if (readFile(snap_path)) |snap| {
        var it = mem.splitScalar(u8, snap, '\n');
        while (it.next()) |l| {
            var f = mem.splitScalar(u8, l, '\t');
            const path = f.next() orelse continue;
            if (path.len == 0) continue;
            old.put(path, .{ .mtime = f.next() orelse "", .size = f.next() orelse "", .ver = f.next() orelse "-", .seen = false }) catch {};
        }
    } else {
        r.first_run = true;
    }

    var snap_new: std.ArrayList(u8) = .empty;
    var log_add: std.ArrayList(u8) = .empty;
    for (list.items) |a| {
        snap_new.appendSlice(A, fmt("{s}\t{d}\t{d}\t{s}\n", .{ a.path, a.mtime, a.size, a.ver })) catch {};
        if (r.first_run) continue;
        if (old.getPtr(a.path)) |o| {
            o.seen = true;
            const same = mem.eql(u8, o.mtime, fmt("{d}", .{a.mtime})) and mem.eql(u8, o.size, fmt("{d}", .{a.size}));
            if (!same) log_add.appendSlice(A, fmt("{s}\tupdated\t{s}\t{s} -> {s}\n", .{ stamp(a.mtime), a.file, o.ver, a.ver })) catch {};
        } else {
            log_add.appendSlice(A, fmt("{s}\tadded\t{s}\t{s}\n", .{ stamp(a.mtime), a.file, a.ver })) catch {};
        }
    }
    if (!r.first_run) {
        var oi = old.iterator();
        while (oi.next()) |e| {
            if (!e.value_ptr.seen)
                log_add.appendSlice(A, fmt("{s}\tremoved\t{s}\t{s}\n", .{ stamp(now), std.fs.path.basename(e.key_ptr.*), e.value_ptr.ver })) catch {};
        }
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = snap_path, .data = snap_new.items }) catch {};
    if (log_add.items.len > 0) appendFile(r.log_path, log_add.items);

    if (readFile(r.log_path)) |lg| {
        var lines: std.ArrayList([]const u8) = .empty;
        var it = mem.splitScalar(u8, lg, '\n');
        while (it.next()) |l| {
            if (l.len > 0) lines.append(A, l) catch {};
        }
        const keep: usize = if (opts.all) lines.items.len else 8;
        r.log_tail = lines.items[lines.items.len -| keep..];
    }

    std.mem.sort(AppImg, list.items, {}, lessAppImg);
    r.items = list.items;

    if (opts.check) {
        const c = run(&.{ "flatpak", "run", "it.mijorus.gearlever", "--list-updates" });
        r.check = if (c.ok) mem.trim(u8, c.stdout, " \n") else "Gear Lever not available — can't check";
    }
    return r;
}

fn renderAppImages(ai: AppImages) !void {
    if (ai.items.len == 0) {
        try panelOpen("◇", "APPIMAGE", "none found", .dim);
        var shown: std.ArrayList(u8) = .empty;
        for (ai.dirs, 0..) |d, i| {
            if (i > 0) shown.appendSlice(A, ", ") catch {};
            shown.appendSlice(A, tilde(d)) catch {};
        }
        try note(.dim, "no AppImages in {s}", .{shown.items});
    } else {
        const newest = ai.items[0].mtime;
        try panelOpen("◇", "APPIMAGE", fmt("applied {s}", .{ago(newest)}), ageStyle(newest));
        try kv("Last run", "{s}{s}{s}  {s}{s}{s}", .{ st(ageStyle(newest)), when(newest), st(.reset), st(.dim), ago(newest), st(.reset) });
        try kv("Tracked", "{d} app{s}", .{ ai.items.len, if (ai.items.len == 1) "" else "s" });
        try blank();
        var namew: usize = 4;
        var verw: usize = 7;
        for (ai.items) |a| {
            namew = @max(namew, dispLen(a.name));
            verw = @max(verw, dispLen(a.ver));
        }
        namew = @min(namew, 28);
        verw = @min(verw, 16);
        try gut();
        try p("  {s}", .{st(.dim)});
        try padTo("APP", namew + 2);
        try padTo("VERSION", verw + 2);
        try p("UPDATED{s}\n", .{st(.reset)});
        for (ai.items) |a| {
            try gut();
            try w("  ");
            try w(st(.bold));
            try padTo(a.name, namew + 2);
            try w(st(.reset));
            try padTo(a.ver, verw + 2);
            try p("{s}{s}{s}  {s}{s}{s}\n", .{ st(ageStyle(a.mtime)), when(a.mtime), st(.reset), st(.dim), ago(a.mtime), st(.reset) });
        }
    }
    try blank();
    if (ai.first_run) {
        try note(.dim, "baseline recorded — updates are logged from now on", .{});
        try note(.dim, "{s}", .{tilde(ai.log_path)});
    } else if (ai.log_tail.len == 0) {
        try note(.dim, "no changes logged yet", .{});
    } else {
        try heading("Change log", tilde(ai.log_path));
        var i = ai.log_tail.len;
        while (i > 0) : (i -= 1) {
            var f = mem.splitScalar(u8, ai.log_tail[i - 1], '\t');
            const t = f.next() orelse "";
            const kind = f.next() orelse "";
            const file = f.next() orelse "";
            const detail = f.next() orelse "";
            try gut();
            try w("  ");
            try marker(if (mem.eql(u8, kind, "removed")) .rm else if (mem.eql(u8, kind, "added")) .add else .up);
            try p(" {s}{s}{s}  ", .{ st(.grey), t, st(.reset) });
            try padTo(file, 34);
            if (mem.indexOf(u8, detail, " -> ")) |ar| {
                try p("  {s}{s}{s} {s}→{s} {s}\n", .{ st(.dim), detail[0..ar], st(.reset), st(.grey), st(.reset), detail[ar + 4 ..] });
            } else {
                try p("  {s}\n", .{detail});
            }
        }
    }
    if (ai.check) |c| {
        try blank();
        try heading("Available", "Gear Lever");
        if (c.len == 0) try note(.green, "  ✓ everything up to date", .{});
        var it = mem.splitScalar(u8, c, '\n');
        while (it.next()) |l| {
            if (l.len > 0) try note(.reset, "  {s}", .{l});
        }
    }
    try panelClose();
}

// ─────────────────────────────────────────────────────────────── timers
const Timer = struct { name: []const u8, user: bool, enabled: []const u8, last: ?i64, next: ?i64, result: []const u8 };

const timer_specs = [_]struct { name: []const u8, user: bool }{
    .{ .name = "uupd.timer", .user = false },
    .{ .name = "ublue-update.timer", .user = false },
    .{ .name = "rpm-ostreed-automatic.timer", .user = false },
    .{ .name = "flatpak-system-update.timer", .user = false },
    .{ .name = "flatpak-user-update.timer", .user = true },
};

fn prop(text: []const u8, key: []const u8) []const u8 {
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len > key.len and mem.startsWith(u8, l, key) and l[key.len] == '=') return l[key.len + 1 ..];
    }
    return "";
}

fn unixProp(v: []const u8) ?i64 {
    if (v.len > 1 and v[0] == '@') return std.fmt.parseInt(i64, v[1..], 10) catch null;
    return null;
}

fn gatherTimers() []const Timer {
    var list: std.ArrayList(Timer) = .empty;
    for (timer_specs) |spec| {
        const base: []const []const u8 = if (spec.user) &.{ "systemctl", "--user" } else &.{"systemctl"};
        const argv = mem.concat(A, []const u8, &.{ base, &.{ "show", "--timestamp=unix", "-p", "LoadState", "-p", "UnitFileState", "-p", "LastTriggerUSec", "-p", "NextElapseUSecRealtime", "-p", "Unit", spec.name } }) catch continue;
        const r = run(argv);
        if (!mem.eql(u8, prop(r.stdout, "LoadState"), "loaded")) continue;
        const svc = prop(r.stdout, "Unit");
        var result: []const u8 = "?";
        if (svc.len > 0) {
            const argv2 = mem.concat(A, []const u8, &.{ base, &.{ "show", "-P", "Result", svc } }) catch continue;
            result = mem.trim(u8, run(argv2).stdout, " \n");
        }
        list.append(A, .{
            .name = spec.name,
            .user = spec.user,
            .enabled = prop(r.stdout, "UnitFileState"),
            .last = unixProp(prop(r.stdout, "LastTriggerUSec")),
            .next = unixProp(prop(r.stdout, "NextElapseUSecRealtime")),
            .result = result,
        }) catch {};
    }
    return list.items;
}

fn timersFailing(ts: []const Timer) usize {
    var n: usize = 0;
    for (ts) |t| {
        if (t.last != null and !mem.eql(u8, t.result, "success")) n += 1;
    }
    return n;
}

fn renderTimers(ts: []const Timer) !void {
    const failing = timersFailing(ts);
    const right = if (ts.len == 0) "none found" else if (failing > 0) fmt("{d} failing", .{failing}) else "all ok";
    try panelOpen("◷", "AUTO-UPDATES", right, if (failing > 0) .red else if (ts.len == 0) .dim else .green);
    if (ts.len == 0) try note(.dim, "no update timers installed", .{});
    for (ts) |t| {
        const ok = mem.eql(u8, t.result, "success");
        const enabled = mem.eql(u8, t.enabled, "enabled");
        try gut();
        if (t.last == null) {
            try p("{s}○{s} ", .{ st(.grey), st(.reset) });
        } else if (ok) {
            try p("{s}✓{s} ", .{ st(.green), st(.reset) });
        } else {
            try p("{s}✗{s} ", .{ st(.red), st(.reset) });
        }
        try w(st(.bold));
        try padTo(fmt("{s}{s}", .{ t.name, if (t.user) " (user)" else "" }), 34);
        try w(st(.reset));
        try w(st(if (enabled) .dim else .yellow));
        try padTo(if (t.enabled.len > 0) t.enabled else "?", 10);
        try w(st(.reset));
        try p("{s}last{s} ", .{ st(.grey), st(.reset) });
        try padTo(if (t.last) |l| ago(l) else "never", 12);
        try p("{s}next{s} {s}", .{ st(.grey), st(.reset), if (t.next) |n| ago(n) else "—" });
        if (t.last != null and !ok) try p("  {s}{s}{s}", .{ st(.red), t.result, st(.reset) });
        try w("\n");
    }
    try panelClose();
}

// ─────────────────────────────────────────────────────────────── sections
const Section = enum { image, flatpak, appimage, timers };
const sec_names = [_][]const u8{ "Image", "Flatpak", "AppImage", "Auto-updates" };
const sec_icons = [_][]const u8{ "◆", "▣", "◇", "◷" };

var d_im: ?Image = null;
var d_fp: ?Flatpak = null;
var d_ai: ?AppImages = null;
var d_tm: ?[]const Timer = null;

fn gather(s: Section) void {
    switch (s) {
        .image => d_im = gatherImage(),
        .flatpak => d_fp = gatherFlatpak(),
        .appimage => d_ai = gatherAppImages(),
        .timers => d_tm = gatherTimers(),
    }
}

fn gatherAll() void {
    for (0..4) |i| gather(@enumFromInt(i));
}

fn render(s: Section) !void {
    switch (s) {
        .image => if (d_im) |x| try renderImage(x),
        .flatpak => if (d_fp) |x| try renderFlatpak(x),
        .appimage => if (d_ai) |x| try renderAppImages(x),
        .timers => if (d_tm) |x| try renderTimers(x),
    }
}

const Sum = struct { t: ?i64 = null, detail: []const u8 = "", style: Style = .dim };

fn summary(s: Section) Sum {
    switch (s) {
        .image => {
            const x = d_im orelse return .{};
            if (x.err) |e| return .{ .detail = e, .style = .yellow };
            if (x.staged) |sd| return .{ .t = x.applied, .detail = fmt("{s}  ⟳ {s} staged — reboot", .{ x.booted.ver, sd.ver }), .style = .yellow };
            return .{ .t = x.applied, .detail = fmt("{s}  ✓ nothing pending", .{x.booted.ver}), .style = .reset };
        },
        .flatpak => {
            const x = d_fp orelse return .{};
            if (x.err) |e| return .{ .detail = e, .style = .yellow };
            if (x.entries.len == 0) return .{ .detail = fmt("no changes in {d} days", .{opts.days}) };
            const last = x.entries[x.entries.len - 1];
            var n: usize = 0;
            for (x.entries) |e| {
                if (mem.eql(u8, e.day, last.day)) n += 1;
            }
            return .{ .t = if (last.t > 0) last.t else null, .detail = fmt("{d} change{s} in last run", .{ n, if (n == 1) "" else "s" }), .style = .reset };
        },
        .appimage => {
            const x = d_ai orelse return .{};
            if (x.items.len == 0) return .{ .detail = "none found" };
            return .{ .t = x.items[0].mtime, .detail = fmt("{d} app{s}", .{ x.items.len, if (x.items.len == 1) "" else "s" }), .style = .reset };
        },
        .timers => {
            const x = d_tm orelse return .{};
            if (x.len == 0) return .{ .detail = "none installed" };
            var last: ?i64 = null;
            for (x) |t| {
                if (t.last) |l| last = if (last) |m| @max(m, l) else l;
            }
            const f = timersFailing(x);
            if (f > 0) return .{ .t = last, .detail = fmt("✗ {d} failing", .{f}), .style = .red };
            return .{ .t = last, .detail = "✓ all ok", .style = .green };
        },
    }
}

fn dot(t: ?i64) !void {
    try p("{s}●{s} ", .{ st(if (t) |tt| ageStyle(tt) else .grey), st(.reset) });
}

fn sumRow(s: Section) !void {
    const x = summary(s);
    try w("    ");
    try dot(x.t);
    try w(st(.bold));
    try padTo(sec_names[@intFromEnum(s)], 14);
    try w(st(.reset));
    try padTo(if (x.t) |tt| ago(tt) else "—", 15);
    try p("{s}{s}{s}\n", .{ st(x.style), x.detail, st(.reset) });
}

fn header() !void {
    var hbuf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = std.posix.gethostname(&hbuf) catch "localhost";
    try p("\n  {s}{s}tustat{s} {s}·{s} {s} {s}·{s} {s}{s}{s}\n\n", .{
        st(.bold), st(.magenta), st(.reset), st(.grey), st(.reset), host, st(.grey), st(.reset), st(.dim), when(now), st(.reset),
    });
}

// ─────────────────────────────────────────────────────────────── terminal
const Size = struct { cols: usize, rows: usize };

fn termSize() Size {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (ioctl(1, std.os.linux.T.IOCGWINSZ, &ws) == 0 and ws.col > 0 and ws.row > 0)
        return .{ .cols = ws.col, .rows = ws.row };
    const cols = if (env.get("COLUMNS")) |c| std.fmt.parseInt(usize, c, 10) catch 80 else 80;
    const rows = if (env.get("LINES")) |c| std.fmt.parseInt(usize, c, 10) catch 24 else 24;
    return .{ .cols = cols, .rows = rows };
}

fn refreshWidth() bool {
    const nw = std.math.clamp(termSize().cols -| 2, 60, 110);
    defer width = nw;
    return nw != width;
}

var orig_tio: ?std.posix.termios = null;

fn rawOn() !void {
    const t = try std.posix.tcgetattr(0);
    orig_tio = t;
    var r = t;
    r.lflag.ECHO = false;
    r.lflag.ICANON = false;
    r.lflag.ISIG = false;
    r.lflag.IEXTEN = false;
    r.iflag.IXON = false;
    r.iflag.ICRNL = false;
    r.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    r.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(0, .FLUSH, r);
    // alternate screen, hide cursor, no autowrap (long lines clip instead of breaking the layout)
    try w("\x1b[?1049h\x1b[?25l\x1b[?7l");
    try out.flush();
}

fn rawOff() void {
    w("\x1b[?7h\x1b[?25h\x1b[?1049l") catch {};
    out.flush() catch {};
    if (orig_tio) |t| std.posix.tcsetattr(0, .FLUSH, t) catch {};
}

const Key = union(enum) { up, down, pgup, pgdn, home, end, enter, back, eof, none, char: u8 };

fn readByte(timeout_ms: i32) ?u8 {
    if (timeout_ms >= 0) {
        var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, timeout_ms) catch return null;
        if (n == 0) return null;
    }
    var b: [1]u8 = undefined;
    const n = std.posix.read(0, &b) catch return null;
    if (n == 0) return null;
    return b[0];
}

fn readKey() Key {
    const c = readByte(-1) orelse return .eof;
    switch (c) {
        27 => {
            // lone ESC = back; ESC [ … = cursor keys
            const c2 = readByte(40) orelse return .back;
            if (c2 != '[' and c2 != 'O') return .back;
            const c3 = readByte(40) orelse return .back;
            return switch (c3) {
                'A' => .up,
                'B' => .down,
                'H' => .home,
                'F' => .end,
                '0'...'9' => blk: {
                    while (readByte(40)) |x| {
                        if (x == '~') break;
                    }
                    break :blk switch (c3) {
                        '5' => .pgup,
                        '6' => .pgdn,
                        '1', '7' => .home,
                        '4', '8' => .end,
                        else => .none,
                    };
                },
                else => .none,
            };
        },
        '\r', '\n' => return .enter,
        127, 8 => return .back,
        else => return .{ .char = c },
    }
}

// Frames are rendered into a buffer, then painted over the old one (no flicker).
var cap: std.Io.Writer.Allocating = undefined;
var saved_out: *std.Io.Writer = undefined;

fn beginCap() void {
    cap = .init(A);
    saved_out = out;
    out = &cap.writer;
}

fn endCap() []const u8 {
    out = saved_out;
    return cap.written();
}

fn present(text: []const u8) !void {
    try w("\x1b[H");
    var it = mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) try w("\n");
        first = false;
        try w(l);
        try w("\x1b[K");
    }
    try w("\x1b[J");
    try out.flush();
}

fn hint(key: []const u8, desc: []const u8) !void {
    try p("{s}{s}{s} {s}{s}{s}   ", .{ st(.bold), key, st(.reset), st(.dim), desc, st(.reset) });
}

// ─────────────────────────────────────────────────────────────── menu UI
const n_items = 5; // four sections + "everything"

fn drawLoading(msg: []const u8) void {
    beginCap();
    header() catch {};
    p("  {s}⟳ {s}{s}\n", .{ st(.yellow), msg, st(.reset) }) catch {};
    present(endCap()) catch {};
}

fn menuRow(i: usize, sel: usize) !void {
    const on = i == sel;
    try gut();
    if (on) {
        try p("{s}{s}▸{s} ", .{ st(.bold), st(.magenta), st(.reset) });
    } else {
        try w("  ");
    }
    try p("{s}{d}{s}  ", .{ st(.dim), i + 1, st(.reset) });
    if (i < 4) {
        const s: Section = @enumFromInt(i);
        const x = summary(s);
        try p("{s}{s}{s} ", .{ st(.magenta), sec_icons[i], st(.reset) });
        try w(st(if (on) .bold else .reset));
        try padTo(sec_names[i], 14);
        try w(st(.reset));
        try dot(x.t);
        try padTo(if (x.t) |tt| ago(tt) else "—", 13);
        const room = if (width > 52) width - 52 else 10;
        try p("{s}{s}{s}", .{ st(x.style), trunc(x.detail, room), st(.reset) });
    } else {
        try p("{s}≡{s} ", .{ st(.magenta), st(.reset) });
        try w(st(if (on) .bold else .reset));
        try padTo("Everything", 14);
        try w(st(.reset));
        try p("{s}all sections on one page{s}", .{ st(.dim), st(.reset) });
    }
    try w("\n");
}

fn drawMenu(sel: usize) !void {
    beginCap();
    try header();
    try panelOpen("●", "UPDATE STATUS", "", .dim);
    try blank();
    for (0..4) |i| try menuRow(i, sel);
    try blank();
    try menuRow(4, sel);
    try blank();
    try panelClose();
    try w("\n    ");
    try hint("↑↓", "move");
    try hint("⏎", "open");
    try hint("1-5", "jump");
    try hint("r", "refresh");
    try hint("q", "quit");
    try w("\n");
    try present(endCap());
}

fn sectionLines(sel: usize) []const []const u8 {
    beginCap();
    if (sel < 4) {
        render(@enumFromInt(sel)) catch {};
    } else {
        for (0..4) |i| render(@enumFromInt(i)) catch {};
    }
    const text = endCap();
    var list: std.ArrayList([]const u8) = .empty;
    var it = mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| list.append(A, l) catch {};
    var lines = list.items;
    while (lines.len > 0 and lines[0].len == 0) lines = lines[1..];
    while (lines.len > 0 and lines[lines.len - 1].len == 0) lines = lines[0 .. lines.len - 1];
    return lines;
}

fn drawDetail(sel: usize, lines: []const []const u8, scroll: usize, body: usize, status: []const u8) !void {
    beginCap();
    const name = if (sel < 4) sec_names[sel] else "Everything";
    try p("\n  {s}{s}tustat{s} {s}›{s} {s}{s}{s}", .{ st(.bold), st(.magenta), st(.reset), st(.grey), st(.reset), st(.bold), name, st(.reset) });
    if (status.len > 0) try p("   {s}⟳ {s}{s}", .{ st(.yellow), status, st(.reset) });
    try w("\n");
    for (0..body) |k| {
        const i = scroll + k;
        if (i < lines.len) try w(lines[i]);
        try w("\n");
    }
    try w("    ");
    if (lines.len > body) {
        try p("{s}{d}–{d}/{d}{s}   ", .{ st(.grey), scroll + 1, @min(scroll + body, lines.len), lines.len, st(.reset) });
    }
    try hint("esc", "back");
    try hint("↑↓", "scroll");
    try hint("c", "check updates");
    try hint("r", "refresh");
    try hint("q", "quit");
    try present(endCap());
}

/// Returns true when the user asked to quit.
fn detailView(sel: usize) !bool {
    _ = refreshWidth();
    var lines = sectionLines(sel);
    var scroll: usize = 0;
    while (true) {
        if (refreshWidth()) lines = sectionLines(sel);
        const rows = termSize().rows;
        const body = if (rows > 6) rows - 4 else 2;
        const maxs = lines.len -| body;
        scroll = @min(scroll, maxs);
        try drawDetail(sel, lines, scroll, body, "");

        switch (readKey()) {
            .back => return false,
            .eof => return true,
            .up => scroll -|= 1,
            .down => scroll += 1,
            .pgup => scroll -|= body,
            .pgdn => scroll += body,
            .home => scroll = 0,
            .end => scroll = maxs,
            .char => |c| switch (c) {
                'q', 3 => return true,
                'h' => return false,
                'k' => scroll -|= 1,
                'j' => scroll += 1,
                ' ' => scroll += body,
                'g' => scroll = 0,
                'G' => scroll = maxs,
                'r', 'c' => {
                    const checking = c == 'c';
                    try drawDetail(sel, lines, scroll, body, if (checking) "checking for available updates…" else "refreshing…");
                    opts.check = checking;
                    if (sel < 4) gather(@enumFromInt(sel)) else gatherAll();
                    opts.check = false;
                    lines = sectionLines(sel);
                },
                else => {},
            },
            else => {},
        }
    }
}

fn tuiMain() !void {
    try rawOn();
    defer rawOff();
    _ = refreshWidth();
    drawLoading("gathering update status…");
    gatherAll();

    var sel: usize = 0;
    while (true) {
        _ = refreshWidth();
        try drawMenu(sel);
        switch (readKey()) {
            .up => sel = (sel + n_items - 1) % n_items,
            .down => sel = (sel + 1) % n_items,
            .home => sel = 0,
            .end => sel = n_items - 1,
            .enter => if (try detailView(sel)) return,
            .eof => return,
            .char => |c| switch (c) {
                'q', 3 => return,
                'k' => sel = (sel + n_items - 1) % n_items,
                'j' => sel = (sel + 1) % n_items,
                '1'...'5' => {
                    sel = c - '1';
                    if (try detailView(sel)) return;
                },
                'r' => {
                    drawLoading("refreshing…");
                    gatherAll();
                },
                else => {},
            },
            else => {},
        }
    }
}

// ─────────────────────────────────────────────────────────────── main
const usage_text =
    \\Usage: tustat [options] [image] [flatpak] [appimage] [timers]
    \\
    \\Shows when updates were last applied on tbzos, and what was applied.
    \\On a terminal with no sections given, opens an interactive menu.
    \\Otherwise prints the requested sections (all if none) and exits.
    \\
    \\  -p, --print      print instead of opening the menu
    \\  -c, --check      also check for available updates (network; no root)
    \\  -a, --all        show every package / day / log line, not just the latest
    \\  -d, --days N     Flatpak history window in days (default 30)
    \\  -V, --version    print version
    \\  -h, --help       this help
    \\
    \\Menu keys:
    \\  ↑↓ / j k  move or scroll     ⏎ / 1-5  open a section
    \\  esc       back to the menu   c        check for available updates
    \\  r         refresh            q        quit
    \\
    \\Env:
    \\  TUSTAT_APPIMAGE_DIRS   colon-separated AppImage dirs
    \\                         (default ~/AppImages:~/Applications:~/.local/bin)
    \\  NO_COLOR               disable colour
    \\
;

fn die(comptime f: []const u8, args: anytype) noreturn {
    std.debug.print("tustat: " ++ f ++ "\n\n" ++ usage_text, args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    A = init.arena.allocator();
    io = init.io;
    env = init.environ_map;

    var buf: [64 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    out = &fw.interface;

    tzset();
    now = std.Io.Clock.real.now(io).toSeconds();
    home = env.get("HOME") orelse "";
    const out_tty = std.Io.File.stdout().isTty(io) catch false;
    const in_tty = std.Io.File.stdin().isTty(io) catch false;
    use_color = out_tty and env.get("NO_COLOR") == null;
    _ = refreshWidth();

    var want = [_]bool{ false, false, false, false };
    var any = false;
    var print = false;
    const args = try init.minimal.args.toSlice(A);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (mem.eql(u8, a, "--check")) {
            opts.check = true;
        } else if (mem.eql(u8, a, "--all")) {
            opts.all = true;
        } else if (mem.eql(u8, a, "--print")) {
            print = true;
        } else if (mem.eql(u8, a, "--help")) {
            try w(usage_text);
            try out.flush();
            return;
        } else if (mem.eql(u8, a, "--version")) {
            try p("tustat {s}\n", .{version});
            try out.flush();
            return;
        } else if (mem.eql(u8, a, "--days") or mem.eql(u8, a, "-d")) {
            i += 1;
            if (i >= args.len) die("{s} needs a number", .{a});
            opts.days = std.fmt.parseInt(u32, args[i], 10) catch die("bad number '{s}'", .{args[i]});
        } else if (a.len > 1 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |ch| switch (ch) {
                'c' => opts.check = true,
                'a' => opts.all = true,
                'p' => print = true,
                'h' => {
                    try w(usage_text);
                    try out.flush();
                    return;
                },
                'V' => {
                    try p("tustat {s}\n", .{version});
                    try out.flush();
                    return;
                },
                else => die("unknown option -{c}", .{ch}),
            };
        } else if (std.meta.stringToEnum(Section, a)) |s| {
            want[@intFromEnum(s)] = true;
            any = true;
        } else {
            die("unknown argument '{s}'", .{a});
        }
    }

    if (!print and !any and out_tty and in_tty) {
        try tuiMain();
        return;
    }

    if (!any) want = .{ true, true, true, true };
    for (want, 0..) |on, k| {
        if (on) gather(@enumFromInt(k));
    }
    try header();
    for (want, 0..) |on, k| {
        if (on) try sumRow(@enumFromInt(k));
    }
    for (want, 0..) |on, k| {
        if (on) try render(@enumFromInt(k));
    }
    try w("\n");
    try out.flush();
}
