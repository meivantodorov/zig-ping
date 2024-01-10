# Zig Ping Program

This repository contains a simple implementation of a ping program written in Zig. It's a hobby project that sends ICMP echo requests to a specified IP address and listens for echo replies, displaying the round-trip time for each ping.

## Features

- Sends ICMP echo requests (ping) to a specified IP address.
- Receives ICMP echo replies and calculates the round-trip time.
- Displays the ping results in a readable format.
- Handles timeouts and errors gracefully.

## Requirements

- Zig compiler (tested with version 0.12.0-dev.1645+7b99189f1)
- Linux operating system with standard networking capabilities

## Installation

1. Clone the repository to your local machine:

   ```bash
   git clone https://github.com/meivantodorov/zig-ping.git
   ```

2. Navigate to the cloned directory:

   ```bash
   cd zig-ping
   ```

3. Compile the program using Zig:

   ```bash
   zig build --summary all
   ```

## Usage

Run the compiled executable with the target IP address as an argument:

```bash
sudo ./zig-out/bin/zig-ping 1.1.1.1
```

Replace `1.1.1.1` with the IP address you wish to ping.

## Program Output

The program outputs the following information for each ping:

- The number of bytes received in the echo reply.
- The IP address of the responding host.
- The ICMP sequence number.
- The Time-To-Live (TTL) value.
- The round-trip time in milliseconds.

Example output:

```
PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data
64 bytes from 1.1.1.1: icmp_seq=1 ttl=64 time=9 ms
64 bytes from 1.1.1.1: icmp_seq=2 ttl=64 time=9 ms
64 bytes from 1.1.1.1: icmp_seq=3 ttl=64 time=10 ms
```

## TODO

- Implement interruption with Ctrl + C and display statistics upon exit.
- Modify the `time` calculation to use floating-point numbers for more accurate timing.
- Parse unsuccessful cases.
- Add functionality to ping hostnames.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

This README provides a basic overview of your Zig ping program. Feel free to adjust or expand it as needed to fit the evolving nature of your project.