# Async/Await (ready future)

`async function` lowers to a ready-future handle (ReadyFuture layout, copied
from `sa_plugin_sla`); `await` unwraps and consumes it. Node runs the same
program as the oracle (42).
