const std = @import("std");
const builtin = @import("builtin");

const hzzp = @import("hzzp");
const wz = @import("wz");

const Heartbeat = @import("Client/Heartbeat.zig");
const https = @import("https.zig");
const discord = @import("discord.zig");
const json = @import("json.zig");
const util = @import("util.zig");

const log = std.log.scoped(.zCord);
const default_agent = "zCord/0.0.1";

const Client = @This();

allocator: *std.mem.Allocator,

auth_token: []const u8,
user_agent: []const u8,
intents: discord.Gateway.Intents,
presence: discord.Gateway.Presence,
connect_info: ?ConnectInfo,

ssl_tunnel: ?*https.Tunnel,
wz: WzClient,
wz_buffer: [0x1000]u8,
write_mutex: std.Thread.Mutex,

heartbeat: Heartbeat,

const WzClient = wz.base.client.BaseClient(https.Tunnel.Client.Reader, https.Tunnel.Client.Writer);
pub const JsonElement = json.Stream(WzClient.PayloadReader).Element;

pub const ConnectInfo = struct {
    heartbeat_interval_ms: u64,
    seq: u32,
    user_id: discord.Snowflake(.user),
    session_id: std.BoundedArray(u8, 0x100),
};

pub fn create(args: struct {
    allocator: *std.mem.Allocator,
    auth_token: []const u8,
    user_agent: []const u8 = default_agent,
    intents: discord.Gateway.Intents = .{},
    presence: discord.Gateway.Presence = .{},
    heartbeat: Heartbeat.Strategy = Heartbeat.Strategy.default,
}) !*Client {
    const result = try args.allocator.create(Client);
    errdefer args.allocator.destroy(result);
    result.allocator = args.allocator;

    result.auth_token = args.auth_token;
    result.user_agent = args.user_agent;
    result.intents = args.intents;
    result.presence = args.presence;
    result.connect_info = null;

    result.ssl_tunnel = null;
    result.write_mutex = .{};

    result.heartbeat = try Heartbeat.init(result, args.heartbeat);
    errdefer result.heartbeat.deinit();

    return result;
}

pub fn destroy(self: *Client) void {
    if (self.ssl_tunnel) |ssl_tunnel| {
        ssl_tunnel.destroy();
    }
    self.heartbeat.deinit();
    self.allocator.destroy(self);
}

fn fetchGatewayHost(self: *Client, buffer: []u8) ![]const u8 {
    var req = try self.sendRequest(self.allocator, .GET, "/api/v8/gateway/bot", null);
    defer req.deinit();

    switch (req.response_code.?) {
        .success_ok => {},
        .client_unauthorized => return error.AuthenticationFailed,
        else => {
            log.warn("Unknown response code: {}", .{req.response_code.?});
            return error.UnknownGatewayResponse;
        },
    }

    try req.completeHeaders();

    var stream = json.stream(req.client.reader());

    const root = try stream.root();
    const match = (try root.objectMatchOne("url")) orelse return error.UnknownGatewayResponse;
    const url = try match.value.stringBuffer(buffer);
    if (std.mem.startsWith(u8, url, "wss://")) {
        return url["wss://".len..];
    } else {
        log.warn("Unknown url: {s}", .{url});
        return error.UnknownGatewayResponse;
    }
}

