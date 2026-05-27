# FAQ: sa_plugin_ts

## Q: Why only a subset of TypeScript?
A: To achieve the performance of a native systems language, we must have deterministic memory layouts. Features like any or runtime prototype changes break the O(1) offset mapping that makes SA so fast.

## Q: How is memory safety guaranteed?
A: The plugin injects SA ownership operators (\\^, !). The resulting SA code is then verified by the Referee using bitmask capability tracking. If the plugin generates unsafe code, the SA compiler will reject it.

## Q: Can I use existing NPM packages?
A: Only if they are written in this "Strict TS" subset and compiled via this plugin. Traditional JS packages relying on Node.js/V8 runtime features are incompatible.

## Q: What about the DOM?
A: DOM access is handled via the SAX (Symbolic Affine XML) airlock, ensuring that UI updates are also verified and secure.
