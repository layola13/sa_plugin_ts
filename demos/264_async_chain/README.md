# Async/Await Chained (pending propagation)

Await inside an `async function` checks the handle state and returns a
pending handle to the caller (`ready_pending_state_return_if_async` shape,
copied from `sa_plugin_sla`). All handles here are ready, so the ready path
runs; Node is the oracle (42).
