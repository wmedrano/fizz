const std = @import("std");

/// Create a new string interner. `Id` must be a struct that contains a single number field named
/// `id`.
pub fn StringInterner(Id: type) type {
    return struct {
        const Self = @This();

        string_to_id: std.StringHashMapUnmanaged(Id) = .{},
        id_to_string: std.AutoHashMapUnmanaged(Id, []const u8) = .{},

        /// Deinitialize the string interner and free all associated memory.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var string_iter = self.string_to_id.keyIterator();
            while (string_iter.next()) |s| allocator.free(s.*);
            self.string_to_id.deinit(allocator);
            self.id_to_string.deinit(allocator);
        }

        /// Get the name of the given id or `null` if it does not exist.
        pub fn getName(self: *const Self, id: Id) ?[]const u8 {
            return self.id_to_string.get(id);
        }

        /// Get the id for the given name or `null` if it does not exist.
        pub fn getId(self: *const Self, name: []const u8) ?Id {
            return self.string_to_id.get(name);
        }

        /// Get the id for the given name or make it and return the new `id` if it does not exist.
        pub fn getOrMakeId(self: *Self, allocator: std.mem.Allocator, name: []const u8) !Id {
            if (self.getId(name)) |id| return id;
            const new_name = try allocator.dupe(u8, name);
            errdefer allocator.free(new_name);
            const id = .{ .id = self.string_to_id.count() };
            try self.id_to_string.put(allocator, id, new_name);
            errdefer _ = self.id_to_string.remove(id);
            try self.string_to_id.put(allocator, new_name, id);
            return id;
        }
    };
}
