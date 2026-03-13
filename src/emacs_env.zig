//! Zig bindings for the Emacs dynamic module API (emacs-module.h).
//!
//! The struct layout is generated from the actual emacs-module.h header
//! using @cImport, ensuring ABI compatibility with any Emacs version.

pub const c = @cImport({
    @cInclude("emacs-module.h");
});

// Re-export the key types for convenience
pub const emacs_env = c.emacs_env;
pub const emacs_runtime = c.struct_emacs_runtime;
pub const emacs_value = c.emacs_value;
pub const ptrdiff_t = c.ptrdiff_t;
pub const emacs_funcall_exit = c.enum_emacs_funcall_exit;

/// Function signature for module functions callable from Elisp.
pub const emacs_function = *const fn (
    env: ?*emacs_env,
    nargs: ptrdiff_t,
    args: [*c]emacs_value,
    data: ?*anyopaque,
) callconv(.c) emacs_value;

// ── Helper functions ────────────────────────────────────────────────────

/// Bind a Zig function as a named Elisp function.
pub fn defun(
    env: *emacs_env,
    name: [*:0]const u8,
    min_arity: ptrdiff_t,
    max_arity: ptrdiff_t,
    func: emacs_function,
    doc: ?[*:0]const u8,
) void {
    const sym = env.intern.?(env, name);
    const fun = env.make_function.?(env, min_arity, max_arity, @ptrCast(func), doc, null);
    var args = [_]emacs_value{ sym, fun };
    _ = env.funcall.?(env, env.intern.?(env, "fset"), 2, &args);
}

/// Call (provide 'feature).
pub fn provide(env: *emacs_env, feature: [*:0]const u8) void {
    const sym = env.intern.?(env, feature);
    var args = [_]emacs_value{sym};
    _ = env.funcall.?(env, env.intern.?(env, "provide"), 1, &args);
}

/// Signal an error to Emacs.
pub fn signal_error(env: *emacs_env, symbol: [*:0]const u8, msg: []const u8) void {
    const err_sym = env.intern.?(env, symbol);
    const err_data = env.make_string.?(env, msg.ptr, @intCast(msg.len));
    var list_args = [_]emacs_value{err_data};
    const err_list = env.funcall.?(env, env.intern.?(env, "list"), 1, &list_args);
    env.non_local_exit_signal.?(env, err_sym, err_list);
}

/// Return the Elisp nil value.
pub fn nil(env: *emacs_env) emacs_value {
    return env.intern.?(env, "nil");
}

/// Return the Elisp t value.
pub fn t_val(env: *emacs_env) emacs_value {
    return env.intern.?(env, "t");
}

/// Check for non-local exit.
pub fn check_exit(env: *emacs_env) bool {
    return env.non_local_exit_check.?(env) != c.emacs_funcall_exit_return;
}

/// Make a global reference (persists across env lifetimes).
pub fn make_global_ref(env: *emacs_env, val: emacs_value) emacs_value {
    return env.make_global_ref.?(env, val);
}

/// Call (insert STRING) in the current buffer.
pub fn insert(env: *emacs_env, str: emacs_value) void {
    var args = [_]emacs_value{str};
    _ = env.funcall.?(env, env.intern.?(env, "insert"), 1, &args);
}

/// Call (point) to get current buffer position.
pub fn point(env: *emacs_env) emacs_value {
    return env.funcall.?(env, env.intern.?(env, "point"), 0, null);
}

/// Call (put-text-property START END PROP VALUE).
pub fn put_text_property(env: *emacs_env, start: emacs_value, end: emacs_value, prop: emacs_value, value: emacs_value) void {
    var args = [_]emacs_value{ start, end, prop, value };
    _ = env.funcall.?(env, env.intern.?(env, "put-text-property"), 4, &args);
}

/// Build a list from a slice of values.
pub fn list(env: *emacs_env, items: []emacs_value) emacs_value {
    return env.funcall.?(env, env.intern.?(env, "list"), @intCast(items.len), items.ptr);
}
