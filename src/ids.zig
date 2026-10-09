//! The identity a simulation issues to its tasks, and a trace records.
const aegis = @import("aegis");

const TaskTag = struct {};

/// A simulated task. Ids are issued from 1, in the order tasks start, by one
/// `TaskIssuer` per simulation; `outside` is no task at all.
pub const TaskId = aegis.id.Id(TaskTag, u32);

/// The issuer of a simulation's task ids: externally serialised, it never
/// wraps and never issues `outside`.
pub const TaskIssuer = aegis.id.Counter(TaskTag, u32);

/// The id of a call made from outside any task: the driver, or a `Sim.at`
/// callback's caller.
pub const outside: TaskId = .fromRaw(0);
