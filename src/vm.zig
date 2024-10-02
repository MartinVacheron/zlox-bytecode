const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Value = @import("values.zig").Value;
const Compiler = @import("compiler.zig").Compiler;
const Obj = @import("obj.zig").Obj;
const ObjString = @import("obj.zig").ObjString;
const config = @import("config");

const Stack = struct {
    values: [STACK_SIZE]Value,
    top: [*]Value,

    const STACK_SIZE: u8 = std.math.maxInt(u8);
    const Self = @This();

    pub fn new() Self {
        return .{
            .values = [_]Value{.{ .Null = undefined }} ** STACK_SIZE,
            .top = undefined,
        };
    }

    pub fn init(self: *Self) void {
        self.top = self.values[0..].ptr;
    }

    fn push(self: *Self, value: Value) void {
        self.top[0] = value;
        self.top += 1;
    }

    fn pop(self: *Self) Value {
        self.top -= 1;
        return self.top[0];
    }

    fn peek(self: *const Self, distance: usize) *const Value {
        return &self.top[-1 - distance];
    }
};

pub const Vm = struct {
    chunk: Chunk,
    ip: [*]u8,
    stack: Stack,
    compiler: Compiler,
    allocator: Allocator,
    objects: ?*Obj,

    const Self = @This();

    const VmErr = error{
        RuntimeErr,
    } || Compiler.CompileErr;

    pub fn new(allocator: Allocator) Self {
        return .{
            .chunk = Chunk.init(allocator),
            .ip = undefined,
            .stack = Stack.new(),
            .compiler = Compiler.new(),
            .allocator = allocator,
            .objects = null,
        };
    }

    pub fn init(self: *Self) void {
        self.stack.init();
        self.compiler.init(self);
    }

    pub fn deinit(self: *Self) void {
        self.chunk.deinit();
        self.free_objects();
    }

    fn free_objects(self: *Self) void {
        var object = self.objects;
        while (object) |obj| {
            const next = obj.next;
            self.free_object(obj);
            object = next;
        }
    }

    fn free_object(self: *Self, object: *Obj) void {
        switch (object.kind) {
            .String => {
                const string = object.as(ObjString);
                self.allocator.free(string.chars);
                self.allocator.destroy(string);
            },
        }
    }

    fn read_byte(self: *Self) u8 {
        const byte = self.ip[0];
        self.ip += 1;
        return byte;
    }

    pub fn interpret(self: *Self, source: []const u8) VmErr!void {
        self.chunk.code.clearRetainingCapacity();
        try self.compiler.compile(source, &self.chunk);
        self.ip = self.chunk.code.items.ptr;

        try self.run();
    }

    pub fn run(self: *Self) VmErr!void {
        while (true) {
            if (config.PRINT_STACK) {
                print("          ", .{});

                var value = self.stack.values[0..].ptr;
                while (value != self.stack.top) : (value += 1) {
                    print("[", .{});
                    value[0].print(std.debug);
                    print("] ", .{});
                }
                print("\n", .{});
            }

            // as it is known as comptime (const via build.zig), not compiled
            // if not needed (equivalent of #ifdef or #[cfg(feature...)])
            if (config.TRACING) {
                const Dis = @import("disassembler.zig").Disassembler;
                const dis = Dis.init(self.chunk);
                _ = dis.dis_instruction(self.instruction_nb());
            }

            const instruction = self.read_byte();
            const op_code: OpCode = @enumFromInt(instruction);

            switch (op_code) {
                .Add => self.stack.push(try self.binop('+')),
                .Constant => {
                    const value = self.chunk.read_constant(self.read_byte());
                    self.stack.push(value);
                },
                .Divide => self.stack.push(try self.binop('/')),
                .Equal => {
                    const v1 = self.stack.pop();
                    const v2 = self.stack.pop();
                    self.stack.push(Value.bool_(v1.equals(v2)));
                },
                .False => self.stack.push(Value.bool_(false)),
                .Greater => self.stack.push(try self.binop('>')),
                .Less => self.stack.push(try self.binop('<')),
                .Multiply => self.stack.push(try self.binop('*')),
                .Negate => {
                    // PERF: https://craftinginterpreters.com/a-virtual-machine.html#challenges [4]
                    const value = self.stack.pop();
                    switch (value) {
                        .Int => |v| self.stack.push(Value.int(-v)),
                        .Float => |v| self.stack.push(Value.float(-v)),
                        else => self.runtime_err("operand must be a number"),
                    }
                },
                .Null => self.stack.push(Value.null_()),
                .Not => {
                    const value = self.stack.pop().as_bool() orelse {
                        self.runtime_err("operator '!' can only be used with bool operand");
                        return error.RuntimeErr;
                    };
                    self.stack.push(Value.bool_(!value));
                },
                .Return => {
                    const value = self.stack.pop();
                    value.print(std.debug);
                    print("\n", .{});
                    return;
                },
                .Subtract => self.stack.push(try self.binop('-')),
                .True => self.stack.push(Value.bool_(true)),
            }
        }
    }

    fn binop(self: *Self, op: u8) Allocator.Error!Value {
        const v2 = self.stack.pop();
        const v1 = self.stack.pop();

        if (v1 == .Obj and v2 == .Obj) {
            return try self.concatenate(v1, v2);
        }

        if (v1 == .Int and v2 != .Int or v1 == .Float and v2 != .Float) {
            self.runtime_err("binary operation only allowed between ints or floats");
        }

        if (v1 == .Int and v2 == .Int) {
            return switch (op) {
                '+' => Value.int(v1.Int + v2.Int),
                '-' => .{ .Int = v1.Int - v2.Int },
                '*' => .{ .Int = v1.Int * v2.Int },
                '/' => .{ .Int = @divTrunc(v1.Int, v2.Int) },
                '<' => Value.bool_(v1.Int < v2.Int),
                '>' => Value.bool_(v1.Int > v2.Int),
                else => unreachable,
            };
        }

        if (v1 == .Float and v2 == .Float) {
            return switch (op) {
                '+' => .{ .Float = v1.Float + v2.Float },
                '-' => .{ .Float = v1.Float - v2.Float },
                '*' => .{ .Float = v1.Float * v2.Float },
                '/' => .{ .Float = v1.Float / v2.Float },
                '<' => Value.bool_(v1.Float < v2.Float),
                '>' => Value.bool_(v1.Float > v2.Float),
                else => unreachable,
            };
        }

        unreachable;
    }

    fn concatenate(self: *Self, str1: Value, str2: Value) Allocator.Error!Value {
        const obj1 = str1.as_obj().?.as(ObjString);
        const obj2 = str2.as_obj().?.as(ObjString);

        const res = try self.allocator.alloc(u8, obj1.chars.len + obj2.chars.len);
        @memcpy(res[0..obj1.chars.len], obj1.chars);
        @memcpy(res[obj1.chars.len..], obj2.chars);

        return Value.obj((try ObjString.create(self, res)).as_obj());
    }

    fn runtime_err(self: *const Self, msg: []const u8) void {
        const line = self.chunk.lines.items[self.instruction_nb()];
        print("[line {}] in script: {s}\n", .{ line, msg });
        // TODO: in repl mode, the stack is corrupted if we don't stop execution
    }

    fn instruction_nb(self: *const Self) usize {
        const addr1 = @intFromPtr(self.ip);
        const addr2 = @intFromPtr(self.chunk.code.items.ptr);
        return addr1 - addr2;
    }
};
