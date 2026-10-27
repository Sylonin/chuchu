//! Cross-platform UDP socket wrapper for mosh transport.
//!
//! Uses POSIX sockets directly for Android/iOS compatibility.

const std = @import("std");

pub const SocketError = error{
    CreateFailed,
    BindFailed,
    ResolveFailed,
    SendFailed,
    ReceiveFailed,
    WouldBlock,
    NotOpen,
    AlreadyOpen,
};

const linux = std.os.linux;

pub const MoshSocket = struct {
    const Self = @This();

    fd: ?linux.fd_t = null,
    remote_addr: linux.sockaddr.in = std.mem.zeroes(linux.sockaddr.in),
    local_port: u16 = 0,

    pub fn init() Self {
        return .{};
    }

    /// Open a non-blocking UDP socket and optionally bind to `local_port`.
    /// If `local_port` is 0 the OS assigns an ephemeral port.
    pub fn open(self: *Self, local_port: u16) SocketError!void {
        if (self.fd != null) return SocketError.AlreadyOpen;

        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return SocketError.CreateFailed;
        const sock: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(sock);

        const addr: linux.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, local_port),
            .addr = 0, // INADDR_ANY
        };
        if (linux.errno(linux.bind(sock, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            return SocketError.BindFailed;
        }

        self.fd = sock;
        self.local_port = local_port;

        // Resolve actual bound port if ephemeral
        if (local_port == 0) {
            var bound_addr: linux.sockaddr.in = undefined;
            var bound_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            if (linux.errno(linux.getsockname(sock, @ptrCast(&bound_addr), &bound_len)) == .SUCCESS) {
                self.local_port = std.mem.bigToNative(u16, bound_addr.port);
            }
        }
    }

    /// Set the remote endpoint address (dotted-quad IPv4). Call before send/receive.
    pub fn setRemote(self: *Self, host: []const u8, port: u16) SocketError!void {
        var octets: [4]u8 = undefined;
        var it = std.mem.splitScalar(u8, host, '.');
        for (&octets) |*octet| {
            const part = it.next() orelse return SocketError.ResolveFailed;
            octet.* = std.fmt.parseInt(u8, part, 10) catch return SocketError.ResolveFailed;
        }
        if (it.next() != null) return SocketError.ResolveFailed;

        self.remote_addr = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(octets),
        };
    }

    /// Send a datagram to the configured remote endpoint.
    pub fn send(self: *Self, data: []const u8) SocketError!void {
        const sock = self.fd orelse return SocketError.NotOpen;
        const rc = linux.sendto(sock, data.ptr, data.len, 0, @ptrCast(&self.remote_addr), @sizeOf(linux.sockaddr.in));
        return switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => SocketError.WouldBlock,
            else => SocketError.SendFailed,
        };
    }

    /// Receive a datagram. Returns `null` if no data is available (non-blocking).
    pub fn receive(self: *Self, buf: []u8) SocketError!?usize {
        const sock = self.fd orelse return SocketError.NotOpen;
        const rc = linux.recvfrom(sock, buf.ptr, buf.len, 0, null, null);
        return switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .AGAIN => null,
            .CONNREFUSED => null, // ICMP port unreachable on some platforms
            else => SocketError.ReceiveFailed,
        };
    }

    pub fn close(self: *Self) void {
        if (self.fd) |sock| {
            _ = linux.close(sock);
            self.fd = null;
        }
    }

    pub fn deinit(self: *Self) void {
        self.close();
        self.* = .{
            .fd = null,
            .remote_addr = std.mem.zeroes(linux.sockaddr.in),
            .local_port = 0,
        };
    }
};

test "open bind send receive roundtrip" {
    var server = MoshSocket.init();
    defer server.deinit();
    try server.open(0);
    const server_port = server.local_port;
    try std.testing.expect(server_port > 0);

    var client = MoshSocket.init();
    defer client.deinit();
    try client.open(0);

    try client.setRemote("127.0.0.1", server_port);
    try client.send("ping");

    var buf: [64]u8 = undefined;
    var received: ?usize = null;
    // Retry a few times because non-blocking recv may race with send.
    for (0..100) |_| {
        received = try server.receive(&buf);
        if (received != null) break;
        std.Thread.sleep(1_000_000); // 1ms
    }
    try std.testing.expect(received != null);
    try std.testing.expectEqualStrings("ping", buf[0..received.?]);
}

test "nonblocking receive returns null when empty" {
    var sock = MoshSocket.init();
    defer sock.deinit();
    try sock.open(0);

    var buf: [64]u8 = undefined;
    const received = try sock.receive(&buf);
    try std.testing.expect(received == null);
}

test "send without open fails" {
    var sock = MoshSocket.init();
    defer sock.deinit();
    try sock.setRemote("127.0.0.1", 12345);
    try std.testing.expectError(SocketError.NotOpen, sock.send("x"));
}
