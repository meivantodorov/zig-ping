const std = @import("std");
const print = std.debug.print;
const os = std.os;
const mem = std.mem;

const IP_TTL = 2; //os.IP.TTL;
const SOCK_RAW = os.SOCK.RAW;
const IPPROTO_ICMP = os.IPPROTO.ICMP; // this must be 1

const SOL_SOCKET: comptime_int = os.SOL.SOCKET;

const SO_RCVTIMEO: comptime_int = os.SO.RCVTIMEO;
const SOL_IP: comptime_int = os.SOL.IP;

var g_interrupted: bool = false;

// 8, 0 type/code
const req = [_]u8{ 8, 0 };
const empty_checksum = [_]u8{ 0, 0 };
const identifier = [_]u8{ 0, 0 };
// 8 * 56 octets
const data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

// Example of valid echo request packet
// [_]u8{ 8, 0, 6, 169, 0, 0, 241, 86} ++ data;

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    // Checks if there has been provided IP address as arg
    if (args.len < 2) {
        print("Expected IP-Address to be provided as args[1]. For example: zing 127.0.0.1 \n", .{});
        return;
    }
    const socket = setup_socket() catch return undefined;
    defer os.close(socket);

    // Getting IP from the args
    const ipString = args[1];
    var ip_tmp: [4]u8 = undefined;

    var index: usize = 0;
    var tokenIterator = std.mem.tokenize(u8, ipString, ".");
    while (tokenIterator.next()) |token| {
        const byte = try std.fmt.parseInt(u8, token, 10);
        if (byte > 255) {
            std.debug.print("Invalid IP address\n", .{});
            return;
        }
        ip_tmp[index] = byte;
        index += 1;
    }

    if (index != 4) {
        std.debug.print("Invalid IP address format\n", .{});
        return;
    }

    const ip = &ip_tmp;

    var rand_impl = std.rand.DefaultPrng.init(5000);
    while (!g_interrupted) {
        // Generate rnd seq and create icmp packet with the correct checksum
        var num = @mod(rand_impl.random().int(i32), 6500);
        const lowerByte = @as(u8, @intCast(num & 0xFF));
        const upperByte = @as(u8, @intCast(num >> 8));
        const seq = [_]u8{ upperByte, lowerByte };

        // Calc the checksum for the payload and create the final icmp packet
        var payload = req ++ empty_checksum ++ identifier ++ seq ++ data;
        const csum_struct = calc_checksum(&payload);
        const csum = [_]u8{ csum_struct.be, csum_struct.le };
        var packet = req ++ csum ++ identifier ++ seq ++ data;

        // Actual send and await for the resp data
        try send_ping(socket, &packet, ip);
        _ = listener(socket);

        // One second delay
        const nanoseconds_in_second = std.time.ns_per_s;
        std.time.sleep(nanoseconds_in_second);
    }
}

fn calc_checksum(array: []u8) struct { be: u8, le: u8 } {
    var sum: u16 = 0;
    var i: usize = 0;
    while (i < array.len) : (i += 2) {
        const upperByte = @as(u16, @intCast(array[i])) << 8;
        const lowerByte = @as(u16, @intCast(array[i + 1]));
        const combinedValue = upperByte | lowerByte;
        sum += combinedValue;
    }

    const lowerByte = @as(u8, @intCast(~sum & 0xFF));
    const upperByte = @as(u8, @intCast(~sum >> 8));

    return .{ .be = upperByte, .le = lowerByte };
}

fn send_ping(socket: os.fd_t, packet: []u8, ip: []u8) !void {
    const dest_addr = os.sockaddr{ .family = os.AF.INET, .data = [14]u8{ 0, 0, ip[0], ip[1], ip[2], ip[3], 0, 0, 0, 0, 0, 0, 0, 0 } };

    // Sending the icmp packet down the pipe.
    _ = try os.sendto(socket, packet, 0, &dest_addr, @sizeOf(os.sockaddr));
}

pub fn setup_socket() !os.fd_t {
    // 64 ms TTL
    const ttl_val = [4]u8{ 64, 0, 0, 0 };

    // Create the socket.
    const socket = try os.socket(os.AF.INET, SOCK_RAW, IPPROTO_ICMP);
    errdefer os.close(socket);
    try os.setsockopt(socket, SOL_IP, IP_TTL, ttl_val[0..]);

    return socket;
}

pub fn listener(socket: i32) ?void {
    // Set the socket timeout to 1 second.
    const ts = os.timespec{ .tv_sec = 1, .tv_nsec = 0 };

    os.setsockopt(socket, SOL_SOCKET, 2, mem.asBytes(&ts)) catch |err| {
        print("setsockopt catch ? {any} \n", .{err});
        return null;
    };

    var recv_addr: os.sockaddr = undefined;
    var packet: [64]u8 = undefined;
    var attempts: u8 = 0;
    const max_attempts: u8 = 3;
    while (true) {
        attempts += 1;

        if (attempts > max_attempts) {
            print("Max attempts reached. Exiting loop.\n", .{});
            break;
        }

        if (recv_ping(socket, &recv_addr, packet[0..])) |_result| {
            _ = _result;

            // const icmp_message = packet[20..res];
            // print("PING {any}.{any}.{any}.{any}\n", .{ packet[16], packet[17], packet[18], packet[19] });
            // print("recev packet data: {any} \n", .{icmp_message});
            print("PING {any}.{any}.{any}.{any} OK\n", .{ packet[16], packet[17], packet[18], packet[19] });
            // print("OK {any}\n", .{packet});
            break;
        } else |err| {
            print("ERROR {any} \n", .{err});
            break;
        }
        print("Attempts {d}\n", .{attempts});
    }

    return null;
}

pub fn recv_ping(socket: os.fd_t, recv_addr: *os.sockaddr, packet: []u8) !usize {
    var addrlen: u32 = @sizeOf(os.sockaddr);
    return try os.recvfrom(socket, packet, 0, recv_addr, &addrlen);
}
