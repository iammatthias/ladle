/// What a user may do, from `you.ext.permissions` (EXTENSIONS.md, `ext:permissions`). A key that
/// is absent or not a boolean takes its default, and so does every key when `permissions` is not
/// an object, such as an older server's list of names.
public struct Permissions: Hashable, Sendable {
    /// May send the requests of the `write` row of `ext:limits`.
    public var write = true
    /// May send `room_join` with a `user_id`, in any room.
    public var addMembers = false
    /// May move other users' messages.
    public var moveAny = false

    public init() {}

    public init(_ value: JSONValue?) {
        write = value?["write"]?.boolValue ?? write
        addMembers = value?["add_members"]?.boolValue ?? addMembers
        moveAny = value?["move_any"]?.boolValue ?? moveAny
    }
}