fn connect(self: *Client) !ConnectInfo {
    std.debug.assert(self.ssl_tunnel == null);

    var buf: [0x100]u8 = undefined;
    const host = try self.fetchGatewayHost(&buf);

    self.ssl_tunnel = try https.Tunnel.create(.{
        .allocator = self.allocator,
        .host = host,
    });
    errdefer self.disconnect();

    const reader = self.ssl_tunnel.?.client.reader();
    const writer = self.ssl_tunnel.?.client.writer();

    const Reader = @TypeOf(reader);
    const Writer = @TypeOf(writer);

    const seed = @truncate(u64, @bitCast(u128, std.time.nanoTimestamp()));
    var prng = std.rand.DefaultPrng.init(seed);

    // Handshake

    // DefaultHandshakeClient on 0.0.6
    // HandshakeClient on master
    //
    // At the end I needed to change DefaultHandshakeClient src at the end
    // This is solved on master branch
    var handshake = wz.base.client.DefaultHandshakeClient(Reader, Writer).init(&self.wz_buffer, reader, writer, prng);
    try handshake.writeStatusLine("/?v=6&encoding=json");
    try handshake.writeHeaderValue("Host", host);
    try handshake.finishHeaders();

    if (!try handshake.wait()) {
        return error.HandshakeError;
    }

    self.wz = wz.base.client.create(
        &self.wz_buffer,
        self.ssl_tunnel.?.client.reader(),
        self.ssl_tunnel.?.client.writer(),
    );

    if (try self.wz.next()) |event| {
        std.debug.assert(event == .header);
    }

    var result: ConnectInfo = undefined;

    var flush_error: WzClient.ReadNextError!void = {};
    {
        std.log.info("here2", .{});

        var stream = json.stream(self.wz.reader());
        defer self.wz.flushReader() catch |err| {
            flush_error = err;
        };
        errdefer |err| log.info("{}", .{stream.debugInfo()});

        const root = try stream.root();
        const paths = try json.path.match(root, struct {
            @"op": u8,
            @"d.heartbeat_interval": u32,
        });

        if (paths.@"op" != @enumToInt(discord.Gateway.Opcode.hello)) {
            return error.MalformedHelloResponse;
        }

        result.heartbeat_interval_ms = paths.@"d.heartbeat_interval";
    }
    try flush_error;

    if (result.heartbeat_interval_ms == 0) {
        return error.MalformedHelloResponse;
    }

    if (self.connect_info) |old_info| {
        try self.sendCommand(.{ .@"resume" = .{
            .token = self.auth_token,
            .seq = old_info.seq,
            .session_id = old_info.session_id.constSlice(),
        } });
        result.seq = old_info.seq;
        result.user_id = old_info.user_id;
        result.session_id = old_info.session_id;
        return result;
    }

    try self.sendCommand(.{ .identify = .{
        .compress = false,
        .intents = self.intents,
        .token = self.auth_token,
        .properties = .{
            .@"$os" = @tagName(builtin.target.os.tag),
            .@"$browser" = self.user_agent,
            .@"$device" = self.user_agent,
        },
        .presence = self.presence,
    } });

    if (try self.wz.next()) |event| {
        if (event.header.opcode == .close) {
            try self.processCloseEvent();
        }
    }

    {
        var stream = json.stream(self.wz.reader());
        defer self.wz.flushReader() catch |err| {
            flush_error = err;
        };
        errdefer |err| log.info("{}", .{stream.debugInfo()});

        const root = try stream.root();
        const paths = try json.path.match(root, struct {
            @"t": std.BoundedArray(u8, 0x100),
            @"s": ?u32,
            @"op": u8,
            @"d.session_id": std.BoundedArray(u8, 0x100),
            @"d.user.id": discord.Snowflake(.user),
            @"d.user.username": std.BoundedArray(u8, 0x100),
            @"d.user.discriminator": std.BoundedArray(u8, 0x100),
        });

        if (!std.mem.eql(u8, paths.@"t".constSlice(), "READY")) {
            return error.MalformedIdentify;
        }
        if (paths.@"op" != @enumToInt(discord.Gateway.Opcode.dispatch)) {
            return error.MalformedIdentify;
        }

        if (paths.@"s") |seq| {
            result.seq = seq;
        }

        result.user_id = paths.@"d.user.id";
        result.session_id = paths.@"d.session_id";

        log.info("Connected -- {s}#{s}", .{
            paths.@"d.user.username".constSlice(),
            paths.@"d.user.discriminator".constSlice(),
        });
    }
    try flush_error;

    return result;
}

fn disconnect(self: *Client) void {
    if (self.ssl_tunnel) |ssl_tunnel| {
        ssl_tunnel.destroy();
        self.ssl_tunnel = null;
    }
}

pub fn ws(self: *Client, context: anytype, comptime handler: type) !void {
    var reconnect_wait: u64 = 1;
    while (true) {
        self.connect_info = self.connect() catch |err| switch (err) {
            error.AuthenticationFailed,
            error.DisallowedIntents,
            error.CertificateVerificationFailed,
            => |e| return e,
            else => {
                log.info("Connect error: {s}", .{@errorName(err)});
                std.time.sleep(reconnect_wait * std.time.ns_per_s);
                reconnect_wait = std.math.min(reconnect_wait * 2, 30);
                continue;
            },
        };
        defer self.disconnect();

        if (@hasDecl(handler, "handleConnect")) {
            handler.handleConnect(context, self.connect_info.?);
        }

        reconnect_wait = 1;

        self.heartbeat.send(.start);
        defer self.heartbeat.send(.stop);

        self.listen(context, handler) catch |err| switch (err) {
            error.ConnectionReset => continue,
            error.InvalidSession => {
                self.connect_info = null;
                continue;
            },
            else => |e| {
                // TODO: convert this to inline switch once available
                if (!util.errSetContains(WzClient.ReadNextError, e)) {
                    return e;
                }
            },
        };
    }
}

