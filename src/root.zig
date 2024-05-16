const std = @import("std");

const ArgIterator = std.process.ArgIterator;

/// Combines `Config` with an `args` field which stores positional arguments.
pub fn Result(comptime Config: type) type {
    return struct {
        config: Config,
        /// Stores extra positional arguments not linked to any flag or option.
        args: []const []const u8,
    };
}

fn fatal(comptime message: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print("error: " ++ message ++ "\n", args) catch {};
    std.process.exit(1);
}

// TODO allow user to specify the maximum number of positional arguments.
const max_positional_args = 8;
// This must be global to guarantee a static lifetime, otherwise allocation would be needed at
// runtime to store positional arguments.
var positionals: [max_positional_args][]const u8 = undefined;

pub fn parse(args: *ArgIterator, comptime Config: type) Result(Config) {
    if (@typeInfo(Config) != .Struct) @compileError("Config type must be a struct.");

    inline for (std.meta.fields(Config)) |field| {
        switch (@typeInfo(field.type)) {
            // Allow bool values only outside of optionals
            .Bool => {},
            .Optional => |optional| assertValidFieldType(optional.child, field.name),
            else => assertValidFieldType(field.type, field.name),
        }
    }

    if (@hasDecl(Config, "switches")) {
        const Switches = @TypeOf(Config.switches);
        if (@typeInfo(Switches) != .Struct) {
            @compileError("'switches' must be a struct declaration.");
        }

        const fields = std.meta.fields(Switches);
        inline for (fields, 1..) |field, i| {
            // check for duplicates
            inline for (fields[i..]) |other_field| {
                if (@field(Config.switches, field.name) ==
                    @field(Config.switches, other_field.name))
                {
                    @compileError(std.fmt.comptimePrint(
                        "Duplicated switch values: '{s}' and '{s}'",
                        .{ field.name, other_field.name },
                    ));
                }
            }

            if (!@hasField(Config, field.name)) @compileError(
                "switch name not defined in Config: '" ++ field.name ++ "'",
            );

            const swtch = @field(Config.switches, field.name);
            if (@TypeOf(swtch) != comptime_int) @compileError(
                "switch is not a character: '" ++ field.name ++ "'",
            );
            switch (swtch) {
                'a'...'z', 'A'...'Z' => {},
                else => @compileError(std.fmt.comptimePrint(
                    "switch is not a letter: '{c}'",
                    .{swtch},
                )),
            }
        }
    }

    var config: Config = undefined;
    var passed: std.enums.EnumFieldStruct(std.meta.FieldEnum(Config), bool, false) = .{};

    var positional_count: u32 = 0;

    next_arg: while (args.next()) |arg| {
        if (arg.len == 0) fatal("empty argument", .{});

        if (arg[0] != '-') {
            if (positional_count == max_positional_args) fatal("too many arguments", .{});
            positionals[positional_count] = arg;
            positional_count += 1;

            continue :next_arg;
        }

        if (arg.len == 1) fatal("unrecognized argument: '-'", .{});
        if (arg[1] == '-') {
            inline for (std.meta.fields(Config)) |field| {
                if (std.mem.eql(u8, arg, flagName(field))) {
                    @field(passed, field.name) = true;

                    @field(config, field.name) = parseArg(field.type, args);

                    continue :next_arg;
                }
            }
            fatal("unrecognized flag: {s}", .{arg});
        }

        if (@hasDecl(Config, "switches")) {
            next_switch: for (arg[1..], 1..) |char, i| {
                inline for (std.meta.fields(@TypeOf(Config.switches))) |switch_field| {
                    if (char == @field(Config.switches, switch_field.name)) {
                        @field(passed, switch_field.name) = true;

                        const FieldType = @TypeOf(@field(config, switch_field.name));
                        // Removing this check would allow formats like "-abc value-for-a value-for-b value-for-c"
                        if (FieldType != bool and i != arg.len - 1) {
                            fatal("expected argument after switch '{c}'", .{char});
                        }
                        const value = parseArg(FieldType, args);
                        @field(config, switch_field.name) = value;

                        continue :next_switch;
                    }
                }

                fatal("unrecognized switch: {c}", .{char});
            }
            continue :next_arg;
        }
    }

    inline for (std.meta.fields(Config)) |field| {
        if (@field(passed, field.name) == false) {
            if (field.default_value) |default_opaque| {
                const default = @as(*const field.type, @ptrCast(@alignCast(default_opaque))).*;
                @field(config, field.name) = default;
            } else {
                @field(config, field.name) = switch (@typeInfo(field.type)) {
                    .Optional => null,
                    .Bool => false,
                    else => fatal("missing required flag: '{s}'", .{flagName(field)}),
                };
            }
        }
    }

    return Result(Config){
        .config = config,
        .args = positionals[0..positional_count],
    };
}

fn assertValidFieldType(comptime T: type, comptime field_name: []const u8) void {
    if (T == []const u8) return;

    switch (@typeInfo(T)) {
        .Int => return,
        .Enum => |e| if (e.is_exhaustive) return,

        else => {}, // fallthrough to compileError.
    }

    @compileError(std.fmt.comptimePrint(
        "Bad Config field type '{s}': {s}.",
        .{ field_name, @typeName(T) },
    ));
}

fn parseArg(comptime T: type, args: *ArgIterator) T {
    if (T == bool) return true;

    const value = args.next() orelse fatal("expected argument.", .{});

    const V = switch (@typeInfo(T)) {
        .Optional => |optional| optional.child,
        else => T,
    };

    if (V == []const u8) return value;

    if (@typeInfo(V) == .Enum) {
        inline for (std.meta.fields(V)) |field| {
            if (std.mem.eql(u8, value, field.name)) {
                return @enumFromInt(field.value);
            }
        }

        fatal("invalid option: '{s}'", .{value});
    }

    if (@typeInfo(V) == .Int) {
        const num = std.fmt.parseInt(V, value, 10) catch |err| switch (err) {
            error.Overflow => fatal(
                "integer argument too big for {s}: '{s}'.",
                .{ @typeName(V), value },
            ),
            error.InvalidCharacter => fatal(
                "expected integer argument, found '{s}'",
                .{value},
            ),
        };
        return num;
    }
}

fn flagName(comptime field: std.builtin.Type.StructField) []const u8 {
    return comptime blk: {
        var name: []const u8 = "--";

        for (field.name) |ch| name = name ++ .{switch (ch) {
            '_' => '-',
            else => ch,
        }};

        break :blk name;
    };
}
