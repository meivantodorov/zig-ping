const std = @import("std");
const print = std.debug.print;
const os = std.os;
const mem = std.mem;
const signal = @import("signal");
const assert = std.debug.assert;

const IP_TTL = 2; //os.IP.TTL;
const SOCK_RAW = os.SOCK.RAW;
const IPPROTO_ICMP = os.IPPROTO.ICMP; // this must be 1

const SOL_SOCKET: comptime_int = os.SOL.SOCKET;

const SO_RCVTIMEO: comptime_int = os.SO.RCVTIMEO;
const SOL_IP: comptime_int = os.SOL.IP;

// 64 ms TTL
var sigint_detected: bool = false;

// 8, 0 type/code
const req = [_]u8{ 8, 0 };
const empty_checksum = [_]u8{ 0, 0 };
const identifier = [_]u8{ 0, 0 };
// 8 * 56 octets
const data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

var startTime: i64 = 0;
var displayed_init_ping = false;
var total_seq: u16 = 0;

const Arguments = struct {
    ttl: u8 = 64,
};

const PingData = struct {
    sent: bool = false,
    icmp_seq: usize,
    ttl: usize,
    time_ms: i64,
};

const help =
    \\Usage
    \\  ./zig-ping [options] <destination>
    \\
    \\Options:
    \\  <destination>      dns name or ip address
    \\  -h                 print help and exit
    \\  -t <ttl>           define time to live
;

var display_ip: [4]u8 = undefined;

var pingDataList = std.ArrayList(PingData).init(std.heap.page_allocator);

pub fn main() !void {
    var arg_params = Arguments{};
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    // Ensure IP address has been provided as arg
    if (args.len < 2) {
        print("ping: usage error: Destination address required \n", .{});
        return;
    }

    for (0.., args[1..]) |i, elem| {
        if (std.mem.eql(u8, elem, "-h")) {
            print("{s}\n", .{help});
            return;
        }

        if (std.mem.eql(u8, args[i], "-t")) {
            const argValue = try std.fmt.parseInt(u8, elem, 10);
            arg_params.ttl = argValue;
        }
    }

    // Getting IP from the args and convert it to string
    const ipString = args[1];
    var ip_tmp: [4]u8 = undefined;

    var index: usize = 0;
    var tokenIterator = std.mem.tokenize(u8, ipString, ".");

    while (tokenIterator.next()) |token| {
        const byte = try std.fmt.parseInt(u8, token, 10);
        if (byte > 255) {
            std.debug.print("invalid IP address\n", .{});
            return;
        }
        ip_tmp[index] = byte;
        index += 1;
    }

    const socket = setup_socket(arg_params) catch return;
    defer os.close(socket);

    if (index != 4) {
        std.debug.print("Invalid IP address format\n", .{});
        return;
    }

    display_ip = ip_tmp;
    const ip = &ip_tmp;

    var seq_num: usize = 0;
    try setAbortSignalHandler(sigintHandler);

    defer pingDataList.deinit();
    while (!sigint_detected) {
        seq_num += 1;
        const lowerByte = @as(u8, @intCast(seq_num & 0xFF));
        const upperByte = @as(u8, @intCast(seq_num >> 8));
        const seq = [_]u8{ upperByte, lowerByte };

        // Calc the checksum for the payload and create the final icmp packet
        var payload = req ++ empty_checksum ++ identifier ++ seq ++ data;
        const csum_struct = calc_checksum(&payload);
        const csum = [_]u8{ csum_struct.be, csum_struct.le };
        var packet = req ++ csum ++ identifier ++ seq ++ data;

        // Actual send and await for the resp data
        startTime = std.time.milliTimestamp();
        try send_ping(socket, &packet, ip);
        _ = try listener(socket);

        // One second delay
        const nanoseconds_in_second = std.time.ns_per_s;
        std.time.sleep(nanoseconds_in_second);
    }
    displayed_init_ping = false;
}

fn send_ping(socket: os.fd_t, packet: []u8, ip: []u8) !void {
    const dest_addr = os.sockaddr{ .family = os.AF.INET, .data = [14]u8{ 0, 0, ip[0], ip[1], ip[2], ip[3], 0, 0, 0, 0, 0, 0, 0, 0 } };

    // Sending the icmp packet down the pipe.
    _ = try os.sendto(socket, packet, 0, &dest_addr, @sizeOf(os.sockaddr));
}

