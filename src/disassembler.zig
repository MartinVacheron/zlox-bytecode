const std = @import("std");
const print = std.debug.print;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;

pub const Disassembler = struct {
    chunk: *const Chunk,

    const Self = @This();

    pub fn init(chunk: *const Chunk) Self {
        return .{
            .chunk = chunk,
        };
    }

    pub fn dis_chunk(self: *const Self, name: []const u8) !void {
        print("== {s} ==\n", .{name});

        var i: usize = 0;
        while (i < self.chunk.code.items.len) {
            i = self.dis_instruction(i);
        }
    }

    pub fn dis_instruction(self: *const Self, offset: usize) usize {
        print("{:0>4} ", .{offset});

        if (offset > 0 and self.chunk.lines.items[offset] == self.chunk.lines.items[offset - 1]) {
            print("   | ", .{});
        } else {
            print("{:>4} ", .{self.chunk.lines.items[offset]});
        }

        const op: OpCode = @enumFromInt(self.chunk.code.items[offset]);
        return switch (op) {
            .Add => simple_instruction("OP_ADD", offset),
            .Constant => self.constant_instruction("OP_CONSTANT", offset),
            .Divide => simple_instruction("OP_DIVIDE", offset),
            .Equal => simple_instruction("OP_EQUAL", offset),
            .False => simple_instruction("OP_FALSE", offset),
            .Greater => simple_instruction("OP_GREATER", offset),
            .Less => simple_instruction("OP_LESS", offset),
            .Multiply => simple_instruction("OP_MULTIPLY", offset),
            .Negate => simple_instruction("OP_NEGATE", offset),
            .Not => simple_instruction("OP_NOT", offset),
            .Null => simple_instruction("OP_NULL", offset),
            .Return => simple_instruction("OP_RETURN", offset),
            .Subtract => simple_instruction("OP_SUBTRACT", offset),
            .True => simple_instruction("OP_TRUE", offset),
        };
    }

    fn simple_instruction(name: []const u8, offset: usize) usize {
        print("{s:<16}\n", .{name});
        return offset + 1;
    }

    fn constant_instruction(self: *const Self, name: []const u8, offset: usize) usize {
        const constant = self.chunk.code.items[offset + 1];
        const value = self.chunk.constants.items[constant];
        print("{s:<16} {:<4} ", .{ name, constant });
        value.print(std.debug);
        print("\n", .{});
        return offset + 2;
    }
};