fn processCloseEvent(self: *Client) !void {
    const event = (try self.wz.next()).?;

    const code_num = std.mem.readIntBig(u16, event.chunk.data[0..2]);
    const code = @intToEnum(discord.Gateway.CloseEventCode, code_num);
    switch (code) {
        _ => {
            log.info("Websocket close frame - {d}: unknown code. Reconnecting...", .{code_num});
            return error.ConnectionReset;
        },
        .NormalClosure,
        .GoingAway,
        .ProtocolError,
        .NoStatusReceived,
        .AbnormalClosure,
        .PolicyViolation,
        .InternalError,
        .ServiceRestart,
        .TryAgainLater,
        .BadGateway,
        .UnknownError,
        .SessionTimedOut,
        => {
            log.info("Websocket close frame - {d}: {s}. Reconnecting...", .{ @enumToInt(code), @tagName(code) });
            return error.ConnectionReset;
        },

        // Most likely user error
        .UnsupportedData => return error.UnsupportedData,
        .InvalidFramePayloadData => return error.InvalidFramePayloadData,
        .MessageTooBig => return error.MessageTooBig,
        .AuthenticationFailed => return error.AuthenticationFailed,
        .AlreadyAuthenticated => return error.AlreadyAuthenticated,
        .DecodeError => return error.DecodeError,
        .UnknownOpcode => return error.UnknownOpcode,
        .RateLimited => return error.WoahNelly,
        .DisallowedIntents => return error.DisallowedIntents,

        // We don't support these yet
        .InvalidSeq => unreachable,
        .InvalidShard => unreachable,
        .ShardingRequired => unreachable,
        .InvalidApiVersion => unreachable,

        // This library fucked up
        .MissingExtension => unreachable,
        .TlsHandshake => unreachable,
        .NotAuthenticated => unreachable,
        .InvalidIntents => unreachable,
    }
}

fn listen(self: *Client, context: anytype, comptime handler: type) !void {
    while (try self.wz.next()) |event| {
        switch (event.header.opcode) {
            .text => {
                self.processChunks(self.wz.reader(), context, handler) catch |err| switch (err) {
                    error.ConnectionReset, error.InvalidSession => |e| return e,
                    else => {
                        log.warn("Process chunks failed: {s}", .{err});
                    },
                };
                try self.wz.flushReader();
            },
            .ping, .pong => {},
            .close => try self.processCloseEvent(),
            .binary => return error.WtfBinary,
            else => return error.WtfWtf,
        }
    }

    log.info("Websocket close frame - {{}}: no reason provided. Reconnecting...", .{});
    return error.ConnectionReset;
}

fn processChunks(self: *Client, reader: anytype, context: anytype, comptime handler: type) !void {
    var stream = json.stream(reader);
    errdefer |err| {
        if (util.errSetContains(@TypeOf(stream).ParseError, err)) {
            log.warn("{}", .{stream.debugInfo()});
        }
    }

    var name_buf: [32]u8 = undefined;
    var name: ?[]u8 = null;
    var op: ?discord.Gateway.Opcode = null;

    const root = try stream.root();

    while (try root.objectMatch(enum { t, s, op, d })) |match| switch (match.key) {
        .t => {
            name = try match.value.optionalStringBuffer(&name_buf);
        },
        .s => {
            if (try match.value.optionalNumber(u32)) |seq| {
                self.connect_info.?.seq = seq;
            }
        },
        .op => {
            op = try std.meta.intToEnum(discord.Gateway.Opcode, try match.value.number(u8));
        },
        .d => {
            switch (op orelse return error.DataBeforeOp) {
                .dispatch => {
                    log.info("<< {d} -- {s}", .{ self.connect_info.?.seq, name });
                    try handler.handleDispatch(
                        context,
                        name orelse return error.DispatchWithoutName,
                        match.value,
                    );
                },
                .heartbeat_ack => self.heartbeat.send(.ack),
                .reconnect => {
                    log.info("Discord reconnect. Reconnecting...", .{});
                    return error.ConnectionReset;
                },
                .invalid_session => {
                    log.info("Discord invalid session. Reconnecting...", .{});
                    const resumable = match.value.boolean() catch false;
                    if (resumable) {
                        return error.ConnectionReset;
                    } else {
                        return error.InvalidSession;
                    }
                },
                else => {
                    log.info("Unhandled {} -- {s}", .{ op, name });
                    match.value.debugDump(std.io.getStdErr().writer()) catch {};
                },
            }
            _ = try match.value.finalizeToken();
        },
    };
}

pub fn sendCommand(self: *Client, command: discord.Gateway.Command) !void {
    if (self.ssl_tunnel == null) return error.NotConnected;

    var buf: [0x1000]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{s}", .{json.format(command)});

    self.write_mutex.lock();
    defer self.write_mutex.unlock();

    try self.wz.writeHeader(.{ .opcode = .text, .length = msg.len });
    try self.wz.writeChunk(msg);
}

pub fn sendRequest(self: *Client, allocator: *std.mem.Allocator, method: https.Request.Method, path: []const u8, body: anytype) !https.Request {
    var req = try https.Request.init(.{
        .allocator = allocator,
        .host = "discord.com",
        .method = method,
        .path = path,
        .user_agent = self.user_agent,
    });
    errdefer req.deinit();

    try req.client.writeHeaderValue("Accept", "application/json");
    try req.client.writeHeaderValue("Content-Type", "application/json");
    try req.client.writeHeaderValue("Authorization", self.auth_token);

    switch (@typeInfo(@TypeOf(body))) {
        .Null => _ = try req.sendEmptyBody(),
        .Optional => {
            if (body == null) {
                _ = try req.sendEmptyBody();
            } else {
                _ = try req.sendPrint("{}", .{json.format(body)});
            }
        },
        else => _ = try req.sendPrint("{}", .{json.format(body)}),
    }

    return req;
}

test {
    std.testing.refAllDecls(@This());
}
