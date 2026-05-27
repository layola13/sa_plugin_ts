const std = @import("std");

pub const Variable = struct {
    name: []const u8,
    type_name: []const u8,
    reg: []const u8,
    is_heap_allocated: bool,
    is_consumed: bool,
};

pub const Scope = struct {
    variables: std.ArrayList(Variable),
    
    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        for (self.variables.items) |v| {
            allocator.free(v.name);
            allocator.free(v.type_name);
            allocator.free(v.reg);
        }
        self.variables.deinit();
    }
};

pub const ScopeManager = struct {
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(Scope),

    pub fn init(allocator: std.mem.Allocator) ScopeManager {
        return .{
            .allocator = allocator,
            .scopes = std.ArrayList(Scope).init(allocator),
        };
    }

    pub fn deinit(self: *ScopeManager) void {
        for (self.scopes.items) |*scope| {
            scope.deinit(self.allocator);
        }
        self.scopes.deinit();
    }

    pub fn enterScope(self: *ScopeManager) !void {
        const scope = Scope{
            .variables = std.ArrayList(Variable).init(self.allocator),
        };
        try self.scopes.append(scope);
    }

    pub fn exitScope(self: *ScopeManager, lowerer: anytype) !void {
        if (self.scopes.items.len == 0) return;
        var scope_opt = self.scopes.pop();
        if (scope_opt) |*scope| {
            defer scope.deinit(self.allocator);

            // Emit physical releases for any active allocated variables in this scope
            var i = scope.variables.items.len;
            while (i > 0) {
                i -= 1;
                const v = scope.variables.items[i];
                if (v.is_heap_allocated and !v.is_consumed) {
                    try lowerer.emit("    !{s}\n", .{v.reg});
                }
            }
        }
    }

    pub fn declareVar(self: *ScopeManager, name: []const u8, type_name: []const u8, reg: []const u8, is_heap: bool) !void {
        if (self.scopes.items.len == 0) return error.NoActiveScope;
        const current = &self.scopes.items[self.scopes.items.len - 1];
        try current.variables.append(.{
            .name = try self.allocator.dupe(u8, name),
            .type_name = try self.allocator.dupe(u8, type_name),
            .reg = try self.allocator.dupe(u8, reg),
            .is_heap_allocated = is_heap,
            .is_consumed = false,
        });
    }

    pub fn lookup(self: *ScopeManager, name: []const u8) ?*Variable {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            for (scope.variables.items) |*v| {
                if (std.mem.eql(u8, v.name, name)) {
                    return v;
                }
            }
        }
        return null;
    }
};
