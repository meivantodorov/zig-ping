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

// 64 ms TTL
const ttl_val = [4]u8{ 64, 0, 0, 0 };

var g_interrupted: bool = false;

// 8, 0 type/code
const req = [_]u8{ 8, 0 };
const empty_checksum = [_]u8{ 0, 0 };
const identifier = [_]u8{ 0, 0 };
// 8 * 56 octets
const data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

var startTime: i64 = 0;

var displayed_init_ping = false;

var total_seq: u16 = 0;

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    // Ensure IP address has been provided as arg
    if (args.len < 2) {
        print("Expected IP-Address to be provided as args[1]. For example: zing 127.0.0.1 \n", .{});
        return;
    }
    const socket = setup_socket() catch return undefined;
    defer os.close(socket);

    // Getting IP from the args and convert it to string
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

    var seq_num: usize = 0;
    while (!g_interrupted) {
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
        _ = listener(socket);

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

pub fn setup_socket() !os.fd_t {
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
                print("PING {any}.{any}.{any}.{any} ", .{ packet[16], packet[17], packet[18], packet[19] });
                print("({any}.{any}.{any}.{any}) {any}({any}) bytes of data \n", .{ packet[16], packet[17], packet[18], packet[19], icmp_payload, icmp_total_len });
                displayed_init_ping = true;
            }

            const endTime = std.time.milliTimestamp();
            const duration = endTime - startTime;

            print("{any} bytes from {any}.{any}.{any}.{any}: icmp_seq={any} ttl={any} time={any} ms\n", .{ packet.len, packet[16], packet[17], packet[18], packet[19], sequenceNumber, packet[8], duration });

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