pub fn setup_socket(args: Arguments) !os.fd_t {
    const ttl_val = [4]u8{ args.ttl, 0, 0, 0 };
    // Create the socket.
    const socket = try os.socket(os.AF.INET, SOCK_RAW, IPPROTO_ICMP);
    errdefer os.close(socket);
    try os.setsockopt(socket, SOL_IP, IP_TTL, ttl_val[0..]);

    return socket;
}

pub fn listener(socket: i32) !void {
    // Set the socket timeout to 1 second.
    const ts = os.timespec{ .tv_sec = 5, .tv_nsec = 0 };

    os.setsockopt(socket, SOL_SOCKET, 2, mem.asBytes(&ts)) catch |err| {
        print("setsockopt catch ? {any} \n", .{err});
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

        if (recv_ping(socket, &recv_addr, packet[0..])) |result| {
            var ip_header = packet[0..2];
            const ihl = (ip_header[0] & 0x0F) * 4; // multiiplying by 4 bytes word to get the ip header len

            const icmp_message = packet[20..result];

            var b = icmp_message[7];
            const sequenceNumber: usize = total_seq * 256 + b;

            var resp_seq = icmp_message[6..8];
            var resp_csum = icmp_message[2..4];
            var resp_type_code = icmp_message[0..2];

            var resp_msg = [_]u8{ resp_type_code[0], resp_type_code[1] } ++ empty_checksum ++ identifier ++ [_]u8{ resp_seq[0], resp_seq[1] } ++ data;

            // Check resp checksum and break if the sum is incorrect
            const csum = calc_checksum(&resp_msg);
            if ((resp_csum[0] != csum.be) or (resp_csum[1] != csum.le)) {
                print("Incorrect checksum! {any}\n", .{icmp_message});
                break;
            }

            if (b == 255) {
                total_seq += 1;
            }

            const icmp_payload = (packet.len) - 8;
            const icmp_total_len = packet.len + ihl;
            if (displayed_init_ping == false) {
                print("PING {any}.{any}.{any}.{any} ", .{ packet[12], packet[13], packet[14], packet[15] });
                print("({any}.{any}.{any}.{any}) {any}({any}) bytes of data \n", .{ packet[12], packet[13], packet[14], packet[15], icmp_payload, icmp_total_len });
                displayed_init_ping = true;
            }

            const endTime = std.time.milliTimestamp();
            const duration = endTime - startTime;

            print("{any} bytes from {any}.{any}.{any}.{any}: icmp_seq={any} ttl={any} time={any} ms\n", .{ packet.len, packet[12], packet[13], packet[14], packet[15], sequenceNumber, packet[8], duration });

            try pingDataList.append(PingData{
                .sent = true,
                .icmp_seq = sequenceNumber,
                .ttl = packet[8],
                .time_ms = duration,
            });
            break;
        } else |err| {
            print("ERROR {any} \n", .{err});
            break;
        }
        print("Attempts {d}\n", .{attempts});
    }
}

pub fn recv_ping(socket: os.fd_t, recv_addr: *os.sockaddr, packet: []u8) !usize {
    var addrlen: u32 = @sizeOf(os.sockaddr);
    return try os.recvfrom(socket, packet, 0, recv_addr, &addrlen);
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

// SigInt handling

fn setAbortSignalHandler(comptime handler: *const fn () void) !void {
    const internal_handler = struct {
        fn internal_handler(sig: c_int) callconv(.C) void {
            assert(sig == os.SIG.INT);
            handler();
        }
    }.internal_handler;
    const act = os.Sigaction{
        .handler = .{ .handler = internal_handler },
        .mask = os.empty_sigset,
        .flags = 0,
    };
    try os.sigaction(os.SIG.INT, &act, null);
}

fn sigintHandler() void {
    sigint_detected = true;
    std.debug.print("\n---{}.{}.{}.{} ping statistics ---\n", .{ display_ip[0], display_ip[1], display_ip[2], display_ip[3] });
    var sent: usize = 0;
    var total_time: i64 = 0;
    const total_packets = pingDataList.items.len;
    for (pingDataList.items) |item| {
        if (item.sent) {
            sent += 1;
        }
        total_time += item.time_ms;
    }
    var lost_percentage: u64 = 100;
    if (total_packets > 0) {
        lost_percentage = ((total_packets - sent) / total_packets) * 100;
    }

    std.debug.print("{} packets, transmitted, {} received, {}% packet loss, time {}ms\n", .{ pingDataList.items.len, sent, lost_percentage, total_time });
}
